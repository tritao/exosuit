package ui;

/** The right panel's tabs. In the Agents layout each one stands in for an Activity Rail destination the layout hides. */
enum abstract ContextPanelTab(String) to String {
	var Files = "context-files";
	var Search = "context-search";
	var Changes = "context-changes";

	/** The tab that shows a rail destination (`files`, `search` or `scm`). */
	public static function forDestination(destination:Null<String>):ContextPanelTab
		return destination == "search" ? Search : destination == "scm" ? Changes : Files;

	/** The tab with a key the Tabs widget reported, or null for another key. */
	public static function fromKey(key:String):Null<ContextPanelTab>
		return key == (Files:String) ? Files : key == (Search:String) ? Search : key == (Changes:String) ? Changes : null;
}
