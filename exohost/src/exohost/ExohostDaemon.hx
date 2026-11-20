package exohost;

import exohost.ExohostRecord.ExohostRecords;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.Runtime;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes;
import sys.FileSystem;
import exohost.ExohostInventory.ExohostProcess;
import exohost.control.ControlRouter;
import exohost.control.PragticalPipes;
import exohost.remote.MachineRemote;
import exohost.remote.DeferredReply;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

typedef ExohostLockHandle = hl.Abstract<"realtime_file_lock">;

/** The single-instance lock: the exclusive file lock a workspace service also uses. Null when another process holds it. */
@:hlNative("haxeon_runtime", "__host_file_lock_acquire")
extern function acquireLock(path:String):Null<ExohostLockHandle>;

@:hlNative("haxeon_runtime", "__host_file_lock_release")
extern function releaseLock(lock:ExohostLockHandle):Void;

/**
	The per-user daemon: one per user (an exclusive lock in exohost's home), a control endpoint for the CLI, the link of
	every editor window (EditorDirectory) and the report of every running workspace service (ExohostServices), and on
	Windows the tray icon. It answers `machine` from memory and pushes `exosuit.machine.changed` to every window when the
	workspaces, their services or the windows' focus change. It is the control plane: the `control` op (ControlRouter)
	and a Pragtical control protocol pipe per window (PragticalPipes) reach every window over its link. With remote
	access on it holds the machine's relay socket and its paired devices' sessions (MachineRemote).

	On Windows the tray menu does not stop this loop: NativeKit runs the popup on its own thread. On macOS the loop
	pauses while the menu is open, since AppKit menus run on the main thread (`ExohostTray.show`).

	Idle cost: it sleeps in the NativeKit event wait, which a tray click or a control connection wakes,
	and rescans processes every REFRESH_SECONDS to keep the tooltip current. It exits after
	`EXOSUIT_EXOHOST_IDLE_SECONDS` (default 120) with nothing of exosuit's to track and no hosted workspace:
	processes it did not start (a terminal build's compiler worker) do not keep it running. Started at
	login (`daemon --login`) it stays resident.
**/
class ExohostDaemon {
	static inline var REFRESH_SECONDS:Float = 10;

	final runtime:Runtime;
	final hub:NativeRpcHub;
	final clients:Array<NativeRpcTransport> = [];
	final directory:EditorDirectory = new EditorDirectory();
	final services:ExohostServices;
	final router:ControlRouter;
	final pragtical:PragticalPipes;
	/** Bumped by every request that changes the machine's workspaces. */
	var catalogRevision:Int = 0;
	/** What the windows were last pushed: the catalog's, the services' and the directory's revisions. */
	var pushed:String = "";
	final jobs:Array<ExohostTerminator> = [];
	var tray:Null<ExohostTray> = null;
	var inventory:ExohostInventory;
	var refreshedAt:Float = 0;
	var idleSince:Float;
	var mainListener:Null<OwnedListenerHandle> = null;
	/** exohost's pipe listener stopped and is started again on the next loop (`listen`). */
	var listenFailed = false;
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
	/** `EXOSUIT_EXOHOST_SPARE=0`: no warm spare (to measure an open without one, or for a test that counts processes). */
	var spareOff = false;
	var quitPending:Bool = false;
	var quitEditors:Array<Int> = [];
	/** The compiler workers a quit spared as shared with a build exosuit did not start, when it began. */
	var quitSharedWorkers:Array<{pid:Int, started:Float}> = [];
	/** The full quit's terminal hosts an editor ran in when it began: ended once no editor runs in them (endReleasedHosts). */
	var quitHeldHosts:Array<{pid:Int, started:Float}> = [];
	var quitRounds:Int = 0;
	var quitCheckAt:Float = 0;
	final refusedAttaches:Array<{transport:NativeRpcTransport, until:Float}> = [];
	static inline var QUIT_ROUNDS:Int = 3;
	/** When set, the loop ends at this time; the delay lets the reply to a stop or quit request flush. */
	var stopAt:Float = -1;
	var menuRequested:Bool = false;
	final idleSeconds:Float;
	final remote:MachineRemote;
	/** The `sessions` op: every running service's sessions and terminals (ExohostSessions). */
	final sessions:ExohostSessions;
	/** Clients waiting for a pairing step to finish: they send nothing until their reply arrives. */
	final waiting:Array<{client:NativeRpcTransport, reply:DeferredReply}> = [];
	var catalog:Null<MachineCatalog> = null;
	/** Started at login: stays up with nothing to track, so the tray icon stays. */
	final resident:Bool;

	public static function run(login:Bool = false):Int {
		var home = ExohostPaths.home();
		if (!ExohostPaths.prepare()) {
			Sys.stderr().writeString("exohost: " + home + " is not a private directory of this user\n");
			return 1;
		}
		var lock = acquireLock(Path.join([home, "exohost.lock"]));
		if (lock == null)
			return 0; // Another exohost owns this home; starting one is always safe to repeat.
		var code = 0;
		try {
			var daemon = new ExohostDaemon(login);
			daemon.loop();
			daemon.dispose();
		} catch (error:Dynamic) {
			code = 1;
			Sys.stderr().writeString("exohost: " + Std.string(error) + "\n");
			try sys.io.File.saveContent(Path.join([home, "daemon-error.txt"]), Std.string(error) + "\n") catch (_:Dynamic) {}
		}
		try FileSystem.deleteFile(Path.join([home, "daemon.json"])) catch (_:Dynamic) {}
		releaseLock(lock);
		return code;
	}

	function new(login:Bool) {
		resident = login;
		var configured = Std.parseFloat(Sys.getEnv("EXOSUIT_EXOHOST_IDLE_SECONDS"));
		idleSeconds = Math.isNaN(configured) || configured < 1 ? 120 : configured;
		spareOff = Sys.getEnv("EXOSUIT_EXOHOST_SPARE") == "0";
		idleSince = Sys.time();
		runtime = Runtime.start();
		// Every editor window and every running service holds a connection: more than a hub's default.
		hub = new NativeRpcHub(runtime.events, 256, 4, ExohostLink.MAX_MESSAGE_BYTES);
		var listenError = listen();
		if (listenError != null) {
			// The first pipe instance is exclusive: another process holding the name is never shared with.
			hub.dispose();
			runtime.dispose();
			throw "exohost's control endpoint " + ExohostPaths.endpoint() + " is held by another process; exohost will not share it (" + listenError + ")";
		}
		router = new ControlRouter(directory, function() return machine().json(serviceOf), workspaceFolders);
		pragtical = new PragticalPipes(runtime.events, router);
		directory.onEvent = router.event;
		directory.onLinked = function(editor, attached) {
			pragtical.linked(editor, attached);
			router.linked(editor, attached);
		};
		router.onEvent = pragtical.event;
		services = new ExohostServices(function(id) {
			for (entry in machine().state.workspaces)
				if (entry.id == id)
					return entry;
			return null;
		}, function(id) {
			// A scratch folder made now changes the machine: the windows are pushed it.
			catalogRevision++;
			return machine().scratch(id);
		});
		remote = new MachineRemote(runtime.events, hub, machine, services);
		sessions = new ExohostSessions(hub, services);
		remote.askSessions = function(ids, terminals, agents) return sessions.ask(machine().state, ids, terminals, agents);
		runtime.events.listen(onEvent);
		inventory = new ExohostInventory(true, directory.editors());
		refreshedAt = Sys.time();
		sys.io.AtomicFile.write(Path.join([ExohostPaths.home(), "daemon.json"]),
			Json.stringify({version: 1, pid: Sys.getPid(), endpoint: ExohostPaths.endpoint()}) + "\n");
		ExohostLogin.refresh();
		if ((Sys.systemName() == "Windows" || Sys.systemName() == "Mac") && Sys.getEnv("EXOSUIT_EXOHOST_TRAY") != "0") {
			try tray = new ExohostTray(inventory.summary(), findIcon()) catch (_:Dynamic) tray = null;
		}
	}

	/**
		Listens on exohost's pipe. NativeKit's listener stops for good when a client connects and closes before it accepts
		(docs/haxeon-compiler-bugs.md), so a stopped listener is started again by the loop.
	**/
	function listen():Null<String> {
		try {
			if (mainListener != null)
				try hub.forget(mainListener) catch (_:Dynamic) {}
			mainListener = null;
			listenFailed = false;
			mainListener = hub.listen(NativeRpcHub.local(ExohostPaths.endpoint()), function(transport) clients.push(transport),
				function() listenFailed = true);
		} catch (error:Dynamic) {
			return Std.string(error);
		}
		return null;
	}

	function loop():Void {
		while (stopAt < 0 || Sys.time() < stopAt) {
			// A service start turns the loop every 10 ms: its report is answered to the editor that waits on it at once.
			runtime.events.wait(services.busy() ? 0.01 : jobs.length > 0 || clients.length > 0 || remote.busy() || sessions.busy() ? 0.1 : 1.0);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			if (menuRequested) {
				menuRequested = false;
				ExohostLogin.refresh();
				refresh();
				showMenu();
			}
			serveClients();
			// Services first: a start that finished answers its editor in this turn's directory poll.
			services.keepSpare(directory.editors().length > 0 && quitting == null && !spareOff);
			if (listenFailed)
				listen();
			router.poll();
			pragtical.poll();
			services.poll();
			directory.poll(function(request) return handle(request, 0));
			pushMachine();
			var refusedIndex = refusedAttaches.length;
			while (refusedIndex-- > 0)
				if (Sys.time() >= refusedAttaches[refusedIndex].until || !refusedAttaches[refusedIndex].transport.isOpen()) {
					refusedAttaches[refusedIndex].transport.close();
					refusedAttaches.splice(refusedIndex, 1);
				}
			remote.poll();
			sessions.poll();
			ExohostLogin.poll();
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
			if (inventory.owned().length > 0 || clients.length > 0 || directory.editors().length > 0 || router.subscriberCount() > 0 || services.count() > 0 || jobs.length > 0 || remote.hosting() || resident)
				idleSince = Sys.time();
			else if (Sys.time() - idleSince >= idleSeconds)
				break;
		}
	}

	/** Tells every window what changed: the machine's workspaces with their services, and where each window is focused. */
	function pushMachine():Void {
		var key = catalogRevision + ":" + services.revision + ":" + directory.revision;
		if (key == pushed)
			return;
		pushed = key;
		if (directory.editors().length == 0 && router.subscriberCount() == 0)
			return;
		try {
			var changed = {machine: machine().json(serviceOf), windows: directory.windows()};
			directory.push("exosuit.machine.changed", changed);
			router.publish("exosuit.machine.changed", changed, null);
		} catch (_:Dynamic) {}
	}

	function refresh():Void {
		inventory = new ExohostInventory(true, directory.editors());
		refreshedAt = Sys.time();
		checkQuitState();
		updateTooltip();
	}

	/** After a scan: a finished quit exits once nothing owned is left. (A new editor ends the quit when it links.) */
	function checkQuitState():Void {
		if (quitting == null)
			return;
		if (quitting == "full" && jobs.length == 0)
			endReleasedHosts();
		if (quitting != null && !quitPending && stopAt < 0 && inventory.owned().length == 0)
			quitDone();
	}

	/**
		Nothing owned is left after a quit. The full quit ends with the daemon. The polite quit does only when nothing else
		keeps the daemon up: started at login, or remote access on. Otherwise its state is dropped and
		the daemon carries on as usual (a phone using this machine hours after the kept terminals ended keeps its access).
	**/
	function quitDone():Void {
		if (quitting == "polite" && (resident || remote.hosting())) {
			quitting = null;
			quitPending = false;
			quitEditors = [];
			return;
		}
		stopAt = Sys.time() + 0.3;
	}

	/**
		The full quit's terminal hosts that had an editor running in them (`python scripts/run.py` from an Exosuit terminal)
		were left running for that editor (ExohostKinds.hostsEditors). Once no editor runs in one any more it is ended, also
		after the quit's rounds are over: it is the quit's, not something the user started since.
	**/
	function endReleasedHosts():Void {
		var released:Array<ExohostProcess> = [];
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

	/** Whether the quit under way asked the editor of process `pid` to close. */
	function quitAsked(pid:Null<Int>):Bool
		return pid != null && quitEditors.indexOf(pid) >= 0;

	/** The user started Exosuit again: nothing of the quit applies to what runs from now on, and remote access is back. */
	function cancelQuit():Void {
		quitting = null;
		quitPending = false;
		quitEditors = [];
		quitHeldHosts = [];
		quitSharedWorkers = [];
		remote.resumeAfterQuit();
	}

	function tooltip():String {
		var lines = [inventory.summary()];
		for (line in [router.drivenSummary()])
			if (line.length > 0)
				lines.push(line);
		return lines.join("\n");
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

	/**
		Ends `processes`. An editor among them is asked over its link to quit in `mode` (`prompt` or `recover`), a workspace
		service over its link to stop.
	**/
	function terminate(processes:Array<ExohostProcess>, mode:String = "prompt"):Void {
		if (processes.length > 0)
			jobs.push(new ExohostTerminator(inventory, processes, function(process) return process.kind == ExohostKind.Editor
				? directory.quit(process.pid, mode, function(_, _) {}) : services.stop(process.pid)));
	}

	function showMenu():Void {
		var current = tray;
		if (current == null)
			return;
		current.show(function(menu) ExohostMenuModel.build(menu, inventory, {
			terminate: function(processes) terminate(processes), openViewer: openViewer, quit: quitEverything, quitKeepingTerminals: quitKeepingTerminals,
			remote: {
				devices: function() return remote.handle({op: "remote-devices"}), enabled: remote.hosting,
				disconnect: function(id:String) { remote.disconnectDevice(id); },
				revoke: function(id:String) { remote.handle({op: "remote-revoke", deviceId: id}); },
				off: function() { remote.handle({op: "remote-disable"}); }
			},
			loginEnabled: ExohostLogin.cached, toggleLogin: ExohostLogin.toggleInBackground
		}));
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
		// Editors keep their unsaved work for the next start (hot exit) and close at once (TDD Q4: the tray quits with recover).
		terminate(ExohostActions.quit(inventory, keepTerminals), "recover");
		// The full quit cuts off everything connected from outside now: every remote device session and the machine's relay
		// connection. They would end with the daemon, which may stay up for an editor.
		if (!keepTerminals)
			remote.cutOff();
	}

	/** A quit's jobs are done: exit when nothing is left, else run another round or carry on as usual. */
	function afterQuitJobs():Void {
		refresh();
		if (quitting == null)
			return; // A new editor registered: the quit is cancelled.
		var again = [for (process in ExohostActions.quit(inventory, quitting == "polite")) if (process.kind != ExohostKind.Editor) process];
		// A worker the quit spared as shared with a build that has since ended (it ran in a terminal the quit ended) is no
		// longer adopted once its session is gone (ExohostInventory.adoptCheckoutChains): end it as the quit's.
		for (worker in quitSharedWorkers) {
			var process = inventory.find(worker.pid);
			if (process != null && process.started == worker.started && !inventory.usedByBuild(process) && again.indexOf(process) < 0)
				again.push(process);
		}
		if (again.length > 0 && quitRounds < QUIT_ROUNDS) {
			// Something reappeared (a service an editor restarted while closing, a host a service started): end it too.
			quitRounds++;
			terminate(again, "recover");
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

	/** Opens a console running `exohost watch`. */
	function openViewer(arguments:Array<String>):Void {
		var launcher = ExohostClient.findLauncher();
		if (launcher == null)
			return;
		try {
			var command = Sys.systemName() == "Windows" ? "cmd.exe" : "x-terminal-emulator";
			var commandArguments = Sys.systemName() == "Windows"
				? ["/c", "start", "Exosuit processes", Sys.executablePath(), launcher].concat(arguments)
				: ["-e", Sys.executablePath(), launcher].concat(arguments);
			var child = sys.io.ChildProcess.spawn(command, commandArguments, Path.directory(launcher), [ExohostClient.libraryVariable()],
				[ExohostClient.nativePath(launcher)], true);
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
			var op = ExohostRecords.stringField(request, "op");
			if (op == "editor-attach" || op == "service-attach" || op == "service-spare") {
				// From here on the connection belongs to the editor's link, the service's report or the spare's link.
				clients.splice(index, 1);
				var accepted = op == "editor-attach" ? directory.attach(client, request)
					: op == "service-spare" ? services.linkSpare(client, request) : services.attach(client, request);
				if (!accepted)
					refusedAttaches.push({transport: client, until: Sys.time() + 2}); // closed later, so the reply is read first
				else if (op == "editor-attach" && quitting != null && !quitAsked(ExohostRecords.intField(request, "pid")))
					cancelQuit(); // A window the quit did not ask to close: the user started Exosuit again.
				continue;
			}
			if (ControlRouter.isSubscription(request)) {
				// From here on the connection carries the events it asked for (TDD Q18: events are opt-in).
				clients.splice(index, 1);
				router.subscribe(client, request);
				continue;
			}
			var reply:Dynamic;
			try reply = handle(request, client.peerProcess()) catch (error:Dynamic) reply = {ok: false, error: Std.string(error)};
			if (Std.isOfType(reply, DeferredReply)) {
				waiting.push({client: client, reply: cast reply});
				continue;
			}
			client.send(Bytes.ofString(Json.stringify(reply)));
		}
	}

	/** One request of exohost's main pipe or of a window's link; `peer` is the process that sent it (0 for a window's). */
	function handle(request:Dynamic, peer:Int):Dynamic {
		var op = ExohostRecords.stringField(request, "op");
		if (op != null && (StringTools.startsWith(op, "workspace-") || op == "machine-rename"))
			catalogRevision++; // the windows are pushed the machine once this request is done
		switch op {
			case "status":
				refresh();
				return {
					ok: true, pid: Sys.getPid(), home: ExohostPaths.home(), summary: inventory.summary(), tray: tray != null,
					editors: directory.editors().length, services: services.count(), background: inventory.background().length,
					orphaned: inventory.orphans().length, terminals: inventory.terminals().length, terminating: jobs.length,
					tooltip: tooltip(), connections: clients.length, idleFor: Sys.time() - idleSince
				};
			case "refresh":
				refresh();
				return {ok: true};
			case "quit":
				refresh();
				var keepTerminals = Reflect.field(request, "keepTerminals") == true;
				var count = ExohostActions.quit(inventory, keepTerminals).length;
				quit(keepTerminals);
				// The reply says how many terminals are ended or kept, so `exohost quit` can say so.
				return {ok: true, terminating: count, terminals: inventory.terminals().length, keepTerminals: keepTerminals};
			case "stop":
				stopAt = Sys.time() + 0.3;
				return {ok: true};
			case "workspace.open":
				// The workspace's service, started first when none runs: the editor connects to the pipe in the reply.
				var opening = new DeferredReply();
				services.open(ExohostRecords.stringField(request, "workspace"), function(service, failure) opening.resolve(service == null
					? {ok: false, error: failure}
					: {ok: true, endpoint: service.endpoint, generation: service.generation, root: service.root}));
				return opening;
			case "service-stop":
				var pid = ExohostRecords.intField(request, "pid");
				if (pid == null || !services.stop(pid))
					return {ok: false, error: "no workspace service of process " + pid + " is linked to exohost"};
				return {ok: true};
			case "machine":
				// `windows`: where each editor window is focused, for the Workbench's "open in another window" (M19 Phase 8).
				return {ok: true, machine: machine().json(serviceOf), windows: directory.windows()};
			case "sessions":
				// Every running workspace service's sessions and terminals; `workspaces` (a list of ids) narrows it. The reply waits for the services.
				var listed:Dynamic = Reflect.field(request, "workspaces");
				var wanted:Null<Array<String>> = null;
				if (Std.isOfType(listed, Array))
					wanted = [for (id in (listed : Array<Dynamic>)) if (Std.isOfType(id, String)) (id : String)];
				return sessions.ask(machine().state, wanted);
			case "editors":
				return {ok: true, editors: directory.editors()};
			case "control":
				return router.handle(request, peer);
			case "editor-quit":
				var pid = ExohostRecords.intField(request, "pid"), mode = ExohostRecords.stringField(request, "mode");
				if (pid == null || !directory.quit(pid, mode == null ? "prompt" : mode, function(_, _) {}))
					return {ok: false, error: "no editor window of process " + pid + " is linked to exohost"};
				return {ok: true};
			case "machine-rename":
				machine().renameMachine(ExohostRecords.stringField(request, "name"));
				return {ok: true, machine: machine().json(serviceOf)};
			case "workspace-create":
				var created = machine().create(ExohostRecords.stringField(request, "name"), requestFolders(request));
				return {ok: true, workspace: created, machine: machine().json(serviceOf)};
			case "workspace-scratch":
				var id = ExohostRecords.stringField(request, "workspace");
				var scratch = machine().scratch(id);
				var workspace:Null<MachineCatalog.MachineWorkspace> = null;
				for (entry in machine().state.workspaces)
					if (entry.id == id)
						workspace = MachineCatalog.copy(entry);
				return {ok: true, scratch: scratch, workspace: workspace, machine: machine().json(serviceOf)};
			case "workspace-rename":
				var renamed = machine().rename(ExohostRecords.stringField(request, "workspace"), ExohostRecords.stringField(request, "name"));
				return {ok: true, workspace: renamed, machine: machine().json(serviceOf)};
			case "workspace-delete":
				machine().delete(ExohostRecords.stringField(request, "workspace"));
				// Its terminals have nothing to come back to: end their hosts, with or without a running service.
				refresh();
				var deleted = ExohostRecords.stringField(request, "workspace");
				terminate([for (host in inventory.terminals()) if (deleted != null && host.workspace == deleted) host]);
				remote.workspaceDeleted(ExohostRecords.stringField(request, "workspace"));
				return {ok: true, machine: machine().json(serviceOf)};
			case "workspace-add-folder":
				var added = machine().addFolder(ExohostRecords.stringField(request, "workspace"), ExohostRecords.stringField(request, "folder"));
				return {ok: true, workspace: added, machine: machine().json(serviceOf)};
			case "workspace-remove-folder":
				var removed = machine().removeFolder(ExohostRecords.stringField(request, "workspace"), ExohostRecords.stringField(request, "folder"));
				return {ok: true, workspace: removed, machine: machine().json(serviceOf)};
			default:
				var remoteReply = remote.handle(request);
				return remoteReply != null ? remoteReply : {ok: false, error: "unknown request"};
		}
	}

	/** This machine's workspaces, loaded on first use so a damaged machine.json fails requests, not the daemon. */
	function machine():MachineCatalog {
		if (catalog == null)
			catalog = new MachineCatalog(MachineCatalog.file(), MachineCatalog.existingFolders());
		return catalog;
	}

	/** A workspace's folders; none for an id the machine does not list. */
	function workspaceFolders(id:String):Array<String> {
		try for (entry in machine().state.workspaces)
			if (entry.id == id)
				return entry.folders.copy()
		catch (_:Dynamic) {}
		return [];
	}

	/** The running service of a workspace, as it reported itself (ExohostServices). */
	function serviceOf(workspace:MachineCatalog.MachineWorkspace):Null<MachineCatalog.MachineService>
		return services.serviceOf(workspace.id);

	/** A `workspace-create` request's folders: `folders` (possibly empty), or the older single `folder`. */
	static function requestFolders(request:Dynamic):Array<String> {
		var folders:Dynamic = Reflect.field(request, "folders");
		if (folders == null) {
			var folder = ExohostRecords.stringField(request, "folder");
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
		var launcher = ExohostClient.findLauncher();
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
		pragtical.dispose();
		directory.dispose();
		services.dispose();
		remote.dispose();
		hub.dispose();
		runtime.dispose();
	}
}
