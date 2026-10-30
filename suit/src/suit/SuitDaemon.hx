package suit;

import suit.SuitRecord.SuitRecords;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.Runtime;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes;
import sys.FileSystem;
import suit.SuitInventory.SuitProcess;
import suit.relay.SuitRelayHosting;
import suit.relay.SuitRelayHosting.SuitRelayStopPlan;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

typedef SuitLockHandle = hl.Abstract<"realtime_file_lock">;

/** The single-instance lock: the exclusive file lock the workspace manager also uses. Null when another process holds it. */
@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function acquireLock(path:String):Null<SuitLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function releaseLock(lock:SuitLockHandle):Void;

/**
	The per-user daemon: one per user (an exclusive lock in suit's home), a control endpoint for the CLI,
	and on Windows the tray icon. It also holds the relay machine socket of every hosted workspace
	(`suit.relay.SuitRelayHosting`).

	The tray menu does not stop this loop: NativeKit runs the popup on its own thread (`SuitTray.show`).

	Idle cost: it sleeps in the NativeKit event wait, which a tray click or a control connection wakes,
	and rescans processes every REFRESH_SECONDS to keep the tooltip current. It exits after
	`EXOSUIT_SUIT_IDLE_SECONDS` (default 120) with nothing of exosuit's to track and no hosted workspace:
	processes it did not start (a terminal build's compiler worker) do not keep it running. Started at
	login (`daemon --login`) it stays resident.
**/
class SuitDaemon {
	static inline var REFRESH_SECONDS:Float = 10;

	final runtime:Runtime;
	final hub:NativeRpcHub;
	final clients:Array<NativeRpcTransport> = [];
	final jobs:Array<SuitTerminator> = [];
	var tray:Null<SuitTray> = null;
	var inventory:SuitInventory;
	var refreshedAt:Float = 0;
	var idleSince:Float;
	var stopAfterJobs:Bool = false;
	/** When set, the loop ends at this time; the delay lets the reply to a stop or quit request flush. */
	var stopAt:Float = -1;
	var menuRequested:Bool = false;
	final idleSeconds:Float;
	final relay:SuitRelayHosting;
	var shownRelay:String = "";
	var catalog:Null<MachineCatalog> = null;
	/** Started at login: stays up with nothing to track, so the tray icon stays. */
	final resident:Bool;

	public static function run(login:Bool = false):Int {
		var home = SuitPaths.home();
		if (!SuitPaths.prepare()) {
			Sys.stderr().writeString("suit: " + home + " is not a private directory of this user\n");
			return 1;
		}
		var lock = acquireLock(Path.join([home, "suit.lock"]));
		if (lock == null)
			return 0; // Another suit owns this home; starting one is always safe to repeat.
		var code = 0;
		try {
			var daemon = new SuitDaemon(login);
			daemon.loop();
			daemon.dispose();
		} catch (error:Dynamic) {
			code = 1;
			Sys.stderr().writeString("suit: " + Std.string(error) + "\n");
			try sys.io.File.saveContent(Path.join([home, "daemon-error.txt"]), Std.string(error) + "\n") catch (_:Dynamic) {}
		}
		try FileSystem.deleteFile(Path.join([home, "daemon.json"])) catch (_:Dynamic) {}
		releaseLock(lock);
		return code;
	}

	function new(login:Bool) {
		resident = login;
		var configured = Std.parseFloat(Sys.getEnv("EXOSUIT_SUIT_IDLE_SECONDS"));
		idleSeconds = Math.isNaN(configured) || configured < 1 ? 120 : configured;
		idleSince = Sys.time();
		runtime = Runtime.start();
		hub = new NativeRpcHub(runtime.events);
		var listenError = listen();
		if (listenError != null) {
			// The first pipe instance is exclusive: another process holding the name is never shared with.
			hub.dispose();
			runtime.dispose();
			throw "suit's control endpoint " + SuitPaths.endpoint() + " is held by another process; suit will not share it (" + listenError + ")";
		}
		relay = new SuitRelayHosting(runtime.events, hub);
		runtime.events.listen(onEvent);
		inventory = new SuitInventory(true);
		refreshedAt = Sys.time();
		sys.io.AtomicFile.write(Path.join([SuitPaths.home(), "daemon.json"]),
			Json.stringify({version: 1, pid: Sys.getPid(), endpoint: SuitPaths.endpoint()}) + "\n");
		SuitLogin.refresh();
		if (Sys.systemName() == "Windows" && Sys.getEnv("EXOSUIT_SUIT_TRAY") != "0") {
			try tray = new SuitTray(inventory.summary(), findIcon()) catch (_:Dynamic) tray = null;
		}
	}

	function listen():Null<String> {
		try {
			hub.listen(NativeRpcHub.local(SuitPaths.endpoint()), function(transport) clients.push(transport));
		} catch (error:Dynamic) {
			return Std.string(error);
		}
		return null;
	}

	function loop():Void {
		while (stopAt < 0 || Sys.time() < stopAt) {
			runtime.events.wait(jobs.length > 0 || clients.length > 0 || relay.busy() ? 0.1 : 1.0);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			if (menuRequested) {
				menuRequested = false;
				SuitLogin.refresh();
				refresh();
				showMenu();
			}
			serveClients();
			relay.poll();
			SuitLogin.poll();
			var relayRevision = relay.revision();
			if (relayRevision != shownRelay) {
				// A remote client came or went: update the tooltip now, not on the next rescan.
				shownRelay = relayRevision;
				updateTooltip();
			}
			var index = jobs.length;
			while (index-- > 0)
				if (jobs[index].tick()) {
					jobs.splice(index, 1);
					refreshedAt = 0;
				}
			if (Sys.time() - refreshedAt >= REFRESH_SECONDS)
				refresh();
			if (stopAfterJobs && jobs.length == 0 && stopAt < 0)
				stopAt = Sys.time() + 0.3;
			if (inventory.owned().length > 0 || clients.length > 0 || jobs.length > 0 || relay.hostingCount() > 0 || resident)
				idleSince = Sys.time();
			else if (Sys.time() - idleSince >= idleSeconds)
				break;
		}
	}

	function refresh():Void {
		inventory = new SuitInventory(true);
		refreshedAt = Sys.time();
		updateTooltip();
	}

	function tooltip():String {
		var hosting = relay.summary();
		return hosting.length == 0 ? inventory.summary() : inventory.summary() + "\n" + hosting;
	}

	function updateTooltip():Void {
		if (tray != null)
			tray.setTooltip(tooltip());
	}

	function onEvent(value:PlatformEvent):Void {
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
		current.show(function(menu) SuitMenuModel.build(menu, inventory, {
			terminate: terminate, openViewer: openViewer, quit: quitEverything,
			hosting: {
				hosts: relay.views, stopHosting: function(root) stopHosting(root), resumeHosting: function(root) relay.resume(root),
				disconnect: function(client) relay.disconnect(client),
				retry: function(machineId) relay.retry(machineId), dismiss: function(machineId) relay.dismiss(machineId),
				loginEnabled: SuitLogin.cached, toggleLogin: SuitLogin.toggleInBackground
			}
		}));
	}

	/** Stop hosting: pause it in relay-settings.json (so nothing restarts it) and stop the workspace service. */
	function stopHosting(root:Null<String>):SuitRelayStopPlan {
		var plan = SuitRelayHosting.stop(inventory, root, relay);
		terminate(plan.terminate);
		return plan;
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
			var request:Dynamic = null;
			try request = Json.parse(message.toString()) catch (_:Dynamic) {}
			if (SuitRelayHosting.isAttach(request)) {
				// A hosting daemon's relay link: from here on it carries relay frames, not control requests.
				clients.splice(index, 1);
				relay.attach(client, request);
				continue;
			}
			var reply:Dynamic;
			try reply = handle(request) catch (error:Dynamic) reply = {ok: false, error: Std.string(error)};
			client.send(Bytes.ofString(Json.stringify(reply)));
		}
	}

	function handle(request:Dynamic):Dynamic {
		var op = suit.SuitRecord.SuitRecords.stringField(request, "op");
		switch op {
			case "status":
				refresh();
				return {
					ok: true, pid: Sys.getPid(), home: SuitPaths.home(), summary: inventory.summary(), tray: tray != null,
					editors: inventory.editors().length, background: inventory.background().length,
					orphaned: inventory.orphans().length, terminating: jobs.length, hosting: relay.hostingCount(),
					tooltip: tooltip(), connections: clients.length, idleFor: Sys.time() - idleSince
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
				stopAt = Sys.time() + 0.3;
				return {ok: true};
			case "relay-stop":
				refresh();
				var plan = stopHosting(SuitRecords.stringField(request, "workspace"));
				return {ok: true, roots: plan.roots, terminating: plan.terminate.length};
			case "relay-pause":
				// Pause without stopping the services: their daemons see the pause and exit on their own.
				refresh();
				return {ok: true, roots: SuitRelayHosting.stop(inventory, SuitRecords.stringField(request, "workspace"), relay).roots};
			case "test-menu":
				// Tests only: open the tray menu as a click does (adding the icon if needed), or close it by
				// removing the icon, so a test can check that the daemon keeps working while it is open.
				if (Sys.getEnv("EXOSUIT_SUIT_HOME") == null || Sys.getEnv("EXOSUIT_SUIT_TEST_MENU") != "1")
					return {ok: false, error: "unknown request"};
				if (Reflect.field(request, "close") == true) {
					if (tray != null)
						tray.dispose();
					tray = null;
					return {ok: true};
				}
				if (tray == null)
					tray = new SuitTray(tooltip(), findIcon());
				menuRequested = true;
				return {ok: true};
			case "machine":
				return {ok: true, machine: machine().json()};
			case "machine-rename":
				machine().renameMachine(SuitRecords.stringField(request, "name"));
				return {ok: true, machine: machine().json()};
			case "workspace-create":
				var created = machine().create(SuitRecords.stringField(request, "name"), requestFolders(request));
				return {ok: true, workspace: created, machine: machine().json()};
			case "workspace-scratch":
				var id = SuitRecords.stringField(request, "workspace");
				var scratch = machine().scratch(id);
				var workspace:Null<MachineCatalog.MachineWorkspace> = null;
				for (entry in machine().state.workspaces)
					if (entry.id == id)
						workspace = MachineCatalog.decodeWorkspace(entry);
				return {ok: true, scratch: scratch, workspace: workspace, machine: machine().json()};
			case "workspace-rename":
				var renamed = machine().rename(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "name"));
				return {ok: true, workspace: renamed, machine: machine().json()};
			case "workspace-delete":
				machine().delete(SuitRecords.stringField(request, "workspace"));
				return {ok: true, machine: machine().json()};
			case "workspace-add-folder":
				var added = machine().addFolder(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "folder"));
				return {ok: true, workspace: added, machine: machine().json()};
			case "workspace-remove-folder":
				var removed = machine().removeFolder(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "folder"));
				return {ok: true, workspace: removed, machine: machine().json()};
			case "login-toggle":
				// As the tray's checkbox does: in the background, answered at once.
				SuitLogin.toggleInBackground();
				return {ok: true};
			default:
				var relayReply = relay.handle(request);
				return relayReply != null ? relayReply : {ok: false, error: "unknown request"};
		}
	}

	/** This machine's workspaces, loaded on first use so a damaged machine.json fails requests, not the daemon. */
	function machine():MachineCatalog {
		if (catalog == null)
			catalog = new MachineCatalog(MachineCatalog.file(), MachineCatalog.existingFolders());
		return catalog;
	}

	/** A `workspace-create` request's folders: `folders` (possibly empty), or the older single `folder`. */
	static function requestFolders(request:Dynamic):Array<String> {
		var folders:Dynamic = Reflect.field(request, "folders");
		if (folders == null) {
			var folder = SuitRecords.stringField(request, "folder");
			return folder == null ? [] : [folder];
		}
		if (!Std.isOfType(folders, Array))
			throw "folders must be a list of folders";
		var list:Array<String> = [];
		for (folder in (folders : Array<Dynamic>)) {
			if (!Std.isOfType(folder, String))
				throw "folders must be a list of folders";
			list.push(folder);
		}
		return list;
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
		relay.dispose();
		hub.dispose();
		runtime.dispose();
	}
}
