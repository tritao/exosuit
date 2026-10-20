package process;

#if !wasm
import sys.FileSystem;
#end

class ExecutablePath {
	/**
		Resolve a bare command name for process launch. Windows CreateProcess only searches PATH for
		.exe, so npm shims such as codex.cmd are found here using PATHEXT. Other platforms, and names
		that already contain a directory, are returned unchanged.
	**/
	public static function resolve(name:String):String {
		#if wasm
		return name;
		#else
		if (Sys.systemName() != "Windows" || name.indexOf("/") >= 0 || name.indexOf("\\") >= 0) return name;
		var path = Sys.getEnv("PATH");
		if (path == null) return name;
		var extensions = Sys.getEnv("PATHEXT");
		var suffixes = name.indexOf(".") >= 0 ? [""] : (extensions == null ? ".COM;.EXE;.BAT;.CMD" : extensions).split(";");
		for (directory in path.split(";")) {
			while (StringTools.endsWith(directory, "\\") || StringTools.endsWith(directory, "/"))
				directory = directory.substr(0, directory.length - 1);
			if (directory.length == 0) continue;
			for (suffix in suffixes) {
				// cmd.exe runs .cmd shims and can misread a forward slash as a switch.
				var candidate = directory + "\\" + name + suffix.toLowerCase();
				if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) return candidate;
			}
		}
		return name;
		#end
	}
}
