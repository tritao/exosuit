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
import workspace.transport.RpcCalls;

class WorkspaceGroupTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	public static function run(root:String):Void {
		FileSystem.createDirectory(root + "/group dir");
		// The form the service reports, which uses the platform's separators.
		var child = FileSystem.fullPath(root + "/group dir");
		var directories = new WorkspaceDirectories(root);
		require(directories.resolve("group dir") == child, "Relative directory did not resolve inside root");
		require(directories.resolve(root + "/../") != null, "An existing folder outside the workspace was refused");
		require(directories.resolve(root + "/missing") == null, "A missing folder was accepted");
		var seed = new WorkspaceService("w", "groups", [
			{
				id: "work",
				name: "Work",
				cwd: root,
				revision: 1
			}
		]);
		var store = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), root);
		var service = new WorkspaceService("w", "groups", seed.snapshot().groups, 256, 16, store, directories.resolve);
		var clock = function() return Sys.time() * 1000;
		var pair = MemoryTransport.pair(),
			client = new RpcConnection(pair.client, clock),
			server = new RpcConnection(pair.server, clock);
		var grants = [
			WorkspaceProtocol.READ,
			WorkspaceProtocol.WRITE,
			WorkspaceProtocol.TREE,
			WorkspaceProtocol.REMOVE,
			WorkspaceTerminalProtocol.READ,
			WorkspaceTerminalProtocol.CONTROL,
			WorkspaceTerminalProtocol.CATALOG
		];
		service.bind(server, grants);
		var readPair = MemoryTransport.pair(),
			readClient = new RpcConnection(readPair.client, clock),
			readServer = new RpcConnection(readPair.server, clock);
		service.bind(readServer, [WorkspaceProtocol.READ]);
		var terminals = TestTerminals.manager("w", "owner", root, 65536, store, function() return service.snapshot().groups);
		terminals.bind(server, grants);
		var allowRemoval = true;
		service.canRemoveGroup = function(group) {
			if (!allowRemoval) return false;
			for (terminal in terminals.snapshot().terminals) if (terminal.group == group) return false;
			return true;
		};
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
		// The groups the read-only client sees.
		function readGroups():Array<WorkspaceGroup> {
			var got:Null<WorkspaceSnapshot> = null;
			RpcCalls.call(readClient, WorkspaceProtocol.QUERY, {workspace: "w"}, 1000, function(value) got = value, function(e) throw e.message);
			pump();
			var answered = got;
			if (answered == null) throw "QUERY was not answered";
			return answered.groups;
		}
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
			RpcCalls.call(client, WorkspaceProtocol.GROUP, request, 1000, function(r) result = r, function(e) code = e.code);
			pump();
			require(error == null ? result != null && code == "" : code == error, "Group mutation " + id + " failed: " + code);
			if (result != null) {
				var expectedSequence = result.sequence;
				var repeated:Null<RenameResult> = null;
				RpcCalls.call(client, WorkspaceProtocol.GROUP, request, 1000, function(r) repeated = r, function(e) throw e.message);
				pump();
				require(repeated != null && repeated.sequence == expectedSequence, "Repeated group mutation changed sequence");
			}
			return result;
		}
		change("parent", "Same", "work", child, 0, "create");
		change("nested", "Same", "parent", null, 0, "create");
		change("other", "Same", "work", root, 0, "create");
		require(readGroups().length == 4, "Second client missed group creation");
		var denied = "";
		RpcCalls.call(readClient, WorkspaceProtocol.GROUP, {
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
		change("parent", "Same", "nested", child, 1, "update", "invalid_group");
		change("nested", "Same", "missing", null, 1, "update", "invalid_group");
		change("other", "Same", "work", root + "/missing", 1, "update", "invalid_directory");
		var canonical = change("other", "Same", "work", root + "/./group dir", 1, "update");
		require(canonical != null && canonical.group.cwd == child, "Group directory was not stored in its canonical form");
		change("other", "Same", "work", root, 2, "update");
		change("nested", "Same", "parent", null, 0, "update", "invalid_request");
		var info:Null<TerminalInfo> = null;
		RpcCalls.call(client, WorkspaceTerminalProtocol.OPEN, {
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
		RpcCalls.call(client, WorkspaceTerminalProtocol.INPUT, {
			workspace: "w",
			instance: "owner",
			id: "inherited",
			sequence: 1,
			data: TestShell.workingDirectory("GROUP_CWD:")
		}, 1000, function(_) {}, function(e) throw e.message);
		pump();
		// PowerShell on a loaded Windows machine takes more than 3 s to print its first line.
		var output = "", deadline = clock() + 15000;
		while (output.indexOf("GROUP_CWD:" + child) < 0 && clock() < deadline) {
			Sys.sleep(0.005);
			pump();
			RpcCalls.call(client, WorkspaceTerminalProtocol.REPLAY, {
				workspace: "w",
				instance: "owner",
				id: "inherited",
				cursor: 0
			}, 1000, function(v) output = [for (event in v.events) event.data.toString()].join(""), function(e) throw e.message);
			pump();
		}
		require(output.indexOf("GROUP_CWD:" + child) >= 0, "Actual shell did not launch in inherited directory:\n" + output);
		change("nested", "Renamed", "other", null, 1, "update");
		change("work", "Work renamed", null, child, 1, "update");
		change("nested", "Stale", "work", null, 1, "update", "stale_revision");
		var observed = Lambda.find(readGroups(), function(g) return g.id == "nested");
		require(observed != null && observed.parent == "other" && observed.name == "Renamed", "Second client missed group move/rename");
		var listing:Null<TerminalCatalog> = null;
		RpcCalls.call(client, WorkspaceTerminalProtocol.LIST, {workspace: "w", instance: "owner", after: null}, 1000, function(v) listing = v,
			function(e) throw e.message);
		pump();
		require(listing != null && listing.terminals[0].cwd == child, "Moving group changed running cwd");
		// An explicit directory must be an existing folder, by its full path or relative to the root.
		for (refused in [root + "/missing-folder", "missing-folder"]) {
			var invalid = "";
			RpcCalls.call(client, WorkspaceTerminalProtocol.OPEN, {
				workspace: "w",
				instance: "owner",
				id: "refused",
				create: true,
				columns: 80,
				rows: 24,
				group: "nested",
				directory: refused
			}, 1000, function(_) throw "Terminal launched in " + refused,
				function(e) invalid = e.code);
			pump();
			require(invalid == "invalid_directory", "Invalid override was accepted: " + refused);
		}
		var overrideInfo:Null<TerminalInfo> = null;
		RpcCalls.call(client, WorkspaceTerminalProtocol.OPEN, {
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
		for (occupied in ["work", "nested"]) {
			var base = Lambda.find(service.snapshot().groups,function(group) return group.id == occupied);
			if (base == null) throw "missing occupied group";
			var deniedRemoval = "";
			RpcCalls.call(client, WorkspaceProtocol.GROUP,{workspace:"w",epoch:"groups",operation:"reject-delete-" + occupied,
				group:base.id,expectedRevision:base.revision,name:base.name,action:"delete",parent:base.parent,cwd:base.cwd,order:base.order},1000,
				function(_) throw "removed an occupied group",function(error) deniedRemoval=error.code);
			pump();
			require(deniedRemoval == "group_not_empty", "group removal ignored children or retained terminals");
		}
		change("delete-me", "Empty group", null, null, 0, "create");
		var deletionBase = Lambda.find(service.snapshot().groups, function(group) return group.id == "delete-me");
		if (deletionBase == null) throw "missing deletion fixture";
		var deletion:RenameGroup = {workspace:"w",epoch:"groups",operation:"delete-empty",group:deletionBase.id,
			expectedRevision:deletionBase.revision,name:deletionBase.name,action:"delete",parent:deletionBase.parent,cwd:deletionBase.cwd,order:deletionBase.order};
		var deletionResult:Null<RenameResult> = null, deletionError = "";
		allowRemoval = false;
		RpcCalls.call(client, WorkspaceProtocol.GROUP,deletion,1000,function(value) deletionResult=value,function(error) deletionError=error.code);
		pump();
		require(deletionError == "group_not_empty" && deletionResult == null, "nonempty host group was removed");
		allowRemoval = true;
		deletionError = "";
		RpcCalls.call(client, WorkspaceProtocol.GROUP,deletion,1000,function(value) deletionResult=value,function(error) deletionError=error.code);
		pump();
		require(deletionResult != null && deletionResult.deleted == true && deletionError == "", "empty group removal failed");
		require(!Lambda.exists(service.snapshot().groups,function(group) return group.id == "delete-me") &&
			!Lambda.exists(readGroups(),function(group) return group.id == "delete-me"), "group removal was not replicated");
		RpcCalls.call(client, WorkspaceProtocol.GROUP,deletion,1000,function(value) deletionResult=value,function(error) deletionError=error.code);
		pump();
		require(deletionError == "" && deletionResult != null && deletionResult.deleted == true, "group deletion retry was not idempotent");
		change("delete-me", "Reused identity", null, null, 0, "create", "group_exists");
		client.close();
		server.close();
		readClient.close();
		readServer.close();
		terminals.dispose();
		store.close();
		store = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), root);
		var wrongRoot = false;
		try {
			var wrong = new WorkspaceSqliteStore(root + "/groups.sqlite", "w", seed.snapshot(), child);
			wrong.close();
		} catch (_:Dynamic)
			wrongRoot = true;
		require(wrongRoot, "Group directory change redirected the database authorization root");
		var recovered = new WorkspaceService("w", "ignored", seed.snapshot().groups, 256, 16, store, directories.resolve);
		var groups = recovered.snapshot().groups;
		require(groups.length == 4, "Created groups did not survive restart");
		var nested = Lambda.find(groups, function(g) return g.id == "nested");
		require(nested != null && nested.name == "Renamed" && nested.parent == "other" && nested.revision == 2, "Nested group state did not survive restart");

		store.close();
		// A catalog in a format from before 2026-10-31 is refused, untouched, with the build that converts it.
		var legacyStore = new WorkspaceSqliteStore(root + "/legacy.sqlite", "w", seed.snapshot(), root);
		legacyStore.close();
		var legacyDb = sqlitekit.Database.open(root + "/legacy.sqlite");
		legacyDb.exec("DROP TABLE workspace_agents; PRAGMA user_version=2");
		legacyDb.close();
		var refusal = "";
		try {
			var old = new WorkspaceSqliteStore(root + "/legacy.sqlite", "w", seed.snapshot(), root);
			old.close();
		} catch (error:Dynamic)
			refusal = Std.string(error);
		require(refusal.indexOf("before 2026-10-31") >= 0 && refusal.indexOf("a457e3dc") >= 0, "An old catalog was not refused by name: " + refusal);
		legacyDb = sqlitekit.Database.open(root + "/legacy.sqlite");
		var version = legacyDb.prepare("PRAGMA user_version");
		require(version.step() && haxe.Int64.toInt(version.columnInt64(0)) == 2, "A refused catalog was rewritten");
		version.close(); legacyDb.close();

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
		Sys.println("PASS: nested groups, empty-only removal, deletion replay/restart, CAS/idempotency, cycles, directory inheritance and running cwd stability");
	}
}
