package app;

import haxeon.rpc.*;
import sqlitekit.Database;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceDeviceRecord;
import haxe.io.Bytes;

private typedef Link = {var client:RpcConnection; var server:RpcConnection;}

class PersistenceTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function rejects(body:Void->Void, message:String):Void {
		var failed = false;
		try
			body()
		catch (_:Dynamic)
			failed = true;
		require(failed, message);
	}

	static function seed():WorkspaceSnapshot
		return {
			epoch: "first",
			cursor: 0,
			groups: [
				{
					id: "work",
					name: "Work",
					cwd: "/workspace",
					revision: 1
				}
			]
		};

	static function service(store:WorkspaceSqliteStore):WorkspaceService
		return new WorkspaceService("workspace", "ignored-on-reopen", seed().groups, 32, 256, 16, store);

	static function connect(service:WorkspaceService):Link {
		var caps = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE];
		var pair = MemoryTransport.pair(1048576, 128);
		var clock = function() return 0.0;
		var client = RpcHandshake.client(pair.client, clock, new RpcPeerOptions("test", caps), caps);
		var server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("test", caps));
		for (_ in 0...8) {
			client.poll();
			server.poll();
		}
		if (client.connection == null || server.connection == null)
			throw "Handshake failed";
		service.bind(server.connection, caps);
		return {client: client.connection, server: server.connection};
	}

	static function pump(link:Link):Void {
		for (_ in 0...8) {
			link.server.poll();
			link.client.poll();
		}
	}

	static function rename(link:Link, operation:String, revision:Int, name:String, ?expectedError:String):Void {
		var done = false;
		link.client.call(WorkspaceProtocol.RENAME, {
			workspace: "workspace",
			epoch: "first",
			operation: operation,
			group: "work",
			expectedRevision: revision,
			name: name
		}, 100, function(result) {
			require(expectedError == null && result.group.name == name, "Unexpected rename result");
			done = true;
		}, function(error) {
			require(expectedError == error.code, "Unexpected rename failure: " + error.code);
			if (error.code == "storage_failed")
				require(error.ambiguous, "Storage failure lost ambiguity");
			done = true;
		});
		pump(link);
		require(done, "Rename did not complete");
	}

	static function devicePersistence(path:String):Void {
		if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
		if (sys.FileSystem.exists(path + ".sqlitekit-lock")) sys.FileSystem.deleteFile(path + ".sqlitekit-lock");
		var deviceId = "0123456789abcdef0123456789abcdef";
		var key = Bytes.alloc(32);
		for (index in 0...key.length) key.set(index, (index * 7 + 3) & 0xff);
		var seed = seed();
		var store = new WorkspaceSqliteStore(path, "workspace", seed);
		store.close();
		// Simulate an existing v4 catalog and verify the additive device migration.
		var admin = Database.open(path);
		admin.exec("DROP TABLE workspace_devices; PRAGMA user_version=4");
		admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		require(store.loadDevices().length == 0, "Device migration created unexpected rows");
		store.close();
		admin = Database.open(path);
		admin.exec("DROP TABLE workspace_devices; CREATE TABLE workspace_agent_metadata (operation TEXT PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO workspace_agent_metadata VALUES('preserved',x'01'); PRAGMA user_version=5");
		admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		require(store.loadDevices().length == 0, "Legacy v5 metadata catalog did not gain device storage");
		store.close();
		admin = Database.open(path);
		var preserved = admin.prepare("SELECT count(*) FROM workspace_agent_metadata WHERE operation='preserved'");
		require(preserved.step() && preserved.columnInt64(0) == 1, "Device migration lost existing agent metadata");
		preserved.close(); admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		var record:WorkspaceDeviceRecord = {
			deviceId: deviceId,
			staticPublicKey: key,
			grants: [WorkspaceProtocol.READ, WorkspaceProtocol.TREE],
			revoked: false
		};
		store.saveDevice(record);
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		var loaded = store.loadDevices();
		require(loaded.length == 1 && loaded[0].deviceId == deviceId && !loaded[0].revoked,
			"Pinned device did not persist");
		require(loaded[0].staticPublicKey.length == key.length && loaded[0].grants.length == 2,
			"Device key or explicit grants did not persist");
		for (index in 0...key.length)
			require(loaded[0].staticPublicKey.get(index) == key.get(index), "Device public key changed in storage");
		store.revokeDevice(deviceId);
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		require(store.loadDevices()[0].revoked, "Device revocation did not persist");
		store.close();
		sys.FileSystem.deleteFile(path);
		if (sys.FileSystem.exists(path + ".sqlitekit-lock")) sys.FileSystem.deleteFile(path + ".sqlitekit-lock");
	}

	static function main():Void {
		var path = Sys.args()[0];
		devicePersistence(path + ".devices");
		var store = new WorkspaceSqliteStore(path, "workspace", seed());
		var catalog = service(store), link = connect(catalog);
		var events = 0;
		link.client.onNotification(WorkspaceProtocol.CHANGED, WorkspaceProtocol.decodeEvent, function(_) {
			events++;
		});
		link.client.call(WorkspaceProtocol.WATCH, {workspace: "workspace", epoch: "first", cursor: 0}, 100, function(_) {}, function(_) throw "Watch failed");
		pump(link);
		rename(link, "op-1", 1, "Saved");
		require(events == 1, "Committed event missing");
		store.close();
		var fresh = seed();
		fresh.epoch = "different-seed";
		store = new WorkspaceSqliteStore(path, "workspace", fresh);
		catalog = service(store);
		link = connect(catalog);
		require(catalog.epoch == "first"
			&& catalog.snapshot().cursor == 1
			&& catalog.snapshot().groups[0].name == "Saved", "Restart lost durable catalog");
		rename(link, "op-1", 1, "Saved");
		require(catalog.snapshot().cursor == 1, "Duplicate mutated after restart");
		rename(link, "op-1", 1, "Conflict", "operation_conflict");
		rename(link, "stale", 1, "Stale", "stale_revision");
		var lookup = false;
		link.client.call(WorkspaceProtocol.OPERATION, {workspace: "workspace", epoch: "first", operation: "op-1"}, 100, function(value) {
			lookup = value.known && value.outcome != null && value.outcome.group.name == "Saved";
		}, function(_) throw "Lookup failed");
		pump(link);
		require(lookup, "Restart lost operation outcome");
		for (index in 2...36)
			rename(link, "op-" + index, index, "Name " + index);
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		var replay = false, reset = false;
		link.client.call(WorkspaceProtocol.WATCH, {workspace: "workspace", epoch: "first", cursor: 33}, 100, function(value) {
			replay = !value.reset && value.events.length == 2 && value.events[0].sequence == 34;
		}, function(_) throw "Replay failed");
		pump(link);
		require(replay, "Restart lost retained events");
		link.client.call(WorkspaceProtocol.WATCH, {workspace: "workspace", epoch: "first", cursor: 0}, 100, function(value) {
			reset = value.reset;
		}, function(_) throw "Reset failed");
		pump(link);
		require(reset, "Expired cursor did not reset");
		// Abort after the group and operation writes: the entire transaction must roll back.
		store.close();
		var admin = Database.open(path);
		admin.exec("CREATE TRIGGER fail_event BEFORE INSERT ON workspace_events BEGIN SELECT RAISE(ABORT,'injected event failure'); END");
		admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		link.client.call(WorkspaceProtocol.WATCH, {workspace: "workspace", epoch: "first", cursor: 35}, 100, function(_) {}, function(_) throw "Watch failed");
		pump(link);
		events = 0;
		link.client.onNotification(WorkspaceProtocol.CHANGED, WorkspaceProtocol.decodeEvent, function(_) {
			events++;
		});
		rename(link, "failed", 36, "Must not commit", "storage_failed");
		require(catalog.snapshot().cursor == 35 && events == 0, "Failed transaction published state");
		var fenced = false;
		link.client.call(WorkspaceProtocol.QUERY, {workspace: "workspace"}, 100, function(_) throw "Failed storage served a snapshot", function(error) {
			fenced = error.code == "storage_unavailable";
		});
		pump(link);
		require(fenced, "Failed storage not fenced");
		store.close();
		admin = Database.open(path);
		admin.exec("DROP TRIGGER fail_event");
		admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		require(catalog.snapshot().cursor == 35 && catalog.snapshot().groups[0].revision == 36, "SQL rollback incomplete");
		rename(link, "failed", 36, "Recovered");
		// The generic database wrapper owns an exclusive lifetime lock as well.
		rejects(function() {
			var duplicate = new WorkspaceSqliteStore(path, "workspace", seed());
			duplicate.close();
		}, "Duplicate database owner accepted");
		rename(link, "winner", 37, "Winner");
		// SQL cursor CAS remains a second fence against invalid/stale commits.
		rejects(function() store.commit({
			workspace: "workspace",
			epoch: "first",
			operation: "loser",
			group: "work",
			expectedRevision: 37,
			name: "Loser"
		}, {
			epoch: "first",
			operation: "loser",
			sequence: 37,
			group: {
				id: "work",
				name: "Loser",
				cwd: "/workspace",
				revision: 38
			}
		}, {
			epoch: "first",
			sequence: 37,
			group: {
				id: "work",
				name: "Loser",
				cwd: "/workspace",
				revision: 38
			}
		}), "Stale cursor accepted");
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		for (index in 38...257)
			rename(link, "op-" + index, index, "Name " + index);
		rename(link, "overflow", 257, "Overflow", "operation_limit");
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		require(catalog.snapshot().cursor == 256, "Retained outcome bounds lost after restart");
		rename(link, "op-1", 1, "Saved");
		rename(link, "overflow", 257, "Overflow", "operation_limit");
		store.close();
		rejects(function() {
			var wrong = new WorkspaceSqliteStore(path, "other", seed());
			try
				wrong.load()
			catch (error:Dynamic) {
				wrong.close();
				throw error;
			}
			wrong.close();
		}, "Wrong workspace accepted");
		admin = Database.open(path);
		admin.exec("UPDATE workspace_groups SET payload=zeroblob(8193)");
		admin.close();
		rejects(function() {
			var corrupt = new WorkspaceSqliteStore(path, "workspace", seed());
			try
				service(corrupt)
			catch (error:Dynamic) {
				corrupt.close();
				throw error;
			}
			corrupt.close();
		}, "Oversized corrupt payload accepted");
		admin = Database.open(path);
		admin.exec("PRAGMA user_version=999");
		admin.close();
		rejects(function() {
			var unsupported = new WorkspaceSqliteStore(path, "workspace", seed());
			unsupported.close();
		}, "Unknown schema accepted");
		Sys.println("PASS: durable catalog/outcomes/events, restart idempotence, atomic rollback, stale-writer fence, bounds and schema refusal");
	}
}
