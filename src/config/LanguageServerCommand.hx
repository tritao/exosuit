package config;

import sys.FileSystem;

/** Resolves argv without shell parsing; environment overrides denote one executable. */
class LanguageServerCommand {
	public static function current(settings:Settings):Array<String> {
		var bundled = ApplicationPaths.bundledLanguageServer();
		var root = Sys.getEnv("HAXEON_ROOT");
		if (root == null || root.length == 0) root = "../haxeon";
		return resolve(settings.haxeonCommand, Sys.getEnv("HAXEON_LSP"), bundled,
			FileSystem.exists(bundled) && !FileSystem.isDirectory(bundled), FileSystem.absolutePath(root));
	}

	public static function resolve(configured:Array<String>, environment:Null<String>, bundled:String,
			bundledAvailable:Bool, compilerRoot:String):Array<String> {
		if (configured.length > 0) return configured.copy();
		if (environment != null && environment.length > 0) return [environment];
		if (bundledAvailable) return [bundled];
		return [compilerRoot + "/scripts/haxeon-lsp"];
	}
}
