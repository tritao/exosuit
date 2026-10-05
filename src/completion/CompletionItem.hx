package completion;

class CompletionItem {
	public final label:String;
	public final detail:String;
	public final insertText:String;
	public final filterText:String;

	public function new(label:String, detail:String = "", ?insertText:String, ?filterText:String) {
		this.label = label;
		this.detail = detail;
		this.insertText = insertText == null ? label : insertText;
		this.filterText = filterText == null ? label : filterText;
	}

	/** Preserve provider ranking and item identity when narrowing suggestions. */
	public static function matching(items:Array<CompletionItem>, prefix:String):Array<CompletionItem> {
		var query = prefix.toLowerCase();
		return [for (item in items) if (StringTools.startsWith(item.filterText.toLowerCase(), query)) item];
	}
}
