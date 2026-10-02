package ui;

import Rect;
import nativekit.ui.core.WidgetId;

/** One editor pane owns tab order and active view, while documents stay shared. */
class UiEditorPane {
	public final id:String;
	public final items:Array<UiEditorTab> = [];
	/** Document metadata for document-only consumers; items owns the full tab list. */
	public var tabs(get, never):Array<UiDocumentView>;
	function get_tabs():Array<UiDocumentView> {
		var result:Array<UiDocumentView> = [];
		for (item in items) {
			var view = UiEditorTabs.document(item);
			if (view != null) result.push(view);
		}
		return result;
	}
	public var activeIndex:Int = -1;
	public var bounds:Null<Rect> = null;
	public var focusTarget:Null<WidgetId> = null;

	public function new(id:String) this.id = id;

	public function activeTab():Null<UiEditorTab>
		return activeIndex >= 0 && activeIndex < items.length ? items[activeIndex] : null;

	public function activeView():Null<UiDocumentView> {
		var item = activeTab();
		return item == null ? null : UiEditorTabs.document(item);
	}
}
