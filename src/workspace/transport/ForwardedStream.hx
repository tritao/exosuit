package workspace.transport;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;

/** What exohost tells a workspace service about a device stream it forwards: who, and what that device may do. */
typedef ForwardedIntro = {
	var device:String;
	var grants:Array<String>;
}

/**
	The first message on a local connection that exohost forwards a paired device's stream over (ADR 0005 section 4):
	the magic `EXFW`, then JSON `{version: 1, device, grants}`. Every message after it belongs to the stream and is
	an ordinary RPC message, so the service runs its usual handshake on the connection with exactly these grants.
	A local peer that is not exohost sends no intro and is a normal same-user client. A same-user peer could send an
	intro too, but only to get fewer rights than it already has.
**/
class ForwardedStream {
	public static inline final MAGIC = "EXFW";
	public static inline final VERSION = 1;
	public static inline final MAX_GRANTS = 64;
	/** The largest RPC message on a forwarded stream: what one device stream frame carries. */
	public static inline final MAX_MESSAGE_BYTES = workspace.service.MachineDirectoryProtocol.MachineStreamFrame.MAX_PAYLOAD;

	public static function intro(device:String, grants:Array<String>):Bytes
		return Bytes.ofString(MAGIC + Json.stringify({version: VERSION, device: device, grants: grants}));

	/** The intro in `message`, or null when it is not one (a normal client's first message, or a malformed intro). */
	public static function parse(message:Bytes):Null<ForwardedIntro> {
		if (message == null || message.length <= MAGIC.length || message.length > 16384 || message.getString(0, MAGIC.length) != MAGIC)
			return null;
		try {
			var value:Dynamic = Json.parse(message.getString(MAGIC.length, message.length - MAGIC.length));
			var device:Dynamic = Reflect.field(value, "device"), grants:Dynamic = Reflect.field(value, "grants");
			if (Reflect.field(value, "version") != VERSION || !Std.isOfType(device, String) || !Std.isOfType(grants, Array))
				return null;
			var list:Array<String> = [];
			for (grant in (grants : Array<Dynamic>)) {
				if (!Std.isOfType(grant, String) || list.length >= MAX_GRANTS)
					return null;
				list.push(grant);
			}
			return {device: device, grants: list};
		} catch (_:Dynamic) {
			return null;
		}
	}

	/** Whether a message begins an intro, well formed or not: such a connection is never a normal client. */
	public static function isIntro(message:Bytes):Bool
		return message != null && message.length >= MAGIC.length && message.getString(0, MAGIC.length) == MAGIC;
}

/** Hands a message already read from a transport back to its next reader, then reads on. */
class PushbackTransport implements MessageTransport {
	final inner:MessageTransport;
	var held:Null<Bytes>;

	public function new(first:Bytes, inner:MessageTransport) {
		held = first;
		this.inner = inner;
	}

	public function isOpen():Bool
		return held != null || inner.isOpen();

	public function send(message:Bytes):Bool
		return inner.send(message);

	public function receive():Null<Bytes> {
		var first = held;
		if (first != null) {
			held = null;
			return first;
		}
		return inner.receive();
	}

	public function close():Void {
		held = null;
		inner.close();
	}
}
