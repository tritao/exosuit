package completion;

class CompletionItem {
	public final label:String;
	public final detail:String;
	public final insertText:String;
	public final filterText:String;
	/** LSP CompletionItemKind; zero means unspecified. */
	public final kind:Int;
	public final documentation:String;

	public function new(label:String, detail:String = "", ?insertText:String, ?filterText:String, kind:Int = 0, documentation:String = "") {
		this.kind = kind;
		this.documentation = documentation;
		this.label = label;
		this.detail = detail;
		this.insertText = insertText == null ? label : insertText;
		this.filterText = filterText == null ? label : filterText;
	}

	public function kindLabel():String return switch (kind) {
		case 2: "method";
		case 3: "fn";
		case 4: "ctor";
		case 5: "field";
		case 6: "var";
		case 7: "class";
		case 8: "iface";
		case 9: "module";
		case 10: "prop";
		case 12: "value";
		case 13: "enum";
		case 14: "word";
		case 15: "snippet";
		case 17: "file";
		case 20: "enum";
		case 21: "const";
		case 22: "struct";
		case 25: "type";
		default: "";
	};

	/** A provider often repeats the label as detail; don't render it twice. */
	public function displayDetail():String {
		var value = StringTools.trim(detail);
		return value == label ? "" : value;
	}

	/** Preserve provider ranking and item identity when narrowing suggestions. */
	public static function matching(items:Array<CompletionItem>, prefix:String):Array<CompletionItem> {
		var query = prefix.toLowerCase();
		return [for (item in items) if (StringTools.startsWith(item.filterText.toLowerCase(), query)) item];
	}
}
