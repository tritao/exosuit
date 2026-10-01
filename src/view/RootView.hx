package view;

import build.BuildDiagnostic;
import build.BuildOutput;
import commandview.CommandViewProvider;
import completion.CompletionItem;
import core.DocumentManager;
import core.FileActions;
import core.FocusManager;
import core.WelcomeActions;
import core.WorkbenchHost;
import editor.Document;
import editor.EditorView;
import language.SignatureHelp;
import style.Theme;
import workspace.Workspace;
import commandview.CommandView;
import search.DocumentSearch;
import search.SearchMatch;
import sys.FileSystem;
import editor.BufferPosition;
import feedback.NotificationCenter;
import feedback.NotificationKind;
import feedback.Problem;
import config.Settings;
import platform.Native;
import plugin.PluginPanelRegistry;
import plugin.PluginDecorationRegistry;
import plugin.PluginStatusRegistry;
import platform.TextInputArea;
import feedback.ProblemRegistry;

class RootView implements WorkbenchHost {
	public static inline final TAB_WIDTH = 180;
	public final node:view.LayoutNode;
	public var tabs(get, never):TabGroup;
	public var activeLeaf(default, null):view.LayoutNode;
	public final renderer:renderer.Renderer;
	public final theme:Theme;
	final focus:FocusManager;
	final documents:DocumentManager;
	public final workspace:Workspace;
	public final sidebar:Sidebar;
	public final searchSidebar:SearchSidebar;
	public final commandView:CommandView;
	public final welcome:WelcomeView;
	public final contextMenu:ContextMenu;
	public final languagePopup:AnchoredPopup;
	public final problems:ProblemRegistry;
	public var createFileRequest:Void->Void = function() {};
	public var createFolderRequest:Void->Void = function() {};
	public var renameFileRequest:Void->Void = function() {};
	public var deleteFileRequest:Void->Void = function() {};
	var problemActivationHandler:Problem->Void = function(problem) {};
	var buildDiagnosticHandler:BuildDiagnostic->Void = function(diagnostic) {};
	public var searchVisible(default, null):Bool = false;
	public final notifications:NotificationCenter;
	public final status:StatusView;
	public final pluginPanels:PluginPanelRegistry;
	public final pluginDecorations:PluginDecorationRegistry;
	public final pluginStatusItems:PluginStatusRegistry;
	public var sidebarVisible(default, null):Bool = true;
	public var displayScaleMilli(default, null):Int;
	public var closeRequest:Void->Void;
	var width:Int;
	var height:Int;
	var draggingDivider:Null<view.LayoutNode>;
	var draggingSidebar:Bool = false;
	var pointerX:Int = -1;
	var pointerY:Int = -1;
	var draggedTabLeaf:Null<view.LayoutNode>;
	var draggedTabView:Null<View>;
	var draggedTabStartX:Int = 0;
	var draggedTabStartY:Int = 0;
	var draggingTab:Bool = false;

	public function new(renderer:renderer.Renderer, theme:Theme, focus:FocusManager, workspace:Workspace, width:Int, height:Int, ?settings:Settings) {
		this.renderer = renderer;
		this.theme = theme;
		this.focus = focus;
		this.workspace = workspace;
		this.documents = workspace.documents;
		sidebar = new Sidebar(workspace);
		searchSidebar = new SearchSidebar();
		commandView = new CommandView();
		welcome = new WelcomeView();
		contextMenu = new ContextMenu();
		languagePopup = new AnchoredPopup();
		problems = new ProblemRegistry();
		notifications = new NotificationCenter();
		pluginPanels = new PluginPanelRegistry();
		pluginDecorations = new PluginDecorationRegistry();
		pluginStatusItems = new PluginStatusRegistry();
		status = new StatusView(renderer, theme, settings == null ? new Settings() : settings, pluginStatusItems, problems);
		closeRequest = function() {};
		this.width = width;
		this.height = height;
		displayScaleMilli = Native.window_display_scale_milli(renderer.window);
		node = new view.LayoutNode(focus, documents);
		activeLeaf = node;
		setNodeBounds();
	}

	function get_tabs():TabGroup
		return activeLeaf.tabs;

	public function activateLeaf(leaf:view.LayoutNode):Void {
		if (!leaf.isLeaf()) throw "only leaf nodes can receive focus";
		activeLeaf = leaf;
		focus.activate(leaf.tabs.activeView);
	}

	public function focusPane(horizontal:Int, vertical:Int):Bool {
		var target = neighboringLeaf(activeLeaf, horizontal, vertical);
		if (target == null) return false;
		activateLeaf(target);
		return true;
	}

	public function moveActiveTab(horizontal:Int, vertical:Int):Bool {
		var source = activeLeaf, target = neighboringLeaf(source, horizontal, vertical), moving = source.tabs.activeView;
		if (target == null || moving == null) return false;
		var document = moving.getDocument();
		if (document != null) {
			for (view in target.tabs.views)
				if (view.getDocument() == document) {
					source.tabs.close(moving, true);
					activateLeaf(target);
					target.tabs.setActive(view);
					return true;
				}
		}
		if (!source.tabs.detach(moving)) return false;
		activateLeaf(target);
		target.tabs.add(moving);
		moving.setBounds(target.x, target.y, target.width, target.height);
		return true;
	}

	public function reorderActiveTab(delta:Int):Bool return tabs.reorderActive(delta);

	public function openDocument(document:Document):View {
		if (document.hasBackingPath()) sidebar.selectPath(document.requirePath());
		var existing = node.findDocument(document);
		if (existing != null) {
			var leaf = leafForView(node, existing);
			if (leaf != null) activateLeaf(leaf);
			tabs.setActive(existing);
			return existing;
		}
		var view = new DocumentView(document, renderer, theme, activeLeaf.width, activeLeaf.height, pluginDecorations);
		view.setBounds(activeLeaf.x, activeLeaf.y, activeLeaf.width, activeLeaf.height);
		return tabs.add(view);
	}

	public function openAuxiliary(view:View):View {
		view.setBounds(activeLeaf.x, activeLeaf.y, activeLeaf.width, activeLeaf.height);
		return tabs.add(view);
	}

	public function splitActive(kind:LayoutKind, newFirst:Bool = false):Bool {
		if (kind == LayoutKind.Leaf) return false;
		var sourceView = tabs.activeView, created = activeLeaf.split(kind, newFirst);
		if (sourceView != null) {
			var document = sourceView.getDocument();
			if (document != null)
				created.tabs.add(new DocumentView(document, renderer, theme, created.width, created.height, pluginDecorations));
		}
		activateLeaf(created);
		return true;
	}

	public function closeActiveTab(force:Bool = false):Bool {
		var view = tabs.activeView;
		if (view == null || !tabs.close(view, force)) return false;
		var document = view.getDocument();
		if (document != null && !node.containsDocument(document))
			documents.close(document, true);
		return true;
	}

	public function documentsLostByClosingActiveTab():Array<Document> {
		var view = tabs.activeView;
		if (view == null) return [];
		var document = view.getDocument();
		return document != null && !containsDocumentExcept(node, document, [view]) ? [document] : [];
	}

	public function documentsLostByClosingActivePane():Array<Document> {
		if (activeLeaf == node) return [];
		var result:Array<Document> = [], excluded = activeLeaf.tabs.views;
		for (view in excluded) {
			var document = view.getDocument();
			if (document != null && result.indexOf(document) < 0 && !containsDocumentExcept(node, document, excluded)) result.push(document);
		}
		return result;
	}

	function containsDocumentExcept(current:view.LayoutNode, document:Document, excluded:Array<View>):Bool {
		if (current.isLeaf()) {
			for (view in current.tabs.views)
				if (excluded.indexOf(view) < 0 && view.getDocument() == document) return true;
			return false;
		}
		return containsDocumentExcept(current.requireFirst(), document, excluded)
			|| containsDocumentExcept(current.requireSecond(), document, excluded);
	}

	public function closeActivePane(force:Bool = false):Bool {
		if (activeLeaf == node) return false;
		for (view in activeLeaf.tabs.views)
			if (view.isDirty() && !force) return false;
		var closing = activeLeaf, documentsToCheck:Array<Document> = [];
		for (view in closing.tabs.views) {
			var document = view.getDocument();
			if (document != null) documentsToCheck.push(document);
		}
		if (!node.collapse(closing)) return false;
		closing.disposeViews();
		activeLeaf = node.firstLeaf();
		focus.activate(activeLeaf.tabs.activeView);
		for (document in documentsToCheck)
			if (!node.containsDocument(document)) documents.close(document, true);
		return true;
	}

	public function resize(width:Int, height:Int):Void {
		this.width = width;
		this.height = height;
		if (sidebarVisible) setSidebarWidth(sidebar.width); else setNodeBounds();
	}

	public function displayScaleChanged(scaleMilli:Int):Void {
		if (scaleMilli <= 0) throw "display scale must be positive";
		displayScaleMilli = scaleMilli;
		setNodeBounds();
	}

	public function setSidebarWidth(width:Int):Void {
		var maximum = this.width - view.LayoutNode.MIN_SIZE;
		if (maximum < 0) maximum = 0;
		if (width < 120) width = 120;
		if (width > maximum) width = maximum;
		sidebar.width = width;
		searchSidebar.width = width;
		setNodeBounds();
	}

	public function toggleSidebar():Bool {
		sidebarVisible = !sidebarVisible;
		setNodeBounds();
		return true;
	}

	function setNodeBounds():Void {
		var sidebarWidth = sidebarVisible ? sidebar.width : 0, contentWidth = width - sidebarWidth;
		if (contentWidth < 0) contentWidth = 0;
		var contentHeight = height - StatusView.HEIGHT;
		if (contentHeight < 0) contentHeight = 0;
		node.setBounds(sidebarWidth, 0, contentWidth, contentHeight);
	}

	public function textInput(text:String):Void {
		if (tabs.activeView != null) tabs.activeView.textInput(text);
	}

	public function setComposition(text:String, start:Int, length:Int):Void {
		if (commandView.active) commandView.setComposition(text, start, length);
		else if (tabs.activeView != null) tabs.activeView.setComposition(text, start, length);
	}

	public function clearComposition():Void {
		commandView.clearComposition();
		if (tabs.activeView != null) tabs.activeView.clearComposition();
	}

	public function textInputArea():Null<TextInputArea> {
		if (commandView.active) return commandView.textInputArea(renderer, width);
		return tabs.activeView == null ? null : tabs.activeView.textInputArea();
	}

	public function cursorChanged():Void {
		if (tabs.activeView != null) tabs.activeView.cursorChanged();
	}

	public function wheel(vertical:Int, horizontal:Int):Void {
		if (commandView.active) {
			commandView.wheel(vertical);
			return;
		}
		if (tabs.activeView != null) tabs.activeView.wheel(vertical, horizontal);
	}

	public function mouseDown(button:Int, x:Int, y:Int, clicks:Int = 1):Void {
		if (commandView.active) {
			commandView.mouseDown(button, x, y, width, height);
			return;
		}
		if (contextMenu.mouseDown(button, x, y)) return;
		if (button == 3) {
			openContextMenu(x, y);
			return;
		}
		if (button == 1 && sidebarVisible && x >= sidebar.width - 3 && x <= sidebar.width + 3) {
			draggingSidebar = true;
			return;
		}
		if (button == 1 && sidebarVisible && x < sidebar.width) {
			if (searchVisible) {
				var match = searchSidebar.mouseDown(x, y);
				if (match != null) openSearchMatch(match);
			} else {
				var path = sidebar.mouseDown(x, y);
				if (path != null) openDocument(documents.open(path));
			}
			return;
		}
		if (button == 1) {
			var divider = node.dividerAt(x, y);
			if (divider != null) {
				draggingDivider = divider;
				return;
			}
		}
		var leaf = node.leafAt(x, y);
		if (leaf == null) return;
		activateLeaf(leaf);
		if (leaf.tabs.activeView == null && button == 1) {
			welcome.mouseDown(x, y, leaf.x, leaf.y, leaf.width, leaf.height);
			return;
		}
		if (button == 1 && y < leaf.y + EditorView.HEADER_HEIGHT) {
			var start = visibleTabStart(leaf), index = start + Std.int((x - leaf.x) / TAB_WIDTH), localX = (x - leaf.x) % TAB_WIDTH;
			if (index >= 0 && index < tabs.views.length) {
				tabs.setActive(tabs.views[index]);
				if (localX >= TAB_WIDTH - 22) closeRequest(); else {
					draggedTabLeaf = leaf;
					draggedTabView = tabs.views[index];
					draggedTabStartX = x;
					draggedTabStartY = y;
				}
			}
			return;
		}
		if (tabs.activeView != null) tabs.activeView.mouseDown(button, x, y, clicks);
	}

	public function mouseMove(x:Int, y:Int):Void {
		pointerX = x;
		pointerY = y;
		if (commandView.active) {
			commandView.mouseMove(x, y, width, height);
			return;
		}
		welcome.mouseMove(x, y);
		contextMenu.mouseMove(x, y);
		if (draggedTabView != null && !draggingTab) {
			var dx = x - draggedTabStartX, dy = y - draggedTabStartY;
			if (dx * dx + dy * dy > 36) draggingTab = true;
		}
		if (draggingSidebar) {
			setSidebarWidth(x);
			return;
		}
		if (draggingDivider != null) {
			draggingDivider.moveDivider(x, y);
			return;
		}
		if (tabs.activeView != null) tabs.activeView.mouseMove(x, y);
	}

	public function mouseUp(button:Int):Void {
		if (commandView.active) return;
		if (button == 1) {
			if (draggingTab) dropDraggedTab(pointerX, pointerY);
			draggedTabLeaf = null;
			draggedTabView = null;
			draggingTab = false;
			draggingDivider = null;
			draggingSidebar = false;
		}
		if (tabs.activeView != null) tabs.activeView.mouseUp(button);
	}

	public function draw():Void {
		if (sidebarVisible) {
			if (searchVisible) searchSidebar.draw(renderer, theme, height); else sidebar.draw(renderer, theme, height);
			drawPluginPanels();
		}
		renderer.clip(0, 0, width, height);
		drawNode(node);
		renderer.clip(0, 0, width, height);
		commandView.draw(renderer, theme, width, height);
		languagePopup.draw(renderer, theme, width, height - StatusView.HEIGHT);
		contextMenu.draw(renderer, theme);
		if (draggingTab) drawTabDropOverlay();
		var notification = notifications.current();
		if (notification != null) {
			renderer.clip(0, 0, width, height);
			var notificationY = height - StatusView.HEIGHT - 28;
			var color = switch notification.kind {
				case Information: theme.information;
				case Warning: theme.warning;
				case Error: theme.error;
			};
			renderer.rect(0, notificationY, width, 28, color);
			renderer.text(8, notificationY + 5, notification.message, theme.caret);
		}
		status.draw(focus.activeView, width, height);
	}

	function dropDraggedTab(x:Int, y:Int):Void {
		var source = draggedTabLeaf, moving = draggedTabView, target = node.leafAt(x, y);
		if (source == null || moving == null || target == null) return;
		var sourceTabs = source.tabs;
		if (target == source && y < target.y + EditorView.HEADER_HEIGHT) {
			var index = visibleTabStart(target) + Std.int((x - target.x) / TAB_WIDTH);
			if (index > target.tabs.views.length) index = target.tabs.views.length;
			source.tabs.detach(moving);
			target.tabs.insert(moving, index);
			activateLeaf(target);
			return;
		}
		var edgeX = Std.int(target.width / 4), edgeY = Std.int(target.height / 4), destination = target;
		if (x < target.x + edgeX) destination = target.split(LayoutKind.Horizontal, true);
		else if (x >= target.x + target.width - edgeX) destination = target.split(LayoutKind.Horizontal, false);
		else if (y < target.y + edgeY) destination = target.split(LayoutKind.Vertical, true);
		else if (y >= target.y + target.height - edgeY) destination = target.split(LayoutKind.Vertical, false);
		if (!sourceTabs.detach(moving)) return;
		destination.tabs.add(moving);
		moving.setBounds(destination.x, destination.y, destination.width, destination.height);
		activateLeaf(destination);
	}

	function drawTabDropOverlay():Void {
		var target = node.leafAt(pointerX, pointerY);
		if (target == null) return;
		var x = target.x, y = target.y, w = target.width, h = target.height, edgeX = Std.int(w / 4), edgeY = Std.int(h / 4);
		if (pointerX < x + edgeX) w = edgeX;
		else if (pointerX >= x + w - edgeX) { x += w - edgeX; w = edgeX; }
		else if (pointerY < y + edgeY) h = edgeY;
		else if (pointerY >= y + h - edgeY) { y += h - edgeY; h = edgeY; }
		else { x += 6; y += 6; w -= 12; h -= 12; }
		renderer.rect(x, y, w, h, theme.selection);
	}

	function openContextMenu(x:Int, y:Int):Void {
		var items:Array<ContextMenuItem> = [];
		if (sidebarVisible && x < sidebar.width && !searchVisible) {
			if (!sidebar.selectAt(x, y)) return;
			var selected = sidebar.activeNode();
			if (selected != null && !selected.directory)
				items.push(new ContextMenuItem("Open", function() { var path = sidebar.activate(); if (path != null) openDocument(documents.open(path)); }));
			items.push(new ContextMenuItem("New File", createFileRequest));
			items.push(new ContextMenuItem("New Folder", createFolderRequest));
			if (selected != null) {
				items.push(new ContextMenuItem("Rename / Move", renameFileRequest));
				items.push(new ContextMenuItem("Move to Trash", deleteFileRequest));
			}
		} else {
			var leaf = node.leafAt(x, y);
			if (leaf == null) return;
			activateLeaf(leaf);
			if (y < leaf.y + EditorView.HEADER_HEIGHT && leaf.tabs.activeView != null) {
				items.push(new ContextMenuItem("Close", closeRequest));
				items.push(new ContextMenuItem("Split Right", function() { splitActive(LayoutKind.Horizontal); }));
				items.push(new ContextMenuItem("Split Down", function() { splitActive(LayoutKind.Vertical); }));
			} else if (leaf.tabs.activeView != null) {
				var view = leaf.tabs.activeView;
				items.push(new ContextMenuItem("Cut", function() { view.cut(); }));
				items.push(new ContextMenuItem("Copy", function() { view.copy(); }));
				items.push(new ContextMenuItem("Paste", function() { view.paste(); }));
				items.push(new ContextMenuItem("Select All", function() { view.selectAll(); }));
				items.push(new ContextMenuItem("Show Problems", showProblems));
			}
		}
		contextMenu.open(x, y, items, width, height - StatusView.HEIGHT);
	}

	function drawPluginPanels():Void {
		var panels = pluginPanels.panels(), y = height - StatusView.HEIGHT - panels.length * 44;
		for (panel in panels) {
			renderer.clip(0, y, sidebar.width, 44);
			renderer.rect(0, y, sidebar.width, 44, theme.surfaceElevated);
			renderer.text(10, y + 3, panel.title, theme.foregroundMuted);
			renderer.text(10, y + 22, panel.text, theme.editorForeground);
			y += 44;
		}
	}

	public function showSearchResults(query:String, results:Array<SearchMatch>):Void {
		searchVisible = true;
		searchSidebar.setResults(query, results);
	}

	public function showProjectSidebar():Void
		searchVisible = false;

	public function searchMove(delta:Int):Bool
		return searchSidebar.selectBy(delta);

	public function searchActivate():Bool {
		var match = searchSidebar.active();
		if (match != null) openSearchMatch(match);
		return true;
	}

	public function openSearchMatch(match:SearchMatch):Void {
		var view = openDocument(documents.open(match.path));
		var document = view.getDocument();
		if (document != null) {
			if (DocumentSearch.valid(document, match)) {
				view.selectRange(new BufferPosition(match.line, match.column), new BufferPosition(match.line, match.column + match.length));
				view.cursorChanged();
			}
		}
	}

	public function setDocumentSearchMatches(results:Array<SearchMatch>):Void {
		clearSearchMatches(node);
		var view = tabs.activeView;
		if (view == null) return;
		view.setSearchMatches(results);
	}

	function clearSearchMatches(current:view.LayoutNode):Void {
		if (current.isLeaf()) {
			for (view in current.tabs.views) view.setSearchMatches([]);
			return;
		}
		clearSearchMatches(current.requireFirst());
		clearSearchMatches(current.requireSecond());
	}

	public function documentRenamed(document:Document):Void
		updateDocumentTitle(node, document);

	function updateDocumentTitle(current:view.LayoutNode, document:Document):Void {
		if (current.isLeaf()) {
			for (view in current.tabs.views) if (view.getDocument() == document) view.setTitle(document.title);
			return;
		}
		updateDocumentTitle(current.requireFirst(), document);
		updateDocumentTitle(current.requireSecond(), document);
	}

	public function sidebarMove(delta:Int):Bool
		return sidebar.selectBy(delta);

	public function sidebarActivate():Bool {
		var path = sidebar.activate();
		if (path == null) return true;
		openDocument(documents.open(path));
		return true;
	}

	function drawNode(current:view.LayoutNode):Void {
		if (current.isLeaf()) {
			drawLeaf(current);
			return;
		}
		drawNode(current.requireFirst());
		renderer.clip(0, 0, width, height);
		drawNode(current.requireSecond());
		renderer.clip(0, 0, width, height);
		var first = current.requireFirst();
		if (current.kind == LayoutKind.Horizontal)
			renderer.rect(first.x + first.width, current.y, view.LayoutNode.DIVIDER_SIZE, current.height, theme.divider);
		else
			renderer.rect(current.x, first.y + first.height, current.width, view.LayoutNode.DIVIDER_SIZE, theme.divider);
	}

	function drawLeaf(leaf:view.LayoutNode):Void {
		renderer.clip(leaf.x, leaf.y, leaf.width, leaf.height);
		if (leaf.tabs.activeView == null) {
			welcome.draw(renderer, theme, leaf.x, leaf.y, leaf.width, leaf.height);
			return;
		}
		leaf.tabs.activeView.draw();
		var x = leaf.x, start = visibleTabStart(leaf), capacity = visibleTabCapacity(leaf), end = start + capacity;
		if (end > leaf.tabs.views.length) end = leaf.tabs.views.length;
		for (index in start...end) {
			var view = leaf.tabs.views[index];
			var active = view == leaf.tabs.activeView,
				hovered = pointerX >= x && pointerX < x + TAB_WIDTH && pointerY >= leaf.y && pointerY < leaf.y + EditorView.HEADER_HEIGHT;
			renderer.rect(x, leaf.y, TAB_WIDTH, EditorView.HEADER_HEIGHT,
				active ? theme.surfaceActive : hovered ? theme.surfaceHover : theme.surfaceInactive);
			renderer.text(x + 12, leaf.y + 13, (view.isDirty() ? "* " : "") + view.title, active ? theme.caret : theme.foregroundMuted);
			var closeHovered = hovered && pointerX >= x + TAB_WIDTH - 22;
			renderer.text(x + TAB_WIDTH - 18, leaf.y + 13, "x", closeHovered ? theme.caret : active ? theme.editorForeground : theme.foregroundSubtle);
			x += TAB_WIDTH;
		}
		if (leaf == activeLeaf) renderer.rect(leaf.x, leaf.y, leaf.width, 2, theme.accent);
	}

	function visibleTabCapacity(leaf:view.LayoutNode):Int {
		var result = Std.int(leaf.width / TAB_WIDTH);
		return result < 1 ? 1 : result;
	}

	function visibleTabStart(leaf:view.LayoutNode):Int {
		var active = leaf.tabs.activeView == null ? 0 : leaf.tabs.indexOf(leaf.tabs.activeView), capacity = visibleTabCapacity(leaf), start = active - capacity + 1;
		if (start < 0) start = 0;
		return start;
	}

	function neighboringLeaf(source:view.LayoutNode, horizontal:Int, vertical:Int):Null<view.LayoutNode> {
		var leaves:Array<view.LayoutNode> = [];
		collectLeaves(node, leaves);
		var sourceX = source.x + Std.int(source.width / 2), sourceY = source.y + Std.int(source.height / 2), best:Null<view.LayoutNode> = null,
			bestScore = 0x7fffffff;
		for (candidate in leaves) if (candidate != source) {
			var candidateX = candidate.x + Std.int(candidate.width / 2), candidateY = candidate.y + Std.int(candidate.height / 2),
				dx = candidateX - sourceX, dy = candidateY - sourceY;
			if (horizontal < 0 && dx >= 0 || horizontal > 0 && dx <= 0 || vertical < 0 && dy >= 0 || vertical > 0 && dy <= 0) continue;
			var primary = horizontal == 0 ? (dy < 0 ? -dy : dy) : (dx < 0 ? -dx : dx),
				secondary = horizontal == 0 ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy), score = primary * 10000 + secondary;
			if (score < bestScore) { bestScore = score; best = candidate; }
		}
		return best;
	}

	function collectLeaves(current:view.LayoutNode, result:Array<view.LayoutNode>):Void {
		if (current.isLeaf()) result.push(current); else {
			collectLeaves(current.requireFirst(), result);
			collectLeaves(current.requireSecond(), result);
		}
	}

	function leafForView(current:view.LayoutNode, view:View):Null<view.LayoutNode> {
		if (current.isLeaf()) return current.tabs.indexOf(view) >= 0 ? current : null;
		var found = leafForView(current.requireFirst(), view);
		return found == null ? leafForView(current.requireSecond(), view) : found;
	}

	public function sessionLines():Array<String> {
		var result:Array<String> = [];
		appendSessionNode(node, "", result);
		result.push("A\t" + routeFor(node, activeLeaf, ""));
		return result;
	}

	function appendSessionNode(current:view.LayoutNode, route:String, result:Array<String>):Void {
		if (!current.isLeaf()) {
			result.push("S\t" + route + "\t" + (current.kind == LayoutKind.Horizontal ? "H" : "V") + "\t" + current.divider);
			appendSessionNode(current.requireFirst(), route + "0", result);
			appendSessionNode(current.requireSecond(), route + "1", result);
			return;
		}
		for (view in current.tabs.views) {
			var document = view.getDocument();
			if (document != null) {
				var reference = document.dirty || !document.hasBackingPath() ? document.recoveryId : document.requirePath(),
					kind = document.dirty || !document.hasBackingPath() ? "R" : "P";
				if (reference.indexOf("\t") < 0 && reference.indexOf("\n") < 0)
				result.push("T\t" + route + "\t" + (view == current.tabs.activeView ? "1" : "0") + "\t" + view.cursorLine() + "\t"
						+ view.cursorColumn() + "\t" + view.scrollX() + "\t" + view.scrollY() + "\t" + kind + "\t" + reference);
			}
		}
	}

	public function restoreSessionLines(lines:Array<String>, ?resolver:(String, String)->Null<Document>):Void {
		focus.activate(null);
		node.reset();
		activeLeaf = node;
		var requestedActive:Null<View> = null;
		for (line in lines) {
			var fields = line.split("\t");
			if (fields.length == 4 && fields[0] == "S" && (fields[2] == "H" || fields[2] == "V")) {
				var target = nodeAtRoute(fields[1]);
				if (target != null && target.isLeaf()) {
					target.split(fields[2] == "H" ? LayoutKind.Horizontal : LayoutKind.Vertical);
					target.setDivider(Std.parseInt(fields[3]));
				}
			}
		}
		for (line in lines) {
			var fields = line.split("\t");
			if (fields.length == 9 && fields[0] == "T") {
				var leaf = nodeAtRoute(fields[1]);
				if (leaf != null && leaf.isLeaf()) {
					var document = resolver == null ? resolveSessionDocument(fields[7], fields[8]) : resolver(fields[7], fields[8]);
					if (document == null) continue;
					var view = new DocumentView(document, renderer, theme, leaf.width, leaf.height, pluginDecorations);
					view.setBounds(leaf.x, leaf.y, leaf.width, leaf.height);
					leaf.tabs.add(view);
					view.restoreCursor(Std.parseInt(fields[3]), Std.parseInt(fields[4]));
					view.restoreScroll(Std.parseInt(fields[5]), Std.parseInt(fields[6]));
					if (fields[2] == "1") {
						leaf.tabs.setActive(view);
					}
				}
			}
		}
		for (line in lines) {
			var fields = line.split("\t");
			if (fields.length == 2 && fields[0] == "A") {
				var leaf = nodeAtRoute(fields[1]);
				if (leaf != null && leaf.isLeaf()) requestedActive = leaf.tabs.activeView;
			}
		}
		node.pruneEmpty();
		activeLeaf = node.firstLeaf();
		if (requestedActive != null) {
			var requestedLeaf = leafForView(node, requestedActive);
			if (requestedLeaf != null) activateLeaf(requestedLeaf); else focus.activate(activeLeaf.tabs.activeView);
		} else focus.activate(activeLeaf.tabs.activeView);
		setNodeBounds();
	}

	function resolveSessionDocument(kind:String, reference:String):Null<Document> {
		if (kind != "P" || !FileSystem.exists(reference) || FileSystem.isDirectory(reference)) return null;
		try {
			return documents.open(reference);
		} catch (error:Dynamic) {
			return null;
		}
	}

	function nodeAtRoute(route:String):Null<view.LayoutNode> {
		if (route.length > 64) return null;
		var current = node;
		for (index in 0...route.length) {
			if (route.charAt(index) != "0" && route.charAt(index) != "1") return null;
			if (current.isLeaf()) return null;
			current = route.charAt(index) == "0" ? current.requireFirst() : current.requireSecond();
		}
		return current;
	}

	function routeFor(current:view.LayoutNode, target:view.LayoutNode, route:String):String {
		if (current == target) return route;
		if (current.isLeaf()) return "";
		var left = routeFor(current.requireFirst(), target, route + "0");
		if (left.length > 0 || current.requireFirst() == target) return left;
		return routeFor(current.requireSecond(), target, route + "1");
	}

	// -- core.WorkbenchHost --

	public function getTheme():Theme return theme;
	public function getProblems():ProblemRegistry return problems;
	public function getPluginDecorations():PluginDecorationRegistry return pluginDecorations;
	public function getPluginStatusItems():PluginStatusRegistry return pluginStatusItems;
	public function getPluginPanels():PluginPanelRegistry return pluginPanels;
	public function asRootView():Null<RootView> return this;
	public function getNotifications():NotificationCenter return notifications;

	public function openCommandView(provider:CommandViewProvider):Void commandView.open(provider);
	public function closeCommandView():Void commandView.close();
	public function isCommandViewActive():Bool return commandView.active;
	public function commandViewKeyPressed(key:Int, modifiers:Int):Bool return commandView.keyPressed(key, modifiers);
	public function commandViewTextInput(text:String):Void commandView.textInput(text);

	public function focusedFilePath():Null<String> {
		if (searchVisible) return null;
		var node = sidebar.activeNode();
		return node == null ? null : node.path;
	}

	public function canCloseActivePane():Bool return activeLeaf != node;

	public function setWorkspaceSearchStatus(complete:Bool, capped:Bool, errorCount:Int):Void
		searchSidebar.setStatus(complete, capped, errorCount);

	public function setProblemActivationHandler(handler:Problem->Void):Void
		problemActivationHandler = handler;

	public function showProblems():Void {
		openAuxiliary(new ProblemsView(problems, renderer, theme, activeLeaf.width, activeLeaf.height, problemActivationHandler));
	}

	public function setBuildDiagnosticHandler(handler:BuildDiagnostic->Void):Void
		buildDiagnosticHandler = handler;

	public function showBuildOutput(title:String, output:BuildOutput):Void {
		var view = new BuildOutputView(output, renderer, theme, activeLeaf.width, activeLeaf.height, buildDiagnosticHandler);
		view.setTitle(title);
		openAuxiliary(view);
	}

	public function openLanguageInformation(area:TextInputArea, text:String):Void
		languagePopup.openInformation(area, text);

	public function openLanguageCompletion(area:TextInputArea, items:Array<CompletionItem>, accept:CompletionItem->Void):Void
		languagePopup.openCompletion(area, items, accept);

	public function openLanguageSignature(area:TextInputArea, help:SignatureHelp):Void
		languagePopup.openSignature(area, help);

	public function handleLanguagePopupKey(key:Int, modifiers:Int):Bool return languagePopup.keyPressed(key, modifiers);
	public function dismissLanguagePopup():Void languagePopup.close();
	public function isLanguagePopupVisible():Bool return languagePopup.visible;

	/** Applies the status bar, sidebar-width, and font portions of visual settings. Color/theme fields are applied by the caller via getTheme(). */
	public function applySettings(settings:Settings):Bool {
		status.applySettings(settings);
		setSidebarWidth(settings.sidebarWidth);
		return renderer.reloadFont(settings.fontPath, settings.fontSize, settings.fontFallbackPaths);
	}

	public function configureFileActions(actions:FileActions):Void {
		createFileRequest = actions.createFile;
		createFolderRequest = actions.createFolder;
		renameFileRequest = actions.renameFile;
		deleteFileRequest = actions.deleteFile;
		closeRequest = actions.closeTab;
	}

	public function configureWelcomeActions(actions:WelcomeActions):Void {
		welcome.recentProjects = actions.recentProjects;
		welcome.newFile = actions.newFile;
		welcome.openFile = actions.openFile;
		welcome.openProject = actions.openProject;
		welcome.findFile = actions.findFile;
		welcome.runCommand = actions.runCommand;
		welcome.openSettings = actions.openSettings;
		welcome.openPlugins = actions.openPlugins;
		welcome.openRecent = actions.openRecent;
	}
}
