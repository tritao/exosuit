package probes;

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeView;

/**
	Open point 3 (trap T11): keyboard (Right/Left) and pointer (disclosure) expansion in a `TreeView` whose
	`onExpandedChanged` does not call `requestFrame()`. Does the next frame (the one the input event schedules) show it?
	Two shapes: a tree made in every root build (explorer, ContextFilesView), and one instance inside a `RetainedView` with a
	constant revision (WorkbenchPanel, ExplorerTreeView's wrapper).
	Also: `setExpanded` from code outside any input event (a callback): does anything schedule a frame?
**/
class TreeExpansionProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(3, "tree made per build", () -> probe(fonts, false));
		Report.guard(3, "tree in a RetainedView", () -> probe(fonts, true));
	}

	static function treeStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(320);
		style.height = LayoutAxis.fixed(240);
		return style;
	}

	static function probe(fonts:FontCollection, retained:Bool):Void {
		var shape = retained ? "retained" : "per-build";
		var model = new ProbeTreeModel();
		var tree:Null<TreeView> = null;
		var expandedCalls = 0;
		var make = function():TreeView {
			var made = new TreeView("tree", model, treeStyle());
			made.onExpandedChanged = function(_, _) expandedCalls++;
			tree = made;
			return made;
		};
		var persistent = retained ? make() : null;
		var wrapper = retained ? new RetainedView("pane", function(_) return persistent, function() return "constant") : null;
		var harness = new Harness(fonts, function(_) return [retained ? (wrapper : View) : make()]);
		var root = harness.submit();
		Report.check(3, shape + ": fixture starts with group collapsed",
			Harness.hasText(root, "group") && !Harness.hasText(root, "a"), "group=" + Harness.hasText(root, "group"));
		harness.ui.focusWidget(row(root, "group").id);
		root = harness.submit();

		var builds = harness.rootBuilds, frames = harness.selfFrames;
		harness.ui.key(UiEventKind.KeyDown, UiKey.Right);
		harness.ui.key(UiEventKind.KeyUp, UiKey.Right);
		root = harness.submit();
		Report.check(3, shape + ": Right expands visibly in the next frame without requestFrame",
			Harness.hasText(root, "a"), "children shown=" + Harness.hasText(root, "a") + " expanded="
			+ tree.isExpanded("group") + " onExpandedChanged=" + expandedCalls + " rootBuilds+="
			+ (harness.rootBuilds - builds) + " selfFrames+=" + (harness.selfFrames - frames));

		builds = harness.rootBuilds;
		frames = harness.selfFrames;
		harness.ui.focusWidget(row(root, "group").id);
		harness.submit();
		harness.ui.key(UiEventKind.KeyDown, UiKey.Left);
		harness.ui.key(UiEventKind.KeyUp, UiKey.Left);
		root = harness.submit();
		Report.check(3, shape + ": Left collapses visibly in the next frame without requestFrame",
			!Harness.hasText(root, "a"), "children shown=" + Harness.hasText(root, "a") + " rootBuilds+="
			+ (harness.rootBuilds - builds) + " selfFrames+=" + (harness.selfFrames - frames));

		builds = harness.rootBuilds;
		harness.click(disclosure(root, "group"));
		root = harness.submit();
		Report.check(3, shape + ": a disclosure click expands visibly in the next frame",
			Harness.hasText(root, "a"), "children shown=" + Harness.hasText(root, "a") + " rootBuilds+="
			+ (harness.rootBuilds - builds));
		harness.ui.pointerLeave();
		root = harness.submit();

		builds = harness.rootBuilds;
		frames = harness.selfFrames;
		tree.setExpanded("group", false);
		var asked = harness.selfFrames - frames;
		Report.check(3, shape + ": setExpanded from code (no input event) does NOT ask the host for a frame",
			asked == 0, "selfFrames+=" + asked + " isDirty=" + harness.ui.isDirty());
		root = harness.submit();
		Report.check(3, shape + ": ...but the next frame someone else schedules shows it",
			!Harness.hasText(root, "a"), "children shown=" + Harness.hasText(root, "a") + " rootBuilds+="
			+ (harness.rootBuilds - builds));

		builds = harness.rootBuilds;
		frames = harness.selfFrames;
		model.changes.value = model.changes.value + 1;
		asked = harness.selfFrames - frames;
		root = harness.submit();
		Report.check(3, shape + ": a model signal bump rebuilds (root dirty) but asks for no frame itself",
			asked == 0 && harness.rootBuilds > builds, "selfFrames+=" + asked + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}

	static function row(root:RenderNode, key:String):RenderNode return Harness.first(root, AccessibilityRole.TreeItem, key);

	static function disclosure(root:RenderNode, key:String):RenderNode {
		var found:Null<RenderNode> = null;
		row(root, key).walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Button) found = node;
		});
		if (found == null) throw "No disclosure on " + key;
		return found;
	}
}
