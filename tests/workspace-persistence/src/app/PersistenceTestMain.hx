package app;

import haxeon.rpc.*;
import sqlitekit.Database;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceProtocol;
import workspace.transport.RpcCalls;

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
		return new WorkspaceService("workspace", "ignored-on-reopen", seed().groups, 256, 16, store);

	static function connect(service:WorkspaceService):Link {
		var caps = [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE];
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
		RpcCalls.call(link.client, WorkspaceProtocol.GROUP, {
			workspace: "workspace",
			epoch: "first",
			operation: operation,
			group: "work",
			expectedRevision: revision,
			name: name,
			action: "update", parent: null, cwd: "/workspace", order: 0
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

	/** A group directory stored in its canonical spelling must not stop the catalog from reopening. */
	static function canonicalDirectory(path:String):Void {
		for (file in [path, path + ".sqlitekit-lock"]) if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
		var resolve = function(value:String):Null<String> return value.toLowerCase();
		var caps = [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE];
		function open():{store:WorkspaceSqliteStore, link:Link, service:WorkspaceService} {
			var store = new WorkspaceSqliteStore(path, "workspace", seed());
			var service = new WorkspaceService("workspace", "ignored-on-reopen", seed().groups, 256, 16, store, resolve);
			var pair = MemoryTransport.pair(1048576, 128), clock = function() return 0.0;
			var client = RpcHandshake.client(pair.client, clock, new RpcPeerOptions("test", caps), caps);
			var server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("test", caps));
			for (_ in 0...8) { client.poll(); server.poll(); }
			service.bind(server.connection, caps);
			return {store: store, link: {client: client.connection, server: server.connection}, service: service};
		}
		var first = open();
		function group(link:Link, operation:String, action:String, revision:Int, cwd:Null<String>):Void {
			var done = false;
			RpcCalls.call(link.client, WorkspaceProtocol.GROUP, {workspace: "workspace", epoch: "first", operation: operation, group: "docs",
				expectedRevision: revision, name: "Docs", action: action, parent: "work", cwd: cwd, order: 0}, 100,
				function(_) done = true, function(error) throw operation + " failed: " + error.code);
			pump(link);
			require(done, operation + " did not complete");
		}
		group(first.link, "create-docs", "create", 0, null);
		group(first.link, "move-docs", "update", 1, "/Workspace/Docs");
		group(first.link, "rename-docs", "update", 2, "/workspace/docs");
		first.store.close();
		var reopened = open();
		var docs = Lambda.find(reopened.service.snapshot().groups, function(g) return g.id == "docs");
		require(docs != null && docs.cwd == "/workspace/docs" && docs.revision == 3, "Canonical group directory did not reopen");
		reopened.store.close();
		for (file in [path, path + ".sqlitekit-lock"]) if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
	}

	static function main():Void {
		var path = Sys.args()[0];
		canonicalDirectory(path + ".canonical");
		var store = new WorkspaceSqliteStore(path, "workspace", seed());
		var catalog = service(store), link = connect(catalog);
		rename(link, "op-1", 1, "Saved");
		store.close();
		var fresh = seed();
		fresh.epoch = "different-seed";
		store = new WorkspaceSqliteStore(path, "workspace", fresh);
		catalog = service(store);
		link = connect(catalog);
		require(catalog.epoch == "first"
			&& catalog.snapshot().cursor == 1
			&& catalog.snapshot().groups[0].name == "Saved", "Restart lost durable catalog");
		// A retry of a stored operation answers its recorded outcome without mutating again.
		rename(link, "op-1", 1, "Saved");
		require(catalog.snapshot().cursor == 1, "Duplicate mutated after restart");
		rename(link, "op-1", 1, "Conflict", "operation_conflict");
		rename(link, "stale", 1, "Stale", "stale_revision");
		for (index in 2...36)
			rename(link, "op-" + index, index, "Name " + index);
		// Abort at the operation write, after the meta and group writes: the entire transaction must roll back.
		store.close();
		var admin = Database.open(path);
		admin.exec("CREATE TRIGGER fail_operation BEFORE INSERT ON workspace_operations BEGIN SELECT RAISE(ABORT,'injected operation failure'); END");
		admin.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		catalog = service(store);
		link = connect(catalog);
		rename(link, "failed", 36, "Must not commit", "storage_failed");
		require(catalog.snapshot().cursor == 35, "Failed transaction changed state");
		var fenced = false;
		RpcCalls.call(link.client, WorkspaceProtocol.QUERY, {workspace: "workspace"}, 100, function(_) throw "Failed storage served a snapshot", function(error) {
			fenced = error.code == "storage_unavailable";
		});
		pump(link);
		require(fenced, "Failed storage not fenced");
		store.close();
		admin = Database.open(path);
		admin.exec("DROP TRIGGER fail_operation");
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
		Sys.println("PASS: durable catalog/outcomes, restart idempotence, atomic rollback, stale-writer fence, bounds and schema refusal");
	}
}
