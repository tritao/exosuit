package ui;

/** One editor-group tab, with content-specific state and lifecycle. */
enum UiEditorTab {
	Document(view:UiDocumentView);
	Image(image:UiImageTab);
	UnsupportedFile(file:UiUnsupportedFileTab);
	Terminal(terminal:UiTerminalTab);
 Agent(agent:UiAgentTab);
	WorkspaceFile(file:UiWorkspaceFileTab);
}
