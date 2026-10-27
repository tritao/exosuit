import editor.profiler.ProfilerService;
import sys.thread.Mutex;
import sys.thread.Lock;
import sys.thread.Thread;

/** Bootstrap-Haxe adapter around the existing HLDI client; newline JSON over bounded process pipes. */
class ProfilerBridge {
	static final output = new Mutex();
	static final wake = new Lock();
	static final finished = new Lock();
	static final messages:Array<Dynamic> = [];
	static var latestSnapshot:Dynamic;
	static var stopping = false;
	static function emit(value:Dynamic):Void {
		output.acquire();
		if (value.type == "snapshot") latestSnapshot = value;
		else {
			latestSnapshot = null;
			if (messages.length >= 32) messages.shift();
			messages.push(value);
		}
		output.release();
		wake.release();
	}
	static function write():Void {
		while (true) {
			wake.wait(0.25);
			output.acquire();
			var value = messages.length > 0 ? messages.shift() : latestSnapshot;
			if (value == latestSnapshot) latestSnapshot = null;
			var done = stopping && value == null;
			output.release();
			if (done) break;
			if (value != null) {
				try { Sys.println(haxe.Json.stringify(value)); Sys.stdout().flush(); }
				catch (_:Dynamic) break;
			}
		}
		finished.release();
	}
	static function compact(value:Dynamic):Dynamic return {
		state:value.state, samples:value.samples, instrumentedCalls:value.instrumentedCalls,
		functions:value.functions, threads:value.threads, gcStats:value.gcStats,
		bufferUtilization:value.bufferUtilization, stalls:value.stalls, lastError:value.lastError
	};
	static function main():Void {
		Thread.create(write);
		var service = new ProfilerService();
		service.setEmitter(function(message) {
			if (message.method == "haxeon/profilerSnapshot") {
				// LSP notifications contain view deltas and omit aggregate arrays. This adapter sends
				// coalesced complete summaries, so obtain those arrays from the shared session owner.
				var snapshot = service.execute("haxeon.profiler.snapshot", []);
				emit({type:"snapshot", value:compact(snapshot)});
			}
		});
		try {
			while (true) {
				var line = Sys.stdin().readLine();
				if (line.length > 4096) throw "Profiler command too large";
				try {
					var command:Dynamic = haxe.Json.parse(line);
					if (command.command == "report" || command.command == "export") {
						var tool = Sys.getEnv("HAXEON_DEVTOOLS_PROFILER_TOOL");
						if (tool == null) throw "hlprof-live path unavailable";
						var args = command.command == "report" ? ["report", "--top", "20", Std.string(command.options.path)]
							: ["export", "--format", "pftrace", "--output", Std.string(command.options.output), Std.string(command.options.path)];
						var process = new sys.io.Process(tool, args);
						var report = process.stdout.readAll().toString();
						var error = process.stderr.readAll().toString();
						var status = process.exitCode(); process.close();
						if (status != 0) throw error;
						emit({type:"report", text:report.substr(0, 120000)});
						continue;
					}
					var result = service.execute("haxeon.profiler." + command.command,
						[command.options == null ? {} : command.options]);
					emit({type:"result", command:command.command, value:compact(result)});
				} catch (error:Dynamic) emit({type:"error", message:Std.string(error)});
			}
		} catch (_:haxe.io.Eof) {}
		service.close();
		output.acquire(); stopping = true; output.release(); wake.release();
		finished.wait(1);
	}
}
