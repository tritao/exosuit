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

	static function connect(service:WorkspaceService, tree:Bool = false):Link {
		var caps = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE];
		if (tree) caps.push(WorkspaceProtocol.TREE);
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
		store.saveDevice({deviceId: deviceId, staticPublicKey: key,
			grants: [WorkspaceProtocol.READ, workspace.service.WorkspaceScmProtocol.READ], revoked: false});
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		loaded = store.loadDevices();
		require(loaded.length == 1 && loaded[0].grants.length == 2
			&& loaded[0].grants.indexOf(WorkspaceProtocol.READ) >= 0
			&& loaded[0].grants.indexOf(workspace.service.WorkspaceScmProtocol.READ) >= 0
			&& loaded[0].grants.indexOf(WorkspaceProtocol.TREE) < 0,
			"Owner-edited grants did not survive reopening the device store");
		store.revokeDevice(deviceId);
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed);
		require(store.loadDevices()[0].revoked, "Device revocation did not persist");
		store.close();
		sys.FileSystem.deleteFile(path);
		if (sys.FileSystem.exists(path + ".sqlitekit-lock")) sys.FileSystem.deleteFile(path + ".sqlitekit-lock");
	}

	/** A group directory stored in its canonical spelling must not stop the catalog from reopening. */
	static function canonicalDirectory(path:String):Void {
		for (file in [path, path + ".sqlitekit-lock"]) if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
		var resolve = function(value:String):Null<String> return value.toLowerCase();
		var caps = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE];
		function open():{store:WorkspaceSqliteStore, link:Link, service:WorkspaceService} {
			var store = new WorkspaceSqliteStore(path, "workspace", seed());
			var service = new WorkspaceService("workspace", "ignored-on-reopen", seed().groups, 32, 256, 16, store, resolve);
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
			link.client.call(WorkspaceProtocol.GROUP, {workspace: "workspace", epoch: "first", operation: operation, group: "docs",
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

	static function removeCatalog(path:String):Void
		for (suffix in ["", "-wal", "-shm", "-journal", ".sqlitekit-lock"]) if (sys.FileSystem.exists(path + suffix)) sys.FileSystem.deleteFile(path + suffix);

	/** Every row of the catalog's group, item, history, content and meta tables, to compare two states of it. */
	static function dump(path:String):String {
		var database = Database.open(path), rows:Array<String> = [];
		for (sql in ["SELECT id||'|'||revision||'|'||hex(payload) FROM workspace_groups ORDER BY id",
			"SELECT id||'|'||hex(payload) FROM workspace_terminals ORDER BY id", "SELECT id||'|'||hex(payload) FROM workspace_agents ORDER BY id",
			"SELECT id||'|'||hex(payload) FROM workspace_terminal_history ORDER BY id",
			"SELECT session||'|'||item||'|'||hex(payload) FROM workspace_agent_content ORDER BY seq", "SELECT epoch||'|'||cursor FROM workspace_meta",
			"SELECT 'operations '||count(*) FROM workspace_operations", "SELECT 'events '||count(*) FROM workspace_events"]) {
			var row = database.prepare(sql);
			while (row.step()) rows.push(row.columnText(0));
			row.close();
			rows.push("--");
		}
		database.close();
		return rows.join("\n");
	}

	static function terminal(id:String, group:String, order:Null<Int>):workspace.service.WorkspaceTerminalProtocol.TerminalRecord
		return {id: id, name: id, group: group, cwd: "/workspace/" + id, instance: "old", state: "exited", exitCode: 0, available: false,
			revision: haxe.Int64.ofInt(4), workspaceRoot: "/workspace", order: order};

	static function createGroup(link:Link, id:String, parent:String):Void {
		var created = false;
		link.client.call(WorkspaceProtocol.GROUP, {workspace: "workspace", epoch: "first", operation: "create-" + id, group: id,
			expectedRevision: 0, name: id, action: "create", parent: parent, cwd: null, order: 0}, 100,
			function(_) created = true, function(error) throw "create-" + id + " failed: " + error.code);
		pump(link);
		require(created, "Group " + id + " was not created");
	}

	/**
		A catalog from before the workspace was the default group: the seeded "work" group holds a terminal (with
		history), a session (with stored content) and a child group, and group operations name it. A start removes it
		once: its contents go to the workspace root after the root's own rows, nothing is lost, the operations and events
		are dropped under a new epoch, and the service restores. A second start changes nothing.
	**/
	static function seedGroupRetirement(path:String):Void {
		removeCatalog(path);
		var store = new WorkspaceSqliteStore(path, "workspace", seed());
		var catalog = service(store), link = connect(catalog, true);
		rename(link, "op-1", 1, "Work renamed");
		createGroup(link, "docs", "work");
		require(catalog.snapshot().cursor == 2, "Group operations were not stored");
		store.saveTerminal(terminal("root-terminal", "", 3000));
		store.saveTerminal(terminal("work-terminal", "work", 0));
		store.saveTerminalHistory("work-terminal", {version: 1, columns: 80, rows: 24, data: Bytes.ofString("history")});
		store.saveAgent({id: "work-agent", name: "Session", group: "work", cwd: "/workspace/agent", thread: "thread", state: "disconnected",
			turn: null, workspaceRoot: "/workspace", provider: "codex", order: 1});
		store.saveAgentContent("codex", "work-agent", "turn", "item", Bytes.ofString("answer"), false);
		store.close();

		store = new WorkspaceSqliteStore(path, "workspace", seed());
		require(store.retireSeedGroup("renewed", "/workspace"), "The Work group was not found");
		catalog = service(store);
		var snapshot = catalog.snapshot();
		require(catalog.epoch == "renewed" && snapshot.cursor == 0, "The epoch was not renewed");
		require(snapshot.groups.length == 1 && snapshot.groups[0].id == "docs", "The Work group is still there");
		var docs = snapshot.groups[0];
		require(docs.parent == null && docs.cwd == null && docs.revision == 2, "The child group did not move to the workspace root");
		var terminals = store.loadTerminals(), agents = store.loadAgents();
		function find(id:String):workspace.service.WorkspaceTerminalProtocol.TerminalRecord {
			for (terminal in terminals) if (terminal.id == id) return terminal;
			throw "Terminal " + id + " was lost";
		}
		var root = find("root-terminal"), moved = find("work-terminal");
		require(terminals.length == 2 && root.group == "" && WorkspaceProtocol.order(root.order) == 3000, "A root terminal changed");
		require(moved.group == "" && moved.cwd == "/workspace/work-terminal" && haxe.Int64.toInt(moved.revision) == 5,
			"The terminal did not move to the root");
		require(agents.length == 1 && agents[0].group == "" && agents[0].cwd == "/workspace/agent", "The session did not move to the root");
		// After the root's last row (3000), in the order they had in Work: the group and terminal (0), then the session (1).
		var groupOrder = WorkspaceProtocol.order(docs.order), terminalOrder = WorkspaceProtocol.order(moved.order);
		require(groupOrder > 3000 && terminalOrder > groupOrder && WorkspaceProtocol.order(agents[0].order) > terminalOrder,
			"Moved rows collide with the root's");
		var history = store.loadTerminalHistory("work-terminal");
		require(history != null, "Terminal history was lost");
		if (history != null) require(history.data.toString() == "history", "Terminal history changed");
		var content = store.loadAgentContent("codex", "work-agent", "turn", "item");
		require(content != null, "Stored session content was lost");
		if (content != null) require(content.bytes.toString() == "answer", "Stored session content changed");
		// The restored service takes edits under the new epoch.
		link = connect(catalog);
		var renamed = false;
		link.client.call(WorkspaceProtocol.RENAME, {workspace: "workspace", epoch: "renewed", operation: "after", group: "docs", expectedRevision: 2,
			name: "Docs renamed"}, 100, function(_) renamed = true, function(error) throw "Rename after removal failed: " + error.code);
		pump(link);
		require(renamed && catalog.snapshot().cursor == 1, "The restored service did not take an edit");
		store.close();

		var before = dump(path);
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		require(!store.retireSeedGroup("again", "/workspace"), "A second start found a Work group");
		catalog = service(store);
		require(catalog.epoch == "renewed" && catalog.snapshot().cursor == 1, "A second start changed the catalog");
		store.close();
		require(dump(path) == before, "A second start changed stored rows");
		removeCatalog(path);

		// A Work group whose folder is not the workspace's: a child group without a folder keeps the one it had.
		var elsewhere = seed();
		elsewhere.groups[0].cwd = "/elsewhere";
		store = new WorkspaceSqliteStore(path, "workspace", elsewhere);
		catalog = new WorkspaceService("workspace", "ignored", elsewhere.groups, 32, 256, 16, store);
		createGroup(connect(catalog, true), "tools", "work");
		store.close();
		store = new WorkspaceSqliteStore(path, "workspace", seed());
		require(store.retireSeedGroup("renewed", "/workspace"), "The Work group was not found");
		var tools = service(store).snapshot().groups;
		require(tools.length == 1 && tools[0].parent == null && tools[0].cwd == "/elsewhere", "The child group lost the folder it had through Work");
		store.close();
		removeCatalog(path);
	}

	static function main():Void {
		var path = Sys.args()[0];
		seedGroupRetirement(path + ".seed-group");
		canonicalDirectory(path + ".canonical");
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
