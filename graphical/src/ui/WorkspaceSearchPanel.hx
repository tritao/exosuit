package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import core.Application;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.SearchField;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.scroll.ScrollController;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;
import controller.WorkspaceFileSearchController;

/** Presentation of local search/replacement and bounded remote workspace search. */
class WorkspaceSearchPanel implements View {
	final application:Application;
	final host:UiWorkbenchHost;
	final requestFrame:Void->Void;
	final remoteSearch:WorkspaceFileSearchController;
	final openRemoteResult:FileSearchMatch->Void;
	public var focusQuery:Bool = false;
	public final scroll = new ScrollController();
	public var replacement(default, null):String = "";
	public var previewVisible(default, null):Bool = false;
	var observedGeneration:Int = -1;
	var observedRemote:Bool = false;
	var observedPreview:Null<search.ReplacementPreview>;
	var previewOffsets:Map<String, Int> = [];
	var queryValue:String;

	public function new(application:Application, host:UiWorkbenchHost, requestFrame:Void->Void,
			remoteSearch:WorkspaceFileSearchController, openRemoteResult:FileSearchMatch->Void) {
		this.application = application;
		this.host = host;
		this.requestFrame = requestFrame;
		this.remoteSearch = remoteSearch;
		this.openRemoteResult = openRemoteResult;
		this.queryValue = application.search.workspaceSearch.query;
	}

	public function search(query:String):Void {
		queryValue = query == null ? "" : query;
		previewVisible = false;
		application.search.clearReplacementPreview();
		var isRemote = remoteSearch.search(queryValue, remoteSearch.mode, application.search.options.caseSensitive);
		if (!isRemote) {
			application.search.workspaceSearch.request(queryValue, application.search.options,
				application.settings.current.searchMaxResults);
		}
		scroll.jumpTo(0, 0);
		requestFrame();
	}

	/** Re-resolve the active source when the workspace attaches, disconnects, or changes. */
	public function workspaceAttachmentChanged():Void search(queryValue);

	public function preview(value:String):Bool {
		replacement = value;
		previewVisible = application.search.previewWorkspaceReplacement(value);
		scroll.jumpTo(0, 0);
		requestFrame();
		return previewVisible;
	}

	public function build(context:BuildContext):RenderNode {
		var search = application.search.workspaceSearch;
		if (!remoteSearch.active && queryValue != search.query) queryValue = search.query;
		var remoteActive = remoteSearch.active;
		var generation = remoteActive ? -remoteSearch.generation - 1 : search.generation;
		if (observedGeneration != generation || observedRemote != remoteActive) {
			observedGeneration = generation;
			observedRemote = remoteActive;
			previewVisible = false;
			scroll.jumpTo(0, 0);
		}
		var style = fill(); style.padding = new Insets(6, 8, 6, 8);
		var input = new SearchField("workspace-search-query", queryValue, this.search, null, "Search in projects");
		var rows:Array<KeyedView> = [new KeyedView("query", input)];
		if (remoteActive) {
			var modeButton = new Button(remoteSearch.mode == "content" ? "Contents" : "File names", null, function() {
				remoteSearch.toggleMode();
				this.search(queryValue);
			}, "workspace-search-remote-mode");
			modeButton.accessibilityLabel = remoteSearch.mode == "content"
				? "Search file contents; activate to search file names"
				: "Search file names; activate to search file contents";
			rows.push(new KeyedView("remote-mode", modeButton));
			rows.push(new KeyedView("status", new Text(remoteStatus())));
			if (remoteSearch.error != null) rows.push(new KeyedView("error", new Text(remoteSearch.error)));
			rows.push(new KeyedView("results", new VirtualList("workspace-remote-search-results", remoteSearch.results.length, 48,
				function(index) {
					var match = remoteSearch.results[index];
					var location = match.line < 0 ? "" : ":" + (match.line + 1);
					var preview = match.line < 0 ? "" : "  " + match.preview;
					var label = (match.kind == "directory" ? "Folder · " : "") + displayPath(match.path) + location + preview;
					var button = new Button(label, rowStyle(48), function() {
						if (generation != -remoteSearch.generation - 1 || !remoteSearch.active) return;
						if (openRemoteResult != null) openRemoteResult(match);
					}, "workspace-remote-search-result-" + index);
					button.accessibilityLabel = label;
					return button;
				}, fill(), null, scroll)));
		} else {
			var replaceStyle = new LayoutStyle(); replaceStyle.width = LayoutAxis.grow();
			var replace = new TextField("workspace-search-replacement", replacement, function(value) {
				replacement = value; previewVisible = false; application.search.clearReplacementPreview(); requestFrame();
			}, replaceStyle);
			replace.placeholder = "Replace with…";
			var previewButton = new Button("Preview replacement", null, function() preview(replacement), "workspace-search-preview");
			previewButton.enabled = search.complete && !search.capped && search.errors.length == 0 && search.results.length > 0;
			rows.push(new KeyedView("replacement", replace));
			rows.push(new KeyedView("preview", previewButton));
			var status = queryValue.length == 0 ? "Search the open projects" : search.complete
				? search.results.length + " results" : "Searching… " + search.results.length + " results";
			if (search.capped) status += " (limit reached)";
			if (search.errors.length > 0) status += " — " + search.errors.length + " errors";
			rows.push(new KeyedView("status", new Text(status)));
			if (search.errors.length > 0) rows.push(new KeyedView("error", new Text(search.errors[0])));
		}
		var snapshot = remoteActive ? null : application.search.replacementPreview;
		if (!remoteActive && previewVisible && snapshot != null) {
			if (observedPreview != snapshot) { observedPreview = snapshot; previewOffsets.clear(); }
			rows.push(new KeyedView("summary", new Text(snapshot.matchCount + " replacements in " + snapshot.files.length + " files")));
			rows.push(new KeyedView("apply", new Button("Apply preview", null, function() {
				if (application.search.replacementPreview != snapshot || search.generation != snapshot.searchGeneration) return;
				application.search.applyWorkspaceReplacement(); previewVisible = false; this.search(queryValue);
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
		} else if (!remoteActive) {
			rows.push(new KeyedView("results", new VirtualList("workspace-search-results", host.workspaceSearchResults.length, 48,
				function(index) {
					var match = host.workspaceSearchResults[index];
					var button = new Button(displayPath(match.path) + ":" + (match.line + 1) + ":" + (match.column + 1) + "  " + match.preview,
						rowStyle(48), function() {
							if (search.generation != generation) return;
							if (!host.activateSearchResult(index)) this.search(queryValue);
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

	function remoteStatus():String {
		if (remoteSearch.query.length == 0) return "Search the connected workspace";
		if (remoteSearch.error != null) return "Workspace search failed";
		var status = remoteSearch.complete ? remoteSearch.results.length + " results" :
			(remoteSearch.waiting ? "Waiting to search…" : "Searching…") + " " + remoteSearch.results.length + " results";
		if (remoteSearch.truncated) status += " (limit reached)";
		if (remoteSearch.skippedEntries > 0) status += " · " + remoteSearch.skippedEntries + " skipped";
		else if (!remoteSearch.complete && remoteSearch.scannedEntries > 0) status += " · " + remoteSearch.scannedEntries + " entries scanned";
		return status;
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
		if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TextField &&
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
