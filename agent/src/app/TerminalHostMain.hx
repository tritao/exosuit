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
	that started it (`terminal-host.hl --terminal-host DIRECTORY`, the program agent/terminal-host builds; see docs/design/terminal-host-status.md).

	It runs from a private copy of the runtime, never from a build tree, starts the program named in `spec.bin`, keeps
	an emulator fed with the program's output (the terminal's only screen: it answers the program's queries), and
	listens on a private pipe. A service attaches with the host's token and gets the screen as it is now, then the output
	as it comes, and the screen again whenever it asks; when the service goes away the host keeps the program running
	and waits for the next one. It keeps the last screen in `screen.bin` (TerminalHostProtocol.SCREEN_FILE), so it can be
	shown when the host is gone. It ends when a service tells it to end over its pipe (END), or when the program has
	ended and no service is attached to hear of it.

	It registers with exohost as a terminal host, so the tray and `exohost terminals` list it under its workspace; exohost ends
	it by killing it.
**/
class TerminalHostMain {
	/** How long a host whose program ended, and which could not write its screen file, waits for a service to collect the last screen and exit code. */
	static inline final LINGER_SECONDS = 86400.0;
	/** A service that takes no output for this long is dropped, so the program is not blocked by it. */
	static inline final STALLED_SECONDS = 60.0;
	/**
		How often a host with no service attached checks that its workspace still exists; two checks in a row must say no.
		`EXOSUIT_TERMINAL_HOST_CHECK_SECONDS` (1 to 30) makes it more often, for tests.
	**/
	static inline final WORKSPACE_CHECK_SECONDS = 30.0;
	/**
		How long a workspace may be missing from exohost's list of this machine's workspaces before its unattached host ends
		the program (its last screen is kept). Only an explicit removal ends a host sooner.
	**/
	static inline final ABSENT_SECONDS = 6 * 3600.0;
	/** How long the program of a host that ends for a long absence has to exit before the host stops waiting for it. */
	static inline final ABANDON_EXIT_SECONDS = 10.0;

	/**
		Why the workspace this host belongs to is gone for certain, or null. Gone means: the host's folder or the
		workspace's state folder was removed, or exohost removed the workspace (`MachineCatalog.removed`: the workspace was
		removed while its service was stopped, so no service will come back for the terminal). A list of workspaces that
		lacks this one is not enough: a catalog that was reset, rewritten badly or emptied says the same
		(`WorkspaceAbsence`).
	**/
	public static function workspaceGone(directory:String, stateDirectory:String, workspace:Null<String>, catalogFile:Null<String>):Null<String> {
		if (!FileSystem.exists(directory)) return "the host's folder was removed";
		if (!FileSystem.exists(stateDirectory)) return "the workspace's state folder was removed";
		if (workspace == null || catalogFile == null) return null;
		try {
			if (exohost.MachineCatalog.removed(catalogFile, workspace)) return "workspace " + workspace + " was removed from this machine";
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
		var emulator = Emulator.open(columns, rows, TerminalHostProtocol.SCROLLBACK_ROWS, "xterm-256color", false);
		// A restarted terminal's past, before the new program draws anything.
		if (spec.prelude.length > 0) {
			emulator.feed(spec.prelude);
			emulator.takeReplies();
		}
		var pty = LocalPtyBackend.spawnProgram(spec.program, spec.arguments, spec.cwd.length == 0 ? null : spec.cwd, spec.environment, columns, rows);
		/** Connections that have not sent the token yet. */
		var waiting:Array<{transport:NativeRpcTransport, until:Float}> = [];
		var owner:Null<NativeRpcTransport> = null;
		var outgoing:Array<Bytes> = [];
		/**
			What was sent to the attached service and not yet acknowledged with CREDIT (TerminalHostProtocol): at most WINDOW,
			counted from its ATTACH, since its pipe ends when more than it holds waits unread.
		**/
		var unacknowledged = 0;
		var stalledSince = 0.0;
		var exited = false, exitCode = 0, exitedAt = 0.0, screenSaved = false, ending = false;
		var screenPath = Path.join([directory, TerminalHostProtocol.SCREEN_FILE]);
		/** Output since the screen file was last written, and when it may be written again. */
		var screenDirty = false, screenSaveAt = 0.0;
		// The service that starts a host attaches within moments. A program that ends before that (it could not start, or
		// exits at once) is reported to that service over the pipe, so the host waits for it a little before it ends.
		var everAttached = false, startedAt = Sys.time();
		// A Windows pipe listener stops when a service connected and left before it was accepted (the host was suspended,
		// say: NativeKit takes ERROR_NO_DATA for a failure). The host listens again, or no service could reach it.
		var listenAgainAt = 0.0, listening = true;
		function listen()
			return hub.listen(NativeRpcHub.local(spec.pipe), function(transport) {
				waiting.push({transport: transport, until: Sys.time() + 10});
			}, function() {
				if (listenAgainAt == 0) listenAgainAt = Sys.time();
			});
		var listener = listen();
		var hostPath = Path.join([directory, "host.json"]);
		var instance = TerminalHostProtocol.instanceOf(spec.token);
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
		// A last screen left here is an earlier host's of this terminal (Restart Terminal): it is in the prelude now.
		try FileSystem.deleteFile(screenPath) catch (_:Dynamic) {}
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
		// The service wrote which terminal of which workspace this is; exohost shows the host by it. Never fatal.
		var identity = exohost.TerminalHostFolder.read(directory);
		var stateDirectory = Path.directory(Path.directory(directory));
		try exohost.ExohostClient.registerTerminalHost({root: identity.root == null ? stateDirectory : identity.root, stateDir: stateDirectory,
			generation: null, workspace: identity.workspace}) catch (_:Dynamic) {}
		// While this file names a running process, no service removes the runtime copy this host runs from.
		var lease = workspace.runtime.TerminalHosts.TerminalHostRuntime.leasePath(Path.directory(FileSystem.fullPath(Sys.programPath())), Sys.getPid());
		try File.saveContent(lease, Sys.executablePath() + "\n") catch (_:Dynamic) {}
		var checkEvery = checkSeconds();
		var workspaceCheckAt = Sys.time() + checkEvery, goneChecks = 0;
		// exohost's list of workspaces: a test's isolated exohost home has its own.
		var catalogFile = exohost.MachineCatalog.file();
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

		/**
			Writes the last screen to its file, while the folder is this host's (after Restart Terminal a newer host's
			`host.json` is there, and the screen in the folder is that one's). Returns false when it could not be written.
		**/
		function saveScreen():Bool {
			screenDirty = false;
			if (!ownsFolder()) return true;
			try {
				var last:Array<Bytes> = [];
				current(last);
				var encoded = TerminalHostProtocol.encodeScreen(last);
				AtomicFile.writeBytes(screenPath, encoded);
				screenSaveAt = Sys.time() + Math.max(TerminalHostProtocol.SCREEN_SAVE_SECONDS, encoded.length / 1048576.0);
				// The export is native memory HashLink's collector does not count (docs/haxeon-compiler-bugs.md): without a
				// collection a host that saves a long history every half minute grows until other allocation starts one.
				#if hl
				if (encoded.length >= 4194304) hl.Gc.major();
				#end
				return true;
			} catch (failure:Dynamic) {
				log(logPath, "the last screen could not be written: " + Std.string(failure));
				screenSaveAt = Sys.time() + TerminalHostProtocol.SCREEN_SAVE_SECONDS;
				return false;
			}
		}

		function theme(foreground:Int, background:Int):Void {
			if (foreground < 0 || foreground > 0xffffff || background < 0 || background > 0xffffff) return;
			emulator.setDefaultColors(foreground, background);
			// A subscribed program is told of the change at once.
			var replies = emulator.takeReplies();
			if (!exited && replies.length > 0) try pty.write(replies) catch (_:Dynamic) {}
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
			stalledSince = 0;
			current(outgoing);
			log(logPath, "service attached: pid " + transport.peerProcess());
		}

		function handle(message:Bytes):Void {
			if (message.length == 0) return;
			var kind = message.get(0);
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
						screenDirty = true;
					} catch (failure:Dynamic) log(logPath, "resize failed: " + Std.string(failure));
				}
			} else if (kind == TerminalHostProtocol.THEME) {
				theme(TerminalHostProtocol.numberOf(message), TerminalHostProtocol.secondNumberOf(message));
			} else if (kind == TerminalHostProtocol.SNAPSHOT) {
				// In order with the output: everything sent before it is in the screen, everything after follows it.
				current(outgoing);
			} else if (kind == TerminalHostProtocol.KILL) {
				log(logPath, "the service asked to end the program");
				if (!exited) try pty.terminate(true) catch (_:Dynamic) {}
			} else if (kind == TerminalHostProtocol.END) {
				log(logPath, "the service asked the host to end");
				ending = true;
			} else if (kind == TerminalHostProtocol.CREDIT) {
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
			if (listenAgainAt > 0 && now >= listenAgainAt) {
				if (listening) hub.forget(listener);
				listening = false;
				try {
					listener = listen();
					listening = true;
					listenAgainAt = 0;
					log(logPath, "the pipe stopped accepting connections; it listens again");
				} catch (failure:Dynamic) {
					listenAgainAt = now + 1;
					log(logPath, "the pipe could not listen again (" + Std.string(failure) + "); trying again in a second");
				}
			}
			if (now >= workspaceCheckAt) {
				workspaceCheckAt = now + checkEvery;
				// Read again each time: the folder says which workspace the terminal belongs to.
				var workspaceId = exohost.TerminalHostFolder.read(directory).workspace;
				if (workspaceId == null) workspaceId = identity.workspace;
				var gone = owner != null ? null : workspaceGone(directory, stateDirectory, workspaceId, catalogFile);
				goneChecks = gone == null ? 0 : goneChecks + 1;
				if (gone != null && goneChecks >= 2) {
					log(logPath, "the host ends its program and itself: " + gone);
					if (!exited) try pty.terminate(true) catch (_:Dynamic) {}
					ending = true;
				} else if (owner == null && !exited && abandonedAt == 0 && workspaceId != null
					&& absence.check(workspaceId, catalogFile, now) >= ABSENT_SECONDS) {
					// Missing for hours from lists that could be trusted: no service will come back. The program is ended and its
					// last screen and exit code are kept (below), as for a program that ended by itself.
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
					// exit code (queued is not delivered): the host then ends once the last screen is kept, below.
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
						if (replies.length > 0) try pty.write(replies) catch (_:Dynamic) {}
						if (event.length > 0) screenDirty = true;
						if (owner != null && event.length > 0)
							outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.OUTPUT, event.data, 0, event.length));
					} else if (event.kind == "status") {
						exited = true;
						exitCode = event.exitCode;
						exitedAt = Sys.time();
						log(logPath, 'the program ended: ${event.state}, exit code ${event.exitCode}');
					}
				}) catch (failure:Dynamic) {
					exited = true;
					exitCode = -1;
					exitedAt = Sys.time();
					log(logPath, "reading the program's output failed: " + Std.string(failure));
				}
				if (exited) {
					// Kept before the service hears of the end: it shows an ended terminal from this file.
					screenSaved = saveScreen();
					if (owner != null) outgoing.push(TerminalHostProtocol.number(TerminalHostProtocol.EXITED, exitCode));
				}
			}
			if (!exited && screenDirty && now >= screenSaveAt) saveScreen();
			if (service != null && outgoing.length > 0) {
				var sent = false;
				while (outgoing.length > 0 && (unacknowledged == 0
					|| unacknowledged + TerminalHostProtocol.cost(outgoing[0]) <= TerminalHostProtocol.WINDOW)
					&& service.send(outgoing[0])) {
					unacknowledged += TerminalHostProtocol.cost(outgoing.shift() ?? throw "No outgoing message");
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
			// The program ended and no service is attached to hear of it: the next service reads its last screen and exit code
			// from the file (TerminalHosts.adopt), and the host is done. It waits on only while the file cannot be written.
			if (exited && owner == null && !ending && waiting.length == 0 && (everAttached || now - startedAt >= 30)) {
				if (!screenSaved && now >= screenSaveAt) screenSaved = saveScreen();
				if (screenSaved) {
					log(logPath, "the program ended with no service attached: its last screen and exit code are in " + TerminalHostProtocol.SCREEN_FILE);
					ending = true;
				}
			}
			if (exited && owner == null && !ending && now - exitedAt >= LINGER_SECONDS) {
				log(logPath, "no service collected the ended program; the host ends");
				ending = true;
			}
		}
		// The listening socket goes first, before `host.json` below: on macOS and Linux its path is the same for every host of
		// this terminal (TerminalHosts.socketPath), and closing it removes that path. A Restart starts the next host once
		// `host.json` is gone (TerminalHosts.endExited), so a socket removed after that would be the new host's.
		if (listening) hub.forget(listener);
		listening = false;
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
		exohost.ExohostClient.unregister();
		try FileSystem.deleteFile(lease) catch (_:Dynamic) {}
		pty.close();
		emulator.close();
		hub.dispose();
		runtime.dispose();
		log(logPath, "host ended");
		return 0;
	}
}

/**
	How long a host's workspace has been missing from exohost's list of this machine's workspaces (`machine.json`), counting
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
		var state:Null<exohost.MachineCatalog.MachineState> = null;
		try {
			if (FileSystem.exists(catalogFile)) state = exohost.MachineCatalog.decode(File.getContent(catalogFile));
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
