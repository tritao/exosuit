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
import workspace.service.WorkspaceFileProtocol;
import workspace.client.WorkspaceAttachment;
import workspace.client.WorkspaceFileClient;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.transport.NativeRpcHub;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.DeviceRpcConnector;
import workspace.transport.RelayDeviceTransport;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelaySocketTicket;
import workspace.transport.RelayTicketAttempt;
import workspace.transport.RelayTicketClient;

typedef BrowserRemoteDevice = {
	var machineId:String;
	var deviceId:String;
	var relayOrigin:Null<String>;
	var updatedAt:Float;
}

/** First-pairing client for the existing browser build; it owns no workspace files locally. */
class BrowserRemoteWorkspaceClient implements WorkspaceAttachment implements WorkspaceRpcEndpoint {
	public var status(default, null):String = "Paste a one-time pairing URL from the desktop Remote Access panel.";
	public var error(default, null):Null<String>;
	public var authenticationCode(default, null):Null<String>;
	public var codeConfirmed(default, null):Bool = false;
	public var workspaceRoot(default, null):Null<String>;
	var serviceInstance:String = "";
	public var grants(default, null):Array<String> = [];
	public var savedDevices(default, null):Array<BrowserRemoteDevice> = [];
	public var connecting(default, null):Bool = false;
	public var lastRpcFailure(default, null):Null<String>;
	public final rpcFailures:Array<String> = [];
	public var revision(default, null):Int = 0;

	final hub:NativeRpcHub;
	final events:NativeKitEvents;
	final clock:Void->Float;
	final changed:Void->Void;
	var operationGeneration:Int = 0;
	var selectedMachine:String;
	var selectedDevice:String;
	var selectedRelayOrigin:Null<String>;
	var selectedDeviceToken:Null<String>;
	var savedConnection:Bool = false;
	var localPrivateKey:Null<Bytes>;
	var machineStaticPublicKey:Null<Bytes>;
	var channel:Null<RelayDeviceTransport>;
	var handshake:Null<NoiseClientHandshake>;
	var secure:Null<NoiseMessageTransport>;
	var connectorAttempt:Null<haxeon.rpc.RpcConnectAttempt>;
	var ticketClient:Null<RelayTicketClient>;
	var ticketAttempt:Null<RelayTicketAttempt>;
	var approved:Null<Dynamic>;
	var approvedChallenge:Null<String>;
	var storeRequest:Int = 0;
	var nextStoreRequest:Int = 1;
	var savedListRequest:Int = 0;
	var savedListRefreshPending:Bool = false;
	var savedLoadRequest:Int = 0;
	var nextSavedRequest:Int = 1;
	var pendingPayloadKind:Int = 0;
	var pendingPayloadRequest:Int = 0;
	var pendingPayloadIndex:Int = 0;
	var pendingPayloadInvalid:Bool = false;
	var pendingPayload = new StringBuf();
	var confirmation:Null<Bytes>;
	var rpc:Null<RpcClient>;
	var reconnectConnector:Null<DeviceRpcConnector>;
	var workspaceConnection:Null<RpcConnection>;
	var fileApiConnection:Null<RpcConnection>;
	var fileApiClient:Null<WorkspaceFileClient>;
	final workbench:RpcWorkspaceWorkbenchClient;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, clock:Void->Float, changed:Void->Void) {
		if (events == null || clock == null || changed == null) throw "Browser remote access needs host services";
		this.events = events;
		this.clock = clock;
		this.changed = changed;
		hub = new NativeRpcHub(events);
		workbench = new RpcWorkspaceWorkbenchClient(this, clock);
		refreshSavedDevices();
	}

	public function beginPairing(url:String):Bool {
		if (disposed) return false;
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		var parsed = BrowserPairingInvitation.parse(StringTools.trim(url));
		if (parsed == null) {
			fail("Enter the complete one-time WSS pairing URL from the desktop.");
			return false;
		}
		selectedMachine = parsed.machineId;
		selectedDevice = parsed.deviceId;
		selectedRelayOrigin = parsed.origin;
		connecting = true;
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
				fail(failure == null || failure == "connect_failed"
					? "Could not connect using this pairing link. Links expire and work only once; create a fresh invitation on the desktop and try again."
					: failure);
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

	public function refreshSavedDevices():Void {
		if (disposed) return;
		if (savedListRequest != 0) {
			savedListRefreshPending = true;
			return;
		}
		savedListRequest = nextSavedRequest++;
		beginPayload(savedListRequest, 1);
		Sys.println("exosuit-remote-list:" + savedListRequest);
	}

	public function receiveStorePayloadChunk(request:Int, kind:Int, index:Int, value:Int):Void {
		if (request != pendingPayloadRequest || kind != pendingPayloadKind) return;
		if (index != pendingPayloadIndex || value < 0 || value > 127 || pendingPayloadIndex >= 32768) {
			pendingPayloadInvalid = true;
			return;
		}
		pendingPayload.addChar(value);
		pendingPayloadIndex++;
	}

	public function receiveStorePayloadComplete(request:Int, kind:Int, length:Int, success:Bool):Void {
		if (request != pendingPayloadRequest || kind != pendingPayloadKind) return;
		if (length != pendingPayloadIndex || pendingPayloadInvalid) success = false;
		var payload = success ? pendingPayload.toString() : "";
		pendingPayload = new StringBuf();
		pendingPayloadRequest = 0;
		pendingPayloadKind = 0;
		pendingPayloadIndex = 0;
		pendingPayloadInvalid = false;
		if (kind == 1 && request == savedListRequest) {
			savedListRequest = 0;
			if (!success) {
				savedDevices = [];
				error = "Could not read saved browser devices.";
				setStatus("Saved devices are unavailable.");
				if (savedListRefreshPending) {
					savedListRefreshPending = false;
					refreshSavedDevices();
				}
				return;
			}
			try {
				var values:Dynamic = Json.parse(payload);
				if (!Std.isOfType(values, Array) || (cast values:Array<Dynamic>).length > 128)
					throw "invalid_device_list";
				var loaded:Array<BrowserRemoteDevice> = [];
				for (value in (cast values:Array<Dynamic>)) {
					var machineId:String = Reflect.field(value, "machineId");
					var deviceId:String = Reflect.field(value, "deviceId");
					var relayOrigin:Null<String> = Reflect.field(value, "relayOrigin");
					if (!validHex(machineId, 32) || !validHex(deviceId, 32)) throw "invalid_device_identity";
					if (relayOrigin != null) {
						try {
							var endpoint = new RelayMachineEndpoint(relayOrigin, machineId);
						if (endpoint.origin != relayOrigin) relayOrigin = null;
						} catch (_:Dynamic) relayOrigin = null;
					}
					var time:Dynamic = Reflect.field(value, "updatedAt");
					var updatedAt:Float = Std.isOfType(time, Float) || Std.isOfType(time, Int) ? time : 0;
					loaded.push({machineId: machineId, deviceId: deviceId, relayOrigin: relayOrigin, updatedAt: updatedAt});
				}
				savedDevices = loaded;
				error = null;
				revision++;
				changed();
			} catch (_:Dynamic) {
				savedDevices = [];
				error = "Saved browser device data is invalid.";
				setStatus("Saved devices are unavailable.");
			}
			if (savedListRefreshPending) {
				savedListRefreshPending = false;
				refreshSavedDevices();
			}
			return;
		}
		if (kind == 2 && request == savedLoadRequest) {
			savedLoadRequest = 0;
			if (!success) {
				fail("Could not open this saved device's encrypted credentials.");
				return;
			}
			try {
				var value:Dynamic = Json.parse(payload);
				var credentials:Dynamic = Reflect.field(value, "credentials");
				var machineId:String = Reflect.field(value, "machineId");
				var deviceId:String = Reflect.field(value, "deviceId");
				var privateHex:String = Reflect.field(credentials, "staticPrivateKey");
				var token:String = Reflect.field(credentials, "deviceToken");
				var machineHex:String = Reflect.field(credentials, "machineStaticPublicKey");
				var relayOrigin:String = Reflect.field(credentials, "relayOrigin");
				if (machineId != selectedMachine || deviceId != selectedDevice || relayOrigin != selectedRelayOrigin
					|| !validHex(privateHex, 64) || !validHex(token, 64) || !validHex(machineHex, 64))
					throw "invalid_saved_credentials";
				localPrivateKey = bytesFromHex(privateHex);
				selectedDeviceToken = token;
				machineStaticPublicKey = bytesFromHex(machineHex);
				requestSavedTicket();
			} catch (_:Dynamic) {
				fail("This saved device could not be authenticated. Pair it again from the desktop.");
			}
		}
	}

	public function beginSavedConnection(machineId:String, deviceId:String):Bool {
		if (disposed) return false;
		var record:Null<BrowserRemoteDevice> = null;
		for (device in savedDevices)
			if (device.machineId == machineId && device.deviceId == deviceId) {
				record = device;
				break;
			}
		if (record == null) {
			fail("That saved browser device is no longer available.");
			return false;
		}
		if (record.relayOrigin == null) {
			fail("This older saved device has no relay address. Pair it again from the desktop.");
			return false;
		}
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		selectedMachine = machineId;
		selectedDevice = deviceId;
		selectedRelayOrigin = record.relayOrigin;
		savedConnection = true;
		connecting = true;
		savedLoadRequest = nextSavedRequest++;
		beginPayload(savedLoadRequest, 2);
		setStatus("Opening encrypted saved-device credentials…");
		Sys.println("exosuit-remote-load:" + Json.stringify({request: savedLoadRequest,
			machineId: machineId, deviceId: deviceId}));
		return true;
	}

	function requestSavedTicket():Void {
		var origin = selectedRelayOrigin, machineId = selectedMachine, token = selectedDeviceToken;
		if (origin == null || machineId == null || token == null) {
			fail("Saved device credentials are incomplete.");
			return;
		}
		var endpoint:RelayMachineEndpoint;
		try endpoint = new RelayMachineEndpoint(origin, machineId) catch (_:Dynamic) {
			fail("The saved relay address is invalid.");
			return;
		}
		try {
			ticketClient = new RelayTicketClient(events, endpoint.isLoopbackHttp);
			var generation = operationGeneration;
			ticketAttempt = ticketClient.request(endpoint, token, function(ticket, error) {
				if (disposed || generation != operationGeneration) return;
				ticketAttempt = null;
				var current = ticketClient;
				ticketClient = null;
				if (current != null) current.dispose();
				if (error != null || ticket == null) {
					fail("Could not get a fresh relay connection ticket: " + (error == null ? "ticket_missing" : error));
					return;
				}
				openSavedDeviceSocket(endpoint, ticket, generation);
			});
			setStatus("Requesting a fresh relay connection ticket…");
		} catch (_:Dynamic) {
			fail("Could not start the saved-device relay connection.");
		}
	}

	function openSavedDeviceSocket(endpoint:RelayMachineEndpoint, ticket:RelaySocketTicket, generation:Int):Void {
		var deviceId = selectedDevice, privateKey = localPrivateKey, machineKey = machineStaticPublicKey;
		if (deviceId == null || privateKey == null || machineKey == null) {
			fail("Saved device keys are unavailable.");
			return;
		}
		try connectorAttempt = hub.connectBytes(NativeRpcHub.websocketUrl(endpoint.websocketUrl(ticket)), function(stream, failure) {
			if (disposed || generation != operationGeneration) {
				if (stream != null) stream.close();
				return;
			}
			connectorAttempt = null;
			if (stream == null) {
				fail(failure == null ? "Could not reconnect to the relay." : failure);
				return;
			}
			try {
				channel = new RelayDeviceTransport(stream, deviceId);
				handshake = new NoiseClientHandshake(channel, privateKey, machineKey,
					NoisePrologue.encode(selectedMachine, deviceId), clock, onNoiseReady);
				setStatus("Verifying the saved machine identity…");
			} catch (_:Dynamic) {
				stream.close();
				fail("Could not start the pinned machine handshake.");
			}
		}) catch (_:Dynamic) {
			fail("Could not open a browser connection to the relay.");
		}
	}


	function onNoiseReady(transport:NoiseMessageTransport):Void {
		secure = transport;
		var current = handshake;
		if (current == null || current.transcriptHash == null || current.remoteStaticKey == null) {
			fail("The relay handshake did not provide a verifiable machine identity.");
			return;
		}
		machineStaticPublicKey = current.remoteStaticKey;
		if (savedConnection) {
			setStatus("Machine identity verified. Connecting to workspace…");
			connectWorkspace(transport);
			return;
		}
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
		refreshSavedDevices();
		var challenge = approvedChallenge, deviceId = selectedDevice;
		if (challenge == null || deviceId == null) {
			fail("The pairing approval is missing its confirmation challenge.");
			return;
		}
		var credentials:Dynamic = approved;
		var deviceToken:Null<String> = credentials == null ? null : Reflect.field(credentials, "deviceToken");
		if (deviceToken == null || !RelaySocketTicket.isToken(deviceToken)) {
			fail("The approved device credentials are unavailable for reconnect.");
			return;
		}
		selectedDeviceToken = deviceToken;
		var message = Bytes.ofString(Json.stringify({version: 1, type: "pairing-confirmed",
			deviceId: deviceId, challenge: challenge}));
		approved = null;
		confirmation = message;
		setStatus("Device approved. Establishing workspace RPC…");
		tryConfirmAndConnect();
	}

	public function poll():Void {
		if (disposed) return;
		workbench.poll();
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
			var connector = reconnectConnector;
			if (connector != null) connector.poll();
			activeRpc.poll();
			if (activeRpc.lastError != null && (rpcFailures.length == 0 || rpcFailures[rpcFailures.length - 1] != activeRpc.lastError.code)) {
				rpcFailures.push(activeRpc.lastError.code);
				if (rpcFailures.length > 16) rpcFailures.shift();
			}
			if (activeRpc.state == RpcClientState.Closed && error == null) {
				var rpcError = activeRpc.lastError;
				var code = rpcError == null ? "" : rpcError.code;
				lastRpcFailure = code;
				fail(switch (code) {
					case "unauthorized", "relay_unauthorized", "authentication_refused", "authorization_failed":
						"This device is no longer authorized. Pair it again from the desktop.";
					case "machine_identity_conflict", "noise_identity_mismatch":
						"The saved machine identity changed. Verify it on the desktop and pair this device again.";
					default:
						"The workspace connection ended. Try a saved device again or pair from the desktop.";
				});
				return;
			}
			if (activeRpc.state != RpcClientState.Connected && !connecting) {
				connecting = true;
				setStatus("Workspace connection lost. Reconnecting securely…");
			}
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
				WorkspaceProtocol.TREE, WorkspaceProtocol.IDENTITY_CAPABILITY, WorkspaceFileProtocol.READ,
				WorkspaceTerminalProtocol.READ,
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
			machineStaticPublicKey: hex(machineKey), relayOrigin: selectedRelayOrigin}));
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
		connectWorkspace(transport);
	}

	function connectWorkspace(transport:NoiseMessageTransport):Void {
		secure = null;
		var origin = selectedRelayOrigin, machineId = selectedMachine, deviceId = selectedDevice;
		var token = selectedDeviceToken, privateKey = localPrivateKey, machineKey = machineStaticPublicKey;
		if (origin == null || machineId == null || deviceId == null || token == null
			|| privateKey == null || machineKey == null) {
			transport.close();
			fail("Authenticated device credentials are unavailable for reconnect.");
			return;
		}
		try reconnectConnector = new DeviceRpcConnector(events, hub, clock,
			new RelayMachineEndpoint(origin, machineId), machineId, deviceId, token,
			privateKey, machineKey, transport) catch (_:Dynamic) {
			transport.close();
			fail("Could not prepare secure workspace reconnect.");
			return;
		}
		var client:RpcClient = null;
		client = new RpcClient(reconnectConnector, clock,
			function() return Math.random(), new RpcPeerOptions("exosuit-editor/1",
				[WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY,
					WorkspaceProtocol.TREE, WorkspaceFileProtocol.READ,
					WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG,
					WorkspaceTerminalProtocol.CONTROL, WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL],
				[WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], 5000, 262144, 32, 1048576),
			function(connection, token, _) onRpcReady(client, connection, token));
		rpc = client;
		client.poll();
	}

	function onRpcReady(client:RpcClient, connection:RpcConnection, token:Int):Void {
		connection.call(WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, 5000, function(identity) {
			if (rpc != client || !client.isCurrent(token)) return;
			if (identity == null || identity.workspace != "workspace" || identity.root == null
				|| identity.root.length == 0 || identity.instance == null || identity.instance.length == 0) {
				fail("Workspace identity response was invalid.");
				return;
			}
			workspaceConnection = connection;
			workspaceRoot = identity.root;
			serviceInstance = identity.instance;
			grants = client.capabilities();
			connecting = false;
			savedConnection = false;
			setStatus("Connected to workspace.");
		}, function(failure) {
			if (rpc == client && client.isCurrent(token)) {
				connecting = true;
				setStatus("Workspace identity check failed. Reconnecting securely…");
				connection.close("workspace_identity_check_failed");
			}
		});
	}

	public function select(root:Null<String>):Void {}

	public function statusLabel():String {
		if (isWorkspaceConnected()) return "Workspace connected";
		return connecting ? (workspaceRoot == null ? "Connecting workspace…" : "Reconnecting workspace…") : "";
	}

	public function failure():Null<String> return error;

	public function fileWorkspace():String return "workspace";

	public function rootPath():Null<String> return workspaceRoot;

	public function serviceGeneration():String return serviceInstance;

	public function rpcConnection():Null<RpcConnection> return isWorkspaceConnected() ? workspaceConnection : null;

	public function failureReason():Null<String>
		return error != null ? error : workspaceRoot == null ? "Workspace disconnected" : null;

	public function supportsWorkspaceGroups():Bool return grants.indexOf(WorkspaceProtocol.TREE) >= 0;

	public function workspaceEpoch():Null<String> return null;

	public function hasCapability(capability:String):Bool return grants.indexOf(capability) >= 0;

	public function workbenchService():WorkspaceWorkbenchClient return workbench;

	public function fileScope():Null<String> return workspaceRoot;

	public function isWorkspaceConnected():Bool
		return workspaceRoot != null && workspaceConnection != null && rpc != null
			&& rpc.current() == workspaceConnection;

	public function canReadFiles():Bool
		return isWorkspaceConnected() && grants.indexOf(WorkspaceFileProtocol.READ) >= 0;

	public function fileClient():Null<WorkspaceFileClient> {
		var connection = canReadFiles() ? workspaceConnection : null;
		if (connection == null) {
			fileApiConnection = null;
			fileApiClient = null;
			return null;
		}
		if (connection != fileApiConnection) {
			fileApiConnection = connection;
			fileApiClient = new WorkspaceFileClient(connection);
		}
		return fileApiClient;
	}

	public function disconnect():Void {
		resetSession();
		error = null;
		authenticationCode = null;
		workspaceRoot = null;
		grants = [];
		setStatus("Disconnected. Paste another one-time pairing URL to connect.");
	}

	public function needsFrames():Bool return !disposed && (rpc != null || handshake != null || channel != null
		|| storeRequest != 0 || confirmation != null || ticketAttempt != null);

	function resetSession():Void {
		operationGeneration++;
		if (storeRequest != 0)
			Sys.println("exosuit-remote-cancel:" + storeRequest);
		if (connectorAttempt != null) connectorAttempt.cancel();
		connectorAttempt = null;
		if (ticketAttempt != null) ticketAttempt.cancel();
		ticketAttempt = null;
		if (ticketClient != null) ticketClient.dispose();
		ticketClient = null;
		if (handshake != null) handshake.close();
		handshake = null;
		if (rpc != null) rpc.close();
		rpc = null;
		if (reconnectConnector != null) reconnectConnector.dispose();
		reconnectConnector = null;
		workspaceConnection = null;
		serviceInstance = "";
		fileApiConnection = null;
		fileApiClient = null;
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
		if (savedLoadRequest != 0 && pendingPayloadRequest == savedLoadRequest) clearPendingPayload();
		selectedMachine = null;
		selectedDevice = null;
		selectedRelayOrigin = null;
		selectedDeviceToken = null;
		savedConnection = false;
		connecting = false;
		savedLoadRequest = 0;
		workbench.poll();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		resetSession();
		workbench.dispose();
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

	static function validHex(value:Null<String>, length:Int):Bool
		return value != null && value.length == length && ~/^[0-9a-f]+$/.match(value);

	static function bytesFromHex(value:String):Bytes {
		if (value == null || value.length % 2 != 0 || !~/^[0-9a-f]+$/.match(value))
			throw "invalid_hex_bytes";
		var result = Bytes.alloc(Std.int(value.length / 2));
		for (index in 0...result.length) {
			var high = "0123456789abcdef".indexOf(value.charAt(index * 2));
			var low = "0123456789abcdef".indexOf(value.charAt(index * 2 + 1));
			result.set(index, (high << 4) | low);
		}
		return result;
	}

	function beginPayload(request:Int, kind:Int):Void {
		pendingPayloadRequest = request;
		pendingPayloadKind = kind;
		pendingPayloadIndex = 0;
		pendingPayloadInvalid = false;
		pendingPayload = new StringBuf();
	}

	function clearPendingPayload():Void {
		pendingPayloadRequest = 0;
		pendingPayloadKind = 0;
		pendingPayloadIndex = 0;
		pendingPayloadInvalid = false;
		pendingPayload = new StringBuf();
	}

	static function wipe(bytes:Null<Bytes>):Void {
		if (bytes != null) for (index in 0...bytes.length) bytes.set(index, 0);
	}
}
