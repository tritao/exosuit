package app;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.Runtime;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import terminalkit.Emulator;
import terminalsession.LocalPtyBackend;
import workspace.runtime.ServiceLog;
import workspace.runtime.TerminalHostProtocol;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	A terminal host: the process that owns one terminal's PTY and screen, so the terminal outlives the workspace service
	that started it (`main.hl --terminal-host DIRECTORY`, see docs/design/terminal-host-status.md).

	It runs from a private copy of the runtime, never from a build tree, starts the program named in `spec.bin`, keeps
	an emulator fed with the program's output, and listens on a private pipe. A service attaches with the host's
	token and gets the screen as it is now, then the output as it comes; when the service goes away the host keeps
	the program running and waits for the next one. It ends when a service tells it to end (a service that heard of
	the program's end does), when `end-request.json` appears in its folder (suit.TerminalHostFolder): the way to end a
	host nothing is attached to, or when the program has ended with no service attached: it then leaves the program's
	last screen, history and exit code in `final.bin` for the next service.

	It registers with suit as a terminal host, so the tray and `suit terminals` list it under its workspace.
**/
class TerminalHostMain {
	/** How long a host whose program ended, and which could not write `final.bin`, waits for a service to collect the last screen and exit code. */
	static inline final LINGER_SECONDS = 86400.0;
	/** A service that takes no output for this long is dropped, so the program is not blocked by it. */
	static inline final STALLED_SECONDS = 60.0;
	/** How often the host looks for an end request in its folder. */
	static inline final END_REQUEST_SECONDS = 1.0;
	/** How long after its ATTACH a service has to send its first CREDIT before it is taken for one that sends none. */
	static inline final CREDIT_WAIT_SECONDS = 1.0;
	/**
		How often a host with no service attached checks that its workspace still exists; two checks in a row must say no.
		`EXOSUIT_TERMINAL_HOST_CHECK_SECONDS` (1 to 30) makes it more often, for tests.
	**/
	static inline final WORKSPACE_CHECK_SECONDS = 30.0;
	/**
		How long a workspace may be missing from suit's list of this machine's workspaces before its unattached host ends
		the program (its last screen is kept in `final.bin`). Only an explicit removal ends a host sooner.
	**/
	static inline final ABSENT_SECONDS = 6 * 3600.0;
	/** How long the program of a host that ends for a long absence has to exit before the host stops waiting for it. */
	static inline final ABANDON_EXIT_SECONDS = 10.0;

	/**
		Why the workspace this host belongs to is gone for certain, or null. Gone means: the host's folder or the
		workspace's state folder was removed, or suit removed the workspace (`MachineCatalog.removed`: the workspace was
		removed while its service was stopped, so no service will come back for the terminal). A list of workspaces that
		lacks this one is not enough: a catalog that was reset, rewritten badly or emptied says the same
		(`WorkspaceAbsence`).
	**/
	public static function workspaceGone(directory:String, stateDirectory:String, workspace:Null<String>, catalogFile:Null<String>):Null<String> {
		if (!FileSystem.exists(directory)) return "the host's folder was removed";
		if (!FileSystem.exists(stateDirectory)) return "the workspace's state folder was removed";
		if (workspace == null || catalogFile == null) return null;
		try {
			if (suit.MachineCatalog.removed(catalogFile, workspace)) return "workspace " + workspace + " was removed from this machine";
		} catch (_:Dynamic) {}
		return null;
	}

	static function checkSeconds():Float {
		var value = Sys.getEnv("EXOSUIT_TERMINAL_HOST_CHECK_SECONDS");
		if (value == null || value.length == 0) return WORKSPACE_CHECK_SECONDS;
		var asked = Std.parseFloat(value);
		return Math.isNaN(asked) || asked < 1 || asked > WORKSPACE_CHECK_SECONDS ? WORKSPACE_CHECK_SECONDS : asked;
	}

	public static function run(args:Array<String>):Int {
		if (args.length != 1) return 2;
		var directory = args[0];
		var logPath = Path.join([directory, "host.log"]);
		try {
			return serve(directory, logPath);
		} catch (failure:Dynamic) {
			log(logPath, "host failed: " + Std.string(failure));
			return 1;
		}
	}

	static function log(path:String, message:String):Void {
		try File.appendContent(path, ServiceLog.line(message) + "\n") catch (_:Dynamic) {}
	}

	static function serve(directory:String, logPath:String):Int {
		var specPath = Path.join([directory, "spec.bin"]);
		var bytes = File.getBytes(specPath);
		// The spec holds the program's environment (API keys among it) and the pipe's token: gone from the disk before
		// anything that can fail, a spec that cannot be decoded included.
		try FileSystem.deleteFile(specPath) catch (_:Dynamic) {}
		var spec = TerminalHostProtocol.decodeSpec(bytes);
		var columns = spec.columns, rows = spec.rows;
		var runtime = Runtime.start();
		var hub = new NativeRpcHub(runtime.events);
		var pty = LocalPtyBackend.spawnProgram(spec.program, spec.arguments, spec.cwd.length == 0 ? null : spec.cwd, spec.environment, columns, rows);
		var emulator = Emulator.open(columns, rows, TerminalHostProtocol.SCROLLBACK_ROWS, "xterm-256color", false);
		/** Connections that have not sent the token yet. */
		var waiting:Array<{transport:NativeRpcTransport, until:Float}> = [];
		var owner:Null<NativeRpcTransport> = null;
		var outgoing:Array<Bytes> = [];
		/**
			What was sent to the attached service and not yet acknowledged with CREDIT (TerminalHostProtocol), and whether
			that service sends CREDIT at all. One that does is sent at most WINDOW unacknowledged: its pipe ends when more
			than it holds waits unread. A service is taken to send CREDIT from its ATTACH on: its first CREDIT follows the
			ATTACH as a separate message and may arrive a loop later, after the history (up to 16 MiB) would have gone out
			unbounded. One that sends something else first, or nothing within CREDIT_WAIT_SECONDS, is an older build that
			sends none: it is sent everything, as before.
		**/
		var unacknowledged = 0, flowControlled = false, creditSeen = false, creditDueBy = 0.0;
		var stalledSince = 0.0;
		var exited = false, exitCode = 0, exitedAt = 0.0, finalTried = false, ending = false;
		var finalPath = Path.join([directory, TerminalHostProtocol.FINAL_FILE]);
		// The service that starts a host attaches within moments. A program that ends before that (it could not start, or
		// exits at once) is reported to that service over the pipe, so the host waits for it a little before leaving a file.
		var everAttached = false, startedAt = Sys.time();
		var listener = hub.listen(NativeRpcHub.local(spec.pipe), function(transport) {
			waiting.push({transport: transport, until: Sys.time() + 10});
		});
		var hostPath = Path.join([directory, "host.json"]);
		var instance = TerminalHostProtocol.instanceOf(spec.token);
		// A request file for this pid is an earlier process's that had it: no one can address this host before `host.json`.
		suit.TerminalHostFolder.clearOwnEndRequest(directory, Sys.getPid());
		AtomicFile.write(hostPath, Json.stringify({
			version: 1,
			protocol: TerminalHostProtocol.VERSION,
			pid: Sys.getPid(),
			instance: instance,
			executable: Sys.executablePath(),
			pipe: spec.pipe,
			token: spec.token,
			program: spec.program
		}) + "\n");
		// A last screen left here is an earlier host's of this terminal (Restart Terminal): not this program's.
		try FileSystem.deleteFile(finalPath) catch (_:Dynamic) {}
		log(logPath, 'host started: pid ${Sys.getPid()}, instance ${instance}, program ${spec.program}, ${columns}x${rows}');
		/** Whether the folder is still this host's: after Restart Terminal a newer host's `host.json` is there (or none yet). */
		function ownsFolder():Bool {
			try {
				var written:Dynamic = Json.parse(File.getContent(hostPath));
				return Reflect.field(written, "token") == spec.token && Reflect.field(written, "pid") == Sys.getPid();
			} catch (_:Dynamic) {
				return false;
			}
		}
		// The service wrote which terminal of which workspace this is; suit shows the host by it. Never fatal.
		var identity = suit.TerminalHostFolder.read(directory);
		var stateDirectory = Path.directory(Path.directory(directory));
		try suit.SuitClient.registerTerminalHost({root: identity.root == null ? stateDirectory : identity.root, stateDir: stateDirectory,
			generation: null, workspace: identity.workspace}) catch (_:Dynamic) {}
		var endCheckAt = 0.0;
		// While this file names a running process, no service removes the runtime copy this host runs from.
		var lease = workspace.runtime.TerminalHosts.TerminalHostRuntime.leasePath(Path.directory(FileSystem.fullPath(Sys.programPath())), Sys.getPid());
		try File.saveContent(lease, Sys.executablePath() + "\n") catch (_:Dynamic) {}
		var checkEvery = checkSeconds();
		var workspaceCheckAt = Sys.time() + checkEvery, goneChecks = 0;
		// Only a host that registers with suit reads suit's list of workspaces: a test's state has none.
		var catalogFile = suit.SuitClient.current() == suit.SuitClient.SuitMode.Off ? null : suit.MachineCatalog.file();
		var absence = new WorkspaceAbsence();
		/** Nonzero once the host ended its program because its workspace was missing for long: when it did. */
		var abandonedAt = 0.0;

		/** What a service gets first: the terminal as it is now, and the exit code if the program has ended. */
		function current(into:Array<Bytes>):Void {
			into.push(TerminalHostProtocol.pair(TerminalHostProtocol.GEOMETRY, columns, rows));
			try TerminalHostProtocol.chunks(TerminalHostProtocol.HISTORY, emulator.historySnapshot(), into) catch (failure:Dynamic)
				log(logPath, "history could not be exported: " + Std.string(failure));
			try TerminalHostProtocol.chunks(TerminalHostProtocol.SCREEN, emulator.screenSnapshot(), into) catch (failure:Dynamic)
				log(logPath, "screen could not be exported: " + Std.string(failure));
			into.push(TerminalHostProtocol.message(TerminalHostProtocol.LIVE));
			if (exited) into.push(TerminalHostProtocol.number(TerminalHostProtocol.EXITED, exitCode));
		}

		function attach(transport:NativeRpcTransport):Void {
			if (owner != null) {
				owner.close();
				log(logPath, "the attached service was replaced by a new one");
			}
			owner = transport;
			everAttached = true;
			outgoing.resize(0);
			unacknowledged = 0;
			flowControlled = true;
			creditSeen = false;
			creditDueBy = Sys.time() + CREDIT_WAIT_SECONDS;
			stalledSince = 0;
			current(outgoing);
			log(logPath, "service attached: pid " + transport.peerProcess());
		}

		/** For a service that sends no CREDIT (an older build): it is sent everything at once, as before. */
		function liftWindow():Void {
			flowControlled = false;
			log(logPath, "the attached service sends no CREDIT (an older build): it is sent everything at once");
		}

		function handle(message:Bytes):Void {
			if (message.length == 0) return;
			var kind = message.get(0);
			// A service that sends CREDIT sends its first right after its ATTACH: anything else first is from an older build.
			if (!creditSeen && flowControlled && kind != TerminalHostProtocol.CREDIT) liftWindow();
			if (kind == TerminalHostProtocol.INPUT) {
				if (!exited && message.length > 1) try pty.write(message.sub(1, message.length - 1)) catch (_:Dynamic) {}
			} else if (kind == TerminalHostProtocol.RESIZE) {
				var wide = TerminalHostProtocol.pairFirst(message), high = TerminalHostProtocol.pairSecond(message);
				if (wide >= 1 && wide <= TerminalHostProtocol.MAX_COLUMNS && high >= 1 && high <= TerminalHostProtocol.MAX_ROWS
					&& (wide != columns || high != rows)) {
					try {
						if (!exited) pty.resize(wide, high);
						emulator.resize(wide, high);
						columns = wide;
						rows = high;
					} catch (failure:Dynamic) log(logPath, "resize failed: " + Std.string(failure));
				}
			} else if (kind == TerminalHostProtocol.KILL) {
				log(logPath, "the service asked to end the program");
				if (!exited) try pty.terminate(true) catch (_:Dynamic) {}
			} else if (kind == TerminalHostProtocol.END) {
				log(logPath, "the service asked the host to end");
				ending = true;
			} else if (kind == TerminalHostProtocol.CREDIT) {
				flowControlled = true;
				creditSeen = true;
				unacknowledged -= TerminalHostProtocol.numberOf(message);
				if (unacknowledged < 0) unacknowledged = 0;
			}
		}

		var lastLoop = Sys.time(), lastActive = Sys.time();
		while (!ending) {
			// With a service attached, or output in the last seconds, the loop runs every 10 ms. A host nobody is attached to
			// whose program is quiet (or has ended) looks four times a second: it may sit like that for hours.
			runtime.events.wait(owner != null || waiting.length > 0 || Sys.time() - lastActive < 2 ? 0.01 : 0.25);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			var now = Sys.time();
			if (now >= endCheckAt) {
				endCheckAt = now + END_REQUEST_SECONDS;
				// This host's own file first: the shared one holds only the last request written, maybe another host's.
				var own = suit.TerminalHostFolder.ownEndRequest(directory, Sys.getPid(), instance);
				var shared = suit.TerminalHostFolder.endRequest(directory);
				var sharedForThis = shared != null && suit.TerminalHostFolder.addressedTo(shared, Sys.getPid(), instance);
				var asked = own != null ? own : sharedForThis ? shared : null;
				if (asked == null && shared != null) {
					// Another host's (an earlier one of this terminal): left for it, unless it names a process that is gone.
					var addressee = shared.pid;
					if (addressee != null && !app.AgentManagerNative.processAlive(addressee)) {
						suit.TerminalHostFolder.clearEndRequest(directory);
						suit.TerminalHostFolder.clearOwnEndRequest(directory, addressee);
					}
				} else if (asked != null) {
					suit.TerminalHostFolder.clearOwnEndRequest(directory, Sys.getPid());
					if (sharedForThis) suit.TerminalHostFolder.clearEndRequest(directory);
					log(logPath, "asked to end by a request in the host's folder: " + asked.reason);
					if (!exited) try pty.terminate(true) catch (_:Dynamic) {}
					// An attached service hears that the terminal ended, not that it lost its host. (If the program had ended
					// before, the service was sent its exit code then.) A host asked to end leaves no final file.
					if (owner != null && !exited) outgoing.push(TerminalHostProtocol.number(TerminalHostProtocol.EXITED, -1));
					ending = true;
				}
			}
			if (now >= workspaceCheckAt) {
				workspaceCheckAt = now + checkEvery;
				// Read again each time: the folder says which workspace the terminal belongs to.
				var workspaceId = suit.TerminalHostFolder.read(directory).workspace;
				if (workspaceId == null) workspaceId = identity.workspace;
				var gone = owner != null ? null : workspaceGone(directory, stateDirectory, workspaceId, catalogFile);
				goneChecks = gone == null ? 0 : goneChecks + 1;
				if (gone != null && goneChecks >= 2) {
					log(logPath, "the host ends its program and itself: " + gone);
					if (!exited) try pty.terminate(true) catch (_:Dynamic) {}
					ending = true;
				} else if (owner == null && !exited && abandonedAt == 0 && workspaceId != null && catalogFile != null
					&& absence.check(workspaceId, catalogFile, now) >= ABSENT_SECONDS) {
					// Missing for hours from lists that could be trusted: no service will come back. The program is ended and its
					// last screen and exit code are kept in final.bin (below), as for a program that ended by itself.
					log(logPath, "workspace " + workspaceId + " has been missing from this machine's workspaces for "
						+ Math.round(ABSENT_SECONDS / 3600) + " hours: the host ends its program and keeps its last screen");
					try pty.terminate(true) catch (_:Dynamic) {}
					abandonedAt = now;
				} else if (owner != null) absence.reset(); // A service came: the workspace is in use.
			}
			if (abandonedAt > 0 && !exited && now - abandonedAt >= ABANDON_EXIT_SECONDS) {
				// The program did not report its end: the last screen is kept anyway.
				exited = true;
				exitCode = -1;
				exitedAt = now;
				log(logPath, "the program did not end when asked; the host leaves its last screen and ends");
			}
			// Time this process did not run (the machine slept, the process was suspended) is not the service stalling.
			if (now - lastLoop > 2 && stalledSince != 0) stalledSince += now - lastLoop;
			lastLoop = now;
			for (entry in waiting.copy()) {
				var first = entry.transport.receive();
				if (first == null) {
					if (!entry.transport.isOpen() || now >= entry.until) {
						entry.transport.close();
						waiting.remove(entry);
					}
					continue;
				}
				waiting.remove(entry);
				if (first.length == spec.token.length + 1 && first.get(0) == TerminalHostProtocol.ATTACH
					&& first.sub(1, first.length - 1).toString() == spec.token)
					attach(entry.transport);
				else {
					log(logPath, "a connection without the token was refused");
					entry.transport.close();
				}
			}
			var service = owner;
			if (service != null) {
				for (_ in 0...64) {
					var message = service.receive();
					if (message == null) break;
					handle(message);
				}
				if (!service.isOpen()) {
					var reason = service.failureReason();
					log(logPath, "service detached" + (reason == null ? "" : " (" + reason + ")") + (exited ? "" : "; the program keeps running"));
					owner = null;
					service = null;
					outgoing.resize(0);
					// A service that heard of the exit says END before it leaves. One that left without may not have got the
					// exit code (queued is not delivered): the last screen is then kept in a file, below.
				}
			}
			// Output is read only when the attached service took what was queued, so a slow service slows the program down
			// instead of growing this queue; a stalled one is dropped.
			if (!exited && outgoing.length == 0) {
				try pty.pollEvents(function(event) {
					if (event.kind == "output") {
						lastActive = Sys.time();
						emulator.feedRange(event.data, 0, event.length);
						var replies = emulator.takeReplies();
						// The attached service's emulator answers the program's queries; with none attached the host does.
						if (owner == null && replies.length > 0) try pty.write(replies) catch (_:Dynamic) {}
						if (owner != null && event.length > 0)
							outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.OUTPUT, event.data, 0, event.length));
					} else if (event.kind == "status") {
						exited = true;
						exitCode = event.exitCode;
						exitedAt = Sys.time();
						log(logPath, 'the program ended: ${event.state}, exit code ${event.exitCode}');
						if (owner != null) outgoing.push(TerminalHostProtocol.number(TerminalHostProtocol.EXITED, exitCode));
					}
				}) catch (failure:Dynamic) {
					exited = true;
					exitCode = -1;
					exitedAt = Sys.time();
					log(logPath, "reading the program's output failed: " + Std.string(failure));
					if (owner != null) outgoing.push(TerminalHostProtocol.number(TerminalHostProtocol.EXITED, exitCode));
				}
			}
			if (service != null && flowControlled && !creditSeen && now >= creditDueBy) liftWindow();
			if (service != null && outgoing.length > 0) {
				var sent = false;
				// Counted from the attach also before the service's first CREDIT, which follows its ATTACH.
				while (outgoing.length > 0 && (!flowControlled || unacknowledged == 0
					|| unacknowledged + TerminalHostProtocol.cost(outgoing[0]) <= TerminalHostProtocol.WINDOW)
					&& service.send(outgoing[0])) {
					unacknowledged += TerminalHostProtocol.cost(outgoing.shift());
					sent = true;
				}
				if (sent || outgoing.length == 0) stalledSince = 0;
				else if (stalledSince == 0) stalledSince = now;
				else if (now - stalledSince >= STALLED_SECONDS) {
					log(logPath, "the attached service stopped reading; dropped it");
					service.close();
					owner = null;
					outgoing.resize(0);
					stalledSince = 0;
				}
			}
			// The program ended and no service is attached to hear of it: its last screen, history and exit code go to a file
			// the next service reads (TerminalHosts.adopt), and the host is done. It waits on only if the file cannot be written.
			if (exited && owner == null && !ending && !finalTried && waiting.length == 0 && (everAttached || now - startedAt >= 30)) {
				finalTried = true;
				if (!ownsFolder()) {
					// Restart Terminal gave the folder to a newer host: no service would take this program's screen for that one's.
					log(logPath, "the program ended and the host's folder belongs to a newer host now; no last screen is left");
					ending = true;
				} else try {
					var last:Array<Bytes> = [];
					current(last);
					AtomicFile.writeBytes(finalPath, TerminalHostProtocol.encodeFinal(last));
					log(logPath, "no service is attached: the last screen and the exit code were written to " + TerminalHostProtocol.FINAL_FILE);
					ending = true;
				} catch (failure:Dynamic) log(logPath, "the last screen could not be written (" + Std.string(failure) + "); waiting for a service");
			}
			if (exited && owner == null && !ending && now - exitedAt >= LINGER_SECONDS) {
				log(logPath, "no service collected the ended program; the host ends");
				ending = true;
			}
		}
		// Let a last EXITED reach the service before the pipe closes.
		var last = owner;
		if (last != null) {
			var until = Sys.time() + 0.5;
			while (Sys.time() < until && last.isOpen()) {
				runtime.events.wait(0.01);
				for (_ in 0...32)
					if (!runtime.events.poll())
						break;
				while (outgoing.length > 0 && last.send(outgoing[0])) outgoing.shift();
			}
			last.close();
		}
		// Only its own record: after Restart Terminal the next host for this terminal runs in the same folder and has
		// written its `host.json` by now.
		if (ownsFolder()) try FileSystem.deleteFile(hostPath) catch (_:Dynamic) {}
		suit.SuitClient.unregister();
		try FileSystem.deleteFile(lease) catch (_:Dynamic) {}
		pty.close();
		emulator.close();
		hub.forget(listener);
		hub.dispose();
		runtime.dispose();
		log(logPath, "host ended");
		return 0;
	}
}

/**
	How long a host's workspace has been missing from suit's list of this machine's workspaces (`machine.json`), counting
	only lists that can be trusted to say so. A list that is missing, unreadable or empty, one of another machine id than
	the last one that listed the workspace, or one with fewer workspaces than that one (a reset, a bad rewrite, a restored
	copy) says nothing, and the count starts again.
**/
class WorkspaceAbsence {
	var machine:Null<String> = null;
	var listedAmong = 0;
	var absentSince = 0.0;

	public function new() {}

	public function reset():Void
		absentSince = 0;

	/** Seconds the workspace has been missing from trusted lists up to `now`; 0 while it is listed or nothing can be told. */
	public function check(workspace:String, catalogFile:String, now:Float):Float {
		var state:Null<suit.MachineCatalog.MachineState> = null;
		try {
			if (FileSystem.exists(catalogFile)) state = suit.MachineCatalog.decode(File.getContent(catalogFile));
		} catch (_:Dynamic) {}
		if (state == null || state.workspaces.length == 0) {
			absentSince = 0;
			return 0;
		}
		for (entry in state.workspaces)
			if (entry.id == workspace) {
				machine = state.id;
				listedAmong = state.workspaces.length;
				absentSince = 0;
				return 0;
			}
		if ((machine != null && state.id != machine) || state.workspaces.length < listedAmong) {
			absentSince = 0;
			return 0;
		}
		if (absentSince == 0) absentSince = now;
		return now - absentSince;
	}
}
