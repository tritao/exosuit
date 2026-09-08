package config;

import sys.FileSystem;

class ApplicationPaths {
	public static function installRoot():String
		return directory(FileSystem.fullPath(Sys.executablePath()));

	public static function resource(path:String):String
		return isAbsolute(path) ? path : child(installRoot(), path);

	public static function bundledLanguageServer():String
		return child(installRoot(), "tools/haxeon-lsp");

	public static function relativeToFile(path:String, source:String):String
		return isAbsolute(path) ? path : child(directory(FileSystem.fullPath(source)), path);

	static function isAbsolute(path:String):Bool {
		if (path.length == 0) return false;
		var first = path.charAt(0);
		return first == "/" || first == "\\" || (path.length > 2 && path.charAt(1) == ":");
	}

	static function directory(path:String):String {
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\"), separator = slash > backslash ? slash : backslash;
		return separator < 0 ? "." : path.substring(0, separator);
	}

	static function child(parent:String, name:String):String
		return parent.length == 0 || parent == "/" ? parent + name : parent + "/" + name;
}
