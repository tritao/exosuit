package workspace.client;

import haxeon.platform.event.EventPump;
import haxeon.rpc.RpcConnection;
import scm.ScmSource;
import workspace.service.WorkspaceProtocol;
import workspace.transport.NativeRpcHub;

/**
	A device's attachment to the machines it is paired with (the phone's and the browser's), over the relay, using the shared desktop clients (ADR 0005
	section 4, M19 Phase 9):

	- pairing (the shared `DevicePairing`): a one-time invitation from the machine (suit), Noise XX, the code the user compares with the machine,
	  approval (which grants only the machine directory), then the credentials go to the device's store
	  (`PairedMachines`: the phone's Keystore file, the browser's encrypted storage). Pairing a machine does not touch the machines already connected;
	- each paired machine is a `RemoteMachine`: one relay channel, the directory of the workspaces the owner granted this
	  device (it follows grants without pairing again) and a `WorkspaceLink` to each workspace in use, as the desktop
	  editor holds them;
	- the open workspace is its machine's kept link. This class presents it to ExosuitApp as the attachment (files,
	  terminals) and as the Workbench's client (the link itself); with none open, the attachment is empty and the
	  Remote panel lists machines and their workspaces.
**/
class RemoteMachines implements WorkspaceAttachment implements WorkspaceRpcEndpoint implements RemoteViewSource {
	static inline final NOT_PAIRED = "Paste the one-time pairing URL from the machine's Remote Access panel to pair this device.";
	/** What the Remote panel says: the pairing's progress while one runs, else the connection's. */
	public var status(get, never):String;
	public var error(default, null):Null<String>;
	/** The pairing in progress: the code to compare, and what the panel says of the machine's key. */
	public final pairingFlow:DevicePairing;
	public var authenticationCode(get, never):Null<String>;
	public var codeConfirmed(get, never):Bool;
	public var machineKeyChanged(get, never):Bool;
	public var machineKeyVerified(get, never):Bool;
	/** True while a pairing is in progress (connecting, comparing the code, waiting for approval). */
	public var pairing(get, never):Bool;
	public var revision(default, null):Int = 0;
	public final credentials:DevicePairing.PairedMachines;
	/** The paired machines, in the order they were paired. */
	public var machines(default, null):Array<RemoteMachine> = [];
	/** The id of the workspace the phone has open, if any, and its machine. */
	public var openId(default, null):Null<String>;
	public var openMachine(default, null):Null<RemoteMachine>;
	/** The open workspace's link, once its machine has made it. */
	public var open(default, null):Null<WorkspaceLink>;

	final events:EventPump;
	final clock:Void->Float;
	final changed:Void->Void;
	final hub:NativeRpcHub;
	/** The Workbench's client while no workspace is open: a link that never connects. */
	final none:WorkspaceLink;
	var ownStatus:String = NOT_PAIRED;
	var shownPairing = -1;
	var shownKey = "";
	final lastReport:Map<String, String> = [];
	var disposed = false;
	var lastRedial:Float = -1e12;

	public function new(events:EventPump, clock:Void->Float, credentials:DevicePairing.PairedMachines, changed:Void->Void) {
		this.events = events;
		this.clock = clock;
		this.credentials = credentials;
		this.changed = changed;
		hub = new NativeRpcHub(events);
		pairingFlow = new DevicePairing(hub, clock, credentials);
		pairingFlow.failed = function(message) {
			error = message;
			setStatus("Remote access needs attention.");
			touch();
		};
		pairingFlow.paired = paired;
		none = new WorkspaceLink(events, clock, function(_, done) done(null, "No workspace is open"), null);
	}

	/** The open workspace's link, which reads its lists; `none` while no workspace is open. */
	public function workbenchService():WorkspaceWorkbenchClient { var link = open; return link == null ? none : link; }

	/** Connects to every saved machine. Called once at start. */
	/** `unreadable`: the device has saved pairings it could not open (nothing is lost; they are not in the store). */
	public function connectSaved(unreadable:Bool = false):Void {
		if (disposed || machines.length > 0) return;
		var damaged = 0;
		for (device in credentials.paired()) {
			try machines.push(new RemoteMachine(events, hub, clock, device, null)) catch (_:Dynamic) damaged++;
		}
		if (unreadable) {
			// The host keeps the file it could not open (it moves it aside before saving a new pairing), so nothing is lost.
			error = "Saved pairings could not be opened. Restart the app to try again. Pairing a machine now starts a new list; the old file is kept.";
			ownStatus = "Remote access needs attention.";
		} else if (damaged > 0) {
			error = damaged == 1 ? "A saved pairing is damaged. Forget it and pair that machine again." : "Saved pairings are damaged. Forget them and pair those machines again.";
			ownStatus = "Remote access needs attention.";
		} else if (machines.length > 0)
			ownStatus = "Connecting to your machines…";
		touch();
	}

	// Pairing

	/**
		The host saw the network change (`changed`) or the app return to the foreground after a while (not `changed`): every
		machine and the open workspace that is waiting out a backoff dials now. On a real change the live connections are
		dropped and dialed again, since their sockets belong to the old network; a healthy connection is otherwise left alone.
		Callbacks arrive in bursts, so a redial within 2 s of the last one is ignored.
	**/
	public function networkChanged(changed:Bool):Void {
		if (disposed) return;
		var now = clock();
		if (changed) {
			if (now - lastRedial < 2000) changed = false;
			else lastRedial = now;
		}
		for (machine in machines) machine.retryNow(changed);
		touch();
	}

	public function beginPairing(url:String):Bool {
		if (disposed) return false;
		error = null;
		var started = pairingFlow.begin(url);
		touch();
		return started;
	}

	/** The user compared the code with the machine's. */
	public function confirmCode():Void {
		pairingFlow.confirmCode();
		touch();
	}

	/** The user gave up on the pairing in progress. */
	public function cancelPairing():Void {
		if (!pairingFlow.active) return;
		pairingFlow.cancel();
		error = null;
		setStatus(machines.length == 0 ? NOT_PAIRED : "");
		touch();
	}

	/** A pairing finished: its machine connects over the channel the pairing used, and older pairings of that machine go. */
	function paired(device:PairedMachine, transport:haxeon.rpc.MessageTransport, older:Array<PairedMachine>):Void {
		var created:RemoteMachine;
		try created = new RemoteMachine(events, hub, clock, device, transport) catch (_:Dynamic) {
			transport.close();
			error = "Could not prepare the machine connection.";
			setStatus("Remote access needs attention.");
			return;
		}
		for (old in older) forget(old.machineId, old.deviceId);
		machines.push(created);
		setStatus("Paired. Waiting for the owner to grant workspaces.");
	}

	function get_status():String return pairingFlow.active ? pairingFlow.status : ownStatus;
	function get_authenticationCode():Null<String> return pairingFlow.authenticationCode;
	function get_codeConfirmed():Bool return pairingFlow.codeConfirmed;
	function get_machineKeyChanged():Bool return pairingFlow.machineKeyChanged;
	function get_machineKeyVerified():Bool return pairingFlow.machineKeyVerified;
	function get_pairing():Bool return pairingFlow.active;

	// Machines and workspaces

	/** Opens a workspace of a paired machine as the attached workspace; a workspace already open is closed first. */
	public function openWorkspace(machine:RemoteMachine, workspace:String):Void {
		if (disposed || openId == workspace && openMachine == machine) return;
		closeWorkspace();
		openMachine = machine;
		openId = workspace;
		open = machine.poll(workspace, []);
		touch();
	}

	public function openView():Null<{machine:String, workspace:String}> {
		var current = openId, machine = openMachine;
		return current == null || machine == null ? null : {machine: machine.device.machineId, workspace: current};
	}

	public function reopen(machineId:String, workspace:String):RemoteReopen {
		var machine:Null<RemoteMachine> = null;
		for (candidate in machines) if (candidate.device.machineId == machineId) machine = candidate;
		if (machine == null) return RemoteReopen.Gone;
		if (machine.machine.directory == null) return RemoteReopen.Waiting;
		var current = openId;
		if (current == null) {
			if (machine.machine.workspaceById(workspace) == null) return RemoteReopen.Gone;
			openWorkspace(machine, workspace);
			return RemoteReopen.Waiting;
		}
		return current == workspace ? RemoteReopen.Open : RemoteReopen.Gone;   // else the user chose something else meanwhile
	}

	/** Detaches the open workspace; its link is no longer kept, so it closes unless its rows still use it. The machines stay connected. */
	public function closeWorkspace():Void {
		open = null;
		openId = null;
		openMachine = null;
		touch();
	}

	/** Forgets a paired machine on this device (its owner still lists the device until they revoke it there). */
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

	/** The attachment's poll (ExosuitApp's): the host moves everything along through `pollMachines`, once a frame. */
	public function poll():Void {}

	/** Moves pairing and the machines along; `expanded` are the workspaces whose rows the Workbench tree shows expanded. */
	public function pollMachines(expanded:Array<String>):Void {
		if (disposed) return;
		pairingFlow.poll();
		if (pairingFlow.revision != shownPairing) {
			shownPairing = pairingFlow.revision;
			touch();
		}
		for (machine in machines) {
			var opened = machine.poll(machine == openMachine ? openId : null, expanded);
			if (machine == openMachine) open = opened;
			var directory = machine.machine.directory;
			if (directory != null) credentials.learn(machine.device.machineId, machine.device.deviceId, directory.name);
		}
		// A workspace the owner took back goes away: the phone leaves it instead of retrying forever.
		var owner = openMachine, current = openId;
		if (owner != null && current != null && owner.machine.directory != null && owner.machine.workspaceById(current) == null) closeWorkspace();
		if (StringTools.startsWith(ownStatus, "Paired") || StringTools.startsWith(ownStatus, "Connecting to your machines")) {
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
			if (DevicePairing.testRun) report();
		}
	}

	/** What a test script may read (debug builds, PhoneSnapshotFile): the pairing state and each machine's connection. */
	public function automationState():Dynamic {
		var current = open;
		return {status: status, error: error, pairing: pairing, code: authenticationCode, machines: [for (machine in machines) {name: machine.name(), online: machine.online(), error: machine.machine.error,
				workspaces: machine.machine.directory == null ? [] : [for (entry in machine.machine.directory.workspaces) entry.name]}],
			open: openId == null ? null : {id: openId, connected: current != null && current.ready, failure: current == null ? null : current.failure()}};
	}

	/** One log line per change of what the panel shows, for the acceptance run's logcat checks (the screenshots are the proof); test runs only. */
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
				DevicePairing.testLog(line);
			}
		}
		var current = open;
		var line = openId == null ? "exosuit-open: none"
			: "exosuit-open: " + openId + " " + (current != null && current.ready ? "connected" : "connecting") + " " + (current == null ? null : current.rootPath());
		if (lastReport.get("open") != line) {
			lastReport.set("open", line);
			DevicePairing.testLog(line);
		}
	}

	/** Everything the Remote panel shows that the objects change on their own, in one string: it differs exactly when the panel must be rebuilt. */
	function uiKey():String {
		var buffer = new StringBuf();
		for (machine in machines) {
			buffer.add(machine.machine.revision);
			buffer.add(":");
			buffer.add(machine.linksRevision());
			buffer.add(":");
			buffer.add(machine.machine.connected() ? 1 : 0);
			buffer.add(";");
		}
		buffer.add(openId);
		var current = open;
		if (current != null) {
			buffer.add(current.ready ? 1 : 0);
			buffer.add(current.catalogRevision());
			buffer.add(current.failure());
		}
		return buffer.toString();
	}

	function touch():Void {
		revision++;
		changed();
	}

	function setStatus(value:String):Void {
		if (ownStatus == value) return;
		ownStatus = value;
		touch();
	}

	/** A workspace's catalog as its link last read it (null until read). */
	public function mirrorOf(machine:RemoteMachine, workspace:String):Null<WorkspaceCatalogMirror>
		return machine.mirrorOf(workspace);

	// WorkspaceAttachment and WorkspaceRpcEndpoint: the open workspace

	public function statusLabel():String { var link = open; return link == null ? "" : link.connecting() ? "Connecting…" : link.ready ? "Connected" : ""; }

	public function failure():Null<String> { var link = open; return error != null ? error : link == null ? null : link.failure(); }

	public function fileWorkspace():String return "workspace";

	public function rootPath():Null<String> { var link = open; return link == null ? null : link.rootPath(); }

	public function serviceGeneration():String { var link = open; return link == null ? "" : link.serviceGeneration(); }

	public function terminalEvents():Null<WorkspaceTerminalEvents> { var link = open; return link == null ? null : link.terminalEvents(); }

	public function rpcConnection():Null<RpcConnection> { var link = open; return link == null ? null : link.rpcConnection(); }

	public function failureReason():Null<String> {
		if (error != null) return error;
		var current = open;
		if (current == null) return openId == null ? "No workspace is open" : "Workspace disconnected";
		return current.failureReason() != null ? current.failureReason() : current.rootPath() == null ? "Workspace disconnected" : null;
	}

	public function supportsWorkspaceGroups():Bool return hasCapability(WorkspaceProtocol.TREE);

	public function workspaceEpoch():Null<String> return null;

	/** What the open workspace's connection was granted; false while it is not connected. */
	public function hasCapability(capability:String):Bool { var link = open; return link != null && link.ready && link.hasCapability(capability); }

	public function fileScope():Null<String> return rootPath();

	public function hasLocalFileAccess():Bool return false;

	public function isConnected():Bool { var link = open; return link != null && link.ready; }

	public function fileClient():Null<WorkspaceFileClient> { var link = open; return link == null ? null : link.fileClient(); }

	public function sourceControlSource():Null<ScmSource> return null;

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		pairingFlow.reset();
		closeWorkspace();
		for (machine in machines) machine.dispose();
		machines = [];
		none.dispose();
		hub.dispose();
	}
}
