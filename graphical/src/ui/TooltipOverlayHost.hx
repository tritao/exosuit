package ui;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Lift tooltip surfaces out of editor stacking contexts before layout. */
class TooltipOverlayHost implements View {
	final content:View;
	public function new(content:View) this.content = content;
	public function build(context:BuildContext):RenderNode {
		var lifted = context.state(context.id("lifted-tab-tooltips"), new Array<{tip:RenderNode, anchor:RenderNode}>()).value;
		// Retained tab headers must recover their tooltip before being reused.
		for (entry in lifted) entry.anchor.add(entry.tip.detach());
		lifted.resize(0);
		var root = content.build(context);
		var tooltips:Array<RenderNode> = [];
		root.walk(function(node) {
			if (node.styleType == "tooltip") tooltips.push(node);
		});
		for (tip in tooltips) {
			lifted.push({tip: tip, anchor: tip.parent});
			root.add(tip.detach());
		}
		return root;
	}
}
