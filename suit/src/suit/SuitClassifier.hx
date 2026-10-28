package suit;

import haxe.io.Path;

typedef SuitClassification = {
	var kind:SuitKind;
	var root:Null<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;
}

/** Recognizes exosuit processes from their command lines, for processes that never registered. */
class SuitClassifier {
	public static function classify(name:String, commandLine:String):Null<SuitClassification> {
		var arguments = split(commandLine);
		var lowered = StringTools.replace(commandLine, "\\", "/").toLowerCase();
		var exe = name.toLowerCase();
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
			var manager = arguments.indexOf("--manager");
			if (manager > program) {
				var stateIndex = arguments.indexOf("--state-dir");
				var generationIndex = arguments.indexOf("--generation");
				return {
					kind: SuitKind.WorkspaceManager,
					root: at(arguments, manager + 1),
					stateDir: stateIndex > 0 ? at(arguments, stateIndex + 1) : null,
					generation: generationIndex > 0 ? at(arguments, generationIndex + 1) : null
				};
			}
			// The daemon: SOCKET PORT CREDENTIAL SEED [DATABASE [ROOT [INSTANCE ...]]].
			var credential = at(arguments, program + 3);
			return {
				kind: SuitKind.WorkspaceHost,
				root: at(arguments, program + 6),
				stateDir: credential == null ? null : Path.directory(credential),
				generation: at(arguments, program + 7)
			};
		}
		if (programIndex(arguments, ["graphical/build/host/main.hl", "tools/exosuit.hl"]) >= 0 || exe == "exosuit.exe" || exe == "exosuit")
			return result(SuitKind.Editor);
		return null;
	}

	static function result(kind:SuitKind):SuitClassification
		return {kind: kind, root: null, stateDir: null, generation: null};

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
