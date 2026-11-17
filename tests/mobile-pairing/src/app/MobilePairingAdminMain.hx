package app;

import haxe.Json;
import haxeon.platform.Runtime;
import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcPeerOptions;
import nativekit.ffi.NativeKit;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.transport.NativeRpcConnector;
import workspace.transport.NativeRpcHub;
import workspace.client.WorkspaceIds;

/**
	Desktop-side helper for the phone rigs: it talks to a workspace service's local socket (`--socket S`) to make the
	sessions and terminals a phone then sees:

	  --list-sessions        prints the service's catalog (ref.workspace, groups, sessions) as JSON and exits
	  --ensure-session NAME  creates an agent session with that name unless the catalog already lists one, prints it
	  --prompt ID TEXT       sends a prompt to session ID and prints the activity text it gets back
	  --ensure-terminal NAME [--provider claude|codex|pi]
	                         creates a workspace terminal (an agent CLI terminal with --provider) with a stable id derived from
	                         NAME unless one exists, prints its id; the terminal stays in the service and is read-only to nobody
	  --hold-control NAME [--hold-seconds N] [--columns C --rows R]   attach as the controller (a "desktop") and keep control for N seconds
	  --seed FILE            fills a new workspace from the JSON in FILE, in this order: `groups` [{name, parent}] (parent: an
	                         earlier group's name, absent for the root), `sessions` [{name, group, provider}] (agent sessions;
	                         group absent for the root) and `terminals` [{group}] (shells); prints {groups: {name: id}, sessions:
	                         [id], terminals: [id]}

	Never used by the product; scripts/mobile-machine-host.py, the e2e scenario and the ws_open scenario start it.
**/
class MobilePairingAdminMain {
	static inline final ONE_SHOT_DEADLINE_MS = 40000.0;

	static var holdSeconds = 30.0;
	static var holdColumns = 120;
	static var holdRows = 30;

	static function main():Void {
		var args = Sys.args(), socket:Null<String> = null;
		var mode = "", name = "", sessionId = "", text = "", provider:Null<String> = null, seedFile = "";
		var index = 0;
		while (index < args.length) {
			var arg = args[index++];
			switch arg {
				case "--socket": socket = args[index++];
				case "--list-sessions": mode = "list";
				case "--ensure-session": mode = "ensure"; name = args[index++];
				case "--prompt": mode = "prompt"; sessionId = args[index++]; text = args[index++];
				case "--ensure-terminal": mode = "terminal"; name = args[index++];
				case "--hold-control": mode = "hold"; name = args[index++];
				case "--hold-seconds": holdSeconds = Std.parseFloat(args[index++]);
				case "--columns": holdColumns = Std.parseInt(args[index++]);
				case "--rows": holdRows = Std.parseInt(args[index++]);
				case "--provider": provider = args[index++];
				case "--seed": mode = "seed"; seedFile = args[index++];
				default: throw "Unknown option: " + arg;
			}
		}
		if (socket == null || mode == "") throw "--socket and a mode are required";
		var runtime = Runtime.start(), hub = new NativeRpcHub(runtime.events), clock = function() return NativeKit.nk_time_seconds() * 1000;
		var connection:Null<RpcConnection> = null;
		var client = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(socket)), clock, function() return 0.5,
			new RpcPeerOptions("exosuit-editor/1", [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE,
				WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceCatalogProtocol.CAPABILITY,
				WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL, WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL],
				[WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], 2000, 262144, 32, 1048576),
			function(opened, generation, _) connection = opened, 10, 100, 2000);
		var code = 0;
		try {
			if (mode == "seed")
				code = seed(runtime, client, function() return connection, clock, seedFile);
			else
				code = oneShot(runtime, client, function() return connection, clock, mode, name, sessionId, text, provider);
		} catch (error:Dynamic) {
			Sys.stderr().writeString("mobile pairing admin failed: " + Std.string(error) + haxe.CallStack.toString(haxe.CallStack.exceptionStack()) + "\n");
			code = 1;
		}
		client.close();
		hub.dispose();
		runtime.dispose();
		Sys.exit(code);
	}

	static function pump(runtime:Runtime, client:RpcClient):Void {
		runtime.events.wait(0.01);
		for (_ in 0...128) if (!runtime.events.poll()) break;
		client.poll();
	}

	static function oneShot(runtime:Runtime, client:RpcClient, current:Void->Null<RpcConnection>, clock:Void->Float, mode:String, name:String,
			sessionId:String, text:String, provider:Null<String>):Int {
		var deadline = clock() + (mode == "hold" ? holdSeconds * 1000 + 60000 : ONE_SHOT_DEADLINE_MS);
		var holdUntil = 0.0, holdStep = 0;
		var failure:Null<String> = null, done = false, started = false;
		var catalog:Dynamic = null, view:Dynamic = null, sent = false, nextRead = 0.0, reading = false;
		var sessions:Array<Dynamic> = [], groups:Array<Dynamic> = [], resume:Null<String> = null;
		var catalogReady = false, catalogPending = false;
		var instance = "", workspaceId = "";
		var ref = {machine: "mobile-pair-test", workspace: "workspace"};
		while (!done && failure == null && clock() < deadline) {
			pump(runtime, client);
			var connection = current();
			if (connection == null) continue;
			// Read the whole catalog first (it gives the instance and the real workspace id).
			if (!catalogReady) {
				if (!catalogPending) {
					catalogPending = true;
					connection.call(WorkspaceCatalogProtocol.CATALOG, {ref: ref, resume: resume, watch: false}, 5000, function(page) {
						catalogPending = false;
						if (catalog == null || page.reset) {
							if (page.reset) {
								sessions = [];
								groups = [];
							}
							catalog = page;
						}
						for (item in page.sessions) sessions.push(item);
						for (item in page.groups) groups.push(item);
						instance = page.instance;
						workspaceId = page.ref.workspace;
						resume = page.token;
						if (!page.more) catalogReady = true;
					}, function(error) {
						failure = "catalog read failed: " + error.code;
					});
				}
				continue;
			}
			switch mode {
				case "list":
					emit(Json.stringify(describe(catalog, workspaceId, instance, groups, sessions)));
					done = true;
				case "ensure":
					var existing:Dynamic = null;
					for (item in sessions) if (item.name == name) existing = item;
					if (existing != null) {
						emit(Json.stringify({created: false, id: existing.id, name: existing.name, workspace: workspaceId}));
						done = true;
					} else if (!started) {
						started = true;
						// No seeded group exists any more: with none, the session goes to the workspace root.
						var group = groups.length > 0 ? groups[0].id : WorkspaceProtocol.ROOT_GROUP;
						var h1 = 5381, h2 = 52711; for (c in 0...name.length) { h1 = ((h1 * 33) ^ name.charCodeAt(c)) & 0x7fffffff; h2 = ((h2 * 31) + name.charCodeAt(c)) & 0x7fffffff; } var id = "agent-" + StringTools.hex(h1, 8).toLowerCase() + StringTools.hex(h2, 8).toLowerCase();
						connection.call(WorkspaceAgentProtocol.CREATE, {workspace: "workspace", instance: instance, id: id, group: group, name: name,
							thread: null}, 20000, function(record) {
							emit(Json.stringify({created: true, id: record.id, name: record.name, group: record.group, cwd: record.cwd,
								workspace: workspaceId}));
							done = true;
						}, function(error) failure = "session creation failed: " + error.code + " " + error.message);
					}
				case "terminal":
					if (!started) {
						started = true;
						var h1 = 5381, h2 = 52711; for (c in 0...name.length) { h1 = ((h1 * 33) ^ name.charCodeAt(c)) & 0x7fffffff; h2 = ((h2 * 31) + name.charCodeAt(c)) & 0x7fffffff; }
						var id = "workspace-terminal-" + StringTools.hex(h1, 8).toLowerCase() + StringTools.hex(h2, 8).toLowerCase();
						connection.call(WorkspaceTerminalProtocol.OPEN, {workspace: "workspace", instance: instance, id: id, create: true, columns: 80, rows: 24,
							group: null, directory: null, watch: null, theme: null, agentProvider: provider}, 20000, function(info) {
							emit(Json.stringify({created: true, id: info.id, state: info.state, agentProvider: info.agentProvider, workspace: workspaceId}));
							done = true;
						}, function(error) {
							if (error.code == "terminal_unavailable") {
								emit(Json.stringify({created: false, id: id, workspace: workspaceId}));
								done = true;
							} else failure = "terminal creation failed: " + error.code + " " + error.message;
						});
					}
				case "hold":
					// Acts as a desktop viewer: attaches, takes control, sets its own grid, then keeps the connection (and so the control) open.
					var hash1 = 5381, hash2 = 52711;
					for (c in 0...name.length) { hash1 = ((hash1 * 33) ^ name.charCodeAt(c)) & 0x7fffffff; hash2 = ((hash2 * 31) + name.charCodeAt(c)) & 0x7fffffff; }
					var terminalId = "workspace-terminal-" + StringTools.hex(hash1, 8).toLowerCase() + StringTools.hex(hash2, 8).toLowerCase();
					if (holdStep == 0) {
						holdStep = 1;
						connection.call(WorkspaceTerminalProtocol.OPEN, {workspace: "workspace", instance: instance, id: terminalId, create: false,
							columns: holdColumns, rows: holdRows, group: null, directory: null, watch: true, theme: null, agentProvider: null}, 20000,
							function(_) holdStep = 2, function(error) failure = "attach failed: " + error.code + " " + error.message);
					} else if (holdStep == 2) {
						holdStep = 3;
						connection.call(WorkspaceTerminalProtocol.SET_CONTROL, {workspace: "workspace", instance: instance, id: terminalId, claim: true,
							takeover: true}, 5000, function(_) holdStep = 4, function(error) failure = "take control failed: " + error.code);
					} else if (holdStep == 4) {
						holdStep = 5;
						connection.call(WorkspaceTerminalProtocol.RESIZE, {workspace: "workspace", instance: instance, id: terminalId, columns: holdColumns,
							rows: holdRows, theme: null}, 5000, function(_) {
							holdStep = 6;
							holdUntil = clock() + holdSeconds * 1000;
							emit(Json.stringify({holding: true, id: terminalId, columns: holdColumns, rows: holdRows}));
						}, function(error) failure = "resize failed: " + error.code);
					} else if (holdStep == 6 && clock() >= holdUntil) done = true;
				case "prompt":
					if (!sent) {
						sent = true;
						connection.call(WorkspaceAgentProtocol.ACTION, {workspace: "workspace", instance: instance, id: sessionId, action: "prompt",
							text: text, request: null}, 20000, function(_) {}, function(error) failure = "prompt failed: " + error.code + " " + error.message);
					} else if (!reading && clock() >= nextRead) {
						reading = true;
						nextRead = clock() + 500;
						connection.call(WorkspaceAgentProtocol.ACTION, {workspace: "workspace", instance: instance, id: sessionId, action: "read",
							text: "", request: null}, 5000, function(value) {
							reading = false;
							view = value;
							var items:Array<Dynamic> = [];
							if (value.items != null) for (entry in value.items) items.push(entry);
							for (item in items)
								if (item.text != null && item.text.indexOf("FAKE-REPLY") >= 0) done = true;
						}, function(error) {
							reading = false;
							failure = "read failed: " + error.code;
						});
					}
				default:
					failure = "unknown mode " + mode;
			}
		}
		if (mode == "prompt") {
			var items:Array<Dynamic> = [];
			if (view != null && view.items != null) items = view.items;
			emit(Json.stringify({session: sessionId, replied: done, activity: view == null ? null : view.activity,
				items: [for (item in items) {kind: item.kind, text: item.text}]}));
		}
		if (failure != null) throw failure;
		if (!done) throw "timed out";
		return 0;
	}

	static inline final SEED_DEADLINE_MS = 120000.0;

	/** `--seed FILE`: one request at a time, each through the same RPC the editor sends for that action. */
	static function seed(runtime:Runtime, client:RpcClient, current:Void->Null<RpcConnection>, clock:Void->Float, path:String):Int {
		var spec:Dynamic = Json.parse(sys.io.File.getContent(path));
		var groups:Array<Dynamic> = spec.groups == null ? [] : spec.groups;
		var sessions:Array<Dynamic> = spec.sessions == null ? [] : spec.sessions;
		var terminals:Array<Dynamic> = spec.terminals == null ? [] : spec.terminals;
		var ids:Map<String, String> = [], sessionIds:Array<String> = [], terminalIds:Array<String> = [];
		var instance:Null<String> = null, epoch:Null<String> = null, failure:Null<String> = null, pending = false, step = 0;
		var ref = {machine: "seed", workspace: "workspace"};
		function group(name:Null<String>):String {
			if (name == null) return WorkspaceProtocol.ROOT_GROUP;
			var id = ids.get(name);
			if (id == null) throw "the seed names no group " + name;
			return id;
		}
		function done(error:haxeon.rpc.RpcError):Void failure = error.code + " " + error.message;
		var total = groups.length + sessions.length + terminals.length, deadline = clock() + SEED_DEADLINE_MS;
		while (failure == null && step < total && clock() < deadline) {
			pump(runtime, client);
			var connection = current();
			// A reply pumped above may have finished the last step.
			if (connection == null || pending || step >= total) continue;
			pending = true;
			if (instance == null) {
				connection.call(WorkspaceCatalogProtocol.CATALOG, {ref: ref, resume: null, watch: false}, 5000, function(page) {
					pending = false;
					instance = page.instance;
				}, done);
			} else if (epoch == null) {
				connection.call(WorkspaceProtocol.QUERY, {workspace: "workspace"}, 5000, function(snapshot) {
					pending = false;
					epoch = snapshot.epoch;
				}, done);
			} else if (step < groups.length) {
				var item = groups[step], id = WorkspaceIds.create("group");
				connection.call(WorkspaceProtocol.GROUP, {workspace: "workspace", epoch: epoch, operation: WorkspaceIds.create("operation"), group: id,
					expectedRevision: 0, name: item.name, action: "create", parent: WorkspaceProtocol.parentFor(group(item.parent)), cwd: null,
					order: step}, 5000, function(result) {
					pending = false;
					epoch = result.epoch;
					ids.set(item.name, id);
					step++;
				}, done);
			} else if (step < groups.length + sessions.length) {
				var item = sessions[step - groups.length];
				connection.call(WorkspaceAgentProtocol.CREATE, {workspace: "workspace", instance: instance, id: WorkspaceIds.create("agent"),
					group: group(item.group), name: item.name, thread: null, provider: item.provider}, 20000, function(record) {
					pending = false;
					sessionIds.push(record.id);
					step++;
				}, done);
			} else {
				var item = terminals[step - groups.length - sessions.length];
				connection.call(WorkspaceTerminalProtocol.OPEN, {workspace: "workspace", instance: instance, id: WorkspaceIds.create("workspace-terminal"),
					create: true, columns: 120, rows: 30, group: group(item.group), directory: null, watch: null, theme: null, agentProvider: null}, 20000,
					function(info) {
					pending = false;
					terminalIds.push(info.id);
					step++;
				}, done);
			}
		}
		if (failure != null) throw "seed step " + step + " failed: " + failure;
		if (step < total) throw "timed out after " + step + " of " + total + " seed steps";
		var named:Dynamic = {};
		for (name in ids.keys()) Reflect.setField(named, name, ids.get(name));
		emit(Json.stringify({groups: named, sessions: sessionIds, terminals: terminalIds}));
		return 0;
	}

	/**
		One result line, flushed at once. Into a pipe or a file stdout is buffered until exit, and `--hold-control` stays running
		for its whole hold: unflushed, its "holding" line reached the test host only when the hold had already ended.
	**/
	static function emit(line:String):Void {
		Sys.println(line);
		Sys.stdout().flush();
	}

	static function describe(catalog:Dynamic, workspaceId:String, instance:String, groups:Array<Dynamic>, sessions:Array<Dynamic>):Dynamic {
		return {ref: {machine: catalog.ref.machine, workspace: workspaceId}, instance: instance, name: catalog.name, folders: catalog.folders,
			status: catalog.status, groups: [for (g in groups) {id: g.id, name: g.name}],
			sessions: [for (s in sessions) {id: s.id, name: s.name, group: s.group, state: s.state, provider: s.provider}]};
	}
}
