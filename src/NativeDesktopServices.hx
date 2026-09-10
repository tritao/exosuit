
import NativeKit;
import NativeKit.NativeKitConstants;
import NativeKitEventValue;
import NativeKitOptions;
import NativeKitRequests;

/** Optional NativeKit-backed desktop services for the graphical application. */
class NativeDesktopServices {
	public final enabled:Bool;
	final requests:NativeKitRequests;
	var eventHandler:Null<NativeKitEventValue->Void>;

	public function new() {
		enabled = environmentEnabled("PRAGTICAL_NATIVEKIT");
		requests = new NativeKitRequests();
		if (!enabled) return;
		if (NativeKit.nk_api_version() != NativeKitConstants.NK_API_VERSION)
			throw "NativeKit API version mismatch";
		var options = new nk_init_options();
		options.set_struct_size(nk_init_options.size());
		options.set_api_version(NativeKitConstants.NK_API_VERSION);
		options.set_event_queue_capacity(256);
		require(NativeKit.nk_init(options), "initialize");
	}

	/** Receives decoded events which do not have a tracked request callback. */
	public function onEvent(handler:NativeKitEventValue->Void):Void
		eventHandler = handler;

	/** Drains pending service completions and other NativeKit events. */
	public function poll():Void {
		if (!enabled) return;
		while (true) {
			var value = requests.poll();
			switch value {
				case None: return;
				default: if (eventHandler != null) eventHandler(value);
			}
		}
	}

	public function openFile(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String, ?allowMultiple:Bool):haxe.Int64 {
		requireEnabled();
		var flags = allowMultiple == true ? NativeKitConstants.NK_DIALOG_ALLOW_MULTIPLE : 0;
		return requests.openFile(0, NativeKitOptions.fileDialog(title, initialPath, null, flags), handler);
	}

	public function saveFile(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String, ?suggestedName:String):haxe.Int64 {
		requireEnabled();
		return requests.saveFile(0, NativeKitOptions.fileDialog(title, initialPath, suggestedName), handler);
	}

	public function selectDirectory(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String):haxe.Int64 {
		requireEnabled();
		return requests.selectDirectory(0, NativeKitOptions.fileDialog(title, initialPath), handler);
	}

	public function readClipboardText(handler:String->Void):haxe.Int64 {
		requireEnabled();
		return requests.readClipboardText(handler);
	}

	public function writeClipboardText(text:String):Void {
		requireEnabled();
		require(NativeKit.nk_clipboard_set_text(text), "write clipboard text");
	}

	public function openUrl(url:String):Void {
		requireEnabled();
		require(NativeKit.nk_shell_open_url(url), "open URL");
	}

	public function openFileExternally(path:String):Void {
		requireEnabled();
		require(NativeKit.nk_shell_open_file(path), "open file");
	}

	public function revealFile(path:String):Void {
		requireEnabled();
		require(NativeKit.nk_shell_reveal_file(path), "reveal file");
	}

	public function shutdown():Void {
		if (enabled) NativeKit.nk_shutdown();
	}

	function requireEnabled():Void
		if (!enabled) throw "NativeKit desktop services are disabled";

	static function require(result:Int, operation:String):Void
		if (result != NativeKitConstants.NK_OK)
			throw 'NativeKit could not $operation ($result): ${NativeKit.nk_last_error()}';

	static function environmentEnabled(name:String):Bool {
		var value = Sys.getEnv(name);
		return value == "1" || value == "true" || value == "yes" || value == "on";
	}
}
