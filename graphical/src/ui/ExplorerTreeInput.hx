package ui;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeView;

/** Keep preview clicks and file operations in the explorer's focus scope. */
class ExplorerTreeInput implements View {
	final tree:TreeView;
	final onFocus:Null<Void->Void>;
	final runCommand:Null<String->Void>;
	public function new(tree:TreeView, ?onFocus:Void->Void, ?runCommand:String->Void) {
		this.tree = tree;
		this.onFocus = onFocus;
		this.runCommand = runCommand;
	}
	public function build(context:BuildContext):RenderNode {
		var root = tree.build(context);
		root.on(UiEventKind.Focus, function(_) { if (onFocus != null) onFocus(); }, "capture");
		root.on(UiEventKind.KeyDown, function(event) {
			var target = root.find(event.target);
			while (target != null && target != root) {
				if (target.semantics != null && target.semantics.role == AccessibilityRole.TextField) return;
				target = target.parent;
			}
			if (onFocus != null) onFocus();
			if (event.modifiers != 0 || runCommand == null) return;
			var command = event.key == UiKey.Delete ? "file:delete" : event.key == UiKey.F2 ? "file:rename" : null;
			if (command == null) return;
			event.preventDefault();
			event.stopPropagation();
			runCommand(command);
		}, "capture");
		return root;
	}
}
