package ui;

import Insets;
import LayoutAxis;
import LayoutDirection;
import LayoutAlignmentY;
import LayoutFrame;
import LayoutStyle;
import FontCollection;
import sys.FileSystem;
import nativekit.ui.core.Command;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.Shortcut;
import nativekit.ui.core.UiContext;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;
import nativekit.ui.core.View;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.docking.DockNode;
import nativekit.ui.docking.DockPanelDescriptor;
import nativekit.ui.docking.DockSplitAxis;
import nativekit.ui.docking.DockDropZone;
import nativekit.ui.docking.DockWorkspaceModel;
import nativekit.ui.host.DesktopUiApplication;
import nativekit.ui.host.UiHostContext;
import platform.HostFileDialogs;
import nativekit.ui.icons.IconName;
import nativekit.ui.theme.Theme;
import nativekit.ui.style.EnvironmentColorScheme;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;
import nativekit.ui.widgets.controls.TabItem;
import nativekit.ui.widgets.controls.Tabs;
import nativekit.ui.widgets.collections.TreeView;
import nativekit.ui.widgets.commands.CommandPalette;
import nativekit.ui.widgets.docking.DockPanelContent;
import nativekit.ui.widgets.docking.DockWorkspace;
import nativekit.ui.widgets.layout.AppShell;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.layout.Spacer;
import nativekit.ui.widgets.layout.Stack;
import nativekit.ui.widgets.layout.StackChild;
import nativekit.ui.widgets.text.Text;
import core.Application;
import platform.HostCapabilities;
import platform.HostCapability;
import feedback.NotificationKind;
import ui.BuildOutputPanel;
import ui.ProblemsPanel;
import ui.UiDocumentView;
import ui.UiWorkbenchHost;

/**
 * exosuit's graphical shell: `DesktopUiHost` owns the window, GPU, and frame
 * loop; this class builds the uikit view tree and owns one `core.Application`
 * (constructed with `UiWorkbenchHost` as its `core.WorkbenchHost`), so open,
 * save, close, dirty tracking, session restore/recovery, search, build
 * tasks, and the Haxeon language client all run through the same
 * controllers the 14 headless tests exercise against `view.RootView` - just
 * against this uikit-backed host instead. See `UiWorkbenchHost`'s doc
 * comment for what it owns on `Application`'s behalf (the open document
 * tabs, and the command-view/language-popup overlays this class renders
 * via `overlayView()`), and `CommandBridge` for how `application.commands`
 * reaches this shell's own `ui.commands`-backed `CommandPalette`.
 */
class ExosuitApp implements DesktopUiApplication {
	public final ui:UiContext;
	public final theme:Theme;
	final darkPalette:Bool;
	final editorPalette:style.Theme;
	final terminalPalette:TerminalPalette;
	public final application:Application;
	public final capabilities:HostCapabilities;
	public final host:UiWorkbenchHost;
	final desktop:Null<HostFileDialogs>;
	final hostContext:Null<UiHostContext>;
	final dock:DockWorkspaceModel;
	var dockPanelContents:Array<DockPanelContent>;
	final editorPanes:Map<Int, EditorPane> = new Map();
	var terminalPane:Null<TerminalPanel>;
	final createTerminal:Null<(String, Void->Void, TerminalPalette)->TerminalPanel>;
	var explorerRoot:Null<String>;
	var explorerModel:Null<DirectoryTreeModel>;
	var statusMessage:String = "Ready";
	var paletteVisible:Bool = false;
	var viewportWidth:Float = 1280.0;
	var viewportHeight:Float = 840.0;
	static inline var TOOLBAR_HEIGHT:Float = 40.0;
	static inline var STATUS_HEIGHT:Float = 26.0;

	public function new(?fonts:FontCollection, ?theme:Theme, ?hostContext:UiHostContext,
			?openPath:String, ?capabilities:HostCapabilities, ?fileDialogs:HostFileDialogs,
			?dark:Bool, ?createTerminal:(String, Void->Void, TerminalPalette)->TerminalPanel) {
		this.createTerminal = createTerminal;
		this.capabilities = capabilities == null ? HostCapabilities.desktop() : capabilities;
		this.hostContext = hostContext;
		darkPalette = dark == null ? true : dark;
		this.theme = theme == null ? ExosuitPalette.theme(darkPalette) : theme;
		terminalPalette = new TerminalPalette(darkPalette);
		ui = new UiContext(null, fonts, this.theme);
		ui.buildContext.environment.colorScheme = darkPalette ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		desktop = fileDialogs;
		if (hostContext != null) hostContext.onCloseRequested = function(close) close();
		dock = makeDock();
		if (openPath == null) dock.close("explorer");
		var capturedHost:UiWorkbenchHost = null;
		application = new Application(function(exosuitTheme, focus, workspace, settings) {
			capturedHost = new UiWorkbenchHost(exosuitTheme, focus, workspace, settings, requestFrame, {
				toggleSidebar: toggleExplorerVisible,
				activateExplorer: function() dock.activate("explorer"),
				activateProblems: function() dock.activate("problems"),
				activateBuild: function() dock.activate("build")
			});
			return capturedHost;
		}, null, null, this.capabilities);
		host = capturedHost;
		editorPalette = darkPalette ? application.theme : ExosuitPalette.lightEditor();
		installCommands();
		application.session.start();
		if (openPath != null) openArgument(openPath);
	}

	function makeDock():DockWorkspaceModel {
		var model = new DockWorkspaceModel();
		model.register(new DockPanelDescriptor("explorer", "Explorer", true, true, IconName.FolderOpen));
		model.register(new DockPanelDescriptor("editor", "Editor", false, true, IconName.NewFile));
		model.register(new DockPanelDescriptor("problems", "Problems", true, true));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("build", "Build Output", true, true, IconName.Terminal));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("terminal", "Terminal", true, true, IconName.Terminal));
		dockPanelContents = [
			new DockPanelContent("explorer", function(_) return explorerPanel()),
			new DockPanelContent("editor", function(_) return editorPanel()),
			new DockPanelContent("problems", function(_) return new ProblemsPanel(host))
		];
		if (capabilities.supports(Processes))
			dockPanelContents.push(new DockPanelContent("build", function(_) return new BuildOutputPanel(host)));
		if (capabilities.supports(Processes))
			dockPanelContents.push(new DockPanelContent("terminal", function(_) return terminalPanel()));
		var bottom = capabilities.supports(Processes) ? DockNode.Tabs(["problems", "build"], "problems") : DockNode.Panel("problems");
		var main = DockNode.Split(DockSplitAxis.Horizontal, 0.22,
			DockNode.Panel("explorer"),
			DockNode.Split(DockSplitAxis.Vertical, 0.72, DockNode.Panel("editor"),
				bottom));
		model.setDefaultLayout(main);
		return model;
	}

	function toggleExplorerVisible():Bool {
		if (explorerRoot == null) { openFolderDialog(); return true; }
		return dock.isOpen("explorer") ? dock.close("explorer") : openExplorer();
	}

	function openExplorer():Bool {
		if (dock.isOpen("explorer")) return dock.activate("explorer");
		if (!dock.dock("explorer", "editor", DockDropZone.Left)) return false;
		dock.setSplitRatio([0], 0.22);
		return true;
	}

	public function openTerminal():Void {
		if (!capabilities.supports(Processes)) return;
		if (terminalPane == null) {
			if (createTerminal == null) return;
			terminalPane = createTerminal(explorerRoot == null ? Sys.getCwd() : explorerRoot,
				requestFrame, terminalPalette);
		}
		if (!dock.isOpen("terminal")) dock.open("terminal", "build");
		dock.activate("terminal");
		requestFrame();
	}

	function toggleTerminal():Void {
		if (dock.isOpen("terminal")) {
			dock.close("terminal");
			if (terminalPane != null) {
				terminalPane.close();
				terminalPane = null;
			}
			requestFrame();
		} else openTerminal();
	}

	function terminalPanel():View
		return terminalPane == null ? placeholderPanel("Terminal is closed.") : terminalPane;

	function installCommands():Void {
		// UiKey has no N/O/W/P constants, so these follow the raw-ASCII-code
		// convention the canonical reference (app/src/Main.hx) uses for the same
		// keys.
		ui.commands.register(new Command("file.new", "New File", function() application.newDocument(),
			new Shortcut(78 /* N */, UiModifier.Control)));
		ui.commands.register(new Command("file.open", "Open File...", openFileDialog,
			new Shortcut(79 /* O */, UiModifier.Control)));
		ui.commands.register(new Command("file.open-folder", "Open Folder...", openFolderDialog,
			new Shortcut(79 /* O */, UiModifier.Control | UiModifier.Shift)));
		// "doc:save" (controller.FileController) already covers the save-as-needed
		// and disk-conflict-confirmation flows; this id just gives it a shortcut
		// and a toolbar button rather than duplicating that logic.
		ui.commands.register(new Command("file.save", "Save", function() application.commands.perform("doc:save", application.context),
			new Shortcut(UiKey.S, UiModifier.Control)));
		ui.commands.register(new Command("file.close-tab", "Close Tab", function() application.requestCloseActiveTab(),
			new Shortcut(87 /* W */, UiModifier.Control)));
		ui.commands.register(new Command("view.toggle-palette", "Toggle Command Palette",
			togglePalette, new Shortcut(80 /* P */, UiModifier.Control | UiModifier.Shift)));
		if (capabilities.supports(Processes))
			ui.commands.register(new Command("view.terminal", "Toggle Terminal", toggleTerminal,
				new Shortcut(96 /* ` */, UiModifier.Control)));
		CommandBridge.install(ui.commands, application.commands, application.keymap, application.context);
	}

	public function view():View {
		var workspaceView = new DockWorkspace("exosuit-workspace", dock, dockPanelContents);
		workspaceView.availableHeight = Math.max(0.0, viewportHeight - TOOLBAR_HEIGHT - STATUS_HEIGHT);
		var workspace:View = explorerRoot == null && !dock.isOpen("explorer")
			? new Row("workspace-with-rail", [new KeyedView("rail", explorerRail()),
				new KeyedView("workspace", workspaceView)], fillStyle())
			: workspaceView;
		var body = new Column("exosuit-body", [
			new KeyedView("workspace", workspace),
			new KeyedView("status", statusBar())
		], fillStyle());
		var shellStyle = fillStyle();
		shellStyle.background = theme.tokens.surface;
		var layers:Array<StackChild> = [new StackChild("shell", new AppShell("exosuit-shell", body,
			topBar(), null, null, shellStyle), 0.0, 0.0, 0, LayoutAxis.grow(), LayoutAxis.grow())];
		if (paletteVisible) {
			var palette = new CommandPalette("exosuit-command-palette", ui.commands,
				ui.commandContext, 320.0, 120.0, "", function() { paletteVisible = false; },
				function(_) { paletteVisible = false; });
			layers.push(new StackChild("palette", palette, 0.0, 0.0, 20));
		}
		var overlay = host.overlayView();
		if (overlay != null) layers.push(new StackChild("host-overlay", overlay, 0.0, 0.0, 30));
		return new Stack("exosuit-overlay-host", layers);
	}

	public function submit(frame:LayoutFrame):RenderNode {
		viewportWidth = frame.width;
		viewportHeight = frame.height;
		pumpApplication();
		return ui.submit(view(), frame);
	}

	/**
	 * Runs `Application.update()` (settings reload, search jobs, session
	 * autosave/recovery, plugin/build/language polling) every rendered frame,
	 * and asks the host for another frame while a build task or the language
	 * server has work outstanding, so that work keeps draining even if
	 * `DesktopUiHost` would otherwise wait for the next input event.
	 */
	function pumpApplication():Void {
		application.update();
		if (terminalPane != null) {
			if (!dock.isOpen("terminal")) {
				terminalPane.close();
				terminalPane = null;
			} else try {
				terminalPane.poll();
			} catch (error:Dynamic) {
				statusMessage = "Terminal: " + Std.string(error);
				terminalPane.close();
				terminalPane = null;
			}
		}
		if (application.build.active != null || application.language.client != null) requestFrame();
	}

	public function context():UiContext return ui;

	public function dispose():Void {
		if (terminalPane != null) {
			terminalPane.close();
			terminalPane = null;
		}
		application.shutdown();
		if (desktop != null) desktop.shutdown();
		ui.dispose();
	}

	public function diagnosticState():Dynamic {
		var active = host.activeDocument();
		return {
			documents: [for (view in host.tabs) view.document.title],
			active: active == null ? -1 : active.id,
			documentsSource: "core.Application (via UiWorkbenchHost)",
			explorerRoot: explorerRoot,
			panels: dock.panelIds(),
			status: statusMessage,
			paletteCommandCount: ui.commands.ids().length,
			errors: [for (entry in application.errors.entries) {source: entry.source, message: entry.message}],
			plugins: application.plugins.enabledIds(),
			terminal: terminalPane == null ? "closed" : terminalPane.status(),
			terminalColumns: terminalPane == null ? 0 : terminalPane.columns(),
			terminalRows: terminalPane == null ? 0 : terminalPane.rows()
		};
	}

	function topBar():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(TOOLBAR_HEIGHT);
		style.direction = LayoutDirection.LeftToRight;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 6.0;
		style.padding = new Insets(10.0, 4.0, 10.0, 4.0);
		style.background = theme.tokens.surfaceRaised;
		var titleStyle = new LayoutStyle();
		titleStyle.width = LayoutAxis.fixed(80.0);
		var items:Array<KeyedView> = [
			new KeyedView("brand", new Text("EXOSUIT", titleStyle, theme.tokens.text,
				TextStyleOverride.text(13.0, 0.5))),
			new KeyedView("new", toolbarButton("New", IconName.NewFile, function() application.newDocument())),
			new KeyedView("open", toolbarButton("Open", IconName.FolderOpen, openFileDialog)),
			new KeyedView("open-folder", toolbarButton("Open Folder", IconName.FolderOpen,
				openFolderDialog)),
			new KeyedView("save", toolbarButton("Save", IconName.Save,
				function() application.commands.perform("doc:save", application.context)))
		];
		if (capabilities.supports(Processes))
			items.push(new KeyedView("terminal", toolbarButton("Terminal", IconName.Terminal, toggleTerminal)));
		items.push(new KeyedView("space", new Spacer("toolbar-space", LayoutAxis.grow(), LayoutAxis.fixed(1.0))));
		items.push(new KeyedView("status", new Text(statusMessage, null, theme.tokens.textSecondary,
			TextStyleOverride.text(12.0))));
		items.push(new KeyedView("palette", toolbarButton("Commands", IconName.Terminal, togglePalette)));
		return new Row("exosuit-toolbar", items, style);
	}

	function toolbarButton(label:String, icon:IconName, action:Void->Void):Button {
		var button = new Button(label, null, action, "toolbar-" + label);
		button.variant = ButtonVariant.Secondary;
		button.leadingIcon = icon;
		return button;
	}

	function statusBar():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(STATUS_HEIGHT);
		style.direction = LayoutDirection.LeftToRight;
		style.childAlignY = LayoutAlignmentY.Center;
		style.padding = new Insets(10.0, 2.0, 10.0, 2.0);
		style.background = theme.tokens.surfaceRaised;
		var active = host.activeDocument();
		var label = active == null ? "No document open" :
			(active.title + (active.dirty ? " *" : "") + " - " + active.encodingLabel());
		var notification = application.root.getNotifications().current();
		var trailing = notification == null ? '${host.tabs.length} open' : notification.message;
		return new Row("exosuit-status", [
			new KeyedView("document", new Text(label, null, theme.tokens.textSecondary,
				TextStyleOverride.text(12.0))),
			new KeyedView("space", new Spacer("status-space", LayoutAxis.grow(), LayoutAxis.fixed(1.0))),
			new KeyedView("notification", new Text(trailing, null,
				notification != null && notification.kind == NotificationKind.Error ? theme.tokens.text : theme.tokens.textSecondary,
				TextStyleOverride.text(12.0)))
		], style);
	}

	function explorerPanel():View {
		if (explorerRoot == null) {
			var open = new Button("Open", null, openFolderDialog, "explorer-open-folder");
			open.variant = ButtonVariant.Secondary;
			open.leadingIcon = IconName.FolderOpen;
			var compact = new LayoutStyle();
			compact.width = LayoutAxis.grow();
			compact.padding = new Insets(4.0, 8.0, 4.0, 8.0);
			return new Column("explorer-empty", [new KeyedView("open", open)], compact);
		}
		if (explorerModel == null) explorerModel = new DirectoryTreeModel(explorerRoot, theme);
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.grow();
		viewportStyle.height = LayoutAxis.grow();
		return new TreeView("exosuit-explorer-tree", explorerModel, viewportStyle, null, 640.0,
			null, [explorerRoot], function(key) { host.setSelectedExplorerPath(key); }, function(key) {
				if (!FileSystem.isDirectory(key)) application.open(key);
			}, null, null);
	}

	function explorerRail():View {
		var railStyle = new LayoutStyle();
		railStyle.width = LayoutAxis.fixed(56.0);
		railStyle.height = LayoutAxis.grow();
		railStyle.padding = new Insets(8.0, 8.0, 8.0, 8.0);
		railStyle.background = theme.tokens.surfaceRaised;
		var buttonStyle = new LayoutStyle();
		buttonStyle.width = LayoutAxis.fixed(40.0);
		buttonStyle.height = LayoutAxis.fixed(36.0);
		var open = new Button("", buttonStyle, openFolderDialog, "rail-open-folder");
		open.leadingIcon = IconName.FolderOpen;
		open.accessibilityLabel = "Open Folder";
		return new Column("explorer-rail", [new KeyedView("open", open)], railStyle);
	}

	function editorPanel():View {
		var tabs = host.tabs;
		if (tabs.length == 0) return welcomePanel();
		pruneStaleEditorPanes(tabs);
		var items:Array<TabItem> = [];
		for (documentView in tabs) {
			var document = documentView.document;
			// Reused across frames (not rebuilt each `view()` call) so its
			// `BufferSelection` (shared with `documentView`, see `UiDocumentView`'s
			// doc comment) persists between edits instead of resetting.
			var pane = editorPanes.get(document.id);
			if (pane == null) {
				pane = new EditorPane(document, theme, requestFrame, documentView.selection, editorPalette,
					host.getPluginDecorations(), documentView.decorationSearchMatches, documentView.searchDecorationRevision);
				editorPanes.set(document.id, pane);
			}
			items.push(new TabItem("doc:" + document.id, (document.dirty ? "* " : "") + document.title,
				pane));
		}
		var tabsStyle = new LayoutStyle();
		tabsStyle.width = LayoutAxis.grow();
		tabsStyle.height = LayoutAxis.grow();
		tabsStyle.direction = LayoutDirection.TopToBottom;
		tabsStyle.childGap = 8.0;
		var active = host.activeDocument();
		return new Tabs("exosuit-editor-tabs", items, active == null ? "" : "doc:" + active.id, function(key) {
			var id = Std.parseInt(StringTools.replace(key, "doc:", ""));
			if (id == null) return;
			for (documentView in tabs)
				if (documentView.document.id == id) {
					host.activateTab(documentView.document);
					return;
				}
		}, tabsStyle);
	}

	function pruneStaleEditorPanes(tabs:Array<UiDocumentView>):Void {
		for (id in editorPanes.keys()) {
			var stillOpen = false;
			for (documentView in tabs) if (documentView.document.id == id) { stillOpen = true; break; }
			if (!stillOpen) editorPanes.remove(id);
		}
	}

	function welcomePanel():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.direction = LayoutDirection.TopToBottom;
		style.childAlignY = LayoutAlignmentY.Center;
		style.padding = new Insets(24.0, 24.0, 24.0, 24.0);
		style.childGap = 10.0;
		var actions = host.welcomeActions;
		var newButton = new Button("New File", null, function() application.newDocument(), "welcome-new");
		newButton.variant = ButtonVariant.Primary;
		var openButton = new Button("Open File...", null, openFileDialog, "welcome-open");
		var items:Array<KeyedView> = [
			new KeyedView("title", new Text("exosuit", null, theme.tokens.text,
				TextStyleOverride.text(20.0))),
			new KeyedView("subtitle", new Text("No documents are open.", null,
				theme.tokens.textSecondary, TextStyleOverride.text(13.0))),
			new KeyedView("new", newButton),
			new KeyedView("open", openButton)
		];
		if (actions != null && actions.recentProjects.length > 0) {
			var recentStyle = new LayoutStyle();
			recentStyle.direction = LayoutDirection.TopToBottom;
			recentStyle.childGap = 4.0;
			var recentRows:Array<KeyedView> = [];
			for (index in 0...actions.recentProjects.length) {
				var path = actions.recentProjects[index];
				recentRows.push(new KeyedView("recent" + index,
					new Button(path, null, function() actions.openRecent(path), "welcome-recent-" + index)));
			}
			items.push(new KeyedView("recent", new Column("welcome-recent", recentRows, recentStyle)));
		}
		return new Column("exosuit-welcome", items, style);
	}

	static function fillStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		return style;
	}

	function placeholderPanel(message:String):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.padding = new Insets(16.0, 16.0, 16.0, 16.0);
		return new Text(message, style, theme.tokens.textSecondary, TextStyleOverride.text(13.0));
	}

	function openArgument(path:String):Void {
		if (FileSystem.exists(path) && FileSystem.isDirectory(path)) {
			explorerRoot = application.workspace.fileSystem.normalize(path);
			explorerModel = null;
			openExplorer();
			application.openArgument(path);
			return;
		}
		if (explorerRoot == null) {
			var slash = path.lastIndexOf("/");
			if (slash > 0) {
				explorerRoot = path.substring(0, slash);
				openExplorer();
			}
		}
		application.openArgument(path);
		statusMessage = "Opened " + path;
	}

	function openFileDialog():Void {
		if (desktop == null) { application.workbench.openPathCommandView(false); requestFrame(); return; }
		desktop.openFile(function(accepted, paths) {
			if (accepted && paths.length > 0) application.open(paths[0]);
			requestFrame();
		});
	}

	function openFolderDialog():Void {
		if (desktop == null) { application.workbench.openPathCommandView(true); requestFrame(); return; }
		desktop.selectDirectory(function(accepted, paths) {
			if (accepted && paths.length > 0) {
				explorerRoot = application.workspace.fileSystem.normalize(paths[0]);
				explorerModel = null;
				openExplorer();
				application.openArgument(paths[0]);
			}
			requestFrame();
		});
	}

	function togglePalette():Void {
		paletteVisible = !paletteVisible;
		requestFrame();
	}

	function requestFrame():Void {
		if (hostContext != null) hostContext.requestFrame();
	}
}
