package workspace.client;

import haxeon.platform.event.EventPump;
import haxeon.rpc.RpcConnector;
import workspace.transport.NativeRpcConnector;
import workspace.transport.NativeRpcHub;

/** A workspace service suit reports, as the pool needs it. */
typedef WatchedService = {
	var workspace:String;
	var endpoint:String;
	var pid:Int;
	var running:Bool;
}

/** A watch that ended by itself: when the pool may try its service again, and how long the last wait was. */
private typedef Blocked = {
	var until:Float;
	var delay:Float;
	var identity:String;
}

/**
	The window's catalog connections (M19 Phase 6): one WorkspaceCatalogWatch for every workspace whose service suit
	says is running, except the one the window is attached to with its full client. `sync` follows suit's list: it
	connects to a service that started, reconnects to one that restarted (another pid or endpoint), and unwatches and
	drops one that stopped. Connections carry catalogs only: no session or terminal content.

	When a watch is dropped its last complete copy is kept, per workspace, until a new watch finishes its first read or
	the workspace leaves the machine, so rows do not vanish while a service restarts or the window is attached
	elsewhere. A watch that ends by itself (the service refused it) is not recreated at once: the workspace waits 1 s,
	doubling to 30 s, and starts over when its watch goes live or its service changes.
**/
class WorkspaceConnections {
	/** The most catalog connections one window holds; a machine with more workspaces running leaves the rest idle. */
	public static inline final LIMIT = 64;
	static inline final BLOCK_MIN = 1000.0;
	static inline final BLOCK_MAX = 30000.0;
	static inline final WINDOWS_PIPE = "\\\\.\\pipe\\exosuit-";
	static inline final UNIX_SOCKET = "agent.sock";

	final connect:String->RpcConnector;
	final clock:Void->Float;
	final random:Void->Float;
	final watches:Map<String, WorkspaceCatalogWatch> = [];
	final identities:Map<String, String> = [];
	final kept:Map<String, WorkspaceCatalogMirror> = [];
	final blocked:Map<String, Blocked> = [];
	/** Dropped watches whose UNWATCH is still on its way out. */
	final retiring:Array<WorkspaceCatalogWatch> = [];
	var disposed = false;
	var structure = 0;
	var machine = "";
	var hub:Null<NativeRpcHub>;
	var lastServices:Array<WatchedService> = [];
	var lastAttached:Null<String>;
	var lastWorkspaces:Null<Array<String>>;

	/** `connect` makes a connector for a service endpoint; the native pool uses `WorkspaceConnections.native`. */
	public function new(connect:String->RpcConnector, clock:Void->Float, ?random:Void->Float) {
		this.connect = connect;
		this.clock = clock;
		this.random = random == null ? function() return Math.random() : random;
	}

	/** The pool a window uses: local pipes and sockets through one NativeRpcHub. */
	public static function native(events:EventPump, clock:Void->Float):WorkspaceConnections {
		var hub = new NativeRpcHub(events);
		var pool = new WorkspaceConnections(function(endpoint) return new NativeRpcConnector(hub, NativeRpcHub.local(endpoint)), clock);
		pool.hub = hub;
		return pool;
	}

	/**
		Whether `endpoint` has the shape the agent gives its service (AgentManager): a named pipe `\\.\pipe\exosuit-<key>` on
		Windows, else `<state folder>/agent.sock`. Suit's reply is data from another process, so a window connects to
		nothing else.
	**/
	public static function validEndpoint(endpoint:String, windows:Bool = true):Bool {
		if (endpoint.length == 0 || endpoint.length > 1024 || endpoint.indexOf("\n") >= 0)
			return false;
		if (windows) {
			if (!StringTools.startsWith(endpoint, WINDOWS_PIPE) || endpoint.length == WINDOWS_PIPE.length)
				return false;
			for (index in WINDOWS_PIPE.length...endpoint.length) {
				var code = StringTools.fastCodeAt(endpoint, index);
				var plain = code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 45 || code == 95;
				if (!plain)
					return false;
			}
			return true;
		}
		if (!StringTools.startsWith(endpoint, "/") || !StringTools.endsWith(endpoint, "/" + UNIX_SOCKET))
			return false;
		return endpoint.split("/").indexOf("..") < 0;
	}

	static function platformEndpoint(endpoint:String):Bool
		return validEndpoint(endpoint, Sys.systemName() == "Windows");

	/**
		Follows suit's list for machine `machineId`. `services` holds the workspaces suit reports a service for;
		`attached` is the workspace this window attaches to with its own client, which needs no second connection;
		`workspaces`, when given, is every workspace on the machine, so a kept copy of one that is gone can go.
	**/
	public function sync(machineId:String, services:Array<WatchedService>, attached:Null<String>, ?workspaces:Array<String>):Void {
		if (disposed)
			return;
		if (machineId != machine) {
			for (id in [for (key in watches.keys()) key])
				drop(id);
			kept.clear();
			blocked.clear();
			machine = machineId;
			structure++;
		}
		lastServices = services;
		lastAttached = attached;
		lastWorkspaces = workspaces;
		reconcile();
	}

	function reconcile():Void {
		if (workspacesKnown()) {
			var known = lastWorkspaces;
			if (known != null)
				for (id in [for (key in kept.keys()) key])
					if (known.indexOf(id) < 0) {
						kept.remove(id);
						structure++;
					}
		}
		var wanted:Map<String, WatchedService> = [];
		for (service in lastServices)
			if (service.running && service.workspace != lastAttached && platformEndpoint(service.endpoint))
				wanted.set(service.workspace, service);
		for (id in [for (key in blocked.keys()) key]) {
			var service = wanted.get(id), entry = blocked.get(id);
			if (service == null || entry == null || entry.identity != identity(service))
				blocked.remove(id);
		}
		for (id in [for (key in watches.keys()) key]) {
			var service = wanted.get(id), watch = watches.get(id);
			if (service == null || watch == null || identities.get(id) != identity(service))
				drop(id);
			else if (watch.ended())
				endedByItself(id, identity(service));
		}
		var count = Lambda.count(watches);
		var now = clock();
		for (id => service in wanted) {
			if (watches.exists(id) || count >= LIMIT)
				continue;
			var wait = blocked.get(id);
			if (wait != null && now < wait.until)
				continue;
			watches.set(id, new WorkspaceCatalogWatch({machine: machine, workspace: id}, connect(service.endpoint), clock, random));
			identities.set(id, identity(service));
			count++;
			structure++;
		}
	}

	function workspacesKnown():Bool
		return lastWorkspaces != null;

	static function identity(service:WatchedService):String
		return service.endpoint + "\n" + service.pid;

	/** A watch the service refused: drop it, and wait before trying that service again. */
	function endedByItself(id:String, identity:String):Void {
		var before = blocked.get(id);
		var delay = before == null ? BLOCK_MIN : Math.min(BLOCK_MAX, before.delay * 2);
		drop(id);
		blocked.set(id, {until: clock() + delay, delay: delay, identity: identity});
	}

	function drop(id:String):Void {
		var watch = watches.get(id);
		watches.remove(id);
		identities.remove(id);
		// The revision never repeats: a dropped watch's own count stays in the total.
		structure += 1 + (watch == null ? 0 : watch.revision);
		if (watch != null) {
			if (watch.mirror.token != null)
				kept.set(id, watch.mirror);
			watch.dispose();
			retiring.push(watch);
		}
	}

	/** The workspace's watch, if the pool holds one. */
	public function watchOf(workspace:String):Null<WorkspaceCatalogWatch>
		return watches.get(workspace);

	/**
		The workspace's catalog: its watch's copy once that has read, else the copy kept from the last watch (null if none).
		A copy that is not from a live watch is stale: show it as reconnecting.
	**/
	public function mirrorOf(workspace:String):Null<WorkspaceCatalogMirror> {
		var watch = watches.get(workspace);
		if (watch != null && watch.mirror.token != null)
			return watch.mirror;
		return kept.get(workspace);
	}

	/** Dropped watches still waiting for their UNWATCH to be answered. */
	public function retiringCount():Int
		return retiring.length;

	/** Connections held now. */
	public function count():Int
		return Lambda.count(watches);

	/** Connections that are open with a complete copy. */
	public function liveCount():Int {
		var live = 0;
		for (watch in watches)
			if (watch.live)
				live++;
		return live;
	}

	/**
		True while a watch is starting or reconnecting and young: ask suit again soon. A watch that has been down longer,
		or ended, does not count, so one dead service cannot keep the window polling fast.
	**/
	public function anyDown():Bool {
		for (watch in watches)
			if (watch.trying())
				return true;
		return false;
	}

	/** Changes whenever the set of watches, a kept copy or any watch's copy does. */
	public function revision():Int {
		var total = structure;
		for (watch in watches)
			total += watch.revision;
		return total;
	}

	public function poll():Void {
		if (disposed)
			return;
		var retry = false;
		var now = clock();
		var index = retiring.length;
		while (index > 0) {
			index--;
			if (retiring[index].drain())
				retiring.splice(index, 1);
		}
		for (id => watch in watches) {
			watch.poll();
			if (watch.mirror.token != null && kept.exists(id)) {
				kept.remove(id);
				structure++;
			}
			if (watch.live && blocked.exists(id))
				blocked.remove(id);
			if (watch.ended())
				retry = true;
		}
		var room = Lambda.count(watches) < LIMIT;
		if (room)
			for (id => wait in blocked)
				if (now >= wait.until && !watches.exists(id))
					retry = true;
		if (retry)
			reconcile();
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		for (id in [for (key in watches.keys()) key])
			drop(id);
		kept.clear();
		for (watch in retiring)
			watch.drain();
		retiring.resize(0);
		var owned = hub;
		if (owned != null)
			owned.dispose();
	}
}
