package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;

/** Asks for the machine's directory; `machine`, when set, must be this machine's id or the call fails with `machine_mismatch`. */
@:wire typedef MachineQuery = {
	@:id(1) var machine:Null<String>;
}

/** One workspace a device is granted: its id, name, whether its service runs, and what this device may do in it. */
@:wire typedef MachineWorkspaceEntry = {
	@:id(1) var workspace:String;
	@:id(2) var name:String;
	/** `running` when the workspace's service is up, `idle` when opening it would start it. */
	@:id(3) var status:String;
	/** The capabilities granted to this device for the workspace; the service enforces them per request. */
	@:id(4) var grants:Array<String>;
}

/** The machine and the workspaces granted to the asking device, and nothing about any other workspace. */
@:wire typedef MachineDirectory = {
	@:id(1) var machine:String;
	@:id(2) var name:String;
	/** Counts changes to this device's view (grants, names, status); a new value means list again. */
	@:id(3) var revision:Int;
	@:id(4) var workspaces:Array<MachineWorkspaceEntry>;
	/**
		The relay id the device paired under (32 hex digits), which need not be derived from `machine`. A machine that
		sends none is an older one whose relay id is its own id, or `machine` without the `machine-` prefix.
	**/
	@:optional @:id(5) var relay:Null<String>;
}

/** Opens a stream to one granted workspace's service. */
@:wire typedef OpenWorkspace = {
	@:id(1) var ref:WorkspaceRef;
}

/** The stream a successful open made: frames with this id reach the workspace's service. */
@:wire typedef WorkspaceStream = {
	@:id(1) var ref:WorkspaceRef;
	@:id(2) var stream:Int;
	@:id(3) var grants:Array<String>;
}

@:wire typedef CloseWorkspace = {
	@:id(1) var stream:Int;
}

/** A hint that the device's directory changed; DIRECTORY reads it. */
@:wire typedef DirectoryChange = {
	@:id(1) var revision:Int;
}

/**
	The machine directory a paired device reads from suit (ADR 0005 section 4, M19 Phase 9). A device pairs once with
	the machine. Its channel carries stream frames: stream 0 is a normal RPC connection with suit
	(application `exosuit-machine/1`, capability `machine.directory`, the methods below); OPEN makes a stream
	to a granted workspace's service, over which the device speaks the workspace protocol (`exosuit-agent/1`) as if
	it were connected to that service directly. Suit forwards frames without reading them.

	Errors: `machine_mismatch`, `unknown_workspace` (a ref this machine does not have, or a workspace not granted: the
	two are the same answer, so a device cannot probe for ids), `workspace_unavailable` (the service did not start),
	`too_many_streams`, `invalid_request`. Never reuse ids.
**/
class MachineDirectoryProtocol {
	public static inline final APPLICATION = "exosuit-machine/1";
	public static inline final CAPABILITY = "machine.directory";
	public static inline final RUNNING = "running";
	public static inline final IDLE = "idle";
	/** Streams a device may hold open at once, the machine stream included. */
	public static inline final STREAM_LIMIT = 16;
	public static inline final NAME_LIMIT = 200;
	public static inline final CHANGED = 183;

	public static final DIRECTORY = new RpcMethod<MachineQuery, MachineDirectory>(180, function(v:MachineQuery) return MessagePack.encode(v),
		function(b:Bytes):MachineQuery return MessagePack.decode(b), function(v:MachineDirectory) return MessagePack.encode(v),
		function(b:Bytes):MachineDirectory return MessagePack.decode(b));
	public static final OPEN = new RpcMethod<OpenWorkspace, WorkspaceStream>(181, function(v:OpenWorkspace) return MessagePack.encode(v),
		function(b:Bytes):OpenWorkspace return MessagePack.decode(b), function(v:WorkspaceStream) return MessagePack.encode(v),
		function(b:Bytes):WorkspaceStream return MessagePack.decode(b));
	public static final CLOSE = new RpcMethod<CloseWorkspace, CloseWorkspace>(182, function(v:CloseWorkspace) return MessagePack.encode(v),
		function(b:Bytes):CloseWorkspace return MessagePack.decode(b), function(v:CloseWorkspace) return MessagePack.encode(v),
		function(b:Bytes):CloseWorkspace return MessagePack.decode(b));

	public static function encodeChange(value:DirectoryChange):Bytes
		return MessagePack.encode(value);

	public static function decodeChange(bytes:Bytes):DirectoryChange
		return MessagePack.decode(bytes);

	/** Whether a request names a bounded workspace on a bounded machine; anything else is `invalid_request`. */
	public static function validOpen(value:Null<OpenWorkspace>):Bool
		return value != null && WorkspaceCatalogProtocol.validRef(value.ref);
}

/**
	The frame a device's Noise channel carries after pairing: one kind byte, a four-byte big-endian stream id, then the
	payload. Kind 0 is data (one RPC message of the stream), kind 1 closes the stream (no payload). Stream 0 is the
	machine stream, always open. A service stream is made by OPEN and ends with CLOSE, a close frame from either side,
	or the channel. A data frame for a stream that is not open is dropped and answered with a close frame. A payload
	is at most `MAX_PAYLOAD` bytes so the whole frame fits the Noise plaintext bound.
**/
class MachineStreamFrame {
	public static inline final DATA = 0;
	public static inline final CLOSE = 1;
	public static inline final HEADER_BYTES = 5;
	public static inline final MACHINE_STREAM = 0;
	/** The Noise plaintext bound, 65492 (NoiseMessageTransport.MAX_PLAINTEXT_BYTES, checked in the transport tests), less the header. */
	public static inline final MAX_PAYLOAD = 65492 - HEADER_BYTES;

	public static function encode(kind:Int, stream:Int, payload:Bytes):Bytes {
		var body = payload == null ? 0 : payload.length;
		var frame = Bytes.alloc(HEADER_BYTES + body);
		frame.set(0, kind);
		frame.set(1, (stream >>> 24) & 0xff);
		frame.set(2, (stream >>> 16) & 0xff);
		frame.set(3, (stream >>> 8) & 0xff);
		frame.set(4, stream & 0xff);
		if (body > 0)
			frame.blit(HEADER_BYTES, payload, 0, body);
		return frame;
	}

	/** The kind of a frame, or -1 when it is malformed (short, unknown kind, or a close with a payload). */
	public static function kind(frame:Bytes):Int {
		if (frame == null || frame.length < HEADER_BYTES || frame.length - HEADER_BYTES > MAX_PAYLOAD)
			return -1;
		var kind = frame.get(0);
		if (kind != DATA && kind != CLOSE || kind == CLOSE && frame.length != HEADER_BYTES)
			return -1;
		return kind;
	}

	public static function stream(frame:Bytes):Int
		return (frame.get(1) << 24) | (frame.get(2) << 16) | (frame.get(3) << 8) | frame.get(4);

	public static function payload(frame:Bytes):Bytes
		return frame.sub(HEADER_BYTES, frame.length - HEADER_BYTES);
}
