package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import workspace.client.DeviceMachine;
import workspace.client.WorkspaceConnections;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineDirectoryProtocol.MachineStreamFrame;
import workspace.service.MachineDirectoryProtocol.MachineWorkspaceEntry;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogChange;
import workspace.service.WorkspaceCatalogProtocol.CatalogQuery;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.transport.MachineKeys;
import workspace.transport.StreamMultiplexer;

private class NoAttempt implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

/** A channel end that refuses sends on demand and holds the Noise plaintext bound, as NoiseMessageTransport does. */
private class Channel implements MessageTransport {
	public static inline final MAX = 65492;
	public final inner:MemoryTransport;
	public var refuse = 0;
	public final sent:Array<Bytes> = [];

	public function new(inner:MemoryTransport) this.inner = inner;

	public function isOpen():Bool return inner.isOpen();

	public function send(message:Bytes):Bool {
		if (message.length > MAX) throw "frame over the Noise bound: " + message.length;
		if (refuse > 0) {
			refuse--;
			return false;
		}
		if (!inner.send(message)) return false;
		sent.push(message);
		return true;
	}

	public function receive():Null<Bytes> return inner.receive();

	public function close():Void inner.close();
}

/** One workspace's service: answers CATALOG with a whole copy each time, naming the sessions it holds. */
private class FakeWorkspace {
	public final id:String;
	public final sessions:Array<String> = [];
	public var version = 0;
	public final watchers:Array<RpcConnection> = [];

	public function new(id:String) this.id = id;

	public function token():String return "v:i:" + version;

	public function setup(connection:RpcConnection, machine:String):Void {
		connection.register(WorkspaceCatalogProtocol.CATALOG, function(query:CatalogQuery, context) {
			if (query.ref.workspace != id || query.ref.machine != machine) {
				context.fail({code: "unknown_workspace", message: "unknown_workspace", ambiguous: false});
				return;
			}
			if (query.watch && watchers.indexOf(connection) < 0) watchers.push(connection);
			context.respond(page(machine));
		});
		connection.register(WorkspaceCatalogProtocol.UNWATCH, function(ref:WorkspaceRef, context) {
			watchers.remove(connection);
			context.respond(ref);
		});
	}

	function page(machine:String):WorkspaceCatalog
		return {ref: {machine: machine, workspace: id}, instance: "i", token: token(), reset: true, more: false, name: "Workspace " + id,
			folders: [], scratch: null, status: "running", attention: 0, groups: [], sessions: [for (name in sessions)
				{id: id + "-" + name, name: name, group: "", directory: "/w/" + id, provider: null, state: "idle", attention: 0}],
			terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: true};

	public function changed(machine:String):Void {
		version++;
		for (watcher in watchers.copy())
			if (watcher.isOpen())
				watcher.notify(WorkspaceCatalogProtocol.CHANGED, ({ref: {machine: machine, workspace: id}, token: token()}:CatalogChange),
					WorkspaceCatalogProtocol.encodeChange);
	}
}

private typedef Served = {
	var mux:StreamMultiplexer;
	var handshake:Null<RpcHandshake>;
	var connection:Null<RpcConnection>;
	var streams:Map<Int, {workspace:String, handshake:RpcHandshake, connection:Null<RpcConnection>}>;
}

/** The machine's end: suit with the Noise channel already open. Grants are per workspace; the device sees only its own. */
private class FakeMachine {
	public final id:String;
	public final granted:Map<String, MachineWorkspaceEntry> = [];
	public final workspaces:Map<String, FakeWorkspace> = [];
	public var revision = 1;
	public var channels(default, null) = 0;
	public var opens = 0;
	public var refuseOpen:Null<String>;
	public var lieAboutMachine = false;
	/** The relay id the directory names (`relay`), or null to answer as a machine from before that field. */
	public var relayId:Null<String> = null;
	var current:Null<Served>;
	var nextStream = 1;
	final clock:Void->Float;

	public function new(id:String, clock:Void->Float) {
		this.id = id;
		this.clock = clock;
	}

	public function service(workspace:String):FakeWorkspace {
		var found = workspaces.get(workspace);
		if (found == null) {
			found = new FakeWorkspace(workspace);
			workspaces.set(workspace, found);
		}
		return found;
	}

	public function accept(transport:MessageTransport):Void {
		channels++;
		var mux = new StreamMultiplexer(transport);
		var options = new RpcPeerOptions(MachineDirectoryProtocol.APPLICATION, [MachineDirectoryProtocol.CAPABILITY], [], 5000, 262144, 16, 1048576);
		current = {mux: mux, handshake: RpcHandshake.server(mux.machineStream(), clock, options), connection: null, streams: []};
	}

	public function grant(workspace:String, name:String, status:String = "idle"):Void {
		service(workspace);
		granted.set(workspace, {workspace: workspace, name: name, status: status, grants: [workspace.service.WorkspaceProtocol.READ, workspace.service.WorkspaceAgentProtocol.READ, workspace.service.WorkspaceTerminalProtocol.READ, WorkspaceCatalogProtocol.CAPABILITY]});
		changed();
	}

	public function revoke(workspace:String):Void {
		granted.remove(workspace);
		var served = current;
		if (served != null)
			for (stream => entry in served.streams)
				if (entry.workspace == workspace) {
					var mux = served.mux.streamOf(stream);
					if (mux != null) mux.close();
					served.streams.remove(stream);
				}
		changed();
	}

	function changed():Void {
		revision++;
		var served = current;
		if (served != null && served.connection != null && served.connection.isOpen())
			served.connection.notify(MachineDirectoryProtocol.CHANGED, {revision: revision}, MachineDirectoryProtocol.encodeChange);
	}

	function entries():Array<MachineWorkspaceEntry> {
		var keys = [for (key in granted.keys()) key];
		keys.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
		return [for (key in keys) granted.get(key)];
	}

	function setup(served:Served, connection:RpcConnection):Void {
		connection.register(MachineDirectoryProtocol.DIRECTORY, function(query, context) {
			if (query.machine != null && query.machine != id) {
				context.fail({code: "machine_mismatch", message: "machine_mismatch", ambiguous: false});
				return;
			}
			context.respond({machine: lieAboutMachine ? "other" : id, name: "cube", revision: revision, workspaces: entries(), relay: relayId});
		});
		connection.register(MachineDirectoryProtocol.OPEN, function(request, context) {
			opens++;
			if (refuseOpen != null) {
				context.fail({code: refuseOpen, message: refuseOpen, ambiguous: false});
				return;
			}
			var entry = granted.get(request.ref.workspace);
			if (request.ref.machine != id) {
				context.fail({code: "machine_mismatch", message: "machine_mismatch", ambiguous: false});
				return;
			}
			if (entry == null) {
				context.fail({code: "unknown_workspace", message: "unknown_workspace", ambiguous: false});
				return;
			}
			if (served.mux.count() >= MachineDirectoryProtocol.STREAM_LIMIT) {
				context.fail({code: "too_many_streams", message: "too_many_streams", ambiguous: false});
				return;
			}
			var stream = nextStream++;
			var transport = served.mux.open(stream);
			var options = new RpcPeerOptions("exosuit-agent/1", entry.grants, [], 5000, 262144, 16, 1048576);
			served.streams.set(stream, {workspace: entry.workspace, handshake: RpcHandshake.server(transport, clock, options), connection: null});
			entry.status = "running";
			context.respond({ref: request.ref, stream: stream, grants: entry.grants});
		});
		connection.register(MachineDirectoryProtocol.CLOSE, function(request, context) {
			var mux = served.mux.streamOf(request.stream);
			if (mux != null) mux.close();
			served.streams.remove(request.stream);
			context.respond(request);
		});
	}

	public function poll():Void {
		var served = current;
		if (served == null) return;
		served.mux.poll();
		var shake = served.handshake;
		if (shake != null) {
			shake.poll();
			if (shake.connection != null) {
				served.connection = shake.connection;
				served.handshake = null;
				setup(served, shake.connection);
			}
		}
		if (served.connection != null) served.connection.poll();
		for (stream => entry in served.streams) {
			var shake = entry.handshake;
			if (entry.connection == null) {
				shake.poll();
				if (shake.connection != null) {
					entry.connection = shake.connection;
					service(entry.workspace).setup(shake.connection, id);
				}
			} else
				entry.connection.poll();
		}
	}

	/** The cable is cut: both ends see a closed channel. */
	public function cut():Void {
		var served = current;
		if (served != null) served.mux.close();
	}

	public function openStreams():Int {
		var served = current;
		var total = 0;
		if (served != null)
			for (stream => _ in served.streams) {
				var s = served.mux.streamOf(stream);
				if (s != null && s.isOpen()) total++;
			}
		return total;
	}
}

/** What DeviceRpcConnector is to a real relay: each connect gives a fresh open channel to the machine. */
private class Dial implements RpcConnector {
	final machine:FakeMachine;
	public var channels:Array<Channel> = [];
	public var down = false;
	public var refuseWith:Null<String>;

	public function new(machine:FakeMachine) this.machine = machine;

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		if (down) {
			complete(Failed({code: refuseWith == null ? "relay_unavailable" : refuseWith, message: "down", ambiguous: false}, refuseWith == null));
			return new NoAttempt();
		}
		var pair = MemoryTransport.pair(1048576, 256);
		var device = new Channel(pair.client);
		channels.push(device);
		machine.accept(new Channel(pair.server));
		complete(Opened(device));
		return new NoAttempt();
	}
}

class MachineDeviceTestMain {
	static var now = 0.0;

	static function clock():Float return now;

	static function require(value:Bool, message:String):Void {
		if (!value) throw "FAIL: " + message;
	}

	static function print(text:String):Void Sys.println(text);

	static function bytes(values:Array<Int>):Bytes {
		var result = Bytes.alloc(values.length);
		for (index in 0...values.length) result.set(index, values[index]);
		return result;
	}

	static function same(left:Bytes, right:Bytes):Bool return left.compare(right) == 0;

	static function main():Void {
		frames();
		multiplexer();
		backpressure();
		hostileFrames();
		directory();
		catalogsOverStreams();
		revokeAndReconnect();
		refusals();
		relayIdentity();
		print("ALL PASS");
	}

	static function pairOfMuxes(refuse:Int = 0):{a:StreamMultiplexer, b:StreamMultiplexer, left:Channel, right:Channel, raw:{client:MemoryTransport, server:MemoryTransport}} {
		var raw = MemoryTransport.pair(1048576, 1024);
		var left = new Channel(raw.client), right = new Channel(raw.server);
		left.refuse = refuse;
		return {a: new StreamMultiplexer(left), b: new StreamMultiplexer(right), left: left, right: right, raw: raw};
	}

	/** The frame codec is the one the protocol vectors freeze. */
	static function frames():Void {
		var frame = MachineStreamFrame.encode(MachineStreamFrame.DATA, 0, bytes([0xab]));
		require(same(frame, bytes([0, 0, 0, 0, 0, 0xab])), "data frame for stream 0 is 0000000000ab");
		require(same(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, 3, null), bytes([1, 0, 0, 0, 3])), "close frame for stream 3 is 0100000003");
		require(MachineStreamFrame.MAX_PAYLOAD == 65487, "payload bound is 65487");
		print("PASS: frames match the protocol vectors");
	}

	static function multiplexer():Void {
		var p = pairOfMuxes();
		var machine0 = p.a.machineStream(), peer0 = p.b.machineStream();
		require(machine0.send(bytes([1, 2, 3])) && same(peer0.receive(), bytes([1, 2, 3])), "stream 0 carries a message");
		require(p.a.open(0) == null, "stream 0 cannot be opened");
		var a5 = p.a.open(5), b5 = p.b.open(5), b6 = p.b.open(6);
		require(a5 != null && b5 != null && b6 != null && p.a.open(5) == null, "a stream id opens once");
		require(a5.send(bytes([5])) && a5.send(bytes([6])) && machine0.send(bytes([7])), "three sends are taken");
		require(b6.receive() == null, "another stream sees nothing");
		require(same(b5.receive(), bytes([5])) && same(b5.receive(), bytes([6])) && b5.receive() == null, "a stream keeps its order");
		require(same(peer0.receive(), bytes([7])), "the machine stream is separate");
		// A close frame ends only that stream, and the id is not reused.
		a5.close();
		require(!a5.isOpen() && b5.receive() == null && !b5.isOpen() && b6.isOpen(), "a close ends one stream on both sides");
		require(p.b.open(5) == null && p.a.open(5) == null, "an ended id is never reused");
		// Data for a stream that is not open is dropped and answered with one close.
		var stray = p.a.open(9);
		require(stray.send(bytes([1])) && stray.send(bytes([2])), "stray data is sent");
		p.b.poll();
		p.a.poll();
		require(!stray.isOpen(), "the peer answered a stray stream with a close");
		var closedFor9 = 0;
		for (frame in p.right.sent) if (MachineStreamFrame.kind(frame) == MachineStreamFrame.CLOSE && MachineStreamFrame.stream(frame) == 9) closedFor9++;
		require(closedFor9 == 1, "only one close for stream 9");
		// The limit counts the machine stream.
		for (id in 100...140) p.a.open(id);
		require(p.a.count() == StreamMultiplexer.STREAMS, "16 streams at most, the machine stream included");
		// Closing stream 0 closes the channel.
		machine0.close();
		require(!p.a.isOpen() && !p.b.isOpen() && !b6.isOpen(), "closing the machine stream closes the channel");
		print("PASS: streams are ordered, independent, closed one by one, bounded and never reused");
	}

	/** A busy channel keeps the frames in order, and the Noise transport sees a refused frame again before any other. */
	static function backpressure():Void {
		var p = pairOfMuxes(3);
		var a1 = p.a.open(1), b1 = p.b.open(1);
		for (value in 1...6) require(a1.send(bytes([value])), "send " + value + " is accepted while the channel is busy");
		p.a.poll();
		p.a.poll();
		p.a.poll();
		var got = [];
		while (true) {
			var message = b1.receive();
			if (message == null) break;
			got.push(message.get(0));
		}
		require(got.join(",") == "1,2,3,4,5", "frames arrive in order: " + got.join(","));
		// The outbox is bounded: a channel that never takes anything pushes back.
		var stuck = pairOfMuxes(100000);
		var s1 = stuck.a.open(1);
		var taken = 0;
		for (index in 0...StreamMultiplexer.OUTBOX_FRAMES + 20) if (s1.send(bytes([index & 0xff]))) taken++;
		require(taken == StreamMultiplexer.OUTBOX_FRAMES, "a stuck channel takes " + StreamMultiplexer.OUTBOX_FRAMES + " frames, took " + taken);
		// A message that cannot fit one frame ends its stream, not the channel.
		var big = p.a.open(2);
		require(!big.send(Bytes.alloc(MachineStreamFrame.MAX_PAYLOAD + 1)) && !big.isOpen() && p.a.isOpen(), "an oversized message ends its stream");
		var edge = p.a.open(3);
		var ok = edge.send(Bytes.alloc(MachineStreamFrame.MAX_PAYLOAD));
		require(ok && edge.isOpen(), "a message of the largest payload is accepted and fits the Noise bound");
		print("PASS: a busy channel keeps order, is bounded, and oversize ends only its stream");
	}

	static function hostileFrames():Void {
		var p = pairOfMuxes();
		var b1 = p.b.open(1);
		var a1 = p.a.open(1);
		// A flood into a stream nobody reads ends that stream.
		for (index in 0...StreamMultiplexer.INBOX_MESSAGES + 10) {
			a1.send(bytes([1]));
			p.b.poll();
			if (index % 32 == 0) p.a.poll();
		}
		p.b.poll();
		// The inbox filled while nobody read, so the stream ended, without touching the channel.
		require(!b1.isOpen() && p.b.isOpen(), "an overflowing stream is closed, not the channel");
		// A malformed frame closes the channel.
		var q = pairOfMuxes();
		q.raw.client.send(bytes([7, 0, 0, 0, 1]));
		q.b.poll();
		require(!q.b.isOpen(), "an unknown frame kind closes the channel");
		var r = pairOfMuxes();
		r.raw.client.send(bytes([1, 0, 0, 0, 1, 9]));
		r.b.poll();
		require(!r.b.isOpen(), "a close with a payload closes the channel");
		var s = pairOfMuxes();
		s.raw.client.send(bytes([0, 0, 0]));
		s.b.poll();
		require(!s.b.isOpen(), "a short frame closes the channel");
		var t = pairOfMuxes();
		t.raw.client.send(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, 0, null));
		t.b.poll();
		require(!t.b.isOpen(), "a close for the machine stream closes the channel");
		print("PASS: floods and malformed frames are contained");
	}

	static function device(machine:FakeMachine, dial:Dial):DeviceMachine
		return new DeviceMachine(dial, relay(machine.id), clock, function() return 0.5);

	/** The relay id a machine is paired under: its id without the "machine-" prefix a catalog id may carry. */
	static function relay(id:String):String return StringTools.startsWith(id, "machine-") ? id.substr(8) : id;

	static function pump(machine:FakeMachine, device:DeviceMachine, pool:Null<WorkspaceConnections> = null, rounds:Int = 30):Void {
		for (_ in 0...rounds) {
			now += 10;
			device.poll();
			machine.poll();
			if (pool != null) pool.poll();
			machine.poll();
		}
	}

	static function names(device:DeviceMachine):String
		return [for (entry in device.workspaces()) entry.workspace + ":" + entry.status].join(",");

	/** One pairing, a directory that follows the owner's grants, with no new pairing. */
	static function directory():Void {
		now = 0;
		var machine = new FakeMachine("m1", clock);
		var dial = new Dial(machine);
		var phone = device(machine, dial);
		pump(machine, phone);
		require(phone.connected() && phone.directory != null && phone.error == null, "the device connected and read the directory");
		require(phone.grantedNothing(), "a freshly paired device is granted nothing");
		machine.grant("A", "Alpha");
		pump(machine, phone);
		require(names(phone) == "A:idle", "grant A appears through CHANGED: " + names(phone));
		var revisionBefore = phone.revision;
		machine.grant("B", "Beta");
		pump(machine, phone);
		require(names(phone) == "A:idle,B:idle" && phone.revision > revisionBefore && dial.channels.length == 1, "grant B appears on the same channel");
		var entryB = phone.workspaceById("B"), entryA = phone.workspaceById("A");
		require(entryB != null && entryA != null && entryB.name == "Beta" && entryA.grants.indexOf(workspace.service.WorkspaceProtocol.READ) >= 0, "entries carry name and grants");
		require(phone.workspaceById("Z") == null, "an ungranted workspace is unknown");
		// A status change sends no hint; the periodic read finds it.
		machine.granted.get("B").status = "running";
		now += DeviceMachine.REFRESH_MS + 100;
		pump(machine, phone, null, 10);
		require(names(phone) == "A:idle,B:running", "a status change is found by the periodic read: " + names(phone));
		phone.dispose();
		print("PASS: the directory follows grants over one channel");
	}

	static function sync(pool:WorkspaceConnections, phone:DeviceMachine):Void {
		var services = [];
		for (entry in phone.workspaces()) services.push({workspace: entry.workspace, endpoint: entry.workspace, pid: 0, running: true});
		pool.sync(phone.machineId == null ? "" : phone.machineId, services, null, [for (entry in phone.workspaces()) entry.workspace]);
	}

	static function pool(phone:DeviceMachine):WorkspaceConnections
		return new WorkspaceConnections(function(endpoint) return phone.workspaceConnector(endpoint), clock, function() return 0.5,
			function(endpoint) return endpoint.length > 0, StreamMultiplexer.STREAMS - 2);

	static function sessionNames(pool:WorkspaceConnections, id:String):String {
		var mirror = pool.mirrorOf(id);
		return mirror == null ? "-" : [for (session in mirror.sessionList()) session.name].join(",");
	}

	/** Two workspaces, each with its own stream, catalogs through the normal watch and pool. */
	static function catalogsOverStreams():Void {
		now = 0;
		var machine = new FakeMachine("machine-m1", clock);
		var dial = new Dial(machine);
		var phone = device(machine, dial);
		machine.grant("A", "Alpha");
		machine.grant("B", "Beta");
		machine.service("A").sessions.push("a-one");
		machine.service("B").sessions.push("b-one");
		machine.service("B").sessions.push("b-two");
		var shared = pool(phone);
		pump(machine, phone, shared, 5);
		sync(shared, phone);
		pump(machine, phone, shared, 60);
		require(sessionNames(shared, "A") == "a-one" && sessionNames(shared, "B") == "b-one,b-two", "each workspace shows its own sessions: " + sessionNames(shared, "A") + " | " + sessionNames(shared, "B"));
		require(machine.openStreams() == 2 && dial.channels.length == 1 && machine.opens == 2, "two streams over one channel");
		// A change in A reaches the phone by CHANGED on A's stream.
		machine.service("A").sessions.push("a-two");
		machine.service("A").changed("machine-m1");
		pump(machine, phone, shared, 40);
		require(sessionNames(shared, "A") == "a-one,a-two" && sessionNames(shared, "B") == "b-one,b-two", "a change in A updates A only: " + sessionNames(shared, "A"));
		// Grant C later: another stream, no new channel.
		machine.grant("C", "Gamma");
		machine.service("C").sessions.push("c-one");
		pump(machine, phone, shared, 10);
		sync(shared, phone);
		pump(machine, phone, shared, 60);
		require(sessionNames(shared, "C") == "c-one" && machine.openStreams() == 3 && dial.channels.length == 1, "a workspace granted later opens on the same channel");
		shared.dispose();
		phone.dispose();
		print("PASS: catalogs of two and then three workspaces over one channel");
	}

	/** Revoking closes the workspace's stream; losing the channel reconnects everything through OPEN again. */
	static function revokeAndReconnect():Void {
		now = 0;
		var machine = new FakeMachine("machine-m1", clock);
		var dial = new Dial(machine);
		var phone = device(machine, dial);
		machine.grant("A", "Alpha");
		machine.grant("B", "Beta");
		machine.service("A").sessions.push("a-one");
		machine.service("B").sessions.push("b-one");
		var shared = pool(phone);
		pump(machine, phone, shared, 5);
		sync(shared, phone);
		pump(machine, phone, shared, 60);
		require(sessionNames(shared, "A") == "a-one" && sessionNames(shared, "B") == "b-one", "both catalogs are read");
		machine.revoke("B");
		pump(machine, phone, shared, 40);
		sync(shared, phone);
		pump(machine, phone, shared, 40);
		require(names(phone) == "A:running" && shared.watchOf("B") == null, "a revoked workspace leaves the directory and the pool");
		require(sessionNames(shared, "B") == "-" && sessionNames(shared, "A") == "a-one", "its catalog copy is dropped; A is untouched: " + sessionNames(shared, "B") + " | " + sessionNames(shared, "A"));
		require(dial.channels.length == 1, "revoking did not reconnect the channel");
		// The cable breaks: the device dials again, reads the directory and reopens A's stream.
		var opensBefore = machine.opens;
		machine.cut();
		pump(machine, phone, shared, 10);
		require(!phone.connected() || dial.channels.length >= 1, "the cut is seen");
		now += 2000;
		pump(machine, phone, shared, 120);
		require(phone.connected() && dial.channels.length == 2 && machine.channels == 2, "the device dialled a new channel");
		now += 6000;
		pump(machine, phone, shared, 120);
		require(machine.opens > opensBefore && machine.openStreams() >= 1, "A's stream was opened again");
		machine.service("A").sessions.push("a-after");
		machine.service("A").changed("machine-m1");
		pump(machine, phone, shared, 80);
		require(sessionNames(shared, "A") == "a-after,a-one", "A's watch is live again after the reconnect: " + sessionNames(shared, "A"));
		// The relay is down: the directory stays as it was and nothing throws.
		dial.down = true;
		machine.cut();
		pump(machine, phone, shared, 30);
		require(!phone.connected() && names(phone) == "A:running", "the last directory stays while the machine is unreachable");
		shared.dispose();
		phone.dispose();
		print("PASS: revoke closes one workspace; a cut channel reconnects every stream");
	}

	static function refusals():Void {
		now = 0;
		var machine = new FakeMachine("machine-m1", clock);
		var dial = new Dial(machine);
		var phone = device(machine, dial);
		machine.grant("A", "Alpha");
		pump(machine, phone);
		// An ungranted id is refused the same way as an unknown one.
		var answer:Null<String> = null;
		phone.openStream({machine: "machine-m1", workspace: "Nope"}, function(stream, error) answer = stream != null ? "stream" : error == null ? "none" : error.code);
		pump(machine, phone, null, 10);
		require(answer == "unknown_workspace", "opening an ungranted workspace is refused: " + answer);
		answer = null;
		phone.openStream({machine: "other", workspace: "A"}, function(stream, error) answer = stream != null ? "stream" : error == null ? "none" : error.code);
		pump(machine, phone, null, 10);
		require(answer == "machine_mismatch", "another machine id is refused: " + answer);
		machine.refuseOpen = "workspace_unavailable";
		answer = null;
		phone.openStream({machine: "machine-m1", workspace: "A"}, function(stream, error) answer = stream != null ? "stream" : error == null ? "none" : error.code);
		pump(machine, phone, null, 10);
		require(answer == "workspace_unavailable", "an unavailable service is reported: " + answer);
		phone.dispose();
		// A machine that answers for another id is not trusted.
		var liar = new FakeMachine("machine-m1", clock);
		liar.lieAboutMachine = true;
		liar.grant("A", "Alpha");
		var other = device(liar, new Dial(liar));
		pump(liar, other, null, 30);
		require(other.directory == null && other.error != null, "a directory for another machine is not accepted: " + other.error);
		other.dispose();
		// Not connected: opening fails at once, with a code the client retries.
		var idle = device(machine, new Dial(machine));
		var code:Null<String> = null;
		idle.openStream({machine: "machine-m1", workspace: "A"}, function(stream, error) code = error == null ? null : error.code);
		require(code == "disconnected", "opening before the machine connected fails at once");
		idle.dispose();
		print("PASS: refusals, mismatched machines and an unconnected machine");
	}

	/**
		A machine whose relay id is its own and differs from its catalog id (suit gives each relay one): the device accepts
		its directory when the directory names the relay id it paired under, and an older machine (no relay id) must still
		answer with the relay id as its own. The values derived from a machine key match the Worker's and suit's.
	**/
	static function relayIdentity():Void {
		var relayHex = "5ff11fa2bc5136b8ccf63b6c679d6f8d";
		var dir = function(machine:String, relay:Null<String>):MachineDirectory return {machine: machine, name: "cube", revision: 1, workspaces: [], relay: relay};
		require(DeviceMachine.answersFor(dir("machine-0123", relayHex), relayHex, null), "a directory naming this relay id is accepted under any machine id");
		require(!DeviceMachine.answersFor(dir("machine-0123", "00000000000000000000000000000000"), relayHex, null), "another relay id is refused");
		require(DeviceMachine.answersFor(dir("machine-" + relayHex, null), relayHex, null) && DeviceMachine.answersFor(dir(relayHex, null), relayHex, null),
			"an older machine answers with the relay id as its own");
		require(!DeviceMachine.answersFor(dir("machine-0123", null), relayHex, null), "an older machine with another id is refused");
		require(!DeviceMachine.answersFor(dir("machine-other", relayHex), relayHex, "machine-0123"), "the pinned machine id holds after the first answer");
		require(!DeviceMachine.answersFor(null, relayHex, null) && !DeviceMachine.answersFor(dir("", relayHex), relayHex, null), "an empty answer is refused");

		var machine = new FakeMachine("machine-0123456789abcdef0123456789abcdef", clock);
		machine.relayId = relayHex;
		machine.grant("A", "Alpha");
		var phone = new DeviceMachine(new Dial(machine), relayHex, clock, function() return 0.5);
		pump(machine, phone, null, 30);
		require(phone.directory != null && phone.machineId == machine.id && names(phone) == "A:idle",
			"the device reads a directory whose machine id is not its relay id: " + phone.error);
		var opened:Null<String> = null;
		phone.openStream({machine: machine.id, workspace: "A"}, function(stream, error) opened = stream != null ? "stream" : error == null ? "none" : error.code);
		pump(machine, phone, null, 10);
		require(opened == "stream", "and opens a workspace under the machine's own id: " + opened);
		phone.dispose();
		var stranger = new DeviceMachine(new Dial(machine), "ffffffffffffffffffffffffffffffff", clock, function() return 0.5);
		pump(machine, stranger, null, 30);
		require(stranger.directory == null && stranger.error != null, "a device paired under another relay id refuses it");
		stranger.dispose();

		var key = Bytes.alloc(32);
		for (index in 0...32)
			key.set(index, index);
		require(MachineKeys.fingerprint(key) == "630dcd2966c4336691125448bbb25b4f", "machine key fingerprint vector: " + MachineKeys.fingerprint(key));
		require(MachineKeys.relayId(key) == relayHex && MachineKeys.derived(relayHex, key) && !MachineKeys.derived("machine-0123", key),
			"relay id vector: " + MachineKeys.relayId(key));
		var shared = Bytes.alloc(32), challenge = Bytes.alloc(32);
		for (index in 0...32) {
			shared.set(index, 0x11);
			challenge.set(index, 32 + index);
		}
		var proof = MachineKeys.registrationProof(shared, relayHex, challenge, StringTools.lpad("", "ab", 64));
		require(proof == "bd14af04eba3b85dbfb2bca787b9a64bcf63070ec15a5e2de9170096057b1598", "registration proof vector: " + proof);
		print("PASS: relay ids apart from machine ids, and the machine key vectors");
	}
}
