package ui;

import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;

/** Mounts an owned terminal in either host without recreating its session. */
class TerminalTabView implements View {
	final terminal:UiTerminalTab;
	final activate:Void->Void;
	final resolved:Rect->WidgetId->Void;
	final contextMenu:Null<UiEvent->Void>;

	public function new(terminal:UiTerminalTab, activate:Void->Void, resolved:Rect->WidgetId->Void, ?contextMenu:UiEvent->Void) {
		this.terminal = terminal;
		this.activate = activate;
		this.resolved = resolved;
		this.contextMenu = contextMenu;
	}

	public function build(context:BuildContext):RenderNode {
		var node = terminal.panel.build(context);
		node.on(UiEventKind.Focus, function(_) activate(), "capture");
		node.on(UiEventKind.PointerDown, function(event) {
			activate();
		}, "capture");
		node.on(UiEventKind.PointerDown, function(event) {
			if (event.defaultPrevented) return;
			var menu = contextMenu;
			if (event.button == 1 && menu != null) { menu(event); event.preventDefault(); event.stopPropagation(); }
		});
		node.onResolved(function(_) resolved(node.globalBounds(), node.id));
		return node;
	}
}
