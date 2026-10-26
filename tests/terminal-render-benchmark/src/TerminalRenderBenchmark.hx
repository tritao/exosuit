import haxe.io.Bytes;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;

@:hlNative("std", "sys_timestamp_ms")
extern function benchmarkMonotonicMs():haxe.Int64;

/** Echoes input and emits ordered output through the production session path. */
class ScenarioBackend implements TerminalBackend {
	final pending:Array<TerminalEvent> = [];
	var offset:haxe.Int64 = 0;
	public var bytes = 0;
	public var inputBytes = 0;
	public var dispatchMs = 0.0;
	public var dispatchCpuMs = 0.0;
	public function new() {}
	public function id():String return "render-benchmark";
	public function output(text:String):Void {
		var data = Bytes.ofString(text);
		pending.push(TerminalEvent.output(offset, data));
		offset += data.length;
		bytes += data.length;
	}
	public function write(data:Bytes):Void {
		inputBytes += data.length;
		output(data.toString());
	}
	public function resize(columns:Int, rows:Int):Void pending.push(TerminalEvent.geometry(columns, rows));
	public function pollEvents(emit:TerminalEvent->Void):Void {
		// Writes triggered by VT queries remain queued for the next poll.
		var batch = pending.copy();
		pending.resize(0);
		var wall = Sys.time();
		var cpu = Sys.threadCpuTime();
		for (event in batch) emit(event);
		dispatchCpuMs = (Sys.threadCpuTime() - cpu) * 1000;
		dispatchMs = (Sys.time() - wall) * 1000;
	}
	public function requestReplay(offset:haxe.Int64):Void throw "Unexpected replay";
	public function terminate(force:Bool):Void {}
	public function detach():Void {}
	public function close():Void {}
}

@:access(ui.TerminalPane)
class BenchmarkApp implements DesktopUiApplication {
	public static final scenarios = ["idle", "typing", "progress", "scroll", "ansi-redraw", "unicode-redraw", "scrollback"];
	public static inline final FRAMES = 140;
	public static inline final WARMUP = 20;
	final ui:UiContext;
	final pane:ui.TerminalPane;
	final backend:ScenarioBackend;
	final samples:Array<Dynamic> = [];
	var frame = 0;
	final progressRepeats:Int;
	final stressSlowPolls:Array<Dynamic> = [];
	var stressMaxPoll:Dynamic = null;

	public function new(host:DesktopUiHostContext) {
		var setting = Sys.getEnv("EXOSUIT_TERMINAL_PROGRESS_REPEATS");
		var repeats = setting == null ? null : Std.parseInt(setting);
		progressRepeats = repeats == null || repeats < 1 ? 1 : repeats;
		ui = new UiContext(null, host.fonts);
		backend = new ScenarioBackend();
		pane = new ui.TerminalPane(new TerminalSession(backend, terminalkit.Emulator.open(80, 24, 10000)),
			host.requestFrame, new ui.TerminalPalette(true));
	}
	public function context():UiContext return ui;
	public function diagnosticState():Dynamic return {
		columns: pane.columns(), rows: pane.rows(), samples: samples,
		framesPerScenario: FRAMES, warmupFrames: WARMUP, scenarios: scenarios,
		inputBytes: backend.inputBytes, outputBytes: backend.bytes,
		progressRepeats: progressRepeats, stressSlowPolls: stressSlowPolls, stressMaxPoll: stressMaxPoll
	};
	function logLine(number:Int):String return StringTools.lpad(Std.string(number), "0", 6)
		+ " INFO compile workspace/terminal module=renderer duration=12ms status=ok\r\n";
	function redraw(tick:Int, unicode:Bool):String {
		var output = new StringBuf();
		output.add("\x1b[H");
		for (row in 0...pane.rows()) {
			output.add("\x1b[" + (row + 1) + ";1H");
			var text = unicode ? "日本語 café λ → 界 " : "build renderer status ";
			// Bound display width; erase the remainder of each row.
			var repeat = Std.int((pane.columns() - 16) / (unicode ? 21 : text.length));
			output.add("\x1b[" + (31 + ((row + tick) % 6)) + "m");
			output.add(StringTools.lpad(Std.string(tick * 100 + row), "0", 8) + " ");
			for (_ in 0...repeat) output.add(text);
			output.add("\x1b[0m\x1b[K");
		}
		return output.toString();
	}
	public function submit(layout:LayoutFrame):RenderNode {
		var stage = Std.int(frame / FRAMES);
		var tick = frame % FRAMES;
		var scenario = scenarios[stage];
		var span = "terminal." + (tick >= WARMUP ? "measured." : "warmup.") + scenario;
		haxeon.ProfileSpan.begin(span);
		if (tick == 0) {
			backend.output("\x1b[0m\x1b[2J\x1b[H\x1b[?25l");
			if (scenario == "idle" || scenario == "scrollback")
				for (line in 0...500) backend.output(logLine(line));
		}
		var bytesBefore = backend.bytes;
		var previous = pane.revisions.copy();
		var monotonicStarted = benchmarkMonotonicMs();
		var cpuStarted = Sys.threadCpuTime();
		var started = Sys.time();
		switch scenario {
			case "typing":
				if (tick % 60 == 0) backend.output("\r\n$ ");
				pane.sendText("abcdefghijklmnopqrstuvwxyz0123456789".charAt(tick % 36));
			case "progress": backend.output("\r\x1b[32mDownloading [" + tick + "/140] 42.5 MiB/s\x1b[0m\x1b[K");
			case "scroll": for (line in 0...10) backend.output(logLine(tick * 10 + line));
			case "ansi-redraw": backend.output(redraw(tick, false));
			case "unicode-redraw": backend.output(redraw(tick, true));
			case "scrollback": pane.session.emulator.scrollback(1 + (tick % 50) * 5);
			default:
		}
		var generated = Sys.time();
		haxeon.ProfileSpan.begin("terminal.poll");
		pane.poll();
		haxeon.ProfileSpan.end("terminal.poll");
		var polled = Sys.time();
		var pollCpuMs = (Sys.threadCpuTime() - cpuStarted) * 1000;
		var pollMonotonicMs = haxe.Int64.toInt(benchmarkMonotonicMs() - monotonicStarted);
		if (scenario == "progress" && progressRepeats > 1) {
			for (replay in 1...progressRepeats) {
				var index = (tick * progressRepeats + replay) % FRAMES;
				backend.output("\r\x1b[32mDownloading [" + index + "/140] 42.5 MiB/s\x1b[0m\x1b[K");
				var mono = benchmarkMonotonicMs();
				var cpu = Sys.threadCpuTime();
				var wall = Sys.time();
				pane.poll();
				var elapsed = (Sys.time() - wall) * 1000;
				var cpuMs = (Sys.threadCpuTime() - cpu) * 1000;
				if (stressMaxPoll == null || elapsed > stressMaxPoll.wallMs || elapsed > 50) {
					var record = {frame: frame + 1, tick: index, replay: replay, startedAtSeconds: wall,
						wallMs: elapsed, cpuMs: cpuMs, monotonicMs: haxe.Int64.toInt(benchmarkMonotonicMs() - mono),
						dispatchMs: backend.dispatchMs, dispatchCpuMs: backend.dispatchCpuMs,
						refreshMs: elapsed - backend.dispatchMs};
					if (stressMaxPoll == null || elapsed > stressMaxPoll.wallMs) stressMaxPoll = record;
					if (elapsed > 50) stressSlowPolls.push(record);
				}
			}
		}
		var stressFinished = Sys.time();
		var changed = 0;
		for (row in 0...pane.revisions.length)
			if (row >= previous.length || previous[row] != pane.revisions[row]) changed++;
		haxeon.ProfileSpan.begin("terminal.ui-submit");
		var root = ui.submit(pane, layout);
		var rowCache = Sys.getEnv("EXOSUIT_TERMINAL_ROW_CACHE");
		if (rowCache == "none" || rowCache == "raster") root.walk(function(node) {
			if (node.styleKey != null && StringTools.startsWith(node.styleKey, "terminal-row-"))
				node.cachePolicy = rowCache == "none" ? haxeon.ui.core.CachePolicy.None : haxeon.ui.core.CachePolicy.Raster;
		});
		haxeon.ProfileSpan.end("terminal.ui-submit");
		var submitted = Sys.time();
		if (frame == 2) ui.focusWidget(root.id);
		samples.push({frame: frame + 1, scenario: scenario, tick: tick,
			measured: tick >= WARMUP, startedAtSeconds: started, pollMs: (polled - started) * 1000,
			pollCpuMs: pollCpuMs, pollMonotonicMs: pollMonotonicMs,
			generateMs: (generated - started) * 1000,
			dispatchMs: backend.dispatchMs, dispatchCpuMs: backend.dispatchCpuMs,
			refreshMs: (polled - generated) * 1000 - backend.dispatchMs,
			uiSubmitMs: (submitted - stressFinished) * 1000, stressMs: (stressFinished - polled) * 1000,
			changedRows: changed, outputBytes: backend.bytes - bytesBefore});
		frame++;
		haxeon.ProfileSpan.end(span);
		return root;
	}
	public function dispose():Void { pane.close(); ui.dispose(); }
}

class TerminalRenderBenchmark {
	static function main():Int {
		var args = Sys.args();
		if (args.length != 1) throw "Expected artifact directory";
		sys.io.File.saveContent(args[0] + "/process-id", Std.string(Sys.getPid()));
		var options = new DesktopUiHostOptions();
		options.title = "Exosuit terminal render benchmark";
		options.width = 1100;
		options.height = 700;
		options.captureDirectory = args[0];
		options.frameLimit = BenchmarkApp.FRAMES * BenchmarkApp.scenarios.length;
		return DesktopUiHost.run(options, function(host) return new BenchmarkApp(host));
	}
}
