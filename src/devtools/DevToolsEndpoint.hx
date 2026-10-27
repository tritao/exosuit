package devtools;

@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateDirectory(path:String):Bool;

/** Same-user local endpoint. NativeKit requires a private parent directory on Unix. */
class DevToolsEndpoint {
	public static function create():String {
		if (Sys.systemName() == "Windows") return "\\\\.\\pipe\\exosuit-devtools-" + Sys.getPid();
		var base = Sys.getEnv("XDG_RUNTIME_DIR");
		if (base == null || base.length == 0) base = Sys.getEnv("TMPDIR");
		if (base == null || base.length == 0 || base.length > 50) base = "/tmp";
		var directory = base + "/exosuit-devtools-" + Sys.getPid();
		if (!preparePrivateDirectory(directory)) throw "Could not create a private DevTools socket directory";
		return directory + "/ui.sock";
	}

	public static function cleanup(path:String):Void {
		if (Sys.systemName() != "Windows") {
			try sys.FileSystem.deleteDirectory(haxe.io.Path.directory(path)) catch (_:Dynamic) {}
		}
	}
}
