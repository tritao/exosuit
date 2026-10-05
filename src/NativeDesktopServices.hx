import haxeon.ui.host.DesktopUiHostContext;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitEventValue;
import haxe.io.Bytes;

/**
 * NativeKit-backed desktop services (file/folder dialogs, clipboard, and
 * shell) for the graphical application.
 *
 * NativeKit itself is owned and pumped by the `DesktopUiHost` the
 * application runs under, so this class does not call `nk_init`/`nk_shutdown`
 * or poll events on its own; it only issues requests through the host's
 * already-live `events.requests` tracker, matching how the shared UIKit
 * reference editor (`app/src/SceneFileDialogs.hx`) uses the same API.
 */
class NativeDesktopServices implements platform.HostFileDialogs {
	final host:DesktopUiHostContext;
	final pending:Array<haxe.Int64> = [];

	public function new(host:DesktopUiHostContext) {
		this.host = host;
	}

	public function confirmSaveChanges(filename:String, handler:String->Void):Void {
		var options = new MessageDialogOptions();
		options.set_title("exosuit");
		options.set_kind(MessageKind.Warning);
		options.set_buttons(MessageButtons.Save | MessageButtons.DontSave | MessageButtons.Cancel);
		options.set_message('Do you want to save the changes you made to "' + filename + '"?\n\nYour changes will be lost if you don’t save them.');
		var request = NativeKit.nk_dialog_message_checked(parentHandle(), options);
		pending.push(request);
		host.events.requests.track(request, function(value) {
			pending.remove(request);
			var answer = switch value {
				case DialogMessage(_, result, button) if (result == Result.Ok):
					button == MessageResult.Yes ? "save" : button == MessageResult.No ? "discard" : "cancel";
				case _: "cancel";
			};
			handler(answer);
			host.requestFrame();
		});
	}

	public function openFile(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String, ?allowMultiple:Bool):haxe.Int64
		return chooseResource(false, title == null ? "Open" : title, null, initialPath,
			allowMultiple == true, handler);

	public function saveFile(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String, ?suggestedName:String):haxe.Int64
		return chooseResource(true, title == null ? "Save" : title, suggestedName, initialPath,
			false, handler);

	public function selectDirectory(handler:Bool->Array<String>->Void, ?title:String,
			?initialPath:String):haxe.Int64 {
		var options = new FileDialogOptions();
		options.set_title(title == null ? "Select Folder" : title);
		if (initialPath != null) options.set_initial_path(initialPath);
		var request = NativeKit.nk_dialog_select_resource_directory_checked(parentHandle(), options);
		track(request, function(paths) handler(paths != null, paths == null ? [] : paths));
		return request;
	}

	function chooseResource(save:Bool, title:String, suggestedName:Null<String>,
			initialPath:Null<String>, allowMultiple:Bool, handler:Bool->Array<String>->Void):haxe.Int64 {
		var options = new FileDialogOptions();
		options.set_title(title);
		if (save) {
			options.set_flags(DialogFlags.ConfirmOverwrite);
			if (suggestedName != null) options.set_suggested_name(suggestedName);
		} else if (allowMultiple) options.set_flags(DialogFlags.AllowMultiple);
		if (initialPath != null) options.set_initial_path(initialPath);
		var request = save ? NativeKit.nk_dialog_save_resource_checked(parentHandle(), options)
			: NativeKit.nk_dialog_open_resource_checked(parentHandle(), options);
		track(request, function(paths) handler(paths != null, paths == null ? [] : paths));
		return request;
	}

	function track(request:haxe.Int64, handler:Null<Array<String>>->Void):Void {
		pending.push(request);
		host.events.requests.track(request, function(value) {
			pending.remove(request);
			switch value {
				case Resources(_, _, result, accepted, items):
					if (result != Result.Ok || !accepted || items.length == 0) { handler(null); return; }
					var paths:Array<String> = [];
					for (item in items) {
						try paths.push(localPath(item.uri)) catch (_:Dynamic) {}
					}
					handler(paths.length == 0 ? null : paths);
				case _: handler(null);
			}
		});
	}

	public function readClipboardText(handler:String->Void):haxe.Int64 {
		var request = NativeKit.nk_clipboard_read_text_checked();
		host.events.requests.track(request, function(value) switch value {
			case ClipboardText(_, result, text): handler(result == Result.Ok ? text : "");
			case _: handler("");
		});
		return request;
	}

	public function writeClipboardText(text:String):Void
		require(NativeKit.nk_clipboard_set_text(text), "write clipboard text");

	public function openUrl(url:String):Void
		require(NativeKit.nk_shell_open_url(url), "open URL");

	public function openFileExternally(path:String):Void
		require(NativeKit.nk_shell_open_file(path), "open file");

	public function revealFile(path:String):Void
		require(NativeKit.nk_shell_reveal_file(path), "reveal file");

	public function shutdown():Void {
		for (request in pending.copy()) {
			host.events.requests.cancel(request);
			NativeKit.nk_dialog_cancel(request);
		}
		pending.resize(0);
	}

	function parentHandle():Handle
		return new Handle(host.window.rawValue());

	static function require(result:Result, operation:String):Void
		if (result != Result.Ok)
			throw 'NativeKit could not $operation ($result): ${NativeKit.nk_last_error()}';

	/** Converts a `file://` resource URI to a local filesystem path. */
	public static function localPath(uri:String):String {
		if (!StringTools.startsWith(uri, "file://")) throw "Expected a local file URI";
		var encoded = uri.substr(7);
		if (StringTools.startsWith(encoded, "localhost/")) encoded = encoded.substr(9);
		if (!StringTools.startsWith(encoded, "/")) throw "Expected a local file URI";
		var source = Bytes.ofString(encoded);
		var output = Bytes.alloc(source.length);
		var count = 0;
		var i = 0;
		while (i < source.length) {
			var value = source.get(i++);
			if (value == 37) {
				if (i + 1 >= source.length) throw "Invalid file URI escape";
				var high = hex(source.get(i++));
				var low = hex(source.get(i++));
				if (high < 0 || low < 0) throw "Invalid file URI escape";
				value = high * 16 + low;
			}
			if (value == 0) throw "Invalid file URI";
			output.set(count++, value);
		}
		var path = output.sub(0, count).toString();
		if (Sys.systemName() == "Windows" && path.length > 2 && path.charAt(2) == ":") path = path.substr(1);
		return path;
	}

	static function hex(value:Int):Int {
		if (value >= 48 && value <= 57) return value - 48;
		if (value >= 65 && value <= 70) return value - 55;
		if (value >= 97 && value <= 102) return value - 87;
		return -1;
	}
}
