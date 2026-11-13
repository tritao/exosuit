import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnection;
import nativekit.ffi.NativeKitTypes.TransportOptions;
import noisekit.NoiseSession;
import scm.ScmSource;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.client.WorkspaceAttachment;
import workspace.client.WorkspaceCatalogMirror;
import workspace.client.WorkspaceFileClient;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.WorkspaceTerminalEvents;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.transport.NativeRpcHub;
import workspace.transport.NoiseClientHandshake;
import workspace.transport.NoiseMessageTransport;
import workspace.transport.NoisePairingCode;
import workspace.transport.NoisePrologue;
import workspace.transport.RelayDeviceTransport;

/**
	The phone's attachment to the machines it is paired with, over the relay, using the shared desktop clients (ADR 0005
	section 4, M19 Phase 9):

	- pairing: a one-time invitation from the machine (suit), Noise XX, the code the user compares with the machine,
	  approval (which grants only the machine directory), then the credentials go to the host's Keystore
	  (`PhoneCredentials`). Pairing a machine does not touch the machines already connected;
	- each paired machine is a `PhoneMachine`: one relay channel, the directory of the workspaces the owner granted this
	  device (it follows grants without pairing again) and catalog watches for the running ones;
	- the open workspace is a `PhoneWorkspace`: its own stream, with the full client grants. This class presents it to
	  ExosuitApp as the attachment (files, terminals, the Workbench's `RpcWorkspaceWorkbenchClient`); with none open, the
	  attachment is empty and the Remote panel lists machines and their workspaces.
**/
class PhoneRemote implements WorkspaceAttachment implements WorkspaceRpcEndpoint implements PhoneViewSource {
	static inline final NOT_PAIRED = "Paste the one-time pairing URL from the machine's Remote Access panel to pair this phone.";
	/** A pairing gives up after this long: past the invitation's lifetime and both of the machine's pairing windows. */
	static inline final PAIRING_MILLISECONDS:Float = 600000;

	public var status(default, null):String = NOT_PAIRED;
	public var error(default, null):Null<String>;
	public var authenticationCode(default, null):Null<String>;
	public var codeConfirmed(default, null):Bool = false;
	/**
		True when this phone is already paired with a machine of the invitation's id whose key differs from the one this
		pairing reached: either that machine was reset, or the invitation leads somewhere else. Confirming replaces the old
		pairing, so the panel warns first.
	**/
	public var machineKeyChanged(default, null):Bool = false;
	/**
		Whether the invitation carried the machine key's fingerprint (`#mk=`) and the key the handshake reached matched it.
		A mismatch ends the pairing at once; false means an invitation without one (an older desktop), where comparing the
		code is the only check, and the panel says so.
	**/
	public var machineKeyVerified(default, null):Bool = false;
	/** True while a pairing is in progress (connecting, comparing the code, waiting for approval). */
	public var pairing(default, null):Bool = false;
	public var revision(default, null):Int = 0;
	public final credentials:PhoneCredentials;
	/** The paired machines, in the order they were paired. */
	public var machines(default, null):Array<PhoneMachine> = [];
	/** The workspace the phone has open, if any. */
	public var open(default, null):Null<PhoneWorkspace>;
	public var openMachine(default, null):Null<PhoneMachine>;

	final events:EventPump;
	final clock:Void->Float;
	final changed:Void->Void;
	final hub:NativeRpcHub;
	final workbench:RpcWorkspaceWorkbenchClient;
	var generation = 0;
	var invitation:Null<PhoneInvitation>;
	var privateKey:Null<Bytes>;
	var machineKey:Null<Bytes>;
	var connectorAttempt:Null<RpcConnectAttempt>;
	var channel:Null<RelayDeviceTransport>;
	var handshake:Null<NoiseClientHandshake>;
	var secure:Null<NoiseMessageTransport>;
	var approved:Null<{deviceToken:String, challenge:String}>;
	var confirmation:Null<Bytes>;
	var storing = false;
	var pendingDevice:Null<SavedDevice>;
	/** Older pairings of the machine being paired: forgotten once the machine has the confirmation, not before. */
	var replacing:Array<SavedDevice> = [];
	var pairingDeadline:Float = 0;
	var consumedCatalog = -1;
	var shownKey = "";
	final lastReport:Map<String, String> = [];
	var disposed = false;

	public function new(events:EventPump, clock:Void->Float, credentials:PhoneCredentials, changed:Void->Void) {
		this.events = events;
		this.clock = clock;
		this.credentials = credentials;
		this.changed = changed;
		hub = new NativeRpcHub(events);
		workbench = new RpcWorkspaceWorkbenchClient(this, clock);
		workbench.workspaceIdentity = function() return open == null ? null : open.id;
		// The session list reads again when the catalog watch says the workspace changed, not on a timer.
		workbench.agentsStale = function() {
			var current = open;
			var watch = current == null ? null : current.catalog;
			if (watch == null || watch.revision == consumedCatalog) return false;
			consumedCatalog = watch.revision;
			return true;
		};
	}

	public function workbenchService():WorkspaceWorkbenchClient return workbench;

	/** Connects to every saved machine. Called once at start. */
	public function connectSaved():Void {
		if (disposed || machines.length > 0) return;
		var damaged = 0;
		for (device in credentials.devices) {
			try machines.push(new PhoneMachine(events, hub, clock, device, null)) catch (_:Dynamic) damaged++;
		}
		if (credentials.unreadable) {
			// The host keeps the file it could not open (it moves it aside before saving a new pairing), so nothing is lost.
			error = "Saved pairings could not be opened. Restart the app to try again. Pairing a machine now starts a new list; the old file is kept.";
			status = "Remote access needs attention.";
		} else if (damaged > 0) {
			error = damaged == 1 ? "A saved pairing is damaged. Forget it and pair that machine again." : "Saved pairings are damaged. Forget them and pair those machines again.";
			status = "Remote access needs attention.";
		} else if (machines.length > 0)
			status = "Connecting to your machines…";
		touch();
	}

	// Pairing

	public function beginPairing(url:String):Bool {
		if (disposed) return false;
		resetPairing();
		error = null;
		var parsed = PhoneInvitation.parse(StringTools.trim(url));
		if (parsed == null) {
			fail("Enter the complete one-time pairing URL from the machine.");
			return false;
		}
		invitation = parsed;
		pairing = true;
		pairingDeadline = clock() + PAIRING_MILLISECONDS;
		try privateKey = NoiseSession.generateKeypair().privateKey catch (_:Dynamic) {
			fail("Secure randomness is unavailable; pairing cannot continue.");
			return false;
		}
		setStatus("Connecting to the relay…");
		var options:TransportOptions;
		try options = NativeRpcHub.websocketUrl(parsed.url) catch (_:Dynamic) {
			fail("The pairing URL uses an unsupported relay address.");
			return false;
		}
		var token = generation;
		try connectorAttempt = hub.connectBytes(options, function(stream, failure) {
			if (disposed || token != generation) {
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
				handshake = new NoiseClientHandshake(channel, privateKey, null, NoisePrologue.encode(parsed.machineId, parsed.deviceId), clock, onNoiseReady);
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

	function onNoiseReady(transport:NoiseMessageTransport):Void {
		secure = transport;
		var done = handshake;
		if (done == null || done.transcriptHash == null || done.remoteStaticKey == null) {
			fail("The relay handshake did not give a verifiable machine identity.");
			return;
		}
		machineKey = done.remoteStaticKey;
		var parsed = invitation, reached = hex(done.remoteStaticKey);
		if (parsed != null && !parsed.link.admits(done.remoteStaticKey)) {
			// Someone between the phone and the machine (the relay, or whoever has the link) answered with another key.
			fail("The machine that answered is not the one that made this invitation: its key does not match the invitation. "
				+ "Nothing was paired. Create a fresh invitation on the machine and try again; if it happens again, do not pair over this relay.");
			return;
		}
		machineKeyVerified = parsed != null && parsed.link.machineKey != null;
		machineKeyChanged = false;
		if (parsed != null)
			for (existing in credentials.devices)
				if (existing.machineId == parsed.machineId && existing.machineStaticPublicKey.toLowerCase() != reached)
					machineKeyChanged = true;
		authenticationCode = NoisePairingCode.fromHandshakeHash(done.transcriptHash);
		Sys.println(machineKeyVerified ? "exosuit-pairing: machine key matches the invitation" : "exosuit-pairing: the invitation has no machine key");
		Sys.println("exosuit-pairing: code " + authenticationCode);
		setStatus("Compare this code with the machine.");
	}

	/** The user compared the code with the machine's. */
	public function confirmCode():Void {
		if (authenticationCode == null || secure == null) return;
		if (!secure.isOpen()) {
			abandonPairing("The pairing connection closed before it was confirmed. Create a fresh invitation on the machine.");
			return;
		}
		codeConfirmed = true;
		Sys.println("exosuit-pairing: the user confirmed the code" + (approved != null ? ", storing the credentials" : ", waiting for the machine's approval"));
		if (approved != null) storeApproved();
		else setStatus("Code confirmed. Waiting for the machine's owner to approve.");
		touch();
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
			Sys.println("exosuit-pairing: approved by the machine" + (codeConfirmed ? "" : ", waiting for the code confirmation"));
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
		var device:SavedDevice = {machineId: parsed.machineId, deviceId: parsed.deviceId, relayOrigin: parsed.origin, staticPrivateKey: hex(key),
			deviceToken: grant.deviceToken, machineStaticPublicKey: hex(machine), name: null};
		// A machine is paired once: an older pairing of the same machine is replaced, not kept beside the new one.
		var replaced = [for (existing in credentials.devices) if (existing.machineId == device.machineId && existing.deviceId != device.deviceId) existing];
		credentials.put(device, function(ok) {
			if (disposed) return;
			if (token != generation) {
				// The pairing was cancelled or failed while the Keystore wrote: the machine never got the confirmation.
				if (ok) credentials.remove(device.machineId, device.deviceId, function(_) {});
				return;
			}
			storing = false;
			if (!ok) {
				fail("Could not store the credentials in the Android Keystore; the pairing was not completed.");
				return;
			}
			replacing = replaced;
			pendingDevice = device;
			confirmation = Bytes.ofString(Json.stringify({version: 1, type: "pairing-confirmed", deviceId: parsed.deviceId, challenge: grant.challenge}));
			approved = null;
			setStatus("Paired. Connecting to the machine…");
			tryConfirmAndConnect();
		});
	}

	function tryConfirmAndConnect():Void {
		var transport = secure, message = confirmation, device = pendingDevice;
		if (transport == null || message == null || device == null || !transport.isOpen()) return;
		if (!transport.send(message)) {
			if (!transport.isOpen()) abandonPairing("Could not confirm the approved device.");
			return;
		}
		var created:PhoneMachine;
		try created = new PhoneMachine(events, hub, clock, device, transport) catch (_:Dynamic) {
			fail("Could not prepare the machine connection.");
			return;
		}
		// The machine's connector owns the channel and the key now; the pairing state lets go of them without closing.
		secure = null;
		channel = null; // the secure transport sits on this relay channel: closing it would drop the machine's first connection
		var older = replacing;
		for (old in older) forget(old.machineId, old.deviceId);
		machines.push(created);
		resetPairing();
		setStatus("Paired. Waiting for the owner to grant workspaces.");
	}

	function resetPairing():Void {
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
		pairing = false;
	}

	function fail(message:String):Void {
		if (pairing) Sys.println("exosuit-pairing: failed: " + message);
		resetPairing();
		error = message;
		setStatus("Remote access needs attention.");
		touch();
	}

	/**
		Ends a pairing that cannot finish. Credentials already stored for it go: the machine never got the confirmation, so
		it rolls the device back, and a restart would dial a device it does not know.
	**/
	function abandonPairing(message:Null<String>):Void {
		var stored = pendingDevice;
		if (message != null) fail(message);
		else {
			resetPairing();
			error = null;
			setStatus(machines.length == 0 ? NOT_PAIRED : "");
			touch();
		}
		if (stored != null) credentials.remove(stored.machineId, stored.deviceId, function(_) {});
	}

	/** The user gave up on the pairing in progress. */
	public function cancelPairing():Void {
		if (pairing) abandonPairing(null);
	}

	// Machines and workspaces

	/** Opens a workspace of a paired machine as the attached workspace; a workspace already open is closed first. */
	public function openWorkspace(machine:PhoneMachine, workspace:String):Void {
		if (disposed || open != null && open.id == workspace && openMachine == machine) return;
		closeWorkspace();
		openMachine = machine;
		open = new PhoneWorkspace(machine.machine, workspace, clock);
		consumedCatalog = -1;
		touch();
	}

	public function openView():Null<{machine:String, workspace:String}> {
		var current = open, machine = openMachine;
		return current == null || machine == null ? null : {machine: machine.device.machineId, workspace: current.id};
	}

	public function reopen(machineId:String, workspace:String):PhoneViewSource.PhoneReopen {
		var machine:Null<PhoneMachine> = null;
		for (candidate in machines) if (candidate.device.machineId == machineId) machine = candidate;
		if (machine == null) return PhoneViewSource.PhoneReopen.Gone;
		if (machine.machine.directory == null) return PhoneViewSource.PhoneReopen.Waiting;
		var current = open;
		if (current == null) {
			if (machine.machine.workspaceById(workspace) == null) return PhoneViewSource.PhoneReopen.Gone;
			openWorkspace(machine, workspace);
			return PhoneViewSource.PhoneReopen.Waiting;
		}
		return current.id == workspace ? PhoneViewSource.PhoneReopen.Open : PhoneViewSource.PhoneReopen.Gone;   // else the user chose something else meanwhile
	}

	/** Detaches the open workspace (its stream closes); the machines stay connected. */
	public function closeWorkspace():Void {
		var current = open;
		open = null;
		openMachine = null;
		if (current != null) current.dispose();
		consumedCatalog = -1;
		workbench.poll();
		touch();
	}

	/** Forgets a paired machine on this phone (its owner still lists the device until they revoke it there). */
	public function forget(machineId:String, deviceId:String):Void {
		for (machine in machines.copy()) {
			if (machine.device.machineId != machineId || machine.device.deviceId != deviceId) continue;
			if (openMachine == machine) closeWorkspace();
			machines.remove(machine);
			machine.dispose();
		}
		credentials.remove(machineId, deviceId, function(_) {});
		touch();
	}

	public function poll():Void {
		if (disposed) return;
		workbench.poll();
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
				abandonPairing(approved == null && pendingDevice == null
					? "The pairing ended before the machine approved it: it was declined, it waited longer than 2 minutes, or the connection dropped. "
						+ "Create a fresh invitation on the machine and pair again."
					: "The pairing ended before the code was confirmed here: the machine waits 2 minutes after approving, or the connection dropped. "
						+ "Create a fresh invitation on the machine and pair again.");
			else if (confirmation == null && pendingDevice == null && approved == null) {
				var message = transport.receive();
				if (message != null) receiveApproval(message);
			}
		}
		if (pairing && !storing && clock() > pairingDeadline)
			abandonPairing("Pairing took too long. Create a fresh invitation on the machine.");
		if (confirmation != null) tryConfirmAndConnect();
		var openId = open == null ? null : open.id;
		for (machine in machines) {
			machine.poll(machine == openMachine ? openId : null);
			var directory = machine.machine.directory;
			if (directory != null) credentials.learn(machine.device.machineId, machine.device.deviceId, directory.name);
		}
		var current = open;
		if (current != null) {
			current.poll();
			// A workspace the owner took back goes away: the phone leaves it instead of retrying forever.
			var owner = openMachine;
			if (owner != null && owner.machine.directory != null && owner.machine.workspaceById(current.id) == null) closeWorkspace();
		}
		if (StringTools.startsWith(status, "Paired") || StringTools.startsWith(status, "Connecting to your machines")) {
			for (machine in machines) {
				var directory = machine.machine.directory;
				if (directory != null) {
					setStatus("");
					break;
				}
			}
		}
		var key = uiKey();
		if (key != shownKey) {
			shownKey = key;
			touch();
			report();
		}
	}

	/** What a test script may read (debug builds, AutomationProbe): the pairing state and each machine's connection. */
	public function automationState():Dynamic {
		var current = open;
		return {status: status, error: error, pairing: pairing, code: authenticationCode, machines: [for (machine in machines) {name: machine.name(), online: machine.online(), error: machine.machine.error,
				workspaces: machine.machine.directory == null ? [] : [for (entry in machine.machine.directory.workspaces) entry.name]}],
			open: current == null ? null : {id: current.id, connected: current.isConnected(), failure: current.failure}};
	}

	/** One log line per change of what the panel shows, for the acceptance run's logcat checks (the screenshots are the proof). */
	function report():Void {
		for (machine in machines) {
			var directory = machine.machine.directory;
			var listed:Array<String> = [];
			if (directory != null)
				for (entry in directory.workspaces) {
					var mirror = mirrorOf(machine, entry.workspace);
					listed.push(entry.name + ":" + entry.status + ":" + (mirror == null ? "-" : Std.string(mirror.sessionList().length)));
				}
			var line = "exosuit-machine: " + machine.name() + " " + (machine.online() ? "online" : "offline") + " [" + listed.join(",") + "]";
			if (lastReport.get(machine.device.deviceId) != line) {
				lastReport.set(machine.device.deviceId, line);
				Sys.println(line);
			}
		}
		var current = open;
		var line = current == null ? "exosuit-open: none" : "exosuit-open: " + current.id + " " + (current.isConnected() ? "connected" : "connecting") + " " + current.root;
		if (lastReport.get("open") != line) {
			lastReport.set("open", line);
			Sys.println(line);
		}
	}

	/** Everything the Remote panel shows that the objects change on their own, in one string: it differs exactly when the panel must be rebuilt. */
	function uiKey():String {
		var buffer = new StringBuf();
		for (machine in machines) {
			buffer.add(machine.machine.revision);
			buffer.add(":");
			buffer.add(machine.pool.revision());
			buffer.add(":");
			buffer.add(machine.machine.connected() ? 1 : 0);
			buffer.add(";");
		}
		var current = open;
		if (current != null) {
			var watch = current.catalog;
			buffer.add(current.isConnected() ? 1 : 0);
			buffer.add(watch == null ? -1 : watch.revision);
			buffer.add(current.failure);
		}
		return buffer.toString();
	}

	function touch():Void {
		revision++;
		changed();
	}

	function setStatus(value:String):Void {
		if (status == value) return;
		status = value;
		touch();
	}

	/** The open workspace's catalog, or the pool's copy for the others (null until read). */
	public function mirrorOf(machine:PhoneMachine, workspace:String):Null<WorkspaceCatalogMirror> {
		if (machine == openMachine && open != null && open.id == workspace) {
			var watch = open.catalog;
			if (watch != null && watch.mirror.token != null) return watch.mirror;
		}
		return machine.mirrorOf(workspace);
	}

	public function disconnect():Void {
		resetPairing();
		closeWorkspace();
		error = null;
		setStatus("Disconnected.");
	}

	// WorkspaceAttachment and WorkspaceRpcEndpoint: the open workspace

	public function select(root:Null<String>):Void {}

	public function statusLabel():String return open == null ? "" : open.connecting() ? "Connecting…" : open.isConnected() ? "Connected" : "";

	public function failure():Null<String> return error != null ? error : open == null ? null : open.failure;

	public function fileWorkspace():String return "workspace";

	public function rootPath():Null<String> return open == null ? null : open.root;

	public function serviceGeneration():String return open == null ? "" : open.serviceInstance;

	public function terminalEvents():Null<WorkspaceTerminalEvents> {
		var current = open;
		var connection = rpcConnection();
		if (current == null || connection == null) {
			if (current != null) current.terminalRouter = null;
			return null;
		}
		var router = current.terminalRouter;
		if (router == null || router.connection != connection) {
			router = new WorkspaceTerminalEvents(connection);
			current.terminalRouter = router;
		}
		return router;
	}

	public function rpcConnection():Null<RpcConnection> {
		var current = open;
		return current == null || !current.isConnected() ? null : current.connection;
	}

	public function failureReason():Null<String> {
		if (error != null) return error;
		var current = open;
		if (current == null) return "No workspace is open";
		return current.failure != null ? current.failure : current.root == null ? "Workspace disconnected" : null;
	}

	public function supportsWorkspaceGroups():Bool return hasCapability(WorkspaceProtocol.TREE);

	public function workspaceEpoch():Null<String> return null;

	public function hasCapability(capability:String):Bool return open != null && open.grants.indexOf(capability) >= 0;

	public function fileScope():Null<String> return rootPath();

	public function hasLocalFileAccess():Bool return false;

	public function isConnected():Bool return open != null && open.isConnected();

	public function fileClient():Null<WorkspaceFileClient> {
		var current = open;
		if (current == null) return null;
		var connection = current.isConnected() && hasCapability(WorkspaceFileProtocol.READ) ? current.connection : null;
		if (connection == null) {
			current.fileApiConnection = null;
			current.fileApiClient = null;
			return null;
		}
		if (connection != current.fileApiConnection) {
			current.fileApiConnection = connection;
			current.fileApiClient = new WorkspaceFileClient(connection);
		}
		return current.fileApiClient;
	}

	public function sourceControlSource():Null<ScmSource> return null;

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		resetPairing();
		closeWorkspace();
		for (machine in machines) machine.dispose();
		machines = [];
		workbench.dispose();
		hub.dispose();
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
