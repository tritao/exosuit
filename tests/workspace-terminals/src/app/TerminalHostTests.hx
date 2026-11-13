package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.Runtime;
import terminalkit.Emulator;
import terminalsession.TerminalSession;
import workspace.client.LocalWorkspaceClient;
import workspace.client.RpcTerminalBackend;
import workspace.runtime.TerminalHostProtocol;
import workspace.transport.NativeRpcHub;

/**
	Small client steps for scripts/test-terminal-hosts.py, which starts and stops the services between them:

	- `host-type ROOT LAUNCHER ID create|attach COMMAND [TEXT]`: opens terminal ID, types COMMAND, waits until TEXT is on
	  its screen (or half a second).
	- `host-dump ROOT LAUNCHER ID FILE [TEXT]`: attaches to terminal ID, waits until TEXT is on its screen or in its
	  scrollback (or until it is synchronized), and writes what the view holds to FILE as JSON: state, exit code, size,
	  scrollback length, modes, and every line from the top of the scrollback to the bottom of the screen.
	- `host-restart ROOT LAUNCHER ID COMMAND TEXT`: attaches to terminal ID, waits until the service gives its host up
	  (the view offers Restart Terminal), restarts it, types COMMAND and waits until TEXT is on its screen.
	- `host-steal ROOT LAUNCHER DIRECTORY`: connects to the terminal host in DIRECTORY with its token, as a second
	  service would, and leaves again: the service that was attached loses its connection.
**/
class TerminalHostTests {
	public static function handles(mode:String):Bool
		return mode == "host-type" || mode == "host-dump" || mode == "host-steal" || mode == "host-restart";

	static function lines(emulator:Emulator):{total:Int, lines:Array<String>} {
		var total = emulator.scrollback(-1).total, rows = emulator.rows();
		var collected:Array<String> = [];
		var position = total;
		while (true) {
			emulator.scrollback(position);
			emulator.snapshot();
			// The last window above the screen overlaps it by the rows it lacks; those repeat, in order.
			for (row in 0...rows) collected.push(emulator.rowText(row));
			if (position == 0) break;
			position = position > rows ? position - rows : 0;
		}
		return {total: total, lines: collected};
	}

	static function shows(emulator:Emulator, text:String, deep:Bool):Bool {
		if (deep) {
			for (line in lines(emulator).lines) if (line.indexOf(text) >= 0) return true;
			return false;
		}
		emulator.snapshot();
		for (row in 0...emulator.rows()) if (emulator.rowText(row).indexOf(text) >= 0) return true;
		return false;
	}

	public static function steal(runtime:Runtime, directory:String):Void {
		var record:Dynamic = Json.parse(sys.io.File.getContent(directory + "/host.json"));
		var pipe:String = record.pipe, token:String = record.token;
		var hub = new NativeRpcHub(runtime.events);
		var state = 0, sent = false, until = Sys.time() + 10, closeAt = 0.0;
		var link:Null<haxeon.rpc.MessageTransport> = null;
		hub.connect(NativeRpcHub.local(pipe), function(result) {
			switch result {
				case Opened(opened):
					link = opened;
					state = 1;
				case Failed(_, _):
					state = -1;
			}
		});
		while (true) {
			runtime.events.wait(0.01);
			for (_ in 0...64) if (!runtime.events.poll()) break;
			if (state < 0) throw "The terminal host's pipe did not open";
			if (Sys.time() > until) throw "Taking the terminal host over timed out";
			var opened = link;
			if (opened == null) continue;
			if (!sent) {
				sent = opened.send(TerminalHostProtocol.message(TerminalHostProtocol.ATTACH, Bytes.ofString(token)));
				if (sent) closeAt = Sys.time() + 0.5;
			} else {
				// Take what the host sends, as a service would, then leave.
				while (opened.receive() != null) {}
				if (Sys.time() >= closeAt || !opened.isOpen()) break;
			}
		}
		if (link != null) link.close();
		hub.dispose();
		Sys.println("PASS: took the terminal host in " + directory + " over and left");
	}

	public static function run(mode:String, args:Array<String>, runtime:Runtime, client:LocalWorkspaceClient, clock:Void->Float):Void {
		var root = args[1], id = args[3];
		var create = mode == "host-type" && args[4] == "create";
		var backend = new RpcTerminalBackend(function() return client, id, root, create);
		var session = new TerminalSession(backend, Emulator.open(100, 30, 10000, "xterm-256color", false), false);
		// The memory measurement makes its terminals this wide (scripts/test-terminal-hosts.py).
		var wide = Sys.getEnv("EXOSUIT_TEST_TERMINAL_COLUMNS");
		if (wide != null && Std.parseInt(wide) != null) session.resize(Std.parseInt(wide), 30);
		var attachStarted = Sys.time();
		var step = function() {
			runtime.events.wait(0.005);
			for (_ in 0...128) if (!runtime.events.poll()) break;
			client.poll();
			if (client.error != null) throw "Workspace failed: " + client.error;
			session.pollEvents();
		};
		var deadline = clock() + 30000;
		while (!backend.isAttached() || !backend.isSynchronized()) {
			if (clock() >= deadline) throw "Terminal " + id + " did not attach: " + backend.controlStatus();
			step();
		}
		Sys.println("ATTACHED " + id + " in " + Math.round((Sys.time() - attachStarted) * 1000) + " ms with "
			+ session.emulator.scrollback(-1).total + " lines above the screen");
		if (mode == "host-restart") {
			// The terminal's host does not answer: wait until the service gives it up, then restart it and type into the new one.
			deadline = clock() + 90000;
			while (backend.controlAction() != "Restart Terminal") {
				if (clock() >= deadline) throw "Terminal " + id + " was not given up: " + session.status + ", " + backend.controlStatus();
				step();
			}
			backend.activateControl();
			while (!backend.canControl() || session.status != "running") {
				if (clock() >= deadline) throw "Terminal " + id + " did not restart: " + session.status + ", " + backend.controlStatus();
				step();
			}
			session.write(TestShell.line(args[4]));
			while (!shows(session.emulator, args[5], false)) {
				if (clock() >= deadline) throw "The restarted terminal " + id + " did not show " + args[5];
				step();
			}
			var settle = clock() + 300;
			while (clock() < settle) step();
			Sys.println("PASS: restarted terminal " + id + " (" + session.status + ")");
		} else if (mode == "host-type") {
			while (!backend.canControl()) {
				if (clock() >= deadline) throw "Terminal " + id + " gave no control: " + backend.controlStatus();
				step();
			}
			session.write(TestShell.line(args[5]));
			var expected = args.length > 6 ? args[6] : null;
			var settle = clock() + 500;
			while (expected == null ? clock() < settle : !shows(session.emulator, expected, false)) {
				if (clock() >= deadline) throw "Terminal " + id + " did not show " + expected;
				step();
			}
			// Let the input's acknowledgement arrive before the client goes away.
			settle = clock() + 300;
			while (clock() < settle) step();
			Sys.println("PASS: typed into terminal " + id);
		} else {
			var expected = args.length > 5 ? args[5] : null;
			var found = expected == null;
			var settle = clock() + 500;
			while (expected == null ? clock() < settle : !(found = shows(session.emulator, expected, true))) {
				if (clock() >= deadline) break;
				step();
			}
			var all = lines(session.emulator);
			session.emulator.scrollback(0);
			sys.io.File.saveContent(args[4], Json.stringify({
				found: found,
				state: session.status,
				exitCode: session.exitCode,
				status: backend.controlStatus(),
				columns: session.emulator.columns(),
				rows: session.emulator.rows(),
				scrollback: all.total,
				alternate: session.emulator.alternateScreen(),
				mouse: session.emulator.mouseMode(),
				modes: session.emulator.inputModes(),
				lines: all.lines
			}));
			Sys.println("PASS: wrote the view of terminal " + id + " (" + all.total + " lines above the screen)");
		}
		session.close();
	}
}
