package terminalsession;

/** Local shell profile. The program path must be absolute. */
class TerminalProfile {
    public final program:String;
    public final arguments:Array<String>;
    public final cwd:String;
    public final environment:Map<String, String>;

    public function new(program:String, arguments:Array<String>, cwd:String,
            ?environment:Map<String, String>) {
        if (program == null || !absolute(program))
            throw "Terminal program must have an absolute path";
        this.program = program;
        this.arguments = arguments == null ? [] : arguments.copy();
        this.cwd = cwd;
        this.environment = environment == null ? null : environment.copy();
    }

    public static function shell(?cwd:String):TerminalProfile {
        if (Sys.systemName() == "Windows") return windowsShell(cwd);
        var path = Sys.getEnv("SHELL");
        if (path == null || !StringTools.startsWith(path, "/")) path = "/bin/sh";
        return new TerminalProfile(path, [], cwd);
    }

    /** Interactive CLI, without a command string injected into a shell. */
    public static function agent(provider:String, cwd:String):TerminalProfile {
        if (["codex", "claude", "pi"].indexOf(provider) < 0) throw "Unsupported terminal agent provider";
        var overrideName = "EXOSUIT_" + provider.toUpperCase() + "_BIN";
        var configured = Sys.getEnv(overrideName);
        var command = configured == null || StringTools.trim(configured) == "" ? provider : configured;
        var script = Sys.getEnv("EXOSUIT_" + provider.toUpperCase() + "_SCRIPT");
        var arguments = script == null || script.length == 0 ? [] : [script];
        var candidates:Array<String> = [];
        if (absolute(command)) candidates.push(command);
        else {
            var path = Sys.getEnv("PATH");
            var extensions = Sys.systemName() == "Windows" ? [".exe", ".cmd", ".bat", ""] : [""];
            if (path != null) for (directory in path.split(Sys.systemName() == "Windows" ? ";" : ":")) {
                if (directory.length == 0) continue;
                for (extension in extensions) candidates.push(haxe.io.Path.join([directory, command + extension]));
            }
        }
        for (candidate in candidates) {
            if (!sys.FileSystem.exists(candidate) || sys.FileSystem.isDirectory(candidate)) continue;
            var resolved = sys.FileSystem.fullPath(candidate);
            if (Sys.systemName() == "Windows" && (StringTools.endsWith(resolved.toLowerCase(), ".cmd") || StringTools.endsWith(resolved.toLowerCase(), ".bat"))) {
                var processor = Sys.getEnv("ComSpec");
                if (processor == null || !absolute(processor)) throw "Command processor is unavailable";
                if (arguments.length > 0) throw "Script overrides require an executable rather than a command shim";
                // NativeKit quotes each argument for the C runtime (a path with spaces becomes "path"), and cmd /c keeps
                // a lone quoted program path. Hand-written ""path"" quoting reached cmd escaped as \"\" and failed.
                return new TerminalProfile(processor, ["/d", "/c", resolved], cwd);
            }
            return new TerminalProfile(resolved, arguments, cwd);
        }
        throw 'The $provider CLI was not found on the workspace host PATH';
    }

    /** PowerShell 7 from PATH, then Windows PowerShell, then the command processor. */
    static function windowsShell(?cwd:String):TerminalProfile {
        var path = Sys.getEnv("PATH");
        if (path != null)
            for (directory in path.split(";")) {
                if (directory.length == 0) continue;
                var candidate = haxe.io.Path.join([directory, "pwsh.exe"]);
                if (absolute(candidate) && sys.FileSystem.exists(candidate))
                    return new TerminalProfile(candidate, ["-NoLogo"], cwd);
            }
        var root = Sys.getEnv("SystemRoot");
        if (root != null) {
            var powershell = root + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
            if (sys.FileSystem.exists(powershell))
                return new TerminalProfile(powershell, ["-NoLogo"], cwd);
        }
        var processor = Sys.getEnv("ComSpec");
        if (processor == null || !absolute(processor))
            processor = (root == null ? "C:\\Windows" : root) + "\\System32\\cmd.exe";
        return new TerminalProfile(processor, [], cwd);
    }

    /** POSIX paths start at the root; Windows paths start at a drive or UNC share. */
    static function absolute(path:String):Bool {
        if (Sys.systemName() != "Windows") return StringTools.startsWith(path, "/");
        return ~/^[A-Za-z]:[\\\/]/.match(path) || StringTools.startsWith(path, "\\\\");
    }

    public function copy():TerminalProfile
        return new TerminalProfile(program, arguments, cwd, environment);

    /** Snapshot the parent environment and apply terminal-specific settings. */
    public function childEnvironment():Array<String> {
        var inherited = Sys.environment();
        inherited.remove("NO_COLOR");
        inherited.set("TERM", "xterm-256color");
        if (environment != null)
            for (name in environment.keys()) {
                if (name == "NO_COLOR" || name == "TERM") continue;
                if (name.length == 0 || name.indexOf("=") >= 0 || name.indexOf(String.fromCharCode(0)) >= 0)
                    throw "Invalid terminal environment name";
                var value = environment.get(name);
                if (value == null || value.indexOf(String.fromCharCode(0)) >= 0)
                    throw "Invalid terminal environment value";
                inherited.set(name, value);
            }
        var result:Array<String> = [];
        for (name in inherited.keys()) result.push(name + "=" + inherited.get(name));
        return result;
    }
}
