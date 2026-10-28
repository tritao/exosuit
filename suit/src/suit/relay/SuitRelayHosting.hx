package suit.relay;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.NativeKitEvents;
import sys.FileSystem;
import suit.SuitInventory;
import suit.SuitPaths;
import suit.relay.SuitRelayBridge.SuitRelayHostView;
import suit.relay.SuitRelayHosts.SuitRelayHost;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;
import suit.SuitRecord.SuitRecords;

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

	/** Hosted and not paused: suit must stay up for these. */
	public function hostingCount():Int {
		var count = 0;
		for (bridge in bridges)
			if (!bridge.paused)
				count++;
		return count;
	}

	public function busy():Bool {
		for (bridge in bridges)
			if (bridge.busy())
				return true;
		return refused.length > 0;
	}

	/** A daemon's `relay-attach`: validated, recorded, and its link handed to the workspace's bridge. */
	public function attach(transport:NativeRpcTransport, request:Dynamic):Void {
		var host:SuitRelayHost;
		try {
			host = SuitRelayHosts.validate(request);
			var stored = WorkspaceCredentialStores.relay().read(WorkspaceCredentialStores.machineAccount(SuitRelayHosts.endpoint(host)));
			if (stored == null)
				throw "relay_credential_missing";
			for (index in 0...stored.length)
				stored.set(index, 0);
			SuitRelayHosts.save(host);
		} catch (error:Dynamic) {
			var reason = Std.string(error);
			if (reason == "hosting_paused")
				pauseBridges(SuitRecords.stringField(request, "machineId"));
			transport.send(Bytes.ofString(Json.stringify({ok: false, error: reason})));
			refused.push({transport: transport, until: Sys.time() + 2});
			return;
		}
		var bridge = find(host.machineId);
		if (bridge == null) {
			bridge = new SuitRelayBridge(events, hub, host, false);
			bridges.push(bridge);
		} else if (bridge.paused)
			bridge.resume();
		var pid = SuitRecords.intField(request, "pid");
		bridge.attach(transport, pid == null ? 0 : pid, host);
		writtenAt = -1e9;
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

	/** Pauses hosting for the matching workspaces (all when `query` is null); returns the roots paused. */
	public function pause(query:Null<String>):Array<String> {
		var roots:Array<String> = [];
		for (bridge in bridges)
			if (SuitRelayHosts.matches(bridge.host, query)) {
				SuitRelayHosts.setPaused(bridge.host.stateDir, true);
				bridge.pause();
				roots.push(bridge.host.root);
			}
		writtenAt = -1e9;
		return roots;
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

	/** Control requests from the CLI: `relay-pause` and `relay-resume` with an optional `workspace`. Null for other ops. */
	public function handle(request:Dynamic):Null<Dynamic> {
		var workspace = SuitRecords.stringField(request, "workspace");
		switch SuitRecords.stringField(request, "op") {
			case "relay-pause":
				return {ok: true, roots: pause(workspace)};
			case "relay-resume":
				return {ok: true, roots: resume(workspace)};
			case "relay-state":
				return {ok: true, hosts: views()};
			case "relay-disconnect":
				var client = SuitRecords.stringField(request, "client");
				if (client == null)
					return {ok: false, error: "client required"};
				for (bridge in bridges) {
					var id = bridge.disconnect(client);
					if (id != null) {
						writtenAt = -1e9;
						return {ok: true, client: id, root: bridge.host.root};
					}
				}
				return {ok: false, error: 'no connected client matches $client (see `suit relay list`)'};
			default:
				return null;
		}
	}

	public function views():Array<SuitRelayHostView>
		return [for (bridge in bridges) bridge.view()];

	/** Changes whenever a client connects or goes, or hosting state changes; the daemon updates the tray then. */
	public function revision():String {
		var parts:Array<String> = [];
		for (bridge in bridges)
			parts.push(bridge.view().state + "/" + bridge.clients.revision + "/" + bridge.attached());
		return parts.join(",");
	}

	/** For the tooltip: "Hosting · 2 devices connected", or "" when nothing is hosted. */
	public function summary():String {
		var hosted = hostingCount();
		if (hosted == 0)
			return "";
		var connected = 0;
		for (bridge in bridges)
			if (!bridge.paused)
				connected += bridge.clients.count();
		return "Hosting" + (hosted > 1 ? " " + hosted + " workspaces" : "") + " · "
			+ (connected == 1 ? "1 device connected" : connected + " devices connected");
	}

	function pauseBridges(machineId:Null<String>):Void {
		var bridge = machineId == null ? null : find(machineId);
		if (bridge != null && !bridge.paused)
			bridge.pause();
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
		var hosts = views();
		// Activity times change with every frame; the file is rewritten when clients come or go, and every 30 s.
		var text = revision();
		if (text == writtenState && now - writtenAt < STATE_REFRESH_SECONDS)
			return;
		try {
			if (hosts.length == 0 && writtenState == "") {
				writtenAt = now;
				return;
			}
			sys.io.AtomicFile.write(statePath(), Json.stringify({version: 1, pid: Sys.getPid(), updatedAt: now, hosts: hosts}) + "\n");
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
		The hosted workspaces as the CLI sees them: the running daemon's published state, or, when suit is
		not running, the host records (shown as not hosted, or paused).
	**/
	public static function readViews():Array<SuitRelayHostView> {
		// The running daemon's live view first: it has current activity times.
		try {
			var reply:Dynamic = suit.SuitControl.request({op: "relay-state"}, 1);
			var hosts:Dynamic = reply == null ? null : Reflect.field(reply, "hosts");
			if (Std.isOfType(hosts, Array))
				return [for (item in (hosts : Array<Dynamic>)) viewOf(item)];
		} catch (_:Dynamic) {}
		try {
			var path = statePath();
			if (FileSystem.exists(path)) {
				var state:Dynamic = Json.parse(sys.io.File.getContent(path));
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
			open: Reflect.field(item, "open")
		};
	}

	static function clientsOf(value:Dynamic):Array<suit.relay.SuitRelayClients.SuitRelayClientView> {
		var result:Array<suit.relay.SuitRelayClients.SuitRelayClientView> = [];
		if (!Std.isOfType(value, Array))
			return result;
		for (item in (value : Array<Dynamic>)) {
			var listed:Dynamic = Reflect.field(item, "grants");
			var framesIn = SuitRecords.intField(item, "framesIn"), framesOut = SuitRecords.intField(item, "framesOut");
			var connectedAt = SuitRecords.floatField(item, "connectedAt"), lastActivity = SuitRecords.floatField(item, "lastActivity");
			result.push({
				id: SuitRecords.stringField(item, "id"),
				kind: SuitRecords.stringField(item, "kind"),
				connectedAt: connectedAt == null ? 0 : connectedAt,
				lastActivity: lastActivity == null ? 0 : lastActivity,
				framesIn: framesIn == null ? 0 : framesIn,
				framesOut: framesOut == null ? 0 : framesOut,
				grants: Std.isOfType(listed, Array) ? [for (grant in (listed : Array<Dynamic>)) Std.string(grant)] : []
			});
		}
		return result;
	}
}
