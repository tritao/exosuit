package command;

class Command {
	public final name:String;
	public final description:String;
	public final predicate:CommandContext->Bool;
	public final perform:CommandContext->Void;

	public function new(name:String, perform:CommandContext->Void, ?predicate:CommandContext->Bool, ?description:String) {
		this.name = name;
		this.description = description == null || StringTools.trim(description).length == 0 ? humanize(name) : description;
		this.perform = perform;
		this.predicate = predicate == null ? function(context:CommandContext) { return true; } : predicate;
	}

	static function humanize(name:String):String {
		var separator = name.indexOf(":"), group = separator < 0 ? "Command" : name.substring(0, separator),
			action = separator < 0 ? name : name.substring(separator + 1);
		group = groupName(group);
		var words = action.split("-");
		for (index in 0...words.length)
			words[index] = capitalize(words[index]);
		return group + ": " + words.join(" ");
	}

	static function groupName(group:String):String
		return switch group {
			case "doc": "Editor"; case "root": "View"; case "layout": "View"; case "workbench": "View";
			case "files": "File"; case "file": "File"; case "folder": "File"; case "project": "Project";
			case "workspace": "Project"; case "navigation": "Go"; case "settings": "Preferences";
			case "keybindings": "Preferences"; case "find": "Find"; case "language": "Language";
			case "build": "Build"; case "plugins": "Plugins"; case "recovery": "Recovery";
			case "commands": "View"; default: capitalize(group);
		};

	static function capitalize(value:String):String {
		if (value.length == 0) return value;
		var code = value.charCodeAt(0);
		return (code >= 97 && code <= 122 ? String.fromCharCode(code - 32) : value.charAt(0)) + value.substring(1);
	}
}
