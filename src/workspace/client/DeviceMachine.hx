package workspace.client;

import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcError;
import haxeon.rpc.RpcPeerOptions;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineDirectoryProtocol.MachineWorkspaceEntry;
import workspace.service.MachineDirectoryProtocol.WorkspaceStream;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.transport.StreamMultiplexer;

private class Finished implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

/** Lets an attempt that is waiting for the machine give up quietly. */
private class WaitingAttempt implements RpcConnectAttempt {
	public var cancelled(default, null) = false;

	public function new() {}

	public function cancel():Void cancelled = true;
}

/** Stream 0 of the machine's channel: each time the client connects, the channel is dialled again and a new multiplexer replaces the old. */
private class MachineStreamConnector implements RpcConnector {
	final owner:DeviceMachine;
	final channel:RpcConnector;

	public function new(owner:DeviceMachine, channel:RpcConnector) {
		this.owner = owner;
		this.channel = channel;
	}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt
		return channel.connect(function(result) {
			switch result {
				case Opened(transport):
					var stream = owner.adopt(transport);
					if (stream == null) {
						transport.close();
						complete(Failed({code: "disconnected", message: "disconnected", ambiguous: false}, true));
					} else
						complete(Opened(stream));
				case Failed(error, retryable):
					complete(Failed(error, retryable));
			}
		});
}

/**
	A workspace's stream: connecting asks the machine to OPEN it, so every reconnect of the workspace's client opens a
	fresh stream. A reconnect never starts the service (`start` false): one that stopped stays stopped, and the link
	decides whether to ask again (WorkspaceLink's `revive`). `first`, when given, is a stream already opened, which the
	first connect takes.
**/
private class WorkspaceStreamConnector implements RpcConnector {
	final owner:DeviceMachine;
	final workspace:String;
	var first:Null<MessageTransport>;

	public function new(owner:DeviceMachine, workspace:String, ?first:MessageTransport) {
		this.owner = owner;
		this.workspace = workspace;
		this.first = first;
	}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		var ready = first;
		first = null;
		if (ready != null && ready.isOpen()) {
			complete(Opened(ready));
			return new Finished();
		}
		var attempt = new WaitingAttempt();
		var machine = owner.machineId;
		if (machine == null) {
			complete(Failed({code: "disconnected", message: "The machine has not answered yet", ambiguous: false}, true));
			return attempt;
		}
		owner.openStream({machine: machine, workspace: workspace}, false, function(stream, _, error) {
			if (attempt.cancelled) {
				if (stream != null)
					stream.close();
				return;
			}
			if (stream != null)
				complete(Opened(stream));
			else {
				var failure = error == null ? {code: "disconnected", message: "disconnected", ambiguous: false} : error;
				// A refusal about the workspace (not granted, not available, too many streams) may change; the client backs off and asks again.
				complete(Failed(failure, failure.code != "invalid_request" && failure.code != "machine_mismatch"));
			}
		});
		return attempt;
	}
}

/**
	A paired machine as the device sees it (ADR 0005 section 4): the directory of the workspaces granted to this device,
	and a way to open a stream to each. It dials the machine's channel through `channel` (a connector whose transport is
	already Noise-authenticated, such as `DeviceRpcConnector`), runs the machine protocol on stream 0 under an RpcClient
	(so it reconnects with backoff), reads DIRECTORY when connected and whenever CHANGED arrives (grants, names, a
	service starting or stopping), and again every REFRESH_MS, which also finds a relay session that died unnoticed.

	`openService(id, start)` makes the device's ServiceOpener for WorkspaceLink: it opens a stream to the workspace and
	names the service exohost forwarded it to; its connector issues OPEN again on every reconnect, never starting the service. A reconnect of the channel ends
	every stream, so the links above reconnect through OPEN again; nothing replays.
**/
class DeviceMachine {
	public static inline final REFRESH_MS = 15000.0;
	static inline final CALL_TIMEOUT = 8000;
	/** OPEN starts an idle workspace's service, which exohost gives ExohostServices.START_SECONDS (30 s); the answer gets more. */
	public static inline final OPEN_TIMEOUT = 40000;

	/** The id the device pairs under: the machine's relay id (32 hex digits), which the directory names in `relay`. */
	public final relayId:String;
	/** The machine's own id, as its directory names it; pinned by the first directory (see `answersFor`). */
	public var machineId(default, null):Null<String>;
	/** The last directory the machine sent, or null before the first. Stays after a disconnect. */
	public var directory(default, null):Null<MachineDirectory>;
	/** Why the last directory read or the connection failed; null after a read succeeds. */
	public var error(default, null):Null<String>;
	/** Changes whenever `directory`, `error` or `connected` does. */
	public var revision(default, null):Int = 0;
	/** The terminal error code when the machine refused this device for good (revoked, bad identity); null otherwise. */
	public var refusal(default, null):Null<String>;

	final client:RpcClient;
	final channel:RpcConnector;
	final pump:Null<Void->Void>;
	final clock:Void->Float;
	var mux:Null<StreamMultiplexer>;
	var machineConnection:Null<RpcConnection>;
	var reading = false;
	var dirty = false;
	var refreshAt:Float = 0;
	var disposed = false;

	public function new(channel:RpcConnector, relayId:String, clock:Void->Float, random:Void->Float, ?pump:Void->Void) {
		this.relayId = relayId;
		this.channel = channel;
		this.clock = clock;
		this.pump = pump;
		var capabilities = [MachineDirectoryProtocol.CAPABILITY];
		client = new RpcClient(new MachineStreamConnector(this, channel), clock, random,
			new RpcPeerOptions("exosuit-editor/1", capabilities, capabilities, 5000, 262144, 16, 1048576),
			function(connection, _, _) established(connection));
	}

	/** The network came back or changed: dial now instead of waiting out the backoff (see RpcClient.retryNow). */
	public function retryNow(redial:Bool):Void {
		if (!disposed)
			client.retryNow(redial);
	}

	public function connected():Bool
		return machineConnection != null && client.current() == machineConnection;

	/** Workspaces this device may open, in the machine's order. Empty before the first directory. */
	public function workspaces():Array<MachineWorkspaceEntry>
		return directory == null ? [] : directory.workspaces;

	public function workspaceById(id:String):Null<MachineWorkspaceEntry> {
		for (entry in workspaces())
			if (entry.workspace == id)
				return entry;
		return null;
	}

	/**
		A ServiceOpener (WorkspaceLink) for the workspaces of this machine: opens a stream to workspace `id` (exohost starts
		its service when idle and `start` is true, else answers `workspace_unavailable`) and gives the service's
		generation and root with a connector whose first connect takes that stream.
	**/
	public function openService(id:String, start:Bool, done:(Null<OpenedService>, Null<String>) -> Void):Void {
		var machine = machineId;
		if (machine == null) {
			done(null, "The machine has not answered yet");
			return;
		}
		openStream({machine: machine, workspace: id}, start, function(stream, opened, error) {
			if (stream == null || opened == null) {
				done(null, error == null ? "The machine is not connected" : describe(error.code));
				return;
			}
			var generation = opened.generation, root = opened.root;
			if (generation == null || root == null) {
				stream.close();
				done(null, "The machine is too old to open workspaces here; update Exosuit on it");
				return;
			}
			done({endpoint: "", generation: generation, root: root, connector: new WorkspaceStreamConnector(this, id, stream)}, null);
		});
	}

	static function describe(code:String):String
		return switch code {
			case "unknown_workspace": "This device may not open that workspace";
			case "workspace_unavailable": "The workspace's service is not running";
			case "too_many_streams": "Too many workspaces are open on this device";
			case "disconnected": "The machine is not connected";
			case other: "The machine refused the workspace (" + other + ")";
		}

	/** Takes the channel a connect produced as the current one (closing the previous), and returns its machine stream. */
	public function adopt(transport:MessageTransport):Null<haxeon.rpc.MessageTransport> {
		if (disposed || !transport.isOpen())
			return null;
		var old = mux;
		if (old != null)
			old.close();
		var next = new StreamMultiplexer(transport);
		mux = next;
		return next.machineStream();
	}

	function established(connection:RpcConnection):Void {
		machineConnection = connection;
		refusal = null;
		connection.onNotification(MachineDirectoryProtocol.CHANGED, MachineDirectoryProtocol.decodeChange, function(change) {
			if (machineConnection != connection)
				return;
			if (directory == null || change.revision != directory.revision)
				read(connection);
		});
		revision++;
		read(connection);
	}

	function read(connection:RpcConnection):Void {
		if (reading) {
			dirty = true;
			return;
		}
		reading = true;
		dirty = false;
		connection.call(MachineDirectoryProtocol.DIRECTORY, {machine: machineId}, CALL_TIMEOUT, function(value) {
			if (machineConnection != connection)
				return;
			reading = false;
			refreshAt = clock() + REFRESH_MS;
			// The first answer names the machine; it must be the one this device paired with, and every later answer the same one.
			if (!answersFor(value, relayId, machineId)) {
				error = "The machine answered for another machine id";
				revision++;
				connection.close("machine_identity_conflict");
				return;
			}
			machineId = value.machine;
			error = null;
			if (!sameDirectory(directory, value)) {
				directory = value;
				revision++;
			}
			if (dirty)
				read(connection);
		}, function(failure) {
			if (machineConnection != connection)
				return;
			reading = false;
			refreshAt = clock() + REFRESH_MS;
			error = failure.code;
			revision++;
			// The relay keeps a device's socket when the machine behind it goes away and comes back (the desktop restarting), and nothing
			// tells the device: the old Noise session is dead and every request times out. Closing the connection makes the client dial
			// again, with a fresh handshake the new machine process accepts.
			if (failure.code == "timeout")
				connection.close("directory_timeout");
		});
	}

	/**
		Whether a directory comes from the machine this device paired with under `relayId`. A machine that names its relay
		id (`relay`) must name this one, and its own id is then free (exohost gives each relay its own id). An older machine
		names none: its id must then be the relay id, or `machine-` and the relay id. Once `pinned` (the first accepted
		answer's id), every later answer must keep it.
	**/
	public static function answersFor(value:Null<MachineDirectory>, relayId:String, pinned:Null<String>):Bool {
		if (value == null || value.machine == null || value.machine.length == 0 || value.machine.length > WorkspaceCatalogProtocol.ID_LIMIT)
			return false;
		var relay = value.relay;
		if (relay != null && relay != relayId)
			return false;
		if (pinned != null)
			return value.machine == pinned;
		return relay != null || value.machine == relayId || value.machine == "machine-" + relayId;
	}

	static function sameDirectory(left:Null<MachineDirectory>, right:MachineDirectory):Bool {
		if (left == null || left.revision != right.revision || left.name != right.name || left.workspaces.length != right.workspaces.length)
			return false;
		for (index in 0...left.workspaces.length) {
			var a = left.workspaces[index], b = right.workspaces[index];
			if (a.workspace != b.workspace || a.name != b.name || a.status != b.status || a.grants.join(",") != b.grants.join(","))
				return false;
		}
		return true;
	}

	/**
		Asks the machine to open a stream to a granted workspace (starting its service when idle, if `start`) and registers
		it on the current channel. `done` gets the transport, or the error (`disconnected` when the machine is not
		connected right now).
	**/
	public function openStream(ref:WorkspaceRef, start:Bool, done:(Null<MessageTransport>, Null<WorkspaceStream>, Null<RpcError>) -> Void):Void {
		var connection = machineConnection, link = mux;
		if (disposed || connection == null || link == null || !connected() || !link.isOpen()) {
			done(null, null, {code: "disconnected", message: "The machine is not connected", ambiguous: false});
			return;
		}
		connection.call(MachineDirectoryProtocol.OPEN, {ref: ref, start: start}, OPEN_TIMEOUT, function(opened:WorkspaceStream) {
			if (machineConnection != connection || mux != link) {
				// The channel changed while the machine was answering: the stream died with it. Tell the machine anyway.
				done(null, null, {code: "disconnected", message: "The machine connection changed", ambiguous: false});
				return;
			}
			var stream = link.open(opened.stream);
			if (stream == null || !sameRef(opened.ref, ref)) {
				done(null, null, {code: "invalid_response", message: "The machine opened an unusable stream", ambiguous: false});
				if (stream != null)
					stream.close();
				else
					closeOnMachine(connection, opened.stream);
				return;
			}
			// Directory entries go stale once grants change; the machine closes the stream then, and the client reconnects.
			done(stream, opened, null);
		}, function(failure) {
			done(null, null, failure);
		});
	}

	function closeOnMachine(connection:RpcConnection, stream:Int):Void
		connection.call(MachineDirectoryProtocol.CLOSE, {stream: stream}, CALL_TIMEOUT, function(_) {}, function(_) {});

	static function sameRef(left:WorkspaceRef, right:WorkspaceRef):Bool
		return left.machine == right.machine && left.workspace == right.workspace;

	/** Moves the channel, the machine client and its refresh along; call every frame. */
	public function poll():Void {
		if (disposed)
			return;
		if (pump != null)
			pump();
		var channel = mux;
		if (channel != null)
			channel.poll();
		client.poll();
		if (client.state == Closed && refusal == null) {
			var last = client.lastError;
			refusal = last == null ? "closed" : last.code;
			error = refusal;
			revision++;
			return;
		}
		var connection = machineConnection;
		if (connection != null && client.current() != connection) {
			machineConnection = null;
			reading = false;
			revision++;
		} else if (connection != null && !reading && clock() >= refreshAt)
			read(connection);
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		client.close();
		var channel = mux;
		mux = null;
		if (channel != null)
			channel.close();
		machineConnection = null;
	}
}
