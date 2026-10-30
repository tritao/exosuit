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
import workspace.PathKey;

/** One-line group name and subdued directory; accessibility keeps the complete path and names the workspace. */
class WorkbenchGroupLabel implements View {
	final name:String;
	final directory:Null<String>;
	final root:Null<String>;
	final workspaceName:Null<String>;
	public function new(name:String, directory:Null<String>, root:Null<String>, ?workspaceName:String) {
		this.name = name; this.directory = directory; this.root = root; this.workspaceName = workspaceName;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.childGap = 6;
		style.childAlignY = haxeon.ui.LayoutAlignmentY.Center; style.clipHorizontal = true;
		var children = [
			new KeyedView("icon", new Icon("group-folder", IconName.FolderClosed, 14)),
			new KeyedView("name", new Text(name, null, null,
				haxeon.ui.core.TextStyleOverride.text(ExosuitPalette.WORKBENCH_TEXT_SIZE)))
		];
		if (directory != null) children.push(new KeyedView("directory", new MutedDirectory(shortDirectory(directory, root))));
		var row = new Row("workbench-group-label", children, style);
		var tooltip = new haxeon.ui.widgets.overlays.Tooltip("group-directory-tooltip", row,
			new Text(directory == null ? name : name + "\n" + directory), 0, 28);
		tooltip.requirePointerMovement = true;
		tooltip.fillAnchor = true;
		var node = tooltip.build(context);
		node.semantics = new Semantics(AccessibilityRole.Text);
		node.semantics.label = "Group " + name + (workspaceName == null ? "" : " in workspace " + workspaceName)
			+ (directory == null ? "" : " · " + directory);
		return node;
	}

	/**
		The short form a group row shows: the workspace root's own name, `./sub/folder` below the root, else the last two
		folders. The service may run on another machine, so a Windows-style path compares the Windows way (any case,
		either separator) wherever this app runs.
	**/
	public static function shortDirectory(directory:String, root:Null<String>):String {
		var windows = PathKey.windowsStyle(directory) || root != null && PathKey.windowsStyle(root);
		var inside = root == null ? null : PathKey.relative(root, directory, windows);
		var separator = directory.indexOf("\\") >= 0 && directory.indexOf("/") < 0 ? "\\" : "/";
		var parts = directory.split(separator).filter(function(part) return part != "");
		if (inside == "") return parts.length > 0 ? parts[parts.length - 1] : directory;
		if (inside != null) return "./" + inside;
		return parts.length > 2 ? "…" + separator + parts[parts.length - 2] + separator + parts[parts.length - 1] : directory;
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
