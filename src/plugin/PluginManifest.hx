package plugin;

import sys.io.File;

class PluginManifest {
	public static inline final MANIFEST_VERSION = 1;
	public static inline final API_VERSION = 2;
	public final path:String;
	public var manifestVersion(default, null):Int = 0;
	public var apiVersion(default, null):Int = 0;
	public var id(default, null):String = "";
	public var version(default, null):String = "";
	public var entry(default, null):String = "Main";
	public final sources:Array<String> = [];
	public final commands:Array<DynamicCommand> = [];
	public final syntaxes:Array<DynamicSyntax> = [];

	public function new(path:String) {
		this.path = path;
		parse(File.getContent(path));
		if (id.length == 0)
			throw 'plugin manifest "$path" has no id';
		if (sources.length == 0)
			throw 'plugin manifest "$path" has no sources';
		if (manifestVersion != MANIFEST_VERSION)
			throw 'plugin manifest "$path" requires manifestVersion=${MANIFEST_VERSION}, got $manifestVersion';
		if (apiVersion != API_VERSION)
			throw 'plugin manifest "$path" requires apiVersion=${API_VERSION}, got $apiVersion';
	}

	function parse(content:String):Void {
		for (line in content.split("\n")) {
			var value = StringTools.trim(line);
			if (value.length == 0 || StringTools.startsWith(value, "#"))
				continue;
			var separator = value.indexOf("=");
			if (separator <= 0)
				throw 'invalid plugin manifest line: "$value"';
			var key = StringTools.trim(value.substring(0, separator)),
				setting = StringTools.trim(value.substring(separator + 1));
			if (key == "manifestVersion")
				manifestVersion = Std.parseInt(setting) ?? 0;
			else if (key == "apiVersion")
				apiVersion = Std.parseInt(setting) ?? 0;
			else if (key == "id")
				id = setting;
			else if (key == "version")
				version = setting;
			else if (key == "entry")
				entry = setting;
			else if (key == "source")
				sources.push(resolve(setting));
			else if (key == "command")
				parseCommand(setting);
			else if (key == "syntax")
				parseSyntax(setting);
			else
				throw 'unknown plugin manifest key "$key"';
		}
	}

	function parseSyntax(value:String):Void {
		var fields = value.split("|");
		if (fields.length != 5)
			throw 'plugin syntax must be name|extensions|keywords|types|literals';
		syntaxes.push(new DynamicSyntax(fields[0], list(fields[1]), list(fields[2]), list(fields[3]), list(fields[4])));
	}

	static function list(value:String):Array<String>
		return value.length == 0 ? [] : value.split(",");

	function parseCommand(value:String):Void {
		var fields = value.split("|");
		if (fields.length != 4)
			throw 'plugin command must be name|function|key|modifiers';
		commands.push(new DynamicCommand(fields[0], fields[1], Std.parseInt(fields[2]) ?? 0, Std.parseInt(fields[3]) ?? 0));
	}

	function resolve(value:String):String {
		if (StringTools.startsWith(value, "/"))
			return value;
		var separator = path.lastIndexOf("/");
		return separator < 0 ? value : path.substring(0, separator + 1) + value;
	}
}
