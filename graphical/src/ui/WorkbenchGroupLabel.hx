package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.MiddleEllipsisText;

/** One-line group name and subdued directory; accessibility keeps the complete path. */
class WorkbenchGroupLabel implements View {
	final name:String;
	final directory:Null<String>;
	final root:Null<String>;
	final running:Int;
	public function new(name:String, directory:Null<String>, root:Null<String>, running:Int) {
		this.name = name; this.directory = directory; this.root = root; this.running = running;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.childGap = 6;
		style.childAlignY = haxeon.ui.LayoutAlignmentY.Center; style.clipHorizontal = true;
		var label = name + (running > 0 ? " · " + running + " running" : "");
		var children = [new KeyedView("icon", new Icon("group-folder", IconName.FolderClosed, 14)), new KeyedView("name", new Text(label))];
		if (directory != null) {
			var path = directory;
			if (root != null && path == root) {
				var parts = path.split("/"); path = parts[parts.length - 1];
			} else if (root != null && StringTools.startsWith(path, root + "/")) path = "./" + path.substring(root.length + 1);
			else {
				var parts = path.split("/");
				if (parts.length > 2) path = "…/" + parts[parts.length - 2] + "/" + parts[parts.length - 1];
			}
			children.push(new KeyedView("directory", new MutedDirectory(path)));
		}
		var node = new Row("workbench-group-label", children, style).build(context);
		node.semantics = new Semantics(AccessibilityRole.Text);
		node.semantics.label = label + (directory == null ? "" : " · " + directory);
		return node;
	}
}

private class MutedDirectory implements View {
	final value:String;
	public function new(value:String) this.value = value;
	public function build(context:BuildContext):RenderNode {
		var node = new MiddleEllipsisText("group-directory", value, true,
			new haxeon.ui.core.TextStyleOverride(null, 12)).build(context);
		node.layout.textColor = context.theme.tokens.textSecondary;
		return node;
	}
}
