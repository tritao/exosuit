package ui;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A row's label unchanged, reporting the node it builds so the panel can find the row under the pointer. */
class WorkbenchRowProbe implements View {
	final label:View;
	final built:RenderNode->Void;

	public function new(label:View, built:RenderNode->Void) {
		this.label = label; this.built = built;
	}

	public function build(context:BuildContext):RenderNode {
		var node = label.build(context);
		built(node);
		return node;
	}
}
