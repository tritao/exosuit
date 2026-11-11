package suit.remote;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectResult;
import noisekit.NoiseSession;
import processkit.Processes;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import suit.MachineCatalog;
import suit.SuitClient;
import suit.SuitInventory;
import suit.SuitPaths;
import suit.SuitRecord.SuitRecords;
import suit.remote.MachineDeviceSession.MachineSessionHost;
import workspace.client.WorkspaceServiceTarget;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.runtime.WorkspaceNoiseIdentity;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineGrants;
import workspace.transport.ForwardedStream;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayMachineEndpoint;

/** A reply a control request gets later, when the pairing step it started completes. */
class DeferredReply {
	public var reply(default, null):Null<Dynamic> = null;
	public final started:Float = Sys.time();

	public function new() {}

	public function resolve(value:Dynamic):Void
		reply = value;
}

private typedef ServiceStart = {
	var workspace:String;
	var stateDir:String;
	var deadline:Float;
	var waiters:Array<Null<String>->Null<String>->Void>;
}

/** An approval in flight: answered once the device has it, or when it fails. */
private typedef PendingApproval = {
	var deviceId:String;
	var finish:Dynamic->Void;
	var answered:Bool;
}

/**
	The machine's relay identity, paired devices and what each may reach (ADR 0005 section 4, M19 Phase 9). One machine
	socket to the relay, held here; Noise terminated here per device channel against the pinned device key; a
	machine-level directory filtered to the device's grants; and, when a device opens a granted workspace, a stream
	forwarded to that workspace's service over its local pipe with the grants attached (`MachineDeviceSession`).

	Secrets: the Noise static key and the relay bearer live in the OS credential store under the machine's relay id (the
	32 hex digits of its machine id). `machine-relay.json` in suit's home holds only the relay origin and that id;
	`machine-devices.json` holds device pins and grants. Both are written only here.
**/
class MachineRemote implements MachineSessionHost {
	static inline final START_SECONDS:Float = 45;
	static inline final MAX_SESSIONS = 16;

	final events:EventPump;
	final hub:NativeRpcHub;
	final catalog:Void->MachineCatalog;
	final allowLoopbackHttp:Bool;
	final store:MachineDeviceStore;
	final sessions:Array<MachineDeviceSession> = [];
	final starts:Array<ServiceStart> = [];
	final deferred:Array<DeferredReply> = [];
	final approvals:Array<PendingApproval> = [];
	var endpoint:Null<RelayMachineEndpoint> = null;
	var host:Null<WorkspaceRelayHost> = null;
	var identity:Null<WorkspaceNoiseIdentity> = null;
	var manager:Null<WorkspacePairingManager> = null;
	var setupError:Null<String> = null;
	/** Why machine-devices.json could not be read at startup; remote access stays off while it is set. */
	var storeError:Null<String> = null;
	var version:Int = 0;

	public function new(events:EventPump, hub:NativeRpcHub, catalog:Void->MachineCatalog) {
		this.events = events;
		this.hub = hub;
		this.catalog = catalog;
		allowLoopbackHttp = Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1";
		// An unreadable device file (another build's version, a hand edit) turns remote access off, not suit: the file is
		// left as it is for the build that wrote it, and nothing here writes it.
		var devicesFile = Path.join([SuitPaths.home(), "machine-devices.json"]);
		var opened:Null<MachineDeviceStore> = null;
		var readError:Null<String> = null;
		try opened = new MachineDeviceStore(devicesFile) catch (error:Dynamic) readError = Std.string(error);
		store = opened != null ? opened : new MachineDeviceStore(devicesFile, false);
		if (readError != null)
			storeError = "machine-devices.json cannot be read (" + readError + "); remote access is off until it is fixed or removed";
		setupError = storeError;
		if (storeError == null && FileSystem.exists(configFile()))
			try load() catch (error:Dynamic) {
				setupError = Std.string(error);
				teardown();
			}
	}

	public static function configFile():String
		return Path.join([SuitPaths.home(), "machine-relay.json"]);

	static function now():Float
		return nativekit.ffi.NativeKit.nk_time_seconds() * 1000;

	/** Whether remote access is set up: suit then stays up and holds the machine socket. */
	public function hosting():Bool
		return host != null;

	/** Work that wants prompt polling. */
	public function busy():Bool
		return sessions.length > 0 || starts.length > 0 || deferred.length > 0 || approvals.length > 0;

	// ---- setup

	function load():Void {
		if (storeError != null)
			throw storeError;
		var info = FileSystem.metadata(configFile());
		if (info == null || info.size > 4096)
			throw "machine-relay.json is not valid";
		var value:Dynamic = Json.parse(File.getContent(configFile()));
		var origin = SuitRecords.stringField(value, "origin"), id = SuitRecords.stringField(value, "machineId");
		if (SuitRecords.intField(value, "version") != 1 || origin == null || id == null)
			throw "machine-relay.json is not valid";
		var target = new RelayMachineEndpoint(origin, id);
		if (target.isLoopbackHttp && !allowLoopbackHttp)
			throw "relay_loopback_disabled";
		var credentials = WorkspaceCredentialStores.relay();
		var stored = credentials.read(WorkspaceCredentialStores.machineAccount(target));
		if (stored == null)
			throw "relay_credential_missing";
		var token = stored.toString();
		wipe(stored);
		endpoint = target;
		identity = new WorkspaceNoiseIdentity(id, credentials);
		var relay = new WorkspaceRelayHost(events, hub, new WorkspaceRelaySettings(target, token), allowLoopbackHttp, null);
		host = relay;
		var pairing = new WorkspacePairingManager(store, relay, identity.privateKeyForHandshake(), function() return [MachineDirectoryProtocol.CAPABILITY],
			now, onAuthenticated);
		manager = pairing;
		relay.onChannel = function(channel) pairing.acceptChannel(channel.channelId, channel);
		setupError = null;
	}

	function teardown():Void {
		for (session in sessions)
			session.close();
		sessions.resize(0);
		if (manager != null)
			manager.dispose();
		manager = null;
		if (host != null)
			host.dispose();
		host = null;
		if (identity != null)
			identity.dispose();
		identity = null;
		endpoint = null;
	}

	/** The machine's relay id: the hex digits of its catalog id, so one id names the machine to the relay and to devices. */
	function relayId():String {
		var id = catalog().state.id;
		var hex = StringTools.startsWith(id, "machine-") ? id.substr("machine-".length) : id;
		if (!~/^[0-9a-f]{32}$/.match(hex))
			throw "The machine id is not a relay id";
		return hex;
	}

	/** Sets up remote access with this relay: a bearer in the credential store and the machine's config. Safe to repeat for the same relay. */
	function enable(origin:String):Void {
		if (storeError != null)
			throw storeError;
		var target = new RelayMachineEndpoint(origin, relayId());
		if (target.isLoopbackHttp && !allowLoopbackHttp)
			throw "relay_loopback_disabled";
		if (endpoint != null) {
			if (endpoint.origin == target.origin)
				return;
			throw "Remote access is already set up with " + endpoint.origin;
		}
		var credentials = WorkspaceCredentialStores.relay();
		var account = WorkspaceCredentialStores.machineAccount(target);
		var existing = credentials.read(account);
		if (existing == null) {
			var generated = NoiseSession.generateKeypair();
			var token = Bytes.ofString(hex(generated.privateKey));
			wipe(generated.privateKey);
			try credentials.write(account, token) catch (error:Dynamic) {
				wipe(token);
				throw error;
			}
			wipe(token);
		} else
			wipe(existing);
		AtomicFile.write(configFile(), Json.stringify({version: 1, origin: target.origin, machineId: target.machineId}) + "\n");
		load();
	}

	/** Stops using the relay and deletes its address. The machine's bearer stays in the credential store for the same relay later. */
	function disable():Void {
		teardown();
		if (FileSystem.exists(configFile()))
			FileSystem.deleteFile(configFile());
		setupError = storeError;
		version++;
	}

	// ---- polling

	public function poll():Void {
		var relay = host;
		if (relay != null) {
			relay.poll(now());
			if (manager != null)
				manager.poll();
		}
		var pairing = manager;
		if (pairing != null)
			for (approval in approvals.copy())
				if (!approval.answered && pairing.awaitingConfirmation(approval.deviceId)) {
					// The device has its approval; its user may take a while to confirm the code, longer than the editor waits.
					version++;
					answerApproval(approval, {ok: true});
				}
		var index = sessions.length;
		while (index-- > 0) {
			sessions[index].poll();
			if (!sessions[index].isOpen())
				sessions.splice(index, 1);
		}
		pollStarts();
		var at = deferred.length;
		while (at-- > 0) {
			var item = deferred[at];
			if (item.reply != null || Sys.time() - item.started > 60)
				deferred.splice(at, 1);
		}
	}

	function onAuthenticated(secure:workspace.transport.NoiseMessageTransport, grants:Array<String>):Void {
		var device = manager == null ? null : manager.authenticating;
		if (device == null || sessions.length >= MAX_SESSIONS) {
			secure.close();
			return;
		}
		// A device has one channel: a new one replaces its old.
		for (session in sessions)
			if (session.deviceId == device)
				session.close();
		sessions.push(new MachineDeviceSession(device, secure, this, now));
	}

	public function dispose():Void {
		teardown();
		for (start in starts)
			for (waiter in start.waiters)
				waiter(null, "workspace_unavailable");
		starts.resize(0);
	}

	// ---- MachineSessionHost

	public function machineId():String
		return catalog().state.id;

	public function revision():Int {
		var total = version;
		for (workspace in catalog().state.workspaces)
			total += workspace.revision;
		return total;
	}

	public function grantsFor(deviceId:String, workspace:String):Null<Array<String>>
		return store.grantsFor(deviceId, workspace);

	public function directory(deviceId:String):MachineDirectory {
		var machine = catalog().state;
		var listed:Array<workspace.service.MachineDirectoryProtocol.MachineWorkspaceEntry> = [];
		for (entry in machine.workspaces) {
			var grants = store.grantsFor(deviceId, entry.id);
			if (grants != null)
				listed.push({workspace: entry.id, name: entry.name, status: running(entry.id) == null ? MachineDirectoryProtocol.IDLE : MachineDirectoryProtocol.RUNNING,
					grants: grants});
		}
		return {machine: machine.id, name: machine.name, revision: revision(), workspaces: listed};
	}

	static function stateDirOf(workspace:String):String
		return Path.join([MachineCatalog.agentStateBase(), "workspaces", workspace]);

	/** The local endpoint of the workspace's running service, or null when it is idle. */
	function running(workspace:String):Null<String> {
		var found = SuitInventory.readEndpoint(stateDirOf(workspace));
		return found != null && Processes.started(found.managerPid) != -1 ? found.socket : null;
	}

	public function openService(deviceId:String, workspace:String, grants:Array<String>, done:Null<MessageTransport>->Null<String>->Void):Void {
		var entry:Null<MachineCatalog.MachineWorkspace> = null;
		for (candidate in catalog().state.workspaces)
			if (candidate.id == workspace)
				entry = candidate;
		if (entry == null) {
			done(null, "unknown_workspace");
			return;
		}
		ensureService(entry, function(socket, error) {
			if (socket == null) {
				done(null, error == null ? "workspace_unavailable" : error);
				return;
			}
			connectService(socket, deviceId, grants, done);
		});
	}

	function connectService(socket:String, deviceId:String, grants:Array<String>, done:Null<MessageTransport>->Null<String>->Void):Void {
		try {
			hub.connect(NativeRpcHub.local(socket), function(result) {
				switch result {
					case Opened(transport):
						if (!transport.send(ForwardedStream.intro(deviceId, grants))) {
							transport.close();
							done(null, "workspace_unavailable");
						} else
							done(transport, null);
					case Failed(_, _):
						done(null, "workspace_unavailable");
				}
			});
		} catch (_:Dynamic) {
			done(null, "workspace_unavailable");
		}
	}

	/** Finds the workspace's running service, or starts it and waits for it (at most START_SECONDS). */
	function ensureService(entry:MachineCatalog.MachineWorkspace, done:Null<String>->Null<String>->Void):Void {
		var socket = running(entry.id);
		if (socket != null) {
			done(socket, null);
			return;
		}
		for (start in starts)
			if (start.workspace == entry.id) {
				start.waiters.push(done);
				return;
			}
		try spawn(entry) catch (error:Dynamic) {
			done(null, "workspace_unavailable");
			return;
		}
		starts.push({workspace: entry.id, stateDir: stateDirOf(entry.id), deadline: Sys.time() + START_SECONDS, waiters: [done]});
	}

	function pollStarts():Void {
		var index = starts.length;
		while (index-- > 0) {
			var start = starts[index];
			var socket = running(start.workspace);
			if (socket == null && Sys.time() < start.deadline)
				continue;
			starts.splice(index, 1);
			for (waiter in start.waiters)
				waiter(socket, socket == null ? "workspace_unavailable" : null);
		}
	}

	/** The agent bytecode beside suit's own (a source build's agent/build/host/main.hl, or a bundle's tools/exosuit-agent.hl). */
	public static function agentLauncher():Null<String> {
		var configured = Sys.getEnv("EXOSUIT_AGENT_LAUNCHER");
		if (configured != null && configured.length > 0)
			return FileSystem.exists(configured) ? FileSystem.fullPath(configured) : null;
		var own = SuitClient.findLauncher();
		if (own == null)
			return null;
		var directory = Path.directory(own);
		for (candidate in [Path.join([Path.directory(Path.directory(Path.directory(directory))), "agent", "build", "host", "main.hl"]),
			Path.join([directory, "exosuit-agent.hl"])])
			if (FileSystem.exists(candidate))
				return FileSystem.fullPath(candidate);
		return null;
	}

	/** Starts the workspace's service as an editor would, detached, in its folders (or its scratch folder). */
	function spawn(entry:MachineCatalog.MachineWorkspace):Void {
		var launcher = agentLauncher();
		if (launcher == null)
			throw "The workspace agent is not installed";
		var scratch = entry.scratch;
		if (entry.folders.length == 0 && scratch == null)
			scratch = catalog().scratch(entry.id);
		var target = WorkspaceServiceTarget.forWorkspace(entry.id, entry.folders, scratch);
		var child = sys.io.Process.spawn(Sys.executablePath(), [launcher].concat(target.managerArguments()).concat(["--detach"]),
			Path.directory(launcher), [SuitClient.libraryVariable(), "EXOSUIT_AGENT_LAUNCHER"], [SuitClient.nativePath(launcher), launcher], true);
		child.close();
	}

	// ---- control requests

	/** A control request for remote access, or null when it is not one. Slow steps answer through a DeferredReply. */
	public function handle(request:Dynamic):Null<Dynamic> {
		var op = SuitRecords.stringField(request, "op");
		if (op == null || !StringTools.startsWith(op, "remote-"))
			return null;
		try {
			switch op {
				case "remote-status":
					return status();
				case "remote-enable":
					var origin = SuitRecords.stringField(request, "origin");
					if (origin == null)
						throw "origin is required";
					enable(origin);
					return status();
				case "remote-disable":
					disable();
					return status();
				case "remote-invite":
					var ttl = SuitRecords.intField(request, "ttl");
					return later(function(finish) {
						requireManager().createInvitation(ttl == null ? 300 : ttl, function(invitation, error) {
							finish(error != null || invitation == null ? {ok: false, error: error == null ? "pairing_unavailable" : error} : {
								ok: true,
								invitation: invitation
							});
						});
					});
				case "remote-devices":
					return devices();
				case "remote-approve":
					var id = SuitRecords.stringField(request, "deviceId");
					var granted = workspaceGrants(request);
					var pairing = requireManager();
					// A repeated or stale Approve (the editor gave up waiting, or the list was old) must not touch the grants of a
					// pairing already under way or of a paired device: only a pairing waiting for the owner gets them.
					if (id == null || !pairing.awaitingApproval(id))
						return {ok: false, error: "pairing_not_found"};
					var previous = store.grantsOf(id);
					return later(function(finish) {
						var approval:PendingApproval = {deviceId: id, finish: finish, answered: false};
						approvals.push(approval);
						// The device's workspaces are in place before it is approved, so its first directory read shows them.
						store.setGrants(id, granted);
						pairing.approve(id, [MachineDirectoryProtocol.CAPABILITY], function(error) {
							approvals.remove(approval);
							if (error != null)
								store.setGrants(id, previous);
							else
								version++;
							answerApproval(approval, error == null ? {ok: true} : {ok: false, error: error});
						});
					});
				case "remote-grant":
					var id = SuitRecords.stringField(request, "deviceId");
					var granted = workspaceGrants(request);
					var known = false;
					for (record in store.loadDevices())
						if (record.deviceId == id && !record.revoked)
							known = true;
					if (!known)
						return {ok: false, error: "device_not_found"};
					store.setGrants(id, granted);
					version++;
					return {ok: true, devices: devices().devices};
				case "remote-reject":
					var rejected = requireManager().reject(SuitRecords.stringField(request, "deviceId"));
					return rejected ? {ok: true} : {ok: false, error: "pairing_not_found"};
				case "remote-revoke":
					var revoked = SuitRecords.stringField(request, "deviceId");
					var pairing = requireManager();
					return later(function(finish) {
						pairing.revoke(revoked, function(error) {
							version++;
							finish(error == null ? {ok: true} : {ok: false, error: error});
						});
					});
				default:
					return {ok: false, error: "unknown request"};
			}
		} catch (error:Dynamic) {
			return {ok: false, error: Std.string(error)};
		}
	}

	function later(work:(Dynamic->Void)->Void):DeferredReply {
		var pending = new DeferredReply();
		deferred.push(pending);
		work(function(value) pending.resolve(value));
		return pending;
	}

	static function answerApproval(approval:PendingApproval, value:Dynamic):Void {
		if (approval.answered)
			return;
		approval.answered = true;
		approval.finish(value);
	}

	function requireManager():WorkspacePairingManager {
		var current = manager;
		if (current == null)
			throw setupError == null ? "Remote access is not set up" : setupError;
		return current;
	}

	function status():Dynamic {
		var relay = host;
		return {
			ok: true, enabled: endpoint != null, connected: relay != null && relay.connected, origin: endpoint == null ? null : endpoint.origin,
			relayMachineId: endpoint == null ? null : endpoint.machineId, machineId: catalog().state.id,
			error: setupError != null ? setupError : relay == null ? null : explainRelayError(relay.lastError), sessions: sessions.length
		};
	}

	/** Relay errors the owner has to act on, said in words; the code stays at the front. */
	static function explainRelayError(error:Null<String>):Null<String> {
		if (error == "machine_identity_conflict")
			// The relay id is the catalog id, which every invitation shows: someone else may have registered it first.
			return error + ": this relay already has this machine's id registered with another credential, so it cannot be "
				+ "used for this machine. Turn remote access off and use another relay (or your own).";
		return error;
	}

	function devices():Dynamic {
		var pending:Array<Dynamic> = [], listed:Array<Dynamic> = [];
		var pairing = manager;
		if (pairing != null) {
			for (item in pairing.listPending())
				pending.push({deviceId: item.deviceId, authenticationCode: item.authenticationCode, expiresInSeconds: item.expiresInSeconds});
			for (item in pairing.listDevices()) {
				var granted:Array<Dynamic> = [];
				var map = store.grantsOf(item.deviceId);
				for (workspace => grants in map)
					granted.push({workspace: workspace, grants: grants, preset: MachineGrants.presetOf(grants)});
				granted.sort(function(a, b) return Reflect.compare(a.workspace, b.workspace));
				listed.push({deviceId: item.deviceId, connected: item.connected, revoked: item.revoked, workspaces: granted});
			}
		}
		var names:Array<Dynamic> = [for (entry in catalog().state.workspaces) {id: entry.id, name: entry.name}];
		return {ok: true, pending: pending, devices: listed, workspaces: names};
	}

	/** `workspaces`: a list of `{workspace, grants}` or `{workspace, preset}`. Each must be a workspace of this machine. */
	function workspaceGrants(request:Dynamic):Map<String, Array<String>> {
		var result = new Map<String, Array<String>>();
		var list:Dynamic = Reflect.field(request, "workspaces");
		if (list == null)
			return result;
		if (!Std.isOfType(list, Array))
			throw "workspaces must be a list";
		for (item in (list : Array<Dynamic>)) {
			var id = SuitRecords.stringField(item, "workspace");
			if (id == null || !Lambda.exists(catalog().state.workspaces, function(entry) return entry.id == id))
				throw "unknown_workspace";
			var grants:Null<Array<String>> = null;
			var preset = SuitRecords.stringField(item, "preset");
			if (preset != null)
				grants = MachineGrants.preset(preset);
			else {
				var given:Dynamic = Reflect.field(item, "grants");
				if (Std.isOfType(given, Array))
					grants = [for (grant in (given : Array<Dynamic>)) Std.string(grant)];
			}
			if (grants == null || !MachineGrants.valid(grants))
				throw "invalid_grants";
			result.set(id, grants);
		}
		return result;
	}

	/** A workspace was deleted: no device keeps access to it. */
	public function workspaceDeleted(workspace:String):Void {
		if (store.forgetWorkspace(workspace))
			version++;
	}

	static function hex(bytes:Bytes):String {
		var output = new StringBuf();
		for (index in 0...bytes.length)
			output.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
		return output.toString();
	}

	static function wipe(bytes:Bytes):Void {
		for (index in 0...bytes.length)
			bytes.set(index, 0);
	}
}
