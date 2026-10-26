package ui;

/** Live, window-owned view state. Documents and terminal sessions keep their identity. */
class UiContextLayout {
	public final panes:Array<UiEditorPane>;
	public final activePane:UiEditorPane;
	public final panelTerminals:Array<UiTerminalTab>;
	public final hiddenTerminals:Array<UiTerminalTab>;
	public final activePanelTerminalIndex:Int;
	public final chrome:Array<String>;
	public function new(panes:Array<UiEditorPane>, activePane:UiEditorPane, panelTerminals:Array<UiTerminalTab>,
		hiddenTerminals:Array<UiTerminalTab>, activePanelTerminalIndex:Int, chrome:Array<String>) {
		this.panes = panes.copy(); this.activePane = activePane;
		this.panelTerminals = panelTerminals.copy(); this.hiddenTerminals = hiddenTerminals.copy();
		this.activePanelTerminalIndex = activePanelTerminalIndex; this.chrome = chrome;
	}
}
