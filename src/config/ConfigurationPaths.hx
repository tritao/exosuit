package config;

class ConfigurationPaths {
	public static function userSettings():String {
		return child(configurationRoot(), "settings.conf");
	}

	public static function session():String {
		return child(stateRoot(), "session.conf");
	}

	public static function recentProjects():String {
		return child(stateRoot(), "recent-projects.conf");
	}

	public static function configurationRoot():String {
		var portable = environment("PRAGTICAL_PORTABLE");
		if (portable != null) return trim(portable);
		var home = environment("HOME"), system = Sys.systemName();
		if (system == "Windows") {
			var roaming = environment("APPDATA");
			return child(roaming == null ? child(home, "AppData/Roaming") : roaming, "Pragtical Haxeon");
		}
		if (system == "Mac") return child(home, "Library/Application Support/Pragtical Haxeon");
		var xdg = environment("XDG_CONFIG_HOME");
		return child(xdg == null ? child(home, ".config") : xdg, "pragtical-haxeon");
	}

	public static function stateRoot():String {
		var portable = environment("PRAGTICAL_PORTABLE");
		if (portable != null) return trim(portable);
		var home = environment("HOME"), system = Sys.systemName();
		if (system == "Windows") {
			var local = environment("LOCALAPPDATA");
			if (local == null) local = environment("APPDATA");
			return child(local == null ? child(home, "AppData/Local") : local, "Pragtical Haxeon");
		}
		if (system == "Mac") return child(home, "Library/Application Support/Pragtical Haxeon");
		var xdg = environment("XDG_STATE_HOME");
		return child(xdg == null ? child(home, ".local/state") : xdg, "pragtical-haxeon");
	}

	public static function recovery():String {
		var sessionPath = session(), separator = sessionPath.lastIndexOf("/");
		return separator < 0 ? "recovery.conf" : sessionPath.substring(0, separator + 1) + "recovery.conf";
	}

	public static function replacementBackup():String {
		var sessionPath = session(), separator = sessionPath.lastIndexOf("/");
		return separator < 0 ? "replacement-backup.conf" : sessionPath.substring(0, separator + 1) + "replacement-backup.conf";
	}

	public static function trash():String {
		var sessionPath = session(), separator = sessionPath.lastIndexOf("/");
		return separator < 0 ? "trash" : sessionPath.substring(0, separator + 1) + "trash";
	}

	public static function projectSettings(root:String):String
		return root + "/.pragtical/settings.conf";

	static function environment(name:String):Null<String> {
		var value = Sys.getEnv(name);
		return value == null || value.length == 0 ? null : value;
	}

	static function child(parent:Null<String>, name:String):String {
		if (parent == null || parent.length == 0) return name;
		return trim(parent) + "/" + name;
	}

	static function trim(path:String):String {
		var end = path.length;
		while (end > 1 && (path.charAt(end - 1) == "/" || path.charAt(end - 1) == "\\")) end--;
		return path.substring(0, end);
	}
}
