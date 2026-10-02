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
 * `core.WorkbenchHost` reachable through the everyday `Void->Bool`-ish
 * headless call shapes the eight controllers already call (see that
 * interface's doc comment), backed by uikit widgets instead of
 * `view.RootView`'s pixel-drawn split-pane tree. Owns the one thing this
 * shell's editor region actually has - an ordered list of open document
 * tabs and which one is active - and the state machines for the two
 * overlay surfaces (the command view, and hover/completion/signature
 * "language popups"), which `ui.ExosuitApp.view()` renders each frame via
 * `overlayView()` and drives via `KeyCaptureView`.
 *
 * `focusPane`/`moveActiveTab` are no-ops (see their doc comments): this
 * shell's `DockWorkspace` has exactly one editor region today, so there is
 * no second pane for either to act on yet. `reorderActiveTab` and
 * `toggleSidebar` are real. `applySettings` has nothing to apply (uikit's
 * fonts are owned by `DesktopUiHostContext`, set up once at host startup).
 */
class UiWorkbenchHost implements WorkbenchHost {
	final theme:Theme;
	final focus:FocusManager;
	final workspace:Workspace;
	final requestFrame:Void->Void;
	final dockActions:DockActions;

	final problems:ProblemRegistry = new ProblemRegistry();
	final pluginDecorations:PluginDecorationRegistry = new PluginDecorationRegistry();
	final pluginStatusItems:PluginStatusRegistry = new PluginStatusRegistry();
	final pluginPanels:PluginPanelRegistry = new PluginPanelRegistry();
	final notifications:NotificationCenter = new NotificationCenter();
	final tabList:Array<UiDocumentView> = [];
	public var tabs(get, never):Array<UiDocumentView>;
	public var activeIndex(default, null):Int = -1;
	public var fileActions(default, null):Null<FileActions>;
	public var welcomeActions(default, null):Null<WelcomeActions>;

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
	public var caretRectProvider:Null<Void->Null<Rect>>;
	var languageArea:Null<TextInputArea>;
	var languageDocumentId:Int = -1;
	var languageKind:Int = LANG_NONE;
	var languageInfoText:String = "";
	var languageItems:Array<CompletionItem> = [];
	var languageAccept:CompletionItem->Void = function(item) {};
	var languageSelected:Int = 0;
	var languageSignature:Null<SignatureHelp>;
	final languageCapture:KeyCaptureView;

	var workspaceSearchQuery:String = "";
	var workspaceSearchResults:Array<SearchMatch> = [];
	var searchSelected:Int = -1;
	var searchComplete:Bool = false;
	var searchCapped:Bool = false;
	var searchErrorCount:Int = 0;

	public function new(theme:Theme, focus:FocusManager, workspace:Workspace, settings:Settings, requestFrame:Void->Void,
			dockActions:DockActions) {
		this.caretRectProvider = null;
		this.languageArea = null;
		this.theme = theme;
		this.focus = focus;
		this.workspace = workspace;
		this.requestFrame = requestFrame;
		this.dockActions = dockActions;
		commandViewCapture = new KeyCaptureView(buildCommandViewContent(), commandViewKeyPressed, commandViewTextInput);
		// Mirrors controller.WorkbenchController.textInput's headless behavior: typing while a
		// language popup is open dismisses it rather than being swallowed silently.
		languageCapture = new KeyCaptureView(buildLanguagePopupContent(), handleLanguagePopupKey, function(text) dismissLanguagePopup());
	}

	function get_tabs():Array<UiDocumentView>
		return tabList;

	public function dispose():Void {
		for (view in tabList) view.dispose();
		tabList.resize(0);
		activeIndex = -1;
	}

	public function activeView():Null<UiDocumentView>
		return activeIndex >= 0 && activeIndex < tabList.length ? tabList[activeIndex] : null;

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
	public function activateTab(document:Document):Void {
		for (index in 0...tabList.length)
			if (tabList[index].document == document) {
				setActiveIndex(index);
				return;
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

	/**
	 * No pane geometry to search: this shell's `DockWorkspace` has exactly
	 * one editor region, so there is nothing to focus into or move a tab
	 * toward yet (a future split-editing feature would need to teach this
	 * host the dock's pane adjacency).
	 */
	public function focusPane(horizontal:Int, vertical:Int):Bool return false;
	public function moveActiveTab(horizontal:Int, vertical:Int):Bool return false;

	public function reorderActiveTab(delta:Int):Bool {
		if (activeIndex < 0) return false;
		var target = activeIndex + delta;
		if (target < 0 || target >= tabList.length) return false;
		var view = tabList.splice(activeIndex, 1)[0];
		tabList.insert(target, view);
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
		var match = workspaceSearchResults[searchSelected];
		var view = openDocument(workspace.documents.open(match.path));
		var document = view.getDocument();
		if (document != null && DocumentSearch.valid(document, match)) {
			view.selectRange(new BufferPosition(match.line, match.column), new BufferPosition(match.line, match.column + match.length));
			view.cursorChanged();
		}
		return true;
	}

	public function focusedFilePath():Null<String> return selectedExplorerPath;

	/**
	 * No separate "pane" yet distinct from the one editor region's tab
	 * strip (see `focusPane`'s doc comment), so there is nothing for
	 * "close pane" to collapse into.
	 */
	public function canCloseActivePane():Bool return false;

	// -- core.WorkbenchHost: open/activate document & active-editor input --

	public function openDocument(document:Document):View {
		for (index in 0...tabList.length)
			if (tabList[index].document == document) {
				setActiveIndex(index);
				return tabList[index];
			}
		var view = new UiDocumentView(document, new BufferSelection());
		tabList.push(view);
		setActiveIndex(tabList.length - 1);
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
		workspaceSearchQuery = query;
		workspaceSearchResults = results.copy();
		searchSelected = results.length > 0 ? 0 : -1;
	}

	public function setWorkspaceSearchStatus(complete:Bool, capped:Bool, errorCount:Int):Void {
		searchComplete = complete;
		searchCapped = capped;
		searchErrorCount = errorCount;
	}

	public function documentsLostByClosingActiveTab():Array<Document> {
		var view = activeView();
		return view == null ? [] : [view.document];
	}

	public function closeActiveTab(force:Bool = false):Bool {
		if (activeIndex < 0) return false;
		var removed = tabList.splice(activeIndex, 1);
		removed[0].dispose();
		activeIndex = tabList.length == 0 ? -1 : (activeIndex >= tabList.length ? tabList.length - 1 : activeIndex);
		focus.activate(activeView());
		requestFrame();
		return true;
	}

	public function documentsLostByClosingActivePane():Array<Document> return [];
	public function closeActivePane(force:Bool = false):Bool return false;

	public function sessionLines():Array<String> {
		var result:Array<String> = [];
		for (index in 0...tabList.length) {
			var view = tabList[index], document = view.document,
				reference = document.dirty || !document.hasBackingPath() ? document.recoveryId : document.requirePath(),
				kind = document.dirty || !document.hasBackingPath() ? "R" : "P";
			if (reference.indexOf("\t") >= 0 || reference.indexOf("\n") >= 0) continue;
			result.push("T\t\t" + (index == activeIndex ? "1" : "0") + "\t" + view.cursorLine() + "\t" + view.cursorColumn()
				+ "\t0\t0\t" + kind + "\t" + reference);
		}
		result.push("A\t");
		return result;
	}

	public function restoreSessionLines(lines:Array<String>, ?resolver:(String, String) -> Null<Document>):Void {
		for (view in tabList) view.dispose();
		tabList.resize(0);
		activeIndex = -1;
		var restoreActive = -1;
		for (raw in lines) {
			var fields = raw.split("\t");
			if (fields.length != 9 || fields[0] != "T") continue;
			var document = resolver == null ? null : resolver(fields[7], fields[8]);
			if (document == null) continue;
			var view = new UiDocumentView(document, new BufferSelection());
			var line = Std.parseInt(fields[3]), column = Std.parseInt(fields[4]);
			if (line != null && column != null) view.restoreCursor(line, column);
			tabList.push(view);
			if (fields[2] == "1") restoreActive = tabList.length - 1;
		}
		activeIndex = restoreActive >= 0 ? restoreActive : (tabList.length > 0 ? 0 : -1);
		focus.activate(activeView());
		requestFrame();
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

	public function openLanguageCompletion(area:TextInputArea, items:Array<CompletionItem>, accept:CompletionItem->Void):Void {
		languageArea = area;
		var active = activeDocument();
		languageDocumentId = active == null ? -1 : active.id;
		languageItems = items;
		languageAccept = accept;
		languageSelected = 0;
		languageInfoText = "";
		languageSignature = null;
		languageKind = items.length == 0 ? LANG_NONE : LANG_COMPLETION;
		if (languageKind != LANG_NONE) languageCapture.resetFocus();
		requestFrame();
	}

	public function openLanguageSignature(area:TextInputArea, help:SignatureHelp):Void {
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
		if (key == Platform.KEY_DOWN) {
			languageSelected = (languageSelected + 1) % languageItems.length;
			requestFrame();
			return true;
		}
		if (key == Platform.KEY_UP) {
			languageSelected = (languageSelected + languageItems.length - 1) % languageItems.length;
			requestFrame();
			return true;
		}
		if (key == Platform.KEY_ENTER || key == Platform.KEY_TAB) {
			var item = languageItems[languageSelected];
			dismissLanguagePopup();
			languageAccept(item);
			return true;
		}
		return false;
	}

	public function dismissLanguagePopup():Void {
		languageKind = LANG_NONE;
		languageArea = null;
		languageDocumentId = -1;
		requestFrame();
	}

	public function isLanguagePopupVisible():Bool return languageKind != LANG_NONE;

	// -- core.WorkbenchHost: settings & one-time wiring --

	/**
	 * uikit's fonts are loaded once into `DesktopUiHostContext.fonts` at host
	 * startup (see `app.GraphicalMain`); this host has no hook to hot-reload
	 * a different font path/size from `Settings`, so there is nothing to
	 * apply and nothing that can fail to apply.
	 */
	public function applySettings(settings:Settings):Bool return true;

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
			panelStyle.padding = new Insets(10.0, 8.0, 10.0, 8.0);
			panelStyle.background = Color.rgba(0.11, 0.11, 0.13, 0.98);
			panelStyle.direction = LayoutDirection.TopToBottom;
			panelStyle.childGap = 4.0;
			switch languageKind {
				case LANG_COMPLETION:
					for (index in 0...languageItems.length) {
						var item = languageItems[index];
						var rowStyle = new LayoutStyle();
						rowStyle.width = LayoutAxis.grow();
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
			scrollStyle.height = LayoutAxis.fit(0.0, Math.max(1.0, context.viewportHeight - 16.0));
			var scroll = new ScrollView("language-scroll", content, scrollStyle);
			var popup = new Popup("language-popup", scroll, area == null ? 0.0 : area.x,
				area == null ? 0.0 : area.y + area.height, null, dismissLanguagePopup);
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
	toggleSidebar:Void->Bool,
	activateExplorer:Void->Void,
	activateProblems:Void->Void,
	activateBuild:Void->Void
}
