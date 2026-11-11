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
import workspace.service.WorkspacePairingProtocol;
import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspacePairingProtocol.PendingPairing;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.transport.NativeRpcConnector;
import workspace.transport.NativeRpcHub;

/**
	Desktop-side test host for a phone (emulator) that pairs over a local relay. It talks to a workspace service's
	local socket as its pairing admin:

	  host mode  --socket S --invite F --status F --stop F
	      creates a pairing invitation (F), writes a status file every 200 ms, approves the invited device the moment
	      it appears (all grants the service offers), re-creates the invitation when `F.renew` appears, and runs until
	      the stop file exists or 20 minutes pass. Exit 0 on the stop file.
	  --list-sessions        prints the service's catalog (ref.workspace, groups, sessions) as JSON and exits
	  --ensure-session NAME  creates an agent session with that name unless the catalog already lists one, prints it
	  --prompt ID TEXT       sends a prompt to session ID and prints the activity text it gets back
	  --ensure-terminal NAME [--provider claude|codex|pi]
	  --hold-control NAME [--hold-seconds N] [--columns C --rows R]   attach as the controller (a "desktop") and keep control for N seconds
	                         creates a workspace terminal (an agent CLI terminal with --provider) with a stable id derived from
	                         NAME unless one exists, prints its id; the terminal stays in the service and is read-only to nobody

	Never used by the product; scripts/mobile-machine-host.py and the e2e scenario start it.
**/
class MobilePairingAdminMain {
	static inline final HOST_DEADLINE_MS = 20 * 60 * 1000.0;
	static inline final ONE_SHOT_DEADLINE_MS = 40000.0;

	/** Everything the phone could use, most first. Approval falls back down this list if the service refuses a grant. */
	static function grantSets():Array<Array<String>> {
		var base = [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceFileProtocol.READ, WorkspaceScmProtocol.READ,
			WorkspaceProtocol.TREE, WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG, WorkspaceTerminalProtocol.CONTROL,
			WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL];
		var more = base.concat([WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE, WorkspaceProtocol.REMOVE, WorkspaceProtocol.ORDER,
			WorkspaceScmProtocol.WRITE, WorkspaceScmProtocol.REMOTE]);
		return [more.concat([WorkspaceCatalogProtocol.CAPABILITY]), base.concat([WorkspaceCatalogProtocol.CAPABILITY]), more, base];
	}

	static var holdSeconds = 30.0;
	static var holdColumns = 120;
	static var holdRows = 30;

	static function main():Void {
		var args = Sys.args(), socket:Null<String> = null, invite:Null<String> = null, status:Null<String> = null, stop:Null<String> = null;
		var mode = "host", name = "", sessionId = "", text = "", provider:Null<String> = null;
		var index = 0;
		while (index < args.length) {
			var arg = args[index++];
			switch arg {
				case "--socket": socket = args[index++];
				case "--invite": invite = args[index++];
				case "--status": status = args[index++];
				case "--stop": stop = args[index++];
				case "--list-sessions": mode = "list";
				case "--ensure-session": mode = "ensure"; name = args[index++];
				case "--prompt": mode = "prompt"; sessionId = args[index++]; text = args[index++];
				case "--ensure-terminal": mode = "terminal"; name = args[index++];
				case "--hold-control": mode = "hold"; name = args[index++];
				case "--hold-seconds": holdSeconds = Std.parseFloat(args[index++]);
				case "--columns": holdColumns = Std.parseInt(args[index++]);
				case "--rows": holdRows = Std.parseInt(args[index++]);
				case "--provider": provider = args[index++];
				default: throw "Unknown option: " + arg;
			}
		}
		if (socket == null) throw "--socket is required";
		var runtime = Runtime.start(), hub = new NativeRpcHub(runtime.events), clock = function() return NativeKit.nk_time_seconds() * 1000;
		var connection:Null<RpcConnection> = null;
		var client = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(socket)), clock, function() return 0.5,
			new RpcPeerOptions("exosuit-editor/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE,
				WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspacePairingProtocol.ADMIN, WorkspaceCatalogProtocol.CAPABILITY,
				WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL, WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL],
				[WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY], 2000, 262144, 32, 1048576),
			function(opened, generation, _) connection = opened, 10, 100, 2000);
		var code = 0;
		try {
			if (mode == "host") {
				if (invite == null || status == null || stop == null) throw "host mode needs --invite, --status and --stop";
				code = host(runtime, client, function() return connection, clock, invite, status, stop);
			} else {
				code = oneShot(runtime, client, function() return connection, clock, mode, name, sessionId, text, provider);
			}
		} catch (error:Dynamic) {
			Sys.stderr().writeString("mobile pairing admin failed: " + Std.string(error) + "\n");
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

	static function write(path:String, contents:String):Void {
		sys.io.File.saveContent(path, contents);
	}

	static function host(runtime:Runtime, client:RpcClient, current:Void->Null<RpcConnection>, clock:Void->Float, invitePath:String,
			statusPath:String, stopPath:String):Int {
		var wanted:Map<String, Bool> = [];
		var invitationPending = false, nextInvitation = 0.0, invitations = 0, listPending = false, nextList = 0.0, nextStatus = 0.0;
		var approvalPending = false, approvedDevices:Map<String, Bool> = [], approved = false;
		var grantedSet:Array<String> = [], catalogGranted:Null<Bool> = null, grantAttempt = 0;
		var pending:Array<PendingPairing> = [], devices:Array<PairingDevice> = [], failure:Null<String> = null, ready = false;
		var deadline = clock() + HOST_DEADLINE_MS, sets = grantSets();
		var renew = invitePath + ".renew", none:Array<String> = [];
		while (clock() < deadline) {
			pump(runtime, client);
			if (sys.FileSystem.exists(stopPath)) {
				write(statusPath, Json.stringify({ready: false, stopped: true, pending: none, approved: approved, connectedDevices: none, failure: failure}));
				return 0;
			}
			var connection = current();
			if (connection == null) continue;
			var renewing = sys.FileSystem.exists(renew);
			if (!invitationPending && clock() >= nextInvitation && (invitations == 0 || renewing)) {
				invitationPending = true;
				connection.call(WorkspacePairingProtocol.CREATE, {ttlSeconds: 300}, 10000, function(value) {
					invitationPending = false;
					invitations++;
					wanted.set(value.deviceId, true);
					if (sys.FileSystem.exists(renew)) sys.FileSystem.deleteFile(renew);
					write(invitePath, Json.stringify({pairingSocketUrl: value.pairingSocketUrl, machineId: value.machineId, deviceId: value.deviceId,
						relayOrigin: value.relayOrigin, expiresInSeconds: value.expiresInSeconds}));
					ready = true;
					failure = null;
				}, function(error) {
					// The relay may not be connected yet; try again shortly.
					invitationPending = false;
					nextInvitation = clock() + 1000;
					failure = "pairing invitation RPC failed: " + error.code;
				});
			}
			if (!listPending && clock() >= nextList) {
				listPending = true;
				nextList = clock() + 200;
				connection.call(WorkspacePairingProtocol.LIST, {}, 2000, function(value) {
					listPending = false;
					pending = value.pending;
					devices = value.devices;
				}, function(error) {
					listPending = false;
					failure = "pairing list RPC failed: " + error.code;
				});
			}
			if (!approvalPending) {
				for (candidate in pending) {
					if (!wanted.exists(candidate.deviceId) || approvedDevices.exists(candidate.deviceId)) continue;
					approvalPending = true;
					var id = candidate.deviceId, attempt = grantAttempt;
					connection.call(WorkspacePairingProtocol.APPROVE, {deviceId: id, grants: sets[attempt]}, 60000, function(result) {
						approvalPending = false;
						if (result.accepted) {
							approvedDevices.set(id, true);
							approved = true;
							grantedSet = sets[attempt];
							catalogGranted = grantedSet.indexOf(WorkspaceCatalogProtocol.CAPABILITY) >= 0;
							failure = null;
						} else if (result.error == "invalid_pairing_grants" && grantAttempt + 1 < sets.length) {
							// The service does not offer one of the grants (workspace.catalog is local-only today): try fewer.
							grantAttempt++;
						} else {
							failure = "pairing approval was refused: " + result.error;
						}
					}, function(error) {
						approvalPending = false;
						failure = "pairing approval RPC failed: " + error.code;
					});
					break;
				}
			}
			if (clock() >= nextStatus) {
				nextStatus = clock() + 200;
				var connected = [for (device in devices) if (device.connected && !device.revoked) device.deviceId];
				write(statusPath, Json.stringify({ready: ready, pending: pending, approved: approved, connectedDevices: connected,
					devices: devices, grants: grantedSet, catalogGranted: catalogGranted, invitations: invitations, failure: failure}));
			}
		}
		write(statusPath, Json.stringify({ready: false, stopped: false, expired: true, pending: none, approved: approved, connectedDevices: none,
			failure: "20 minute deadline reached"}));
		return 0;
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
					Sys.println(Json.stringify(describe(catalog, workspaceId, instance, groups, sessions)));
					done = true;
				case "ensure":
					var existing:Dynamic = null;
					for (item in sessions) if (item.name == name) existing = item;
					if (existing != null) {
						Sys.println(Json.stringify({created: false, id: existing.id, name: existing.name, workspace: workspaceId}));
						done = true;
					} else if (!started) {
						started = true;
						// No seeded group exists any more: with none, the session goes to the workspace root.
						var group = groups.length > 0 ? groups[0].id : WorkspaceProtocol.ROOT_GROUP;
						var h1 = 5381, h2 = 52711; for (c in 0...name.length) { h1 = ((h1 * 33) ^ name.charCodeAt(c)) & 0x7fffffff; h2 = ((h2 * 31) + name.charCodeAt(c)) & 0x7fffffff; } var id = "agent-" + StringTools.hex(h1, 8).toLowerCase() + StringTools.hex(h2, 8).toLowerCase();
						connection.call(WorkspaceAgentProtocol.CREATE, {workspace: "workspace", instance: instance, id: id, group: group, name: name,
							thread: null}, 20000, function(record) {
							Sys.println(Json.stringify({created: true, id: record.id, name: record.name, group: record.group, cwd: record.cwd,
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
							Sys.println(Json.stringify({created: true, id: info.id, state: info.state, agentProvider: info.agentProvider, workspace: workspaceId}));
							done = true;
						}, function(error) {
							if (error.code == "terminal_unavailable") {
								Sys.println(Json.stringify({created: false, id: id, workspace: workspaceId}));
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
							Sys.println(Json.stringify({holding: true, id: terminalId, columns: holdColumns, rows: holdRows}));
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
			Sys.println(Json.stringify({session: sessionId, replied: done, activity: view == null ? null : view.activity,
				items: [for (item in items) {kind: item.kind, text: item.text}]}));
		}
		if (failure != null) throw failure;
		if (!done) throw "timed out";
		return 0;
	}

	static function describe(catalog:Dynamic, workspaceId:String, instance:String, groups:Array<Dynamic>, sessions:Array<Dynamic>):Dynamic {
		return {ref: {machine: catalog.ref.machine, workspace: workspaceId}, instance: instance, name: catalog.name, folders: catalog.folders,
			status: catalog.status, groups: [for (g in groups) {id: g.id, name: g.name}],
			sessions: [for (s in sessions) {id: s.id, name: s.name, group: s.group, state: s.state, provider: s.provider}]};
	}
}
