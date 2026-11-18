package devtools;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
	Leaves evidence when the UI thread stops ticking. The UI thread calls `beat` once per tick (and `phase` at the
	boundaries worth knowing); a background thread looks every half second and, once the UI thread has been silent for
	`threshold` seconds, appends a report to `file`: how long it has been silent, the phase and the recent phases it last
	named, and the process. HashLink cannot read another thread's stack, so the phases are the stack: they say which
	step the UI thread entered last and never left. A later beat writes one line saying how long the stall lasted.
	Costs one clock read and two stores per beat.
**/
class HangWatchdog {
	final file:String;
	final threshold:Float;
	final clock:Void->Float;
	var lastBeat:Float;
	var lastPhase = "start";
	var recent:Array<String> = [];
	var reportedFor = -1.0;
	var running = false;
	var stopped = false;

	public function new(file:String, threshold:Float = 5.0, ?clock:Void->Float) {
		this.file = file;
		this.threshold = threshold;
		this.clock = clock == null ? Sys.time : clock;
		lastBeat = this.clock();
	}

	/** Where the report goes by default: the app's state folder. */
	public static function defaultFile():String
		return Path.join([exohost.MachineCatalog.agentStateBase(), "logs", "ui-hang.log"]);

	/** The UI thread is alive and entering `name` (the step it is about to run). */
	public function beat(name:String):Void {
		var now = clock();
		if (reportedFor >= 0) recovered(now);
		lastBeat = now;
		phase(name);
	}

	/** The UI thread entered another step; the report lists the last few. */
	public function phase(name:String):Void {
		lastPhase = name;
		var list = recent;
		if (list.length >= 12) list = list.slice(list.length - 11);
		list.push(name);
		recent = list;
	}

	/** One look from the watcher: writes a report if the UI thread has been silent for the threshold and none was written for this stall. */
	public function check():Bool {
		var now = clock(), beat = lastBeat;
		if (now - beat < threshold || reportedFor == beat) return false;
		reportedFor = beat;
		var lines = ["== UI thread stalled for " + Std.int((now - beat) * 10) / 10 + " s at " + Date.now().toString() + " (pid " + Sys.getPid() + ")",
			"last phase: " + lastPhase, "recent phases: " + recent.join(" > ")];
		write(lines.join("\n") + "\n");
		return true;
	}

	function recovered(now:Float):Void {
		var stalled = Std.int((now - lastBeat) * 10) / 10;
		reportedFor = -1.0;
		write("== UI thread ticking again after " + stalled + " s\n");
	}

	function write(text:String):Void {
		try {
			var directory = Path.directory(file);
			if (directory.length > 0 && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
			var existing = FileSystem.exists(file) ? FileSystem.stat(file).size : 0;
			// The log is for the latest stalls: past 1 MB it starts over.
			if (existing > 1048576) File.saveContent(file, text);
			else {
				var out = File.append(file, false);
				out.writeString(text);
				out.close();
			}
		} catch (_:Dynamic) {}
	}

	/** Starts the watcher thread; `stop` ends it. */
	public function start():Void {
		if (running) return;
		running = true;
		stopped = false;
		sys.thread.Thread.create(function() {
			while (!stopped) {
				Sys.sleep(0.5);
				if (!stopped) check();
			}
			running = false;
		});
	}

	public function stop():Void stopped = true;
}
