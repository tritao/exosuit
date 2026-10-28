package suit;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.NativeKitRuntime;
import haxeon.platform.NativeKitEventValue;
import nativekit.ffi.NativeKitTypes;
import sys.FileSystem;
import suit.SuitInventory.SuitProcess;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	The per-user daemon: one per user (an exclusive lock in suit's home), a control endpoint for the CLI,
	and on Windows the tray icon.

	Idle cost: it sleeps in the NativeKit event wait, which a tray click or a control connection wakes,
	and rescans processes every REFRESH_SECONDS to keep the tooltip current. It exits after
	`EXOSUIT_SUIT_IDLE_SECONDS` (default 120) with nothing to track: no editor and no background process.
**/
class SuitDaemon {
	static inline var REFRESH_SECONDS:Float = 10;
	static inline var MENU_GROUP_LIMIT:Int = 30;

	final runtime:NativeKitRuntime;
	final hub:NativeRpcHub;
	final clients:Array<NativeRpcTransport> = [];
	final jobs:Array<SuitTerminator> = [];
	var tray:Null<SuitTray> = null;
	var inventory:SuitInventory;
	var refreshedAt:Float = 0;
	var idleSince:Float;
	var stopAfterJobs:Bool = false;
	var stopNow:Bool = false;
	var menuRequested:Bool = false;
	final idleSeconds:Float;

	public static function run():Int {
		var home = SuitPaths.home();
		if (!SuitPaths.prepare()) {
			Sys.stderr().writeString("suit: " + home + " is not a private directory of this user
");
			return 1;
		}
		var lock = SuitNative.acquireLock(Path.join([home, "suit.lock"]));
		if (lock == null)
			return 0; // Another suit owns this home; starting one is always safe to repeat.
		var code = 0;
		try {
			var daemon = new SuitDaemon();
			daemon.loop();
			daemon.dispose();
		} catch (error:Dynamic) {
			code = 1;
			try sys.io.File.saveContent(Path.join([home, "daemon-error.txt"]), Std.string(error) + "\n") catch (_:Dynamic) {}
		}
		try FileSystem.deleteFile(Path.join([home, "daemon.json"])) catch (_:Dynamic) {}
		SuitNative.releaseLock(lock);
		return code;
	}

	function new() {
		var configured = Std.parseFloat(Sys.getEnv("EXOSUIT_SUIT_IDLE_SECONDS"));
		idleSeconds = Math.isNaN(configured) || configured < 1 ? 120 : configured;
		idleSince = Sys.time();
		runtime = NativeKitRuntime.start();
		hub = new NativeRpcHub(runtime.events);
		hub.listen(NativeRpcHub.local(SuitPaths.endpoint()), function(transport) clients.push(transport));
		runtime.events.listen(onEvent);
		inventory = new SuitInventory();
		refreshedAt = Sys.time();
		sys.io.AtomicFile.write(Path.join([SuitPaths.home(), "daemon.json"]),
			Json.stringify({version: 1, pid: Sys.getPid(), endpoint: SuitPaths.endpoint()}) + "\n");
		if (Sys.systemName() == "Windows" && Sys.getEnv("EXOSUIT_SUIT_TRAY") != "0") {
			try tray = new SuitTray(inventory.summary(), findIcon()) catch (_:Dynamic) tray = null;
		}
	}

	function loop():Void {
		while (!stopNow) {
			runtime.events.wait(jobs.length > 0 || clients.length > 0 ? 0.1 : 1.0);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			if (menuRequested) {
				menuRequested = false;
				refresh();
				showMenu();
			}
			serveClients();
			var index = jobs.length;
			while (index-- > 0)
				if (jobs[index].tick()) {
					jobs.splice(index, 1);
					refreshedAt = 0;
				}
			if (Sys.time() - refreshedAt >= REFRESH_SECONDS)
				refresh();
			if (stopAfterJobs && jobs.length == 0)
				break;
			if (inventory.processes.length > 0 || clients.length > 0 || jobs.length > 0)
				idleSince = Sys.time();
			else if (Sys.time() - idleSince >= idleSeconds)
				break;
		}
	}

	function refresh():Void {
		inventory = new SuitInventory();
		refreshedAt = Sys.time();
		if (tray != null)
			tray.setTooltip(inventory.summary());
	}

	function onEvent(value:NativeKitEventValue):Void {
		switch value {
			case Raw(kind, source, _, _, _, _, data):
				var current = tray;
				if (current == null)
					return;
				if ((kind == EventKind.TrayMenuRequested || kind == EventKind.TrayActivated) && current.owns(source.rawValue()))
					menuRequested = true; // Shown from the loop, not inside the event pump.
				else if (kind == EventKind.MenuItemActivated && data != null && data.length >= 8)
					current.activate(data.getInt32(0));
			default:
		}
	}

	function terminate(processes:Array<SuitProcess>):Void {
		if (processes.length > 0)
			jobs.push(new SuitTerminator(inventory, processes));
	}

	function showMenu():Void {
		var current = tray;
		if (current == null)
			return;
		current.show(function(menu) {
			menu.item(inventory.summary());
			var group:Null<String> = null, shown = 0;
			for (process in inventory.processes) {
				if (process.group != group) {
					group = process.group;
					shown = 0;
					menu.separator();
					menu.item(group);
				}
				if (shown++ >= MENU_GROUP_LIMIT) {
					if (shown == MENU_GROUP_LIMIT + 1)
						menu.item("    … more in the process viewer");
					continue;
				}
				var target = process;
				var entry = menu.submenu("    " + SuitReport.label(process));
				var relay = SuitReport.relayState(process);
				if (relay.length > 0)
					menu.item("Remote access: " + relay, null, entry);
				menu.item(process.kind == "editor" ? "Close" : "Terminate", function() terminate([target]), entry);
			}
			var hosted = inventory.hosted();
			if (hosted.length > 0) {
				menu.separator();
				var remote = menu.submenu("Remote access (" + hosted.length + ")");
				for (process in hosted) {
					var target = process;
					menu.item(SuitReport.workspace(process) + ": " + SuitReport.relayState(process), null, remote);
					menu.item("    Stop hosting " + SuitReport.workspace(process), function() terminate([target]), remote);
				}
				menu.separator(remote);
				menu.item("Stop all hosting", function() terminate(SuitActions.hosting(inventory)), remote);
				menu.item("Open Remote Access…", function() openViewer(["watch", "--relay"]), remote);
			}
			menu.separator();
			var orphans = inventory.orphans();
			menu.item("Terminate orphaned processes (" + orphans.length + ")", orphans.length == 0 ? null : function() terminate(SuitActions.orphans(inventory)));
			var background = inventory.background();
			menu.item("Terminate all background processes (" + background.length + ")",
				background.length == 0 ? null : function() terminate(SuitActions.background(inventory)));
			menu.item("Open process viewer…", function() openViewer(["watch"]));
			menu.separator();
			menu.item("Quit Exosuit", quitEverything);
		});
	}

	/** Stops everything, editors included (asked to close first), then exits. */
	function quitEverything():Void {
		terminate(SuitActions.everything(inventory));
		stopAfterJobs = true;
	}

	/** Opens a console running `suit watch`. */
	function openViewer(arguments:Array<String>):Void {
		var launcher = SuitClient.findLauncher();
		if (launcher == null)
			return;
		try {
			var command = Sys.systemName() == "Windows" ? "cmd.exe" : "x-terminal-emulator";
			var commandArguments = Sys.systemName() == "Windows"
				? ["/c", "start", "Exosuit processes", Sys.executablePath(), launcher].concat(arguments)
				: ["-e", Sys.executablePath(), launcher].concat(arguments);
			var child = sys.io.Process.spawn(command, commandArguments, Path.directory(launcher), [SuitClient.libraryVariable()],
				[SuitClient.nativePath(launcher)], true);
			child.close();
		} catch (_:Dynamic) {}
	}

	function serveClients():Void {
		var index = clients.length;
		while (index-- > 0) {
			var client = clients[index];
			if (!client.isOpen()) {
				clients.splice(index, 1);
				continue;
			}
			var message:Null<Bytes> = null;
			try message = client.receive() catch (_:Dynamic) {
				client.close();
				continue;
			}
			if (message == null)
				continue;
			var reply:Dynamic;
			try reply = handle(Json.parse(message.toString())) catch (error:Dynamic) reply = {ok: false, error: Std.string(error)};
			client.send(Bytes.ofString(Json.stringify(reply)));
		}
	}

	function handle(request:Dynamic):Dynamic {
		var op = SuitInventory.stringField(request, "op");
		switch op {
			case "status":
				refresh();
				return {
					ok: true, pid: Sys.getPid(), home: SuitPaths.home(), summary: inventory.summary(), tray: tray != null,
					editors: inventory.editors().length, background: inventory.background().length,
					orphaned: inventory.orphans().length, terminating: jobs.length
				};
			case "refresh":
				refresh();
				return {ok: true};
			case "quit":
				refresh();
				var count = SuitActions.everything(inventory).length;
				quitEverything();
				return {ok: true, terminating: count};
			case "stop":
				stopNow = true;
				return {ok: true};
			default:
				return {ok: false, error: "unknown request"};
		}
	}

	function findIcon():Null<String> {
		var launcher = SuitClient.findLauncher();
		var directory = launcher == null ? Sys.getCwd() : Path.directory(launcher);
		for (_ in 0...8) {
			for (candidate in [Path.join([directory, "exosuit.ico"]), Path.join([directory, "graphical", "assets", "exosuit.ico"])])
				if (FileSystem.exists(candidate))
					return FileSystem.fullPath(candidate);
			var parent = Path.directory(directory);
			if (parent == directory || parent.length == 0)
				break;
			directory = parent;
		}
		return null;
	}

	function dispose():Void {
		if (tray != null)
			tray.dispose();
		tray = null;
		for (client in clients)
			client.close();
		hub.dispose();
		runtime.dispose();
	}
}
