package app;

import haxeon.rpc.*;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;

private typedef Link = {var client:RpcConnection; var server:RpcConnection; var transport:MemoryTransport; var revoke:Void->Void;}

class WorkspaceRpcTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static final ALL = [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE];

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

	/** What a QUERY on `link` answers, after pumping it. */
	static function query(link:Link):WorkspaceSnapshot {
		var result:Null<WorkspaceSnapshot> = null;
		link.client.call(WorkspaceProtocol.QUERY, {workspace: "workspace"}, 100, function(value) result = value, function(error) throw error.code);
		pump(link);
		var answered = result;
		if (answered == null)
			throw "QUERY was not answered";
		return answered;
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
		var service = new WorkspaceService("workspace", "epoch-1", [initial], 8);
		initial.name = "caller mutation";
		var reader = connect(service, ALL, clock),
			writer = connect(service, ALL, clock);
		var outcomes:Array<RenameResult> = [], errors:Array<String> = [];
		var ambiguity:Array<Bool> = [];
		var rename = function(link:Link, operation:String, revision:Int, name:String):Void {
			link.client.call(WorkspaceProtocol.GROUP, {
				workspace: "workspace",
				epoch: "epoch-1",
				operation: operation,
				group: "work",
				expectedRevision: revision,
				name: name,
				action: "update", parent: null, cwd: "/workspace/project", order: 0
			}, 100, function(value) {
				outcomes.push(value);
			}, function(error) {
				errors.push(error.code);
				ambiguity.push(error.ambiguous);
			});
		};
		rename(writer, "rename-1", 1, "Coding");
		pump(writer);
		var seen = query(reader);
		require(seen.epoch == "epoch-1" && seen.cursor == 1 && seen.groups[0].name == "Coding" && seen.groups[0].cwd == "/workspace/project",
			"another client's QUERY missed the change");
		seen.groups[0].name = "bad";
		require(service.snapshot().groups[0].name == "Coding", "snapshot leaked mutable state");
		// Accepted mutation reply is lost; a retry with the same operation id after reconnecting gets its recorded outcome.
		writer.transport.loseNext();
		rename(writer, "rename-2", 2, "Review");
		writer.server.poll();
		now = 100;
		writer.client.poll();
		require(errors[0] == "timeout" && ambiguity[0] && service.snapshot().cursor == 2, "lost reply did not preserve committed mutation");
		writer.client.close();
		writer.server.poll();
		writer = connect(service, ALL, clock);
		rename(writer, "rename-2", 2, "Review");
		pump(writer);
		require(service.snapshot().cursor == 2 && outcomes.length == 2 && outcomes[1].group.name == "Review" && outcomes[1].sequence == 2
			&& outcomes[1].group.revision == 3, "retry duplicated mutation or lost its outcome");
		rename(writer, "rename-2", 2, "Different");
		pump(writer);
		require(errors[1] == "operation_conflict" && service.snapshot().cursor == 2, "operation id accepted different payload");
		rename(writer, "stale", 1, "Stale");
		pump(writer);
		require(errors[2] == "stale_revision", "revision conflict ignored");
		for (index in 3...9) {
			rename(writer, "rename-" + index, index, "Name " + index);
			pump(writer);
		}
		require(query(reader).groups[0].name == "Name 8", "later changes missing");
		rename(writer, "full", 9, "Overflow");
		pump(writer);
		require(errors[3] == "operation_limit" && service.snapshot().cursor == 8, "retention evicted uncertain operations");
		// Negotiated permissions gate actual handlers, and revocation closes the connection.
		var readOnly = connect(service, [WorkspaceProtocol.READ], clock);
		rename(readOnly, "denied", 9, "Denied");
		pump(readOnly);
		require(errors[4] == "unauthorized", "read-only peer mutated state");
		reader.revoke();
		reader.client.poll();
		require(!reader.client.isOpen(), "revocation left the connection open");
		// Restart changes epoch: QUERY names the new one; a mutation of the old epoch is refused.
		service = new WorkspaceService("workspace", "epoch-2", [
			{
				id: "work",
				name: "Restarted",
				cwd: "/workspace/project",
				revision: 1
			}
		], 8);
		var restarted = connect(service, ALL, clock);
		var fresh = query(restarted);
		require(fresh.epoch == "epoch-2" && fresh.cursor == 0 && fresh.groups[0].name == "Restarted", "epoch restart failed to replace snapshot");
		var staleError = "";
		restarted.client.call(WorkspaceProtocol.GROUP, {
			workspace: "workspace",
			epoch: "epoch-1",
			operation: "rename-2",
			group: "work",
			expectedRevision: 2,
			name: "Review",
			action: "update", parent: null, cwd: "/workspace/project", order: 0
		}, 100, function(_) {
			throw "old-epoch mutation executed";
		}, function(error) {
			staleError = error.code;
		});
		pump(restarted);
		require(staleError == "stale_epoch" && service.snapshot().cursor == 0, "restart accepted old mutation epoch");
	}
}
