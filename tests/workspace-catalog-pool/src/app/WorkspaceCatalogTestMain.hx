package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import haxeon.rpc.RpcError;
import workspace.client.WorkspaceCatalogMirror;
import workspace.client.WorkspaceCatalogWatch;
import workspace.client.CatalogSnapshots;
import workspace.client.WorkspaceLink;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogChange;
import workspace.service.WorkspaceCatalogProtocol.CatalogQuery;
import workspace.service.WorkspaceCatalogProtocol.CatalogSession;
import workspace.service.WorkspaceCatalogProtocol.CatalogTerminal;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

private class NoAttempt implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

/** A workspace service's catalog end, answering CATALOG and UNWATCH the way docs/RPC-VECTORS.md says. */
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
		// The watch's owner asks for the catalog plus the three read grants (Holder), and a service that lacks one refuses it.
		var granted = [WorkspaceCatalogProtocol.CAPABILITY, workspace.service.WorkspaceProtocol.READ, workspace.service.WorkspaceAgentProtocol.READ, workspace.service.WorkspaceTerminalProtocol.READ];
		var options = new RpcPeerOptions("exosuit-agent/1", granted, [], 2000, 262144, 8, 1048576);
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
			// A service answers to its own id and to the alias "workspace", and names its real id in the reply.
			if (query.ref.workspace != id && query.ref.workspace != "workspace") {
				context.fail(new RpcError("unknown_workspace", "unknown_workspace", false));
				return;
			}
			if (failNext > 0) {
				failNext--;
				requests++;
				context.fail(new RpcError("boom", "boom", false));
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
			complete(Failed(new RpcError("connect_failed", "connect_failed", false), true));
			return new NoAttempt();
		}
		var pair = MemoryTransport.pair(262144, 64);
		network.opened++;
		service.accept(pair.server);
		complete(Opened(pair.client));
		return new NoAttempt();
	}
}

/**
	A watch's owner, as a WorkspaceLink holds one: its own client to the service, and the shared catalog watch it
	attaches to each connection that client establishes and detaches when that connection goes away.
**/
private class Holder {
	public final watch:WorkspaceCatalogWatch;
	public final client:RpcClient;
	/** Connections the watch was attached to. */
	public var attached = 0;
	var held:Null<RpcConnection>;

	public function new(network:Network, endpoint:String, clock:Void->Float, ref:WorkspaceRef, learning:Bool = false) {
		var created = WorkspaceCatalogWatch.shared(ref, clock, learning);
		watch = created;
		// The connection holds the three read grants along with the catalog, as a link's client does.
		var granted = [WorkspaceCatalogProtocol.CAPABILITY, workspace.service.WorkspaceProtocol.READ, workspace.service.WorkspaceAgentProtocol.READ,
			workspace.service.WorkspaceTerminalProtocol.READ];
		client = new RpcClient(network.connector(endpoint), clock, function() return 0.5,
			new RpcPeerOptions("exosuit-editor/1", granted, granted, 2000, 262144, 8, 1048576), function(connection, _, _) {
				held = connection;
				attached++;
				created.attach(connection);
			}, 100, 5000, 5000);
	}

	/** The connection the watch is attached to, while it is the client's current one. */
	public function connection():Null<RpcConnection>
		return held;

	public function poll():Void {
		client.poll();
		var last = held;
		if (last != null && client.current() != last) {
			held = null;
			watch.detach();
		}
		watch.poll();
	}

	public function dispose():Void {
		watch.dispose();
		client.close();
	}
}

/** Catalog watches shared on their owners' connections, against fake workspace services: they follow other clients, kills and restarts. */
class WorkspaceCatalogTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static var now = 0.0;

	static function clock():Float
		return now;

	/** An endpoint in the shape the agent gives its service on this system. */
	static function ep(id:String):String
		return Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-" + id : "/tmp/exosuit-" + id + "/agent.sock";

	/** A holder of a watch on `id`'s service; with `learning` the watch starts on the alias and learns the id. */
	static function hold(network:Network, id:String, learning:Bool = false):Holder
		return new Holder(network, ep(id), clock, {machine: "m", workspace: learning ? "workspace" : id}, learning);

	static function pump(holders:Array<Holder>, services:Array<FakeService>, rounds:Int = 12):Void {
		for (round in 0...rounds) {
			for (holder in holders) holder.poll();
			for (fake in services) fake.poll();
		}
	}

	static function main():Void {
		mirrorOrder();
		sharedWatch();
		bounds();
		bigWorkspace();
		unwatchNeverAnswered();
		snapshots();
		hostileInput();
		changeDuringRead();
		changeDuringBackoff();
		endpoints();
		behaviour();
		measure();
	}

	/** Only the agent's own endpoint shapes are valid. */
	static function endpoints():Void {
		var pipe = "\\\\.\\pipe\\exosuit-0123abcd-X_y";
		require(WorkspaceLink.validEndpoint(pipe, true), "the agent's pipe name is valid");
		require(!WorkspaceLink.validEndpoint("\\\\.\\pipe\\other", true) && !WorkspaceLink.validEndpoint("\\\\.\\pipe\\exosuit-", true)
			&& !WorkspaceLink.validEndpoint("\\\\.\\pipe\\exosuit-a\\b", true) && !WorkspaceLink.validEndpoint("\\\\evil\\pipe\\exosuit-a", true)
			&& !WorkspaceLink.validEndpoint("C:\\x\\agent.sock", true), "other pipes and paths are refused on Windows");
		require(WorkspaceLink.validEndpoint("/home/u/state/workspaces/w1/agent.sock", false), "the agent's socket path is valid");
		require(!WorkspaceLink.validEndpoint("agent.sock", false) && !WorkspaceLink.validEndpoint("/tmp/other.sock", false)
			&& !WorkspaceLink.validEndpoint("/tmp/../etc/agent.sock", false) && !WorkspaceLink.validEndpoint("", false)
			&& !WorkspaceLink.validEndpoint("/etc/passwd", false), "other sockets are refused");
		print("PASS: only the agent's pipe and socket shapes are valid endpoints");
	}

	/** A looping, oversized, failing or non-watching service is bounded, backed off and never read as live. */
	static function bounds():Void {
		var network = new Network();
		var x = new FakeService("X", "ix", clock);
		network.add(x, ep("X"));
		x.addSession("s", "One");
		var holder = hold(network, "X");
		var watch = holder.watch;

		x.misbehave = "repeat";
		pump([holder], [x], 60);
		require(!watch.live && watch.mirror.token == null && watch.reads == 2 && watch.error != null, "a more page that repeats its token is a failure: " + watch.reads + " " + watch.error);
		require(watch.retryDelay == 2000, "and the next retry waits longer: " + watch.retryDelay);

		x.misbehave = "endless";
		now += 1500;
		pump([holder], [x], 4000);
		require(!watch.live && watch.mirror.token == null && x.requests >= WorkspaceCatalogWatch.MAX_PAGES && x.requests <= WorkspaceCatalogWatch.MAX_PAGES + 2, "an endless catalog stops at the page cap: " + x.requests);
		require(watch.error != null && watch.error.indexOf("pages") >= 0, "page cap reason: " + watch.error);

		x.misbehave = "huge";
		now += 5000;
		pump([holder], [x], 200);
		require(!watch.live && watch.mirror.token == null && watch.error != null && watch.error.indexOf("items") >= 0, "an oversized catalog is refused: " + watch.error);

		// A well-behaved service recovers, and the delay starts over.
		x.misbehave = "";
		now += 40000;
		pump([holder], [x], 40);
		require(watch.live && watch.retryDelay == WorkspaceCatalogWatch.RETRY_MIN_MS && watch.mirror.sessions.exists("s"), "recovery resets the delay: " + watch.retryDelay);
		require(holder.attached == 1, "all of it on one connection: " + holder.attached);

		// Failed calls wait 1 s, 2 s, 4 s: each retry comes only after its delay.
		x.addSession("t", "Two");
		pump([holder], [x], 6);
		holder.dispose();
		x.failNext = 3;
		var before = x.requests;
		var second = hold(network, "X");
		var again = second.watch;
		pump([second], [x], 10);
		require(x.requests == before + 1 && again.retryDelay == 2000, "first failure waits a second: " + (x.requests - before));
		now += 900;
		pump([second], [x], 10);
		require(x.requests == before + 1, "no retry before the delay");
		now += 200;
		pump([second], [x], 10);
		require(x.requests == before + 2 && again.retryDelay == 4000, "second retry after two: " + again.retryDelay);
		now += 2100;
		pump([second], [x], 10);
		now += 4100;
		pump([second], [x], 20);
		require(again.live && again.retryDelay == WorkspaceCatalogWatch.RETRY_MIN_MS, "third failure then success");
		second.dispose();

		// A service that does not register the watch is not live.
		x.refuseWatch = true;
		var third = hold(network, "X");
		pump([third], [x], 20);
		var unwatched = third.watch;
		require(!unwatched.live && unwatched.mirror.sessions.exists("s") && unwatched.error != null, "watching:false is not live, though its data shows");
		third.dispose();
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
		var holder = hold(network, "Big");
		pump([holder], [big], 400);
		var watch = holder.watch;
		require(watch.live && Lambda.count(watch.mirror.sessions) == 2000 && watch.reads > 64, "two thousand items over " + watch.reads + " pages: " + Lambda.count(watch.mirror.sessions) + " " + watch.error);
		holder.dispose();
		print("PASS: a catalog of 2000 items reads in " + watch.reads + " pages");
	}

	/** A change announced while pages are still coming is read afterwards. */
	static function changeDuringRead():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		a.pageSize = 1;
		network.add(a, ep("A"));
		for (index in 0...12) a.addSession("s" + index, "S" + index);
		var holder = hold(network, "A");
		var watch = holder.watch;
		var injected = false;
		for (round in 0...400) {
			pump([holder], [a], 1);
			if (!injected && watch.reads >= 2) {
				require(watch.mirror.token == null, "still reading");
				a.addGroup("0early", "Sorted before what was sent");
				injected = true;
			}
		}
		require(injected && watch.live && watch.mirror.groups.exists("0early") && Lambda.count(watch.mirror.sessions) == 12, "the change made during the read arrived: " + watch.error);
		holder.dispose();
		print("PASS: a CHANGED during a multi-page read is read after it");
	}

	/**
		A device has one connection per relay route, so its catalog watch follows the connection its own client holds
		(`WorkspaceCatalogWatch.shared`): started on the alias it learns the workspace's id, follows changes, and after a
		restart of the service attaches to the new connection and reads again.
	**/
	static function sharedWatch():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.addSession("s1", "One");
		var holder = hold(network, "A", true);
		var watch = holder.watch;
		pump([holder], [a], 60);
		require(watch.live && holder.attached == 1, "the shared watch reads on the client's connection: " + watch.error);
		require(watch.ref.workspace == "A" && watch.ref.machine == "m", "the watch adopted the service's real id: " + watch.ref.workspace);
		require(Lambda.count(watch.mirror.sessions) == 1, "the first page holds the session");
		var readsBefore = watch.reads;
		a.addSession("s2", "Two");
		pump([holder], [a], 60);
		require(Lambda.count(watch.mirror.sessions) == 2 && watch.reads == readsBefore + 1, "a CHANGED reads once");
		// The service goes away and comes back as another instance: the watch keeps its copy while down, then resets.
		a.kill();
		pump([holder], [a], 60);
		require(!watch.live && Lambda.count(watch.mirror.sessions) == 2, "down: not live, copy kept");
		a.restart("ib");
		for (round in 0...80) {
			now += 100;
			pump([holder], [a], 1);
		}
		require(watch.live && holder.attached == 2 && watch.mirror.instance == "ib", "after the restart it attached to the new connection and read again");
		holder.dispose();
		print("PASS: a shared catalog watch learns the id, follows changes and reattaches after a restart");
	}

	/** CHANGED does not read before a failed read's delay is over. */
	static function changeDuringBackoff():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.addSession("s1", "One");
		var holder = hold(network, "A");
		pump([holder], [a]);
		var watch = holder.watch;
		require(watch.live, "live first");
		var before = a.requests;
		a.failNext = 1;
		a.addSession("u1", "Two");
		pump([holder], [a]);
		require(a.requests == before + 1 && watch.error != null, "the read failed");
		a.addSession("u2", "Three");
		pump([holder], [a]);
		require(a.requests == before + 1, "CHANGED waits for the delay: " + (a.requests - before));
		now += 1100;
		pump([holder], [a]);
		require(a.requests == before + 2 && watch.mirror.sessions.exists("u1") && watch.mirror.sessions.exists("u2") && watch.error == null, "then one read gets both");
		holder.dispose();
		print("PASS: CHANGED during a retry delay waits for the delay");
	}

	/** A disposed watch's UNWATCH that is never answered holds nothing: dispose returns at once and the owner's connection stays. */
	static function unwatchNeverAnswered():Void {
		var network = new Network();
		var a = new FakeService("A", "ia", clock);
		network.add(a, ep("A"));
		a.silentUnwatch = true;
		var holder = hold(network, "A");
		pump([holder], [a]);
		var watch = holder.watch;
		require(watch.live, "live first");
		var connection = holder.connection();
		watch.dispose();
		require(watch.ended() && !watch.live, "dispose ends the watch at once");
		pump([holder], [a], 6);
		require(a.unwatched == 1, "UNWATCH was sent: " + a.unwatched);
		now += WorkspaceCatalogWatch.LINGER_MS + 100;
		pump([holder], [a], 6);
		require(connection != null && connection.isOpen() && holder.client.current() == connection && holder.attached == 1,
			"the unanswered UNWATCH timed out and left the owner's connection open");
		// The service still believes it is watched; a change it announces reaches a watch that is gone, and nothing reads.
		var requests = a.requests;
		a.addSession("late", "Late");
		pump([holder], [a], 6);
		require(a.requests == requests && watch.reads > 0, "a disposed watch reads nothing more");
		holder.client.close();
		print("PASS: an unanswered UNWATCH never blocks: the watch ends at once and its owner's connection stays");
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

	/**
		Idle rows: a service's catalog snapshot reads back as the catalog it held, is read again only when its bytes
		change, and a missing, damaged or partial one gives no rows.
	**/
	static function snapshots():Void {
		var base = haxe.io.Path.join([Sys.getEnv("TEMP") == null ? "/tmp" : Sys.getEnv("TEMP"), "exosuit-snapshots-" + Std.int(Sys.time())]);
		var folder = base + "/workspaces/w1";
		for (path in [base, base + "/workspaces", folder]) sys.FileSystem.createDirectory(path);
		var file = folder + "/" + WorkspaceCatalogProtocol.SNAPSHOT_FILE;
		var clockNow = 0.0;
		var saved = new CatalogSnapshots(base, function() return clockNow);
		require(saved.of("w1") == null && saved.of("../w1") == null, "no snapshot, or a bad id, gives no rows");
		var page:WorkspaceCatalog = {ref: {machine: "", workspace: "w1"}, instance: "i", token: "i.3", reset: true, more: false, name: "One",
			folders: ["/a"], scratch: null, status: "idle", attention: 0,
			groups: [{id: "g", name: "Work", cwd: null, revision: 1, parent: null, order: 0}],
			sessions: [], terminals: [{id: "t", name: "shell", group: "g", directory: "/a", state: "running", exitCode: 0, available: true,
				revision: haxe.Int64.make(0, 4), agentProvider: null, attention: 0}],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: false};
		sys.io.File.saveBytes(file, WorkspaceCatalogProtocol.encodeSnapshot(page));
		clockNow += 5000;
		var mirror = saved.of("w1");
		require(mirror != null && mirror.groupList().length == 1 && mirror.terminalList().length == 1 && mirror.terminalList()[0].name == "shell",
			"the snapshot reads back as its catalog");
		var revision = saved.revision;
		clockNow += 5000;
		require(saved.of("w1") == mirror && saved.revision == revision, "unchanged bytes are not decoded again");
		page.terminals = [];
		sys.io.File.saveBytes(file, WorkspaceCatalogProtocol.encodeSnapshot(page));
		require(saved.of("w1") == mirror, "a snapshot is looked at no more than once per check interval");
		clockNow += 5000;
		var next = saved.of("w1");
		require(next != mirror && next.terminalList().length == 0 && saved.revision > revision, "a changed snapshot is read again");
		page.more = true;
		sys.io.File.saveBytes(file, WorkspaceCatalogProtocol.encodeSnapshot(page));
		clockNow += 5000;
		require(saved.of("w1") == null, "a partial page gives no rows");
		sys.io.File.saveContent(file, "not a snapshot");
		clockNow += 5000;
		require(saved.of("w1") == null, "a damaged snapshot gives no rows");
		sys.FileSystem.deleteFile(file);
		sys.FileSystem.deleteDirectory(folder);
		sys.FileSystem.deleteDirectory(base + "/workspaces");
		sys.FileSystem.deleteDirectory(base);
		print("PASS: idle rows come from the service's catalog snapshot, read again only when it changes");
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
		var holderA = hold(network, "A"), holderB = hold(network, "B");
		var holders = [holderA, holderB];

		// Each watch reads on its owner's connection, pages the paged one, and the first copy is a reset.
		pump(holders, all);
		var watchA = holderA.watch, watchB = holderB.watch;
		require(watchA.live && watchB.live, "two live watches");
		require(watchA.mirror.sessions.exists("s1") && watchA.mirror.groups.exists("g1") && watchA.mirror.name == "Workspace A", "A's catalog arrived");
		require(Lambda.count(watchB.mirror.sessions) == 6 && watchB.mirror.terminals.exists("t1") && !watchB.mirror.partial, "B's seven items arrived over pages: " + Lambda.count(watchB.mirror.sessions));
		require(b.resets == 1 && watchB.reads == 3, "B was paged: " + watchB.reads + " pages");
		require(watchB.mirror.folders.length == 1 && watchB.mirror.folders[0] == "/w/B", "folders came in the reset");
		require(a.watchers.length == 1 && b.watchers.length == 1, "each service watches this connection");

		// A session another client creates shows up within one catalog event: one notification, one read.
		var before = watchA.reads, revision = watchA.revision;
		a.addSession("s2", "Made elsewhere", "g1");
		pump(holders, all);
		require(a.changedSent == 1, "one CHANGED for one change");
		require(watchA.mirror.sessions.exists("s2") && watchA.reads == before + 1 && a.deltas == 1, "the new session arrived in one delta read");
		require(watchA.revision != revision, "the watch's revision moved");
		require(b.deltas == 0, "the other service was not read");

		// A hint whose token is ours causes no read.
		var reads = watchA.reads;
		a.repeat();
		pump(holders, all);
		require(watchA.reads == reads && watchA.skipped == 1, "a CHANGED with our token is skipped");

		// A removal arrives as a delta too.
		a.removeSession("s1");
		pump(holders, all);
		require(!watchA.mirror.sessions.exists("s1") && watchA.mirror.sessions.exists("s2"), "removal applied");

		// Disposing a watch unwatches on the owner's connection, which stays; a new watch on a new connection starts with a reset.
		var kept = holderB.connection();
		watchB.dispose();
		pump(holders, all);
		require(b.unwatched == 1 && b.watchers.length == 0, "UNWATCH reached the service: " + b.unwatched);
		require(kept != null && kept.isOpen() && holderB.client.current() == kept, "the owner's connection stays open");
		var copy = watchB.mirror;
		b.addSession("b9", "After");
		pump(holders, all);
		require(watchB.mirror == copy && !copy.sessions.exists("b9"), "a disposed watch's copy no longer changes");
		holderB.client.close();
		holderB = hold(network, "B");
		holders = [holderA, holderB];
		pump(holders, all);
		require(holderB.watch.live && b.resets == 2 && holderB.watch.mirror.sessions.exists("b9"), "a new watch starts with a fresh reset");

		// A dropped connection: the owner detaches, the watch keeps its copy, and on the client's next connection it
		// resumes from its token: no reset, only the delta.
		var resumed = a.resets;
		a.kill();
		a.up = true;
		pump(holders, all, 3);
		require(!watchA.live && watchA.mirror.sessions.exists("s2"), "a lost connection shows as not live, copy kept");
		a.addSession("s3", "While away", "g1");
		now += 200;
		pump(holders, all);
		now += 400;
		pump(holders, all);
		require(watchA.live && watchA.mirror.sessions.exists("s3") && holderA.attached == 2, "reattached and caught up: " + holderA.attached);
		require(a.resets == resumed, "resumed from the token, with no reset: " + a.resets + " vs " + resumed);

		// A detach the owner reports itself (before the watch sees the connection close) clears live the same way.
		var revisionBefore = watchA.revision;
		watchA.detach();
		require(!watchA.live && watchA.revision == revisionBefore + 1 && watchA.mirror.sessions.exists("s3"), "detach keeps the copy and clears live");
		var ignored = watchA.reads;
		a.addSession("s4", "Unseen", "g1");
		pump(holders, all);
		require(watchA.reads == ignored && !watchA.mirror.sessions.exists("s4"), "a detached watch ignores CHANGED on its old connection");

		// A killed service that restarts as a new instance comes back with a reset that keeps stored work.
		a.kill();
		pump(holders, all, 3);
		require(!watchA.live, "the killed service's watch is not live");
		require(holderB.watch.live, "the other workspace is untouched");
		a.restart("ia2");
		for (round in 0...40) {
			now += 100;
			pump(holders, all, 1);
		}
		require(watchA.live && watchA.mirror.instance == "ia2" && watchA.mirror.sessions.exists("s4") && a.resets == resumed + 1 && holderA.attached == 3,
			"restarted service's catalog is back with a reset, reattached on the new connection");

		for (holder in holders) holder.dispose();
		pump([], all, 4);
		require(a.watchers.length == 0 && b.watchers.length == 0, "no watchers remain");
		print("PASS: shared watches page, resume, update in one event and unwatch on their owner's connection; a killed service returns after a restart");
	}

	/** Ten workspaces of realistic size in one window: connections held and memory taken. */
	static function measure():Void {
		hl.Gc.major();
		var baseline = hl.Gc.heapBytes();
		var network = new Network();
		var fakes:Array<FakeService> = [];
		for (index in 0...10) {
			var id = "W" + index;
			var fake = new FakeService(id, "i" + index, clock);
			fake.pageSize = 24;
			for (g in 0...6) fake.addGroup("g" + g, "Group " + g);
			for (s in 0...30) fake.addSession("s" + s, "Session number " + s, "g" + (s % 6));
			for (t in 0...12) fake.addTerminal("t" + t, "Terminal " + t, "g" + (t % 6));
			network.add(fake, ep(id));
			fakes.push(fake);
		}
		hl.Gc.major();
		var servers = hl.Gc.heapBytes();
		var holders = [for (index in 0...10) hold(network, "W" + index)];
		pump(holders, fakes, 30);
		var live = 0;
		for (holder in holders) if (holder.watch.live) live++;
		require(live == 10, "ten live watches: " + live);
		var items = 0;
		for (holder in holders) {
			var mirror = holder.watch.mirror;
			items += Lambda.count(mirror.sessions) + Lambda.count(mirror.terminals) + Lambda.count(mirror.groups);
		}
		hl.Gc.major();
		var held = hl.Gc.heapBytes();
		var perWatch = Std.int((held - servers) / 10);
		var opened = network.opened;
		// One change on one service reads one service.
		var reads = 0;
		for (holder in holders) reads += holder.watch.reads;
		fakes[3].addSession("late", "Late");
		pump(holders, fakes);
		var after = 0;
		for (holder in holders) after += holder.watch.reads;
		require(after == reads + 1, "one change cost one read across ten workspaces: " + (after - reads));
		for (holder in holders) holder.dispose();
		print("PASS: ten workspaces: " + opened + " connections opened, " + items + " catalog items mirrored, "
			+ Std.int(perWatch / 1024) + " KiB heap per watched workspace with its connection (" + Std.int((held - servers) / 1024) + " KiB total; fakes " + Std.int((servers - baseline) / 1024) + " KiB)");
	}

	static function print(text:String):Void
		Sys.println(text);
}
