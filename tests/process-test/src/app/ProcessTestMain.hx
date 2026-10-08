package app;

import process.OwnedProcess;
import process.ProcessManager;
import sys.io.Process;
import sys.io.ChildProcess;
import haxe.io.Bytes;
import build.BuildOutput;
import build.BuildTaskCodec;

class ProcessTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function collect(process:OwnedProcess, timeout:Float):Array<String> {
		var output = "", errors = "", deadline = Sys.time() + timeout, settled = 0;
		while (Sys.time() < deadline && settled < 2) {
			var stdout = process.readStdout(), stderr = process.readStderr();
			output += stdout;
			errors += stderr;
			if (process.exited() && stdout.length == 0 && stderr.length == 0) settled++; else settled = 0;
		}
		require(settled >= 2, "process did not exit and drain before timeout");
		return [output, errors];
	}

	static function streamingBytes(fixture:String):Void {
		var child = Process.spawn(fixture, ["copy"]), input = Bytes.alloc(131072), output = Bytes.alloc(131072), spare = Bytes.alloc(1);
		for (index in 0...input.length) input.set(index, index & 255);
		require(child.readStdout(output, 0, 1) == -2, "empty live pipe was not would-block");
		var sent = 0, received = 0, closedInput = false, partial = false, eof = false;
		var deadline = Sys.time() + 5;
		while (Sys.time() < deadline && !eof) {
			if (sent < input.length) {
				var count = child.writeStdin(input, sent, input.length - sent);
				if (count > 0 && count < input.length - sent) partial = true;
				sent += count;
			} else if (!closedInput) { child.closeStdin(); closedInput = true; }
			// One spare byte allows observing EOF after receiving the entire payload.
			var target = received < output.length ? output : spare;
			var offset = received < output.length ? received : 0;
			var count = child.readStdout(target, offset, target.length - offset);
			if (count == -1) eof = true;
			else if (count > 0) received += count;
		}
		require(eof && partial && sent == input.length && received == input.length, "partial byte writes or pipe EOF were lost");
		for (index in 0...input.length) require(output.get(index) == input.get(index), "binary process pipe corrupted a byte");
		while (child.pollExit() == -1 && Sys.time() < deadline) {}
		require(child.pollExit() == 0, "streaming process did not exit");
		var writeFailed = false;
		try { child.writeStdin(input, 0, 1); } catch (_:Dynamic) { writeFailed = true; }
		require(writeFailed, "write to closed stdin did not fail");
		child.close(); child.close();
		var readFailed = false;
		try { child.readStdout(output, 0, 1); } catch (_:Dynamic) { readFailed = true; }
		require(readFailed, "disposed streaming handle remained usable");
		var broken = Process.spawn(fixture, ["exit", "0"]);
		deadline = Sys.time() + 5;
		while (broken.pollExit() == -1 && Sys.time() < deadline) {}
		require(broken.pollExit() == 0, "broken-pipe fixture did not exit");
		writeFailed = false;
		try { broken.writeStdin(input, 0, 1); } catch (_:Dynamic) { writeFailed = true; }
		require(writeFailed, "broken stdin pipe did not throw safely");
		broken.close();
		var spawnFailed = false;
		try { Process.spawn("/definitely/missing/exosuit-process", []); } catch (error:Dynamic) {
			spawnFailed = true;
			var message = Std.string(error);
			require(StringTools.startsWith(message, "Could not start process") && message.indexOf(": ") >= 0 && message.length < 256,
				"spawn failure corrupted the OS error message");
		}
		require(spawnFailed, "missing executable did not fail during spawn");
	}

	static function main():Int {
		var arguments = Sys.args();
		require(arguments.length == 2, "process test requires fixture and cwd");
		var fixture = arguments[0], cwd = arguments[1], manager = new ProcessManager(), environment:Map<String, String> = [];
		var decoded = BuildTaskCodec.parse("task=test\nexecutable=tool\nargument=with spaces\nenvironment=KEY=value=kept\n"), bounded = new BuildOutput();
		require(decoded.length == 1 && decoded[0].arguments[0] == "with spaces" && decoded[0].environment.get("KEY") == "value=kept",
			"task configuration did not preserve argument or environment boundaries");
		var wideLine = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
		for (index in 0...BuildOutput.MAX_LINES + 5) bounded.append('$wideLine-$index\n');
		require(bounded.lines.length > 0 && bounded.lines.length <= BuildOutput.MAX_LINES && bounded.byteCount <= BuildOutput.MAX_BYTES
			&& bounded.lines[0].text.indexOf("-0") < 0,
			"build output retention exceeded its line or byte bound");
		environment.set("PHX_TEST", "environment value");
		var inspected = manager.start(fixture, ["inspect", "argument with spaces"], cwd, environment), streams = collect(inspected, 5.0);
		require(inspected.exitStatus() == 0 && streams[0].indexOf("cwd=" + cwd) >= 0
			&& streams[0].indexOf("env=environment value") >= 0 && streams[0].indexOf("arg=argument with spaces") >= 0
			&& streams[1] == "fixture-stderr\n", "process arguments, cwd, environment, or split output were corrupted");
		require(manager.release(inspected) && inspected.state() == 0, "released process handle was not stale");

		var failed = manager.start(fixture, ["exit", "7"]), failureStreams = collect(failed, 5.0);
		require(failureStreams[0] == "" && failed.exitStatus() == 7, "nonzero process exit status was lost");
		manager.release(failed);

		var flooded = manager.start(fixture, ["flood", "200000"]), floodStreams = collect(flooded, 5.0);
		require(flooded.exitStatus() == 0 && floodStreams[0].length == 200000, "nonblocking process output was truncated or hung");
		manager.release(flooded);
		var unicode = manager.start(fixture, ["unicode-boundary"]), unicodeStreams = collect(unicode, 5.0);
		require(unicode.exitStatus() == 0 && unicodeStreams[0] == StringTools.rpad("", "x", 4095) + "😀",
			"process output corrupted UTF-8 split at the native read boundary");
		manager.release(unicode);

		var copied = manager.start(fixture, ["copy"]), input = "framed stdin Olá 😀\n";
		var written = 0, deadline = Sys.time() + 5.0;
		while (written == 0 && Sys.time() < deadline) written = copied.writeStdin(input);
		require(written == haxe.io.Bytes.ofString(input).length, "process stdin write was partial or used character length");
		require(copied.closeStdin(), "process stdin did not close");
		var copyStreams = collect(copied, 5.0);
		require(copied.exitStatus() == 0 && copyStreams[0] == input && copyStreams[1] == "", "process stdin was not copied byte-exactly");
		manager.release(copied);
		var blocked = manager.start(fixture, ["sleep"]), block = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
		var backpressure = false;
		for (_ in 0...10000)
			if (blocked.writeStdin(block) == 0) {
				backpressure = true;
				break;
			}
		require(backpressure, "process stdin did not expose nonblocking backpressure");
		manager.release(blocked);

		var cancelled = manager.start(fixture, ["sleep"]);
		require(cancelled.cancel(), "process cancellation request failed");
		collect(cancelled, 5.0);
		require(cancelled.exitStatus() >= 128, "cancelled process did not report a signal exit");
		manager.release(cancelled);
		manager.start(fixture, ["sleep"]);
		manager.shutdown();
		streamingBytes(fixture);
		require(manager.activeCount() == 0, "process manager shutdown retained owned processes");
		Sys.println("PASS: owned nonblocking processes, binary partial I/O, exact launch configuration, cancellation, and cleanup");
		return 0;
	}
}
