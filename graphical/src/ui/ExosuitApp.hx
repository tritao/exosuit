package ui;

import Color;

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
import nativekit.ui.core.RetainedView;
import nativekit.ui.core.Shortcut;
import nativekit.ui.core.UiContext;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
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
import nativekit.ui.widgets.controls.TabsOptions;
import nativekit.ui.widgets.controls.TabsSelectionMode;
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
	var nextTerminalId:Int = 1;
	var pendingTerminalFocus:Bool = false;
	final createTerminal:Null<(String, Void->Void, TerminalPalette)->TerminalPanel>;
	public var searchPanel(default, null):WorkspaceSearchPanel;
	public final filesScroll = new nativekit.ui.widgets.scroll.ScrollController();
	final activityIcons:Map<String, IconName> = [];
	public final sidebar = new nativekit.ui.widgets.sidebar.SidebarModel();
	var explorerRoot:Null<String>;
	var explorerModel:Null<DirectoryTreeModel>;
	var explorerTree:Null<TreeView>;
	final tabClicks = new nativekit.ui.core.PointerClickSequence();
	var statusMessage:String = "Ready";
	var paletteVisible:Bool = false;
	var settingsPanel:Null<nativekit.ui.widgets.settings.SettingsPanel>;
	var contextMenu:Null<CommandMenu> = null;
	var viewRevision:Int = 0;
	var submittedBuildKey:Null<String>;
	var nextBackgroundPoll:Float = 0.0;
	var visibleNotification:Null<feedback.Notification>;
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
		var preferences = new config.Preferences(config.ConfigurationPaths.userSettings());
		if (fonts != null) {
			var loaded = false;
			var candidates = [preferences.current.fontPath,
				"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
				"/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
				"/System/Library/Fonts/Menlo.ttc", "C:/Windows/Fonts/consola.ttf"];
			for (path in candidates) {
				if (loaded || !FileSystem.exists(path) || FileSystem.isDirectory(path)) continue;
				try { fonts.add(path, FontFamily.Monospace); loaded = true; }
				catch (error:Dynamic) { statusMessage = "Editor font: " + Std.string(error); }
			}
			// DesktopUiHost resolves default script and emoji fallbacks on demand.
			// Explicit lists retain their configured font order and family.
			var fallbacks = preferences.store.isDefault("editor/fonts/font_fallback_paths")
				? config.Settings.bundledFontFallbackPaths() : preferences.current.fontFallbackPaths;
			for (path in fallbacks) {
				if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
					try fonts.add(path, FontFamily.Monospace) catch (error:Dynamic) { statusMessage = "Editor fallback: " + Std.string(error); }
			}
		}
		ui = new UiContext(null, fonts, this.theme);
		ui.buildContext.environment.colorScheme = darkPalette ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		desktop = fileDialogs;
		if (hostContext != null) hostContext.onCloseRequested = function(close) close();
		registerSidebarDestination("files", IconName.FolderOpen, explorerPanel, new nativekit.ui.widgets.sidebar.SidebarModeOptions("Files", 0, true));
		registerSidebarDestination("search", IconName.Search, function() return searchPanel,
			new nativekit.ui.widgets.sidebar.SidebarModeOptions("Search", 10, true));
		dock = makeDock();
		if (openPath == null) dock.close("explorer");
		var capturedHost:UiWorkbenchHost = null;
		application = new Application(function(exosuitTheme, focus, workspace, settings) {
			capturedHost = new UiWorkbenchHost(exosuitTheme, focus, workspace, settings, requestFrame, {
				model: dock,
				focusEditor: function(id) { ui.buildContext.requestFocusAfterLayout(id); requestFrame(); },
				toggleSidebar: toggleExplorerVisible,
				activateExplorer: function() {
					if (explorerRoot == null && application.workspace.projects.length > 0)
						explorerRoot = application.workspace.projects[0].root;
					openExplorer();
				},
				activateProblems: function() dock.activate("problems"),
				activateBuild: function() dock.activate("build")
			});
			return capturedHost;
		}, preferences, null, this.capabilities);
		host = capturedHost;
		if (hostContext != null) hostContext.onPoll = pollBackground;
		sidebar.setVisible(dock.isOpen("explorer"));
		sidebar.onChange = syncSidebar;
		searchPanel = new WorkspaceSearchPanel(application, host, requestFrame);
		host.captureSidebar = function() {
			sidebar.setVisible(dock.isOpen("explorer"));
			return "B\tsidebar\t1\t" + sidebar.encode();
		};
		host.restoreSidebar = function(lines) {
			for (line in lines) if (StringTools.startsWith(line, "B\tsidebar\t1\t")) sidebar.restore(line.substring(12));
		};
		host.activateSearch = function() showSidebarMode("search");
		if (this.createTerminal != null) host.restoreTerminal = restoreTerminalTab;
		host.caretRectProvider = function() {
			var active = host.activeView();
			if (active == null) return null;
			var pane = editorPanes.get(active.id);
			return pane == null ? null : pane.caretRect;
		};
		editorPalette = darkPalette ? application.theme : ExosuitPalette.lightEditor();
		installCommands();
		var previousSidebarWidth = application.settings.current.sidebarWidth;
		sidebar.rememberWidth(previousSidebarWidth);
		application.settings.subscribe(function(value) {
			if (hostContext != null) hostContext.zoom = value.applicationZoom / 100.0;
			terminalPalette.fontSize = value.terminalFontSize;
			if (value.sidebarWidth != previousSidebarWidth) {
				previousSidebarWidth = value.sidebarWidth;
				sidebar.rememberWidth(value.sidebarWidth);
				syncSidebar();
			}
			CommandBridge.refreshShortcuts(ui.commands, application.commands, application.keymap);
			requestFrame();
		});
		application.session.start();
		if (dock.isOpen("terminal") && host.panelTerminals.length == 0) openTerminal();
		if (openPath != null) openArgument(openPath);
	}

	function makeDock():DockWorkspaceModel {
		var model = new DockWorkspaceModel();
		model.register(new DockPanelDescriptor("explorer", "Sidebar", true, true, IconName.FolderOpen, nativekit.ui.docking.DockPanelHeaderMode.Content, new nativekit.ui.docking.DockPanelGrouping("sidebar")));
		model.register(new DockPanelDescriptor("editor", "Editor", false, true, IconName.NewFile, nativekit.ui.docking.DockPanelHeaderMode.Content, new nativekit.ui.docking.DockPanelGrouping("editors", false)));
		model.register(new DockPanelDescriptor("problems", "Problems", true, true, IconName.AlertTriangle, nativekit.ui.docking.DockPanelHeaderMode.Dock, new nativekit.ui.docking.DockPanelGrouping("tools")));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("build", "Build Output", true, true, IconName.Terminal, nativekit.ui.docking.DockPanelHeaderMode.Dock, new nativekit.ui.docking.DockPanelGrouping("tools")));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("terminal", "Terminal", true, true, IconName.Terminal, nativekit.ui.docking.DockPanelHeaderMode.Dock, new nativekit.ui.docking.DockPanelGrouping("tools")));
		dockPanelContents = [
			new DockPanelContent("explorer", function(_) return new nativekit.ui.widgets.sidebar.SidebarHost("sidebar-modes", sidebar, function(id) { showSidebarMode(id); }, function(id) return activityIcons.get(id))),
			new DockPanelContent("editor", function(_) return editorPanel("editor")),
			new DockPanelContent("problems", function(_) return new ProblemsPanel(host, [for (project in application.workspace.projects) project.root]))
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
		if (dock.isOpen("explorer")) { sidebar.setVisible(false); return !dock.isOpen("explorer"); }
		var selected = sidebar.selected();
		return showSidebarMode(selected == null ? "files" : selected.id);
	}

	function openExplorer():Bool return showSidebarMode("files");

	public function showSidebarMode(id:String):Bool {
		if (!sidebar.select(id)) return false;
		if (!dock.isOpen("explorer")) return false;
		if (id == "search") searchPanel.focusQuery = true;
		dock.activate("explorer"); requestFrame(); return true;
	}

	function syncSidebar():Void {
		viewRevision++;
		if (!sidebar.visible) {
			if (dock.isOpen("explorer")) dock.close("explorer");
		} else {
			if (!dock.isOpen("explorer")) dock.dock("explorer", host.activePane.id, DockDropZone.Left);
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, Math.max(0, viewportWidth - ActivityBar.WIDTH),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		requestFrame();
	}

	public function openTerminal():Void {
		if (!capabilities.supports(Processes)) return;
		if (host.panelTerminals.length == 0) {
			var terminal = newTerminalTab();
			if (terminal == null) return;
			host.panelTerminals.push(terminal);
			host.activePanelTerminalIndex = 0;
		}
		if (!dock.isOpen("terminal")) {
			if (dock.isOpen("build")) dock.open("terminal", "build");
			else if (dock.isOpen("problems")) dock.open("terminal", "problems");
			else dock.dock("terminal", host.activePane.id, DockDropZone.Bottom);
		}
		dock.activate("terminal");
		pendingTerminalFocus = true;
		requestFrame();
	}

	function newTerminalTab():Null<UiTerminalTab> {
		var number = nextTerminalId++;
		return restoreTerminalTab("terminal-" + number, "Terminal " + number,
			explorerRoot == null ? Sys.getCwd() : explorerRoot);
	}

	function restoreTerminalTab(id:String, title:String, cwd:String):Null<UiTerminalTab> {
		var create = createTerminal;
		if (create == null) return null;
		var number = StringTools.startsWith(id, "terminal-") ? Std.parseInt(id.substring(9)) : null;
		if (number != null && number >= nextTerminalId) nextTerminalId = number + 1;
		var directory = FileSystem.exists(cwd) && FileSystem.isDirectory(cwd) ? cwd : Sys.getCwd();
		try {
			return new UiTerminalTab(id, title, cwd, create(directory, requestFrame, terminalPalette));
		} catch (error:Dynamic) {
			statusMessage = "Terminal: " + Std.string(error);
			return null;
		}
	}

	public function moveTerminalToEditor():Bool {
		openTerminal();
		var terminal = host.activePanelTerminal();
		if (terminal == null) return false;
		host.panelTerminals.splice(host.activePanelTerminalIndex, 1);
		host.activePanelTerminalIndex = Std.int(Math.min(host.activePanelTerminalIndex, host.panelTerminals.length - 1));
		if (host.panelTerminals.length == 0) dock.close("terminal");
		host.attachTerminal(terminal);
		pendingTerminalFocus = false;
		requestFrame();
		return true;
	}

	public function moveTerminalToPanel():Bool {
		var item = host.activeTab();
		var terminal = item == null ? null : UiEditorTabs.terminal(item);
		if (terminal == null || !host.detachTerminal(terminal)) return false;
		host.panelTerminals.push(terminal);
		host.activePanelTerminalIndex = host.panelTerminals.length - 1;
		openTerminal();
		return true;
	}

	function toggleTerminal():Void {
		if (dock.isOpen("terminal")) {
			dock.close("terminal");
			closePanelTerminals();
			requestFrame();
		} else openTerminal();
	}

	function closePanelTerminals():Void {
		for (terminal in host.panelTerminals) terminal.dispose();
		host.panelTerminals.resize(0);
		host.activePanelTerminalIndex = -1;
	}

	function terminalPanel():View {
		if (host.panelTerminals.length == 0) return placeholderPanel("Terminal is closed.");
		var items:Array<TabItem> = [];
		for (terminal in host.panelTerminals) {
			var view = new TerminalTabView(terminal, function() {
				host.deactivateDocumentFocus();
			}, function(_, id) {
				if (pendingTerminalFocus && host.activePanelTerminal() == terminal) {
					ui.buildContext.requestFocusAfterLayout(id);
					pendingTerminalFocus = false;
				}
			}, function(event) {
				host.activePanelTerminalIndex = host.panelTerminals.indexOf(terminal);
				showContextMenu([new CommandMenuEntry("terminal:move-to-editor", "Move Terminal to Editor")],
					event, function() return host.activePanelTerminal() == terminal && !terminal.disposed);
			});
			if (host.panelTerminals.length == 1) return view;
			items.push(new TabItem("terminal:" + terminal.id, terminal.title, view));
		}
		var active = host.activePanelTerminal();
		return Tabs.withOptions("terminal-sessions", items, active == null ? "" : "terminal:" + active.id, function(key) {
			for (index in 0...host.panelTerminals.length) if (key == "terminal:" + host.panelTerminals[index].id) {
				host.activePanelTerminalIndex = index;
				pendingTerminalFocus = true;
				requestFrame();
			}
		}, terminalTabsOptions());
	}

	function terminalTabsOptions():TabsOptions {
		var options = new TabsOptions();
		options.selectionMode = TabsSelectionMode.Controlled;
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		options.style = style;
		return options;
	}

	public function openSettings():Void {
		paletteVisible = false;
		host.closeCommandView();
		settingsPanel = new nativekit.ui.widgets.settings.SettingsPanel("exosuit-settings", application.settings.store, requestFrame);
		requestFrame();
	}

	public function setApplicationZoom(percent:Int):Void {
		application.settings.store.set("appearance/workbench/zoom_percent",
			nativekit.ui.properties.PropertyValue.Int(Std.int(Math.max(70, Math.min(200, percent)))));
	}

	function installCommands():Void {
		var modifier = Sys.systemName() == "Mac" ? UiModifier.Super : UiModifier.Control;
		var zoomIn = new Command("view.zoom-in", "Zoom In", function() setApplicationZoom(application.settings.current.applicationZoom + 10), new Shortcut(61, modifier));
		zoomIn.addShortcut(new Shortcut(61, modifier | UiModifier.Shift));
		zoomIn.addShortcut(new Shortcut(43, modifier));
		zoomIn.addShortcut(new Shortcut(334, modifier));
		ui.commands.register(zoomIn);
		ui.commands.register(new Command("view.zoom-out", "Zoom Out", function() setApplicationZoom(application.settings.current.applicationZoom - 10), new Shortcut(45, modifier)).addShortcut(new Shortcut(333, modifier)));
		ui.commands.register(new Command("view.zoom-reset", "Reset Zoom", function() setApplicationZoom(100), new Shortcut(48, modifier)).addShortcut(new Shortcut(320, modifier)));

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
		if (capabilities.supports(Processes)) {
			application.commands.add("terminal:move-to-editor", function(_) moveTerminalToEditor(),
				function(_) return host.activePanelTerminal() != null);
			application.commands.add("terminal:move-to-panel", function(_) moveTerminalToPanel(),
				function(_) { var tab = host.activeTab(); return tab != null && UiEditorTabs.terminal(tab) != null; });
		}
		application.commands.add("workspace:search", function(_) showSidebarMode("search"));
		application.commands.add("sidebar:files", function(_) showSidebarMode("files"));
		application.commands.add("sidebar:search", function(_) showSidebarMode("search"));
		application.commands.add("settings:open", function(_) openSettings());
		ui.commands.register(new Command("preferences.open", "Settings…", openSettings,
			new Shortcut(UiKey.Comma, UiModifier.Control)));
		CommandBridge.install(ui.commands, application.commands, application.keymap, application.context);
	}

	public function view():View {
		pruneStaleEditorPanes(host.allViews());
		for (pane in host.panes) {
			var found = false;
			for (content in dockPanelContents) if (content.panelId == pane.id) { found = true; break; }
			if (!found) {
				var paneId = pane.id;
				dockPanelContents.push(new DockPanelContent(paneId, function(_) return editorPanel(paneId)));
			}
		}
		var workspaceView = new DockWorkspace("exosuit-workspace", dock, dockPanelContents);
		workspaceView.availableWidth = Math.max(0, viewportWidth - ActivityBar.WIDTH);
		workspaceView.availableHeight = Math.max(0.0, viewportHeight - TOOLBAR_HEIGHT - STATUS_HEIGHT);
		var workspace:View = new Row("workspace-with-activity-bar", [
			new KeyedView("activity-bar", new ActivityBar(sidebar, activityIcons, activateSidebarDestination,
				application.settings.current.tabTooltipDelay)),
			new KeyedView("workspace", workspaceView)
		], fillStyle());
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
		if (settingsPanel != null) {
			if (settingsPanel.catalog.store != application.settings.store) {
				var filter = settingsPanel.filter, advanced = settingsPanel.showAdvanced, category = settingsPanel.selectedCategory;
				settingsPanel = new nativekit.ui.widgets.settings.SettingsPanel("exosuit-settings", application.settings.store, requestFrame);
				settingsPanel.setShowAdvanced(advanced);
				settingsPanel.setFilter(filter);
				if (category != null) settingsPanel.select(category);
			}
			var settingsStyle = new LayoutStyle();
			settingsStyle.width = LayoutAxis.grow();
			settingsStyle.height = LayoutAxis.fixed(Math.max(180.0, Math.min(560.0, viewportHeight - 160.0)));
			var dismiss = function() { settingsPanel = null; requestFrame(); };
			var content = new Column("settings-content", [new KeyedView("panel", settingsPanel),
				new KeyedView("close", new Button("Close", null, dismiss, "settings-close"))], settingsStyle);
			var dialog = new nativekit.ui.widgets.overlays.Dialog("settings-dialog", "Settings", content, dismiss,
				Math.max(240.0, Math.min(860.0, viewportWidth - 48.0)));
			layers.push(new StackChild("settings", dialog, 0.0, 0.0, 50, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		var overlay = host.overlayView();
		if (overlay != null) layers.push(new StackChild("host-overlay", overlay, 0.0, 0.0, 30));
		var menu = contextMenu;
		if (menu != null) {
			if (!menu.isCurrent()) contextMenu = null;
			else layers.push(new StackChild("context-menu", menu, 0.0, 0.0, 40));
		}
		return new Stack("exosuit-overlay-host", layers);
	}

	public function submit(frame:LayoutFrame):RenderNode {
		if (hostContext != null && hostContext.repaintOnly && submittedBuildKey != null)
			return ui.submitCached(view, frame, submittedBuildKey);
		var widthChanged = viewportWidth != frame.width;
		viewportWidth = frame.width;
		viewportHeight = frame.height;
		if (widthChanged && dock.isOpen("explorer")) {
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, Math.max(0, viewportWidth - ActivityBar.WIDTH),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		pumpApplication();
		dock.setPanelBadge("problems", host.getProblems().values().length);
		if (explorerModel != null) explorerModel.refresh();
		var key = viewRevision + ":" + dock.revision + ":" +
			(explorerModel == null ? -1 : explorerModel.revision()) + ":" +
			application.settings.current.minimapEnabled + ":problems=" + host.getProblems().revision + ":prefs=" + application.settings.store.revision;
		var activeView = host.activeView();
		key += ":active=" + (activeView == null ? -1 : activeView.id);
		for (view in host.allViews()) {
			var selection = view.selection;
			key += ":" + view.id + ":" + view.document.buffer.stateId + ":" +
				selection.anchor.line + ":" + selection.anchor.column + ":" +
				selection.cursor.line + ":" + selection.cursor.column + ":" +
				view.scrollController.offsetX + ":" + view.scrollController.offsetY + ":" +
				view.searchDecorationRevision() + ":" + view.preview + ":" + view.document.dirty + ":" +
				view.document.title + ":" + view.document.path;
			if (selection.rangeCount() > 1) for (range in selection.allRanges())
				key += ":range=" + range.anchor.line + ":" + range.anchor.column + ":" +
					range.cursor.line + ":" + range.cursor.column;
		}
		submittedBuildKey = key;
		return ui.submitCached(view, frame, key);
	}

	/** Drain services without requesting a render merely because they are running. */
	function pollBackground():Void {
		var now = Sys.time();
		if (now < nextBackgroundPoll) return;
		nextBackgroundPoll = now + 0.05;
		pumpApplication();
	}

	function pumpApplication():Void {
		nextBackgroundPoll = Sys.time() + 0.05;
		var previousLanguageStatus = application.language.statusLabel();
		var previousProblems = host.getProblems().revision;
		var previousNotification = visibleNotification;
		var previousBuildBytes = application.build.output.byteCount;
		var previousBuild = application.build.active;
		var previousDecorations = host.getPluginDecorations().revision;
		var previousPluginStatus = host.getPluginStatusItems().revision;
		var previousPluginPanels = host.getPluginPanels().revision;
		application.update();
		if (previousLanguageStatus != application.language.statusLabel() ||
			previousProblems != host.getProblems().revision ||
			previousNotification != host.getNotifications().current() ||
			previousBuildBytes != application.build.output.byteCount || previousBuild != application.build.active ||
			previousDecorations != host.getPluginDecorations().revision ||
			previousPluginStatus != host.getPluginStatusItems().revision ||
			previousPluginPanels != host.getPluginPanels().revision)
			requestFrame();
		visibleNotification = host.getNotifications().current();
		ui.buildContext.environment.scrollbarVisibility = host.scrollbarVisibility;
		if (!dock.isOpen("terminal")) closePanelTerminals();
		for (terminal in host.allTerminalTabs()) {
			if (terminal.disposed) continue;
			try { terminal.panel.poll(); } catch (error:Dynamic) {
				statusMessage = "Terminal: " + Std.string(error);
				terminal.dispose();
				host.detachTerminal(terminal);
				var index = host.panelTerminals.indexOf(terminal);
				if (index >= 0) {
					host.panelTerminals.splice(index, 1);
					if (host.activePanelTerminalIndex > index) host.activePanelTerminalIndex--;
					else if (host.activePanelTerminalIndex == index)
						host.activePanelTerminalIndex = Std.int(Math.min(index, host.panelTerminals.length - 1));
				}
				requestFrame();
			}
		}

	}

	public function context():UiContext return ui;

	public function dispose():Void {
		if (hostContext != null) hostContext.onPoll = null;
		application.shutdown();
		host.dispose();
		if (desktop != null) desktop.shutdown();
		ui.dispose();
	}

	public function diagnosticState():Dynamic {
		var active = host.activeDocument();
		var tab = host.activeTab();
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		if (terminal == null) terminal = host.activePanelTerminal();
		var panel = terminal == null ? null : terminal.panel;
		return {
			documents: [for (view in host.allViews()) view.document.title],
			active: active == null ? -1 : active.id,
			documentsSource: "core.Application (via UiWorkbenchHost)",
			explorerRoot: explorerRoot,
			explorerWatching: explorerModel != null && explorerModel.watchChanges,
			sidebarMode: sidebar.activeId,
			sidebarState: sidebar.encode(),
			panels: dock.panelIds(),
			status: statusMessage,
			paletteCommandCount: ui.commands.ids().length,
			errors: [for (entry in application.errors.entries) {source: entry.source, message: entry.message}],
			plugins: application.plugins.enabledIds(),
			terminal: panel == null ? "closed" : panel.status(),
			terminalColumns: panel == null ? 0 : panel.columns(),
			terminalRows: panel == null ? 0 : panel.rows()
		};
	}

	function topBar():View {
		return new RetainedView("toolbar", function(_) return buildTopBar(),
			function() return statusMessage + ":" + ui.animations.revision);
	}

	function buildTopBar():View {
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
		var active = host.activeDocument();
		var tab = host.activeTab();
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		var label = active == null ? (terminal == null ? "No document open" : terminal.title) :
			(active.title + (active.dirty ? " *" : "") + " - " + active.encodingLabel());
		var notification = application.root.getNotifications().current();
		var languageStatus = application.language.statusLabel();
		var trailing = notification == null && languageStatus.length > 0 ? languageStatus : notification == null ? '${host.activePane.items.length} open' : notification.message;
		var error = notification != null && notification.kind == NotificationKind.Error;
		return new RetainedView("status-bar", function(_) {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(STATUS_HEIGHT);
			style.direction = LayoutDirection.LeftToRight;
			style.childAlignY = LayoutAlignmentY.Center;
			style.padding = new Insets(10.0, 2.0, 10.0, 2.0);
			style.background = theme.tokens.surfaceRaised;
			return new Row("exosuit-status", [
				new KeyedView("document", new Text(label, null, theme.tokens.textSecondary,
					TextStyleOverride.text(12.0))),
				new KeyedView("space", new Spacer("status-space", LayoutAxis.grow(), LayoutAxis.fixed(1.0))),
				new KeyedView("notification", new Text(trailing, null,
					error ? theme.tokens.text : theme.tokens.textSecondary,
					TextStyleOverride.text(12.0)))
			], style);
		}, function() return label.length + ":" + label + trailing.length + ":" + trailing + ":" + error + ":" + ui.animations.revision);
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
		explorerModel.refresh();
		if (explorerTree != null) return new ExplorerTreeView(explorerTree, explorerModel, darkPalette, hostContext == null ? null : hostContext.events);
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.grow();
		viewportStyle.height = LayoutAxis.grow();
		viewportStyle.clipHorizontal = true;
		var tree = new TreeView("exosuit-explorer-tree", explorerModel, viewportStyle, filesScroll, 640.0,
			null, [explorerRoot], function(key) { host.setSelectedExplorerPath(key); }, function(key) {
				if (!FileSystem.isDirectory(key)) application.open(key);
			}, null, null);
		tree.expandOnSingleClick = true;
		tree.onItemClicked = function(path, count) {
			if (count != 1 || FileSystem.isDirectory(path)) return;
			try host.openPreview(application.workspace.documents.open(path)) catch (error:Dynamic) application.reportError("files", "Could not open file: " + Std.string(error));
		};
		tree.onItemContextMenu = function(path, event) {
			var menuRoot = explorerRoot;
			host.setSelectedExplorerPath(path);
			showContextMenu([
				new CommandMenuEntry("file:new", "New File…"),
				new CommandMenuEntry("folder:new", "New Folder…"),
				new CommandMenuEntry("file:rename", "Rename…"),
				new CommandMenuEntry("file:delete", "Delete…")
			], event, function() return explorerRoot == menuRoot && host.focusedFilePath() == path && FileSystem.exists(path));
		};
		explorerTree = tree;
		return new ExplorerTreeView(tree, explorerModel, darkPalette, hostContext == null ? null : hostContext.events);
	}

	/** Register a destination once; the Activity Bar follows the sidebar's order and visibility. */
	public function registerSidebarDestination(id:String, icon:IconName, provider:Void->View,
			options:nativekit.ui.widgets.sidebar.SidebarModeOptions):Void {
		sidebar.register(id, provider, options);
		activityIcons.set(id, icon);
	}

	public function activateSidebarDestination(id:String):Void {
		if (sidebar.find(id) == null) return;
		if (dock.isOpen("explorer") && sidebar.activeId == id) sidebar.setVisible(false);
		else showSidebarMode(id);
	}

	function editorPanel(paneId:String):View {
		var editorPane = host.paneById(paneId);
		if (editorPane == null) return welcomePanel();
		var tabs = editorPane.tabs;
		if (editorPane.items.length == 0) return welcomePanel();
		pruneStaleEditorPanes(host.allViews());
		var items:Array<TabItem> = [];
		var filenames:Map<String, String> = new Map();
		for (item in editorPane.items) {
			var terminal = UiEditorTabs.terminal(item);
			if (terminal != null) {
				var terminalKey = UiEditorTabs.key(item);
				items.push(new TabItem(terminalKey, terminal.title, new TerminalTabView(terminal,
					function() host.activateEditorTab(terminalKey, paneId),
					function(bounds, id) host.editorResolved(paneId, bounds, id)), true, IconName.Terminal));
				continue;
			}
			var documentView = UiEditorTabs.document(item);
			if (documentView == null) continue;
			var document = documentView.document;
			// Reused across frames (not rebuilt each `view()` call) so its
			// `BufferSelection` (shared with `documentView`, see `UiDocumentView`'s
			// doc comment) persists between edits instead of resetting.
			var pane = editorPanes.get(documentView.id);
			if (pane == null) {
				pane = new EditorPane(document, theme, requestFrame, documentView.selection, editorPalette,
					host.getPluginDecorations(), documentView.decorationSearchMatches, documentView.searchDecorationRevision, documentView.scrollController);
				editorPanes.set(documentView.id, pane);
			}
			pane.minimapEnabled = application.settings.current.minimapEnabled;
			pane.fontSize = application.settings.current.fontSize;
			pane.onResolvedEditor = function(bounds, id) host.editorResolved(paneId, bounds, id);
			pane.onActivated = function() host.activateTab(document, paneId);
			pane.onContextMenu = function(event) {
				host.activateTab(document, paneId);
				showContextMenu([
					new CommandMenuEntry("doc:undo", "Undo"),
					new CommandMenuEntry("doc:redo", "Redo"),
					new CommandMenuEntry("doc:cut", "Cut"),
					new CommandMenuEntry("doc:copy", "Copy"),
					new CommandMenuEntry("doc:paste", "Paste"),
					new CommandMenuEntry("doc:select-all", "Select All"),
					new CommandMenuEntry("find:open", "Find…"),
					new CommandMenuEntry("find:replace", "Replace…")
				], event, function() return host.activeView() == documentView);
			};
			pane.onCaretRectChanged = function() {
				if (host.isLanguagePopupVisible()) {
					if (host.textInputArea() == null) host.dismissLanguagePopup();
					else requestFrame();
				}
			};
			filenames.set("doc:" + document.id, document.title);
			var breadcrumbRoot:Null<String> = null;
			if (document.path != null) for (project in application.workspace.projects) {
				var root = StringTools.replace(project.root, "\\", "/");
				var path = StringTools.replace(document.path, "\\", "/");
				var prefix = StringTools.endsWith(root, "/") ? root : root + "/";
				if (StringTools.startsWith(path, prefix) && (breadcrumbRoot == null || root.length > breadcrumbRoot.length))
					breadcrumbRoot = root;
			}
			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.grow();
			contentStyle.height = LayoutAxis.grow();
			var content = new Column("document-content:" + documentView.id, [
				new KeyedView("breadcrumbs", new EditorBreadcrumbs(document, breadcrumbRoot,
					theme.tokens.textSecondary, Color.fromBytes((editorPalette.editorBackground >>> 24) & 255,
						(editorPalette.editorBackground >>> 16) & 255, (editorPalette.editorBackground >>> 8) & 255,
						editorPalette.editorBackground & 255), darkPalette,
					function(path, event) showBreadcrumbMenu(document, paneId, path, event))),
				new KeyedView("editor", pane)
			], contentStyle);
			items.push(new TabItem("doc:" + document.id, (document.dirty ? "* " : "") + document.title + (documentView.preview ? " (preview)" : ""),
				content));
		}
		var tabsStyle = new LayoutStyle();
		tabsStyle.width = LayoutAxis.grow();
		tabsStyle.height = LayoutAxis.grow();
		tabsStyle.direction = LayoutDirection.TopToBottom;
		tabsStyle.childGap = 0.0;
		var active = editorPane.activeTab();
		var options = new TabsOptions();
		options.style = tabsStyle;
		options.selectionMode = TabsSelectionMode.Controlled;
		var widget = Tabs.withOptions("exosuit-editor-tabs:" + paneId, items, active == null ? "" : UiEditorTabs.key(active),
			function(key) host.activateEditorTab(key, paneId), options);
		widget.onTabHeaderBuilt = function(key, node) {
			node.on(nativekit.ui.core.UiEventKind.Click, function(event) {
				if (event.button != 0 || tabClicks.register(paneId + ":" + key, event) != 2) return;
				for (view in tabs) if (key == "doc:" + view.document.id) host.keepDocument(view.document, paneId);
			});
		};
		widget.onTabContextMenu = function(key, event) {
			for (item in editorPane.items) {
				var terminal = UiEditorTabs.terminal(item);
				if (terminal == null || key != UiEditorTabs.key(item)) continue;
				host.activateEditorTab(key, paneId);
				showContextMenu([
					new CommandMenuEntry("terminal:move-to-panel", "Move Terminal to Panel"),
					new CommandMenuEntry("root:close", "Close Terminal")
				], event, function() return host.activeTab() == item);
				return;
			}
			for (view in tabs) {
				var document = view.document;
				if (key != "doc:" + document.id) continue;
				host.activateTab(document, paneId);
				showContextMenu([
					new CommandMenuEntry("doc:save", "Save"),
					new CommandMenuEntry("doc:save-as", "Save As…"),
					new CommandMenuEntry("root:close", "Close Tab")
				], event, function() return host.activeView() == view);
				return;
			}
		};
		return new EditorTabsView(widget, filenames, darkPalette, application.settings.current.tabTooltipDelay);
	}

	function showBreadcrumbMenu(document:editor.Document, paneId:String, path:String, event:UiEvent):Void {
		var directory = haxe.io.Path.directory(path);
		var items:Array<nativekit.ui.widgets.overlays.MenuItem> = [];
		try {
			var entries = FileSystem.readDirectory(directory);
			entries.sort(function(a, b) {
				var ad = FileSystem.isDirectory(directory + "/" + a), bd = FileSystem.isDirectory(directory + "/" + b);
				return ad != bd ? (ad ? -1 : 1) : Reflect.compare(a.toLowerCase(), b.toLowerCase());
			});
			for (name in entries) {
				var target = directory + "/" + name;
				var folder = FileSystem.isDirectory(target);
				items.push(new nativekit.ui.widgets.overlays.MenuItem(target, name + (folder ? "  ›" : ""), function() {
					contextMenu = null;
					if (folder) showBreadcrumbMenu(document, paneId, target + "/_", event);
					else { host.activateTab(document, paneId); application.open(target); }
					requestFrame();
				}));
			}
		} catch (error:Dynamic) { application.reportError("files", "Could not list folder: " + Std.string(error)); return; }
		var x = event.x, y = event.y;
		if (ui.root != null) {
			var anchor = ui.root.find(event.target);
			if (anchor != null && anchor.resolved != null) { var bounds = anchor.globalBounds(); x = bounds.x; y = bounds.y + bounds.height + 4; }
		}
		paletteVisible = false;
		host.dismissLanguagePopup();
		var breadcrumbMenu:CommandMenu = null;
		breadcrumbMenu = new CommandMenu(application.commands, application.context, [], x, y,
			function() {
				var pane = host.paneById(paneId);
				if (pane == null) return false;
				var view = pane.activeView();
				return view != null && view.document == document;
			},
			function() { if (contextMenu == breadcrumbMenu) contextMenu = null; requestFrame(); }, items);
		contextMenu = breadcrumbMenu;
		requestFrame();
	}

	function showContextMenu(entries:Array<CommandMenuEntry>, event:UiEvent, valid:Void->Bool):Void {
		var x = event.x, y = event.y;
		if (event.kind == UiEventKind.KeyDown && ui.root != null) {
			var node = ui.root.find(event.target);
			if (node != null && node.resolved != null) {
				var bounds = node.globalBounds();
				x = bounds.x;
				y = bounds.y + bounds.height;
				if (node.semantics != null && node.semantics.role == nativekit.ui.semantics.AccessibilityRole.TextField) {
					var caret = host.textInputArea();
					if (caret != null) { x = caret.x; y = caret.y + caret.height; }
				}
			}
		}
		paletteVisible = false;
		host.dismissLanguagePopup();
		contextMenu = new CommandMenu(application.commands, application.context, entries, x, y, valid,
			function() { contextMenu = null; requestFrame(); });
		requestFrame();
	}

	function pruneStaleEditorPanes(tabs:Array<UiDocumentView>):Void {
		for (id in editorPanes.keys()) {
			var stillOpen = false;
			for (documentView in tabs) if (documentView.id == id) { stillOpen = true; break; }
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
			explorerTree = null;
			filesScroll.jumpTo(0, 0);
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
			explorerTree = null;
				filesScroll.jumpTo(0, 0);
				openExplorer();
				application.openArgument(paths[0]);
			}
			requestFrame();
		});
	}

	function togglePalette():Void {
		contextMenu = null;
		paletteVisible = !paletteVisible;
		requestFrame();
	}

	function requestFrame():Void {
		viewRevision++;
		if (hostContext != null) hostContext.requestFrame();
	}
}
