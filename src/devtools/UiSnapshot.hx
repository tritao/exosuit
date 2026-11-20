package devtools;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;

/**
	What the UI shows, for a program that drives the editor (`exosuit.ui.snapshot` on the control plane, see
	ui.control.EditorControl; the phone's debug file, PhoneSnapshotFile):

	  frame                 the UI frame number
	  viewport              {width, height}: the UI's size in logical pixels
	  elements              every visible node with an accessibility label: {id, role, label, x, y, w, h} in logical
	                        viewport pixels, the coordinates synthetic input takes. Workbench tree rows are labelled
	                        with their row keys (`g:`, `w:`, ...).
	  focus                 the label of the widget with keyboard focus ("-" when none, "(unlabelled)" without a label)

	Positions come from here, never from fixed pixels.
**/
class UiSnapshot {
	public static inline var ELEMENT_LIMIT = 4000;

	public static function capture(ui:UiContext):Dynamic {
		var elements:Array<Dynamic> = [];
		var width = 0.0, height = 0.0;
		var root = ui.root;
		if (root != null) {
			try { var bounds = root.globalBounds(); width = bounds.width; height = bounds.height; } catch (_:Dynamic) {}
			root.walk(function(node:RenderNode) {
				if (elements.length >= ELEMENT_LIMIT) return;
				var semantics = node.semantics;
				if (semantics == null || semantics.label == null || semantics.label.length == 0) return;
				if (node.styleType == "devtools-overlay") return;
				var geometry = node.resolved;
				if (geometry == null || !geometry.visible) return;
				try {
					var bounds = node.globalBounds();
					if (bounds.width <= 0 || bounds.height <= 0) return;
					elements.push({id: node.id.value, role: Std.string((cast semantics.role : Int)), label: semantics.label.substr(0, 160),
						x: bounds.x, y: bounds.y, w: bounds.width, h: bounds.height});
				} catch (_:Dynamic) {}
			});
		}
		var metrics = ui.frameMetrics;
		var focusedId = ui.focus.focusedId, focusLabel = "-";
		if (focusedId != null && ui.root != null) {
			var focused = ui.root.find(focusedId);
			focusLabel = focused == null ? "(gone)" : focused.semantics != null && focused.semantics.label != null ? focused.semantics.label.substr(0, 80) : "(unlabelled)";
		}
		return {frame: metrics == null ? -1 : metrics.frameNumber, viewport: {width: width, height: height}, focus: focusLabel, elements: elements};
	}

	/** The visible node with id `id` (an element's `id`, stable across frames), or null. */
	public static function find(ui:UiContext, id:Int):Null<RenderNode> {
		var found:Null<RenderNode> = null;
		var root = ui.root;
		if (root != null)
			root.walk(function(node:RenderNode) {
				if (found == null && node.id.value == id && node.resolved != null && node.resolved.visible) found = node;
			});
		return found;
	}
}
