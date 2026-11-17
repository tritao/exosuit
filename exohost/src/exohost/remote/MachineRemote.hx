package exohost.remote;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectResult;
import noisekit.NoiseSession;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import exohost.MachineCatalog;
import exohost.ExohostClient;
import exohost.ExohostPaths;
import exohost.ExohostRecord.ExohostRecords;
import exohost.remote.MachineDeviceSession.MachineSessionHost;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.runtime.WorkspaceNoiseIdentity;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineGrants;
import workspace.transport.ForwardedStream;
import workspace.transport.MachineKeys;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelayRegistrationProver;

/** A reply a control request gets later, when the pairing step it started completes. */
class DeferredReply {
	public var reply(default, null):Null<Dynamic> = null;
	public final started:Float = Sys.time();

	public function new() {}

	public function resolve(value:Dynamic):Void
		reply = value;
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

	Secrets: the Noise static key and the relay bearer live in the OS credential store under the machine's relay id. Each
	relay gets its own id, derived from a Noise key made for it (`MachineKeys.relayId`); a relay set up before that keeps
	the 32 hex digits of the catalog id (`MachineRelayIds`). Devices learn the relay id from the invitation and the
	directory's `relay` field. `machine-relay.json` in exohost's home holds only the relay origin and that id,
	`machine-relay-ids.json` the id per relay used, `machine-devices.json` device pins and grants. All are written only
	here.
**/
class MachineRemote implements MachineSessionHost {
	static inline final MAX_SESSIONS = 16;

	final events:EventPump;
	final hub:NativeRpcHub;
	final catalog:Void->MachineCatalog;
	final services:ExohostServices;
	final allowLoopbackHttp:Bool;
	final store:MachineDeviceStore;
	final sessions:Array<MachineDeviceSession> = [];
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
	/** True from a full quit's `cutOff` until `resumeAfterQuit`: remote access is configured but ended by the quit. */
	var cutByQuit:Bool = false;

	/** `services` starts and finds the workspaces' services a device opens. */
	public function new(events:EventPump, hub:NativeRpcHub, catalog:Void->MachineCatalog, services:ExohostServices) {
		this.events = events;
		this.hub = hub;
		this.catalog = catalog;
		this.services = services;
		allowLoopbackHttp = Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1";
		// An unreadable device file (another build's version, a hand edit) turns remote access off, not exohost: the file is
		// left as it is for the build that wrote it, and nothing here writes it.
		var devicesFile = Path.join([ExohostPaths.home(), "machine-devices.json"]);
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
		return Path.join([ExohostPaths.home(), "machine-relay.json"]);

	static function now():Float
		return nativekit.ffi.NativeKit.nk_time_seconds() * 1000;

	/** Whether remote access is set up: exohost then stays up and holds the machine socket. */
	public function hosting():Bool
		return host != null;

	/** Work that wants prompt polling. */
	public function busy():Bool
		return sessions.length > 0 || deferred.length > 0 || approvals.length > 0;

	// ---- setup

	function load():Void {
		if (storeError != null)
			throw storeError;
		var info = FileSystem.metadata(configFile());
		if (info == null || info.size > 4096)
			throw "machine-relay.json is not valid";
		var value:Dynamic = Json.parse(File.getContent(configFile()));
		var origin = ExohostRecords.stringField(value, "origin"), id = ExohostRecords.stringField(value, "machineId");
		if (ExohostRecords.intField(value, "version") != 1 || origin == null || id == null)
			throw "machine-relay.json is not valid";
		var target = new RelayMachineEndpoint(origin, id);
		if (target.isLoopbackHttp && !allowLoopbackHttp)
			throw "relay_loopback_disabled";
		// A relay set up before machine-relay-ids.json: remember its id, so turning remote access off and on keeps it.
		try new MachineRelayIds(relayIdsFile()).remember(target.origin, target.machineId) catch (_:Dynamic) {}
		var credentials = WorkspaceCredentialStores.relay();
		var stored = credentials.read(WorkspaceCredentialStores.machineAccount(target));
		if (stored == null)
			throw "relay_credential_missing";
		var token = stored.toString();
		wipe(stored);
		endpoint = target;
		var own = new WorkspaceNoiseIdentity(id, credentials);
		identity = own;
		var relay = new WorkspaceRelayHost(events, hub, target, token, allowLoopbackHttp);
		host = relay;
		// A relay id derived from the machine key can be proven to the relay, so an id someone else registered first is taken back.
		relay.proveIdentityWith(RelayRegistrationProver.forKey(id, own.privateKeyForHandshake(), own.publicKey));
		var pairing = new WorkspacePairingManager(store, relay, own.privateKeyForHandshake(), function() return [MachineDirectoryProtocol.CAPABILITY],
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

	public static function relayIdsFile():String
		return Path.join([ExohostPaths.home(), "machine-relay-ids.json"]);

	/** The hex digits of the catalog id: the relay id every relay used before each relay got its own. Null when it is not one. */
	function legacyRelayId():Null<String> {
		var id = catalog().state.id;
		var hex = StringTools.startsWith(id, "machine-") ? id.substr("machine-".length) : id;
		return MachineRelayIds.valid(hex) ? hex : null;
	}

	/**
		The relay id for a relay (`MachineRelayIds.choose`). A new one is derived from a Noise key made for this relay
		(`MachineKeys.relayId`), stored as the relay identity's key before the id is used, so the id is not guessable from
		anything an invitation shows and the relay can be shown that a registration holds the key.
	**/
	function relayIdFor(origin:String, credentials:workspace.runtime.WorkspaceCredentialStore):String {
		var canonical = new RelayMachineEndpoint(origin, StringTools.lpad("", "0", 32)).origin;
		return new MachineRelayIds(relayIdsFile()).choose(canonical, legacyRelayId(), function(id) {
			var stored = credentials.read(WorkspaceCredentialStores.machineAccount(new RelayMachineEndpoint(canonical, id)));
			if (stored == null)
				return false;
			wipe(stored);
			return true;
		}, function() {
			var generated = NoiseSession.generateKeypair();
			var id = MachineKeys.relayId(generated.publicKey);
			try credentials.write("noise-static:" + id, generated.privateKey) catch (error:Dynamic) {
				wipe(generated.privateKey);
				throw error;
			}
			wipe(generated.privateKey);
			return id;
		});
	}

	/** Sets up remote access with this relay: a bearer in the credential store and the machine's config. Safe to repeat for the same relay. */
	function enable(origin:String):Void {
		if (storeError != null)
			throw storeError;
		var credentials = WorkspaceCredentialStores.relay();
		var current = endpoint;
		if (current != null) {
			if (current.origin == new RelayMachineEndpoint(origin, current.machineId).origin)
				return;
			throw "Remote access is already set up with " + current.origin;
		}
		if (new RelayMachineEndpoint(origin, StringTools.lpad("", "0", 32)).isLoopbackHttp && !allowLoopbackHttp)
			throw "relay_loopback_disabled";
		var target = new RelayMachineEndpoint(origin, relayIdFor(origin, credentials));
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

	/**
		Stops using the relay and deletes its address. The machine's bearer and Noise key stay in the credential store, and its
		relay id in machine-relay-ids.json, for the same relay later.
	**/
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

	/** Closes every live session of one device; returns how many. Its pairing and grants stay. */
	public function disconnectDevice(deviceId:String):Int {
		var closed = 0;
		for (session in sessions.copy())
			if (session.deviceId == deviceId) {
				session.close();
				sessions.remove(session);
				closed++;
			}
		if (closed > 0)
			version++;
		return closed;
	}

	/**
		exohost's full quit: ends every remote session and the machine's relay connection now, so no device reaches this
		machine while the daemon finishes the quit. Remote access stays configured (machine-relay.json is kept) and is
		back when exohost next starts. A phone's app is not quit by this; it is cut off and shows the machine as offline.
	**/
	public function cutOff():Void {
		if (host == null && sessions.length == 0)
			return;
		teardown();
		setupError = "remote access was ended by Quit; it resumes when exohost starts again or Exosuit is started again";
		cutByQuit = true;
		version++;
	}

	/**
		A quit the daemon survived was cancelled (the user started Exosuit again): remote access comes back as it was set
		up, as when exohost starts. Does nothing unless `cutOff` ended it.
	**/
	public function resumeAfterQuit():Void {
		if (!cutByQuit)
			return;
		cutByQuit = false;
		setupError = storeError;
		if (storeError == null && FileSystem.exists(configFile()))
			try load() catch (error:Dynamic) {
				setupError = Std.string(error);
				teardown();
			}
		version++;
	}

	public function dispose():Void {
		teardown();
	}

	// ---- MachineSessionHost

	public function machineId():String
		return catalog().state.id;

	/** Changes with grants and devices (`version`), the workspaces' names and folders, and a service starting or stopping (a directory's status). */
	public function revision():Int {
		var total = version + services.revision;
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
				listed.push({workspace: entry.id, name: entry.name, status: services.serviceOf(entry.id) == null ? MachineDirectoryProtocol.IDLE : MachineDirectoryProtocol.RUNNING,
					grants: grants});
		}
		// The relay id names the pairing to the device; the machine's own id is the catalog's (they differ for relays set up now).
		return {machine: machine.id, name: machine.name, revision: revision(), workspaces: listed, relay: endpoint == null ? null : endpoint.machineId};
	}

	public function openService(deviceId:String, workspace:String, grants:Array<String>, start:Bool,
			done:(Null<MessageTransport>, Null<workspace.client.OpenedService>, Null<String>) -> Void):Void {
		if (!start && services.serviceOf(workspace) == null) {
			done(null, null, "workspace_unavailable");
			return;
		}
		services.open(workspace, function(service, error) {
			if (service == null) {
				done(null, null, error == "unknown_workspace" ? error : "workspace_unavailable");
				return;
			}
			try {
				hub.connect(NativeRpcHub.local(service.endpoint), function(result) {
					switch result {
						case Opened(transport):
							if (!transport.send(ForwardedStream.intro(deviceId, grants))) {
								transport.close();
								done(null, null, "workspace_unavailable");
							} else
								done(transport, service, null);
						case Failed(_, _):
							done(null, null, "workspace_unavailable");
					}
				});
			} catch (_:Dynamic) {
				done(null, null, "workspace_unavailable");
			}
		});
	}

	// ---- control requests

	/** A control request for remote access, or null when it is not one. Slow steps answer through a DeferredReply. */
	public function handle(request:Dynamic):Null<Dynamic> {
		var op = ExohostRecords.stringField(request, "op");
		if (op == null || !StringTools.startsWith(op, "remote-"))
			return null;
		try {
			switch op {
				case "remote-status":
					return status();
				case "remote-enable":
					var origin = ExohostRecords.stringField(request, "origin");
					if (origin == null)
						throw "origin is required";
					enable(origin);
					return status();
				case "remote-disable":
					disable();
					return status();
				case "remote-invite":
					var ttl = ExohostRecords.intField(request, "ttl");
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
				case "remote-disconnect":
					// Ends a device's live session now; the pairing stays, so the device may connect again (revoke to cut it off).
					var id = ExohostRecords.stringField(request, "deviceId");
					var closed = id == null ? 0 : disconnectDevice(id);
					return closed > 0 ? {ok: true, sessions: closed} : {ok: false, error: "device_not_connected"};
				case "remote-approve":
					var id = ExohostRecords.stringField(request, "deviceId");
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
					var id = ExohostRecords.stringField(request, "deviceId");
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
					var id = ExohostRecords.stringField(request, "deviceId");
					return id != null && requireManager().reject(id) ? {ok: true} : {ok: false, error: "pairing_not_found"};
				case "remote-revoke":
					var revoked = ExohostRecords.stringField(request, "deviceId");
					if (revoked == null)
						return {ok: false, error: "device_not_found"};
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
			// A relay id that is the catalog id (relays set up before each relay got its own) is in every invitation, so someone
			// else may have registered it first; a derived id is proven and taken back, unless the relay predates proofs.
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
				var open = 0;
				for (session in sessions)
					if (session.deviceId == item.deviceId && session.isOpen())
						open++;
				listed.push({deviceId: item.deviceId, name: store.nameOf(item.deviceId), pairedAt: store.pairedAtOf(item.deviceId),
					connected: item.connected || open > 0, sessions: open, revoked: item.revoked, workspaces: granted});
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
			var id = ExohostRecords.stringField(item, "workspace");
			if (id == null || !Lambda.exists(catalog().state.workspaces, function(entry) return entry.id == id))
				throw "unknown_workspace";
			var grants:Null<Array<String>> = null;
			var preset = ExohostRecords.stringField(item, "preset");
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
