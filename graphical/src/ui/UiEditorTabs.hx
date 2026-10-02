package ui;

class UiEditorTabs {
	public static function document(tab:UiEditorTab):Null<UiDocumentView>
		return switch tab { case Document(view): view; case Terminal(_): null; };

	public static function terminal(tab:UiEditorTab):Null<UiTerminalTab>
		return switch tab { case Document(_): null; case Terminal(value): value; };

	public static function key(tab:UiEditorTab):String
		return switch tab { case Document(view): "doc:" + view.document.id; case Terminal(value): "terminal:" + value.id; };

	public static function dispose(tab:UiEditorTab):Void
		switch tab { case Document(view): view.dispose(); case Terminal(value): value.dispose(); }
}
