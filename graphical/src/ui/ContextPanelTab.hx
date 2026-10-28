package ui;

/** The right panel's tabs. In the Agents layout each one stands in for an Activity Rail destination the layout hides. */
enum abstract ContextPanelTab(String) to String {
	var Files = "context-files";
	var Search = "context-search";
	var Changes = "context-changes";
}
