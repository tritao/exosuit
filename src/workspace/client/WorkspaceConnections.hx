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

/**
	The window's catalog connections (M19 Phase 6): one WorkspaceCatalogWatch for every workspace whose service suit
	says is running, except the one the window is attached to with its full client. `sync` follows suit's list: it
	connects to a service that started, reconnects to one that restarted (another pid or endpoint), and unwatches and
	drops one that stopped. Connections carry catalogs only: no session or terminal content.
**/
class WorkspaceConnections {
	/** The most catalog connections one window holds; a machine with more workspaces running leaves the rest idle. */
	public static inline final LIMIT = 64;

	final connect:String->RpcConnector;
	final clock:Void->Float;
	final random:Void->Float;
	final watches:Map<String, WorkspaceCatalogWatch> = [];
	final identities:Map<String, String> = [];
	var disposed = false;
	var structure = 0;
	var machine = "";
	var hub:Null<NativeRpcHub>;

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
		Follows suit's list for machine `machineId`. `services` holds the workspaces suit reports a service for;
		`attached` is the workspace this window attaches to with its own client, which needs no second connection.
	**/
	public function sync(machineId:String, services:Array<WatchedService>, attached:Null<String>):Void {
		if (disposed)
			return;
		if (machineId != machine) {
			for (id in [for (key in watches.keys()) key])
				drop(id);
			machine = machineId;
		}
		var wanted:Map<String, WatchedService> = [];
		for (service in services)
			if (service.running && service.workspace != attached && service.endpoint.length > 0)
				wanted.set(service.workspace, service);
		for (id in [for (key in watches.keys()) key]) {
			var service = wanted.get(id), watch = watches.get(id);
			if (service == null || watch == null || identities.get(id) != identity(service) || watch.ended())
				drop(id);
		}
		var count = Lambda.count(watches);
		for (id => service in wanted) {
			if (watches.exists(id) || count >= LIMIT)
				continue;
			watches.set(id, new WorkspaceCatalogWatch({machine: machine, workspace: id}, connect(service.endpoint), clock, random));
			identities.set(id, identity(service));
			count++;
			structure++;
		}
	}

	static function identity(service:WatchedService):String
		return service.endpoint + "\n" + service.pid;

	function drop(id:String):Void {
		var watch = watches.get(id);
		watches.remove(id);
		identities.remove(id);
		// The revision never repeats: a dropped watch's own count stays in the total.
		structure += 1 + (watch == null ? 0 : watch.revision);
		if (watch != null)
			watch.dispose();
	}

	/** The workspace's watch, if the pool holds one. */
	public function watchOf(workspace:String):Null<WorkspaceCatalogWatch>
		return watches.get(workspace);

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

	/** True when a connection is down while suit still lists its service: ask suit again soon. */
	public function anyDown():Bool {
		for (watch in watches)
			if (!watch.live)
				return true;
		return false;
	}

	/** Changes whenever the set of watches or any watch's copy does. */
	public function revision():Int {
		var total = structure;
		for (watch in watches)
			total += watch.revision;
		return total;
	}

	public function poll():Void {
		if (disposed)
			return;
		for (watch in watches)
			watch.poll();
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		for (id in [for (key in watches.keys()) key])
			drop(id);
		var owned = hub;
		if (owned != null)
			owned.dispose();
	}
}
