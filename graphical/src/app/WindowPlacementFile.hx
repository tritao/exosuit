package app;

import haxeon.ui.host.WindowPlacement;
import sys.FileSystem;
import sys.io.File;

/**
	Where the editor's window was, kept in the state folder (`window.conf`, beside session.conf) so the next run, or a
	live reload that reopens the window, puts it back there. `PRAGTICAL_PORTABLE` moves it with the rest of the state.
	A file that is missing or cannot be read means no saved place, never an error.
**/
class WindowPlacementFile {
	/** How often a running editor looks at where its window is, in seconds. */
	static inline final CHECK_SECONDS = 1.0;

	final path:String;
	var saved:String = "";
	var checkedAt:Float = 0;

	public function new() {
		path = haxe.io.Path.join([config.ConfigurationPaths.stateRoot(), "window.conf"]);
	}

	public function load():Null<WindowPlacement> {
		try {
			if (!FileSystem.exists(path)) return null;
			var text = StringTools.trim(File.getContent(path));
			var parts = text.split(" ");
			if (parts.length != 5) return null;
			var numbers = [for (index in 0...4) Std.parseInt(parts[index])];
			for (number in numbers) if (number == null) return null;
			if (numbers[2] <= 0 || numbers[3] <= 0) return null;
			saved = text;
			return new WindowPlacement(numbers[0], numbers[1], numbers[2], numbers[3], parts[4] == "maximized");
		} catch (_:Dynamic) {
			return null;
		}
	}

	/** Saves the window's place when it changed; looks at most once per CHECK_SECONDS unless `force` is set. */
	public function update(read:Null<Void->Null<WindowPlacement>>, force:Bool = false):Void {
		if (read == null) return;
		var time = Sys.time();
		if (!force && time - checkedAt < CHECK_SECONDS) return;
		checkedAt = time;
		var placement = try read() catch (_:Dynamic) null;
		if (placement == null) return;
		var text = placement.x + " " + placement.y + " " + placement.width + " " + placement.height + " "
			+ (placement.maximized ? "maximized" : "normal");
		if (text == saved) return;
		try {
			var directory = haxe.io.Path.directory(path);
			if (directory.length > 0 && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
			File.saveContent(path, text + "\n");
			saved = text;
		} catch (_:Dynamic) {}
	}
}
