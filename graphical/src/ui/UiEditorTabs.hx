package ui;

class UiEditorTabs {
	public static function document(tab:UiEditorTab):Null<UiDocumentView>
		return switch tab {
			case Document(view): view;
			case Terminal(_), Agent(_), WorkspaceFile(_): null;
		};

	public static function workspaceFile(tab:UiEditorTab):Null<UiWorkspaceFileTab>
		return switch tab {
			case WorkspaceFile(value): value;
			case _: null;
		};

	public static function agent(tab:UiEditorTab):Null<UiAgentTab>
		return switch tab {
			case Agent(value): value;
			case _: null;
		};

	public static function terminal(tab:UiEditorTab):Null<UiTerminalTab>
		return switch tab {
			case Document(_), Agent(_), WorkspaceFile(_): null;
			case Terminal(value): value;
		};

	public static function key(tab:UiEditorTab):String
		return switch tab {
			case Document(view): "doc:" + view.document.id;
			case Terminal(value): "terminal:" + value.id;
			case Agent(value): "agent:" + value.id;
			case WorkspaceFile(value): value.id;
		};

	public static function dispose(tab:UiEditorTab):Void
		switch tab {
			case Document(view):
				view.dispose();
			case Terminal(value):
				value.dispose();
			case Agent(_), WorkspaceFile(_):
		}
}
