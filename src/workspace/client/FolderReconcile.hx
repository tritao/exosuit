package workspace.client;

import workspace.PathKey;

/** Whether a running service serves the folders the machine catalog gives its workspace. */
class FolderReconcile {
	/** The wait before the next try after a failure: doubled, up to a minute. */
	public static function nextDelay(delay:Float):Float return Math.min(60.0, delay * 2);

	/**
		True when the folders `served` differ from `wanted`, order aside. A workspace with no folders is served from its
		`scratch` folder, if it has one.
	**/
	public static function differs(served:Array<String>, wanted:Array<String>, scratch:Null<String>):Bool {
		var expected = wanted.length > 0 || scratch == null ? wanted : [scratch];
		if (served.length != expected.length) return true;
		var keys = [for (path in served) PathKey.of(path)];
		for (path in expected) if (keys.indexOf(PathKey.of(path)) < 0) return true;
		return false;
	}
}
