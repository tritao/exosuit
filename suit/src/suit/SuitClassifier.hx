package suit;

import haxe.io.Path;
import suit.SuitKind;

typedef SuitClassification = {
	var kind:SuitKind;
	var root:Null<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;
	var workspace:Null<String>;
	/** A terminal host's own folder (`<state>/terminal-hosts/<key>`); null for anything else. */
	var terminalDir:Null<String>;
}

/** Recognizes exosuit processes from their command lines, for processes that never registered. */
class SuitClassifier {
	public static function classify(name:String, commandLine:String):Null<SuitClassification> {
		var arguments = split(commandLine);
		var lowered = StringTools.replace(commandLine, "\\", "/").toLowerCase();
		var exe = name.toLowerCase();
		// A `cmd /C` wrapper repeats its program's command line; it is listed only as a parent link (SuitInventory.SCANNED_NAMES).
		if (exe == "cmd.exe")
			return null;
		// First: a host runs the agent's program under another name, and in a bundle from a copy of exosuit-agent.exe.
		var hostDirectory = terminalDirectory(arguments);
		if (hostDirectory != null) {
			var found = result(SuitKind.TerminalHost);
			found.terminalDir = hostDirectory;
			found.stateDir = stateOfTerminal(hostDirectory);
			return found;
		}
		// Agent providers and editor helpers, by markers only exosuit's own launches carry (a user's `claude` in a terminal
		// has none of them, and is not adopted anyway: a shell breaks its tie to exosuit).
		if (lowered.indexOf("--permission-prompt-tool stdio") >= 0 && lowered.indexOf("stream-json") >= 0)
			return result(SuitKind.AgentProvider);
		if (lowered.indexOf("run-codex-proxy.py") >= 0 || (lowered.indexOf("codex") >= 0 && lowered.indexOf("app-server") >= 0))
			return result(SuitKind.AgentProvider);
		if (lowered.indexOf("--mode rpc") >= 0 && lowered.indexOf("pi-permissions-") >= 0)
			return result(SuitKind.AgentProvider);
		if (lowered.indexOf("haxeon-lsp") >= 0)
			return result(SuitKind.LanguageServer);
		if (lowered.indexOf("scripts/devtools.py") >= 0)
			return result(SuitKind.HelperProcess);
		// Helpers that run under a general program (node, hl) and say what they are (SuitKinds.HELPER_MARKER): the Claude
		// name bridge and the profiler bridge.
		if (lowered.indexOf(SuitKinds.HELPER_MARKER) >= 0)
			return result(SuitKind.HelperProcess);
		if (exe != "hl.exe" && exe != "hl" && exe.indexOf("exosuit") != 0)
			return null;
		if (lowered.indexOf("/haxeon/compiler/") >= 0 && lowered.indexOf(".hl") >= 0)
			return result(SuitKind.CompilerWorker);
		if (lowered.indexOf("live-host.hl") >= 0)
			return result(SuitKind.LiveHost);
		if (lowered.indexOf("haxeon-cli.hl") >= 0)
			return lowered.indexOf("--live") >= 0 ? result(SuitKind.LiveSession) : null;
		var program = programIndex(arguments, ["suit/build/host/main.hl", "exosuit-suit.hl"]);
		if (program >= 0)
			return result(SuitKind.Suit);
		program = programIndex(arguments, ["agent/build/host/main.hl", "exosuit-agent.hl"]);
		if (program < 0 && (exe == "exosuit-agent.exe" || exe == "exosuit-agent"))
			program = 0;
		if (program >= 0) {
			// The warm spare (`--spare`) until it adopts a workspace; its registry record then names the workspace.
			if (arguments.indexOf("--spare") > program)
				return result(SuitKind.WorkspaceSpare);
			// A workspace's service: `--workspace ID [--folder F]... [--scratch S]`. Its state folder and generation are
			// in its registry record.
			var workspace = arguments.indexOf("--workspace");
			if (workspace < program)
				return null;
			return {
				kind: SuitKind.WorkspaceHost,
				root: firstFolder(arguments),
				stateDir: null,
				generation: null,
				workspace: at(arguments, workspace + 1),
				terminalDir: null
			};
		}
		if (programIndex(arguments, ["graphical/build/host/main.hl", "tools/exosuit.hl"]) >= 0 || exe == "exosuit.exe" || exe == "exosuit")
			return result(SuitKind.Editor);
		return null;
	}

	/**
		The Exosuit checkout an editor's run session serves: `hl haxeon-cli.hl run --project <ROOT>/graphical/haxeon.json ...`
		(live or not, as `scripts/run.py` starts it). Null for anything else.
	**/
	public static function runSessionCheckout(name:String, arguments:Array<String>):Null<String> {
		var exe = name.toLowerCase();
		if (exe != "hl.exe" && exe != "hl" || programIndex(arguments, ["haxeon-cli.hl"]) < 0 || arguments.indexOf("run") < 0)
			return null;
		var project = arguments.indexOf("--project");
		return project < 0 ? null : checkoutOf(at(arguments, project + 1), "/graphical/haxeon.json");
	}

	/** The Exosuit checkout an editor runs from: `<ROOT>/graphical/build/host/main.hl` or its live form `live.hl`. */
	public static function editorCheckout(arguments:Array<String>):Null<String> {
		for (argument in arguments)
			for (suffix in ["/graphical/build/host/main.hl", "/graphical/build/host/live.hl"]) {
				var root = checkoutOf(argument, suffix);
				if (root != null)
					return root;
			}
		return null;
	}

	/** True for the source-tree launcher's command line: a program that runs `scripts/run.py` (python, relative or not). */
	public static function isRunScript(name:String, arguments:Array<String>):Bool {
		if (name.toLowerCase().indexOf("python") != 0)
			return false;
		for (index in 1...arguments.length) {
			var value = StringTools.replace(arguments[index], "\\", "/").toLowerCase();
			if (value == "scripts/run.py" || StringTools.endsWith(value, "/scripts/run.py"))
				return true;
		}
		return false;
	}

	/** True for a Haxeon client: HashLink running `haxeon-cli.hl` (a build, a run or a live session), which uses compiler workers. */
	public static function isHaxeonClient(name:String, arguments:Array<String>):Bool {
		var exe = name.toLowerCase();
		return (exe == "hl.exe" || exe == "hl") && programIndex(arguments, ["haxeon-cli.hl"]) >= 0;
	}

	/**
		The toolchain a HashLink process runs on: its program's folder (`<haxeon>/.tools/hashlink`), as SuitInventory.rootKey
		compares paths. A Haxeon client and the compiler workers it starts run the same hl.exe. Null when there is no program
		or it is not named by an absolute path (`hl out/haxeon-cli.hl build`, found on PATH): its toolchain is unknown.
	**/
	public static function toolchainOf(arguments:Array<String>):Null<String> {
		if (arguments.length == 0 || arguments[0].length == 0)
			return null;
		var program = StringTools.replace(arguments[0], "\\", "/");
		if (!Path.isAbsolute(program))
			return null;
		var directory = Path.directory(program);
		return directory.length == 0 ? null : SuitInventory.rootKey(directory);
	}

	/** True when `path` (a program path or an argument) lies inside the checkout `root`'s folder `child` (`haxeon`, `graphical/build`). */
	public static function inCheckout(path:Null<String>, root:String, child:String):Bool {
		if (path == null)
			return false;
		var prefix = SuitInventory.rootKey(root) + "/" + child + "/";
		return StringTools.startsWith(SuitInventory.rootKey(path), prefix);
	}

	/** `value` without `suffix` (compared with forward slashes, without case on Windows), or null when it does not end so. */
	static function checkoutOf(value:Null<String>, suffix:String):Null<String> {
		if (value == null)
			return null;
		var normalized = StringTools.replace(value, "\\", "/");
		if (normalized.length <= suffix.length || !StringTools.endsWith(normalized.toLowerCase(), suffix))
			return null;
		return normalized.substr(0, normalized.length - suffix.length);
	}

	static function result(kind:SuitKind):SuitClassification
		return {kind: kind, root: null, stateDir: null, generation: null, workspace: null, terminalDir: null};

	/** The folder after `--terminal-host` when it directly follows the program (`hl terminal-host.hl --terminal-host DIR`, or `exosuit-agent --terminal-host DIR`). */
	public static function terminalDirectory(arguments:Array<String>):Null<String> {
		var flag = arguments.indexOf("--terminal-host");
		if (flag < 1 || flag > 2)
			return null;
		if (flag == 2 && !StringTools.endsWith(arguments[1].toLowerCase(), ".hl"))
			return null;
		return at(arguments, flag + 1);
	}

	/** The workspace state folder a terminal host's folder lies in: two levels up (`<state>/terminal-hosts/<key>`). */
	public static function stateOfTerminal(directory:String):Null<String> {
		var normalized = StringTools.replace(directory, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substr(0, normalized.length - 1);
		var hosts = Path.directory(normalized);
		if (Path.withoutDirectory(hosts) != "terminal-hosts")
			return null;
		var state = Path.directory(hosts);
		return state.length == 0 ? null : state;
	}

	/** A workspace service's first `--folder`, else its `--scratch`: the folder it starts in. */
	static function firstFolder(arguments:Array<String>):Null<String> {
		var folder = arguments.indexOf("--folder");
		if (folder < 0) folder = arguments.indexOf("--scratch");
		return folder < 0 ? null : at(arguments, folder + 1);
	}

	static function at(arguments:Array<String>, index:Int):Null<String>
		return index >= 0 && index < arguments.length && arguments[index].length > 0 ? arguments[index] : null;

	static function programIndex(arguments:Array<String>, suffixes:Array<String>):Int {
		for (index in 0...arguments.length) {
			var value = StringTools.replace(arguments[index], "\\", "/").toLowerCase();
			for (suffix in suffixes)
				if (StringTools.endsWith(value, suffix))
					return index;
		}
		return -1;
	}

	/** Splits a command line the way the Microsoft C runtime does (quotes group; backslashes escape quotes). */
	public static function split(commandLine:String):Array<String> {
		var result:Array<String> = [];
		var current = new StringBuf();
		var inQuotes = false, any = false, index = 0;
		while (index < commandLine.length) {
			var c = commandLine.charAt(index);
			if (c == "\\") {
				var slashes = 0;
				while (index < commandLine.length && commandLine.charAt(index) == "\\") {
					slashes++;
					index++;
				}
				if (index < commandLine.length && commandLine.charAt(index) == "\"") {
					for (_ in 0...Std.int(slashes / 2))
						current.add("\\");
					if (slashes % 2 == 1) {
						current.add("\"");
						index++;
					}
				} else
					for (_ in 0...slashes)
						current.add("\\");
				any = true;
				continue;
			}
			if (c == "\"") {
				inQuotes = !inQuotes;
				any = true;
			} else if ((c == " " || c == "\t") && !inQuotes) {
				if (any)
					result.push(current.toString());
				current = new StringBuf();
				any = false;
			} else {
				current.add(c);
				any = true;
			}
			index++;
		}
		if (any)
			result.push(current.toString());
		return result;
	}
}
