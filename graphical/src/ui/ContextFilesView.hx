package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.text.Text;

/** Independent tree state for the context dock; never reparents the left Files tree. */
class ContextFilesView implements View {
	final roots:Void->Array<String>;
	final identity:Void->String;
	final createModel:Array<String>->ExplorerTreeModel;
	final open:(ExplorerTreeModel, String, Bool)->Void;
	final host:UiWorkbenchHost;
	final changed:Void->Void;
	final dark:Void->Bool;
	final events:Null<haxeon.platform.event.EventPump>;
	var model:Null<ExplorerTreeModel>;
	var tree:Null<TreeView>;
	var key:String = "";
	var nextRefresh:Float = 0;
	public function new(roots:Void->Array<String>, identity:Void->String, createModel:Array<String>->ExplorerTreeModel,
		open:(ExplorerTreeModel, String, Bool)->Void, host:UiWorkbenchHost, changed:Void->Void,
		dark:Void->Bool, ?events:haxeon.platform.event.EventPump) {
		this.roots = roots; this.identity = identity; this.createModel = createModel; this.open = open;
		this.host = host; this.changed = changed; this.dark = dark; this.events = events;
	}
	public function dispose():Void { if (model != null) model.dispose(); model = null; tree = null; key = ""; }
	public function poll(now:Float):Void {
		var current = model; if (current == null) return;
		var before = current.revision();
		if (Std.isOfType(current, DirectoryTreeModel)) {
			var local:DirectoryTreeModel = cast current;
			local.pollLoads();
			if (tree != null) for (path in local.readyExpansions(now)) tree.setExpanded(path, true);
		}
		if (now >= nextRefresh) { current.refresh(); nextRefresh = now + 0.5; }
		if (current.revision() != before) changed();
	}
	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("context-files"), function() {
			var paths = roots(), next = identity() + ":" + paths.join("\n");
			if (key != next) { dispose(); key = next; }
			if (paths.length == 0) return new Text("No folders in this context.").build(context);
			if (model == null) model = createModel(paths);
			var current = model;
			current.setResourceDecorations(host.getResourceDecorations());
			var local:Null<DirectoryTreeModel> = Std.isOfType(current, DirectoryTreeModel) ? cast current : null;
			var remote:Null<WorkspaceFileTreeModel> = Std.isOfType(current, WorkspaceFileTreeModel) ? cast current : null;
			if (tree == null) {
				var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
				tree = new TreeView("context-files-tree", current, style, null, 600, null,
					[for (index in 0...current.rootCount()) current.rootKeyAt(index)], host.setSelectedExplorerPath,
					function(path) open(current, path, true));
				tree.indentWidth = 10; tree.verticalGuidesOnly = true; tree.compactLeafIndent = true;
				tree.expandOnSingleClick = true;
				tree.onItemClicked = function(path, count) open(current, path, count == 2);
				if (local != null) {
					tree.hasChildrenHint = local.hasChildrenHint;
					tree.onExpansionRequested = function(path, expanded, toggle) {
						var allowed = local.requestExpansion(path, expanded, toggle); changed(); return allowed;
					};
					tree.onExpandedChanged = local.setDirectoryExpanded;
					tree.onCollapseAll = local.cancelRequestedExpansions;
				} else if (remote != null) tree.hasChildrenHint = remote.isDirectoryKey;
			}
			return new ExplorerTreeView(tree, current, dark(), events, null, host.focusExplorer).build(context);
		});
	}
}
