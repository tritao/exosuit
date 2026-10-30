package platform;

/** The user's own folders, from the environment. */
class UserFolders {
	/** The home folder: USERPROFILE on Windows, HOME elsewhere; null when it is not set. */
	public static function home():Null<String> {
		var home = Sys.getEnv(Sys.systemName() == "Windows" ? "USERPROFILE" : "HOME");
		return home == null || home.length == 0 ? null : home;
	}
}
