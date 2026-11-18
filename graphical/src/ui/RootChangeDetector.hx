package ui;

import haxeon.ui.host.UiHostContext;

/**
	What the window's root build depends on that is not read as a tracked source: plain revisions and values of the host,
	the settings, the plugin surfaces, the problems and every open document view. `ExosuitApp.submit` asks before each
	frame whether any of them changed since the last time, and if so marks the root stale, so the frame is a full build as
	it was when they were all part of the root cache key. It compares scalars and keeps what it saw in fields reused
	across frames, so a frame in which nothing changed allocates nothing here.
**/
class RootChangeDetector {
	var first = true;
	var safeArea = 0;
	var windowControls = 0;
	var minimap = false;
	var problems = 0;
	var settings = 0;
	var decorations = 0;
	var gutterMarkers = 0;
	var resourceDecorations = 0;
	var statusItems = 0;
	var panels = 0;
	var responsiveRight = false;
	var activeView = -1;
	/** One record per open document view, in the order `UiWorkbenchHost.allViews` lists them. */
	final views:Array<SeenView> = [];
	var viewCount = 0;

	public function new() {}

	/** Records the current values; true when one differs from the last call (always on the first). */
	public function changed(host:UiWorkbenchHost, hostContext:Null<UiHostContext>, minimapEnabled:Bool, settingsRevision:Int,
			responsiveRightHidden:Bool):Bool {
		var differs = first;
		first = false;
		var nextSafeArea = hostContext == null ? 0 : hostContext.safeAreaRevision;
		var nextWindowControls = hostContext == null || hostContext.windowControls == null ? 0 : hostContext.windowControls.revision;
		var active = host.activeView();
		var nextActive = active == null ? -1 : active.id;
		if (nextSafeArea != safeArea || nextWindowControls != windowControls || minimapEnabled != minimap
			|| host.getProblems().revision != problems || settingsRevision != settings
			|| host.getPluginDecorations().revision != decorations || host.getPluginGutterMarkers().revision != gutterMarkers
			|| host.getResourceDecorations().revision != resourceDecorations || host.getPluginStatusItems().revision != statusItems
			|| host.getPluginPanels().revision != panels || responsiveRightHidden != responsiveRight || nextActive != activeView)
			differs = true;
		safeArea = nextSafeArea;
		windowControls = nextWindowControls;
		minimap = minimapEnabled;
		problems = host.getProblems().revision;
		settings = settingsRevision;
		decorations = host.getPluginDecorations().revision;
		gutterMarkers = host.getPluginGutterMarkers().revision;
		resourceDecorations = host.getResourceDecorations().revision;
		statusItems = host.getPluginStatusItems().revision;
		panels = host.getPluginPanels().revision;
		responsiveRight = responsiveRightHidden;
		activeView = nextActive;
		var index = 0;
		for (pane in host.panes) for (item in pane.items) {
			var view = UiEditorTabs.document(item);
			if (view == null) continue;
			if (index == views.length) views.push(new SeenView());
			if (views[index].update(view)) differs = true;
			index++;
		}
		if (index != viewCount) differs = true;
		viewCount = index;
		return differs;
	}
}

/** The values of one document view the root build shows: caret, selection, scroll, search marks, tab state. */
private class SeenView {
	var id = -1;
	var reveal = 0;
	var state = 0;
	var anchorLine = 0;
	var anchorColumn = 0;
	var cursorLine = 0;
	var cursorColumn = 0;
	var offsetX = 0.0;
	var offsetY = 0.0;
	var search = 0;
	var preview = false;
	var dirty = false;
	/** With `deleted`, what the tab title is made from (`editor.Document.title`), compared without building the title. */
	var path:Null<String> = null;
	var deleted = false;
	/** Line and column of each end of every range after the primary one, four numbers per range. */
	final ranges:Array<Int> = [];

	public function new() {}

	/** Records the view's values; true when one differs from what was recorded before. */
	public function update(view:UiDocumentView):Bool {
		var selection = view.selection, document = view.document;
		var nextDeleted = document.externalState == editor.ExternalState.Deleted;
		var differs = view.id != id || view.cursorRevealRevision != reveal || document.buffer.stateId != state
			|| selection.anchor.line != anchorLine || selection.anchor.column != anchorColumn
			|| selection.cursor.line != cursorLine || selection.cursor.column != cursorColumn
			|| view.scrollController.offsetX != offsetX || view.scrollController.offsetY != offsetY
			|| view.searchDecorationRevision() != search || view.preview != preview || document.dirty != dirty
			|| document.path != path || nextDeleted != deleted;
		id = view.id;
		reveal = view.cursorRevealRevision;
		state = document.buffer.stateId;
		anchorLine = selection.anchor.line;
		anchorColumn = selection.anchor.column;
		cursorLine = selection.cursor.line;
		cursorColumn = selection.cursor.column;
		offsetX = view.scrollController.offsetX;
		offsetY = view.scrollController.offsetY;
		search = view.searchDecorationRevision();
		preview = view.preview;
		dirty = document.dirty;
		path = document.path;
		deleted = nextDeleted;
		if (selection.rangeCount() > 1) {
			var all = selection.allRanges();
			var count = (all.length - 1) * 4;
			if (ranges.length != count) { differs = true; ranges.resize(count); }
			for (index in 1...all.length) {
				var range = all[index], at = (index - 1) * 4;
				if (ranges[at] != range.anchor.line || ranges[at + 1] != range.anchor.column
					|| ranges[at + 2] != range.cursor.line || ranges[at + 3] != range.cursor.column) differs = true;
				ranges[at] = range.anchor.line;
				ranges[at + 1] = range.anchor.column;
				ranges[at + 2] = range.cursor.line;
				ranges[at + 3] = range.cursor.column;
			}
		} else if (ranges.length > 0) {
			differs = true;
			ranges.resize(0);
		}
		return differs;
	}
}
