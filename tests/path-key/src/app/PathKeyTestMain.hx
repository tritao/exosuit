package app;

import workspace.PathKey;

/** Path comparison shared by the Agents scope, its Search and Changes, the group labels and the SCM path lookups. */
class PathKeyTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function windows():Void {
		require(PathKey.of("C:\\Work\\Repo\\", true) == "c:/work/repo", "separators, trailing separator and case");
		require(PathKey.of("C:\\", true) == "c:/" && PathKey.of("C:/", true) == "c:/", "a drive root keeps its separator");
		require(PathKey.same("C:\\Users\\Me\\repo", "c:/users/me/REPO/", true), "same path in other spellings");
		require(!PathKey.same("C:/work/a", "C:/work/b", true), "different paths compared equal");
		require(PathKey.within("C:\\Users\\me\\repo", "c:/users/ME/repo/src/A.hx", true), "case-insensitive containment");
		require(PathKey.within("C:/work", "C:\\work", true), "a folder contains itself");
		require(!PathKey.within("C:/work", "C:/workshop/a", true), "a sibling with a shared prefix is inside");
		require(PathKey.within("C:\\", "C:\\work\\a", true) && PathKey.within("C:/", "c:/", true), "a drive root contains its paths");
		require(!PathKey.within("C:\\", "D:\\work", true), "another drive is inside a drive root");
		require(PathKey.relative("C:\\Repo", "c:\\repo\\Sub\\File.hx", true) == "Sub/File.hx", "relative keeps the child's spelling");
		require(PathKey.relative("C:\\", "C:\\a\\b", true) == "a/b", "relative under a drive root");
		require(PathKey.relative("C:/repo/", "C:/repo", true) == "", "relative of the folder itself");
		require(PathKey.relative("C:/repo", "C:/other", true) == null, "relative outside the folder");
	}

	static function posix():Void {
		require(PathKey.of("/home/Me/repo/", false) == "/home/Me/repo", "POSIX keeps case");
		require(PathKey.of("/", false) == "/", "the POSIX root keeps its separator");
		require(!PathKey.same("/home/me", "/home/ME", false), "POSIX case ignored");
		require(PathKey.within("/", "/home/me", false) && PathKey.relative("/", "/home/me", false) == "home/me", "POSIX root");
		require(PathKey.within("/home/me/", "/home/me/a/b", false), "trailing separator on the parent");
		require(!PathKey.within("/home/me", "/home/meow", false), "POSIX sibling prefix");
	}

	static function style():Void {
		require(PathKey.windowsStyle("C:\\work") && PathKey.windowsStyle("d:/work") && PathKey.windowsStyle("\\\\server\\share"), "Windows spellings");
		require(!PathKey.windowsStyle("/home/me") && !PathKey.windowsStyle("relative/path") && !PathKey.windowsStyle("1:/x"), "POSIX spellings");
	}

	/** Inputs that used to compare wrongly: empty and drive-relative parents, long-path prefixes, doubled separators. */
	static function edges():Void {
		require(PathKey.of("") == "" && !PathKey.within("", "/home/me", false) && !PathKey.within("", "C:/work", true)
			&& PathKey.relative("", "", false) == "", "an empty parent contained other paths");
		require(PathKey.relative("C:", "C:/work", true) == null && PathKey.relative("C:/", "C:/work", true) == "work"
			&& PathKey.relative("C:", "C:", true) == "", "the drive-relative C: acted as the drive root");
		require(PathKey.same("\\\\?\\C:\\Work\\a", "c:/work/a", true) && PathKey.relative("C:\\work", "\\\\?\\C:\\work\\b", true) == "b",
			"a long-path prefix changed the path");
		require(PathKey.same("\\\\?\\UNC\\server\\share\\x", "\\\\server\\share\\x", true)
			&& PathKey.same("\\\\?\\unc\\server\\share\\x", "//server/share/x", true), "a long UNC path differed from its short form");
		require(PathKey.of("C:\\work\\\\a//b/", true) == "c:/work/a/b" && PathKey.of("/home//me///x", false) == "/home/me/x",
			"doubled separators were kept");
		require(PathKey.of("\\\\server\\share\\", true) == "//server/share" && PathKey.within("//server/share", "\\\\SERVER\\Share\\x", true)
			&& !PathKey.within("/server", "//server/x", false), "a UNC root lost or gained its double separator");
		// Case mapping may change a string's length (U+0130 lowercases to two code units on some targets); matching by
		// segment keeps the child's own spelling of what follows.
		require(PathKey.relative("C:/\u0130stanbul", "c:/\u0130STANBUL/Sub/File.hx", true) == "Sub/File.hx", "a length-changing case mapping shifted the match");
	}

	static function main():Void {
		windows();
		posix();
		style();
		edges();
		hangWatchdog();
		Sys.println("PASS: path keys ignore separators, trailing separators and Windows case; containment respects roots and sibling prefixes");
	}

	/** A UI thread that stops ticking leaves a report naming its last phase; one that keeps ticking leaves nothing. */
	static function hangWatchdog():Void {
		var directory = haxe.io.Path.join([Sys.getEnv("TEMP") == null ? "." : Sys.getEnv("TEMP"), "exosuit-hang-watchdog-test-" + Sys.getPid()]);
		var file = haxe.io.Path.join([directory, "logs", "ui-hang.log"]);
		var now = 100.0;
		var watchdog = new devtools.HangWatchdog(file, 5.0, function() return now);
		watchdog.beat("tick");
		watchdog.phase("build workbench");
		now = 104.0;
		require(!watchdog.check() && !sys.FileSystem.exists(file), "a 4 s gap was reported");
		now = 106.0;
		require(watchdog.check(), "a 6 s stall was not reported");
		var text = sys.io.File.getContent(file);
		require(text.indexOf("stalled for 6") >= 0 && text.indexOf("last phase: build workbench") >= 0 && text.indexOf("tick > build workbench") >= 0, "the report: " + text);
		require(!watchdog.check(), "one stall was reported twice");
		now = 110.0;
		watchdog.beat("tick");
		require(sys.io.File.getContent(file).indexOf("ticking again after 10") >= 0, "the end of the stall was not noted");
		now = 112.0;
		require(!watchdog.check(), "a ticking thread was reported");
		// The real watcher thread, with a real stall.
		var real = new devtools.HangWatchdog(haxe.io.Path.join([directory, "logs", "real.log"]), 0.4);
		real.start();
		real.beat("tick");
		real.phase("artificial stall");
		Sys.sleep(1.5);
		real.stop();
		var reported = sys.FileSystem.exists(haxe.io.Path.join([directory, "logs", "real.log"])) ? sys.io.File.getContent(haxe.io.Path.join([directory, "logs", "real.log"])) : "";
		require(reported.indexOf("last phase: artificial stall") >= 0, "the watcher thread wrote no report for a 1.5 s stall: " + reported);
		try {
			for (name in sys.FileSystem.readDirectory(haxe.io.Path.join([directory, "logs"]))) sys.FileSystem.deleteFile(haxe.io.Path.join([directory, "logs", name]));
			sys.FileSystem.deleteDirectory(haxe.io.Path.join([directory, "logs"]));
			sys.FileSystem.deleteDirectory(directory);
		} catch (_:Dynamic) {}
	}
}
