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
import workspace.FolderLabels;
import workspace.PathKey;
import workspace.Project;
import workspace.ProjectNode;
import workspace.Workspace;

/**
	Search over the Agents layout's scope folders for the right panel: one group's folder, or every attached folder and
	group folder outside them, each result labelled by its folder when there are several. It has its own query and
	results, so the editor workspace's Search keeps its own; files come from an open project that holds a folder, else
	from a window-owned index of the folder that is never added to the workspace.
**/
class ScopedSearchPanel implements View {
	final workspace:Workspace;
	final directories:Void->Array<String>;
	final open:SearchMatch->Void;
	final requestFrame:Void->Void;
	final maximum:Void->Int;
	public final search:WorkspaceSearch;
	public final scroll = new ScrollController();
	public var focusQuery:Bool = false;
	var query:String = "";
	var searchedDirectories:String = "";
	final ownProjects:Map<String, Project> = [];
	/** The query ran over a folder index that was still filling, so it runs again once the index is complete. */
	var searchedPartial:Bool = false;
	/** The query's text input from the last build, so a focus request goes straight to it. */
	var queryInput:Null<RenderNode>;

	/** Drop the kept input node, which links the whole old tree and its handlers (GraphicalMain.liveRelease). */
	public function releaseRetained():Void
		queryInput = null;

	public function new(workspace:Workspace, directories:Void->Array<String>, open:SearchMatch->Void, requestFrame:Void->Void, maximum:Void->Int) {
		this.workspace = workspace; this.directories = directories; this.open = open; this.requestFrame = requestFrame; this.maximum = maximum;
		search = new WorkspaceSearch(workspace, workspace.jobs, requestFrame, scopedFiles);
	}

	public function update(now:Float):Void search.update(now);

	/** Runs the query again, e.g. after a result went stale because its file changed. */
	public function rerun():Void run(query);

	public function dispose():Void {
		search.cancel();
		keepProjects([]);
	}

	/** Stops indexing, and forgets, the window-owned indexes of folders not in `keep`. */
	function keepProjects(keep:Array<String>):Void {
		var wanted = [for (folder in keep) PathKey.of(folder)];
		for (key in [for (key in ownProjects.keys()) key]) {
			if (wanted.indexOf(key) >= 0) continue;
			var project = ownProjects.get(key);
			if (project != null) project.cancelIndex();
			ownProjects.remove(key);
		}
	}

	function run(value:String):Void {
		query = value == null ? "" : value;
		searchedDirectories = directories().join("
");
		searchedPartial = false;
		search.request(query, new SearchOptions(), maximum());
		scroll.jumpTo(0, 0);
		requestFrame();
	}

	/** Files of the scope folders: for each, an open project's files under it, or the window-owned index of the folder. */
	function scopedFiles():Array<ProjectNode> {
		var result:Array<ProjectNode> = [], folders = directories();
		keepProjects(folders);
		var partial = false;
		for (root in folders) {
			var files = filesOf(root);
			if (indexing(root)) partial = true;
			for (file in files) result.push(file);
		}
		searchedPartial = partial;
		return result;
	}

	function filesOf(root:String):Array<ProjectNode> {
		for (project in workspace.projects) {
			if (PathKey.same(project.root, root)) return project.files();
			if (PathKey.within(project.root, root)) return [for (file in project.files()) if (PathKey.within(root, file.path)) file];
		}
		var key = PathKey.of(root);
		var own = ownProjects.get(key);
		if (own == null) {
			try own = new Project(root, workspace.fileSystem, workspace.jobs) catch (_:Dynamic) own = null;
			if (own == null) return [];
			ownProjects.set(key, own);
		}
		return own.files();
	}

	/** Whether the window-owned index of `root` is still filling. */
	function indexing(root:String):Bool {
		var own = ownProjects.get(PathKey.of(root));
		return own != null && own.indexing();
	}

	function anyIndexing(folders:Array<String>):Bool {
		for (root in folders) if (indexing(root)) return true;
		return false;
	}

	public function build(context:BuildContext):RenderNode {
		var current = directories();
		// A new scope reruns the query there instead of showing another folder's results.
		if (query.length > 0 && (current.join("
") != searchedDirectories || searchedPartial && !anyIndexing(current))) run(query);
		var style = fill(); style.padding = new Insets(6, 8, 6, 8); style.childGap = 4;
		var rows:Array<KeyedView> = [new KeyedView("query", new QueryField(new SearchField("scoped-search-query", query, run, null, "Search in folder"),
			function(input) queryInput = input))];
		var status = current.length == 0 ? "No folder to search" : query.length == 0 ? (current.length > 1 ? "Search these folders" : "Search this folder") : search.complete
			? search.results.length + " results" : "Searching… " + search.results.length + " results";
		if (search.capped) status += " (limit reached)";
		if (anyIndexing(current)) status += " · indexing folder";
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
		var input = queryInput;
		if (focusQuery && input != null) { context.requestFocusAfterLayout(input.id); focusQuery = false; }
		return node;
	}

	/** The path inside its scope folder; with several folders it starts with the folder's name. */
	static function relative(roots:Array<String>, path:String):String {
		for (root in roots) {
			var inside = PathKey.relative(root, path);
			if (inside == null) continue;
			var shown = inside == "" ? path : inside;
			return roots.length > 1 ? FolderLabels.labels(roots)[roots.indexOf(root)] + "/" + shown : shown;
		}
		return path;
	}

	static function rowStyle(height:Float):LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(height); return style;
	}
	static function fill():LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow(); return style;
	}
}

/** Builds the search field and hands back its text input node. */
private class QueryField implements View {
	final field:SearchField;
	final built:RenderNode->Void;
	public function new(field:SearchField, built:RenderNode->Void) { this.field = field; this.built = built; }
	public function build(context:BuildContext):RenderNode {
		var node = field.build(context);
		var input = textInput(node);
		if (input != null) built(input);
		return node;
	}
	static function textInput(node:RenderNode):Null<RenderNode> {
		if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TextField) return node;
		for (child in node.children) { var found = textInput(child); if (found != null) return found; }
		return null;
	}
}
