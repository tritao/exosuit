package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.rpc.RpcClientState;
import haxeon.platform.NativeKitEvents;
import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcPeerOptions;
import nativekit.ffi.NativeKitTypes.TransportOptions;
import noisekit.NoiseSession;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.transport.NativeRpcHub;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.RelayDeviceTransport;
import workspace.transport.TransferredMessageConnector;

/** First-pairing client for the existing browser build; it owns no workspace files locally. */
class BrowserRemoteWorkspaceClient {
	public var status(default, null):String = "Paste a one-time pairing URL from the desktop Remote Access panel.";
	public var error(default, null):Null<String>;
	public var authenticationCode(default, null):Null<String>;
	public var codeConfirmed(default, null):Bool = false;
	public var workspaceRoot(default, null):Null<String>;
	public var grants(default, null):Array<String> = [];
	public var revision(default, null):Int = 0;

	final hub:NativeRpcHub;
	final clock:Void->Float;
	final changed:Void->Void;
	var operationGeneration:Int = 0;
	var selectedMachine:String;
	var selectedDevice:String;
	var localPrivateKey:Null<Bytes>;
	var machineStaticPublicKey:Null<Bytes>;
	var channel:Null<RelayDeviceTransport>;
	var handshake:Null<NoiseClientHandshake>;
	var secure:Null<NoiseMessageTransport>;
	var connectorAttempt:Null<haxeon.rpc.RpcConnectAttempt>;
	var approved:Null<Dynamic>;
	var approvedChallenge:Null<String>;
	var storeRequest:Int = 0;
	var nextStoreRequest:Int = 1;
	var confirmation:Null<Bytes>;
	var rpc:Null<RpcClient>;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, clock:Void->Float, changed:Void->Void) {
		if (events == null || clock == null || changed == null) throw "Browser remote access needs host services";
		this.clock = clock;
		this.changed = changed;
		hub = new NativeRpcHub(events);
	}

	public function beginPairing(url:String):Bool {
		if (disposed) return false;
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		var parsed = parseInvitationUrl(StringTools.trim(url));
		if (parsed == null) {
			fail("Enter the complete one-time WSS pairing URL from the desktop.");
			return false;
		}
		selectedMachine = parsed.machineId;
		selectedDevice = parsed.deviceId;
		try {
			var keypair = NoiseSession.generateKeypair();
			localPrivateKey = keypair.privateKey;
		} catch (_:Dynamic) {
			fail("Secure browser randomness is unavailable; pairing cannot continue.");
			return false;
		}
		setStatus("Connecting to relay…");
		var options:TransportOptions;
		try options = NativeRpcHub.websocketUrl(parsed.url)
		catch (_:Dynamic) {
			fail("The pairing URL is invalid or uses an unsupported relay address.");
			return false;
		}
		var generation = operationGeneration;
		try connectorAttempt = hub.connectBytes(options, function(stream, failure) {
			if (disposed || generation != operationGeneration) {
				if (stream != null) stream.close();
				return;
			}
			connectorAttempt = null;
			if (stream == null) {
				fail(failure == null ? "Could not connect to the relay." : failure);
				return;
			}
			try {
				var deviceId = selectedDevice, machineId = selectedMachine, privateKey = localPrivateKey;
				if (deviceId == null || machineId == null || privateKey == null) throw "pairing_state_missing";
				channel = new RelayDeviceTransport(stream, deviceId);
				handshake = new NoiseClientHandshake(channel, privateKey, null,
					NoisePrologue.encode(machineId, deviceId), clock, onNoiseReady);
				setStatus("Verifying encrypted connection…");
			} catch (_:Dynamic) {
				stream.close();
				fail("Could not start the secure pairing handshake.");
			}
		}) catch (_:Dynamic) {
			fail("Could not open a browser connection to the relay.");
			return false;
		}
		return true;
	}

	static function parseInvitationUrl(url:String):Null<{url:String, machineId:String, deviceId:String}> {
		var pattern = ~/^(wss?):\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?\/v1\/machines\/([0-9a-f]{32})\/pair\/([0-9a-f]{32})\?secret=([0-9a-f]{64})$/;
		if (url == null || !pattern.match(url)) return null;
		var scheme = pattern.matched(1).toLowerCase();
		var host = pattern.matched(2).toLowerCase();
		var port = pattern.matched(3);
		if (port != null && (Std.parseInt(port) == null || Std.parseInt(port) > 65535 || Std.parseInt(port) < 1)) return null;
		if (scheme != "wss" && host != "localhost" && host != "127.0.0.1") return null;
		return {url: url, machineId: pattern.matched(4), deviceId: pattern.matched(5)};
	}

	function onNoiseReady(transport:NoiseMessageTransport):Void {
		secure = transport;
		var current = handshake;
		if (current == null || current.transcriptHash == null || current.remoteStaticKey == null) {
			fail("The relay handshake did not provide a verifiable machine identity.");
			return;
		}
		machineStaticPublicKey = current.remoteStaticKey;
		authenticationCode = NoisePairingCode.fromHandshakeHash(current.transcriptHash);
		setStatus("Compare this code with the one shown on the desktop.");
	}

	/** Called only after the user has compared the browser and desktop codes. */
	public function confirmCode():Void {
		if (authenticationCode == null || secure == null || !secure.isOpen()) return;
		codeConfirmed = true;
		if (approved != null) storeApprovedDevice(approved);
		else setStatus("Code confirmed. Waiting for desktop approval…");
	}

	public function credentialStored(request:Int, success:Bool):Void {
		if (request != storeRequest || storeRequest == 0 || disposed) return;
		storeRequest = 0;
		if (!success) {
			fail("Could not protect this device credential in browser storage; the pairing was not completed.");
			return;
		}
		var challenge = approvedChallenge, deviceId = selectedDevice;
		if (challenge == null || deviceId == null) {
			fail("The pairing approval is missing its confirmation challenge.");
			return;
		}
		wipe(localPrivateKey);
		localPrivateKey = null;
		var message = Bytes.ofString(Json.stringify({version: 1, type: "pairing-confirmed",
			deviceId: deviceId, challenge: challenge}));
		approved = null;
		confirmation = message;
		setStatus("Device approved. Establishing workspace RPC…");
		tryConfirmAndConnect();
	}

	public function poll():Void {
		if (disposed) return;
		var currentHandshake = handshake;
		if (currentHandshake != null) {
			currentHandshake.poll();
			if (currentHandshake.finished) {
				handshake = null;
				if (currentHandshake.failure != null) {
					fail("Secure pairing failed: " + currentHandshake.failure);
					return;
				}
			}
		}
		var activeRpc = rpc;
		if (activeRpc != null) {
			activeRpc.poll();
			if (activeRpc.state == RpcClientState.Closed && error == null)
				fail("The workspace connection closed. Reconnect with a new pairing invitation or a saved device.");
			return;
		}
		var transport = secure;
		if (transport != null && transport.isOpen() && storeRequest == 0 && confirmation == null) {
			var message = transport.receive();
			if (message != null) receiveApproval(message);
			if (!transport.isOpen() && rpc == null && error == null)
				fail("The pairing connection closed before it was confirmed.");
		}
		if (confirmation != null) tryConfirmAndConnect();
	}

	function receiveApproval(message:Bytes):Void {
		if (approved != null) {
			fail("The pairing server sent an unexpected second approval message.");
			return;
		}
		try {
			var value:Dynamic = Json.parse(message.toString());
			if (value == null || value.version != 1 || value.type != "pairing-approved"
				|| value.deviceId != selectedDevice || value.challenge == null
				|| !~/^[0-9a-f]{64}$/.match(value.challenge) || value.deviceToken == null
				|| !~/^[0-9a-f]{64}$/.match(value.deviceToken) || value.grants == null
				|| !Std.isOfType(value.grants, Array)) throw "invalid_approval";
			var offered = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE,
				WorkspaceProtocol.TREE, WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceTerminalProtocol.READ,
				WorkspaceTerminalProtocol.CATALOG, WorkspaceTerminalProtocol.CONTROL,
				WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL];
			var seen:Map<String, Bool> = [];
			for (grant in (cast value.grants:Array<String>)) {
				if (grant == null || offered.indexOf(grant) < 0 || seen.exists(grant)) throw "invalid_grants";
				seen.set(grant, true);
			}
			if (!seen.exists(WorkspaceProtocol.READ) || !seen.exists(WorkspaceProtocol.IDENTITY_CAPABILITY))
				throw "missing_required_grant";
			grants = (cast value.grants:Array<String>).copy();
			approvedChallenge = value.challenge;
			approved = {deviceToken: value.deviceToken};
			setStatus(codeConfirmed ? "Desktop approved. Protecting this device credential…" : "Desktop approved. Confirm the matching code here to finish pairing.");
			if (codeConfirmed) storeApprovedDevice(value);
		} catch (_:Dynamic) {
			fail("The pairing server sent an invalid approval response.");
		}
	}

	function storeApprovedDevice(value:Dynamic):Void {
		var privateKey = localPrivateKey, machineKey = machineStaticPublicKey;
		var machineId = selectedMachine, deviceId = selectedDevice;
		if (storeRequest != 0 || privateKey == null || machineKey == null || machineId == null || deviceId == null) return;
		storeRequest = nextStoreRequest++;
		setStatus("Protecting device credentials in browser storage…");
		Sys.println("exosuit-remote-store:" + Json.stringify({request: storeRequest, machineId: machineId,
			deviceId: deviceId, staticPrivateKey: hex(privateKey), deviceToken: value.deviceToken,
			machineStaticPublicKey: hex(machineKey)}));
	}

	function tryConfirmAndConnect():Void {
		var transport = secure, message = confirmation;
		if (transport == null || message == null || !transport.isOpen()) return;
		if (!transport.send(message)) {
			if (!transport.isOpen()) fail("Could not confirm the approved device.");
			return;
		}
		confirmation = null;
		secure = null;
		var client:RpcClient = null;
		client = new RpcClient(new TransferredMessageConnector(transport), clock,
			function() return Math.random(), new RpcPeerOptions("exosuit-editor/1",
				[WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY,
					WorkspaceProtocol.TREE, WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG,
					WorkspaceTerminalProtocol.CONTROL, WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL],
				[WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], 5000, 262144, 32, 1048576),
			function(connection, token, _) onRpcReady(client, connection, token));
		rpc = client;
		client.poll();
	}

	function onRpcReady(client:RpcClient, connection:RpcConnection, token:Int):Void {
		connection.call(WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, 5000, function(identity) {
			if (rpc != client || !client.isCurrent(token)) return;
			workspaceRoot = identity.root;
			setStatus("Connected to workspace.");
		}, function(failure) {
			if (rpc == client && client.isCurrent(token)) fail("Workspace identity check failed: " + failure.code);
		});
	}

	public function disconnect():Void {
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		setStatus("Disconnected. Paste another one-time pairing URL to connect.");
	}

	public function needsFrames():Bool return !disposed && (rpc != null || handshake != null || channel != null || storeRequest != 0 || confirmation != null);

	function resetSession():Void {
		operationGeneration++;
		if (storeRequest != 0)
			Sys.println("exosuit-remote-cancel:" + storeRequest);
		if (connectorAttempt != null) connectorAttempt.cancel();
		connectorAttempt = null;
		if (handshake != null) handshake.close();
		handshake = null;
		if (rpc != null) rpc.close();
		rpc = null;
		if (secure != null) secure.close();
		secure = null;
		if (channel != null) channel.close();
		channel = null;
		wipe(localPrivateKey);
		localPrivateKey = null;
		machineStaticPublicKey = null;
		approved = null;
		approvedChallenge = null;
		confirmation = null;
		codeConfirmed = false;
		storeRequest = 0;
		selectedMachine = null;
		selectedDevice = null;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		resetSession();
		hub.dispose();
	}

	function fail(message:String):Void {
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		error = message;
		setStatus("Remote access needs attention.");
	}

	function setStatus(value:String):Void {
		if (status == value) return;
		status = value;
		revision++;
		changed();
	}

	static function hex(bytes:Bytes):String {
		var output = new StringBuf();
		for (index in 0...bytes.length) {
			var value = bytes.get(index);
			output.addChar("0123456789abcdef".charCodeAt(value >>> 4));
			output.addChar("0123456789abcdef".charCodeAt(value & 0xf));
		}
		return output.toString();
	}

	static function wipe(bytes:Null<Bytes>):Void {
		if (bytes != null) for (index in 0...bytes.length) bytes.set(index, 0);
	}
}
