package syntax;

import haxe.Json;

/** JSON TextMate grammar with local repository rules and references. */
class TextMateGrammar {
	public final scopeName:String;
	public final name:Null<String>;
	public final fileTypes:Array<String>;
	public final patterns:Array<TextMateRule>;
	public final repository:Map<String, TextMateRule> = [];
	var parseDepth = 0;

	public function new(source:String) {
		if (source == null || source.length == 0 || source.length > 4 * 1024 * 1024)
			throw "TextMate grammar JSON is empty or too large";
		var raw:Dynamic = Json.parse(source);
		var rawScope = Reflect.field(raw, "scopeName");
		if (!Std.isOfType(rawScope, String) || (cast rawScope:String).length == 0)
			throw "TextMate grammar requires a scopeName";
		scopeName = cast rawScope;
		var rawName = Reflect.field(raw, "name");
		name = Std.isOfType(rawName, String) ? cast rawName : null;
		fileTypes = strings(Reflect.field(raw, "fileTypes"));
		var rawRepository = Reflect.field(raw, "repository");
		if (rawRepository != null) {
			for (key in Reflect.fields(rawRepository)) {
				var ruleRaw = Reflect.field(rawRepository, key);
				if (ruleRaw != null) repository.set(key, new TextMateRule(this, ruleRaw));
			}
		}
		patterns = parseRules(Reflect.field(raw, "patterns"));
	}

	public function parseRules(raw:Dynamic):Array<TextMateRule> {
		if (raw == null) return [];
		if (!Std.isOfType(raw, Array)) throw 'TextMate grammar "$scopeName" patterns must be an array';
		var values:Array<Dynamic> = cast raw;
		if (values.length > 8192) throw 'TextMate grammar "$scopeName" contains too many patterns';
		if (parseDepth >= 64) return [];
		parseDepth++;
		var result:Array<TextMateRule> = [];
		var index = 0;
		while (index < values.length) {
			result.push(new TextMateRule(this, values[index]));
			index++;
		}
		parseDepth--;
		return result;
	}

	public function repositoryRule(name:String):Null<TextMateRule>
		return repository.get(name);

	static function strings(value:Dynamic):Array<String> {
		if (value == null) return [];
		if (!Std.isOfType(value, Array)) throw "TextMate grammar fileTypes must be an array";
		var result:Array<String> = [];
		for (item in (cast value:Array<Dynamic>))
			if (Std.isOfType(item, String)) result.push(cast item);
		return result;
	}
}
