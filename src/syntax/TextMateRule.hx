package syntax;

class TextMateRule {
	static var nextId = 1;
	public final id:Int = nextId++;
	public final grammar:TextMateGrammar;
	public final include:Null<String>;
	public final match:Null<String>;
	public final begin:Null<String>;
	public final end:Null<String>;
	public final whilePattern:Null<String>;
	public final name:Null<String>;
	public final contentName:Null<String>;
	public final patterns:Array<TextMateRule>;
	public final captures:Map<Int, String>;
	public final beginCaptures:Map<Int, String>;
	public final endCaptures:Map<Int, String>;
	public final whileCaptures:Map<Int, String>;
	public final applyEndPatternLast:Bool;

	public function new(grammar:TextMateGrammar, raw:Dynamic) {
		this.grammar = grammar;
		include = stringField(raw, "include");
		match = stringField(raw, "match");
		begin = stringField(raw, "begin");
		end = stringField(raw, "end");
		whilePattern = stringField(raw, "while");
		name = stringField(raw, "name");
		contentName = stringField(raw, "contentName");
		patterns = grammar.parseRules(field(raw, "patterns"));
		captures = parseCaptures(field(raw, "captures"));
		beginCaptures = parseCaptures(field(raw, "beginCaptures"));
		endCaptures = parseCaptures(field(raw, "endCaptures"));
		whileCaptures = parseCaptures(field(raw, "whileCaptures"));
		applyEndPatternLast = boolField(raw, "applyEndPatternLast");
		if (include == null && match == null && begin == null && whilePattern == null && patterns.length == 0)
			throw 'TextMate rule in "${grammar.scopeName}" has no include, match, begin, or while pattern';
		if (begin != null && end == null && whilePattern == null)
			throw 'TextMate begin rule in "${grammar.scopeName}" has neither end nor while pattern';
	}

	static function field(value:Dynamic, key:String):Dynamic
		return value == null ? null : Reflect.field(value, key);

	static function stringField(value:Dynamic, key:String):Null<String> {
		var result = field(value, key);
		if (result == null) return null;
		if (!Std.isOfType(result, String)) throw 'TextMate rule field "$key" must be a string';
		return cast result;
	}

	static function boolField(value:Dynamic, key:String):Bool {
		var result = field(value, key);
		return result != null && Std.isOfType(result, Bool) ? cast result : false;
	}

	static function parseCaptures(value:Dynamic):Map<Int, String> {
		var result:Map<Int, String> = [];
		if (value == null) return result;
		for (index in 0...256) {
			var raw = Reflect.field(value, Std.string(index));
			if (raw == null) continue;
			var name = Reflect.field(raw, "name");
			if (Std.isOfType(name, String)) result.set(index, cast name);
		}
		return result;
	}
}
