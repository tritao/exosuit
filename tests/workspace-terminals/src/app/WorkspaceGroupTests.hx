package app;

import haxeon.rpc.*;
import haxe.io.Bytes;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceService;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.runtime.WorkspaceDirectories;
import sys.FileSystem;

class WorkspaceGroupTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	public static function run(root:String):Void {
		var child = root + "/group dir";
		FileSystem.createDirectory(child);
		var directories = new WorkspaceDirectories(root);
		require(directories.resolve("group dir") == child, "Relative directory did not resolve inside root");
		require(directories.resolve(root + "/../") == null, "Outside directory authorized");
		var seed = new WorkspaceService("w", "groups", [
			{
				id: "work",
				name: "Work",
				cwd: root,
				revision: 1
			}
		]);
		var store = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), 32, root);
		var service = new WorkspaceService("w", "groups", seed.snapshot().groups, 32, 256, 16, store, directories.resolve);
		var clock = function() return Sys.time() * 1000;
		var pair = MemoryTransport.pair(),
			client = new RpcConnection(pair.client, clock),
			server = new RpcConnection(pair.server, clock);
		var grants = [
			WorkspaceProtocol.READ,
			WorkspaceProtocol.WRITE,
			WorkspaceProtocol.TREE,
			WorkspaceProtocol.EVENTS,
			WorkspaceTerminalProtocol.READ,
			WorkspaceTerminalProtocol.CONTROL,
			WorkspaceTerminalProtocol.CATALOG
		];
		service.bind(server, grants);
		var readPair = MemoryTransport.pair(),
			readClient = new RpcConnection(readPair.client, clock),
			readServer = new RpcConnection(readPair.server, clock);
		service.bind(readServer, [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS]);
		var replica = new workspace.service.WorkspaceReplica("w");
		replica.restore(readClient, function() return true);
		var terminals = new WorkspaceTerminalManager("w", "owner", root, 65536, store, function() return service.snapshot().groups);
		terminals.bind(server, grants);
		function pump():Void {
			client.poll();
			server.poll();
			terminals.poll();
			client.poll();
			readClient.poll();
			readServer.poll();
			readClient.poll();
		}
		for (_ in 0...4)
			pump();
		require(replica.ready, "Read-only observer failed to subscribe");
		var counter = 0;
		function change(id:String, name:String, parent:Null<String>, cwd:Null<String>, revision:Int, action:String, ?error:String):Null<RenameResult> {
			counter++;
			var request:RenameGroup = {
				workspace: "w",
				epoch: "groups",
				operation: "group-op-" + counter,
				group: id,
				name: name,
				expectedRevision: revision,
				action: action,
				parent: parent,
				cwd: cwd,
				order: counter
			};
			var result:Null<RenameResult> = null, code = "";
			client.call(WorkspaceProtocol.GROUP, request, 1000, function(r) result = r, function(e) code = e.code);
			pump();
			require(error == null ? result != null && code == "" : code == error, "Group mutation " + id + " failed: " + code);
			if (result != null) {
				var expectedSequence = result.sequence;
				var repeated:Null<RenameResult> = null;
				client.call(WorkspaceProtocol.GROUP, request, 1000, function(r) repeated = r, function(e) throw e.message);
				pump();
				require(repeated != null && repeated.sequence == expectedSequence, "Repeated group mutation changed sequence");
			}
			return result;
		}
		change("parent", "Same", "work", child, 0, "create");
		change("nested", "Same", "parent", null, 0, "create");
		change("other", "Same", "work", root, 0, "create");
		require(replica.view().length == 4, "Second client missed group creation");
		var denied = "";
		readClient.call(WorkspaceProtocol.GROUP, {
			workspace: "w",
			epoch: "groups",
			operation: "denied",
			group: "forbidden",
			name: "X",
			expectedRevision: 0,
			action: "create"
		}, 1000, function(_) throw "Read-only peer mutated groups",
			function(e) denied = e.code);
		pump();
		pump();
		require(denied == "unauthorized", "Read-only group mutation was not denied");
		var legacy = "";
		client.call(WorkspaceProtocol.RENAME, {
			workspace: "w",
			epoch: "groups",
			operation: "legacy-create",
			group: "forbidden",
			name: "X",
			expectedRevision: 0,
			action: "create"
		}, 1000,
			function(_) throw "Legacy method bypassed tree capability", function(e) legacy = e.code);
		pump();
		require(legacy == "invalid_request", "Legacy rename accepted group creation");
		change("parent", "Same", "nested", child, 1, "update", "invalid_group");
		change("nested", "Same", "missing", null, 1, "update", "invalid_group");
		change("other", "Same", "work", root + "/../", 1, "update", "invalid_group");
		change("nested", "Same", "parent", null, 0, "update", "invalid_request");
		var info:Null<TerminalInfo> = null;
		client.call(WorkspaceTerminalProtocol.OPEN, {
			workspace: "w",
			instance: "owner",
			id: "inherited",
			create: true,
			columns: 80,
			rows: 24,
			group: "nested"
		}, 1000, function(i) info = i, function(e) throw e.message);
		pump();
		require(info != null && info.cwd == child, "Nested group directory was not inherited");
		client.call(WorkspaceTerminalProtocol.INPUT, {
			workspace: "w",
			instance: "owner",
			id: "inherited",
			sequence: 1,
			data: Bytes.ofString("printf 'GROUP_CWD:'; pwd\n")
		}, 1000, function(_) {}, function(e) throw e.message);
		pump();
		var output = "", deadline = clock() + 3000;
		while (output.indexOf("GROUP_CWD:" + child) < 0 && clock() < deadline) {
			Sys.sleep(0.005);
			pump();
			client.call(WorkspaceTerminalProtocol.OUTPUT, {
				workspace: "w",
				instance: "owner",
				id: "inherited",
				offset: 0
			}, 1000, function(v) output = v.data.toString(), function(e) throw e.message);
			pump();
		}
		require(output.indexOf("GROUP_CWD:" + child) >= 0, "Actual shell did not launch in inherited directory");
		change("nested", "Renamed", "other", null, 1, "update");
		change("work", "Work renamed", null, child, 1, "update");
		change("nested", "Stale", "work", null, 1, "update", "stale_revision");
		var observed = Lambda.find(replica.view(), function(g) return g.id == "nested");
		require(observed != null && observed.parent == "other" && observed.name == "Renamed", "Second client missed group move/rename");
		var listing:Null<TerminalCatalog> = null;
		client.call(WorkspaceTerminalProtocol.LIST, {workspace: "w", instance: "owner", after: null}, 1000, function(v) listing = v,
			function(e) throw e.message);
		pump();
		require(listing != null && listing.terminals[0].cwd == child, "Moving group changed running cwd");
		var invalid = "";
		client.call(WorkspaceTerminalProtocol.OPEN, {
			workspace: "w",
			instance: "owner",
			id: "outside",
			create: true,
			columns: 80,
			rows: 24,
			group: "nested",
			directory: root + "/../"
		}, 1000, function(_) throw "Outside terminal launched",
			function(e) invalid = e.code);
		pump();
		require(invalid == "invalid_directory", "Outside override was accepted");
		var overrideInfo:Null<TerminalInfo> = null;
		client.call(WorkspaceTerminalProtocol.OPEN, {
			workspace: "w",
			instance: "owner",
			id: "override",
			create: true,
			columns: 80,
			rows: 24,
			group: "nested",
			directory: child
		}, 1000, function(v) overrideInfo = v, function(e) throw e.message);
		pump();
		require(overrideInfo != null && overrideInfo.cwd == child, "Explicit directory override lost");
		client.close();
		server.close();
		readClient.close();
		readServer.close();
		terminals.dispose();
		store.close();
		store = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), 32, root);
		var wrongRoot = false;
		try {
			var wrong = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), 32, child);
			wrong.close();
		} catch (_:Dynamic)
			wrongRoot = true;
		require(wrongRoot, "Group directory change redirected the database authorization root");
		var recovered = new WorkspaceService("w", "ignored", seed.snapshot().groups, 32, 256, 16, store, directories.resolve);
		var groups = recovered.snapshot().groups;
		require(groups.length == 4, "Created groups did not survive restart");
		var nested = Lambda.find(groups, function(g) return g.id == "nested");
		require(nested != null && nested.name == "Renamed" && nested.parent == "other" && nested.revision == 2, "Nested group state did not survive restart");

		store.close();
		// A failed legacy-root migration must leave the old schema reopenable by its correct owner.
		var legacyStore = new WorkspaceSqliteStore(root + "/legacy-root.sqlite", "w", seed.snapshot());
		legacyStore.close();
		var legacyDb = sqlitekit.Database.open(root + "/legacy-root.sqlite");
		legacyDb.exec("DROP TABLE workspace_agents; ALTER TABLE workspace_meta DROP COLUMN root; PRAGMA user_version=2");
		legacyDb.close();
		var rejectedLegacy = false;
		try {
			var wrong = new WorkspaceSqliteStore(root + "/legacy-root.sqlite", "w", seed.snapshot(), 32, child);
			wrong.close();
		} catch (_:Dynamic)
			rejectedLegacy = true;
		require(rejectedLegacy, "Legacy root mismatch was accepted");
		legacyStore = new WorkspaceSqliteStore(root + "/legacy-root.sqlite", "w", seed.snapshot(), 32, root);
		require(legacyStore.load().snapshot.cursor == 0, "Failed root migration prevented correct-owner recovery");
		legacyStore.close();

		var wideName = "", wideRoot = "";
		for (_ in 0...128)
			wideName += "😀";
		for (_ in 0...1024)
			wideRoot += "😀";
		var wide:TerminalRecord = {
			id: wideName,
			name: wideName,
			group: wideName,
			cwd: wideRoot,
			instance: wideName,
			state: "exited",
			exitCode: 0,
			available: false,
			revision: 1,
			workspaceRoot: wideRoot
		};
		require(haxeon.wire.MessagePack.encode(wide).length > 8192, "Unicode metadata fixture did not exercise expanded blob budget");
		var wideStore = new WorkspaceSqliteStore(root + "/wide-metadata.sqlite", "w", seed.snapshot());
		wideStore.saveTerminal(wide);
		var wideRead = wideStore.loadTerminals();
		require(wideRead.length == 1 && wideRead[0].workspaceRoot == wideRoot, "Large bounded Unicode metadata failed SQLite roundtrip");
		wideStore.close();
		Sys.println("PASS: nested groups, duplicate names, CAS/idempotency, cycles, directory inheritance/overrides, running cwd stability and SQLite restart");
	}
}
