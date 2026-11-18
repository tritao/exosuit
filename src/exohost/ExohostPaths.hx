package exohost;

import haxe.io.Path;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateDirectory(path:String):Bool;

/**
	Where the per-user exohost daemon keeps its state and listens.

	`EXOSUIT_EXOHOST_HOME` moves everything, the control endpoint included, so a test gets its own isolated
	exohost that never sees the user's registry or answers on the user's pipe.
**/
class ExohostPaths {
	public static function home():String {
		var configured = Sys.getEnv("EXOSUIT_EXOHOST_HOME");
		if (configured != null && configured.length > 0)
			return configured;
		return defaultHome();
	}

	/** The user's exohost home, where exohost lives without `EXOSUIT_EXOHOST_HOME`. */
	public static function defaultHome():String {
		if (Sys.systemName() == "Windows") {
			var local = Sys.getEnv("LOCALAPPDATA");
			if (local == null || local.length == 0)
				local = Path.join([Sys.getEnv("USERPROFILE"), "AppData", "Local"]);
			return Path.join([local, "exosuit", "exohost"]);
		}
		var state = Sys.getEnv("XDG_STATE_HOME");
		if (state == null || state.length == 0)
			state = Path.join([Sys.getEnv("HOME"), ".local", "state"]);
		return Path.join([state, "exosuit", "exohost"]);
	}

	/**
		Creates exohost's home and registry, readable only by this user (the daemon's lock requires it).
		Returns false when they cannot be made private, for example when another account owns them.
	**/
	public static function prepare():Bool {
		var directory = home();
		// A parent that cannot be created makes preparePrivateDirectory fail, which reports it.
		try sys.FileSystem.createDirectory(Path.directory(directory)) catch (_:Dynamic) {}
		return preparePrivateDirectory(directory) && preparePrivateDirectory(registry());
	}

	/** One `<pid>.json` record per registered process. */
	public static function registry():String
		return Path.join([home(), "registry"]);

	public static function endpoint():String {
		if (Sys.systemName() != "Windows")
			return Path.join([home(), "exohost.sock"]);
		var name = "exosuit-exohost-" + user();
		var configured = Sys.getEnv("EXOSUIT_EXOHOST_HOME");
		if (configured != null && configured.length > 0)
			name += "-" + haxe.crypto.Sha256.encode(configured).substr(0, 12);
		return "\\\\.\\pipe\\" + name;
	}

	/**
		The Pragtical control protocol pipe of editor window `instance` (docs/design/exohostctl/TDD-exosuit-ctl.md §5.4):
		`\\.\pipe\exosuit-exohostctl-<user>-<instance>` on Windows, a socket in exohost's runtime folder elsewhere.
	**/
	public static function instanceEndpoint(instance:String):String
		return Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-exohostctl-" + user() + "-" + instance : Path.join([home(), "runtime", instance + ".sock"]);

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
