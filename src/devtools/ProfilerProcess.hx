package devtools;

import haxe.io.Bytes;
import sys.io.ChildProcess;

/** Nonblocking adapter for the shared HLDI implementation. Heavy decoding stays outside the viewer UI thread. */
class ProfilerProcess {
	public var snapshot(default, null):Dynamic;
	public var status(default, null) = "Profiler not connected";
	public var revision(default, null) = 0;
	public var recording(default, null) = false;
	public var report(default, null) = "";
	final process:ChildProcess;
	final buffer = Bytes.alloc(16384);
	var input = "";
	var outgoing = "";
	var disposed = false;

	public function new(port:Int) {
		var bridge = Sys.getEnv("HAXEON_DEVTOOLS_BRIDGE");
		var runtime = Sys.getEnv("HAXEON_DEVTOOLS_RUNTIME");
		if (bridge == null || runtime == null) throw "Launch with scripts/devtools.py to prepare the profiler adapter";
		process = sys.io.Process.spawn(runtime, [bridge]);
		if (port > 0) command("connect", {port:port, host:"127.0.0.1", maxEntries:20, leafCapacity:128, eventCapacity:128});
	}

	public function command(name:String, ?options:Dynamic):Void {
		if (disposed) return;
		var message = haxe.Json.stringify({command:name, options:options == null ? {unused:0} : options}) + "\n";
		if (outgoing.length + message.length > 16384) throw "Profiler command queue full";
		outgoing += message;
	}

	public function poll():Void {
		if (disposed) return;
		if (outgoing.length > 0) {
			var bytes = Bytes.ofString(outgoing);
			var sent = process.writeStdin(bytes, 0, bytes.length);
			if (sent > 0) outgoing = bytes.getString(sent, bytes.length - sent);
		}
		for (_ in 0...4) {
			var count = process.readStdout(buffer, 0, buffer.length);
			if (count <= 0) break;
			input += buffer.getString(0, count);
			if (input.length > 262144) { status = "Profiler response exceeded limit"; dispose(); return; }
		}
		var newline = input.indexOf("\n");
		while (newline >= 0) {
			try {
				var value:Dynamic = haxe.Json.parse(input.substr(0, newline));
				if (value.type == "error") status = value.message;
				else if (value.type == "report") { report = value.text; status = "Capture loaded/exported"; }
				else {
					snapshot = value.value;
					if (snapshot != null && snapshot.state != null) status = snapshot.state;
					if (value.type == "result" && value.command == "captureStart") recording = true;
					if (value.type == "result" && value.command == "captureStop") recording = false;
				}
				revision++;
			} catch (error:Dynamic) { status = Std.string(error); revision++; }
			input = input.substr(newline + 1); newline = input.indexOf("\n");
		}
		process.readStderr(buffer, 0, buffer.length);
		if (process.pollExit() != -1) { status = "Profiler adapter exited"; revision++; dispose(); }
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		process.closeStdin();
		var deadline = Sys.time() + 1;
		while (process.pollExit() == -1 && Sys.time() < deadline) {
			process.readStdout(buffer, 0, buffer.length);
			process.readStderr(buffer, 0, buffer.length);
			Sys.sleep(0.01);
		}
		process.close();
	}
}
