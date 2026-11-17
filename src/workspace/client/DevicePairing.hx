package workspace.client;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import nativekit.ffi.NativeKitTypes.TransportOptions;
import noisekit.NoiseSession;
import workspace.service.MachineDirectoryProtocol;
import workspace.transport.NativeRpcHub;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.RelayDeviceTransport;

/** One machine a device paired with, as the device keeps it. The key and token are secrets: the host keeps them protected. */
typedef PairedMachine = {
	/** The relay id the device paired under. */
	var machineId:String;
	var deviceId:String;
	var relayOrigin:String;
	/** The device's Noise private key, hex. */
	var staticPrivateKey:String;
	var deviceToken:String;
	/** The machine's Noise public key the device pins, hex. */
	var machineStaticPublicKey:String;
	/** The machine's name, learned from its directory. Null until then. */
	var name:Null<String>;
}

/** Where a device keeps its pairings: the phone's Keystore file, the browser's encrypted storage. */
interface PairedMachines {
	function paired():Array<PairedMachine>;
	/** Adds or replaces a pairing; `done(false)` when it could not be stored. */
	function put(device:PairedMachine, done:Bool->Void):Void;
	function remove(machineId:String, deviceId:String, done:Bool->Void):Void;
	/** The machine's name, as its directory gave it: kept so an offline machine still shows it. */
	function learn(machineId:String, deviceId:String, name:String):Void;
}

/**
	A device pairing with a machine (ADR 0005 section 4), shared by every device client (the phone, the browser): a
	one-time invitation from the machine's Remote Access panel (`PairingLink`), Noise XX over the relay's pairing socket,
	the code the user compares with the machine, the machine's approval (which grants only the machine directory), then
	the credentials go to the device's store and the encrypted receipt confirms them to the machine.

	The owner reads `status`, `authenticationCode`, `codeConfirmed`, `machineKeyVerified` and `machineKeyChanged` for its
	panel, and is told through `failed` (the pairing ended; a sentence for the user) and `paired` (the stored pairing,
	the authenticated channel, which the machine connection takes over, and the older pairings of the same machine that
	it replaced).
**/
class DevicePairing {
	/** A pairing gives up after this long: past the invitation's lifetime and both of the machine's pairing windows. */
	static inline final PAIRING_MILLISECONDS:Float = 600000;

	public var status(default, null):String = "";
	public var authenticationCode(default, null):Null<String>;
	public var codeConfirmed(default, null):Bool = false;
	/**
		True when this device is already paired with a machine of the invitation's id whose key differs from the one this
		pairing reached: either that machine was reset, or the invitation leads somewhere else. Confirming replaces the old
		pairing, so the panel warns first.
	**/
	public var machineKeyChanged(default, null):Bool = false;
	/**
		Whether the invitation carried the machine key's fingerprint (`#mk=`) and the key the handshake reached matched it.
		A mismatch ends the pairing at once; false means an invitation without one (an older desktop), where comparing the
		code is the only check.
	**/
	public var machineKeyVerified(default, null):Bool = false;
	/** True while a pairing is in progress (connecting, comparing the code, waiting for approval). */
	public var active(default, null):Bool = false;
	/** Changes whenever anything above does. */
	public var revision(default, null):Int = 0;

	public var failed:String->Void = function(_) {};
	public var paired:(PairedMachine, MessageTransport, Array<PairedMachine>) -> Void = function(_, _, _) {};

	final hub:NativeRpcHub;
	final clock:Void->Float;
	final store:PairedMachines;
	var generation = 0;
	var invitation:Null<PairingLink>;
	var privateKey:Null<Bytes>;
	var machineKey:Null<Bytes>;
	var connectorAttempt:Null<RpcConnectAttempt>;
	var channel:Null<RelayDeviceTransport>;
	var handshake:Null<NoiseClientHandshake>;
	var secure:Null<NoiseMessageTransport>;
	var approved:Null<{deviceToken:String, challenge:String}>;
	var confirmation:Null<Bytes>;
	var storing = false;
	var pendingDevice:Null<PairedMachine>;
	/** Older pairings of the machine being paired: forgotten once the machine has the confirmation, not before. */
	var replacing:Array<PairedMachine> = [];
	var deadline:Float = 0;

	public function new(hub:NativeRpcHub, clock:Void->Float, store:PairedMachines) {
		this.hub = hub;
		this.clock = clock;
		this.store = store;
	}

	/** Starts pairing with the invitation `url`; false (and `failed`) when it cannot start. */
	public function begin(url:String):Bool {
		reset();
		var parsed = PairingLink.parse(StringTools.trim(url));
		if (parsed == null) {
			fail("Enter the complete one-time pairing URL from the machine.");
			return false;
		}
		invitation = parsed;
		active = true;
		deadline = clock() + PAIRING_MILLISECONDS;
		try privateKey = NoiseSession.generateKeypair().privateKey catch (_:Dynamic) {
			fail("Secure randomness is unavailable; pairing cannot continue.");
			return false;
		}
		setStatus("Connecting to the relay…");
		var options:TransportOptions;
		try options = NativeRpcHub.websocketUrl(parsed.socketUrl) catch (_:Dynamic) {
			fail("The pairing URL uses an unsupported relay address.");
			return false;
		}
		var token = generation;
		try connectorAttempt = hub.connectBytes(options, function(stream, failure) {
			if (token != generation) {
				if (stream != null) stream.close();
				return;
			}
			connectorAttempt = null;
			if (stream == null) {
				fail(failure == null || failure == "connect_failed" ? "Could not connect using this pairing link. Links expire and work once; create a fresh invitation." : failure);
				return;
			}
			try {
				channel = new RelayDeviceTransport(stream, parsed.deviceId);
				handshake = new NoiseClientHandshake(channel, privateKey, null, NoisePrologue.encode(parsed.relayId, parsed.deviceId), clock, noiseReady);
				setStatus("Verifying the encrypted connection…");
			} catch (_:Dynamic) {
				stream.close();
				fail("Could not start the secure pairing handshake.");
			}
		}) catch (_:Dynamic) {
			fail("Could not open a connection to the relay.");
			return false;
		}
		return true;
	}

	function noiseReady(transport:NoiseMessageTransport):Void {
		secure = transport;
		var done = handshake;
		if (done == null || done.transcriptHash == null || done.remoteStaticKey == null) {
			fail("The relay handshake did not give a verifiable machine identity.");
			return;
		}
		machineKey = done.remoteStaticKey;
		var parsed = invitation, reached = hex(done.remoteStaticKey);
		if (parsed != null && !parsed.admits(done.remoteStaticKey)) {
			// Someone between the device and the machine (the relay, or whoever has the link) answered with another key.
			fail("The machine that answered is not the one that made this invitation: its key does not match the invitation. "
				+ "Nothing was paired. Create a fresh invitation on the machine and try again; if it happens again, do not pair over this relay.");
			return;
		}
		machineKeyVerified = parsed != null && parsed.machineKey != null;
		machineKeyChanged = false;
		if (parsed != null)
			for (existing in store.paired())
				if (existing.machineId == parsed.relayId && existing.machineStaticPublicKey.toLowerCase() != reached)
					machineKeyChanged = true;
		authenticationCode = NoisePairingCode.fromHandshakeHash(done.transcriptHash);
		testLog(machineKeyVerified ? "exosuit-pairing: machine key matches the invitation" : "exosuit-pairing: the invitation has no machine key");
		testLog("exosuit-pairing: code " + authenticationCode);
		setStatus("Compare this code with the machine.");
	}

	/** The user compared the code with the machine's. */
	public function confirmCode():Void {
		if (authenticationCode == null || secure == null) return;
		if (!secure.isOpen()) {
			abandon("The pairing connection closed before it was confirmed. Create a fresh invitation on the machine.");
			return;
		}
		codeConfirmed = true;
		testLog("exosuit-pairing: the user confirmed the code" + (approved != null ? ", storing the credentials" : ", waiting for the machine's approval"));
		if (approved != null) storeApproved();
		else setStatus("Code confirmed. Waiting for the machine's owner to approve.");
		revision++;
	}

	function receiveApproval(message:Bytes):Void {
		if (approved != null) {
			fail("The machine sent a second approval.");
			return;
		}
		try {
			var value:Dynamic = Json.parse(message.toString());
			var parsed = invitation;
			if (parsed == null || value == null || value.version != 1 || value.type != "pairing-approved" || value.deviceId != parsed.deviceId
				|| value.challenge == null || !~/^[0-9a-f]{64}$/.match(value.challenge) || value.deviceToken == null
				|| !~/^[0-9a-f]{64}$/.match(value.deviceToken) || !Std.isOfType(value.grants, Array))
				throw "invalid_approval";
			// Pairing grants only the machine directory; the owner grants workspaces afterwards.
			var granted:Array<String> = cast value.grants;
			if (granted.indexOf(MachineDirectoryProtocol.CAPABILITY) < 0) throw "missing_required_grant";
			approved = {deviceToken: value.deviceToken, challenge: value.challenge};
			testLog("exosuit-pairing: approved by the machine" + (codeConfirmed ? "" : ", waiting for the code confirmation"));
			setStatus(codeConfirmed ? "The machine approved. Storing the credentials…" : "The machine approved. Confirm the matching code to finish.");
			if (codeConfirmed) storeApproved();
		} catch (_:Dynamic) {
			fail("The machine sent an invalid approval.");
		}
	}

	function storeApproved():Void {
		var parsed = invitation, key = privateKey, machine = machineKey, grant = approved;
		if (storing || parsed == null || key == null || machine == null || grant == null) return;
		storing = true;
		var token = generation;
		var device:PairedMachine = {machineId: parsed.relayId, deviceId: parsed.deviceId, relayOrigin: parsed.origin, staticPrivateKey: hex(key),
			deviceToken: grant.deviceToken, machineStaticPublicKey: hex(machine), name: null};
		// A machine is paired once: an older pairing of the same machine is replaced, not kept beside the new one.
		var replaced = [for (existing in store.paired()) if (existing.machineId == device.machineId && existing.deviceId != device.deviceId) existing];
		store.put(device, function(ok) {
			if (token != generation) {
				// The pairing was cancelled or failed while the store wrote: the machine never got the confirmation.
				if (ok) store.remove(device.machineId, device.deviceId, function(_) {});
				return;
			}
			storing = false;
			if (!ok) {
				fail("Could not store the credentials on this device; the pairing was not completed.");
				return;
			}
			replacing = replaced;
			pendingDevice = device;
			confirmation = Bytes.ofString(Json.stringify({version: 1, type: "pairing-confirmed", deviceId: parsed.deviceId, challenge: grant.challenge}));
			approved = null;
			setStatus("Paired. Connecting to the machine…");
			tryConfirm();
		});
	}

	function tryConfirm():Void {
		var transport = secure, message = confirmation, device = pendingDevice;
		if (transport == null || message == null || device == null || !transport.isOpen()) return;
		if (!transport.send(message)) {
			if (!transport.isOpen()) abandon("Could not confirm the approved device.");
			return;
		}
		// The machine connection owns the channel and the key now; the pairing lets go of them without closing.
		secure = null;
		channel = null;
		var older = replacing;
		reset();
		setStatus("Paired. Waiting for the owner to grant workspaces.");
		paired(device, transport, older);
	}

	/** Moves the handshake, the approval and the confirmation along; call every frame. */
	public function poll():Void {
		var shake = handshake;
		if (shake != null) {
			shake.poll();
			if (shake.finished) {
				handshake = null;
				if (shake.failure != null) {
					fail("Secure pairing failed: " + shake.failure);
					return;
				}
			}
		}
		var transport = secure;
		// A close in any phase before the confirmation is sent ends the pairing, also once the approval is here: nothing else would.
		if (transport != null && !storing) {
			if (!transport.isOpen())
				// The machine closes the channel when it gives the pairing up (declined, or 2 minutes without approval or confirmation).
				abandon(approved == null && pendingDevice == null
					? "The pairing ended before the machine approved it: it was declined, it waited longer than 2 minutes, or the connection dropped. "
						+ "Create a fresh invitation on the machine and pair again."
					: "The pairing ended before the code was confirmed here: the machine waits 2 minutes after approving, or the connection dropped. "
						+ "Create a fresh invitation on the machine and pair again.");
			else if (confirmation == null && pendingDevice == null && approved == null) {
				var message = transport.receive();
				if (message != null) receiveApproval(message);
			}
		}
		if (active && !storing && clock() > deadline)
			abandon("Pairing took too long. Create a fresh invitation on the machine.");
		if (confirmation != null) tryConfirm();
	}

	/** The user gave up on the pairing in progress. */
	public function cancel():Void {
		if (active) abandon(null);
	}

	/**
		Ends a pairing that cannot finish. Credentials already stored for it go: the machine never got the confirmation, so
		it rolls the device back, and a restart would dial a device it does not know.
	**/
	function abandon(message:Null<String>):Void {
		var stored = pendingDevice;
		if (message != null) fail(message);
		else {
			reset();
			setStatus("");
		}
		if (stored != null) store.remove(stored.machineId, stored.deviceId, function(_) {});
	}

	function fail(message:String):Void {
		if (active) testLog("exosuit-pairing: failed: " + message);
		reset();
		status = "";
		revision++;
		failed(message);
	}

	/** Drops any pairing in progress and everything it held. */
	public function reset():Void {
		generation++;
		if (connectorAttempt != null) connectorAttempt.cancel();
		connectorAttempt = null;
		if (handshake != null) handshake.close();
		handshake = null;
		if (secure != null) secure.close();
		secure = null;
		if (channel != null) channel.close();
		channel = null;
		wipe(privateKey);
		privateKey = null;
		machineKey = null;
		approved = null;
		confirmation = null;
		pendingDevice = null;
		replacing = [];
		storing = false;
		invitation = null;
		authenticationCode = null;
		codeConfirmed = false;
		machineKeyChanged = false;
		machineKeyVerified = false;
		active = false;
		revision++;
	}

	function setStatus(value:String):Void {
		if (status == value) return;
		status = value;
		revision++;
	}

	/**
		Whether this is a test run: the rig turns on the debug app's automation (`EXOSUIT_AUTOMATION_DIR`, see
		ExosuitActivity), and the acceptance scripts read the `exosuit-pairing:` and `exosuit-machine:` lines from the log.
	**/
	public static final testRun:Bool = { var dir = Sys.getEnv("EXOSUIT_AUTOMATION_DIR"); dir != null && dir.length > 0; };

	/** A line for the test run's log checks; nothing in other runs. */
	public static function testLog(line:String):Void
		if (testRun) Sys.println(line);

	public static function hex(bytes:Bytes):String {
		var output = new StringBuf();
		for (index in 0...bytes.length) {
			var value = bytes.get(index);
			output.addChar("0123456789abcdef".charCodeAt(value >>> 4));
			output.addChar("0123456789abcdef".charCodeAt(value & 0xf));
		}
		return output.toString();
	}

	public static function bytesFromHex(value:String):Bytes {
		if (value == null || value.length % 2 != 0 || !~/^[0-9a-f]+$/.match(value)) throw "invalid_hex_bytes";
		var result = Bytes.alloc(Std.int(value.length / 2));
		for (index in 0...result.length)
			result.set(index, ("0123456789abcdef".indexOf(value.charAt(index * 2)) << 4) | "0123456789abcdef".indexOf(value.charAt(index * 2 + 1)));
		return result;
	}

	static function wipe(bytes:Null<Bytes>):Void {
		if (bytes != null) for (index in 0...bytes.length) bytes.set(index, 0);
	}
}
