package app;

import haxeon.ui.LayoutFrame;

import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.host.DesktopUiHostContext;
import ui.ExosuitApp;

/** Repeatable real UI workload; fixtures and settings must live outside user data. */
@:access(ui.ExosuitApp)
class MemoryWorkloadApp extends ExosuitApp {
	final fixture:String;
	final workloadEnd:Int;
	public var frames = 0;
	public function new(context:DesktopUiHostContext, fixture:String, cycles:Int) {
		super(context.fonts, null, context, null, null, null, false,
			(cwd, requestFrame, palette) -> ui.TerminalPane.open(cwd, requestFrame, palette));
		this.fixture = fixture;
		workloadEnd = 21 + cycles * 30;
		application.openArgument(fixture);
	}
	public function observe(directory:String, stage:String):Void {
		var paneCount = 0;
		for (_ in editorPanes.keys()) paneCount++;
		sys.io.File.saveContent(directory + "/" + stage + ".ui.json", haxe.Json.stringify({
			states: ui.buildContext.stateStore.diagnosticCounts(),
			keys: ui.buildContext.diagnosticKeyCounts(),
			documents: application.workspace.documents.documents.length,
			views: host.allViews().length,
			editorPanes: paneCount,
			terminals: host.allTerminalTabs().length
		}));
		StartupMemory.sample(directory, stage);
	}

	override public function submit(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frames++;
		var step = (frames - 21) % 30;
		if (frames >= 21 && frames < workloadEnd) {
			if (step == 0) {
				for (i in 0...12) application.openArgument(fixture + "/file-" + i + ".txt");
				if (host.activePane.tabs.length != 12) throw "workload failed to open 12 documents";
				openTerminal();
				if (host.allTerminalTabs().length != 1) throw "workload failed to create shell";
			}
			if (step >= 2 && step <= 8) {
				var view = host.activeView();
				view.textInput("workload edit\n");
				view.restoreScroll(0, (step - 2) * 10000);
			}
			if (step == 9) {
				showSidebarMode("search");
				searchPanel.search("needle");
				application.workspaceSearch.flush();
				for (_ in 0...1000) if (!application.workspaceSearch.complete) application.workspace.jobs.update(32);
				if (!application.workspaceSearch.complete || application.workspaceSearch.results.length == 0)
					throw "workload search did not complete";
			}
			if (step == 13) application.openArgument(fixture + "/file-0.txt");
			if (step == 17) {
				searchPanel.search(""); application.workspaceSearch.flush();
				while (host.activePane.items.length > 0) if (!host.closeActiveTab(true)) throw "workload close failed";
				for (terminal in host.panelTerminals) terminal.dispose();
				host.panelTerminals.resize(0); host.activePanelTerminalIndex = -1;
				dock.close("terminal"); showSidebarMode("files");
				if (host.allTerminalTabs().length != 0) throw "workload terminal remained open";
			}
		}
		return super.submit(frame);
	}
}

class MemoryWorkloadMain {
	static function main():Int {
		var args = Sys.args();
		if (args.length < 2 || args.length > 3) throw "expected fixture directory, observations directory and optional cycle count";
		var cycles = args.length == 3 ? Std.parseInt(args[2]) : 10;
		if (cycles == null || cycles < 1 || cycles > 1000) throw "cycle count must be between 1 and 1000";
		var workloadEnd = 21 + cycles * 30;
		var finalFrame = workloadEnd + 60;

		var options = new DesktopUiHostOptions();
		options.title = "Exosuit memory workload";
		options.width = 1280; options.height = 840;
		options.captureDirectory = args[1] + "/captures";
		options.frameLimit = finalFrame;
		var app:MemoryWorkloadApp = null;
		options.captureReady = function() {
			var n = app.frames;
			if (n == 20 || n == finalFrame) {
				app.observe(args[1], n == 20 ? "baseline" : "final-idle");
				hl.Gc.major();
				app.observe(args[1], n == 20 ? "baseline-gc" : "final-idle-gc");
				if (n == finalFrame && Sys.getEnv("EXOSUIT_WORKLOAD_HEAP_DUMP") == "1") StartupMemory.dump(args[1]);
			}
			if (n >= 21 && n < workloadEnd) {
				var step = (n - 21) % 30;
				var cycle = Std.int((n - 21) / 30) + 1;
				if (step == 15) app.observe(args[1], "cycle-" + cycle + "-loaded");
				if (step == 29) {
					app.observe(args[1], "cycle-" + cycle + "-clean");
					hl.Gc.major();
					app.observe(args[1], "cycle-" + cycle + "-clean-gc");
				}
			}
			return true;
		};
		var status = DesktopUiHost.run(options, context -> app = new MemoryWorkloadApp(context, args[0], cycles));

		return status;
	}
}
