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
						text(command, "mono"), text(command, "appFilesRoot"), credentials(command),
							flag(command, "credentialsUnreadable"));
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
				case "keyboardWanted":
					// 1: a text field is active; 2: none is, so a soft keyboard on screen is stale.
					if (host == null) return 2;
					return host.keyboardWanted() ? 1 : 2;
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
					// 2: the link was turned down (the UI says why). It came from a test rig's intent, so the host logs it and
					// carries on; 0 would put the app on its fatal error screen.
					return remote.beginPairing(text(command, "url")) ? 1 : 2;
				case "network":
					// The device network changed ("changed": true) or the app came back to the foreground. Dial now; see PhoneRemote.networkChanged.
					var remote = AndroidExosuitFactory.remote;
					if (remote == null) return 0;
					remote.networkChanged(flag(command, "changed"));
					return 1;
				case "prefill":
					// A shared or opened invitation: fill in the pairing field and show the Remote panel. Never starts pairing (any
					// app can send this); 2 when the text is no pairing link.
					return AndroidExosuitFactory.prefillPairing(text(command, "url")) ? 1 : 2;
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

	static function flag(command:Dynamic, key:String):Bool {
		var value:Dynamic = Reflect.field(command, key);
		return Std.isOfType(value, Bool) ? value : false;
	}

	static function text(command:Dynamic, key:String):String {
		var value:Dynamic = Reflect.field(command, key);
		return Std.isOfType(value, String) ? value : "";
	}
}
