package workspace.runtime;

import haxe.io.Bytes;
import workspace.service.WorkspaceDevicePersistence;
import workspace.service.WorkspaceDeviceRecord;
import workspace.service.WorkspacePairingAdmin;
import workspace.service.WorkspacePairingProtocol.PairingInvitation;
import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspacePairingProtocol.PendingPairing;
import workspace.service.WorkspaceProtocol;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.NoiseServerHandshake;
import workspace.transport.RelayFrameCodec;
import noisekit.NoiseSession;

private typedef PairingInvitationState = {var expiresAt:Float;}
private typedef PairingHandshake = {var deviceId:String; var handshake:NoiseServerHandshake;}
private typedef PairingCandidate = {
	var deviceId:String;
	var staticPublicKey:Bytes;
	var authenticationCode:String;
	var expiresAt:Float;
	var transport:NoiseMessageTransport;
	var state:String;
	var grants:Null<Array<String>>;
	var deviceToken:Null<String>;
	var confirmation:String;
	var relayRegistered:Bool;
	var approvalMessage:Null<Bytes>;
	var completion:Null<Null<String>->Void>;
}

/** Owns one-use invitations and the local approval gate for new Noise devices. */
class WorkspacePairingManager implements WorkspacePairingAdmin {
	static inline final MAX_INVITATIONS:Int = 8;
	static inline final MAX_PENDING:Int = 8;
	static inline final DEFAULT_PENDING_MILLISECONDS:Float = 120000;
	static inline final AUDIT_MILLISECONDS:Float = 1000;

	final store:WorkspaceDevicePersistence;
	final relay:WorkspacePairingRelay;
	final machinePrivateKey:Bytes;
	final offeredGrants:Void->Array<String>;
	final clock:Void->Float;
	final onAuthenticated:NoiseMessageTransport->Array<String>->Void;
	final invitations:Map<String, PairingInvitationState> = [];
	final handshakes:Array<PairingHandshake> = [];
	final pending:Map<String, PairingCandidate> = [];
	final active:Map<String, NoiseMessageTransport> = [];
	final activeRecords:Map<String, WorkspaceDeviceRecord> = [];
	final relayRevocations:Map<String, Bool> = [];
	var nextAudit:Float;
	var disposed:Bool = false;

	public function new(store:WorkspaceDevicePersistence, relay:WorkspacePairingRelay, machinePrivateKey:Bytes,
		offeredGrants:Void->Array<String>, clock:Void->Float,
		onAuthenticated:NoiseMessageTransport->Array<String>->Void) {
		if (store == null || relay == null || machinePrivateKey == null || machinePrivateKey.length != 32
			|| offeredGrants == null || clock == null || onAuthenticated == null)
			throw "Invalid workspace pairing manager configuration";
		this.store = store;
		this.relay = relay;
		this.machinePrivateKey = machinePrivateKey;
		this.offeredGrants = offeredGrants;
		this.clock = clock;
		this.onAuthenticated = onAuthenticated;
		nextAudit = clock() + AUDIT_MILLISECONDS;
	}

	public function createInvitation(ttlSeconds:Int, complete:PairingInvitation->Null<String>->Void):Void {
		if (complete == null)
			throw "Pairing invitation callback cannot be null";
		purgeInvitations();
		if (disposed || !relay.isConnected()) {
			complete(null, "relay_machine_offline");
			return;
		}
		if (ttlSeconds < 1 || ttlSeconds > 300 || invitationCount() >= MAX_INVITATIONS) {
			complete(null, ttlSeconds < 1 || ttlSeconds > 300 ? "invalid_pairing_lifetime" : "pairing_invitation_limit");
			return;
		}
		var generated = NoiseSession.generateKeypair();
		var deviceId = hex(generated.publicKey.sub(0, 16));
		var secret = hex(generated.privateKey);
		wipe(generated.privateKey);
		if (findDevice(deviceId) != null || invitations.exists(deviceId) || pending.exists(deviceId)) {
			complete(null, "pairing_id_collision");
			return;
		}
		relay.createPairing(deviceId, secret, ttlSeconds, function(error) {
			if (disposed) {
				complete(null, "pairing_manager_closed");
				return;
			}
			if (error != null) {
				complete(null, error);
				return;
			}
			invitations.set(deviceId, {expiresAt: clock() + ttlSeconds * 1000});
			var endpoint = relay.pairingEndpoint();
			complete({relayOrigin: endpoint.origin, machineId: endpoint.machineId, deviceId: deviceId,
				secret: secret, pairingSocketUrl: endpoint.pairingSocketUrl(deviceId, secret), expiresInSeconds: ttlSeconds}, null);
		});
	}

	/** Routes only known pinned devices or ids with a live, single-use invitation. */
	public function acceptChannel(deviceId:String, channel:haxeon.rpc.MessageTransport):Void {
		if (disposed || channel == null || !channel.isOpen()) {
			if (channel != null) channel.close();
			return;
		}
		try RelayFrameCodec.decodeChannelId(deviceId) catch (_:Dynamic) {
			channel.close();
			return;
		}
		var device = findDevice(deviceId);
		if (device != null) {
			if (device.revoked) {
				channel.close();
				return;
			}
			startHandshake(deviceId, channel, device.staticPublicKey);
			return;
		}
		var invite = invitations.get(deviceId);
		if (invite == null || invite.expiresAt <= clock() || pending.exists(deviceId) || pairingCount() >= MAX_PENDING) {
			invitations.remove(deviceId);
			channel.close();
			return;
		}
		// The Worker consumes pairing capabilities once. Mirror that locally before
		// starting Noise so a failed transcript cannot reuse this invitation.
		invitations.remove(deviceId);
		startHandshake(deviceId, channel, null);
	}

	function startHandshake(deviceId:String, channel:haxeon.rpc.MessageTransport, expectedKey:Null<Bytes>):Void {
		var handshake:Null<NoiseServerHandshake> = null;
		var created = new NoiseServerHandshake(channel, machinePrivateKey, expectedKey,
			NoisePrologue.encode(relay.pairingEndpoint().machineId, deviceId), clock, function(transport) {
			var currentHandshake = handshake;
			if (currentHandshake == null) {
				transport.close();
				return;
			}
			if (expectedKey != null) {
				var current = findDevice(deviceId);
				if (current == null || current.revoked || !sameBytes(current.staticPublicKey, expectedKey)) {
					transport.close();
					return;
				}
				activate(deviceId, current, transport);
				return;
			}
			var remoteKey = currentHandshake.remoteStaticKey;
			var transcript = currentHandshake.transcriptHash;
			if (remoteKey == null || transcript == null || pending.exists(deviceId) || pairingCount() > MAX_PENDING) {
				transport.close();
				return;
			}
			pending.set(deviceId, {
				deviceId: deviceId,
				staticPublicKey: remoteKey,
				authenticationCode: NoisePairingCode.fromHandshakeHash(transcript),
				expiresAt: clock() + DEFAULT_PENDING_MILLISECONDS,
				transport: transport,
				state: "waiting",
				grants: null,
				deviceToken: null,
				confirmation: "",
				relayRegistered: false,
				approvalMessage: null,
				completion: null
			});
		});
		handshake = created;
		handshakes.push({deviceId: deviceId, handshake: created});
	}

	function activate(deviceId:String, record:WorkspaceDeviceRecord, transport:NoiseMessageTransport):Bool {
		active.set(deviceId, transport);
		activeRecords.set(deviceId, record);
		try
			onAuthenticated(transport, record.grants.copy())
		catch (_:Dynamic) {
			active.remove(deviceId);
			activeRecords.remove(deviceId);
			transport.close();
			return false;
		}
		if (!transport.isOpen()) {
			active.remove(deviceId);
			activeRecords.remove(deviceId);
			return false;
		}
		return true;
	}

	public function listPending():Array<PendingPairing> {
		purgeExpired();
		var result:Array<PendingPairing> = [];
		for (candidate in pending)
			if (candidate.state == "waiting")
				result.push({deviceId: candidate.deviceId, authenticationCode: candidate.authenticationCode,
					expiresInSeconds: Std.int(Math.max(0, (candidate.expiresAt - clock()) / 1000))});
		result.sort(function(left, right) return Reflect.compare(left.deviceId, right.deviceId));
		return result;
	}

	public function listDevices():Array<PairingDevice> {
		var result:Array<PairingDevice> = [];
		for (record in store.loadDevices())
			result.push({deviceId: record.deviceId, grants: record.grants.copy(), revoked: record.revoked,
				connected: !record.revoked && active.exists(record.deviceId)});
		result.sort(function(left, right) return Reflect.compare(left.deviceId, right.deviceId));
		return result;
	}

	public function approve(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void {
		if (complete == null)
			throw "Pairing approval callback cannot be null";
		purgeExpired();
		var candidate = pending.get(deviceId);
		if (candidate == null || candidate.state != "waiting") {
			complete("pairing_not_found");
			return;
		}
		if (!validGrants(grants)) {
			complete("invalid_pairing_grants");
			return;
		}
		if (findDevice(deviceId) != null) {
			complete("device_id_already_registered");
			return;
		}
		candidate.state = "registering";
		candidate.grants = grants.copy();
		var tokenKey = NoiseSession.generateKeypair();
		var deviceToken = hex(tokenKey.privateKey);
		candidate.confirmation = hex(tokenKey.publicKey);
		wipe(tokenKey.privateKey);
		candidate.deviceToken = deviceToken;
		candidate.completion = complete;
		relay.registerDevice(deviceId, deviceToken, function(error) {
			if (pending.get(deviceId) != candidate) {
				revokeRelayDevice(deviceId, function(_) {});
				return;
			}
			if (!candidate.transport.isOpen()) {
				rollback(candidate, "pairing_disconnected");
				return;
			}
			if (error != null) {
				candidate.state = "waiting";
				candidate.grants = null;
				candidate.deviceToken = null;
				candidate.confirmation = "";
				candidate.completion = null;
				complete(error);
				return;
			}
			candidate.relayRegistered = true;
			var record:WorkspaceDeviceRecord = {deviceId: deviceId, staticPublicKey: candidate.staticPublicKey,
				grants: candidate.grants.copy(), revoked: false};
			try {
				store.saveDevice(record);
			} catch (_:Dynamic) {
				rollback(candidate, "device_persistence_failed");
				return;
			}
			candidate.state = "delivering";
			candidate.approvalMessage = Bytes.ofString(haxe.Json.stringify({
				version: 1,
				type: "pairing-approved",
				deviceId: deviceId,
				deviceToken: deviceToken,
				challenge: candidate.confirmation,
				grants: candidate.grants
			}));
			advance(candidate);
		});
	}

	function validGrants(grants:Array<String>):Bool {
		if (grants == null || grants.length > 32)
			return false;
		var offered = offeredGrants(), seen:Map<String, Bool> = [];
		for (grant in grants) {
			if (grant == null || offered.indexOf(grant) < 0 || seen.exists(grant))
				return false;
			seen.set(grant, true);
		}
		return true;
	}

	function advance(candidate:PairingCandidate):Void {
		if (pending.get(candidate.deviceId) != candidate
			|| candidate.state != "delivering" && candidate.state != "awaiting_confirmation")
			return;
		if (!candidate.transport.isOpen()) {
			rollback(candidate, "pairing_disconnected");
			return;
		}
		if (candidate.state == "delivering") {
			var approvalMessage = candidate.approvalMessage;
			if (approvalMessage == null || candidate.grants == null) {
				rollback(candidate, "invalid_pairing_approval");
				return;
			}
			if (!candidate.transport.send(approvalMessage))
				return;
			candidate.state = "awaiting_confirmation";
			candidate.expiresAt = clock() + 10000;
			candidate.approvalMessage = null;
			candidate.deviceToken = null;
			return;
		}
		var confirmation = candidate.transport.receive();
		if (confirmation == null)
			return;
		if (!isValidConfirmation(confirmation, candidate)) {
			rollback(candidate, "pairing_confirmation_invalid");
			return;
		}
		var record:WorkspaceDeviceRecord = {deviceId: candidate.deviceId, staticPublicKey: candidate.staticPublicKey,
			grants: candidate.grants.copy(), revoked: false};
		var completion = candidate.completion;
		if (!activate(candidate.deviceId, record, candidate.transport)) {
			rollback(candidate, "pairing_rpc_admission_failed");
			return;
		}
		pending.remove(candidate.deviceId);
		candidate.completion = null;
		if (completion != null) completion(null);
	}

	function isValidConfirmation(message:Bytes, candidate:PairingCandidate):Bool {
		if (message == null || message.length == 0 || message.length > 1024)
			return false;
		try {
			var value:Dynamic = haxe.Json.parse(message.toString());
			return value != null && value.version == 1 && value.type == "pairing-confirmed"
				&& value.deviceId == candidate.deviceId && value.challenge == candidate.confirmation;
		} catch (_:Dynamic) {
			return false;
		}
	}

	public function reject(deviceId:String):Bool {
		var candidate = pending.get(deviceId);
		if (candidate == null)
			return false;
		rollback(candidate, "pairing_rejected");
		return true;
	}

	function rollback(candidate:PairingCandidate, reason:String):Void {
		if (pending.get(candidate.deviceId) != candidate)
			return;
		pending.remove(candidate.deviceId);
		candidate.transport.close();
		if (findDevice(candidate.deviceId) != null)
			try store.deleteDevice(candidate.deviceId) catch (_:Dynamic) {}
		if (candidate.relayRegistered)
			revokeRelayDevice(candidate.deviceId, function(_) {});
		candidate.state = reason;
		var completion = candidate.completion;
		candidate.completion = null;
		if (completion != null)
			try completion(reason) catch (_:Dynamic) {}
	}

	public function revoke(deviceId:String, complete:Null<String>->Void):Void {
		if (complete == null)
			throw "Device revocation callback cannot be null";
		var record = findDevice(deviceId);
		if (record == null || record.revoked) {
			complete("device_not_found");
			return;
		}
		try
			store.revokeDevice(deviceId)
		catch (_:Dynamic) {
			complete("device_revocation_failed");
			return;
		}
		var transport = active.get(deviceId);
		if (transport != null) transport.close();
		active.remove(deviceId);
		activeRecords.remove(deviceId);
		revokeRelayDevice(deviceId, complete);
	}

	function revokeRelayDevice(deviceId:String, complete:Null<String>->Void):Void {
		relayRevocations.set(deviceId, true);
		relay.revokeDevice(deviceId, function(error) {
			if (error == null)
				relayRevocations.remove(deviceId);
			complete(error);
		});
	}

	public function poll():Void {
		if (disposed)
			return;
		for (item in handshakes.copy()) {
			item.handshake.poll();
			if (item.handshake.finished)
				handshakes.remove(item);
		}
		purgeInvitations();
		purgeExpired();
		for (candidate in pending)
			if (candidate.state == "delivering" || candidate.state == "awaiting_confirmation") advance(candidate);
		for (deviceId in [for (key in active.keys()) key]) {
			var transport = active.get(deviceId);
			if (transport == null || !transport.isOpen()) {
				active.remove(deviceId);
				activeRecords.remove(deviceId);
			}
		}
		if (clock() >= nextAudit) {
			nextAudit = clock() + AUDIT_MILLISECONDS;
			if (relay.isConnected())
				for (deviceId in [for (key in relayRevocations.keys()) key])
					relay.revokeDevice(deviceId, function(error) {
						if (error == null)
							relayRevocations.remove(deviceId);
					});
			var latest = store.loadDevices();
			for (deviceId in [for (key in active.keys()) key]) {
				var transport = active.get(deviceId), previous = activeRecords.get(deviceId), current = findDeviceIn(latest, deviceId);
				if (transport == null || current == null || current.revoked || previous == null
					|| !sameBytes(current.staticPublicKey, previous.staticPublicKey) || !sameGrants(current.grants, previous.grants)) {
					if (transport != null) transport.close();
					active.remove(deviceId);
					activeRecords.remove(deviceId);
				}
			}
		}
	}

	function purgeInvitations():Void {
		for (deviceId in [for (key in invitations.keys()) key]) {
			var invite = invitations.get(deviceId);
			if (invite == null || invite.expiresAt <= clock()) invitations.remove(deviceId);
		}
	}

	function purgeExpired():Void {
		for (deviceId in [for (key in pending.keys()) key]) {
			var candidate = pending.get(deviceId);
			if (candidate != null && candidate.expiresAt <= clock()) rollback(candidate, "pairing_expired");
		}
	}

	function invitationCount():Int {
		var count = 0;
		for (_ in invitations) count++;
		return count;
	}

	function pairingCount():Int {
		var count = pendingCount();
		for (_ in handshakes) count++;
		return count;
	}

	function pendingCount():Int {
		var count = 0;
		for (_ in pending) count++;
		return count;
	}

	function findDevice(deviceId:String):Null<WorkspaceDeviceRecord>
		return findDeviceIn(store.loadDevices(), deviceId);

	static function findDeviceIn(records:Array<WorkspaceDeviceRecord>, deviceId:String):Null<WorkspaceDeviceRecord> {
		for (record in records)
			if (record.deviceId == deviceId) return record;
		return null;
	}

	static function sameBytes(left:Bytes, right:Bytes):Bool {
		if (left == null || right == null || left.length != right.length) return false;
		var difference = 0;
		for (index in 0...left.length) difference |= left.get(index) ^ right.get(index);
		return difference == 0;
	}

	static function sameGrants(left:Array<String>, right:Array<String>):Bool {
		if (left == null || right == null || left.length != right.length) return false;
		var a = left.copy(), b = right.copy();
		a.sort(Reflect.compare);
		b.sort(Reflect.compare);
		for (index in 0...a.length) if (a[index] != b[index]) return false;
		return true;
	}

	static function hex(bytes:Bytes):String {
		var output = new StringBuf();
		for (index in 0...bytes.length) output.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
		return output.toString();
	}

	static function wipe(bytes:Bytes):Void {
		for (index in 0...bytes.length) bytes.set(index, 0);
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (item in handshakes) item.handshake.close();
		handshakes.resize(0);
		for (candidate in [for (item in pending) item]) rollback(candidate, "pairing_manager_closed");
		for (transport in active) transport.close();
		active.clear();
		activeRecords.clear();
		invitations.clear();
	}
}
