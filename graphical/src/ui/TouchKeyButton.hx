package ui;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.widgets.controls.Button;

/**
	A button that never takes keyboard focus, so pressing it leaves the terminal focused and the on-screen keyboard
	up. The ordinary Button is focusable, and focus leaving a text input hides the keyboard on a phone.
**/
class TouchKeyButton extends Button {
	public function new(label:String, ?style:LayoutStyle, ?onClick:Void->Void, ?key:String) {
		super(label, style, onClick, key);
	}

	override function buildButton(context:BuildContext, id:WidgetId):RenderNode {
		var node = super.buildButton(context, id);
		node.focusable = false;
		return node;
	}
}
