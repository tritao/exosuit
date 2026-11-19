package exohost.remote;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import workspace.service.MachineDirectoryProtocol;
import workspace.service.MachineDirectoryProtocol.MachineDirectory;
import workspace.service.MachineDirectoryProtocol.MachineStreamFrame;
import workspace.service.MachineDirectoryProtocol.MachineSessions;
import exohost.remote.DeferredReply;
import workspace.service.MachineDirectoryProtocol.MachineSessionEntry;
import workspace.service.MachineGrants;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.transport.StreamMultiplexer;
import workspace.transport.StreamMultiplexer.MuxStream;

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
		idle and `start` is true. `done` gets the connection and the service it reached, or an error code
		(`unknown_workspace`, `workspace_unavailable`).
	**/
	/** The sessions of `deviceId`'s readable running workspaces, as exohost's `sessions` op answers (polled until `reply` is set). */
	function listSessions(deviceId:String):DeferredReply;
	function openService(deviceId:String, workspace:String, grants:Array<String>, start:Bool,
		done:(Null<MessageTransport>, Null<workspace.client.OpenedService>, Null<String>) -> Void):Void;
}

private typedef ServiceStream = {
	var device:MuxStream;
	var workspace:String;
	var grants:Array<String>;
	var pipe:MessageTransport;
	/** A message the other side refused; it is offered again before anything else moves that way. */
	var toService:Null<Bytes>;
	var toDevice:Null<Bytes>;
}

/**
	A paired device's authenticated channel (ADR 0005 section 4). Stream frames run on it, split by the same
	`StreamMultiplexer` the device uses: stream 0 is the machine directory, an RPC connection with this process, and
	OPEN adds a stream that exohost forwards, message for message and unread, to a workspace service's local pipe. The service enforces the device's grants per request;
	exohost decides only which workspaces open. A grant that changes or goes closes that workspace's streams.
**/
class MachineDeviceSession {
	static inline final MESSAGES_PER_POLL = 64;
	/**
		Streams one device may hold in one workspace, open or opening. Each is a connection to the workspace's service, and
		the service has a bounded pool of them for all devices.
	**/
	public static inline final STREAMS_PER_WORKSPACE = 6;

	public final deviceId:String;
	final mux:StreamMultiplexer;
	final host:MachineSessionHost;
	final clock:Void->Float;
	final streams:Map<Int, ServiceStream> = [];
	/** The workspace of each OPEN still in progress (one entry per OPEN). */
	final openingIn:Array<String> = [];
	var handshake:Null<RpcHandshake>;
	var connection:Null<RpcConnection>;
	var nextStream:Int = 1;
	var shownRevision:Int;
	var closed:Bool = false;
	/** SESSIONS requests waiting for their workspaces' services. */
	final asked:Array<{reply:DeferredReply, answer:MachineSessions->Void}> = [];

	public function new(deviceId:String, secure:MessageTransport, host:MachineSessionHost, clock:Void->Float) {
		this.deviceId = deviceId;
		this.mux = new StreamMultiplexer(secure);
		this.host = host;
		this.clock = clock;
		var options = new RpcPeerOptions(MachineDirectoryProtocol.APPLICATION, [MachineDirectoryProtocol.CAPABILITY], [], 30000,
			MachineStreamFrame.MAX_PAYLOAD, 16, 4 * MachineStreamFrame.MAX_PAYLOAD);
		handshake = RpcHandshake.server(mux.machineStream(), clock, options);
		shownRevision = host.revision();
	}

	public function isOpen():Bool
		return !closed && mux.isOpen();

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

	public function poll():Void {
		if (closed)
			return;
		mux.poll();
		if (!mux.isOpen()) {
			close();
			return;
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
		answerSessions();
		var revision = host.revision();
		if (revision != shownRevision && current != null) {
			shownRevision = revision;
			current.notify(MachineDirectoryProtocol.CHANGED, {revision: revision}, MachineDirectoryProtocol.encodeChange);
		}
	}

	/** Moves messages between each device stream and its service's pipe, holding one that a side refused. */
	function pumpStreams():Void {
		for (id in [for (key in streams.keys()) key]) {
			var stream = streams.get(id);
			if (stream == null)
				continue;
			for (_ in 0...MESSAGES_PER_POLL) {
				var message = stream.toService != null ? stream.toService : stream.device.receive();
				if (message == null)
					break;
				stream.toService = stream.pipe.send(message) ? null : message;
				if (stream.toService != null)
					break;
			}
			for (_ in 0...MESSAGES_PER_POLL) {
				var message = stream.toDevice != null ? stream.toDevice : stream.pipe.receive();
				if (message == null)
					break;
				if (message.length > MachineStreamFrame.MAX_PAYLOAD) {
					closeStream(id, true);
					break;
				}
				stream.toDevice = stream.device.send(message) ? null : message;
				if (stream.toDevice != null)
					break;
			}
			if (streams.exists(id) && (!stream.pipe.isOpen() || !stream.device.isOpen()))
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

	/** Ends a service stream: its pipe closes, and the device hears of it unless it closed the stream itself. */
	function closeStream(id:Int, tell:Bool):Void {
		var stream = streams.get(id);
		if (stream == null)
			return;
		streams.remove(id);
		stream.pipe.close();
		if (tell)
			stream.device.close();
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
		current.register(MachineDirectoryProtocol.SESSIONS, function(request, context) {
			var wanted = request.machine;
			if (wanted != null && wanted != host.machineId()) {
				context.fail({code: "machine_mismatch", message: "This is not that machine", ambiguous: false});
				return;
			}
			asked.push({reply: host.listSessions(deviceId), answer: function(value) context.respond(value)});
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
			if (streamCount() + openingIn.length >= MachineDirectoryProtocol.STREAM_LIMIT - 1
				|| streamsIn(ref.workspace) >= STREAMS_PER_WORKSPACE) {
				context.fail({code: "too_many_streams", message: "Too many open workspaces", ambiguous: false});
				return;
			}
			var id = nextStream++;
			openingIn.push(ref.workspace);
			host.openService(deviceId, ref.workspace, grants, request.start != false, function(pipe, service, error) {
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
				var device = mux.open(id);
				if (device == null) {
					pipe.close();
					context.fail({code: "too_many_streams", message: "Too many open workspaces", ambiguous: false});
					return;
				}
				streams.set(id, {device: device, workspace: ref.workspace, grants: grants, pipe: pipe, toService: null, toDevice: null});
				if (!context.respond({ref: ref, stream: id, grants: grants.copy(), generation: service == null ? null : service.generation,
					root: service == null ? null : service.root}))
					closeStream(id, true);
			});
		});
		current.register(MachineDirectoryProtocol.CLOSE, function(request, context) {
			closeStream(request.stream, false);
			context.respond({stream: request.stream});
		});
	}

	/** Answers the SESSIONS requests whose services have all replied (or timed out), in exohost's `sessions` reply shape. */
	function answerSessions():Void {
		var at = asked.length;
		while (--at >= 0) {
			var item = asked[at];
			var reply:Dynamic = item.reply.reply;
			if (reply == null)
				continue;
			asked.splice(at, 1);
			var entries:Array<MachineSessionEntry> = [];
			for (entry in workspace.sessions.SessionIndex.fromJson(reply))
				entries.push({id: entry.id, name: entry.name, workspace: entry.workspaceId, workspaceName: entry.workspaceName,
					groupPath: entry.groupPath, groupNames: entry.groupNames, kind: (entry.kind : String), state: (entry.state : String),
					lastActive: entry.lastActive, last: entry.last});
			var unavailable:Array<String> = [];
			var listed:Dynamic = Reflect.field(reply, "unavailable");
			if (Std.isOfType(listed, Array))
				for (id in (listed : Array<Dynamic>))
					if (Std.isOfType(id, String))
						unavailable.push(id);
			item.answer({sessions: entries, unavailable: unavailable});
		}
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
		mux.close();
	}
}
