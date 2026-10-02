package ui;

/** One editor-group tab, with content-specific state and lifecycle. */
enum UiEditorTab {
	Document(view:UiDocumentView);
	Terminal(terminal:UiTerminalTab);
}
