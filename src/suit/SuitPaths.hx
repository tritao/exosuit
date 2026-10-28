package suit;

import haxe.io.Path;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateDirectory(path:String):Bool;

/**
	Where the per-user suit daemon keeps its state and listens.

	`EXOSUIT_SUIT_HOME` moves everything, the control endpoint included, so a test gets its own isolated
	suit that never sees the user's registry or answers on the user's pipe.
**/
class SuitPaths {
	public static function home():String {
		var configured = Sys.getEnv("EXOSUIT_SUIT_HOME");
		if (configured != null && configured.length > 0)
			return configured;
		return defaultHome();
	}

	/** The user's suit home, where suit lives without `EXOSUIT_SUIT_HOME`. */
	public static function defaultHome():String {
		if (Sys.systemName() == "Windows") {
			var local = Sys.getEnv("LOCALAPPDATA");
			if (local == null || local.length == 0)
				local = Path.join([Sys.getEnv("USERPROFILE"), "AppData", "Local"]);
			return Path.join([local, "exosuit", "suit"]);
		}
		var state = Sys.getEnv("XDG_STATE_HOME");
		if (state == null || state.length == 0)
			state = Path.join([Sys.getEnv("HOME"), ".local", "state"]);
		return Path.join([state, "exosuit", "suit"]);
	}

	/**
		Creates suit's home and registry, readable only by this user (the daemon's lock requires it).
		Returns false when they cannot be made private, for example when another account owns them.
	**/
	public static function prepare():Bool {
		var directory = home();
		createAncestors(Path.directory(directory));
		return preparePrivateDirectory(directory) && preparePrivateDirectory(registry());
	}

	/** Creates `directory` and any missing parents; createDirectory makes one level only. */
	static function createAncestors(directory:String):Void {
		if (directory.length == 0 || sys.FileSystem.exists(directory))
			return;
		var parent = Path.directory(directory);
		if (parent != directory)
			createAncestors(parent);
		try sys.FileSystem.createDirectory(directory) catch (_:Dynamic) {}
	}

	/** One `<pid>.json` record per registered process. */
	public static function registry():String
		return Path.join([home(), "registry"]);

	public static function endpoint():String {
		if (Sys.systemName() != "Windows")
			return Path.join([home(), "suit.sock"]);
		var name = "exosuit-suit-" + user();
		var configured = Sys.getEnv("EXOSUIT_SUIT_HOME");
		if (configured != null && configured.length > 0)
			name += "-" + haxe.crypto.Sha256.encode(configured).substr(0, 12);
		return "\\\\.\\pipe\\" + name;
	}

	static function user():String {
		var name = Sys.getEnv("USERNAME");
		if (name == null || name.length == 0)
			name = Sys.getEnv("USER");
		if (name == null || name.length == 0)
			return "user";
		var result = new StringBuf();
		for (index in 0...name.length) {
			var c = name.charCodeAt(index);
			var safe = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95;
			result.addChar(safe ? c : 95);
		}
		return result.toString();
	}
}
