package ui;

import haxeon.ui.FontFamily;
import haxeon.ui.Path;

import haxeon.ui.Color;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.FontCollection;
import sys.FileSystem;
import haxeon.ui.core.Command;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.core.Shortcut;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockDropZone;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.UiHostContext;
import platform.HostFileDialogs;
import haxeon.ui.icons.IconName;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.EnvironmentColorScheme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabsOptions;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.commands.CommandPalette;
import haxeon.ui.widgets.docking.DockPanelContent;
import haxeon.ui.widgets.docking.DockWorkspace;
import haxeon.ui.widgets.layout.AppShell;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import haxeon.ui.widgets.text.Text;
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
 * controllers exercised by the headless model tests, alongside
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
	var workbenchClient:Null<workspace.client.WorkspaceWorkbenchClient>;
	var pairingClient:Null<workspace.client.WorkspacePairingClient>;
	var remoteAccessPanel:Null<RemoteAccessPanel>;
	var pairingRevision:Int = -1;
	var terminalBrowserVisible:Bool = false;
	var terminalBrowserRevision:Int = -1;
	var terminalBrowserPanel:Null<WorkspaceTerminalsPanel>;
	var workbenchPanel:Null<WorkbenchPanel>;

 var codexPoll:Float=0;
 var agentRevision=-1;
	var groupEditor:Null<GroupEditorPanel>;
	var agentAttach:Null<AgentAttachPanel>;
	var workspaceAttachment:Null<workspace.client.WorkspaceAttachment>;
	var workspaceStatus:String = "";
	var workspaceError:Null<String>;
	public var saveConfirmation(default, null):Null<String>;
	var saveConfirmationHandler:Null<String->Void>;
	public var saveAsDestination(default, null):Null<String>;
	var saveAsReplace:Bool = false;
	var saveAsHandler:Null<(Null<String>, Bool)->Void>;
	final hostContext:Null<UiHostContext>;
	final dock:DockWorkspaceModel;
	var dockPanelContents:Array<DockPanelContent>;
	final editorPanes:Map<Int, EditorPane> = new Map();
	var nextTerminalId:Int = 1;
	var pendingTerminalFocus:Bool = false;
	final createWorkspaceTerminal:Null<(String, String, Bool, Void->Void, TerminalPalette, Null<String>, Null<String>)->TerminalPanel>;
	final createTerminal:Null<(String, Void->Void, TerminalPalette)->TerminalPanel>;
	public var searchPanel(default, null):WorkspaceSearchPanel;
	public final filesScroll = new haxeon.ui.widgets.scroll.ScrollController();
	final activityIcons:Map<String, IconName> = [];
	public final sidebar = new haxeon.ui.widgets.sidebar.SidebarModel();
	var explorerRoot:Null<String>;
	var explorerModel:Null<ExplorerTreeModel>;
	var explorerTree:Null<TreeView>;
	final workspaceFileOpenPending:Map<String, Bool> = new Map();
	final workspaceFileRefreshPending:Map<String, Bool> = new Map();
	final tabClicks = new haxeon.ui.core.PointerClickSequence();
	var statusMessage:String = "Ready";
	var paletteVisible:Bool = false;
	var settingsPanel:Null<haxeon.ui.widgets.settings.SettingsPanel>;
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
			?dark:Bool, ?createTerminal:(String, Void->Void, TerminalPalette)->TerminalPanel,
			?createWorkspaceTerminal:(String, String, Bool, Void->Void, TerminalPalette, Null<String>, Null<String>)->TerminalPanel) {
		this.createTerminal = createTerminal;
		this.createWorkspaceTerminal = createWorkspaceTerminal;
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
		registerSidebarDestination("files", IconName.FolderOpen, explorerPanel, new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files", 0, true));
		registerSidebarDestination("search", IconName.Search, function() return searchPanel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search", 10, true));
		dock = makeDock();
		if (openPath == null) dock.close("explorer");
		var capturedHost:UiWorkbenchHost = null;
		application = new Application(function(exosuitTheme, focus, workspace, settings) {
			capturedHost = new UiWorkbenchHost(exosuitTheme, focus, workspace, settings, requestFrame, {
				model: dock,
				focusEditor: function(id) { ui.buildContext.requestFocusAfterLayout(id); requestFrame(); },
				editorPreedit: function(id, event) {
					if (!ui.focusWidget(id)) return;
					ui.text(UiEventKind.TextEdit, event.text == null ? "" : event.text, event.data);
					requestFrame();
				},
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
		if (hostContext != null) hostContext.onCloseRequested = function(close) {
			application.files.requestQuit(close);
			requestFrame();
		};
		application.confirmations.saveChangesPrompt = function(filename, handler) {
			if (desktop != null) {
				try { desktop.confirmSaveChanges(filename, handler); return; }
				catch (_:Dynamic) {} // Unsupported native dialogs use the same button-based modal.
			}
			saveConfirmation = filename;
			saveConfirmationHandler = handler;
			requestFrame();
		};
		application.files.chooseSaveDestination = function(document, handler) {
			var initial = document.hasBackingPath() ? haxe.io.Path.directory(document.requirePath()) :
				application.workspace.projects.length == 0 ? "" : application.workspace.projects[0].root;
			var name = document.hasBackingPath() ? haxe.io.Path.withoutDirectory(document.requirePath()) : document.title;
			if (desktop != null) {
				try {
					desktop.saveFile(function(accepted, paths) {
						handler(accepted && paths.length > 0 ? paths[0] : null, accepted);
						requestFrame();
					}, "Save As", initial, name);
					return;
				} catch (_:Dynamic) {} // Unsupported native choosers use the themed dialog.
			}
			saveAsDestination = initial.length == 0 ? name : haxe.io.Path.join([initial, name]);
			saveAsReplace = false;
			saveAsHandler = handler;
			requestFrame();
		};
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
		host.restoreAgent=makeAgentTab;
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
		if (openPath != null) openArgument(openPath);
		if (dock.isOpen("terminal") && host.panelTerminals.length == 0) openTerminal();
	}

	function makeDock():DockWorkspaceModel {
		var model = new DockWorkspaceModel();
		var terminalUiAvailable = capabilities.supports(Processes) || createWorkspaceTerminal != null;
		model.register(new DockPanelDescriptor("explorer", "Sidebar", true, true, IconName.FolderOpen, haxeon.ui.docking.DockPanelHeaderMode.Content, new haxeon.ui.docking.DockPanelGrouping("sidebar")));
		model.register(new DockPanelDescriptor("editor", "Editor", false, true, IconName.NewFile, haxeon.ui.docking.DockPanelHeaderMode.Content, new haxeon.ui.docking.DockPanelGrouping("editors", false)));
		model.register(new DockPanelDescriptor("problems", "Problems", true, true, IconName.AlertTriangle, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("build", "Build Output", true, true, IconName.Terminal, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		if (terminalUiAvailable)
			model.register(new DockPanelDescriptor("terminal", "Terminal", true, true, IconName.Terminal, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		dockPanelContents = [
			new DockPanelContent("explorer", function(_) return new haxeon.ui.widgets.sidebar.SidebarHost("sidebar-modes", sidebar, function(id) { showSidebarMode(id); }, function(id) return activityIcons.get(id))),
			new DockPanelContent("editor", function(_) return editorPanel("editor")),
			new DockPanelContent("problems", function(_) return new ProblemsPanel(host, [for (project in application.workspace.projects) project.root]))
		];
		if (capabilities.supports(Processes))
			dockPanelContents.push(new DockPanelContent("build", function(_) return new BuildOutputPanel(host)));
		if (terminalUiAvailable)
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
		var id = "terminal-" + number;
		if (createWorkspaceTerminal != null && application.workspace.activeProject != null)
			id = workspace.client.WorkspaceIds.create("workspace-terminal");
		return createTerminalTab(id, "Terminal " + number,
			explorerRoot == null ? Sys.getCwd() : explorerRoot, false);
	}

	function restoreTerminalTab(id:String, title:String, cwd:String, remote:Bool,resource:String, workspaceRoot:String):Null<UiTerminalTab>
		return createTerminalTab(id,title,cwd,true,remote,resource,workspaceRoot);

	function createTerminalTab(id:String, title:String, cwd:String, restored:Bool, ?remoteOwner:Bool, ?resource:String, ?workspaceRoot:String, ?group:String, ?directory:String):Null<UiTerminalTab> {
		var create = createTerminal;
		var remote = createWorkspaceTerminal;
		var isRemote = remoteOwner == null ? StringTools.startsWith(id, "workspace-terminal-") : remoteOwner;
		if ((remote == null || !isRemote) && create == null) return null;
		var number = StringTools.startsWith(id, "terminal-") ? Std.parseInt(id.substring(9)) : null;
		if (number != null && number >= nextTerminalId) nextTerminalId = number + 1;
		var localDirectory = FileSystem.exists(cwd) && FileSystem.isDirectory(cwd) ? cwd : Sys.getCwd();
		try {
			var panel:TerminalPanel;
			if (remote != null && isRemote)
				panel = remote(resource == null ? id : resource, workspaceRoot == null ? cwd : workspaceRoot,
					restored, requestFrame, terminalPalette, group, directory);
			else if (create != null)
				panel = create(localDirectory, requestFrame, terminalPalette);
			else
				return null;
			return new UiTerminalTab(id, title, cwd, panel,isRemote,resource,workspaceRoot);
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
			requestFrame();
		} else openTerminal();
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
		settingsPanel = new haxeon.ui.widgets.settings.SettingsPanel("exosuit-settings", application.settings.store, requestFrame);
		requestFrame();
	}

	public function setApplicationZoom(percent:Int):Void {
		application.settings.store.set("appearance/workbench/zoom_percent",
			haxeon.ui.properties.PropertyValue.Int(Std.int(Math.max(70, Math.min(200, percent)))));
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
			ui.commands.register(new Command("terminal:browse", "Workspace Terminals…", openWorkspaceTerminals));
			ui.commands.register(new Command("terminal:terminate", "Terminate Active Terminal", function() {
				var active = host.activeTab();
				var terminal = active == null ? null : UiEditorTabs.terminal(active);
				if (terminal == null) terminal = host.activePanelTerminal();
				if (terminal != null) { terminal.panel.terminate(true); requestFrame(); }
			}));
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

	function resolveSaveConfirmation(answer:String):Void {
		var handler = saveConfirmationHandler;
		saveConfirmationHandler = null;
		saveConfirmation = null;
		if (handler != null) handler(answer);
		requestFrame();
	}

	function resolveSaveAs(cancel:Bool = false):Void {
		var handler = saveAsHandler;
		var destination = saveAsDestination;
		if (handler == null) return;
		if (!cancel && (destination == null || StringTools.trim(destination).length == 0)) return;
		if (!cancel && !saveAsReplace && application.workspace.fileSystem.exists(destination)) {
			saveAsReplace = true;
			requestFrame();
			return;
		}
		var overwrite = saveAsReplace;
		saveAsHandler = null;
		saveAsDestination = null;
		saveAsReplace = false;
		handler(cancel ? null : destination, overwrite);
		requestFrame();
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
        if(terminalBrowserVisible) {
            var dismiss=function() {terminalBrowserVisible=false;requestFrame();};
            var browserStyle=new LayoutStyle();browserStyle.width=LayoutAxis.grow();
            browserStyle.height=LayoutAxis.fixed(Math.max(180.0,Math.min(480.0,viewportHeight-160.0)));
            var browser:View=terminalBrowserPanel==null ? new Text("Workspace terminals are not connected") : terminalBrowserPanel;
            var content=new Column("workspace-terminals-content",[new KeyedView("browser",browser),
                new KeyedView("close",new Button("Close",null,dismiss,"workspace-terminals-close"))],browserStyle);
            layers.push(new StackChild("workspace-terminals",new haxeon.ui.widgets.overlays.Dialog("workspace-terminals-dialog","Workspace Terminals",content,dismiss,
                Math.max(240.0,Math.min(640.0,viewportWidth-48.0))),0.0,0.0,50,LayoutAxis.grow(),LayoutAxis.grow()));
        }

		if (groupEditor != null) {
			var dismiss = function() { groupEditor = null; requestFrame(); };
			layers.push(new StackChild("workbench-group-dialog", new haxeon.ui.widgets.overlays.Dialog(
				"workbench-group-dialog", "Group", groupEditor, dismiss, Math.max(240.0, Math.min(520.0, viewportWidth - 48.0))),
				0.0, 0.0, 60, LayoutAxis.grow(), LayoutAxis.grow()));
		}

		if (agentAttach != null) {
			if (!agentAttach.isCurrent()) agentAttach = null;
			else {
				var dismiss = function() { agentAttach = null; requestFrame(); };
				layers.push(new StackChild("attach-agent-dialog", new haxeon.ui.widgets.overlays.Dialog(
					"attach-agent-dialog", "Attach Codex thread", agentAttach, dismiss,
					Math.max(240, Math.min(560, viewportWidth - 48))), 0, 0, 60, LayoutAxis.grow(), LayoutAxis.grow()));
			}
		}

		if (settingsPanel != null) {
			if (settingsPanel.catalog.store != application.settings.store) {
				var filter = settingsPanel.filter, advanced = settingsPanel.showAdvanced, category = settingsPanel.selectedCategory;
				settingsPanel = new haxeon.ui.widgets.settings.SettingsPanel("exosuit-settings", application.settings.store, requestFrame);
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
			var dialog = new haxeon.ui.widgets.overlays.Dialog("settings-dialog", "Settings", content, dismiss,
				Math.max(240.0, Math.min(860.0, viewportWidth - 48.0)));
			layers.push(new StackChild("settings", dialog, 0.0, 0.0, 50, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		if (saveConfirmation != null) {
			var content = new Column("save-confirmation-content", [
				new KeyedView("message", new Text('Do you want to save the changes you made to "' + saveConfirmation + '"?')),
				new KeyedView("detail", new Text("Your changes will be lost if you don’t save them.")),
				new KeyedView("actions", new Row("save-confirmation-actions", [
					new KeyedView("discard", new Button("Don’t Save", null, function() resolveSaveConfirmation("discard"), "save-confirmation-discard")),
					new KeyedView("cancel", new Button("Cancel", null, function() resolveSaveConfirmation("cancel"), "save-confirmation-cancel")),
					new KeyedView("save", new Button("Save", null, function() resolveSaveConfirmation("save"), "save-confirmation-save"))
				]))
			]);
			var dialog = new haxeon.ui.widgets.overlays.Dialog("save-confirmation", "Unsaved Changes", content,
				function() resolveSaveConfirmation("cancel"), Math.max(240, Math.min(540, viewportWidth - 48)));
			dialog.dismissOnOutside = false;
			layers.push(new StackChild("save-confirmation", dialog, 0, 0, 60, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		if (saveAsHandler != null) {
			var controls:Array<KeyedView> = [];
			if (saveAsReplace) {
				controls.push(new KeyedView("message", new Text('Replace "' + saveAsDestination + '"?')));
				controls.push(new KeyedView("detail", new Text("The existing file will be overwritten.")));
			} else {
				var field = new haxeon.ui.widgets.text.TextField("save-as-path", saveAsDestination, function(value) {
					saveAsDestination = value;
					requestFrame();
				}, null, "File path");
				field.onSubmit = function(_) resolveSaveAs();
				controls.push(new KeyedView("path", field));
			}
			controls.push(new KeyedView("actions", new Row("save-as-actions", [
				new KeyedView("cancel", new Button("Cancel", null, function() resolveSaveAs(true), "save-as-cancel")),
				new KeyedView("save", new Button(saveAsReplace ? "Replace" : "Save", null, function() resolveSaveAs(), "save-as-save"))
			])));
			var dialog = new haxeon.ui.widgets.overlays.Dialog("save-as-dialog", "Save As", new Column("save-as-content", controls),
				function() resolveSaveAs(true), Math.max(240, Math.min(540, viewportWidth - 48)));
			dialog.dismissOnOutside = false;
			layers.push(new StackChild("save-as", dialog, 0, 0, 70, LayoutAxis.grow(), LayoutAxis.grow()));
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
		if (host.commandView.input.readClipboard == null) {
			host.commandView.input.readClipboard = function(handler) { ui.clipboard.readText(handler); };
			host.commandView.input.writeClipboard = function(value) { ui.clipboard.writeText(value); return true; };
		}
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
			key += ":reveal=" + view.cursorRevealRevision;
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

	public function attachWorkbench(client:workspace.client.WorkspaceWorkbenchClient):Void {
		workbenchClient = client;
		terminalBrowserPanel = new WorkspaceTerminalsPanel(client, openCatalogTerminal, forgetCatalogTerminal, requestFrame);
		workbenchPanel = new WorkbenchPanel(client, openCatalogTerminal, newGroupedTerminal, editWorkspaceGroup,
			function(path) application.openArgument(path), openWorkspaceTerminals, requestFrame, openCodexAgent, showWorkbenchMenu, attachCodexThread);
		if (sidebar.find("workbench") == null)
			registerSidebarDestination("workbench", IconName.Terminal, function() return workbenchPanel == null ? new Text("Workspace disconnected") : workbenchPanel,
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Workbench", 20, true));
	}

	public function detachWorkbench(client:workspace.client.WorkspaceWorkbenchClient):Void {
		if (workbenchClient != client) return;
		workbenchClient = null;
		workbenchPanel = null;
		terminalBrowserPanel = null;
		terminalBrowserVisible = false;
		groupEditor = null;
		agentAttach = null;
		agentRevision = -1;
		requestFrame();
	}

	public function attachRemoteAccess(client:workspace.client.WorkspacePairingClient):Void {
		pairingClient = client;
		remoteAccessPanel = new RemoteAccessPanel(client, requestFrame, function(value) {
			try {
				ui.clipboard.writeText(value);
				return true;
			} catch (_:Dynamic) return false;
		});
		registerSidebarDestination("remote-access", IconName.Radar, function() return remoteAccessPanel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Remote Access", 30, true));
	}

 function makeAgentTab(id:String,resource:String,root:String,title:String):UiAgentTab {
  return new UiAgentTab(id,resource,root,title,new CodexSessionPanel(function() return workbenchClient==null?null:workbenchClient.agentService(),resource,root,requestFrame));
 }
 function openCodexAgent(resource:String):Void {
  var client=workbenchClient, catalog=client==null?null:client.agentService().agents();
  if(catalog==null) return;
  for(record in catalog.records) if(record.id==resource) {
   var id=ResourceViewIdentity.view(catalog.root,resource,"agent");
   host.attachAgent(makeAgentTab(id,resource,catalog.root,record.name));requestFrame();return;
  }
 }

	function newGroupedTerminal(group:String):Void {
		var client = workbenchClient;
		if (client == null || !client.canCreateTerminals()) return;
		var catalog = client == null ? null : client.terminalCatalog();
		if (catalog == null || workbenchPanel == null) return;
		var selected = workbenchPanel.model.groups.get(group);
		if (selected == null) return;
		var root = catalog.workspaceRoot;
		if (root == null) return;
		var cwd = workbenchPanel.model.directory(selected);
		var resource = workspace.client.WorkspaceIds.create("workspace-terminal");
		var terminal = createTerminalTab(ResourceViewIdentity.view(root, resource), "Terminal", cwd == null ? root : cwd, false, true, resource, root, group);
		if (terminal == null) return;
		host.panelTerminals.push(terminal); host.activePanelTerminalIndex = host.panelTerminals.length - 1;
		dock.open("terminal"); dock.activate("terminal"); pendingTerminalFocus = true; requestFrame();
	}

	function attachCodexThread(group:workspace.service.WorkspaceProtocol.WorkspaceGroup):Void {
		if (workbenchClient == null || workbenchPanel == null) return;
		var cwd = workbenchPanel.model.directory(group);
		if (cwd == null) return;
		agentAttach = new AgentAttachPanel(workbenchClient, group, cwd,
			function() { agentAttach = null; requestFrame(); }, openCodexAgent, requestFrame);
		requestFrame();
	}

	function showWorkbenchMenu(items:Array<haxeon.ui.widgets.overlays.MenuItem>, event:UiEvent, valid:Void->Bool):Void {
		var x = event.x, y = event.y;
		var node = ui.root == null ? null : ui.root.find(event.target);
		if (node != null && node.resolved != null) {
			var bounds = node.globalBounds(); x = bounds.x; y = bounds.y + bounds.height;
		}
		var actions:Array<haxeon.ui.widgets.overlays.MenuItem> = [];
		for (item in items) {
			var action = item;
			actions.push(new haxeon.ui.widgets.overlays.MenuItem(item.key, item.label, function() {
				contextMenu = null;
				if (valid() && action.enabled) action.onSelect();
				requestFrame();
			}, item.enabled));
		}
		contextMenu = new CommandMenu(application.commands, application.context, [], x, y, valid,
			function() { contextMenu = null; requestFrame(); }, actions);
		requestFrame();
	}

	function editWorkspaceGroup(group:workspace.service.WorkspaceProtocol.WorkspaceGroup, create:Bool):Void {
		if (workbenchClient == null) return;
		groupEditor = new GroupEditorPanel(workbenchClient, group, create, function() { groupEditor = null; requestFrame(); }, requestFrame);
		requestFrame();
	}

	public function openWorkspaceTerminals():Void {
		terminalBrowserVisible = true;
		if (workbenchClient != null) workbenchClient.refreshTerminals(true);
		requestFrame();
	}

	public function openCatalogTerminal(record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Bool {
		if (workbenchClient == null || !workbenchClient.canReadTerminals() || !record.available) return false;
		for (tab in host.allTerminalTabs()) if (tab.resourceId == record.id && tab.workspaceRoot == record.workspaceRoot && tab.remote && !tab.disposed) {
			tab.title = record.name;
			var pane = host.terminalPaneFor(tab);
			if (pane != null) host.attachTerminal(tab);
			else {
				host.activePanelTerminalIndex = host.panelTerminals.indexOf(tab);
				dock.open("terminal");
				dock.activate("terminal");
				pendingTerminalFocus = true;
			}
			terminalBrowserVisible = false;
			requestFrame();
			return true;
		}
		var terminal = createTerminalTab(ResourceViewIdentity.view(record.workspaceRoot == null ? record.cwd : record.workspaceRoot, record.id), record.name, record.cwd, true, true, record.id, record.workspaceRoot);
		if (terminal == null) return false;
		host.panelTerminals.push(terminal);
		host.activePanelTerminalIndex = host.panelTerminals.length - 1;
		dock.open("terminal");
		dock.activate("terminal");
		pendingTerminalFocus = true;
		terminalBrowserVisible = false;
		requestFrame();
		return true;
	}

	function forgetCatalogTerminal(record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
		if (workbenchClient == null || !workbenchClient.canControlTerminals()
			|| record.state == "running" || record.state == "starting") return;
		workbenchClient.forgetTerminal(record);
		for (tab in host.allTerminalTabs()) if (tab.remote && tab.resourceId == record.id && tab.workspaceRoot == record.workspaceRoot) {
			host.detachTerminal(tab);
			var index = host.panelTerminals.indexOf(tab);
			if (index >= 0) {
				host.panelTerminals.splice(index, 1);
				host.activePanelTerminalIndex = Std.int(Math.min(host.activePanelTerminalIndex, host.panelTerminals.length - 1));
			}
			tab.dispose();
		}
		requestFrame();
	}

	public function attachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		clearExplorerModel();
		if (workspaceAttachment != null)
			workspaceAttachment.dispose();
		workspaceAttachment = attachment;
		requestFrame();
	}

	public function detachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		if (workspaceAttachment != attachment) return;
		clearExplorerModel();
		workspaceAttachment = null;
		workspaceStatus = "";
		workspaceError = null;
		requestFrame();
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
        if(workbenchClient!=null && ((sidebar.visible && sidebar.activeId=="workbench")|| (host.activeTab()!=null&&UiEditorTabs.agent(host.activeTab())!=null))) {
   workbenchClient.agentService().refreshAgents();
   if(agentRevision!=workbenchClient.agentService().agentRevision()) {agentRevision=workbenchClient.agentService().agentRevision();requestFrame();}
   var active=host.activeTab(), agent=active==null?null:UiEditorTabs.agent(active), catalog=workbenchClient.agentService().agents();
   if(agent!=null && catalog!=null && agent.workspaceRoot==catalog.root && Sys.time()>=codexPoll) {codexPoll=Sys.time()+1;workbenchClient.agentService().agentAction(agent.resource,"read","",null);}
  }
        if((terminalBrowserVisible || groupEditor != null || (sidebar.visible && sidebar.activeId == "workbench")) && workbenchClient!=null) workbenchClient.refreshTerminals(false);
        if(workbenchClient!=null && workbenchClient.terminalCatalogRevision()!=terminalBrowserRevision) {
            terminalBrowserRevision=workbenchClient.terminalCatalogRevision();
            var catalog=workbenchClient.terminalCatalog();
            if(catalog!=null) for(record in catalog.terminals) for(tab in host.allTerminalTabs())
                if(tab.remote && tab.resourceId==record.id && tab.workspaceRoot==record.workspaceRoot) { tab.title=record.name; tab.cwd=record.cwd; }
            requestFrame();
        }
		var previousLanguageStatus = application.language.statusLabel();
		var previousProblems = host.getProblems().revision;
		var previousNotification = visibleNotification;
		var previousBuildBytes = application.build.output.byteCount;
		var previousBuild = application.build.active;
		var previousDecorations = host.getPluginDecorations().revision;
		var previousPluginStatus = host.getPluginStatusItems().revision;
		var previousPluginPanels = host.getPluginPanels().revision;
		application.update();
		var attachment = workspaceAttachment;
		if (attachment != null) {
			var project = application.workspace.activeProject;
			attachment.select(project == null ? null : project.root);
			attachment.poll();
			var failure = attachment.failure();
			if (failure != null && failure != workspaceError) application.reportError("workspace", failure);
			workspaceError = failure;
			var label = attachment.statusLabel();
			if (workspaceStatus != label) {
				workspaceStatus = label;
				requestFrame();
			}
		}
		if (pairingClient != null) {
			if (sidebar.visible && sidebar.activeId == "remote-access") pairingClient.refreshPairings(false);
			if (pairingRevision != pairingClient.pairingRevision()) {
				pairingRevision = pairingClient.pairingRevision();
				requestFrame();
			}
		}
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
		for (terminal in host.allTerminalTabs()) {
			if (terminal.disposed) continue;
			try { terminal.panel.poll(); } catch (error:Dynamic) {
				statusMessage = "Terminal: " + Std.string(error);
				if (terminal.remote) { requestFrame(); continue; }
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
		clearExplorerModel();
		if (workspaceAttachment != null) workspaceAttachment.dispose();
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
			workspaceFileTabs: workspaceFileDiagnostics(),
			active: active == null ? -1 : active.id,
			documentsSource: "core.Application (via UiWorkbenchHost)",
			explorerRoot: explorerRoot,
			explorerIdentity: explorerModel == null ? null : explorerModel.rootIdentity(),
			explorerWatching: explorerModel != null && explorerModel.watchesChanges(),
			sidebarMode: sidebar.activeId,
			sidebarState: sidebar.encode(),
			panels: dock.panelIds(),
			status: statusMessage,
			workspaceConnection: workspaceStatus,
			paletteCommandCount: ui.commands.ids().length,
			errors: [for (entry in application.errors.entries) {source: entry.source, message: entry.message}],
			plugins: application.plugins.enabledIds(),
			terminalIds: [for (terminal in host.allTerminalTabs()) terminal.id],
			terminalResourceIds: [for (terminal in host.allTerminalTabs()) terminal.resourceId],
			terminalBrowserVisible: terminalBrowserVisible,
			agentCatalog:workbenchClient==null?null:workbenchClient.agentService().agents(),
   agentTabs:host.agentResourceIds(),
   terminalCatalog: workbenchClient == null ? null : workbenchClient.terminalCatalog(),
			terminal: panel == null ? "closed" : panel.status(),
			terminalColumns: panel == null ? 0 : panel.columns(),
			terminalRows: panel == null ? 0 : panel.rows()
		};
	}

	function workspaceFileDiagnostics():Array<Dynamic> {
		var result:Array<Dynamic> = [];
		for (pane in host.panes) for (item in pane.items) {
			var file = UiEditorTabs.workspaceFile(item);
			if (file != null) result.push({scope: file.scope, root: file.rootName, path: file.path,
				revision: file.revision, preview: file.preview, syntax: file.textModel.syntax.name,
				diskChanged: file.diskChanged});
		}
		return result;
	}

	function topBar():View {
		return new RetainedView("toolbar", function(_) return buildTopBar(),
			function() return statusMessage + ":" + workspaceStatus + ":" + ui.animations.revision);
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
		if (workspaceStatus.length > 0)
			items.push(new KeyedView("workspace-status", new Text(workspaceStatus, null, theme.tokens.textSecondary, TextStyleOverride.text(12.0))));
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
		var attachment = workspaceAttachment;
		var remoteFiles = attachment != null;
		var remoteScope:String = explorerRoot;
		var remoteWorkspace = attachment == null ? "" : attachment.fileWorkspace();
		if (attachment != null && attachment.fileScope() != null) remoteScope = attachment.fileScope();
		var remoteModelCurrent = explorerModel != null && Std.isOfType(explorerModel, WorkspaceFileTreeModel)
			&& (cast(explorerModel, WorkspaceFileTreeModel)).scopeId() == remoteScope
			&& (cast(explorerModel, WorkspaceFileTreeModel)).workspaceId() == remoteWorkspace;
		var localModelCurrent = explorerModel != null && Std.isOfType(explorerModel, DirectoryTreeModel)
			&& explorerModel.rootIdentity() == explorerRoot;
		if (remoteFiles ? !remoteModelCurrent : !localModelCurrent) {
			clearExplorerModel();
			if (remoteFiles) {
				var rootName = remoteScope;
				var slash = rootName.lastIndexOf("/");
				if (slash >= 0 && slash + 1 < rootName.length) rootName = rootName.substring(slash + 1);
				explorerModel = new WorkspaceFileTreeModel(function()
					return workspaceAttachment == null ? null : workspaceAttachment.fileClient(),
					remoteWorkspace, remoteScope, rootName, theme, requestFrame,
					function(root) host.markWorkspaceFilesChanged(remoteScope, root));
			} else explorerModel = new DirectoryTreeModel(explorerRoot, theme);
		}
		explorerModel.refresh();
		if (explorerTree != null) return new ExplorerTreeView(explorerTree, explorerModel, darkPalette, hostContext == null ? null : hostContext.events);
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.grow();
		viewportStyle.height = LayoutAxis.grow();
		viewportStyle.clipHorizontal = true;
		var remoteModel:Null<WorkspaceFileTreeModel> = Std.isOfType(explorerModel, WorkspaceFileTreeModel)
			? cast explorerModel : null;
		var tree = new TreeView("exosuit-explorer-tree", explorerModel, viewportStyle, filesScroll, 640.0,
			null, [explorerModel.rootKeyAt(0)], function(key) { host.setSelectedExplorerPath(key); }, function(key) {
				if (remoteModel != null) {
					if (remoteModel.isMoreKey(key) || remoteModel.isRetryKey(key)) remoteModel.activateSpecial(key);
					else if (!remoteModel.isDirectoryKey(key)) openWorkspaceFile(remoteModel, key, true);
				} else if (!FileSystem.isDirectory(key)) application.open(key);
			}, null, null);
		tree.expandOnSingleClick = true;
		tree.onItemClicked = function(path, count) {
			if (remoteModel != null) {
				if (remoteModel.isMoreKey(path) || remoteModel.isRetryKey(path)) {
					if (count == 1) remoteModel.activateSpecial(path);
					return;
				}
				if (count == 1 && !remoteModel.isDirectoryKey(path)) openWorkspaceFile(remoteModel, path, false);
				else if (count == 2 && !remoteModel.isDirectoryKey(path)) openWorkspaceFile(remoteModel, path, true);
				return;
			}
			if (count != 1 || FileSystem.isDirectory(path)) return;
			try host.openPreview(application.workspace.documents.open(path)) catch (error:Dynamic) application.reportError("files", "Could not open file: " + Std.string(error));
		};
		tree.onItemContextMenu = function(path, event) {
			if (remoteModel != null) return;
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

	function openWorkspaceFile(model:WorkspaceFileTreeModel, key:String, sticky:Bool):Void {
		var path = model.relativePath(key), entry = model.entryForKey(key);
		if (path == null || path.length == 0 || entry == null) return;
		var root = model.rootId();
		var scope = model.scopeId();
		host.activateWorkspaceFile(scope, root, path, sticky);
		var sizeBytes = WorkspaceFileReader.previewSize(entry.size);
		if (sizeBytes == null) {
			application.reportError("files", "File exceeds the 16 MiB preview limit");
			return;
		}
		if (!host.canOpenWorkspaceFile(scope, root, path, sizeBytes)) {
			application.reportError("files", "Workspace file preview memory limit reached; close another file first");
			return;
		}
		var pendingKey = workspaceFileKey(model.workspaceId(), scope, root, path);
		if (workspaceFileOpenPending.exists(pendingKey)) {
			if (sticky) workspaceFileOpenPending.set(pendingKey, true);
			return;
		}
		if (workspaceFileRefreshPending.exists(pendingKey)) return;
		if (workspaceFileReadCount() >= 2) {
			application.reportError("files", "Two workspace file reads are already in progress");
			return;
		}
		workspaceFileOpenPending.set(pendingKey, sticky);
		var attachment = workspaceAttachment;
		var client = attachment == null ? null : attachment.fileClient();
		if (client == null) {
			workspaceFileOpenPending.remove(pendingKey);
			application.reportError("files", "Workspace file service is not connected");
			return;
		}
		WorkspaceFileReader.read(client, model.workspaceId(), root, path, entry.revision,
			function(result:WorkspaceFileReadResult) {
				var makeSticky = workspaceFileOpenPending.get(pendingKey) == true;
				workspaceFileOpenPending.remove(pendingKey);
				if (result.error != null || result.contents == null || result.revision == null) {
					application.reportError("files", result.error == null ? "Could not read workspace file" : result.error);
					return;
				}
				if (!host.canOpenWorkspaceFile(scope, root, path, result.sizeBytes)) {
					application.reportError("files", "Workspace file preview memory limit reached; close another file first");
					return;
				}
				var file = new UiWorkspaceFileTab(model.workspaceId(), root, scope, model.rootDisplayName(), path, result.revision,
					result.contents, result.sizeBytes, !makeSticky, application.syntaxes, editorPalette);
				host.openWorkspaceFile(file, !makeSticky);
			});
	}

	function refreshWorkspaceFile(file:UiWorkspaceFileTab):Void {
		if (file == null || file.refreshing || !host.hasWorkspaceFile(file)) return;
		var key = workspaceFileKey(file.workspace, file.scope, file.root, file.path);
		if (workspaceFileOpenPending.exists(key) || workspaceFileRefreshPending.exists(key)) return;
		if (workspaceFileReadCount() >= 2) {
			file.refreshError = "Two workspace file reads are already in progress";
			requestFrame();
			return;
		}
		var attachment = workspaceAttachment;
		var client = attachment == null ? null : attachment.fileClient();
		if (client == null || attachment.fileWorkspace() != file.workspace
			|| attachment.fileScope() != null && attachment.fileScope() != file.scope) {
			file.refreshError = "Workspace is disconnected; showing the last loaded snapshot";
			requestFrame();
			return;
		}
		file.refreshing = true;
		file.refreshError = null;
		workspaceFileRefreshPending.set(key, true);
		requestFrame();
		var fail = function(message:String):Void {
			workspaceFileRefreshPending.remove(key);
			file.refreshing = false;
			if (host.hasWorkspaceFile(file)) file.refreshError = message;
			requestFrame();
		};
		client.stat(file.workspace, file.root, file.path, function(stat) {
			if (!host.hasWorkspaceFile(file)) { fail(""); return; }
			if (stat == null || stat.workspace != file.workspace || stat.root != file.root || stat.path != file.path
				|| stat.entry == null || stat.entry.kind != "file" || stat.entry.revision == null) {
				fail("Workspace returned invalid file metadata; showing the last loaded snapshot");
				return;
			}
			var sizeBytes = WorkspaceFileReader.previewSize(stat.entry.size);
			if (sizeBytes == null) {
				fail("File is larger than the 16 MiB preview limit; showing the last loaded snapshot");
				return;
			}
			if (!host.canOpenWorkspaceFile(file.scope, file.root, file.path, sizeBytes)) {
				fail("Workspace file preview memory limit reached; showing the last loaded snapshot");
				return;
			}
			WorkspaceFileReader.read(client, file.workspace, file.root, file.path, stat.entry.revision,
				function(result:WorkspaceFileReadResult) {
					if (result.error != null || result.contents == null || result.revision == null) {
						fail((result.error == null ? "Could not refresh file" : result.error) + "; showing the last loaded snapshot");
						return;
					}
					if (!host.canOpenWorkspaceFile(file.scope, file.root, file.path, result.sizeBytes)) {
						fail("Workspace file preview memory limit reached; showing the last loaded snapshot");
						return;
					}
					var updated = new UiWorkspaceFileTab(file.workspace, file.root, file.scope, file.rootName, file.path,
						result.revision, result.contents, result.sizeBytes, file.preview, application.syntaxes, editorPalette);
					workspaceFileRefreshPending.remove(key);
					file.refreshing = false;
					if (host.replaceWorkspaceFileSnapshot(file, updated)) requestFrame();
				});
		}, function(error) fail((error == null ? "Could not refresh file" : error.message) +
			"; showing the last loaded snapshot"));
	}

	function workspaceFileReadCount():Int {
		var count = 0;
		for (_ in workspaceFileOpenPending.keys()) count++;
		for (_ in workspaceFileRefreshPending.keys()) count++;
		return count;
	}

	static function workspaceFileKey(workspace:String, scope:String, root:String, path:String):String
		return workspace.length + ":" + workspace + scope.length + ":" + scope + root.length + ":" + root + path;

	/** Register a destination once; the Activity Bar follows the sidebar's order and visibility. */
	public function registerSidebarDestination(id:String, icon:IconName, provider:Void->View,
			options:haxeon.ui.widgets.sidebar.SidebarModeOptions):Void {
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
		pruneStaleEditorPanes(host.allViews());
		if (editorPane.items.length == 0) return welcomePanel();
		var items:Array<TabItem> = [];
		var filenames:Map<String, String> = new Map();
		for (item in editorPane.items) {
   var agent=UiEditorTabs.agent(item);
   if(agent!=null) {
    var key=UiEditorTabs.key(item), tab=new TabItem(key,agent.title,agent.panel,true,IconName.Terminal);
    tab.onClose=function() host.closeTab(item,paneId,true);
    items.push(tab);continue;
   }
			var workspaceFile = UiEditorTabs.workspaceFile(item);
			if (workspaceFile != null) {
				var fileKey = UiEditorTabs.key(item);
				var fileTab = new TabItem(fileKey,
					workspaceFile.title + (workspaceFile.preview ? " (preview)" : ""),
					new WorkspaceFilePreviewView(workspaceFile, theme, editorPalette,
						function() refreshWorkspaceFile(workspaceFile)), true);
				fileTab.onClose = function() host.closeTab(item, paneId, true);
				filenames.set(fileKey, workspaceFile.rootName + "/" + workspaceFile.path);
				items.push(fileTab);
				continue;
			}

			var terminal = UiEditorTabs.terminal(item);
			if (terminal != null) {
				var terminalKey = UiEditorTabs.key(item);
				var terminalTab = new TabItem(terminalKey, terminal.title, new TerminalTabView(terminal,
					function() host.activateEditorTab(terminalKey, paneId),
					function(bounds, id) host.editorResolved(paneId, bounds, id)), true, IconName.Terminal);
				terminalTab.onClose = function() host.closeTab(item, paneId, true);
				items.push(terminalTab);
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
				pane = new EditorPane(document, theme, function() {
					documentView.cursorChanged();
					requestFrame();
				}, documentView.selection, editorPalette,
					host.getPluginDecorations(), documentView.decorationSearchMatches, documentView.searchDecorationRevision, documentView.scrollController);
				editorPanes.set(documentView.id, pane);
			}
			pane.minimapEnabled = application.settings.current.minimapEnabled;
			pane.consumeCursorReveal = documentView.consumeCursorReveal;
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
			var fileTab = new TabItem("doc:" + document.id, (document.dirty ? "* " : "") + document.title + (documentView.preview ? " (preview)" : ""), content);
			fileTab.onClose = function() application.files.requestCloseTab(host.documentsLostByClosingTab(item),
				function() return host.closeTab(item, paneId, true));
			items.push(fileTab);
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
			node.on(haxeon.ui.core.UiEventKind.Click, function(event) {
				if (event.button != 0 || tabClicks.register(paneId + ":" + key, event) != 2) return;
				for (view in tabs) if (key == "doc:" + view.document.id) host.keepDocument(view.document, paneId);
				for (item in editorPane.items) {
					var workspaceFile = UiEditorTabs.workspaceFile(item);
					if (workspaceFile != null && UiEditorTabs.key(item) == key) host.keepWorkspaceFile(workspaceFile);
				}
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
		var items:Array<haxeon.ui.widgets.overlays.MenuItem> = [];
		try {
			var entries = FileSystem.readDirectory(directory);
			entries.sort(function(a, b) {
				var ad = FileSystem.isDirectory(directory + "/" + a), bd = FileSystem.isDirectory(directory + "/" + b);
				return ad != bd ? (ad ? -1 : 1) : Reflect.compare(a.toLowerCase(), b.toLowerCase());
			});
			for (name in entries) {
				var target = directory + "/" + name;
				var folder = FileSystem.isDirectory(target);
				items.push(new haxeon.ui.widgets.overlays.MenuItem(target, name + (folder ? "  ›" : ""), function() {
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
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TextField) {
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
			clearExplorerModel();
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
				clearExplorerModel();
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

	function clearExplorerModel():Void {
		if (explorerModel != null) explorerModel.dispose();
		explorerModel = null;
		explorerTree = null;
	}

	function requestFrame():Void {
		viewRevision++;
		if (hostContext != null) hostContext.requestFrame();
	}
}
