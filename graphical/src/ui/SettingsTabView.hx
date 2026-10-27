package ui;

import haxeon.ui.*;
import haxeon.ui.core.*;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;

/** Measure against the editor pane rather than the whole application window. */
class SettingsTabView implements View {
	final tab:UiSettingsTab;
	final refresh:Void->Void;
	final resolved:(Rect, WidgetId)->Void;
	public function new(tab:UiSettingsTab, refresh:Void->Void, resolved:(Rect, WidgetId)->Void) {
		this.tab = tab; this.refresh = refresh; this.resolved = resolved;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow(); style.padding = new Insets(16, 16, 16, 16);
		var node = new Column("settings-tab-content", [new KeyedView("settings", tab.panel)], style).build(context);
		var target:Null<WidgetId> = null;
		node.walk(function(child) {
			if (target == null && child.focusable && child.enabled) target = child.id;
		});
		node.onResolved(function(geometry) {
			var bounds = geometry.viewportBounds();
			var compact = bounds.width < 760;
			if (tab.panel.compact != compact) { tab.panel.compact = compact; refresh(); }
			if (target != null) resolved(bounds, target);
		});
		return node;
	}
}
