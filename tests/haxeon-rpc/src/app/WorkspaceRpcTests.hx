package app;

import haxeon.rpc.*;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceReplica;

private typedef Link = {var client:RpcConnection; var server:RpcConnection; var transport:MemoryTransport; var revoke:Void->Void;}

class WorkspaceRpcTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static final ALL = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE];

	static function connect(service:WorkspaceService, caps:Array<String>, clock:Void->Float):Link {
		var pair = MemoryTransport.pair(1024 * 1024, 128);
		var client = RpcHandshake.client(pair.client, clock, new RpcPeerOptions("client/1", caps, [], 50, 65536, 16, 1024 * 1024), caps);
		var server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("service/1", ALL, [], 50, 65536, 16, 1024 * 1024));
		for (index in 0...8) {
			client.poll();
			server.poll();
		}
		var a = client.connection, b = server.connection;
		if (a == null || b == null)
			throw "Handshake failed";
		return {
			client: a,
			server: b,
			transport: pair.server,
			revoke: service.bind(b, server.capabilities())
		};
	}

	static function pump(link:Link):Void {
		for (index in 0...8) {
			link.server.poll();
			link.client.poll();
		}
	}

	public static function run():Void {
		var now = 0.0;
		var clock = function() return now;
		var initial:WorkspaceGroup = {
			id: "work",
			name: "Work",
			cwd: "/workspace/project",
			revision: 1
		};
		var service = new WorkspaceService("workspace", "epoch-1", [initial], 2, 8);
		initial.name = "caller mutation";
		var watch = connect(service, ALL, clock),
			writer = connect(service, ALL, clock);
		var generation = 1;
		var replica = new WorkspaceReplica("workspace", 100);
		replica.restore(watch.client, function() return generation == 1 && watch.client.isOpen());
		// The watch reply triggers the snapshot call; a mutation lands before snapshot.
		watch.server.poll();
		watch.client.poll();
		var outcomes:Array<RenameResult> = [], errors:Array<String> = [];
		var ambiguity:Array<Bool> = [];
		var rename = function(link:Link, operation:String, revision:Int, name:String):Void {
			link.client.call(WorkspaceProtocol.RENAME, {
				workspace: "workspace",
				epoch: "epoch-1",
				operation: operation,
				group: "work",
				expectedRevision: revision,
				name: name
			}, 100, function(value) {
				outcomes.push(value);
			}, function(error) {
				errors.push(error.code);
				ambiguity.push(error.ambiguous);
			});
		};
		rename(writer, "rename-1", 1, "Coding");
		pump(writer);
		pump(watch);
		require(replica.ready
			&& replica.cursor == 1
			&& replica.view()[0].name == "Coding"
			&& replica.view()[0].cwd == "/workspace/project",
			"watch/snapshot race lost change");
		var copy = replica.view();
		copy[0].name = "bad";
		require(replica.view()[0].name == "Coding", "view leaked mutable state");
		// Accepted mutation reply is lost; reconnect and query its recorded outcome.
		writer.transport.loseNext();
		rename(writer, "rename-2", 2, "Review");
		writer.server.poll();
		now = 100;
		writer.client.poll();
		require(errors[0] == "timeout" && ambiguity[0] && service.snapshot().cursor == 2, "lost reply did not preserve committed mutation");
		writer.client.close();
		writer.server.poll();
		writer = connect(service, ALL, clock);
		var known:OperationResult = {known: false, outcome: null};
		writer.client.call(WorkspaceProtocol.OPERATION, {workspace: "workspace", epoch: "epoch-1", operation: "rename-2"}, 100, function(value) {
			known = value;
		}, function(error) {
			errors.push(error.code);
		});
		pump(writer);
		require(known.known
			&& known.outcome != null
			&& known.outcome.group.name == "Review"
			&& known.outcome.sequence == 2, "outcome reconciliation failed");
		rename(writer, "rename-2", 2, "Review");
		pump(writer);
		require(service.snapshot().cursor == 2 && outcomes.length == 2 && outcomes[1].group.revision == 3, "retry duplicated mutation");
		rename(writer, "rename-2", 2, "Different");
		pump(writer);
		require(errors[1] == "operation_conflict" && service.snapshot().cursor == 2, "operation id accepted different payload");
		rename(writer, "stale", 1, "Stale");
		pump(writer);
		require(errors[2] == "stale_revision", "revision conflict ignored");
		pump(watch);
		require(replica.cursor == 2 && replica.view()[0].name == "Review", "live event missing");
		// Disconnect retains application cursor; explicit restoration replays missed events.
		watch.client.close();
		watch.server.poll();
		generation = 2;
		rename(writer, "rename-3", 3, "Planning");
		pump(writer);
		watch = connect(service, ALL, clock);
		replica.restore(watch.client, function() return generation == 2 && watch.client.isOpen());
		pump(watch);
		require(replica.ready && replica.cursor == 3 && replica.view()[0].name == "Planning", "resume missed retained event");
		// More changes than retained history force watch-before-snapshot recovery.
		watch.client.close();
		watch.server.poll();
		generation = 3;
		rename(writer, "rename-4", 4, "A");
		pump(writer);
		rename(writer, "rename-5", 5, "B");
		pump(writer);
		rename(writer, "rename-6", 6, "C");
		pump(writer);
		watch = connect(service, ALL, clock);
		replica.restore(watch.client, function() return generation == 3 && watch.client.isOpen());
		pump(watch);
		require(replica.ready && replica.cursor == 6 && replica.view()[0].name == "C", "history gap did not recover snapshot");
		// Loss during live delivery is detected at the next sequence and recoverable.
		watch.transport.loseNext();
		rename(writer, "rename-7", 7, "D");
		pump(writer);
		rename(writer, "rename-8", 8, "E");
		pump(writer);
		pump(watch);
		require(!replica.ready && replica.error == "replay_gap", "live gap silently accepted");
		replica.recover();
		pump(watch);
		require(replica.ready && replica.cursor == 8 && replica.view()[0].name == "E", "live gap recovery failed");
		rename(writer, "full", 9, "Overflow");
		pump(writer);
		require(errors[3] == "operation_limit" && service.snapshot().cursor == 8, "retention evicted uncertain operations");
		// Negotiated permissions gate actual handlers and revocation ends subscriptions.
		var reader = connect(service, [WorkspaceProtocol.READ], clock);
		rename(reader, "denied", 9, "Denied");
		pump(reader);
		require(errors[4] == "unauthorized", "read-only peer mutated state");
		watch.revoke();
		watch.client.poll();
		require(!watch.client.isOpen(), "revocation left subscription active");
		// Restart changes epoch: query recovers state; missing outcomes remain unknown.
		generation = 4;
		service = new WorkspaceService("workspace", "epoch-2", [
			{
				id: "work",
				name: "Restarted",
				cwd: "/workspace/project",
				revision: 1
			}
		], 2, 8);
		watch = connect(service, ALL, clock);
		replica.restore(watch.client, function() return generation == 4 && watch.client.isOpen());
		pump(watch);
		require(replica.ready && replica.epoch == "epoch-2" && replica.cursor == 0 && replica.view()[0].name == "Restarted",
			"epoch restart failed to replace snapshot");
		known = {known: true, outcome: null};
		watch.client.call(WorkspaceProtocol.OPERATION, {workspace: "workspace", epoch: "epoch-1", operation: "rename-2"}, 100, function(value) {
			known = value;
		}, function(_) {});
		pump(watch);
		require(!known.known && known.outcome == null, "restart guessed unretained operation never executed");
		var staleError = "";
		watch.client.call(WorkspaceProtocol.RENAME, {
			workspace: "workspace",
			epoch: "epoch-1",
			operation: "rename-2",
			group: "work",
			expectedRevision: 2,
			name: "Review"
		}, 100, function(_) {
			throw "old-epoch mutation executed";
		}, function(error) {
			staleError = error.code;
		});
		pump(watch);
		require(staleError == "stale_epoch" && service.snapshot().cursor == 0, "restart accepted old mutation epoch");

		// A response already queued on the retired connection cannot replace the view.
		var old = connect(service, ALL, clock),
			fresh = connect(service, ALL, clock);
		var current = 1;
		var fenced = new WorkspaceReplica("workspace", 100);
		fenced.restore(old.client, function() return current == 1 && old.client.isOpen());
		old.server.poll(); // Reply accepted, but caller has not seen it yet.
		current = 2;
		fenced.restore(fresh.client, function() return current == 2 && fresh.client.isOpen());
		pump(fresh);
		var stable = fenced.view()[0].name;
		pump(old);
		require(fenced.ready && fenced.epoch == "epoch-2" && fenced.view()[0].name == stable, "retired watch callback replaced new view");
		fresh.client.close();
		require(!fenced.ready, "disconnected replica reported live readiness");
		// A stalled observer cannot exhaust service memory or block another client.
		var bounded = new WorkspaceService("bounded", "bounded-epoch", [
			{
				id: "work",
				name: "Work",
				cwd: null,
				revision: 1
			}
		], 2, 8);
		var pair = MemoryTransport.pair(4096, 1);
		var a = RpcHandshake.client(pair.client, clock, new RpcPeerOptions("slow", ALL, [], 50, 1024, 1, 2048), ALL);
		var b = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("service", ALL, [], 50, 1024, 1, 2048));
		for (index in 0...8) {
			a.poll();
			b.poll();
		}
		var slow = a.connection, slowServer = b.connection;
		if (slow == null || slowServer == null)
			throw "missing slow connection";
		bounded.bind(slowServer, ALL);
		slow.call(WorkspaceProtocol.WATCH, {workspace: "bounded", epoch: "", cursor: 0}, 100, function(_) {}, function(_) {});
		slowServer.poll(); // Fill its receive queue with the watch acknowledgement.
		var fast = connect(bounded, ALL, clock), committed = 0;
		for (index in 0...5) {
			fast.client.call(WorkspaceProtocol.RENAME, {
				workspace: "bounded",
				epoch: "bounded-epoch",
				operation: "op-" + index,
				group: "work",
				expectedRevision: index + 1,
				name: "Name " + index
			}, 100, function(_) {
				committed++;
			}, function(_) {
				throw "slow observer blocked writer";
			});
			pump(fast);
		}
		require(!slowServer.isOpen() && slowServer.bufferedBytes() == 0 && committed == 5 && bounded.snapshot().cursor == 5,
			"slow observer was unbounded or blocked writer");
	}
}
