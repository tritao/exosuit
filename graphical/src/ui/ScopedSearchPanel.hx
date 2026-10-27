package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.SearchField;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import search.SearchMatch;
import search.SearchOptions;
import search.WorkspaceSearch;
import workspace.Project;
import workspace.ProjectNode;
import workspace.Workspace;

/**
	Search over one folder for the Agents layout's right panel. It has its own query and results, so the editor
	workspace's Search keeps its own; files come from an open project that holds the folder, else from a window-owned
	index of the folder that is never added to the workspace.
**/
class ScopedSearchPanel implements View {
	final workspace:Workspace;
	final directory:Void->Null<String>;
	final open:SearchMatch->Void;
	final requestFrame:Void->Void;
	final maximum:Void->Int;
	public final search:WorkspaceSearch;
	public final scroll = new ScrollController();
	public var focusQuery:Bool = false;
	var query:String = "";
	var searchedDirectory:Null<String>;
	var ownProject:Null<Project>;
	/** The query ran over a folder index that was still filling, so it runs again once the index is complete. */
	var searchedPartial:Bool = false;

	public function new(workspace:Workspace, directory:Void->Null<String>, open:SearchMatch->Void, requestFrame:Void->Void, maximum:Void->Int) {
		this.workspace = workspace; this.directory = directory; this.open = open; this.requestFrame = requestFrame; this.maximum = maximum;
		search = new WorkspaceSearch(workspace, workspace.jobs, requestFrame, scopedFiles);
	}

	public function update(now:Float):Void search.update(now);

	/** Runs the query again, e.g. after a result went stale because its file changed. */
	public function rerun():Void run(query);

	public function dispose():Void {
		search.cancel();
		if (ownProject != null) ownProject.cancelIndex();
		ownProject = null;
	}

	function run(value:String):Void {
		query = value == null ? "" : value;
		searchedDirectory = directory();
		searchedPartial = false;
		search.request(query, new SearchOptions(), maximum());
		scroll.jumpTo(0, 0);
		requestFrame();
	}

	/** Files of the scope folder: an open project's files under it, or the window-owned index of the folder. */
	function scopedFiles():Array<ProjectNode> {
		var root = directory();
		if (root == null) return [];
		for (project in workspace.projects) {
			if (same(project.root, root)) return project.files();
			if (within(project.root, root)) return [for (file in project.files()) if (within(root, file.path)) file];
		}
		if (ownProject == null || !same(ownProject.root, root)) {
			if (ownProject != null) ownProject.cancelIndex();
			ownProject = null;
			try {
				ownProject = new Project(root, workspace.fileSystem, workspace.jobs);
			} catch (_:Dynamic) {
				return [];
			}
		}
		var project = ownProject;
		if (project == null) return [];
		searchedPartial = project.indexing();
		return project.files();
	}

	static function key(path:String):String {
		var value = StringTools.replace(path, "\\", "/");
		return Sys.systemName() == "Windows" ? value.toLowerCase() : value;
	}
	static function same(left:String, right:String):Bool return key(left) == key(right);
	static function within(parent:String, child:String):Bool {
		var prefix = key(parent);
		if (!StringTools.endsWith(prefix, "/")) prefix += "/";
		return StringTools.startsWith(key(child), prefix);
	}

	public function build(context:BuildContext):RenderNode {
		var current = directory();
		// A new scope reruns the query there instead of showing another folder's results.
		var partial = ownProject;
		if (query.length > 0 && (current != searchedDirectory || searchedPartial && partial != null && !partial.indexing())) run(query);
		var style = fill(); style.padding = new Insets(6, 8, 6, 8); style.childGap = 4;
		var rows:Array<KeyedView> = [new KeyedView("query", new SearchField("scoped-search-query", query, run, null, "Search in folder"))];
		var status = current == null ? "No folder to search" : query.length == 0 ? "Search this folder" : search.complete
			? search.results.length + " results" : "Searching… " + search.results.length + " results";
		if (search.capped) status += " (limit reached)";
		var indexed = ownProject;
		if (indexed != null && indexed.indexing() && current != null && same(indexed.root, current)) status += " · indexing folder";
		if (search.errors.length > 0) status += " — " + search.errors.length + " skipped";
		rows.push(new KeyedView("status", new Text(status)));
		var generation = search.generation;
		rows.push(new KeyedView("results", new VirtualList("scoped-search-results", search.results.length, 48, function(index) {
			var match = search.results[index];
			var label = relative(current, match.path) + ":" + (match.line + 1) + ":" + (match.column + 1) + "  " + match.preview;
			var button = new Button(label, rowStyle(48), function() {
				if (search.generation == generation) open(match);
				requestFrame();
			}, "scoped-search-result-" + index);
			button.accessibilityLabel = match.path + ":" + (match.line + 1) + ":" + (match.column + 1) + " " + match.preview;
			return button;
		}, fill(), null, scroll)));
		var node = new Column("scoped-search-panel", rows, style).build(context);
		if (focusQuery) {
			var input = findQuery(node);
			if (input != null) { context.requestFocusAfterLayout(input.id); focusQuery = false; }
		}
		return node;
	}

	static function relative(root:Null<String>, path:String):String
		return root != null && within(root, path) ? StringTools.replace(path, "\\", "/").substring(key(root).length + (StringTools.endsWith(key(root), "/") ? 0 : 1)) : path;

	static function findQuery(node:RenderNode):Null<RenderNode> {
		if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TextField
			&& node.semantics.label == "Search in folder") return node;
		for (child in node.children) { var found = findQuery(child); if (found != null) return found; }
		return null;
	}

	static function rowStyle(height:Float):LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(height); return style;
	}
	static function fill():LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow(); return style;
	}
}
