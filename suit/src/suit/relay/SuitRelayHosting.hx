package suit.relay;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.NativeKitEvents;
import processkit.Processes;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import suit.SuitActions;
import suit.SuitControl;
import suit.SuitInventory;
import suit.SuitInventory.SuitProcess;
import suit.SuitPaths;
import suit.relay.SuitRelayBridge.SuitRelayHostView;
import suit.relay.SuitRelayClients.SuitRelayClientView;
import suit.relay.SuitRelayHosts.SuitRelayHost;
import suit.relay.SuitRelayProtocol.SuitRelayOpen;
import workspace.PathKey;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;
import suit.SuitRecord.SuitRecords;

/** What Stop hosting did: the roots paused, and the workspace services that must stop. */
typedef SuitRelayStopPlan = {
	var roots:Array<String>;
	var terminate:Array<SuitProcess>;
}

/**
	Relay hosting inside the suit daemon: one `SuitRelayBridge` per hosted workspace, loaded from the host
	records at start and added when a daemon attaches. It publishes `relay-state.json` in suit's home for
	the CLI (`suit relay list`, `suit menu`), and keeps suit from idling out while anything is hosted.
**/
class SuitRelayHosting {
	static inline var STATE_REFRESH_SECONDS:Float = 30;
	/** A state file older than this is from a suit that is no longer running. */
	static inline var STATE_FRESH_SECONDS:Float = 90;

	final events:NativeKitEvents;
	final hub:NativeRpcHub;
	final bridges:Array<SuitRelayBridge> = [];
	/** Refused attaches, kept open briefly so the refusal reaches the daemon before the pipe closes. */
	final refused:Array<{transport:NativeRpcTransport, until:Float}> = [];
	var writtenState:String = "";
	var writtenAt:Float = -1e9;

	public function new(events:NativeKitEvents, hub:NativeRpcHub) {
		this.events = events;
		this.hub = hub;
		for (host in SuitRelayHosts.load())
			bridges.push(new SuitRelayBridge(events, hub, host, SuitRelayHosts.isPaused(host.stateDir)));
	}

	public static function isAttach(request:Dynamic):Bool
		return SuitRecords.stringField(request, "op") == SuitRelayProtocol.ATTACH_OP;

	/** Workspaces suit must stay up for: hosted, not paused, not failed, not left to a direct daemon. */
	public function hostingCount():Int {
		var count = 0;
		for (bridge in bridges)
			if (bridge.hosting())
				count++;
		return count;
	}

	public function busy():Bool {
		for (bridge in bridges)
			if (bridge.busy())
				return true;
		return refused.length > 0;
	}

	/**
		A daemon's `relay-attach`: the caller is checked (SuitRelayHosts.validate), the host recorded, and its
		link handed to the workspace's bridge. A refusal other than a pause leaves the machine to that daemon,
		which dials the relay itself, so suit's bridge holds off while it runs.
	**/
	public function attach(transport:NativeRpcTransport, request:Dynamic):Void {
		var pid = transport.peerProcess();
		var machineId = SuitRecords.stringField(request, "machineId");
		var existing = machineId == null ? null : find(machineId);
		var host:SuitRelayHost;
		try {
			var recorded = existing != null ? existing.host : machineId == null ? null : SuitRelayHosts.find(machineId);
			host = SuitRelayHosts.validate(request, callerExecutable(pid, request), recorded);
			var stored = WorkspaceCredentialStores.relay().read(WorkspaceCredentialStores.machineAccount(SuitRelayHosts.endpoint(host)));
			if (stored == null)
				throw "relay_credential_missing";
			for (index in 0...stored.length)
				stored.set(index, 0);
			SuitRelayHosts.save(host);
		} catch (error:Dynamic) {
			var reason = Std.string(error);
			if (existing != null) {
				if (reason == "hosting_paused") {
					if (!existing.paused)
						existing.pause();
				} else if (pid > 0)
					existing.holdFor(pid, reason);
			}
			transport.send(Bytes.ofString(Json.stringify({ok: false, error: reason})));
			refused.push({transport: transport, until: Sys.time() + 2});
			writtenAt = -1e9;
			return;
		}
		var bridge = existing;
		if (bridge == null) {
			bridge = new SuitRelayBridge(events, hub, host, false);
			bridges.push(bridge);
		} else if (bridge.paused)
			bridge.resume();
		bridge.attach(transport, pid, host);
		writtenAt = -1e9;
	}

	/**
		The verified caller's executable. An isolated test suit (EXOSUIT_SUIT_HOME set) may also name, in
		EXOSUIT_SUIT_TEST_ATTACH_CALLER, a stand-in program allowed to attach for the executable it names.
	**/
	static function callerExecutable(pid:Int, request:Dynamic):Null<String> {
		if (pid <= 0)
			return null;
		var image = Processes.executablePath(pid);
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME"), standIn = Sys.getEnv("EXOSUIT_SUIT_TEST_ATTACH_CALLER");
		if (image != null && home != null && home.length > 0 && standIn != null && standIn.length > 0 && PathKey.same(image, standIn))
			return SuitRecords.stringField(request, "executable");
		return image;
	}

	public function poll():Void {
		var now = Sys.time();
		for (bridge in bridges)
			bridge.poll(now);
		var index = refused.length;
		while (index-- > 0)
			if (now >= refused[index].until || !refused[index].transport.isOpen()) {
				refused[index].transport.close();
				refused.splice(index, 1);
			}
		writeState(now);
	}

	/**
		Stop hosting for the matching workspaces (all when `query` is null), whether suit hosts them or their
		daemon does: pauses each workspace's relay settings once, pauses suit's bridges, and returns the
		workspace services to stop. `hosting` is the running daemon's; the CLI passes null when suit is down.
	**/
	public static function stop(inventory:SuitInventory, query:Null<String>, hosting:Null<SuitRelayHosting>):SuitRelayStopPlan {
		var paused = new Map<String, Bool>();
		var roots:Array<String> = [];
		function pauseDir(stateDir:Null<String>, root:Null<String>):Void {
			if (stateDir == null || paused.exists(PathKey.of(stateDir)))
				return;
			paused.set(PathKey.of(stateDir), true);
			if (SuitRelayHosts.setPaused(stateDir, true) && root != null)
				roots.push(root);
		}
		if (hosting != null) {
			for (bridge in hosting.bridges)
				if (SuitRelayHosts.matches(bridge.host, query)) {
					pauseDir(bridge.host.stateDir, bridge.host.root);
					bridge.pause();
				}
			hosting.writtenAt = -1e9;
		} else
			for (host in SuitRelayHosts.load())
				if (SuitRelayHosts.matches(host, query))
					pauseDir(host.stateDir, host.root);
		var targets = SuitActions.hosting(inventory, query);
		for (process in targets)
			pauseDir(process.stateDir, process.root);
		return {roots: roots, terminate: targets};
	}

	public function resume(query:Null<String>):Array<String> {
		var roots:Array<String> = [];
		for (bridge in bridges)
			if (SuitRelayHosts.matches(bridge.host, query) && bridge.paused) {
				if (!SuitRelayHosts.setPaused(bridge.host.stateDir, false))
					continue;
				bridge.resume();
				roots.push(bridge.host.root);
			}
		writtenAt = -1e9;
		return roots;
	}

	/** Ends one client's session (see SuitRelayBridge.disconnect); returns the bridge's root and full id, or null. */
	public function disconnect(query:String):Null<{client:String, root:String}> {
		var now = Sys.time();
		for (bridge in bridges) {
			var id = bridge.disconnect(query, now);
			if (id != null) {
				writtenAt = -1e9;
				return {client: id, root: bridge.host.root};
			}
		}
		return null;
	}

	/** Retry a failed workspace now. */
	public function retry(machineId:String):Bool {
		var bridge = find(machineId);
		if (bridge == null)
			return false;
		bridge.retry();
		writtenAt = -1e9;
		return true;
	}

	/** Dismiss: suit stops hosting this workspace and forgets its record; the next daemon attach adds it again. */
	public function dismiss(machineId:String):Bool {
		var bridge = find(machineId);
		if (bridge == null)
			return false;
		bridge.dispose();
		bridges.remove(bridge);
		SuitRelayHosts.remove(machineId);
		writtenAt = -1e9;
		return true;
	}

	/**
		Control requests from the CLI and the tray: `relay-resume` (optional `workspace`), `relay-state`,
		`relay-disconnect` (`client`), `relay-retry` and `relay-forget` (`machineId` or `workspace`). Null for
		other ops. `relay-stop` needs the daemon's inventory and jobs, so the daemon handles it.
	**/
	public function handle(request:Dynamic):Null<Dynamic> {
		var workspace = SuitRecords.stringField(request, "workspace");
		switch SuitRecords.stringField(request, "op") {
			case "relay-resume":
				return {ok: true, roots: resume(workspace)};
			case "relay-state":
				return {ok: true, hosts: views()};
			case "relay-disconnect":
				var client = SuitRecords.stringField(request, "client");
				if (client == null)
					return {ok: false, error: "client required"};
				var result = disconnect(client);
				if (result == null)
					return {ok: false, error: 'no connected client matches $client (see `suit relay list`)'};
				return {ok: true, client: result.client, root: result.root};
			case "relay-retry", "relay-forget":
				var matched = [for (bridge in bridges) if (matchesRequest(bridge, request)) bridge.host];
				for (host in matched)
					if (SuitRecords.stringField(request, "op") == "relay-retry")
						retry(host.machineId);
					else
						dismiss(host.machineId);
				return {ok: true, roots: [for (host in matched) host.root]};
			default:
				return null;
		}
	}

	static function matchesRequest(bridge:SuitRelayBridge, request:Dynamic):Bool {
		var machineId = SuitRecords.stringField(request, "machineId");
		if (machineId != null)
			return bridge.host.machineId == machineId;
		return SuitRelayHosts.matches(bridge.host, SuitRecords.stringField(request, "workspace"));
	}

	public function views():Array<SuitRelayHostView> {
		var now = Sys.time();
		return [for (bridge in bridges) bridge.view(now)];
	}

	/** Changes whenever a client connects, goes or is disconnected, or hosting state changes; the tray updates then. */
	public function revision():String {
		var parts:Array<String> = [];
		for (bridge in bridges) {
			var view = bridge.view(Sys.time());
			parts.push(view.state + "/" + view.error + "/" + bridge.clients.revision + "/" + bridge.clientCount() + "/" + bridge.attached());
		}
		return parts.join(",");
	}

	/** For the tooltip: "Hosting · 2 devices connected", or "" when nothing is hosted. */
	public function summary():String {
		var hosted = 0, connected = 0, failed = 0;
		for (bridge in bridges) {
			if (bridge.paused)
				continue;
			if (bridge.failure != null) {
				failed++;
				continue;
			}
			hosted++;
			connected += bridge.clientCount();
		}
		if (hosted + failed == 0)
			return "";
		var text = hosted == 0 ? "Remote access stopped" : "Hosting" + (hosted > 1 ? " " + hosted + " workspaces" : "") + " · "
			+ (connected == 1 ? "1 device connected" : connected + " devices connected");
		return failed > 0 ? text + " · " + failed + " failed" : text;
	}

	function find(machineId:String):Null<SuitRelayBridge> {
		for (bridge in bridges)
			if (bridge.host.machineId == machineId)
				return bridge;
		return null;
	}

	static function statePath():String
		return Path.join([SuitPaths.home(), "relay-state.json"]);

	function writeState(now:Float):Void {
		// Activity times change with every frame; the file is rewritten when clients come or go, and every 30 s.
		var text = revision();
		if (text == writtenState && now - writtenAt < STATE_REFRESH_SECONDS)
			return;
		try {
			var hosts = views();
			if (hosts.length == 0 && writtenState == "") {
				writtenAt = now;
				return;
			}
			AtomicFile.write(statePath(), Json.stringify({version: 1, pid: Sys.getPid(), updatedAt: now, hosts: hosts}) + "\n");
			writtenState = text;
			writtenAt = now;
		} catch (_:Dynamic) {}
	}

	public function dispose():Void {
		for (bridge in bridges)
			bridge.dispose();
		bridges.resize(0);
		for (item in refused)
			item.transport.close();
		refused.resize(0);
		try if (FileSystem.exists(statePath())) FileSystem.deleteFile(statePath()) catch (_:Dynamic) {}
	}

	/**
		The hosted workspaces as the CLI sees them: the running daemon's live view, its published state, or,
		when suit is not running, the host records (shown as not hosted, or paused).
	**/
	public static function readViews():Array<SuitRelayHostView> {
		try {
			var reply:Dynamic = SuitControl.request({op: "relay-state"}, 1);
			var hosts:Dynamic = reply == null ? null : Reflect.field(reply, "hosts");
			if (Std.isOfType(hosts, Array))
				return [for (item in (hosts : Array<Dynamic>)) viewOf(item)];
		} catch (_:Dynamic) {}
		try {
			var path = statePath();
			if (FileSystem.exists(path)) {
				var state:Dynamic = Json.parse(File.getContent(path));
				var updatedAt = SuitRecords.floatField(state, "updatedAt");
				var listed:Dynamic = Reflect.field(state, "hosts");
				if (updatedAt != null && Sys.time() - updatedAt < STATE_FRESH_SECONDS && Std.isOfType(listed, Array))
					return [for (item in (listed : Array<Dynamic>)) viewOf(item)];
			}
		} catch (_:Dynamic) {}
		var result:Array<SuitRelayHostView> = [];
		for (host in SuitRelayHosts.load()) {
			var paused = SuitRelayHosts.isPaused(host.stateDir);
			result.push({
				root: host.root, stateDir: host.stateDir, machineId: host.machineId, origin: host.origin,
				state: paused ? "paused" : "not hosted", error: paused ? null : "suit is not running",
				serviceRunning: false, servicePid: 0, starts: 0, clients: [], open: null
			});
		}
		return result;
	}

	static function viewOf(item:Dynamic):SuitRelayHostView {
		var pid = SuitRecords.intField(item, "servicePid"), starts = SuitRecords.intField(item, "starts");
		var open:Dynamic = Reflect.field(item, "open");
		var terminals = open == null ? null : SuitRecords.intField(open, "terminals");
		var agents = open == null ? null : SuitRecords.intField(open, "agents");
		var parsedOpen:Null<SuitRelayOpen> = open == null ? null : {terminals: terminals == null ? 0 : terminals, agents: agents == null ? 0 : agents};
		return {
			root: SuitRecords.stringField(item, "root"),
			stateDir: SuitRecords.stringField(item, "stateDir"),
			machineId: SuitRecords.stringField(item, "machineId"),
			origin: SuitRecords.stringField(item, "origin"),
			state: SuitRecords.stringField(item, "state"),
			error: SuitRecords.stringField(item, "error"),
			serviceRunning: Reflect.field(item, "serviceRunning") == true,
			servicePid: pid == null ? 0 : pid,
			starts: starts == null ? 0 : starts,
			clients: clientsOf(Reflect.field(item, "clients")),
			open: parsedOpen
		};
	}

	static function clientsOf(value:Dynamic):Array<SuitRelayClientView> {
		var result:Array<SuitRelayClientView> = [];
		if (!Std.isOfType(value, Array))
			return result;
		for (item in (value : Array<Dynamic>)) {
			var listed:Dynamic = Reflect.field(item, "grants");
			var framesIn = SuitRecords.intField(item, "framesIn"), framesOut = SuitRecords.intField(item, "framesOut");
			var connectedAt = SuitRecords.floatField(item, "connectedAt"), lastActivity = SuitRecords.floatField(item, "lastActivity");
			var route = SuitRecords.stringField(item, "route");
			result.push({
				id: SuitRecords.stringField(item, "id"),
				kind: SuitRecords.stringField(item, "kind"),
				connectedAt: connectedAt == null ? 0 : connectedAt,
				lastActivity: lastActivity == null ? 0 : lastActivity,
				framesIn: framesIn == null ? 0 : framesIn,
				framesOut: framesOut == null ? 0 : framesOut,
				grants: Std.isOfType(listed, Array) ? [for (grant in (listed : Array<Dynamic>)) Std.string(grant)] : [],
				route: route == null ? "suit" : route
			});
		}
		return result;
	}
}
