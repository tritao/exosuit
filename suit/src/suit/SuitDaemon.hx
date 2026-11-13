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
import suit.remote.MachineRemote;
import suit.remote.MachineRemote.DeferredReply;
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
	/**
		Set by a quit. "full": end everything exosuit started, terminal hosts included; "polite": everything but terminal
		hosts. Either way the daemon exits only once a fresh inventory holds nothing of exosuit's. Background processes
		that reappear are ended again, up to QUIT_ROUNDS rounds; editors are asked to close once. Whatever is still
		running after that (an editor kept open over unsaved work, the hosts a polite quit kept) stays listed, and the
		daemon exits when the last of it ends.

		Ending again is over once a check finds nothing left to end or the rounds are used up (`quitPending` false): what
		is started afterwards is the user's new session, never touched, and the periodic scan stops. The daemon then only
		exits when nothing owned is left. An editor that registers after the quit (not one of `quitEditors`) cancels the
		whole quit state: the user started Exosuit again.
	**/
	var quitting:Null<String> = null;
	var quitPending:Bool = false;
	var quitEditors:Array<Int> = [];
	/** The compiler workers a quit spared as shared with a build exosuit did not start, when it began. */
	var quitSharedWorkers:Array<{pid:Int, started:Float}> = [];
	/** The full quit's terminal hosts an editor ran in when it began: ended once no editor runs in them (endReleasedHosts). */
	var quitHeldHosts:Array<{pid:Int, started:Float}> = [];
	var quitRounds:Int = 0;
	var quitCheckAt:Float = 0;
	/** True from a full quit until a new editor registers: the relay link of a restarted workspace service is refused. */
	var relayRefused:Bool = false;
	final refusedAttaches:Array<{transport:NativeRpcTransport, until:Float}> = [];
	static inline var QUIT_ROUNDS:Int = 3;
	/** When set, the loop ends at this time; the delay lets the reply to a stop or quit request flush. */
	var stopAt:Float = -1;
	var menuRequested:Bool = false;
	final idleSeconds:Float;
	final relay:SuitRelayHosting;
	final remote:MachineRemote;
	/** Clients waiting for a pairing step to finish: they send nothing until their reply arrives. */
	final waiting:Array<{client:NativeRpcTransport, reply:DeferredReply}> = [];
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
		remote = new MachineRemote(runtime.events, hub, machine);
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
			runtime.events.wait(jobs.length > 0 || clients.length > 0 || relay.busy() || remote.busy() ? 0.1 : 1.0);
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
			var refusedIndex = refusedAttaches.length;
			while (refusedIndex-- > 0)
				if (Sys.time() >= refusedAttaches[refusedIndex].until || !refusedAttaches[refusedIndex].transport.isOpen()) {
					refusedAttaches[refusedIndex].transport.close();
					refusedAttaches.splice(refusedIndex, 1);
				}
			relay.poll();
			remote.poll();
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
			if (quitting != null && quitPending && jobs.length == 0 && stopAt < 0 && Sys.time() >= quitCheckAt)
				afterQuitJobs();
			if (inventory.owned().length > 0 || clients.length > 0 || jobs.length > 0 || relay.hostingCount() > 0 || remote.hosting() || resident)
				idleSince = Sys.time();
			else if (Sys.time() - idleSince >= idleSeconds)
				break;
		}
	}

	function refresh():Void {
		inventory = new SuitInventory(true);
		refreshedAt = Sys.time();
		checkQuitState();
		updateTooltip();
	}

	/** After a scan: a new editor ends any quit state; a finished quit exits once nothing owned is left. */
	function checkQuitState():Void {
		if (quitting == null && !relayRefused)
			return;
		for (editor in inventory.editors())
			if (quitEditors.indexOf(editor.pid) < 0) {
				cancelQuit();
				return;
			}
		if (quitting == "full" && jobs.length == 0)
			endReleasedHosts();
		if (quitting != null && !quitPending && stopAt < 0 && inventory.owned().length == 0)
			quitDone();
	}

	/**
		Nothing owned is left after a quit. The full quit ends with the daemon. The polite quit does only when nothing else
		keeps the daemon up: started at login, remote access on, or a workspace hosted. Otherwise its state is dropped and
		the daemon carries on as usual (a phone using this machine hours after the kept terminals ended keeps its access).
	**/
	function quitDone():Void {
		if (quitting == "polite" && (resident || remote.hosting() || relay.hostingCount() > 0)) {
			quitting = null;
			quitPending = false;
			quitEditors = [];
			return;
		}
		stopAt = Sys.time() + 0.3;
	}

	/**
		The full quit's terminal hosts that had an editor running in them (`python scripts/run.py` from an Exosuit terminal)
		were left running for that editor (SuitKinds.hostsEditors). Once no editor runs in one any more it is ended, also
		after the quit's rounds are over: it is the quit's, not something the user started since.
	**/
	function endReleasedHosts():Void {
		var released:Array<SuitProcess> = [];
		var index = quitHeldHosts.length;
		while (index-- > 0) {
			var held = quitHeldHosts[index];
			var host = inventory.find(held.pid);
			if (host == null || host.started != held.started) {
				quitHeldHosts.splice(index, 1);
				continue;
			}
			if (inventory.hostedEditors(host.pid, host.started).length == 0) {
				quitHeldHosts.splice(index, 1);
				released.push(host);
			}
		}
		terminate(released);
	}

	/** The user started Exosuit again: nothing of the quit applies to what runs from now on, and remote access is back. */
	function cancelQuit():Void {
		quitting = null;
		quitPending = false;
		quitEditors = [];
		quitHeldHosts = [];
		quitSharedWorkers = [];
		relayRefused = false;
		remote.resumeAfterQuit();
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
			terminate: terminate, openViewer: openViewer, quit: quitEverything, quitKeepingTerminals: quitKeepingTerminals,
			remote: {
				devices: function() return remote.handle({op: "remote-devices"}), enabled: remote.hosting,
				disconnect: function(id:String) { remote.disconnectDevice(id); },
				revoke: function(id:String) { remote.handle({op: "remote-revoke", deviceId: id}); },
				off: function() { remote.handle({op: "remote-disable"}); }
			},
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

	/** The full Quit: ends everything exosuit started, terminal hosts included, editors asked to close first, then exits. */
	function quitEverything():Void
		quit(false);

	/** The polite quit: as quitEverything, but terminal hosts keep running and the daemon stays up while any lives. */
	function quitKeepingTerminals():Void
		quit(true);

	function quit(keepTerminals:Bool):Void {
		refresh();
		quitting = keepTerminals ? "polite" : "full";
		quitPending = true;
		quitEditors = [for (editor in inventory.editors()) editor.pid];
		quitHeldHosts = keepTerminals ? [] : [
			for (host in inventory.terminals()) if (inventory.hostedEditors(host.pid, host.started).length > 0) {pid: host.pid, started: host.started}
		];
		quitSharedWorkers = [for (worker in inventory.shared()) {pid: worker.pid, started: worker.started}];
		quitRounds = 1;
		quitCheckAt = 0;
		terminate(SuitActions.quit(inventory, keepTerminals));
		// The full quit cuts off everything connected from outside now: every remote device session, the machine's relay
		// connection and the workspaces' relay links. They would end with the daemon, which may stay up for an editor.
		if (!keepTerminals) {
			remote.cutOff();
			relay.dispose();
			relayRefused = true;
		}
	}

	/** A quit's jobs are done: exit when nothing is left, else run another round or carry on as usual. */
	function afterQuitJobs():Void {
		refresh();
		if (quitting == null)
			return; // A new editor registered: the quit is cancelled.
		var again = [for (process in SuitActions.quit(inventory, quitting == "polite")) if (process.kind != SuitKind.Editor) process];
		// A worker the quit spared as shared with a build that has since ended (it ran in a terminal the quit ended) is no
		// longer adopted once its session is gone (SuitInventory.adoptCheckoutChains): end it as the quit's.
		for (worker in quitSharedWorkers) {
			var process = inventory.find(worker.pid);
			if (process != null && process.started == worker.started && !inventory.usedByBuild(process) && again.indexOf(process) < 0)
				again.push(process);
		}
		if (again.length > 0 && quitRounds < QUIT_ROUNDS) {
			// Something reappeared (a service an editor restarted while closing, a host a service started): end it too.
			quitRounds++;
			terminate(again);
			return;
		}
		if (inventory.owned().length == 0) {
			quitDone();
			return;
		}
		// Something is left (an editor kept open, the hosts a polite quit kept) and nothing more to end: keep listing it,
		// stop ending and scanning, and exit when the last of it ends (checked by the ordinary rescan).
		quitPending = false;
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
		var held = waiting.length;
		while (held-- > 0) {
			var item = waiting[held];
			if (!item.client.isOpen())
				waiting.splice(held, 1);
			else if (item.reply.reply != null) {
				waiting.splice(held, 1);
				item.client.send(Bytes.ofString(Json.stringify(item.reply.reply)));
			}
		}
		var index = clients.length;
		while (index-- > 0) {
			var client = clients[index];
			if (!client.isOpen()) {
				clients.splice(index, 1);
				continue;
			}
			if (Lambda.exists(waiting, function(item) return item.client == client))
				continue;
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
				if (relayRefused) {
					// The full quit ended remote access: a restarted workspace service does not get it back.
					client.send(Bytes.ofString(Json.stringify({ok: false, error: "suit_quitting"})));
					refusedAttaches.push({transport: client, until: Sys.time() + 2}); // closed later, so the reply is read first
					clients.splice(index, 1);
					continue;
				}
				// A hosting daemon's relay link: from here on it carries relay frames, not control requests.
				clients.splice(index, 1);
				relay.attach(client, request);
				continue;
			}
			var reply:Dynamic;
			try reply = handle(request) catch (error:Dynamic) reply = {ok: false, error: Std.string(error)};
			if (Std.isOfType(reply, DeferredReply)) {
				waiting.push({client: client, reply: cast reply});
				continue;
			}
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
					orphaned: inventory.orphans().length, terminals: inventory.terminals().length, terminating: jobs.length, hosting: relay.hostingCount(),
					tooltip: tooltip(), connections: clients.length, idleFor: Sys.time() - idleSince
				};
			case "refresh":
				refresh();
				return {ok: true};
			case "quit":
				refresh();
				var keepTerminals = Reflect.field(request, "keepTerminals") == true;
				var count = SuitActions.quit(inventory, keepTerminals).length;
				quit(keepTerminals);
				// The reply says how many terminals are ended or kept, so `suit quit` can say so.
				return {ok: true, terminating: count, terminals: inventory.terminals().length, keepTerminals: keepTerminals};
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
				// `windows`: where each editor window is focused, for the Workbench's "open in another window" (M19 Phase 8).
				return {ok: true, machine: machine().json(services), windows: SuitInventory.liveWindows()};
			case "machine-rename":
				machine().renameMachine(SuitRecords.stringField(request, "name"));
				return {ok: true, machine: machine().json(services)};
			case "workspace-create":
				var created = machine().create(SuitRecords.stringField(request, "name"), requestFolders(request));
				return {ok: true, workspace: created, machine: machine().json(services)};
			case "workspace-scratch":
				var id = SuitRecords.stringField(request, "workspace");
				var scratch = machine().scratch(id);
				var workspace:Null<MachineCatalog.MachineWorkspace> = null;
				for (entry in machine().state.workspaces)
					if (entry.id == id)
						workspace = MachineCatalog.copy(entry);
				return {ok: true, scratch: scratch, workspace: workspace, machine: machine().json(services)};
			case "workspace-rename":
				var renamed = machine().rename(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "name"));
				return {ok: true, workspace: renamed, machine: machine().json(services)};
			case "workspace-delete":
				machine().delete(SuitRecords.stringField(request, "workspace"));
				// Its terminals have nothing to come back to: end their hosts, with or without a running service.
				refresh();
				var deleted = SuitRecords.stringField(request, "workspace");
				terminate([for (host in inventory.terminals()) if (deleted != null && host.workspace == deleted) host]);
				remote.workspaceDeleted(SuitRecords.stringField(request, "workspace"));
				return {ok: true, machine: machine().json(services)};
			case "workspace-add-folder":
				var added = machine().addFolder(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "folder"));
				return {ok: true, workspace: added, machine: machine().json(services)};
			case "workspace-remove-folder":
				var removed = machine().removeFolder(SuitRecords.stringField(request, "workspace"), SuitRecords.stringField(request, "folder"));
				return {ok: true, workspace: removed, machine: machine().json(services)};
			case "login-toggle":
				// As the tray's checkbox does: in the background, answered at once.
				SuitLogin.toggleInBackground();
				return {ok: true};
			default:
				var remoteReply = remote.handle(request);
				if (remoteReply != null)
					return remoteReply;
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

	/** The running service of a workspace, as a `machine` reply reports it. */
	function services(workspace:MachineCatalog.MachineWorkspace):Null<MachineCatalog.MachineService>
		return SuitInventory.serviceFor(inventory.owned(), workspace.id);

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
		remote.dispose();
		relay.dispose();
		hub.dispose();
		runtime.dispose();
	}
}
