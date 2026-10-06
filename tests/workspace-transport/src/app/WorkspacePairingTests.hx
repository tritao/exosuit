package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import noisekit.NoiseSession;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspacePairingRelay;
import workspace.service.WorkspaceDevicePersistence;
import workspace.service.WorkspaceDeviceRecord;
import workspace.service.WorkspacePairingProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.NoiseServerHandshake;

private class MemoryDeviceStore implements WorkspaceDevicePersistence {
	final devices:Map<String, WorkspaceDeviceRecord> = [];

	public function new() {}

	public function loadDevices():Array<WorkspaceDeviceRecord> {
		var result:Array<WorkspaceDeviceRecord> = [];
		for (device in devices)
			result.push(copy(device));
		return result;
	}

	public function saveDevice(device:WorkspaceDeviceRecord):Void
		devices.set(device.deviceId, copy(device));

	public function revokeDevice(deviceId:String):Void {
		var device = devices.get(deviceId);
		if (device != null) {
			var revoked = copy(device);
			revoked.revoked = true;
			devices.set(deviceId, revoked);
		}
	}

	public function deleteDevice(deviceId:String):Void
		devices.remove(deviceId);

	static function copy(device:WorkspaceDeviceRecord):WorkspaceDeviceRecord
		return {deviceId: device.deviceId, staticPublicKey: device.staticPublicKey.sub(0, device.staticPublicKey.length),
			grants: device.grants.copy(), revoked: device.revoked};
}

private class MemoryPairingRelay implements WorkspacePairingRelay {
	final endpoint:RelayMachineEndpoint;
	public var online:Bool = true;
	public var registrationError:Null<String>;
	public var registered:Map<String, String> = [];
	public var revoked:Array<String> = [];
	public var invitations:Map<String, String> = [];

	public function new() {
		endpoint = new RelayMachineEndpoint("https://relay.example", "0123456789abcdef0123456789abcdef");
	}

	public function pairingEndpoint():RelayMachineEndpoint
		return endpoint;

	public function isConnected():Bool
		return online;

	public function createPairing(channelId:String, secret:String, ttlSeconds:Int, complete:Null<String>->Void):Void {
		invitations.set(channelId, secret);
		complete(null);
	}

	public function registerDevice(channelId:String, token:String, complete:Null<String>->Void):Void {
		if (registrationError != null) {
			complete(registrationError);
			return;
		}
		registered.set(channelId, token);
		complete(null);
	}

	public function revokeDevice(channelId:String, complete:Null<String>->Void):Void {
		revoked.push(channelId);
		registered.remove(channelId);
		complete(null);
	}
}

class WorkspacePairingTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw 'Workspace pairing test failed: ${message}';
	}

	static function manager(store:MemoryDeviceStore, relay:MemoryPairingRelay, machinePrivate:Bytes,
		now:Void->Float, onAuthenticated:NoiseMessageTransport->Array<String>->Void):WorkspacePairingManager
		return new WorkspacePairingManager(store, relay, machinePrivate,
			function() return [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS], now, onAuthenticated);

	static function invitation(pairing:WorkspacePairingManager):workspace.service.WorkspacePairingProtocol.PairingInvitation {
		var result:Null<workspace.service.WorkspacePairingProtocol.PairingInvitation> = null;
		var error:Null<String> = null;
		pairing.createInvitation(30, function(value, failure) {
			result = value;
			error = failure;
		});
		require(error == null && result != null, 'relay issues a short-lived pairing invitation');
		return cast result;
	}

	public static function run():Void {
		approvalAndRevocation();
		rejectionReuseAndExpiry();
		mitmCodeComparison();
		Sys.println('PASS: first-device pairing approval, denial, expiry, single use and revocation');
	}

	static function approvalAndRevocation():Void {
		var nowValue = 1000.0, now = function() return nowValue;
		var store = new MemoryDeviceStore(), relay = new MemoryPairingRelay();
		var machine = NoiseSession.generateKeypair(), authenticated = 0, authenticatedGrants:Array<String> = [];
		var pairing = manager(store, relay, machine.privateKey, now, function(_, grants) {
			authenticated++;
			authenticatedGrants = grants;
		});
		var invite = invitation(pairing);
		var device = NoiseSession.generateKeypair();
		var pair = MemoryTransport.pair(1024 * 1024, 32);
		pairing.acceptChannel(invite.deviceId, pair.server);
		var deviceSecure:Null<NoiseMessageTransport> = null;
		var prologue = NoisePrologue.encode(relay.endpoint.machineId, invite.deviceId);
		var clientNoise = new NoiseClientHandshake(pair.client, device.privateKey, null, prologue, now,
			function(transport) deviceSecure = transport);
		for (_ in 0...12) {
			pairing.poll();
			clientNoise.poll();
		}
		require(clientNoise.finished && clientNoise.failure == null && deviceSecure != null,
			'new device completes an unpinned Noise XX handshake');
		var pending = pairing.listPending();
		require(pending.length == 1 && pending[0].deviceId == invite.deviceId,
			'new device waits in the explicit local approval queue');
		require(pending[0].authenticationCode == NoisePairingCode.fromHandshakeHash(clientNoise.transcriptHash),
			'both endpoints display the same transcript authentication code');
		require(authenticated == 0 && store.loadDevices().length == 0 && relay.registered.get(invite.deviceId) == null,
			'no device credential, persisted trust or RPC admission exists before desktop approval');

		var invalidGrantError:Null<String> = 'callback_missing';
		pairing.approve(invite.deviceId, [WorkspaceProtocol.WRITE], function(error) invalidGrantError = error);
		require(invalidGrantError == 'invalid_pairing_grants' && pairing.listPending().length == 1
			&& relay.registered.get(invite.deviceId) == null,
			'approval cannot grant a capability the workspace did not offer');
		relay.registrationError = 'relay_unavailable';
		var registrationError:Null<String> = 'callback_missing';
		pairing.approve(invite.deviceId, [WorkspaceProtocol.READ], function(error) registrationError = error);
		require(registrationError == 'relay_unavailable' && pairing.listPending().length == 1
			&& store.loadDevices().length == 0 && relay.registered.get(invite.deviceId) == null,
			'relay registration failure leaves the candidate pending and untrusted');
		relay.registrationError = null;
		var approvalError:Null<String> = 'callback_missing';
		pairing.approve(invite.deviceId, [WorkspaceProtocol.READ], function(error) approvalError = error);
		var approvalBytes = deviceSecure.receive();
		require(approvalBytes != null, 'approved device receives its relay bearer inside encrypted Noise');
		var approved:Dynamic = Json.parse(approvalBytes.toString());
		require(approved.type == 'pairing-approved' && approved.deviceId == invite.deviceId
			&& approved.deviceToken == relay.registered.get(invite.deviceId) && approved.challenge != null,
			'approval payload matches the registered relay credential');
		require(approvalError == 'callback_missing' && authenticated == 0,
			'server withholds RPC admission until the device confirms receipt over Noise');
		require(deviceSecure.send(Bytes.ofString(Json.stringify({version: 1, type: 'pairing-confirmed',
			deviceId: invite.deviceId, challenge: approved.challenge}))), 'device sends encrypted receipt confirmation');
		pairing.poll();
		require(approvalError == null && authenticated == 1 && authenticatedGrants.length == 1
			&& authenticatedGrants[0] == WorkspaceProtocol.READ,
			'confirmed approval grants only selected capabilities and then admits RPC');
		var record = store.loadDevices()[0];
		require(record.deviceId == invite.deviceId && !record.revoked && record.grants[0] == WorkspaceProtocol.READ,
			'approved static key and grant subset are persisted');
		var devices = pairing.listDevices();
		require(devices.length == 1 && devices[0].connected && !devices[0].revoked
			&& devices[0].grants[0] == WorkspaceProtocol.READ,
			'local administration can list the approved device without exposing its key or bearer');

		var revokedError:Null<String> = 'callback_missing';
		pairing.revoke(invite.deviceId, function(error) revokedError = error);
		require(revokedError == null && store.loadDevices()[0].revoked && !pair.server.isOpen()
			&& relay.revoked.indexOf(invite.deviceId) >= 0,
			'revocation persists locally, closes the live Noise channel and removes the relay device');
		devices = pairing.listDevices();
		require(devices.length == 1 && devices[0].revoked && !devices[0].connected,
			'revoked devices remain visible in the audit list but cannot appear connected');
		pairing.dispose();
		wipe(machine.privateKey);
		wipe(device.privateKey);
	}

	static function rejectionReuseAndExpiry():Void {
		var nowValue = 5000.0, now = function() return nowValue;
		var store = new MemoryDeviceStore(), relay = new MemoryPairingRelay();
		var machine = NoiseSession.generateKeypair(), pairing = manager(store, relay, machine.privateKey, now, function(_, _) {});
		var rejectedInvite = invitation(pairing), rejectedDevice = NoiseSession.generateKeypair();
		var rejectedPair = MemoryTransport.pair();
		pairing.acceptChannel(rejectedInvite.deviceId, rejectedPair.server);
		var rejectedSecure:Null<NoiseMessageTransport> = null;
		var rejectedNoise = new NoiseClientHandshake(rejectedPair.client, rejectedDevice.privateKey, null,
			NoisePrologue.encode(relay.endpoint.machineId, rejectedInvite.deviceId), now,
			function(transport) rejectedSecure = transport);
		for (_ in 0...12) {
			pairing.poll();
			rejectedNoise.poll();
		}
		require(rejectedSecure != null && pairing.listPending().length == 1, 'candidate reaches approval without RPC');
		require(pairing.reject(rejectedInvite.deviceId) && !rejectedPair.server.isOpen()
			&& store.loadDevices().length == 0 && relay.registered.get(rejectedInvite.deviceId) == null,
			'rejection closes candidate without storing or registering a device');

		var reuseInvite = invitation(pairing), abandoned = MemoryTransport.pair(), replay = MemoryTransport.pair();
		pairing.acceptChannel(reuseInvite.deviceId, abandoned.server);
		pairing.acceptChannel(reuseInvite.deviceId, replay.server);
		require(abandoned.server.isOpen() && !replay.server.isOpen(),
			'local invitation is consumed before handshake completion and cannot be replayed');
		abandoned.server.close();

		var expiryInvite = invitation(pairing), nowBeforeExpiry = nowValue;
		nowValue += 30001;
		pairing.poll();
		var expired = MemoryTransport.pair();
		pairing.acceptChannel(expiryInvite.deviceId, expired.server);
		require(!expired.server.isOpen(), 'expired invitation cannot start a handshake');
		nowValue = nowBeforeExpiry + 30002;

		var pendingInvite = invitation(pairing), pendingDevice = NoiseSession.generateKeypair();
		var pendingPair = MemoryTransport.pair();
		pairing.acceptChannel(pendingInvite.deviceId, pendingPair.server);
		var pendingSecure:Null<NoiseMessageTransport> = null;
		var pendingNoise = new NoiseClientHandshake(pendingPair.client, pendingDevice.privateKey, null,
			NoisePrologue.encode(relay.endpoint.machineId, pendingInvite.deviceId), now,
			function(transport) pendingSecure = transport);
		for (_ in 0...12) {
			pairing.poll();
			pendingNoise.poll();
		}
		require(pendingSecure != null && pairing.listPending().length == 1, 'pending candidate is awaiting approval');
		nowValue += 120001;
		pairing.poll();
		require(pairing.listPending().length == 0 && !pendingPair.server.isOpen()
			&& store.loadDevices().length == 0 && relay.registered.get(pendingInvite.deviceId) == null,
			'unapproved candidate expires and closes without relay registration');

		var confirmationInvite = invitation(pairing), confirmationDevice = NoiseSession.generateKeypair();
		var confirmationPair = MemoryTransport.pair(), confirmationSecure:Null<NoiseMessageTransport> = null;
		pairing.acceptChannel(confirmationInvite.deviceId, confirmationPair.server);
		var confirmationNoise = new NoiseClientHandshake(confirmationPair.client, confirmationDevice.privateKey, null,
			NoisePrologue.encode(relay.endpoint.machineId, confirmationInvite.deviceId), now,
			function(transport) confirmationSecure = transport);
		for (_ in 0...12) {
			pairing.poll();
			confirmationNoise.poll();
		}
		var confirmationError:Null<String> = 'callback_missing';
		pairing.approve(confirmationInvite.deviceId, [WorkspaceProtocol.READ], function(error) confirmationError = error);
		require(confirmationSecure.receive() != null && confirmationError == 'callback_missing',
			'approved bearer waits for encrypted device receipt confirmation');
		nowValue += 10001;
		pairing.poll();
		require(confirmationError == 'pairing_expired' && !confirmationPair.server.isOpen()
			&& store.loadDevices().length == 0 && relay.registered.get(confirmationInvite.deviceId) == null
			&& relay.revoked.indexOf(confirmationInvite.deviceId) >= 0,
			'missing receipt confirmation expires, closes the channel and rolls back local/relay trust');
		pairing.dispose();
		wipe(machine.privateKey);
		wipe(rejectedDevice.privateKey);
		wipe(pendingDevice.privateKey);
		wipe(confirmationDevice.privateKey);
	}

	static function mitmCodeComparison():Void {
		var machine = NoiseSession.generateKeypair(), device = NoiseSession.generateKeypair();
		var direct = transcript(machine.privateKey, device.privateKey, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
		var attacker = NoiseSession.generateKeypair();
		var relayFacingPhone = transcript(attacker.privateKey, device.privateKey, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
		var realMachine = NoiseSession.generateKeypair(), attackerDevice = NoiseSession.generateKeypair();
		var relayFacingMachine = transcript(realMachine.privateKey, attackerDevice.privateKey, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
		require(direct.serverCode == direct.clientCode, 'honest transcript code matches on both peers');
		require(relayFacingPhone.serverCode != relayFacingMachine.clientCode,
			'a relay terminating two independent Noise sessions produces different codes for users to detect');
		wipe(machine.privateKey);
		wipe(device.privateKey);
		wipe(attacker.privateKey);
		wipe(realMachine.privateKey);
		wipe(attackerDevice.privateKey);
	}

	static function transcript(serverPrivate:Bytes, clientPrivate:Bytes, deviceId:String):{serverCode:String, clientCode:String} {
		var pair = MemoryTransport.pair();
		var prologue = NoisePrologue.encode('0123456789abcdef0123456789abcdef', deviceId);
		var serverTransport:Null<NoiseMessageTransport> = null, clientTransport:Null<NoiseMessageTransport> = null;
		var server = new NoiseServerHandshake(pair.server, serverPrivate, null, prologue,
			function() return 0.0, function(transport) serverTransport = transport);
		var client = new NoiseClientHandshake(pair.client, clientPrivate, null, prologue, function() return 0.0,
			function(transport) clientTransport = transport);
		for (_ in 0...12) {
			server.poll();
			client.poll();
		}
		var serverHash = server.transcriptHash, clientHash = client.transcriptHash;
		require(serverHash != null && clientHash != null && equal(serverHash, clientHash),
			'Noise XX peers agree on the transcript hash');
		if (serverTransport != null) serverTransport.close();
		if (clientTransport != null) clientTransport.close();
		return {serverCode: NoisePairingCode.fromHandshakeHash(serverHash),
			clientCode: NoisePairingCode.fromHandshakeHash(clientHash)};
	}

	static function equal(left:Bytes, right:Bytes):Bool {
		if (left == null || right == null || left.length != right.length)
			return false;
		var difference = 0;
		for (index in 0...left.length)
			difference |= left.get(index) ^ right.get(index);
		return difference == 0;
	}

	static function wipe(bytes:Bytes):Void {
		for (index in 0...bytes.length)
			bytes.set(index, 0);
	}
}
