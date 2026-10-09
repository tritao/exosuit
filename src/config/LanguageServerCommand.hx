package config;

import sys.FileSystem;

/** Resolves argv without shell parsing; environment overrides denote one executable. */
class LanguageServerCommand {
	public static function current(settings:Settings):Array<String> {
		if (settings.haxeonCommand.length == 0) {
			var pinned = Sys.getEnv("EXOSUIT_HAXEON_LSP_COMMAND");
			if (pinned != null && pinned.length > 0) return parsePinnedCommand(pinned);
		}
		var bundled = ApplicationPaths.bundledLanguageServer();
		var root = Sys.getEnv("HAXEON_ROOT");
		if (root == null || root.length == 0) root = findCompilerRoot(ApplicationPaths.installRoot());
		if (root == null) root = findCompilerRoot(Sys.getCwd());
		if (root == null) root = "haxeon";
		return resolve(settings.haxeonCommand, Sys.getEnv("HAXEON_LSP"), bundled,
			FileSystem.exists(bundled) && !FileSystem.isDirectory(bundled), FileSystem.absolutePath(root));
	}

	/** CLI launches run from the manifest folder, which may be below the checkout root. */
	public static function findCompilerRoot(start:String):Null<String> {
		var directory = FileSystem.absolutePath(start);
		while (true) {
			var candidate = directory + "/haxeon";
			if (FileSystem.exists(candidate + "/scripts/haxeon-lsp") && !FileSystem.isDirectory(candidate + "/scripts/haxeon-lsp")) return candidate;
			var parent = haxe.io.Path.directory(directory);
			if (parent == directory || parent.length == 0) break;
			directory = parent;
		}
		return null;
	}

	static function parsePinnedCommand(value:String):Array<String> {
		var decoded:Dynamic;
		try decoded = haxe.Json.parse(value) catch (_:Dynamic)
			throw "EXOSUIT_HAXEON_LSP_COMMAND must be a JSON array of command arguments";
		if (!Std.isOfType(decoded, Array))
			throw "EXOSUIT_HAXEON_LSP_COMMAND must be a JSON array of command arguments";
		var result:Array<String> = [];
		for (argument in (cast decoded : Array<Dynamic>)) {
			if (!Std.isOfType(argument, String) || (cast argument : String).length == 0)
				throw "EXOSUIT_HAXEON_LSP_COMMAND must contain non-empty strings";
			result.push(cast argument);
		}
		if (result.length == 0)
			throw "EXOSUIT_HAXEON_LSP_COMMAND cannot be empty";
		return result;
	}

	public static function resolve(configured:Array<String>, environment:Null<String>, bundled:String,
			bundledAvailable:Bool, compilerRoot:String):Array<String> {
		if (configured.length > 0) return configured.copy();
		if (environment != null && environment.length > 0) return [environment];
		if (bundledAvailable) return [bundled];
		return [compilerRoot + "/scripts/haxeon-lsp"];
	}
}
