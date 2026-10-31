package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import workspace.client.WorkspaceCatalogMirror;
import workspace.client.WorkspaceCatalogWatch;
import workspace.client.WorkspaceConnections;
import workspace.client.WorkspaceServiceTarget;
import workspace.client.WorkspaceStarter;
import workspace.client.WorkspaceStarter.StartedProcess;
import workspace.client.WorkspaceConnections.WatchedService;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogChange;
import workspace.service.WorkspaceCatalogProtocol.CatalogQuery;
import workspace.service.WorkspaceCatalogProtocol.CatalogSession;
import workspace.service.WorkspaceCatalogProtocol.CatalogTerminal;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

private class FakeStarted implements StartedProcess {
	public var alive = true;
	public var code = 0;
	public var released = false;

	public function new() {}

	public function running():Bool return alive;

	public function exitStatus():Int return code;

	public function readStdout():String return "";

	public function readStderr():String return "";

	public function release():Void released = true;
}

private class NoAttempt implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

/** A workspace service's catalog end, answering CATALOG and UNWATCH the way docs/roadmap/RPC-VECTORS.md says. */
private class FakeService {
	public final id:String;
	public var instance:String;
	public var up = true;
	public var resets = 0;
	public var deltas = 0;
	public var pageSize = 3;
	public var changedSent = 0;
	/** "repeat": more pages that never move the token; "endless": more pages forever; "huge": pages of thousands of sessions. */
	public var misbehave = "";
	/** The next this many CATALOG calls fail. */
	public var failNext = 0;
	public var refuseWatch = false;
	/** The application name the service answers the handshake with; another one makes the watch end. */
	public var application = "exosuit-agent/1";
	public var requests = 0;
	/** UNWATCH calls received. */
	public var unwatched = 0;
	/** UNWATCH is received but never answered. */
	public var silentUnwatch = false;
	var generated = 0;
	/** What an unwatch or disconnect leaves: connections registered for CHANGED. */
	public final watchers:Array<RpcConnection> = [];
	public var connections(default, null):Int = 0;
	final clock:Void->Float;
	final groups:Map<String, WorkspaceGroup> = [];
	final sessions:Map<String, CatalogSession> = [];
	final terminals:Map<String, CatalogTerminal> = [];
	final log:Array<{version:Int, kind:String, id:String, removed:Bool}> = [];
	final handshakes:Array<{handshake:RpcHandshake, transport:MemoryTransport}> = [];
	final open:Array<{connection:RpcConnection, transport:MemoryTransport}> = [];
	var version = 0;
	var dirty = false;

	public function new(id:String, instance:String, clock:Void->Float) {
		this.id = id;
		this.instance = instance;
		this.clock = clock;
	}

	function token():String
		return "v:" + instance + ":" + version;

	function record(kind:String, key:String, removed:Bool):Void {
		version++;
		log.push({version: version, kind: kind, id: key, removed: removed});
		dirty = true;
	}

	public function addGroup(key:String, name:String, ?parent:String):Void {
		groups.set(key, {id: key, name: name, cwd: null, revision: 1, parent: parent, order: 0});
		record("g", key, false);
	}

	public function addSession(key:String, name:String, group:String = ""):Void {
		sessions.set(key, {id: key, name: name, group: group, directory: "/w/" + id, provider: null, state: "idle", attention: 0});
		record("s", key, false);
	}

	public function removeSession(key:String):Void {
		sessions.remove(key);
		record("s", key, true);
	}

	public function addTerminal(key:String, name:String, group:String = ""):Void {
		terminals.set(key, {id: key, name: name, group: group, directory: "/w/" + id, state: "running", exitCode: 0, available: true,
			revision: haxe.Int64.ofInt(1), agentProvider: null, attention: 0});
		record("t", key, false);
	}

	public function accept(transport:MemoryTransport):Void {
		connections++;
		// The watch asks for the catalog plus the three read grants (WorkspaceCatalogWatch), and a service that lacks one refuses it.
		var granted = [WorkspaceCatalogProtocol.CAPABILITY, workspace.service.WorkspaceProtocol.READ, workspace.service.WorkspaceAgentProtocol.READ, workspace.service.WorkspaceTerminalProtocol.READ];
		var options = new RpcPeerOptions(application, granted, [], 2000, 262144, 8, 1048576);
		handshakes.push({handshake: RpcHandshake.server(transport, clock, options), transport: transport});
	}

	/** Takes the service down: every connection closes, as a killed process's would. */
	public function kill():Void {
		up = false;
		for (entry in handshakes.concat([])) entry.transport.close();
		for (entry in open) entry.transport.close();
		handshakes.resize(0);
		open.resize(0);
		watchers.resize(0);
	}

	/** Starts again as a new instance: tokens of the old one are unknown, the work is what was stored. */
	public function restart(next:String):Void {
		instance = next;
		version = 0;
		log.resize(0);
		up = true;
	}

	function setup(connection:RpcConnection):Void {
		connection.register(WorkspaceCatalogProtocol.CATALOG, function(query:CatalogQuery, context) {
			if (query.ref.workspace != id) {
				context.fail({code: "unknown_workspace", message: "unknown_workspace", ambiguous: false});
				return;
			}
			if (failNext > 0) {
				failNext--;
				requests++;
				context.fail({code: "boom", message: "boom", ambiguous: false});
				return;
			}
			if (query.watch && !refuseWatch && watchers.indexOf(connection) < 0) watchers.push(connection);
			context.respond(page(query));
		});
		connection.register(WorkspaceCatalogProtocol.UNWATCH, function(ref:WorkspaceRef, context) {
			unwatched++;
			if (silentUnwatch) return;
			watchers.remove(connection);
			context.respond(ref);
		});
	}

	function page(query:CatalogQuery):WorkspaceCatalog {
		requests++;
		if (misbehave != "") {
			generated++;
			var odd = blank(query.resume == null, misbehave == "repeat" ? "c:stuck" : "c:" + generated);
			odd.more = true;
			if (misbehave == "huge")
				for (index in 0...2000)
					odd.sessions.push({id: "x" + generated + "-" + index, name: "n", group: "", directory: "/d", provider: null, state: "idle", attention: 0});
			return odd;
		}
		var resume = query.resume;
		var parts = resume == null ? [] : resume.split(":");
		if (parts.length == 3 && parts[0] == "v" && parts[1] == instance && Std.parseInt(parts[2]) != null && Std.parseInt(parts[2]) <= version)
			return delta(Std.parseInt(parts[2]));
		var offset = 0, snapshot = version;
		var continuing = parts.length == 4 && parts[0] == "c" && parts[1] == instance;
		if (continuing) {
			offset = Std.parseInt(parts[2]);
			snapshot = Std.parseInt(parts[3]);
		}
		return reset(offset, !continuing, snapshot);
	}

	function reset(offset:Int, first:Bool, snapshot:Int):WorkspaceCatalog {
		var items:Array<{kind:String, id:String}> = [];
		for (key in sortedKeys([for (key in groups.keys()) key])) items.push({kind: "g", id: key});
		for (key in sortedKeys([for (key in sessions.keys()) key])) items.push({kind: "s", id: key});
		for (key in sortedKeys([for (key in terminals.keys()) key])) items.push({kind: "t", id: key});
		if (first) resets++;
		var end = offset + pageSize;
		var more = end < items.length;
		var result = blank(first, more ? "c:" + instance + ":" + end + ":" + snapshot : "v:" + instance + ":" + snapshot);
		result.folders = first ? ["/w/" + id] : [];
		for (item in items.slice(offset, end)) fill(result, item.kind, item.id, false);
		return result;
	}

	function delta(from:Int):WorkspaceCatalog {
		deltas++;
		var result = blank(false, token());
		var seen:Map<String, Bool> = [];
		var index = log.length;
		while (index > 0) {
			index--;
			var entry = log[index];
			if (entry.version <= from) break;
			var key = entry.kind + entry.id;
			if (seen.exists(key)) continue;
			seen.set(key, true);
			fill(result, entry.kind, entry.id, entry.removed);
		}
		return result;
	}

	function fill(result:WorkspaceCatalog, kind:String, key:String, removed:Bool):Void {
		switch kind {
			case "g": if (removed) result.removedGroups.push(key) else result.groups.push(groups.get(key));
			case "s": if (removed) result.removedSessions.push(key) else result.sessions.push(sessions.get(key));
			default: if (removed) result.removedTerminals.push(key) else result.terminals.push(terminals.get(key));
		}
	}

	function blank(reset:Bool, token:String):WorkspaceCatalog
		return {ref: {machine: "m", workspace: id}, instance: instance, token: token, reset: reset, more: StringTools.startsWith(token, "c:"),
			name: "Workspace " + id, folders: [], scratch: null, status: "running", attention: 0, groups: [], sessions: [], terminals: [],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: !refuseWatch};

	static function sortedKeys(keys:Array<String>):Array<String> {
		keys.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
		return keys;
	}

	/** Moves handshakes and requests along, and sends CHANGED once for the changes since the last tick. */
	public function poll():Void {
		for (entry in handshakes.concat([])) {
			entry.handshake.poll();
			var connection = entry.handshake.connection;
			if (connection != null) {
				handshakes.remove(entry);
				setup(connection);
				open.push({connection: connection, transport: entry.transport});
			} else if (entry.handshake.isFinished()) handshakes.remove(entry);
		}
		for (entry in open.concat([])) {
			entry.connection.poll();
			if (!entry.connection.isOpen()) {
				open.remove(entry);
				watchers.remove(entry.connection);
			}
		}
		if (dirty && up) {
			dirty = false;
			for (watcher in watchers) {
				var change:CatalogChange = {ref: {machine: "m", workspace: id}, token: token()};
				if (watcher.notify(WorkspaceCatalogProtocol.CHANGED, change, WorkspaceCatalogProtocol.encodeChange)) changedSent++;
			}
		}
	}

	/** Tells watchers about the current token again, without a change. */
	public function repeat():Void {
		for (watcher in watchers) {
			var change:CatalogChange = {ref: {machine: "m", workspace: id}, token: token()};
			if (watcher.notify(WorkspaceCatalogProtocol.CHANGED, change, WorkspaceCatalogProtocol.encodeChange)) changedSent++;
		}
	}
}

private class Network {
	public final services:Map<String, FakeService> = [];
	public var opened = 0;

	public function new() {}

	public function connector(endpoint:String):RpcConnector
		return new Dial(this, endpoint);

	public function add(service:FakeService, endpoint:String):Void
		services.set(endpoint, service);
}

private class Dial implements RpcConnector {
	final network:Network;
	final endpoint:String;

	public function new(network:Network, endpoint:String) {
		this.network = network;
		this.endpoint = endpoint;
	}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		var service = network.services.get(endpoint);
		if (service == null || !service.up) {
			complete(Failed({code: "connect_failed", message: "connect_failed", ambiguous: false}, true));
			return new NoAttempt();
		}
		var pair = MemoryTransport.pair(262144, 64);
		network.opened++;
		service.accept(pair.server);
		complete(Opened(pair.client));
		return new NoAttempt();
	}
}

/** A window's pool against fake workspace services: the catalog follows other clients, kills and restarts. */
class WorkspaceCatalogTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static var now = 0.0;

	static function get(pool:WorkspaceConnections, id:String):WorkspaceCatalogWatch {
		var watch = pool.watchOf(id);
		if (watch == null) throw "no watch for " + id;
		return watch;
	}

	static function clock():Float
		return now;

	/** An endpoint in the shape the agent gives its service on this system. */
	static function ep(id:String):String
		return Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-" + id : "/tmp/exosuit-" + id + "/agent.sock";

	static function service(id:String, pid:Int, running:Bool = true):WatchedService
		return {workspace: id, endpoint: ep(id), pid: pid, running: running};

	static function pump(pool:WorkspaceConnections, services:Array<FakeService>, rounds:Int = 12):Void {
		for (round in 0...rounds) {
			pool.poll();
			for (fake in services) fake.poll();
		}
	}

	static function main():Void {
		mirrorOrder();
		bounds();
		bigWorkspace();
		unwatchNeverAnswered();
		starterQueue();
		hostileInput();
		changeDuringRead();
		changeDuringBackoff();
		endpoints();
		deadWatch();
		keptCopies();
		behaviour();
		measure();
	}

	/** Only the agent's own endpoint shapes are connected to. */
	static function endpoints():Void {
		var pipe = "\\\\.\\pipe\\exosuit-0123abcd-X_y";
		require(WorkspaceConnections.validEndpoint(pipe, true), "the agent's pipe name is valid");
		require(!WorkspaceConnections.validEndpoint("\\\\.\\pipe\\other", true) && !WorkspaceConnections.validEndpoint("\\\\.\\pipe\\exosuit-", true)
			&& !WorkspaceConnections.validEndpoint("\\\\.\\pipe\\exosuit-a\\b", true) && !WorkspaceConnections.validEndpoint("\\\\evil\\pipe\\exosuit-a", true)
			&& !WorkspaceConnections.validEndpoint("C:\\x\\agent.sock", true), "other pipes and paths are refused on Windows");
		require(WorkspaceConnections.validEndpoint("/home/u/state/workspaces/w1/agent.sock", false), "the agent's socket path is valid");
		require(!WorkspaceConnections.validEndpoint("agent.sock", false) && !WorkspaceConnections.validEndpoint("/tmp/other.sock", false)
			&& !WorkspaceConnections.validEndpoint("/tmp/../etc/agent.sock", false) && !WorkspaceConnections.validEndpoint("", false), "other sockets are refused");
		var network = new Network();
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", [{workspace: "A", endpoint: "/etc/passwd", pid: 1, running: true}], null);
		require(pool.count() == 0 && network.opened == 0, "an endpoint of another shape is never dialed");
		pool.dispose();
		print("PASS: only the agent's pipe and socket shapes are connected to");
	}

	/** A watch that ends by itself waits, doubling, before its service is tried again, and does not keep the window polling fast. */
	static function deadWatch():Void {
		var network = new Network();
		var d = new FakeService("D", "id", clock);
		d.application = "not-the-agent/1";
		network.add(d, ep("D"));
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		var list = [service("D", 1)];
		pool.sync("m", list, null);
		pump(pool, [d], 20);
		require(pool.count() == 0 && network.opened == 1 && !pool.anyDown(), "an ended watch is dropped and does not count as down");
		pump(pool, [d], 20);
		require(network.opened == 1, "and it is not dialed again at once");
		now += 1100;
		pump(pool, [d], 20);
		require(network.opened == 2 && pool.count() == 0, "tried again after a second");
		now += 1500;
		pump(pool, [d], 20);
		require(network.opened == 2, "the second wait is longer");
		now += 600;
		pump(pool, [d], 20);
		require(network.opened == 3, "two seconds");
		// A restarted service (another pid) is new information: it is tried at once.
		pool.sync("m", [service("D", 2)], null);
		pump(pool, [d], 20);
		require(network.opened == 4, "a new pid is not held back");
		// A service that behaves goes live, and the waits start over.
		d.application = "exosuit-agent/1";
		now += 1100;
		pump(pool, [d], 40);
		require(pool.count() == 1 && pool.liveCount() == 1, "it recovers");
		// A watch that stays down long enough no longer asks for fast refreshes.
		var slow = new FakeService("S", "is", clock);
		slow.up = false;
		network.add(slow, ep("S"));
		pool.sync("m", [service("D", 2), service("S", 1)], null);
		pump(pool, [slow, d], 10);
		require(pool.anyDown(), "a young watch that is down asks for fast refreshes");
		now += 20000;
		pump(pool, [slow, d], 10);
		require(!pool.anyDown(), "an old one does not");
		pool.dispose();
		print("PASS: a watch that ends waits 1 s, 2 s, ... before its service is dialed again; dead watches do not keep the window refreshing");
	}

	/** The last copy stays while a service restarts or the window is attached elsewhere, until a new watch reads or the workspace is gone. */
	static function keptCopies():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.addSession("s1", "Kept");
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		var list = [service("A", 1)];
		pool.sync("m", list, null, ["A"]);
		pump(pool, [a]);
		require(pool.mirrorOf("A") != null && get(pool, "A").live, "live copy");
		// The window attaches to it: the watch goes, the copy stays.
		pool.sync("m", list, "A", ["A"]);
		var held = pool.mirrorOf("A");
		require(pool.watchOf("A") == null && held != null && held.sessions.exists("s1"), "the copy stays when the window attaches");
		// Detaching starts a new watch; the old copy shows until the new one has read.
		pool.sync("m", list, null, ["A"]);
		require(pool.mirrorOf("A") == held, "the old copy shows until the new watch has read");
		pump(pool, [a]);
		require(pool.mirrorOf("A") == get(pool, "A").mirror && pool.mirrorOf("A") != held, "then the new watch's copy replaces it");
		// A service stops and restarts: rows stay.
		a.kill();
		pump(pool, [a], 3);
		pool.sync("m", [service("A", 1, false)], null, ["A"]);
		require(pool.watchOf("A") == null && pool.mirrorOf("A") != null, "rows stay while the service is stopped");
		// The workspace leaves the machine.
		pool.sync("m", [], null, []);
		require(pool.mirrorOf("A") == null, "a workspace that left the machine loses its copy");
		pool.dispose();
		print("PASS: the last catalog copy is kept across restarts and attaching, and goes when a new watch reads or the workspace leaves");
	}

	/** A looping, oversized, failing or non-watching service is bounded, backed off and never read as live. */
	static function bounds():Void {
		var network = new Network();
		var x = new FakeService("X", "ix", clock);
		network.add(x, ep("X"));
		x.addSession("s", "One");
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", [service("X", 1)], null);

		x.misbehave = "repeat";
		pump(pool, [x], 60);
		var watch = get(pool, "X");
		require(!watch.live && watch.mirror.token == null && watch.reads == 2 && watch.error != null, "a more page that repeats its token is a failure: " + watch.reads + " " + watch.error);
		require(watch.retryDelay == 2000, "and the next retry waits longer: " + watch.retryDelay);

		x.misbehave = "endless";
		now += 1500;
		pump(pool, [x], 4000);
		require(!watch.live && watch.mirror.token == null && x.requests >= WorkspaceCatalogWatch.MAX_PAGES && x.requests <= WorkspaceCatalogWatch.MAX_PAGES + 2, "an endless catalog stops at the page cap: " + x.requests);
		require(watch.error != null && watch.error.indexOf("pages") >= 0, "page cap reason: " + watch.error);

		x.misbehave = "huge";
		now += 5000;
		pump(pool, [x], 200);
		require(!watch.live && watch.mirror.token == null && watch.error != null && watch.error.indexOf("items") >= 0, "an oversized catalog is refused: " + watch.error);

		// A well-behaved service recovers, and the delay starts over.
		x.misbehave = "";
		now += 40000;
		pump(pool, [x], 40);
		require(watch.live && watch.retryDelay == WorkspaceCatalogWatch.RETRY_MIN_MS && watch.mirror.sessions.exists("s"), "recovery resets the delay: " + watch.retryDelay);

		// Failed calls wait 1 s, 2 s, 4 s: each retry comes only after its delay.
		x.addSession("t", "Two");
		pump(pool, [x], 6);
		x.failNext = 3;
		var before = x.requests;
		watch.dispose();
		pool.sync("m", [], null);
		pool.sync("m", [service("X", 2)], null);
		var again = get(pool, "X");
		pump(pool, [x], 10);
		require(x.requests == before + 1 && again.retryDelay == 2000, "first failure waits a second: " + (x.requests - before));
		now += 900;
		pump(pool, [x], 10);
		require(x.requests == before + 1, "no retry before the delay");
		now += 200;
		pump(pool, [x], 10);
		require(x.requests == before + 2 && again.retryDelay == 4000, "second retry after two: " + again.retryDelay);
		now += 2100;
		pump(pool, [x], 10);
		now += 4100;
		pump(pool, [x], 20);
		require(again.live && again.retryDelay == WorkspaceCatalogWatch.RETRY_MIN_MS, "third failure then success");

		// A service that does not register the watch is not live.
		pool.sync("m", [], null);
		x.refuseWatch = true;
		pool.sync("m", [service("X", 3)], null);
		pump(pool, [x], 20);
		var unwatched = get(pool, "X");
		require(!unwatched.live && unwatched.mirror.sessions.exists("s") && unwatched.error != null, "watching:false is not live, though its data shows");
		pool.dispose();
		print("PASS: paged reads are capped, a stuck token fails, retries back off from 1 s and reset, and watching:false is not live");
	}

	/** A workspace of about two thousand items needs more than 64 pages and still finishes. */
	static function bigWorkspace():Void {
		require(WorkspaceCatalogWatch.MAX_PAGES * WorkspaceCatalogProtocol.PAGE_LIMIT >= WorkspaceCatalogWatch.MAX_ITEMS, "the page cap covers the item cap");
		var network = new Network();
		var big = new FakeService("Big", "ib", clock);
		big.pageSize = WorkspaceCatalogProtocol.PAGE_LIMIT;
		network.add(big, ep("Big"));
		for (index in 0...2000) big.addSession("s" + index, "Session " + index);
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", [service("Big", 1)], null);
		pump(pool, [big], 400);
		var watch = get(pool, "Big");
		require(watch.live && Lambda.count(watch.mirror.sessions) == 2000 && watch.reads > 64, "two thousand items over " + watch.reads + " pages: " + Lambda.count(watch.mirror.sessions) + " " + watch.error);
		pool.dispose();
		print("PASS: a catalog of 2000 items reads in " + watch.reads + " pages");
	}

	/** A change announced while pages are still coming is read afterwards. */
	static function changeDuringRead():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		a.pageSize = 1;
		network.add(a, ep("A"));
		for (index in 0...12) a.addSession("s" + index, "S" + index);
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", [service("A", 1)], null);
		var watch = get(pool, "A");
		var injected = false;
		for (round in 0...400) {
			pump(pool, [a], 1);
			if (!injected && watch.reads >= 2) {
				require(watch.mirror.token == null, "still reading");
				a.addGroup("0early", "Sorted before what was sent");
				injected = true;
			}
		}
		require(injected && watch.live && watch.mirror.groups.exists("0early") && Lambda.count(watch.mirror.sessions) == 12, "the change made during the read arrived: " + watch.error);
		pool.dispose();
		print("PASS: a CHANGED during a multi-page read is read after it");
	}

	/** CHANGED does not read before a failed read's delay is over. */
	static function changeDuringBackoff():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.addSession("s1", "One");
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", [service("A", 1)], null);
		pump(pool, [a]);
		var watch = get(pool, "A");
		require(watch.live, "live first");
		var before = a.requests;
		a.failNext = 1;
		a.addSession("u1", "Two");
		pump(pool, [a]);
		require(a.requests == before + 1 && watch.error != null, "the read failed");
		a.addSession("u2", "Three");
		pump(pool, [a]);
		require(a.requests == before + 1, "CHANGED waits for the delay: " + (a.requests - before));
		now += 1100;
		pump(pool, [a]);
		require(a.requests == before + 2 && watch.mirror.sessions.exists("u1") && watch.mirror.sessions.exists("u2") && watch.error == null, "then one read gets both");
		pool.dispose();
		print("PASS: CHANGED during a retry delay waits for the delay");
	}

	/** Names from a catalog are clipped, and repeated folders are kept once however many come. */
	static function hostileInput():Void {
		var mirror = new WorkspaceCatalogMirror();
		var long = StringTools.rpad("", "x", 5000);
		var folders = [for (index in 0...6000) "/f/" + (index % 3000)];
		mirror.apply({ref: {machine: "m", workspace: "W"}, instance: "i", token: "v:i:1", reset: true, more: false, name: long, folders: folders, scratch: null,
			status: "running", attention: 0, groups: [{id: "g", name: long, cwd: null, revision: 1, parent: null, order: 0}],
			sessions: [{id: "s", name: long, group: "", directory: "/d", provider: null, state: "idle", attention: 0}],
			terminals: [{id: "t", name: long, group: "", directory: "/d", state: "running", exitCode: 0, available: true, revision: haxe.Int64.ofInt(1),
				agentProvider: null, attention: 0}],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: true});
		require(mirror.folders.length == 3000, "repeated folders were kept once: " + mirror.folders.length);
		var limit = WorkspaceCatalogMirror.MAX_LABEL;
		var g = mirror.groups.get("g"), s = mirror.sessions.get("s"), t = mirror.terminals.get("t");
		if (g == null || s == null || t == null) throw "the items arrived";
		require(mirror.name.length == limit && g.name.length == limit && s.name.length == limit && t.name.length == limit, "long names are clipped to " + limit);
		var first = mirror.sessionList();
		require(mirror.sessionList() == first, "the sorted list is reused while the copy is unchanged");
		mirror.apply({ref: {machine: "m", workspace: "W"}, instance: "i", token: "v:i:2", reset: false, more: false, name: "W", folders: [], scratch: null,
			status: "running", attention: 0, groups: [], sessions: [], terminals: [], removedGroups: [], removedSessions: ["s"], removedTerminals: [], watching: true});
		require(mirror.sessionList() != first && mirror.sessionList().length == 0, "and rebuilt after a page");
		print("PASS: catalog names are clipped, folders deduplicated with a map, sorted lists cached per revision");
	}

	/** A dropped watch whose UNWATCH is never answered closes after the linger, and disposing the pool does not wait for it. */
	static function unwatchNeverAnswered():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.silentUnwatch = true;
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		var list = [service("A", 1)];
		pool.sync("m", list, null);
		pump(pool, [a]);
		require(get(pool, "A").live, "live first");
		pool.sync("m", list, "A");
		pump(pool, [a], 6);
		require(a.unwatched == 1 && pool.retiringCount() == 1, "UNWATCH was sent and waits for an answer: " + pool.retiringCount());
		now += WorkspaceCatalogWatch.LINGER_MS + 100;
		pump(pool, [a], 6);
		require(pool.retiringCount() == 0, "the watch closed without an answer");
		// Disposing the pool while one is outstanding returns at once.
		pool.sync("m", list, null);
		pump(pool, [a]);
		pool.sync("m", list, "A");
		pump(pool, [a], 4);
		require(pool.retiringCount() == 1, "a second unanswered UNWATCH");
		pool.dispose();
		print("PASS: an unanswered UNWATCH closes after the linger and never blocks the pool");
	}

	/** The starter launches two at a time, queues the rest, frees a slot on timeout, and drops a queued start on cancel. */
	static function starterQueue():Void {
		var clockNow = 0.0;
		var fakes:Array<FakeStarted> = [];
		var launched:Array<String> = [];
		var finished:Map<String, String> = [];
		var starter = new WorkspaceStarter(null, "launcher", function() return clockNow, null, function(target, root) {
			var fake = new FakeStarted();
			fakes.push(fake);
			launched.push(target.workspace);
			return fake;
		});
		var begin = function(id:String):Void {
			starter.start(WorkspaceServiceTarget.forWorkspace(id, ["."], null), function(failure) finished.set(id, failure == null ? "ok" : failure));
		};
		begin("a");
		begin("b");
		begin("c");
		starter.poll();
		require(launched.join(",") == "a,b" && starter.queued() == 1 && starter.starting("c"), "two launch, the third waits: " + launched + " " + finished);
		require(starter.cancel("c") && !starter.starting("c") && starter.queued() == 0 && finished.get("c") == "ok", "a queued start is dropped");
		require(!starter.cancel("a") && starter.starting("a"), "a launched start is not");
		begin("c");
		starter.poll();
		require(launched.length == 2 && starter.queued() == 1, "still two slots in use");
		fakes[0].alive = false;
		starter.poll();
		starter.poll();
		require(finished.get("a") == "ok" && fakes[0].released && launched.join(",") == "a,b,c", "a finished start frees its slot: " + launched);
		begin("d");
		starter.poll();
		require(launched.length == 3 && starter.queued() == 1, "d waits");
		clockNow += 96000;
		starter.poll();
		starter.poll();
		require(finished.get("b") != null && finished.get("b") != "ok" && finished.get("c") != "ok" && launched.join(",") == "a,b,c,d", "a start that times out frees its slot: " + launched + " " + finished);
		print("PASS: starts launch two at a time, queue, free slots on exit or timeout, and a queued one cancels");
	}

	/** A page that removes and upserts the same id leaves it present. */
	static function mirrorOrder():Void {
		var mirror = new WorkspaceCatalogMirror();
		var session:CatalogSession = {id: "s", name: "Again", group: "", directory: "/d", provider: null, state: "idle", attention: 0};
		var base:WorkspaceCatalog = {ref: {machine: "m", workspace: "W"}, instance: "i", token: "v:i:1", reset: true, more: false, name: "W", folders: [],
			scratch: null, status: "running", attention: 0, groups: [], sessions: [{id: "s", name: "First", group: "", directory: "/d", provider: null,
				state: "idle", attention: 0}], terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: true};
		mirror.apply(base);
		mirror.apply({ref: base.ref, instance: "i", token: "v:i:2", reset: false, more: false, name: "W", folders: [], scratch: null, status: "running",
			attention: 0, groups: [], sessions: [session], terminals: [], removedGroups: [], removedSessions: ["s"], removedTerminals: [], watching: true});
		var kept = mirror.sessions.get("s");
		require(kept != null && kept.name == "Again", "an id removed and re-added in one page survives");
		print("PASS: removals apply before upserts in one page");
	}

	static function behaviour():Void {
		var network = new Network();
		var a = new FakeService("A", "ia1", clock), b = new FakeService("B", "ib1", clock);
		network.add(a, ep("A"));
		network.add(b, ep("B"));
		a.addGroup("g1", "Work");
		a.addSession("s1", "Refactor", "g1");
		b.addTerminal("t1", "Shell");
		for (index in 0...6) b.addSession("b" + index, "Session " + index);
		var all = [a, b];
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);

		// Both running: the pool connects to each, pages the paged one, and the first copy is a reset.
		var list = [service("A", 1), service("B", 2)];
		pool.sync("m", list, null);
		pump(pool, all);
		require(pool.count() == 2 && pool.liveCount() == 2, "two live watches");
		var watchA = get(pool, "A"), watchB = get(pool, "B");
		require(watchA.mirror.sessions.exists("s1") && watchA.mirror.groups.exists("g1") && watchA.mirror.name == "Workspace A", "A's catalog arrived");
		require(Lambda.count(watchB.mirror.sessions) == 6 && watchB.mirror.terminals.exists("t1") && !watchB.mirror.partial, "B's seven items arrived over pages: " + Lambda.count(watchB.mirror.sessions));
		require(b.resets == 1 && watchB.reads == 3, "B was paged: " + watchB.reads + " pages");
		require(watchB.mirror.folders.length == 1 && watchB.mirror.folders[0] == "/w/B", "folders came in the reset");
		require(a.watchers.length == 1 && b.watchers.length == 1, "each service watches this connection");

		// A session another client creates shows up within one catalog event: one notification, one read.
		var before = watchA.reads, revision = pool.revision();
		a.addSession("s2", "Made elsewhere", "g1");
		pump(pool, all);
		require(a.changedSent == 1, "one CHANGED for one change");
		require(watchA.mirror.sessions.exists("s2") && watchA.reads == before + 1 && a.deltas == 1, "the new session arrived in one delta read");
		require(pool.revision() != revision, "the pool's revision moved");
		require(b.deltas == 0, "the other service was not read");

		// A hint whose token is ours causes no read.
		var reads = watchA.reads;
		a.repeat();
		pump(pool, all);
		require(watchA.reads == reads && watchA.skipped == 1, "a CHANGED with our token is skipped");

		// A removal arrives as a delta too.
		a.removeSession("s1");
		pump(pool, all);
		require(!watchA.mirror.sessions.exists("s1") && watchA.mirror.sessions.exists("s2"), "removal applied");

		// The window's attached workspace needs no second connection; leaving it brings it back.
		pool.sync("m", list, "B");
		require(pool.count() == 1 && pool.watchOf("B") == null, "the attached workspace is dropped from the pool");
		pump(pool, all);
		require(b.watchers.length == 0, "its service stopped watching this connection");
		require(b.unwatched == 1, "UNWATCH reached the service before the connection closed: " + b.unwatched);
		pool.sync("m", list, null);
		pump(pool, all);
		require(pool.count() == 2 && get(pool, "B").live && b.resets == 2, "it returns with a fresh reset");

		// A dropped connection reconnects with backoff and resumes from its token: no reset, only the delta.
		var resumed = a.resets;
		a.kill();
		a.up = true;
		pump(pool, all, 3);
		require(!get(pool, "A").live && pool.anyDown(), "a lost connection shows as not live");
		a.addSession("s3", "While away", "g1");
		now += 200;
		pump(pool, all);
		now += 400;
		pump(pool, all);
		require(get(pool, "A").live && get(pool, "A").mirror.sessions.exists("s3"), "reconnected and caught up");
		require(a.resets == resumed, "resumed from the token, with no reset: " + a.resets + " vs " + resumed);

		// Killing a service shows it idle: the watch is down, then suit says so and the pool drops it.
		a.kill();
		pump(pool, all, 3);
		require(!get(pool, "A").live, "the killed service's watch is not live");
		list = [service("A", 1, false), service("B", 2)];
		pool.sync("m", list, null);
		require(pool.count() == 1 && pool.watchOf("A") == null, "suit says stopped: the watch is dropped");
		pump(pool, all);
		require(get(pool, "B").live, "the other workspace is untouched");

		// Restarting brings it back, as a new instance with a reset.
		a.restart("ia2");
		list = [service("A", 9), service("B", 2)];
		pool.sync("m", list, null);
		pump(pool, all);
		var restored = pool.watchOf("A");
		require(restored != null && restored.live && restored.mirror.instance == "ia2" && restored.mirror.sessions.exists("s3"), "restarted service's catalog is back");
		require(pool.count() == 2, "both watched again");

		// A new pid at the same endpoint is a restart too: the old watch is replaced.
		list = [service("A", 10), service("B", 2)];
		pool.sync("m", list, null);
		require(pool.watchOf("A") != restored, "a new pid replaces the watch");
		pump(pool, all);
		require(get(pool, "A").live, "and it goes live");

		// A service suit has not reported running is never connected to.
		pool.sync("m", [service("A", 10, false), service("B", 2, false)], null);
		require(pool.count() == 0, "idle services have no connection");
		pump(pool, all);
		require(a.watchers.length == 0 && b.watchers.length == 0, "no watchers remain");
		pool.dispose();
		print("PASS: the pool follows suit's list; catalogs page, resume and update in one event; a killed service shows idle and a restart returns");
	}

	/** Ten workspaces of realistic size in one window: connections held and memory taken. */
	static function measure():Void {
		hl.Gc.major();
		var baseline = hl.Gc.heapBytes();
		var network = new Network();
		var fakes:Array<FakeService> = [];
		var list:Array<WatchedService> = [];
		for (index in 0...10) {
			var id = "W" + index;
			var fake = new FakeService(id, "i" + index, clock);
			fake.pageSize = 24;
			for (g in 0...6) fake.addGroup("g" + g, "Group " + g);
			for (s in 0...30) fake.addSession("s" + s, "Session number " + s, "g" + (s % 6));
			for (t in 0...12) fake.addTerminal("t" + t, "Terminal " + t, "g" + (t % 6));
			network.add(fake, ep(id));
			fakes.push(fake);
			list.push(service(id, index + 1));
		}
		hl.Gc.major();
		var servers = hl.Gc.heapBytes();
		var pool = new WorkspaceConnections(network.connector, clock, function() return 0.5);
		pool.sync("m", list, null);
		pump(pool, fakes, 30);
		require(pool.count() == 10 && pool.liveCount() == 10, "ten live watches: " + pool.liveCount());
		var items = 0;
		for (index in 0...10) {
			var mirror = get(pool, "W" + index).mirror;
			items += Lambda.count(mirror.sessions) + Lambda.count(mirror.terminals) + Lambda.count(mirror.groups);
		}
		hl.Gc.major();
		var held = hl.Gc.heapBytes();
		var perWatch = Std.int((held - servers) / 10);
		var opened = network.opened;
		// One change on one service reads one service.
		var reads = 0;
		for (index in 0...10) reads += get(pool, "W" + index).reads;
		fakes[3].addSession("late", "Late");
		pump(pool, fakes);
		var after = 0;
		for (index in 0...10) after += get(pool, "W" + index).reads;
		require(after == reads + 1, "one change cost one read across ten workspaces: " + (after - reads));
		pool.dispose();
		print("PASS: ten workspaces: " + pool.count() + " connections held after dispose, " + opened + " opened, " + items + " catalog items mirrored, "
			+ Std.int(perWatch / 1024) + " KiB heap per watched workspace (" + Std.int((held - servers) / 1024) + " KiB total; fakes " + Std.int((servers - baseline) / 1024) + " KiB)");
	}

	static function print(text:String):Void
		Sys.println(text);
}
