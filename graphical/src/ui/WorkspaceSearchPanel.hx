package ui;

import LayoutAxis;
import LayoutStyle;
import Insets;
import core.Application;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.SearchField;
import nativekit.ui.widgets.text.TextField;
import nativekit.ui.widgets.text.Text;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.collections.VirtualList;
import nativekit.ui.widgets.scroll.ScrollController;

/** Presentation of the existing cooperative search and transactional replacement. */
class WorkspaceSearchPanel implements View {
	final application:Application;
	final host:UiWorkbenchHost;
	final requestFrame:Void->Void;
	public var focusQuery:Bool = false;
	public final scroll = new ScrollController();
	public var replacement(default, null):String = "";
	public var previewVisible(default, null):Bool = false;
	var observedGeneration:Int = -1;
	var observedPreview:Null<search.ReplacementPreview>;
	var previewOffsets:Map<String, Int> = [];
	public function new(application:Application, host:UiWorkbenchHost, requestFrame:Void->Void) {
		this.application = application; this.host = host; this.requestFrame = requestFrame;
	}
	public function search(query:String):Void {
		previewVisible = false; application.search.clearReplacementPreview();
		application.search.workspaceSearch.request(query, application.search.options, application.settings.current.searchMaxResults);
		scroll.jumpTo(0, 0); requestFrame();
	}
	public function preview(value:String):Bool {
		replacement = value;
		previewVisible = application.search.previewWorkspaceReplacement(value);
		scroll.jumpTo(0, 0); requestFrame(); return previewVisible;
	}
	public function build(context:BuildContext):RenderNode {
		var search = application.search.workspaceSearch;
		var generation = search.generation;
		if (observedGeneration != search.generation) {
			observedGeneration = search.generation; previewVisible = false; scroll.jumpTo(0, 0);
		}
		var style = fill(); style.padding = new Insets(6, 8, 6, 8);
		var input = new SearchField("workspace-search-query", search.query, this.search, null, "Search in projects");
		var replaceStyle = new LayoutStyle(); replaceStyle.width = LayoutAxis.grow();
		var replace = new TextField("workspace-search-replacement", replacement, function(value) {
			replacement = value; previewVisible = false; application.search.clearReplacementPreview(); requestFrame();
		}, replaceStyle);
		replace.placeholder = "Replace with…";
		var previewButton = new Button("Preview replacement", null, function() preview(replacement), "workspace-search-preview");
		previewButton.enabled = search.complete && !search.capped && search.errors.length == 0 && search.results.length > 0;
		var rows:Array<KeyedView> = [new KeyedView("query", input), new KeyedView("replacement", replace),
			new KeyedView("preview", previewButton)];
		var status = search.query.length == 0 ? "Search the open projects" : search.complete ? search.results.length + " results" : "Searching… " + search.results.length + " results";
		if (search.capped) status += " (limit reached)";
		if (search.errors.length > 0) status += " — " + search.errors.length + " errors";
		rows.push(new KeyedView("status", new Text(status)));
		if (search.errors.length > 0) rows.push(new KeyedView("error", new Text(search.errors[0])));
		var snapshot = application.search.replacementPreview;
		if (previewVisible && snapshot != null) {
			if (observedPreview != snapshot) { observedPreview = snapshot; previewOffsets.clear(); }
			rows.push(new KeyedView("summary", new Text(snapshot.matchCount + " replacements in " + snapshot.files.length + " files")));
			rows.push(new KeyedView("apply", new Button("Apply preview", null, function() {
				if (application.search.replacementPreview != snapshot || search.generation != snapshot.searchGeneration) return;
				application.search.applyWorkspaceReplacement(); previewVisible = false; this.search(search.query);
			}, "workspace-search-apply")));
			rows.push(new KeyedView("results", new VirtualList("workspace-replacement-files", snapshot.files.length, 96,
				function(index) {
					var file = snapshot.files[index];
					var changed = previewOffsets.get(file.path);
					if (changed == null) { changed = firstDifference(file.originalText, file.proposedText); previewOffsets.set(file.path, changed); }
					return new Column("preview-file-" + index, [new KeyedView("path", new Text(displayPath(file.path) + " (" + file.matchCount + ")")),
						new KeyedView("before", new Text("- " + snippet(file.originalText, changed))),
						new KeyedView("after", new Text("+ " + snippet(file.proposedText, changed)))], rowStyle(96));
				}, fill(), null, scroll)));
		} else {
			rows.push(new KeyedView("results", new VirtualList("workspace-search-results", host.workspaceSearchResults.length, 48,
				function(index) {
					var match = host.workspaceSearchResults[index];
					var button = new Button(displayPath(match.path) + ":" + (match.line + 1) + ":" + (match.column + 1) + "  " + match.preview,
						rowStyle(48), function() {
							if (search.generation != generation) return;
							if (!host.activateSearchResult(index)) this.search(search.query);
							requestFrame();
						}, "workspace-search-result-" + index);
					button.accessibilityLabel = match.path + ":" + (match.line + 1) + ":" + (match.column + 1) + " " + match.preview;
					return button;
				}, fill(), null, scroll)));
		}
		var node = new Column("workspace-search-panel", rows, style).build(context);
		if (focusQuery) {
			var inputNode = findQuery(node);
			if (inputNode != null) { context.requestFocusAfterLayout(inputNode.id); focusQuery = false; }
		}
		return node;
	}
	function displayPath(path:String):String {
		for (project in application.workspace.projects) if (StringTools.startsWith(path, project.root + "/")) {
			var relative = path.substring(project.root.length + 1);
			return application.workspace.projects.length == 1 ? relative :
				project.root.substring(project.root.lastIndexOf("/") + 1) + "/" + relative;
		}
		return path;
	}
	static function findQuery(node:RenderNode):Null<RenderNode> {
		if (node.semantics != null && node.semantics.role == nativekit.ui.semantics.AccessibilityRole.TextField &&
			node.semantics.label == "Search in projects") return node;
		for (child in node.children) { var found = findQuery(child); if (found != null) return found; }
		return null;
	}
	static function firstDifference(before:String, after:String):Int {
		var offset = 0, limit = Std.int(Math.min(before.length, after.length));
		while (offset < limit && before.charCodeAt(offset) == after.charCodeAt(offset)) offset++;
		return offset;
	}
	static function snippet(value:String, offset:Int):String {
		var start = value.lastIndexOf("\n", offset > 0 ? offset - 1 : 0) + 1;
		var end = value.indexOf("\n", offset);
		if (end < 0) end = value.length;
		return value.substring(start, Std.int(Math.min(end, start + 160)));
	}
	static function rowStyle(height:Float):LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(height); return style;
	}
	static function fill():LayoutStyle {
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow(); return style;
	}
}
