package ui;

import build.BuildDiagnostic;
import build.BuildOutput;
import commandview.CommandView;
import commandview.CommandViewProvider;
import completion.CompletionItem;
import config.Settings;
import core.FileActions;
import core.FocusManager;
import core.WelcomeActions;
import core.WorkbenchHost;
import editor.BufferPosition;
import editor.BufferSelection;
import editor.Document;
import feedback.NotificationCenter;
import feedback.Problem;
import feedback.ProblemRegistry;
import language.SignatureHelp;
import platform.Platform;
import platform.TextInputArea;
import Rect;
import plugin.PluginDecorationRegistry;
import plugin.PluginPanelRegistry;
import plugin.PluginStatusRegistry;
import search.DocumentSearch;
import search.SearchMatch;
import style.Theme;
import view.RootView;
import view.View;
import view.LayoutKind;
import nativekit.ui.docking.DockWorkspaceModel;
import nativekit.ui.docking.DockPanelDescriptor;
import nativekit.ui.docking.DockDropZone;
import nativekit.ui.docking.DockNode;
import nativekit.ui.docking.DockNodeTools;
import nativekit.ui.core.WidgetId;
import workspace.Workspace;

import Color;
import Insets;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import nativekit.ui.core.View as NkView;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.overlays.Popup;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.Text;
import nativekit.ui.core.TextStyleOverride;

/**
 * UIKit workbench host owning document and terminal tabs in DockWorkspace
 * editor panes. Each document view owns its selection and scroll position;
 * terminal tabs retain their session while moving between panes and tools.
 * Command and language overlays are rendered by ExosuitApp.overlayView().
 */
class UiWorkbenchHost implements WorkbenchHost {
	final theme:Theme;
	final focus:FocusManager;
	final workspace:Workspace;
	final requestFrame:Void->Void;
	final dockActions:DockActions;
	final defaultDockLayout:DockNode;

	final problems:ProblemRegistry = new ProblemRegistry();
	final pluginDecorations:PluginDecorationRegistry = new PluginDecorationRegistry();
	final pluginStatusItems:PluginStatusRegistry = new PluginStatusRegistry();
	final pluginPanels:PluginPanelRegistry = new PluginPanelRegistry();
	final notifications:NotificationCenter = new NotificationCenter();
	public final panes:Array<UiEditorPane> = [];
	public var activePane(default, null):UiEditorPane;
	var nextPaneId:Int = 1;
	var pendingEditorFocus:Bool = false;
	var tabList(get, never):Array<UiDocumentView>;
	function get_tabList():Array<UiDocumentView> return activePane.tabs;
	public var tabs(get, never):Array<UiDocumentView>;
	public var activeIndex(get, set):Int;
	function get_activeIndex():Int return activePane.activeIndex;
	function set_activeIndex(value:Int):Int return activePane.activeIndex = value;
	public var fileActions(default, null):Null<FileActions>;
	public var welcomeActions(default, null):Null<WelcomeActions>;
	public var restoreTerminal:Null<(String, String, String)->Null<UiTerminalTab>>;
	public final panelTerminals:Array<UiTerminalTab> = [];
	public var activePanelTerminalIndex:Int = -1;

	public function activePanelTerminal():Null<UiTerminalTab>
		return activePanelTerminalIndex >= 0 && activePanelTerminalIndex < panelTerminals.length ?
			panelTerminals[activePanelTerminalIndex] : null;

	public function allTerminalTabs():Array<UiTerminalTab> {
		var result = panelTerminals.copy();
		for (pane in panes) for (item in pane.items) {
			var terminal = UiEditorTabs.terminal(item);
			if (terminal != null) result.push(terminal);
		}
		return result;
	}

	public function deactivateDocumentFocus():Void focus.activate(null);

	var problemActivationHandler:Problem->Void = function(problem) {};
	var buildDiagnosticHandler:BuildDiagnostic->Void = function(diagnostic) {};
	public var currentBuildTitle(default, null):String = "";
	public var currentBuildOutput(default, null):Null<BuildOutput>;
	var selectedExplorerPath:Null<String>;

	final commandView:CommandView = new CommandView();
	var commandViewProvider:Null<CommandViewProvider>;
	final commandViewCapture:KeyCaptureView;

	static inline var LANG_NONE = 0;
	static inline var LANG_INFO = 1;
	static inline var LANG_COMPLETION = 2;
	static inline var LANG_SIGNATURE = 3;
	static inline var COMPLETION_ROW_HEIGHT = 24.0;
	static inline var COMPLETION_ROW_GAP = 4.0;
	static inline var COMPLETION_PADDING = 8.0;
	static inline var COMPLETION_MAX_HEIGHT = 236.0;
	public var caretRectProvider:Null<Void->Null<Rect>>;
	var languageArea:Null<TextInputArea>;
	var languageDocumentId:Int = -1;
	var languageKind:Int = LANG_NONE;
	var languageInfoText:String = "";
	var languageItems:Array<CompletionItem> = [];
	var languageAccept:CompletionItem->Void = function(item) {};
	var languageSelected:Int = 0;
	final languageScroll = new nativekit.ui.widgets.scroll.ScrollController();
	var languageInput:Null<String->Void>;
	var languageKey:Null<(Int, Int)->Bool>;
	var languageSignature:Null<SignatureHelp>;
	final languageCapture:KeyCaptureView;

	public var activateSearch:Void->Void = function() {};
	public var captureSidebar:Null<Void->String>;
	public var restoreSidebar:Null<Array<String>->Void>;
	public var workspaceSearchQuery(default, null):String = "";
	public var workspaceSearchResults(default, null):Array<SearchMatch> = [];
	var searchSelected:Int = -1;
	public var searchComplete(default, null):Bool = false;
	public var searchCapped(default, null):Bool = false;
	public var searchErrorCount(default, null):Int = 0;

	var scrollSettings:Settings;
	public var scrollbarVisibility(get, never):Int;
	function get_scrollbarVisibility():Int return switch scrollSettings.scrollbarVisibility {
		case "always": nativekit.ui.widgets.scroll.ScrollbarVisibility.Always;
		case "hidden": nativekit.ui.widgets.scroll.ScrollbarVisibility.Hidden;
		default: nativekit.ui.widgets.scroll.ScrollbarVisibility.Auto;
	};

	public function new(theme:Theme, focus:FocusManager, workspace:Workspace, settings:Settings, requestFrame:Void->Void,
			dockActions:DockActions) {
		this.caretRectProvider = null;
		this.languageArea = null;
		this.theme = theme;
		scrollSettings = settings.copy();
		this.focus = focus;
		this.workspace = workspace;
		this.requestFrame = requestFrame;
		this.dockActions = dockActions;
		defaultDockLayout = DockNodeTools.clone(dockActions.model.defaultRoot);
		activePane = new UiEditorPane("editor");
		panes.push(activePane);
		commandViewCapture = new KeyCaptureView(buildCommandViewContent(), commandViewKeyPressed, commandViewTextInput);
		// Completion owns its revision-checked input callback; informational popups
		// dismiss and forward committed text to the active editor.
		languageCapture = new KeyCaptureView(buildLanguagePopupContent(), handleLanguagePopupKey, function(text) {
			if (!handleLanguagePopupText(text)) { dismissLanguagePopup(); textInput(text); }
		}, function(event) {
			dismissLanguagePopup();
			if (activePane.focusTarget != null) dockActions.editorPreedit(activePane.focusTarget, event);
		});
	}

	function get_tabs():Array<UiDocumentView>
		return tabList;

	public function allViews():Array<UiDocumentView> {
		var result:Array<UiDocumentView> = [];
		for (pane in panes) for (view in pane.tabs) result.push(view);
		return result;
	}

	public function paneById(id:String):Null<UiEditorPane> {
		for (pane in panes) if (pane.id == id) return pane;
		return null;
	}

	public function dispose():Void {
		for (terminal in panelTerminals) terminal.dispose();
		panelTerminals.resize(0);
		for (pane in panes) {
			for (item in pane.items) UiEditorTabs.dispose(item);
			pane.items.resize(0);
			pane.activeIndex = -1;
		}
	}

	public function splitActive(kind:LayoutKind, newFirst:Bool = false):Bool {
		if (kind == LayoutKind.Leaf) return false;
		var source = activeView();
		var created = new UiEditorPane("editor-pane-" + nextPaneId++);
		dockActions.model.register(new DockPanelDescriptor(created.id, "Editor", false, true, null, nativekit.ui.docking.DockPanelHeaderMode.Content, new nativekit.ui.docking.DockPanelGrouping("editors", false)));
		var zone = kind == LayoutKind.Horizontal ?
			(newFirst ? DockDropZone.Left : DockDropZone.Right) :
			(newFirst ? DockDropZone.Top : DockDropZone.Bottom);
		if (!dockActions.model.dock(created.id, activePane.id, zone)) return false;
		if (source != null) {
			var selection = new BufferSelection();
			selection.restoreSnapshot(source.document.buffer, source.selection.snapshot(), false);
			created.items.push(UiEditorTab.Document(new UiDocumentView(source.document, selection, scrollSettings)));
			created.activeIndex = 0;
		}
		panes.push(created);
		activePane = created;
		pendingEditorFocus = true;
		focus.activate(activeView());
		requestFrame();
		return true;
	}

	public function activeView():Null<UiDocumentView>
		return activePane.activeView();

	public function activeTab():Null<UiEditorTab> return activePane.activeTab();
	public function canCloseActiveTab():Bool return activeTab() != null;

	public function terminalPaneFor(terminal:UiTerminalTab):Null<UiEditorPane> {
		for (pane in panes) for (item in pane.items)
			if (UiEditorTabs.terminal(item) == terminal) return pane;
		return null;
	}

	public function attachTerminal(terminal:UiTerminalTab):Void {
		var pane = terminalPaneFor(terminal);
		if (pane == null) { pane = activePane; pane.items.push(UiEditorTab.Terminal(terminal)); }
		activateEditorTab("terminal:" + terminal.id, pane.id);
	}

	public function detachTerminal(terminal:UiTerminalTab):Bool {
		var pane = terminalPaneFor(terminal);
		if (pane == null) return false;
		for (index in 0...pane.items.length) if (UiEditorTabs.terminal(pane.items[index]) == terminal) {
			pane.items.splice(index, 1);
			if (pane.activeIndex > index) pane.activeIndex--;
			else if (pane.activeIndex == index) pane.activeIndex = Std.int(Math.min(index, pane.items.length - 1));
			if (pane == activePane) focus.activate(activeView());
			requestFrame();
			return true;
		}
		return false;
	}

	public function activateEditorTab(key:String, paneId:String):Void {
		var pane = paneById(paneId);
		if (pane == null) return;
		for (index in 0...pane.items.length) if (UiEditorTabs.key(pane.items[index]) == key) {
			activePane = pane;
			dockActions.model.activate(pane.id);
			setActiveIndex(index);
			pendingEditorFocus = true;
			return;
		}
	}

	public function switchActiveTab(delta:Int):Bool {
		if (activePane.items.length == 0) return false;
		var count = activePane.items.length;
		setActiveIndex((activeIndex + delta % count + count) % count);
		pendingEditorFocus = true;
		return true;
	}

	public function activeDocument():Null<Document> {
		var view = activeView();
		return view == null ? null : view.document;
	}

	function setActiveIndex(index:Int):Void {
		activeIndex = index;
		focus.activate(activeView());
		requestFrame();
	}

	/** Called by `ExosuitApp`'s `Tabs` widget when the user clicks a different tab. */
	public function activateTab(document:Document, ?paneId:String):Void {
		if (paneId != null) {
			var pane = paneById(paneId);
			if (pane == null) return;
			activePane = pane;
			dockActions.model.activate(pane.id);
		}
		for (index in 0...activePane.items.length) {
			var view = UiEditorTabs.document(activePane.items[index]);
			if (view != null && view.document == document) {
				setActiveIndex(index);
				return;
			}
		}
	}


	public function setSelectedExplorerPath(path:Null<String>):Void
		selectedExplorerPath = path;

	// -- core.WorkbenchHost: shared state --

	public function getTheme():Theme return theme;
	public function getProblems():ProblemRegistry return problems;
	public function getPluginDecorations():PluginDecorationRegistry return pluginDecorations;
	public function getPluginStatusItems():PluginStatusRegistry return pluginStatusItems;
	public function getPluginPanels():PluginPanelRegistry return pluginPanels;
	public function getNotifications():NotificationCenter return notifications;
	public function asRootView():Null<RootView> return null;

	// -- core.WorkbenchHost: command-view / confirmations --

	public function openCommandView(provider:CommandViewProvider):Void {
		commandViewProvider = provider;
		commandView.open(provider);
		commandViewCapture.resetFocus();
		requestFrame();
	}

	public function closeCommandView():Void {
		commandView.close();
		commandViewProvider = null;
		requestFrame();
	}

	public function isCommandViewActive():Bool return commandView.active;

	public function commandViewKeyPressed(key:Int, modifiers:Int):Bool {
		var handled = commandView.keyPressed(key, modifiers);
		if (handled) requestFrame();
		return handled;
	}

	public function commandViewTextInput(text:String):Void {
		commandView.textInput(text);
		requestFrame();
	}

	// -- core.WorkbenchHost: focus & navigation requests --

	public function editorResolved(paneId:String, bounds:Rect, target:WidgetId):Void {
		var pane = paneById(paneId);
		if (pane == null) return;
		pane.bounds = bounds;
		pane.focusTarget = target;
		if (pendingEditorFocus && pane == activePane) {
			pendingEditorFocus = false;
			dockActions.focusEditor(target);
		}
	}

	function activatePane(pane:UiEditorPane):Void {
		activePane = pane;
		dockActions.model.activate(pane.id);
		focus.activate(activeView());
		pendingEditorFocus = true;
		if (pane.focusTarget != null) dockActions.focusEditor(pane.focusTarget);
		requestFrame();
	}

	function neighboringPane(horizontal:Int, vertical:Int):Null<UiEditorPane> {
		var source = activePane.bounds;
		if (source == null || (horizontal == 0 && vertical == 0)) return null;
		var best:Null<UiEditorPane> = null, bestScore:Float = Math.POSITIVE_INFINITY;
		for (pane in panes) {
			var bounds = pane.bounds;
			if (pane == activePane || bounds == null || !dockActions.model.isOpen(pane.id)) continue;
			var dx = bounds.x + bounds.width / 2.0 - source.x - source.width / 2.0;
			var dy = bounds.y + bounds.height / 2.0 - source.y - source.height / 2.0;
			if (horizontal < 0 && dx >= 0 || horizontal > 0 && dx <= 0 ||
				vertical < 0 && dy >= 0 || vertical > 0 && dy <= 0) continue;
			var primary = horizontal == 0 ? Math.abs(dy) : Math.abs(dx);
			var secondary = horizontal == 0 ? Math.abs(dx) : Math.abs(dy);
			var score = primary * 10000.0 + secondary;
			if (score < bestScore) { bestScore = score; best = pane; }
		}
		return best;
	}

	public function focusPane(horizontal:Int, vertical:Int):Bool {
		var target = neighboringPane(horizontal, vertical);
		if (target == null) return false;
		activatePane(target);
		return true;
	}

	public function moveActiveTab(horizontal:Int, vertical:Int):Bool {
		var target = neighboringPane(horizontal, vertical), moving = activeTab();
		if (target == null || moving == null) return false;
		var source = activePane;
		var movingDocument = UiEditorTabs.document(moving);
		if (movingDocument != null) movingDocument.preview = false;
		source.items.splice(source.activeIndex, 1);
		source.activeIndex = source.items.length == 0 ? -1 : Std.int(Math.min(source.activeIndex, source.items.length - 1));
		var duplicate = -1;
		var documentView = UiEditorTabs.document(moving);
		if (documentView != null) for (index in 0...target.items.length) {
			var candidate = UiEditorTabs.document(target.items[index]);
			if (candidate != null && candidate.document == documentView.document) { candidate.preview = false; duplicate = index; break; }
		}
		if (duplicate >= 0) { UiEditorTabs.dispose(moving); target.activeIndex = duplicate; }
		else { target.items.push(moving); target.activeIndex = target.items.length - 1; }
		target.focusTarget = null;
		activatePane(target);
		return true;
	}

	public function reorderActiveTab(delta:Int):Bool {
		if (activeIndex < 0) return false;
		var target = activeIndex + delta;
		if (target < 0 || target >= activePane.items.length) return false;
		var view = activePane.items.splice(activeIndex, 1)[0];
		var documentView = UiEditorTabs.document(view);
		if (documentView != null) documentView.preview = false;
		activePane.items.insert(target, view);
		activeIndex = target;
		requestFrame();
		return true;
	}

	public function toggleSidebar():Bool {
		if (dockActions == null) return false;
		requestFrame();
		return dockActions.toggleSidebar();
	}

	public function showProjectSidebar():Void {
		if (dockActions != null) dockActions.activateExplorer();
	}

	public function searchMove(delta:Int):Bool {
		if (workspaceSearchResults.length == 0) return false;
		searchSelected = ((searchSelected + delta) % workspaceSearchResults.length + workspaceSearchResults.length) % workspaceSearchResults.length;
		return true;
	}

	public function searchActivate():Bool {
		if (searchSelected < 0 || searchSelected >= workspaceSearchResults.length) return true;
		return activateSearchResult(searchSelected);
	}

	public function activateSearchResult(index:Int):Bool {
		if (index < 0 || index >= workspaceSearchResults.length) return false;
		searchSelected = index;
		var match = workspaceSearchResults[index];
		var document = workspace.documents.open(match.path);
		if (!DocumentSearch.valid(document, match)) return false;
		var view = openDocument(document);
		view.selectRange(new BufferPosition(match.line, match.column), new BufferPosition(match.line, match.column + match.length));
		view.cursorChanged(); requestFrame();
		return true;
	}

	public function focusedFilePath():Null<String> return selectedExplorerPath;

	/** The last editor pane remains available even when its tabs are empty. */
	public function canCloseActivePane():Bool return panes.length > 1;

	// -- core.WorkbenchHost: open/activate document & active-editor input --

	public function openDocument(document:Document):View return openDocumentTab(document, false);

	public function openPreview(document:Document):View return openDocumentTab(document, true);

	public function keepDocument(document:Document, ?paneId:String):Void {
		var pane = paneId == null ? activePane : paneById(paneId);
		if (pane == null) return;
		for (view in pane.tabs) if (view.document == document) view.preview = false;
		requestFrame();
	}

	function openDocumentTab(document:Document, preview:Bool):View {
		for (index in 0...activePane.items.length) {
			var existing = UiEditorTabs.document(activePane.items[index]);
			if (existing != null && existing.document == document) {
				if (!preview) existing.preview = false;
				setActiveIndex(index);
				return existing;
			}
		}
		var insertion = activePane.items.length;
		if (preview) for (index in 0...activePane.items.length) {
			var candidate = UiEditorTabs.document(activePane.items[index]);
			if (candidate == null || !candidate.preview) continue;
			if (candidate.document.dirty) { candidate.preview = false; continue; }
			activePane.items.splice(index, 1); insertion = index; candidate.dispose();
			var shared = false;
			for (other in allViews()) if (other.document == candidate.document) shared = true;
			if (!shared) workspace.documents.close(candidate.document, true);
			break;
		}
		var view = new UiDocumentView(document, new BufferSelection(), scrollSettings);
		view.preview = preview && !document.dirty;
		activePane.items.insert(insertion, UiEditorTab.Document(view));
		setActiveIndex(insertion);
		return view;
	}


	/** Tab labels are read live from `Document.title`/`.dirty` each frame by `ExosuitApp.editorPanel`; there is no cached title to refresh. */
	public function documentRenamed(document:Document):Void {}

	/** EditorPane imports the active view's primary selection on the next UI rebuild. */
	public function cursorChanged():Void {}

	public function textInput(text:String):Void {
		var view = activeView();
		if (view != null) view.textInput(text);
	}

	public function setComposition(text:String, start:Int, length:Int):Void {}
	public function clearComposition():Void {}

	public function setDocumentSearchMatches(matches:Array<SearchMatch>):Void {
		var view = activeView();
		if (view != null) view.setSearchMatches(matches);
	}

	public function showSearchResults(query:String, results:Array<SearchMatch>):Void {
		if (workspaceSearchQuery != query) activateSearch();
		workspaceSearchQuery = query;
		workspaceSearchResults = results;
		requestFrame();
		searchSelected = results.length > 0 ? 0 : -1;
	}

	public function setWorkspaceSearchStatus(complete:Bool, capped:Bool, errorCount:Int):Void {
		searchComplete = complete;
		searchCapped = capped;
		searchErrorCount = errorCount;
		requestFrame();
	}

	public function documentsLostByClosingActiveTab():Array<Document> {
		var view = activeView();
		if (view == null) return [];
		for (other in allViews()) if (other != view && other.document == view.document) return [];
		return [view.document];
	}

	public function closeActiveTab(force:Bool = false):Bool {
		if (activeIndex < 0) return false;
		var lost = documentsLostByClosingActiveTab();
		if (!force) for (document in lost) if (document.dirty) return false;
		var removed = activePane.items.splice(activeIndex, 1);
		UiEditorTabs.dispose(removed[0]);
		for (document in lost) workspace.documents.close(document, true);
		activeIndex = activePane.items.length == 0 ? -1 : Std.int(Math.min(activeIndex, activePane.items.length - 1));
		focus.activate(activeView());
		requestFrame();
		return true;
	}

	public function documentsLostByClosingActivePane():Array<Document> {
		var result:Array<Document> = [];
		if (!canCloseActivePane()) return result;
		for (view in activePane.tabs) {
			var shared = false;
			for (pane in panes) if (pane != activePane)
				for (other in pane.tabs) if (other.document == view.document) shared = true;
			if (!shared && !result.contains(view.document)) result.push(view.document);
		}
		return result;
	}

	public function closeActivePane(force:Bool = false):Bool {
		if (!canCloseActivePane()) return false;
		var lost = documentsLostByClosingActivePane();
		if (!force) for (document in lost) if (document.dirty) return false;
		var removed = activePane;
		panes.remove(removed);
		dockActions.model.unregister(removed.id);
		for (item in removed.items) UiEditorTabs.dispose(item);
		removed.items.resize(0);
		for (document in lost) workspace.documents.close(document, true);
		activatePane(panes[0]);
		return true;
	}

	public function sessionLines():Array<String> {
		var result:Array<String> = [];
		result.push("D\tdock\t1\t" + dockActions.model.snapshotJson());
		result.push("Q\t" + activePane.id);
		if (captureSidebar != null) result.push(captureSidebar());
		for (index in 0...panelTerminals.length) {
			var terminal = panelTerminals[index];
			if (!terminal.disposed && terminal.cwd.indexOf("\t") < 0 && terminal.cwd.indexOf("\n") < 0)
				result.push("Y\t" + (index == activePanelTerminalIndex ? "1" : "0") + "\t" +
					terminal.id + "\t" + terminal.title + "\t" + terminal.cwd);
		}
		for (pane in panes) {
			result.push("P\t" + pane.id);
			for (index in 0...pane.items.length) {
				var item = pane.items[index];
				var terminal = UiEditorTabs.terminal(item);
				if (terminal != null) {
					if (!terminal.disposed && terminal.cwd.indexOf("\t") < 0 && terminal.cwd.indexOf("\n") < 0)
						result.push("X\t" + pane.id + "\t" + (index == pane.activeIndex ? "1" : "0") + "\t" +
							terminal.id + "\t" + terminal.title + "\t" + terminal.cwd);
					continue;
				}
				var view = UiEditorTabs.document(item);
				if (view == null) continue;
				var document = view.document;
				var reference = document.dirty || !document.hasBackingPath() ? document.recoveryId : document.requirePath();
				var kind = document.dirty || !document.hasBackingPath() ? "R" : "P";
				if (reference.indexOf("\t") >= 0 || reference.indexOf("\n") >= 0) continue;
				var location = "\t" + view.cursorLine() + "\t" + view.cursorColumn() + "\t" + view.scrollX() + "\t" + view.scrollY() + "\t" + kind + "\t" + reference;
				result.push("V\t" + pane.id + "\t" + (index == pane.activeIndex ? "1" : "0") + location);
				// Older session readers retain every document through their flat tab format.
				result.push("T\t\t" + (view == activeView() ? "1" : "0") + location);
			}
		}
		result.push("A\t");
		return result;
	}

	function validEditorPaneId(id:String):Bool {
		if (id == "editor") return true;
		if (!StringTools.startsWith(id, "editor-pane-")) return false;
		var suffix = id.substring(12), number = Std.parseInt(suffix);
		return number != null && number > 0 && Std.string(number) == suffix;
	}

	function fallbackDockLayout(node:DockNode, editorId:String):DockNode {
		return switch node {
			case DockNode.Panel(id): DockNode.Panel(id == "editor" ? editorId : id);
			case DockNode.Split(axis, ratio, first, second):
				DockNode.Split(axis, ratio, fallbackDockLayout(first, editorId), fallbackDockLayout(second, editorId));
			case DockNode.Tabs(ids, selected):
				DockNode.Tabs([for (id in ids) id == "editor" ? editorId : id], selected == "editor" ? editorId : selected);
			case DockNode.Empty: DockNode.Empty;
		};
	}

	public function restoreSessionLines(lines:Array<String>, ?resolver:(String, String) -> Null<Document>):Void {
		var retainedTerminals:Map<String, UiTerminalTab> = [];
		for (terminal in allTerminalTabs()) retainedTerminals.set(terminal.id, terminal);
		panelTerminals.resize(0);
		activePanelTerminalIndex = -1;
		focus.activate(null);
		for (view in allViews()) view.dispose();
		for (pane in panes) dockActions.model.unregister(pane.id);
		panes.resize(0);
		var modern = false;
		var snapshot:Null<String> = null, selectedPane:Null<String> = null;
		for (raw in lines) {
			var fields = raw.split("\t");
			if (fields.length == 4 && fields[0] == "D" && fields[1] == "dock" && fields[2] == "1") snapshot = fields[3];
			if (fields.length == 2 && fields[0] == "Q") selectedPane = fields[1];
			if (fields.length != 2 || fields[0] != "P" || !validEditorPaneId(fields[1]) || paneById(fields[1]) != null) continue;
			modern = true;
			var pane = new UiEditorPane(fields[1]);
			panes.push(pane);
			dockActions.model.register(new DockPanelDescriptor(pane.id, "Editor", false, true, null, nativekit.ui.docking.DockPanelHeaderMode.Content, new nativekit.ui.docking.DockPanelGrouping("editors", false)));
			if (pane.id != "editor") {
				var number = Std.parseInt(pane.id.substring(12));
				if (number != null && number >= nextPaneId) nextPaneId = number + 1;
			}
		}
		if (panes.length == 0) {
			var pane = new UiEditorPane("editor");
			panes.push(pane);
			dockActions.model.register(new DockPanelDescriptor(pane.id, "Editor", false, true, null, nativekit.ui.docking.DockPanelHeaderMode.Content, new nativekit.ui.docking.DockPanelGrouping("editors", false)));
		}
		activePane = panes[0];
		for (raw in lines) {
			var fields = raw.split("\t");
			if (fields.length == 5 && fields[0] == "Y") {
				var terminal = resolveTerminal(fields[2], fields[3], fields[4], retainedTerminals);
				if (terminal != null) {
					panelTerminals.push(terminal);
					if (fields[1] == "1" || activePanelTerminalIndex < 0) activePanelTerminalIndex = panelTerminals.length - 1;
				}
				continue;
			}
			if (modern && fields.length == 6 && fields[0] == "X") {
				var pane = paneById(fields[1]);
				var terminal = pane == null ? null : resolveTerminal(fields[3], fields[4], fields[5], retainedTerminals);
				if (pane != null && terminal != null) {
					pane.items.push(UiEditorTab.Terminal(terminal));
					if (fields[2] == "1" || pane.activeIndex < 0) pane.activeIndex = pane.items.length - 1;
				}
				continue;
			}
			if (fields.length != 9 || fields[0] != (modern ? "V" : "T")) continue;
			var pane = modern ? paneById(fields[1]) : panes[0];
			if (pane == null) continue;
			var document = resolver == null ? null : resolver(fields[7], fields[8]);
			if (document == null) continue;
			var view = new UiDocumentView(document, new BufferSelection(), scrollSettings);
			var line = Std.parseInt(fields[3]), column = Std.parseInt(fields[4]);
			if (line != null && column != null) view.restoreCursor(line, column);
			var scrollX = Std.parseInt(fields[5]), scrollY = Std.parseInt(fields[6]);
			if (scrollX != null && scrollY != null) view.restoreScroll(scrollX, scrollY);
			pane.items.push(UiEditorTab.Document(view));
			if (fields[2] == "1" || pane.activeIndex < 0) pane.activeIndex = pane.items.length - 1;
		}
		for (terminal in retainedTerminals) terminal.dispose();
		dockActions.model.setDefaultLayout(fallbackDockLayout(defaultDockLayout, panes[0].id));
		if (snapshot != null) dockActions.model.restoreJson(snapshot);
		if (restoreSidebar != null) restoreSidebar(lines);
		// Invalid/older layouts still reopen every resolved pane and document.
		for (pane in panes) if (!dockActions.model.isOpen(pane.id)) dockActions.model.open(pane.id);
		var requested = selectedPane == null ? null : paneById(selectedPane);
		if (requested != null) activePane = requested;
		dockActions.model.activate(activePane.id);
		pendingEditorFocus = true;
		focus.activate(activeView());
		requestFrame();
	}

	function resolveTerminal(id:String, title:String, cwd:String, retained:Map<String, UiTerminalTab>):Null<UiTerminalTab> {
		for (terminal in allTerminalTabs()) if (terminal.id == id) return null;
		var existing = retained.get(id);
		if (existing != null) {
			retained.remove(id);
			if (!existing.disposed && existing.cwd == cwd && existing.title == title) return existing;
			existing.dispose();
		}
		var create = restoreTerminal;
		return create == null ? null : create(id, title, cwd);
	}

	// -- core.WorkbenchHost: problem / build-output publishing --

	public function setProblemActivationHandler(handler:Problem->Void):Void problemActivationHandler = handler;
	public function activateProblem(problem:Problem):Void problemActivationHandler(problem);

	public function showProblems():Void {
		if (dockActions != null) dockActions.activateProblems();
	}

	public function setBuildDiagnosticHandler(handler:BuildDiagnostic->Void):Void buildDiagnosticHandler = handler;
	public function activateBuildDiagnostic(diagnostic:BuildDiagnostic):Void buildDiagnosticHandler(diagnostic);

	public function showBuildOutput(title:String, output:BuildOutput):Void {
		currentBuildTitle = title;
		currentBuildOutput = output;
		if (dockActions != null) dockActions.activateBuild();
	}

	// -- core.WorkbenchHost: language popups --

	public function textInputArea():Null<TextInputArea> {
		if (activeView() == null || caretRectProvider == null) return null;
		var rect = caretRectProvider();
		return rect == null ? null : new TextInputArea(Std.int(Math.floor(rect.x)),
			Std.int(Math.floor(rect.y)), Std.int(Math.ceil(rect.width)), Std.int(Math.ceil(rect.height)));
	}

	public function openLanguageInformation(area:TextInputArea, text:String):Void {
		languageScroll.jumpTo(0.0, 0.0);
		languageInput = null;
		languageKey = null;
		languageAccept = function(item) {};
		languageArea = area;
		var active = activeDocument();
		languageDocumentId = active == null ? -1 : active.id;
		languageInfoText = text;
		languageItems = [];
		languageSignature = null;
		languageKind = text.length == 0 ? LANG_NONE : LANG_INFO;
		if (languageKind != LANG_NONE) languageCapture.resetFocus();
		requestFrame();
	}

	public function openLanguageCompletion(area:TextInputArea, items:Array<CompletionItem>, accept:CompletionItem->Void, ?input:String->Void, ?key:(Int, Int)->Bool):Void {
		languageInput = input;
		languageKey = key;
		languageArea = area;
		var active = activeDocument();
		languageDocumentId = active == null ? -1 : active.id;
		languageItems = items;
		languageAccept = accept;
		languageSelected = 0;
		languageScroll.jumpTo(0.0, 0.0);
		languageInfoText = "";
		languageSignature = null;
		languageKind = items.length == 0 ? LANG_NONE : LANG_COMPLETION;
		if (languageKind != LANG_NONE) languageCapture.resetFocus();
		requestFrame();
	}

	public function openLanguageSignature(area:TextInputArea, help:SignatureHelp):Void {
		languageScroll.jumpTo(0.0, 0.0);
		languageInput = null;
		languageKey = null;
		languageAccept = function(item) {};
		languageArea = area;
		var active = activeDocument();
		languageDocumentId = active == null ? -1 : active.id;
		languageSignature = help;
		languageItems = [];
		languageInfoText = "";
		languageKind = LANG_SIGNATURE;
		languageCapture.resetFocus();
		requestFrame();
	}

	public function handleLanguagePopupKey(key:Int, modifiers:Int):Bool {
		if (languageKind == LANG_NONE) return false;
		if (key == Platform.KEY_ESCAPE) {
			dismissLanguagePopup();
			return true;
		}
		if (languageKind != LANG_COMPLETION || languageItems.length == 0) return false;
		if (languageKey != null && languageKey(key, modifiers)) return true;
		if (key == Platform.KEY_DOWN) {
			languageSelected = (languageSelected + 1) % languageItems.length;
			revealLanguageSelection();
			requestFrame();
			return true;
		}
		if (key == Platform.KEY_UP) {
			languageSelected = (languageSelected + languageItems.length - 1) % languageItems.length;
			revealLanguageSelection();
			requestFrame();
			return true;
		}
		if (key == Platform.KEY_ENTER || key == Platform.KEY_TAB) {
			var item = languageItems[languageSelected];
			var accept = languageAccept;
			dismissLanguagePopup();
			accept(item);
			return true;
		}
		return false;
	}

	function revealLanguageSelection():Void {
		var top = COMPLETION_PADDING + languageSelected * (COMPLETION_ROW_HEIGHT + COMPLETION_ROW_GAP), bottom = top + COMPLETION_ROW_HEIGHT;
		if (top < languageScroll.offsetY) languageScroll.jumpTo(0.0, top);
		else if (bottom > languageScroll.offsetY + languageScroll.viewportHeight)
			languageScroll.jumpTo(0.0, bottom - languageScroll.viewportHeight);
	}

	public function dismissLanguagePopup():Void {
		if (languageKind != LANG_NONE && activePane.focusTarget != null) dockActions.focusEditor(activePane.focusTarget);
		languageItems = [];
		languageAccept = function(item) {};
		languageInput = null;
		languageKey = null;
		languageKind = LANG_NONE;
		languageArea = null;
		languageDocumentId = -1;
		requestFrame();
	}

	public function isLanguagePopupVisible():Bool return languageKind != LANG_NONE;

	public function handleLanguagePopupText(text:String):Bool {
		if (languageKind != LANG_COMPLETION || languageInput == null) return false;
		languageInput(text);
		return true;
	}

	// -- core.WorkbenchHost: settings & one-time wiring --

	/** Updates motion settings for existing and future document panes. */
	public function applySettings(settings:Settings):Bool {
		scrollSettings = settings.copy();
		for (view in allViews()) view.applyScrollSettings(scrollSettings);
		return true;
	}

	public function configureFileActions(actions:FileActions):Void fileActions = actions;
	public function configureWelcomeActions(actions:WelcomeActions):Void welcomeActions = actions;

	// -- Overlay presentation (uikit-specific; not part of core.WorkbenchHost) --

	/** The command-view or language-popup overlay to render this frame, or null for neither. */
	public function overlayView():Null<NkView> {
		if (commandView.active) return commandViewCapture;
		if (languageKind != LANG_NONE) {
			var active = activeDocument();
			if (active == null || active.id != languageDocumentId) dismissLanguagePopup();
			else return languageCapture;
		}
		return null;
	}

	function buildCommandViewContent():NkView {
		return new OverlayBuilderView(function(context) {
			var rows:Array<KeyedView> = [];
			for (index in 0...commandView.results.length) {
				var entry = commandView.results[index], provider = commandViewProvider;
				var label = entry.label + (entry.detail.length > 0 ? "  " + entry.detail : "")
					+ (entry.trailing.length > 0 ? "   [" + entry.trailing + "]" : "");
				var button = new Button(label, null, function() {
					if (provider != null) provider.onAccept(entry, commandView.query, false);
				}, "cv-row-" + index);
				button.variant = index == commandView.selected ? ButtonVariant.Primary : ButtonVariant.Secondary;
				rows.push(new KeyedView("row" + index, button));
			}
			var listStyle = new LayoutStyle();
			listStyle.width = LayoutAxis.grow();
			var list = new Column("cv-rows", rows, listStyle);
			var scrollStyle = new LayoutStyle();
			scrollStyle.width = LayoutAxis.fixed(520.0);
			scrollStyle.height = LayoutAxis.fixed(320.0);
			scrollStyle.background = Color.rgba(0.11, 0.11, 0.13, 0.98);
			var scroll = new ScrollView("cv-scroll", list, scrollStyle);
			var promptStyle = new LayoutStyle();
			promptStyle.width = LayoutAxis.fixed(520.0);
			promptStyle.padding = new Insets(10.0, 8.0, 10.0, 8.0);
			promptStyle.background = Color.rgba(0.16, 0.16, 0.19, 1.0);
			var prompt = commandViewProvider == null ? "" : commandViewProvider.prompt;
			var input = new Text(prompt + commandView.query + "█", promptStyle, Color.rgba(1.0, 1.0, 1.0, 1.0),
				TextStyleOverride.text(14.0));
			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.fixed(520.0);
			var content = new Column("cv-content", [new KeyedView("input", input), new KeyedView("list", scroll)], contentStyle);
			return new Popup("command-view", content, 40.0, 40.0, null, function() {
				if (commandView.active) commandView.close(true);
			});
		});
	}

	function buildLanguagePopupContent():NkView {
		return new OverlayBuilderView(function(context) {
			var rows:Array<NkView> = [];
			var panelStyle = new LayoutStyle();
			panelStyle.width = LayoutAxis.fixed(Math.max(1.0, Math.min(380.0, context.viewportWidth - 16.0)));
			panelStyle.padding = new Insets(10.0, COMPLETION_PADDING, 10.0, COMPLETION_PADDING);
			panelStyle.background = Color.rgba(0.11, 0.11, 0.13, 0.98);
			panelStyle.direction = LayoutDirection.TopToBottom;
			panelStyle.childGap = COMPLETION_ROW_GAP;
			switch languageKind {
				case LANG_COMPLETION:
					for (index in 0...languageItems.length) {
						var item = languageItems[index];
						var rowStyle = new LayoutStyle();
						rowStyle.width = LayoutAxis.grow();
						rowStyle.height = LayoutAxis.fixed(COMPLETION_ROW_HEIGHT);
						rowStyle.direction = LayoutDirection.LeftToRight;
						var color = index == languageSelected ? Color.rgba(1.0, 1.0, 1.0, 1.0) : Color.rgba(0.75, 0.75, 0.78, 1.0);
						rows.push(new Row("lang-row-" + index,
							[
								new KeyedView("label", new Text(item.label, null, color, TextStyleOverride.text(13.0))),
								new KeyedView("detail", new Text("  " + item.detail, null, Color.rgba(0.6, 0.6, 0.65, 1.0), TextStyleOverride.text(12.0)))
							], rowStyle));
					}
				case LANG_SIGNATURE:
					var help = languageSignature;
					if (help != null) {
						rows.push(new Text(help.label, null, Color.rgba(1.0, 1.0, 1.0, 1.0), TextStyleOverride.text(13.0)));
						if (help.documentation.length > 0)
							rows.push(new Text(help.documentation, null, Color.rgba(0.75, 0.75, 0.78, 1.0), TextStyleOverride.text(12.0)));
					}
				default:
					rows.push(new Text(languageInfoText, null, Color.rgba(1.0, 1.0, 1.0, 1.0), TextStyleOverride.text(13.0)));
			}
			var keyed:Array<KeyedView> = [for (index in 0...rows.length) new KeyedView("row" + index, rows[index])];
			var content = new Column("lang-content", keyed, panelStyle);
			var area = textInputArea();
			if (area == null) area = languageArea;
			var scrollStyle = new LayoutStyle();
			scrollStyle.width = panelStyle.width;
			var maxHeight = Math.max(1.0, context.viewportHeight - 16.0);
			if (languageKind == LANG_COMPLETION) maxHeight = Math.min(COMPLETION_MAX_HEIGHT, maxHeight);
			scrollStyle.height = LayoutAxis.fit(0.0, maxHeight);
			var scroll = new ScrollView("language-scroll", content, scrollStyle, nativekit.ui.widgets.scroll.ScrollAxis.Vertical, languageScroll);
			var popup = new Popup("language-popup", scroll, area == null ? 0.0 : area.x,
				area == null ? 0.0 : area.y + area.height, null, dismissLanguagePopup);
			popup.modal = false;
			popup.anchorRectProvider = caretRectProvider;
			return popup;
		});
	}
}

/** Rebuild an overlay with the current viewport and retained UI context each frame. */
private class OverlayBuilderView implements NkView {
	final factory:nativekit.ui.core.BuildContext->NkView;

	public function new(factory:nativekit.ui.core.BuildContext->NkView) {
		this.factory = factory;
	}

	public function build(context:nativekit.ui.core.BuildContext):nativekit.ui.core.RenderNode
		return factory(context).build(context);
}

/**
 * uikit-side actions `UiWorkbenchHost` needs from `ExosuitApp`'s
 * `DockWorkspaceModel`, wired once when `ExosuitApp` builds this host
 * (mirroring how `core.Application` wires `FileActions`/`WelcomeActions`
 * into the host, just in the other direction).
 */
typedef DockActions = {
	model:DockWorkspaceModel,
	focusEditor:WidgetId->Void,
	editorPreedit:(WidgetId, nativekit.ui.core.UiEvent)->Void,
	toggleSidebar:Void->Bool,
	activateExplorer:Void->Void,
	activateProblems:Void->Void,
	activateBuild:Void->Void
}
