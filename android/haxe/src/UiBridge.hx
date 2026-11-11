import haxe.io.Bytes;
import runtime.memory.RawPtr;

/**
	The one entry point the JNI layer calls (`exosuit_jni.c` looks up `UiBridge.init` and `UiBridge.commandJSON` in the
	module's identity manifest). A command is a length-prefixed JSON object: start, resize, frame, close.
**/
class UiBridge {
	static var host:Null<AndroidUiHost>;
	static var failed = false;

	@:keep public static function init():Void {}

	/** Before a live patch that drops functions: let go of the UI tree and its handlers (haxeon docs/LIVE_PATCHING.md). Debug builds only call it. */
	@:keep public static function liveRelease():Void {
		var current = AndroidExosuitFactory.app;
		if (current != null) current.releaseRetained();
	}

	/** After a live patch, applied or refused: the next frame builds the UI from the code that now runs. */
	@:keep public static function liveRebuild():Void {
		var current = AndroidExosuitFactory.app;
		if (current != null) current.requestFrame();
	}

	@:keep public static function commandJSON(raw:hl.Bytes):Int {
		try {
			var command:Dynamic = haxe.Json.parse(read(raw).toString());
			switch text(command, "type") {
				case "start":
					if (host != null) return 0;
					host = new AndroidUiHost(integer(command, "surface"), integer(command, "width"), integer(command, "height"),
						integer(command, "fbWidth"), integer(command, "fbHeight"), number(command, "scale"), text(command, "regular"),
						text(command, "mono"), text(command, "appFilesRoot"), credentials(command));
					return 1;
				case "resize":
					if (host == null) return 0;
					host.resize(integer(command, "width"), integer(command, "height"), integer(command, "fbWidth"),
						integer(command, "fbHeight"), number(command, "scale"));
					return 1;
				case "insets":
					if (host == null) return 0;
					host.setSafeArea(number(command, "left"), number(command, "top"), number(command, "right"), number(command, "bottom"),
						number(command, "keyboard"));
					return 1;
				case "back":
					// 1: the UI consumed Back; 2: nothing left to go back to, the Activity may finish.
					if (host == null) return 2;
					return host.back() ? 1 : 2;
				case "frame":
					if (host == null || failed) return 0;
					host.frame(number(command, "timeMs"));
					return 1;
				case "hostResult":
					HostBridge.result(integer(command, "id"), integer(command, "ok") == 1);
					return 1;
				case "pair":
					var remote = AndroidExosuitFactory.remote;
					if (remote == null) return 0;
					return remote.beginPairing(text(command, "url")) ? 1 : 0;
				case "open":
					// Debug builds: open the workspace with this name as soon as a paired machine lists it.
					var remote = AndroidExosuitFactory.remote;
					if (remote == null) return 0;
					remote.openByName(text(command, "name"));
					return 1;
				case "close":
					if (host != null) host.close();
					host = null;
					return 1;
				default:
					return 0;
			}
		} catch (error:Dynamic) {
			failed = true;
			Sys.println("UiBridge: " + Std.string(error));
			Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack(true)));
			return 0;
		}
	}

	/**
		Copies the next request for the host (HostBridge) into the buffer the JNI layer passes: its first four bytes hold
		the capacity (big-endian), the frame goes after them. Returns the frame's length, 0 when there is none, -1 when it
		does not fit (it stays queued). The JNI layer calls it after every frame, so it must stay cheap.
	**/
	@:keep public static function takeHostRequest(raw:hl.Bytes):Int {
		var frame = HostBridge.peek();
		if (frame == null) return 0;
		var pointer:RawPtr<UInt8> = cast raw;
		if (pointer.isNull()) return -1;
		var capacity = 0;
		for (index in 0...4) capacity = (capacity << 8) | (cast pointer.offset(index).load() : Int);
		if (capacity < 0 || frame.length > capacity - 4) return -1;
		HostBridge.take();
		for (index in 0...frame.length) {
			pointer.offset(index + 4).store(cast frame.get(index));
			frame.set(index, 0);
		}
		return frame.length;
	}

	/** The stored credentials, base64 in the start command; null when there are none. */
	static function credentials(command:Dynamic):Null<Bytes> {
		var value:Dynamic = Reflect.field(command, "credentials");
		if (!Std.isOfType(value, String) || (value:String).length == 0) return null;
		return haxe.crypto.Base64.decode(value);
	}

	static function read(raw:hl.Bytes):Bytes {
		var pointer:RawPtr<UInt8> = cast raw;
		if (pointer.isNull()) throw "null command";
		var length = 0;
		for (index in 0...4) length = (length << 8) | (cast pointer.offset(index).load() : Int);
		if (length < 0 || length > 65536) throw "bad command length";
		var bytes = Bytes.alloc(length);
		for (index in 0...length) bytes.set(index, cast pointer.offset(index + 4).load());
		return bytes;
	}

	static function integer(command:Dynamic, key:String):Int {
		var value:Dynamic = Reflect.field(command, key);
		if (!Std.isOfType(value, Int)) throw 'invalid integer "$key"';
		return value;
	}

	static function number(command:Dynamic, key:String):Float {
		var value:Dynamic = Reflect.field(command, key);
		if (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)) throw 'invalid number "$key"';
		return value;
	}

	static function text(command:Dynamic, key:String):String {
		var value:Dynamic = Reflect.field(command, key);
		return Std.isOfType(value, String) ? value : "";
	}
}
