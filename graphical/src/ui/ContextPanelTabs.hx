package ui;

/** Maps rail destinations and Tabs widget keys to the right panel's tabs. */
class ContextPanelTabs {
	/** The tab that shows a rail destination (`files`, `search` or `scm`). */
	public static function forDestination(destination:Null<String>):ContextPanelTab
		return destination == "search" ? ContextPanelTab.Search : destination == "scm" ? ContextPanelTab.Changes : ContextPanelTab.Files;

	/** The tab with a key the Tabs widget reported, or null for another key. */
	public static function fromKey(key:String):Null<ContextPanelTab> {
		for (tab in [ContextPanelTab.Files, ContextPanelTab.Search, ContextPanelTab.Changes]) if ((tab:String) == key) return tab;
		return null;
	}
}
