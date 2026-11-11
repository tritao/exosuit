package suit.remote;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineDirectoryProtocol.MachineStreamFrame;
import workspace.service.MachineGrants;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;

/** What a device session asks of the machine it serves; MachineRemote implements it, tests fake it. */
interface MachineSessionHost {
	function machineId():String;
	/** The workspaces granted to `deviceId`, with their status. */
	function directory(deviceId:String):MachineDirectory;
	/** The device's capabilities in `workspace`, or null when not granted. */
	function grantsFor(deviceId:String, workspace:String):Null<Array<String>>;
	/** Changes whenever the view of any device may have changed. */
	function revision():Int;
	/**
		A connection to `workspace`'s service with the device's stream intro already sent, starting the service when it is
		idle. `done` gets the connection, or an error code (`unknown_workspace`, `workspace_unavailable`).
	**/
	function openService(deviceId:String, workspace:String, grants:Array<String>, done:Null<MessageTransport>->Null<String>->Void):Void;
}

/** Stream 0 of a device's channel as a message transport, for the RPC connection with suit itself. */
private class MachineStreamTransport implements MessageTransport {
	final session:MachineDeviceSession;
	final inbox:Array<Bytes> = [];
	var closed:Bool = false;

	public function new(session:MachineDeviceSession) {
		this.session = session;
	}

	public function deliver(payload:Bytes):Void
		inbox.push(payload);

	public function isOpen():Bool
		return !closed && session.channelOpen();

	public function send(message:Bytes):Bool
		return isOpen() && message.length <= MachineStreamFrame.MAX_PAYLOAD
			&& session.sendFrame(MachineStreamFrame.encode(MachineStreamFrame.DATA, MachineStreamFrame.MACHINE_STREAM, message));

	public function receive():Null<Bytes>
		return inbox.length > 0 ? inbox.shift() : null;

	public function close():Void
		closed = true;
}

private typedef ServiceStream = {
	var id:Int;
	var workspace:String;
	var grants:Array<String>;
	var pipe:MessageTransport;
}

/**
	A paired device's authenticated channel (ADR 0005 section 4). Stream frames run on it (`MachineStreamFrame`): stream 0
	is the machine directory, an RPC connection with this process, and OPEN adds a stream that suit forwards, frame
	for frame and unread, to a workspace service's local pipe. The service enforces the device's grants per request;
	suit decides only which workspaces open. A grant that changes or goes closes that workspace's streams.
**/
class MachineDeviceSession {
	static inline final OUTBOX_LIMIT = 256;
	static inline final FRAMES_PER_POLL = 64;
	/**
		Streams one device may hold in one workspace, open or opening. Each is a connection to the workspace's service, and
		the service has a bounded pool of them for all devices.
	**/
	public static inline final STREAMS_PER_WORKSPACE = 6;

	public final deviceId:String;
	final secure:MessageTransport;
	final host:MachineSessionHost;
	final clock:Void->Float;
	final machineStream:MachineStreamTransport;
	final streams:Map<Int, ServiceStream> = [];
	final opening:Array<Int> = [];
	/** The workspace of each OPEN still in progress (one entry per OPEN). */
	final openingIn:Array<String> = [];
	final outbox:Array<Bytes> = [];
	var handshake:Null<RpcHandshake>;
	var connection:Null<RpcConnection>;
	var nextStream:Int = 1;
	var shownRevision:Int;
	var closed:Bool = false;

	public function new(deviceId:String, secure:MessageTransport, host:MachineSessionHost, clock:Void->Float) {
		this.deviceId = deviceId;
		this.secure = secure;
		this.host = host;
		this.clock = clock;
		machineStream = new MachineStreamTransport(this);
		var options = new RpcPeerOptions(MachineDirectoryProtocol.APPLICATION, [MachineDirectoryProtocol.CAPABILITY], [], 30000,
			MachineStreamFrame.MAX_PAYLOAD, 16, 4 * MachineStreamFrame.MAX_PAYLOAD);
		handshake = RpcHandshake.server(machineStream, clock, options);
		shownRevision = host.revision();
	}

	public function isOpen():Bool
		return !closed && secure.isOpen();

	public function channelOpen():Bool
		return !closed && secure.isOpen();

	/** The number of service streams open now. */
	public function streamCount():Int {
		var count = 0;
		for (_ in streams)
			count++;
		return count;
	}

	/** The streams to `workspace`, open or opening. */
	function streamsIn(workspace:String):Int {
		var count = 0;
		for (stream in streams)
			if (stream.workspace == workspace)
				count++;
		for (opened in openingIn)
			if (opened == workspace)
				count++;
		return count;
	}

	/** Queues a frame for the device; closes the session when the device is not reading. */
	public function sendFrame(frame:Bytes):Bool {
		if (outbox.length == 0 && secure.send(frame))
			return true;
		if (outbox.length >= OUTBOX_LIMIT) {
			close();
			return false;
		}
		outbox.push(frame);
		return true;
	}

	function flush():Void {
		while (outbox.length > 0 && secure.send(outbox[0]))
			outbox.shift();
	}

	public function poll():Void {
		if (closed)
			return;
		if (!secure.isOpen()) {
			close();
			return;
		}
		flush();
		for (_ in 0...FRAMES_PER_POLL) {
			var frame = secure.receive();
			if (frame == null)
				break;
			if (!dispatch(frame)) {
				close();
				return;
			}
		}
		var pending = handshake;
		if (pending != null) {
			pending.poll();
			if (pending.isFinished()) {
				handshake = null;
				connection = pending.connection;
				if (connection == null) {
					close();
					return;
				}
				register(connection);
			}
		}
		var current = connection;
		if (current != null) {
			current.poll(32, MachineStreamFrame.MAX_PAYLOAD * 4);
			if (!current.isOpen()) {
				close();
				return;
			}
		}
		pumpStreams();
		checkGrants();
		var revision = host.revision();
		if (revision != shownRevision && current != null) {
			shownRevision = revision;
			current.notify(MachineDirectoryProtocol.CHANGED, {revision: revision}, MachineDirectoryProtocol.encodeChange);
		}
	}

	function dispatch(frame:Bytes):Bool {
		var kind = MachineStreamFrame.kind(frame);
		if (kind < 0)
			return false;
		var id = MachineStreamFrame.stream(frame);
		if (id == MachineStreamFrame.MACHINE_STREAM) {
			// The machine stream cannot be closed by a frame; the channel ends it.
			if (kind == MachineStreamFrame.DATA)
				machineStream.deliver(MachineStreamFrame.payload(frame));
			return true;
		}
		var stream = streams.get(id);
		if (stream == null) {
			if (kind == MachineStreamFrame.DATA && opening.indexOf(id) < 0)
				sendFrame(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, id, null));
			return true;
		}
		if (kind == MachineStreamFrame.CLOSE)
			closeStream(id, false);
		else if (!stream.pipe.send(MachineStreamFrame.payload(frame)))
			closeStream(id, true);
		return true;
	}

	function pumpStreams():Void {
		for (id in [for (key in streams.keys()) key]) {
			var stream = streams.get(id);
			if (stream == null)
				continue;
			for (_ in 0...FRAMES_PER_POLL) {
				var message = stream.pipe.receive();
				if (message == null)
					break;
				if (message.length > MachineStreamFrame.MAX_PAYLOAD) {
					closeStream(id, true);
					break;
				}
				sendFrame(MachineStreamFrame.encode(MachineStreamFrame.DATA, id, message));
			}
			if (streams.exists(id) && !stream.pipe.isOpen())
				closeStream(id, true);
		}
	}

	/** Closes streams whose workspace is no longer granted, or granted something else. */
	function checkGrants():Void {
		for (id in [for (key in streams.keys()) key]) {
			var stream = streams.get(id);
			if (stream == null)
				continue;
			var current = host.grantsFor(deviceId, stream.workspace);
			if (current == null || !MachineGrants.same(current, stream.grants))
				closeStream(id, true);
		}
	}

	function closeStream(id:Int, tell:Bool):Void {
		var stream = streams.get(id);
		if (stream == null)
			return;
		streams.remove(id);
		stream.pipe.close();
		if (tell)
			sendFrame(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, id, null));
	}

	function register(current:RpcConnection):Void {
		current.register(MachineDirectoryProtocol.DIRECTORY, function(request, context) {
			var wanted = request.machine;
			if (wanted != null && wanted != host.machineId()) {
				context.fail({code: "machine_mismatch", message: "This is not that machine", ambiguous: false});
				return;
			}
			shownRevision = host.revision();
			context.respond(host.directory(deviceId));
		});
		current.register(MachineDirectoryProtocol.OPEN, function(request, context) {
			if (!MachineDirectoryProtocol.validOpen(request)) {
				context.fail({code: "invalid_request", message: "Invalid workspace reference", ambiguous: false});
				return;
			}
			var ref:WorkspaceRef = request.ref;
			if (ref.machine != host.machineId()) {
				context.fail({code: "machine_mismatch", message: "This is not that machine", ambiguous: false});
				return;
			}
			var grants = host.grantsFor(deviceId, ref.workspace);
			if (grants == null) {
				// The same answer as for a workspace that does not exist: a device cannot probe for ids.
				context.fail({code: "unknown_workspace", message: "No such workspace", ambiguous: false});
				return;
			}
			if (streamCount() + opening.length >= MachineDirectoryProtocol.STREAM_LIMIT - 1
				|| streamsIn(ref.workspace) >= STREAMS_PER_WORKSPACE) {
				context.fail({code: "too_many_streams", message: "Too many open workspaces", ambiguous: false});
				return;
			}
			var id = nextStream++;
			opening.push(id);
			openingIn.push(ref.workspace);
			host.openService(deviceId, ref.workspace, grants, function(pipe, error) {
				opening.remove(id);
				openingIn.remove(ref.workspace);
				if (pipe == null || closed) {
					if (pipe != null)
						pipe.close();
					context.fail({code: error == null ? "workspace_unavailable" : error, message: "Could not open the workspace", ambiguous: false});
					return;
				}
				var now = host.grantsFor(deviceId, ref.workspace);
				if (now == null || !MachineGrants.same(now, grants)) {
					pipe.close();
					context.fail({code: "unknown_workspace", message: "No such workspace", ambiguous: false});
					return;
				}
				streams.set(id, {id: id, workspace: ref.workspace, grants: grants, pipe: pipe});
				if (!context.respond({ref: ref, stream: id, grants: grants.copy()}))
					closeStream(id, false);
			});
		});
		current.register(MachineDirectoryProtocol.CLOSE, function(request, context) {
			closeStream(request.stream, false);
			context.respond({stream: request.stream});
		});
	}

	public function close():Void {
		if (closed)
			return;
		closed = true;
		for (id in [for (key in streams.keys()) key])
			closeStream(id, false);
		var current = connection;
		if (current != null)
			current.close();
		var pending = handshake;
		if (pending != null)
			pending.close();
		secure.close();
	}
}
