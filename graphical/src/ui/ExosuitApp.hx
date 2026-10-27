package ui;

import haxeon.ui.widgets.overlays.TooltipPlacement;

import haxeon.ui.FontFamily;
import haxeon.ui.Path;

import haxeon.ui.Color;
import haxeon.ui.Rect;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.FontCollection;
import sys.FileSystem;
import sys.io.File;
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
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import nativekit.ffi.NativeKitTypes;
import platform.HostFileDialogs;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityState;
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
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;
import controller.WorkspaceFileSearchController;
import scm.LocalScmSource;
import scm.ScmGroupId;
import scm.ScmSource;

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
 * reaches this shell's command picker through `ui.commands`.
 */
class ExosuitApp implements DesktopUiApplication {
	public final ui:UiContext;
	public final theme:Theme;
	var darkPalette:Bool;
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
 var nextActiveCodexRead:Float=0;
 var codexReadIndex:Int=0;
 var agentRevision=-1;
	var groupEditor:Null<GroupEditorPanel>;
	var agentAttach:Null<AgentAttachPanel>;
	var workspaceAttachment:Null<workspace.client.WorkspaceAttachment>;
	var searchFileClient:Null<workspace.client.WorkspaceFileClient>;
	var remoteFileSearch:WorkspaceFileSearchController;
	var pendingWorkspaceFolderReveal:Null<String>;
	var workspaceStatus:String = "";
	var workspaceError:Null<String>;
	public var saveConfirmation(default, null):Null<String>;
	var saveConfirmationHandler:Null<String->Void>;
	var trashConfirmation:Null<String>;
	var trashConfirmationHandler:Null<Bool->Void>;
	var skipTrashConfirmation:Bool = false;
	public var saveAsDestination(default, null):Null<String>;
	var saveAsReplace:Bool = false;
	var saveAsHandler:Null<(Null<String>, Bool)->Void>;
	final hostContext:Null<UiHostContext>;
	var scmDirectoryWatch:Null<ScmDirectoryWatch>;
	var scmFocusSubscription:Null<NativeKitEventSubscription>;
	final dock:DockWorkspaceModel;
	final layoutControls:WorkbenchLayoutControls;
	final layoutModes:WorkbenchLayoutModes;
	var contextFiles:Null<ContextFilesView>;
	var contextLayoutsReady:Bool = false;
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
	var filesUseWorkspaceRoots:Bool = false;
	var explorerModel:Null<ExplorerTreeModel>;
	var explorerTree:Null<TreeView>;
	var explorerRename:Null<ExplorerRename>;
	var renamedExplorerPath:Null<String>;
	var localScmSource:Null<LocalScmSource>;
	var sourceControlPanelValue:Null<SourceControlPanel>;
	var sourceControlPanelIdentity:Null<String>;
	final scmDecorationOwners:Map<String, Bool> = [];
	final scmDecorationRevisions:Map<String, String> = [];
	final scmDocumentMarkers:Map<Int, scm.ScmOpenDocumentMarkers> = [];
	final scmDocumentMarkerKeys:Map<Int, String> = [];
	var scmBranchStatus:Null<plugin.PluginStatusItem>;
	var scmPresentationSourceIdentity:Null<String>;
	var scmBranchJob:Null<scm.ScmJob<Array<scm.ScmBranch>>>;
	var scmBranchRequestToken:Int = 0;
	var pendingScmSource:Null<ScmSource>;
	var pendingScmRepository:Null<scm.ScmRepository>;
	var pendingScmGroup:Null<scm.ScmGroup>;
	var pendingScmResource:Null<scm.ScmResource>;
	var nextScmOperationId:Int = 1;
	public var gutterMarkerClickHandler:Null<plugin.PluginGutterMarker->Void>;
	final workspaceFileLoader = new WorkspaceFileLoader();
	final workspaceFileRefreshPending:Map<String, Bool> = new Map();
	final tabClicks = new haxeon.ui.core.PointerClickSequence();
	var statusMessage:String = "Ready";
	var explorerReturnPath:Null<String>;
	var zoomOverlayUntil:Float = 0.0;
	var settingsPanel:Null<haxeon.ui.widgets.settings.SettingsPanel>;
	var settingsModels:Array<workspace.service.WorkspaceAgentProtocol.AgentModel> = [];
	var settingsModelsNext:Null<String>;
	var settingsModelsPending:Bool = false;
	var settingsModelsError:Null<String>;
	var settingsModelsToken:Int = 0;
	var contextMenu:Null<CommandMenu> = null;
	var manageMenu:Null<CommandMenu> = null;
	var viewRevision:Int = 0;
	var submittedBuildKey:Null<String>;
	var nextBackgroundPoll:Float = 0.0;
	var nextExplorerPoll:Float = 0.0;
	var nextScmPoll:Float = 0.0;
	final scmAutoFetchPending:Map<String, Bool> = [];
	final scmAutoFetchLast:Map<String, Float> = [];
	var visibleNotification:Null<feedback.Notification>;
	var notificationPanel:Null<NotificationPanel>;
	var notificationsVisible:Bool = false;
	var notificationRevision:Int = -1;
	final terminalErrors:Map<String, String> = [];
	var viewportWidth:Float = 1280.0;
	var viewportHeight:Float = 840.0;
	static inline var PHONE_LAYOUT_MAX_WIDTH:Float = 640.0;
	var phoneLayoutActive:Bool = false;
	var phoneModeApplying:Bool = false;
	var desktopDockRoot:Null<DockNode>;
	var desktopSidebarWidth:Float = 260;
	var desktopDockActivePanel:Null<String>;
	var phoneContentRoot:Null<DockNode>;
	static inline var TOOLBAR_HEIGHT:Float = 40.0;
	static inline var BRAND_WIDTH:Float = 108.0;
	static inline var TOOLBAR_BUTTON_WIDTH:Float = 32.0;
	static inline var TOOLBAR_GAP:Float = 6.0;
	static inline var STATUS_HEIGHT:Float = StatusBarView.HEIGHT;

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
		var fontErrors:Array<String> = [];
		if (fonts != null) {
			var loaded = false;
			var candidates = [preferences.current.fontPath,
				"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
				"/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
				"/System/Library/Fonts/Menlo.ttc", "C:/Windows/Fonts/consola.ttf"];
			for (path in candidates) {
				if (loaded || !FileSystem.exists(path) || FileSystem.isDirectory(path)) continue;
				try { fonts.add(path, FontFamily.Monospace); loaded = true; }
				catch (error:Dynamic) { fontErrors.push("Editor font: " + Std.string(error)); }
			}
			// DesktopUiHost resolves default script and emoji fallbacks on demand.
			// Explicit lists retain their configured font order and family.
			var fallbacks = preferences.store.isDefault("editor/fonts/font_fallback_paths")
				? config.Settings.bundledFontFallbackPaths() : preferences.current.fontFallbackPaths;
			for (path in fallbacks) {
				if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
					try fonts.add(path, FontFamily.Monospace) catch (error:Dynamic) { fontErrors.push("Editor fallback: " + Std.string(error)); }
			}
		}
		ui = new UiContext(null, fonts, this.theme);
		ui.onModifiersChanged = function(modifiers) {
			for (pane in editorPanes) pane.pointerModifiersChanged(modifiers);
		};
		ui.buildContext.environment.colorScheme = darkPalette ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		desktop = fileDialogs;
		registerSidebarDestination("files", IconName.FolderOpen, explorerPanel, new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files", 0, true));
		registerSidebarDestination("search", IconName.Search, function() return searchPanel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search", 10, true));
		if (this.capabilities.supports(HostCapability.SourceControl))
			registerSidebarDestination("scm", IconName.Hierarchy, sourceControlPanel, new haxeon.ui.widgets.sidebar.SidebarModeOptions("Source Control", 15, true));
		dock = makeDock();
		layoutControls = new WorkbenchLayoutControls(dock);
		layoutModes = new WorkbenchLayoutModes(dock, sidebar, layoutControls, requestFrame);
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
				activateProblems: function() { if (!layoutControls.bottomOpen()) layoutControls.toggleBottom(); dock.open("problems"); dock.activate("problems"); },
				activateBuild: function() { if (!layoutControls.bottomOpen()) layoutControls.toggleBottom(); dock.open("build"); dock.activate("build"); }
			});
			return capturedHost;
		}, preferences, null, this.capabilities);
		host = capturedHost;
		if (hostContext != null) {
			scmDirectoryWatch = new ScmDirectoryWatch(application.scm, hostContext.events);
			application.onScmWatchPathsChanged = function(root, paths, excluded) {
				if (scmDirectoryWatch != null) scmDirectoryWatch.update(root, paths, excluded);
			};
			scmFocusSubscription = hostContext.events.listen(function(event) {
				switch event {
					case WindowStateChanged(_, flags) if ((flags & WindowStateFlags.Active) != 0):
						application.scm.windowFocused();
					case _:
				}
			});
		}
		application.files.afterFileOperation = function(path) {
			if (sidebar.visible && sidebar.activeId == "files" && explorerTree != null) {
				explorerReturnPath = path;
				explorerTree.select(path);
				explorerTree.scrollIntoView(path);
				host.focusExplorer();
				requestFrame();
			}
		};
		application.openFileView = function(path, preview, focusEditor) {
			var view = host.openFile(path, preview, focusEditor);
			if (focusEditor) host.focusActiveEditor();
			return view;
		};
		application.opensDirectly = UiImageTab.supports;
		application.onBackgroundOpen = requestFrame;
		host.configureKeybinding = function(command) {
			openSettings();
			settingsPanel.setShowAdvanced(true);
			settingsPanel.select("editor/keyboard");
		};
		if (hostContext != null) hostContext.onCloseRequested = function(close) {
			application.files.requestQuit(close);
			requestFrame();
		};
		application.language.onPresentationChanged = requestFrame;
		application.confirmations.saveChangesPrompt = function(filename, handler) {
			if (desktop != null) {
				try { desktop.confirmSaveChanges(filename, handler); return; }
				catch (_:Dynamic) {} // Unsupported native dialogs use the same button-based modal.
			}
			saveConfirmation = filename;
			saveConfirmationHandler = handler;
			requestFrame();
		};
		application.confirmations.trashPrompt = function(path, handler) {
			if (!application.settings.current.confirmTrash) { handler(true); return; }
			host.closeCommandView();
			if (desktop != null) {
				try {
					desktop.confirmMoveToTrash(path, function(confirmed, skip) {
						if (confirmed && skip) application.settings.store.set("files/explorer/confirm_trash", haxeon.ui.properties.PropertyValue.Bool(false));
						handler(confirmed);
						if (!confirmed) {
							explorerReturnPath = path;
							host.focusExplorer();
							requestFrame();
						}
					});
					return;
				}
				catch (_:Dynamic) {} // Hosts without native dialogs use the in-app confirmation.
			}
			trashConfirmation = path;
			trashConfirmationHandler = handler;
			skipTrashConfirmation = false;
			requestFrame();
		};
		application.files.renameInPlace = beginExplorerRename;
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
		workspaceFileLoader.capacity = function() {
			var refreshing = 0;
			for (_ in workspaceFileRefreshPending.keys()) refreshing++;
			return Std.int(Math.max(0, 2 - refreshing));
		};
		remoteFileSearch = new WorkspaceFileSearchController(function() return workspaceAttachment, requestFrame);
		searchPanel = new WorkspaceSearchPanel(application, host, requestFrame,
			remoteFileSearch, openWorkspaceSearchResult);
		host.captureSidebar = function() {
			if (phoneLayoutActive) sidebar.rememberWidth(desktopSidebarWidth);
			sidebar.setVisible(dock.isOpen("explorer"));
			return "B\tsidebar\t1\t" + sidebar.encode();
		};
		host.captureDockLayout = captureDockLayout;
		host.captureExtraLayout = function() return [layoutControls.capture(), layoutModes.captureContext()];
		host.restoreExtraLayout = function(lines) { layoutControls.restore(lines); layoutModes.restoreContext(lines); };
		host.captureWindowLayout = function() return [layoutModes.captureWindow()];
		host.restoreWindowLayout = layoutModes.restoreWindow;
		host.beforeContextDetach = layoutModes.suspend;
		layoutModes.beforeApply = function() {
			if (!phoneLayoutActive) return;
			var saved = haxeon.ui.docking.DockWorkspaceSnapshotCodec.decode(captureDockLayout());
			if (saved == null) return;
			phoneModeApplying = true; phoneLayoutActive = false;
			sidebar.rememberWidth(desktopSidebarWidth);
			dock.setRoot(saved.root);
		};
		layoutModes.afterApply = function() {
			if (!phoneModeApplying) return;
			desktopDockRoot = haxeon.ui.docking.DockNodeTools.clone(dock.root);
			desktopDockActivePanel = dock.activePanelId;
			phoneContentRoot = haxeon.ui.docking.DockNodeTools.remove(haxeon.ui.docking.DockNodeTools.remove(dock.root, "explorer"), "context-panel");
			phoneLayoutActive = true; phoneModeApplying = false; syncPhoneDockRoot();
		};
		host.afterContextRestore = function() { layoutModes.resume(); layoutModes.refreshContext(); };
		var defaultSidebar = sidebar.encode();
		host.restoreSidebar = function(lines) {
			var saved = defaultSidebar;
			for (line in lines) if (StringTools.startsWith(line, "B\tsidebar\t1\t")) saved = line.substring(12);
			sidebar.restore(saved);
		};
		host.activateSearch = function() showSidebarMode("search");
		host.restoreAgent=makeAgentTab;
  if (this.createTerminal != null || this.createWorkspaceTerminal != null) host.restoreTerminal = restoreTerminalTab;
		host.caretRectProvider = function() {
			var active = host.activeView();
			if (active == null) return null;
			var pane = editorPanes.get(active.id);
			return pane == null ? null : pane.caretRect;
		};
		editorPalette = new style.Theme();
		updateEditorPalette();
		for (error in fontErrors) application.reportError("fonts", error);
		installCommands();
		syncScmSidebar();
		var previousSidebarWidth = application.settings.current.sidebarWidth;
		sidebar.rememberWidth(previousSidebarWidth);
		application.settings.subscribe(function(value) {
			updateEditorPalette();
			layoutModes.setPreference(value.layoutMode);
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
		host.initializeContext(session.ContextLayoutStore.key(application.activeContext.kind, application.activeContext.id));
		host.beforeContextRestore = function() {
			phoneLayoutActive = false; desktopDockRoot = null; desktopDockActivePanel = null; phoneContentRoot = null;
			contextMenu = null;
		};
		application.activeContext.subscribe(function() {
			var key = session.ContextLayoutStore.key(application.activeContext.kind, application.activeContext.id);
			if (contextLayoutsReady) { host.switchContext(key); pendingTerminalFocus = dock.activePanelId == "terminal"; }
			else host.initializeContext(key);
			var roots = filesUseWorkspaceRoots ? application.savedWorkspaces.roots() : application.activeContext.roots;
			explorerRoot = roots.length == 0 ? null : roots[0];
			clearExplorerModel(); clearLocalScmSource();
			for (root in roots) if (controller.SavedWorkspaceController.available(root)) application.scm.discover(root, _ -> requestFrame());
			requestFrame();
		});
		application.savedWorkspaces.onIdentityAssigned = function(previous, next) host.renameContext(session.ContextLayoutStore.key(workspace.ContextKind.Workspace, previous), session.ContextLayoutStore.key(workspace.ContextKind.Workspace, next));
		application.savedWorkspaces.onChanged = function() {
			var roots = filesUseWorkspaceRoots ? application.savedWorkspaces.roots() : application.activeContext.roots;
			explorerRoot = roots.length == 0 ? null : roots[0];
			clearExplorerModel(); filesScroll.jumpTo(0, 0);
			if (roots.length > 0 && !contextLayoutsReady) openExplorer();
			else if (roots.length == 0) { sidebar.setVisible(false); dock.close("explorer"); }
			requestFrame();
		};
		if (desktop != null) {
			application.savedWorkspaces.chooseOpen = function() desktop.openFile(function(accepted, paths) {
				if (accepted && paths.length > 0) application.savedWorkspaces.open(paths[0]);
				requestFrame();
			}, "Open Workspace");
			application.savedWorkspaces.chooseSaveAs = function() desktop.saveFile(function(accepted, paths) {
				if (accepted && paths.length > 0) {
					var file = paths[0];
					if (!StringTools.endsWith(file, ".exosuit-workspace")) file += ".exosuit-workspace";
					application.savedWorkspaces.saveAs(file);
				}
				requestFrame();
			}, "Save Workspace As", null, "Workspace.exosuit-workspace");
			application.savedWorkspaces.chooseFolder = function() desktop.selectDirectory(function(accepted, paths) {
				if (accepted && paths.length > 0) application.savedWorkspaces.addFolder(paths[0]);
				requestFrame();
			}, "Add Folder to Workspace");
		}
		application.session.start();
		contextLayoutsReady = true;
		if (openPath != null) openArgument(openPath);
		if (dock.isOpen("terminal") && host.panelTerminals.length == 0) openTerminal();
		layoutModes.start(application.settings.current.layoutMode);
	}

	function makeDock():DockWorkspaceModel {
		var model = new DockWorkspaceModel();
		var terminalUiAvailable = capabilities.supports(Processes) || createWorkspaceTerminal != null;
		model.register(new DockPanelDescriptor("explorer", "Sidebar", true, true, IconName.FolderOpen, haxeon.ui.docking.DockPanelHeaderMode.Content, new haxeon.ui.docking.DockPanelGrouping("sidebar")));
		if (capabilities.supports(HostCapability.Filesystem))
			model.register(new DockPanelDescriptor("context-panel", "Context", true, true, IconName.FolderOpen, haxeon.ui.docking.DockPanelHeaderMode.Content, new haxeon.ui.docking.DockPanelGrouping("context", false)));
		model.register(new DockPanelDescriptor("editor", "Editor", false, true, IconName.NewFile, haxeon.ui.docking.DockPanelHeaderMode.Content, new haxeon.ui.docking.DockPanelGrouping("editors", false)));
		model.register(new DockPanelDescriptor("problems", "Problems", true, true, IconName.AlertTriangle, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		if (capabilities.supports(Processes))
			model.register(new DockPanelDescriptor("build", "Build Output", true, true, IconName.Terminal, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		if (terminalUiAvailable)
			model.register(new DockPanelDescriptor("terminal", "Terminal", true, true, IconName.Terminal, haxeon.ui.docking.DockPanelHeaderMode.Dock, new haxeon.ui.docking.DockPanelGrouping("tools")));
		dockPanelContents = [
			new DockPanelContent("explorer", function(_) {
				var view = new haxeon.ui.widgets.sidebar.SidebarHost("sidebar-modes", sidebar,
					function(id) { showSidebarMode(id); }, function(id) return activityIcons.get(id), true);
				view.headerActions = function(id) return id == "files" ? explorerHeaderActions() : null;
				view.headerActionsVisible = function(node) {
					var focused = ui.focus.focusedId;
					return haxeon.ui.style.StyleStateUtil.contains(node.states, haxeon.ui.style.StyleState.Hovered)
						|| (focused != null && node.find(focused) != null);
				};
				return view;
			}),
			new DockPanelContent("editor", function(_) return editorPanel("editor")),
			new DockPanelContent("problems", function(_) return new ProblemsPanel(host, application.activeContext.roots, application.activeContext.kind == workspace.ContextKind.Group))
		];
		if (capabilities.supports(HostCapability.Filesystem))
			dockPanelContents.push(new DockPanelContent("context-panel", function(_) return contextPanel()));
		if (capabilities.supports(Processes))
			dockPanelContents.push(new DockPanelContent("build", function(_) return new BuildOutputPanel(host, application.activeContext.kind == workspace.ContextKind.Group ? application.activeContext.roots : null)));
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
		layoutModes.markLeft();
		if (dock.isOpen("explorer")) { sidebar.setVisible(false); return !dock.isOpen("explorer"); }
		var selected = sidebar.selected();
		return showSidebarMode(selected == null ? "files" : selected.id);
	}

	function openExplorer():Bool return showSidebarMode("files");

	public function showSidebarMode(id:String):Bool {
		if (!sidebar.select(id)) return false;
		layoutModes.markLeft();
		if (!dock.isOpen("explorer")) return false;
		if (id == "search") searchPanel.focusQuery = true;
		dock.activate("explorer"); requestFrame(); return true;
	}

	function syncSidebar():Void {
		viewRevision++;
		if (phoneModeApplying) { requestFrame(); return; }
		if (phoneLayoutActive) {
			syncPhoneDockRoot();
		} else if (!sidebar.visible) {
			if (dock.isOpen("explorer")) dock.close("explorer");
		} else {
			if (!dock.isOpen("explorer")) dock.dock("explorer", host.activePane.id, DockDropZone.Left);
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, Math.max(0, viewportWidth - ActivityBar.WIDTH),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		requestFrame();
	}

	/** At phone width, show the sidebar or editor as one full-width workspace. */
	function syncResponsiveDockLayout():Void {
		var phone = viewportWidth > 0 && viewportWidth <= PHONE_LAYOUT_MAX_WIDTH;
		if (phone) {
			if (!phoneLayoutActive) {
				desktopSidebarWidth = sidebar.width;
				desktopDockRoot = haxeon.ui.docking.DockNodeTools.clone(dock.root);
				desktopDockActivePanel = dock.activePanelId;
				phoneContentRoot = haxeon.ui.docking.DockNodeTools.remove(haxeon.ui.docking.DockNodeTools.remove(desktopDockRoot, "explorer"), "context-panel");
				phoneLayoutActive = true;
			} else if (!sidebar.visible) {
				phoneContentRoot = haxeon.ui.docking.DockNodeTools.clone(dock.root);
			}
			syncPhoneDockRoot();
			return;
		}
		if (!phoneLayoutActive) return;

		if (!sidebar.visible) phoneContentRoot = haxeon.ui.docking.DockNodeTools.clone(dock.root);
		phoneLayoutActive = false;
		sidebar.rememberWidth(desktopSidebarWidth);
		var restored = sidebar.visible ?
			(desktopDockRoot == null ? haxeon.ui.docking.DockNodeTools.clone(dock.root) :
				haxeon.ui.docking.DockNodeTools.clone(desktopDockRoot)) :
			(phoneContentRoot == null ? haxeon.ui.docking.DockNodeTools.remove(dock.root, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(phoneContentRoot));
		if (!sidebar.visible) restored = haxeon.ui.docking.DockNodeTools.remove(restored, "explorer");
		if (desktopDockRoot != null && haxeon.ui.docking.DockNodeTools.contains(desktopDockRoot, "context-panel") && !haxeon.ui.docking.DockNodeTools.contains(restored, "context-panel"))
			restored = layoutControls.withRight(restored);
		if (!haxeon.ui.docking.DockNodeTools.same(dock.root, restored)) dock.setRoot(restored);
		if (sidebar.visible && !dock.isOpen("explorer")) {
			var target = dock.isOpen(host.activePane.id) ? host.activePane.id :
				haxeon.ui.docking.DockNodeTools.firstPanel(dock.root);
			if (target == null) dock.open("explorer");
			else dock.dock("explorer", target, DockDropZone.Left);
		} else if (!sidebar.visible && desktopDockActivePanel != null && dock.isOpen(desktopDockActivePanel)) {
			dock.activate(desktopDockActivePanel);
		}
		desktopDockRoot = null;
		desktopDockActivePanel = null;
		phoneContentRoot = null;
	}

	function syncPhoneDockRoot():Void {
		if (!phoneLayoutActive) return;
		var target = sidebar.visible ? DockNode.Panel("explorer") :
			(phoneContentRoot == null ? haxeon.ui.docking.DockNodeTools.remove(dock.root, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(phoneContentRoot));
		if (!haxeon.ui.docking.DockNodeTools.same(dock.root, target)) dock.setRoot(target);
	}

	function captureDockLayout():String {
		if (!phoneLayoutActive || desktopDockRoot == null) return dock.snapshotJson();
		var layout:DockNode;
		var active:Null<String>;
		if (sidebar.visible) {
			layout = haxeon.ui.docking.DockNodeTools.clone(desktopDockRoot);
			if (!haxeon.ui.docking.DockNodeTools.contains(layout, "explorer")) {
				var content = phoneContentRoot == null ?
					haxeon.ui.docking.DockNodeTools.remove(layout, "explorer") :
					haxeon.ui.docking.DockNodeTools.clone(phoneContentRoot);
				var width = Math.max(1.0, 1280.0 - ActivityBar.WIDTH - DockWorkspace.DividerExtent);
				layout = DockNode.Split(DockSplitAxis.Horizontal, Math.min(0.9, sidebar.width / width),
					DockNode.Panel("explorer"), content);
			}
			active = "explorer";
		} else {
			layout = phoneContentRoot == null ?
				haxeon.ui.docking.DockNodeTools.remove(desktopDockRoot, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(phoneContentRoot);
			active = desktopDockActivePanel;
		}
		if (haxeon.ui.docking.DockNodeTools.contains(desktopDockRoot, "context-panel") && !haxeon.ui.docking.DockNodeTools.contains(layout, "context-panel"))
			layout = layoutControls.withRight(layout);
		if (active != null && !haxeon.ui.docking.DockNodeTools.contains(layout, active))
			active = haxeon.ui.docking.DockNodeTools.firstPanel(layout);
		return haxeon.ui.docking.DockWorkspaceSnapshotCodec.encode(
			new haxeon.ui.docking.DockWorkspaceSnapshot(layout, active));
	}

	function terminalUiAvailable():Bool return createTerminal != null || createWorkspaceTerminal != null;

	/** A remote attachment must never fall back to a browser/local shell. */
	public function terminalCreationFailure():Null<String> {
		var client = workbenchClient;
		if (client != null) {
			if (createWorkspaceTerminal == null) return "This host cannot display workspace terminals";
			if (!client.canReadTerminals()) return "Workspace disconnected or terminal read permission was not granted";
			if (!client.canControlTerminals()) return "Terminal creation requires terminal control permission";
			if (!client.canCreateTerminals()) return "Terminal creation is unavailable for this workspace";
			return null;
		}
		if (workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess())
			return "Connect to a workspace with terminal control permission";
		return capabilities.supports(Processes) && terminalUiAvailable() ? null : "Connect to a workspace to create a terminal";
	}

	function canCreateTerminal():Bool return terminalCreationFailure() == null;
	function canShowTerminal():Bool return host.activePanelTerminal() != null || canCreateTerminal();
	function activeTerminal():Null<UiTerminalTab> {
		var active = host.activeTab(), terminal = active == null ? null : UiEditorTabs.terminal(active);
		return terminal == null ? host.activePanelTerminal() : terminal;
	}
	function canTerminateTerminal():Bool {
		var terminal = activeTerminal();
		return terminal != null && (!terminal.remote || (workbenchClient != null && workbenchClient.canControlTerminals()));
	}

	public function newTerminal():Void {
		var terminal = newTerminalTab();
		if (terminal == null) return;
		if (sidebar.activeId == "workbench") showTerminalInEditor(terminal);
		else {
			host.panelTerminals.push(terminal);
			host.activePanelTerminalIndex = host.panelTerminals.length - 1;
			openTerminalPanel();
		}
	}

	public function openTerminal():Void {
        if (sidebar.activeId == "workbench") {
            var terminal = newTerminalTab();
            if (terminal != null) showTerminalInEditor(terminal);
            return;
        }
        openTerminalPanel();
    }

    function openTerminalPanel():Void {
		if (!terminalUiAvailable()) return;
		if (host.panelTerminals.length == 0) {
			var terminal = newTerminalTab();
			if (terminal == null) return;
			host.panelTerminals.push(terminal);
			host.activePanelTerminalIndex = 0;
		}
		if (!layoutControls.bottomOpen()) layoutControls.toggleBottom();
		if (!dock.isOpen("terminal")) {
			if (dock.isOpen("build")) dock.open("terminal", "build");
			else if (dock.isOpen("problems")) dock.open("terminal", "problems");
			else dock.dock("terminal", host.activePane.id, DockDropZone.Bottom);
		}
		dock.activate("terminal");
		pendingTerminalFocus = true;
		requestFrame();
	}

    function showTerminalInEditor(terminal:UiTerminalTab):Void {
        terminal.retainOnClose = true;
        host.attachTerminal(terminal);
        if (workbenchPanel != null && sidebar.activeId == "workbench") workbenchPanel.revealNode("t:" + terminal.resourceId);
        dock.close("terminal");
        pendingTerminalFocus = false;
        terminalBrowserVisible = false;
        requestFrame();
    }

	function newTerminalTab(?group:String, ?agentProvider:String):Null<UiTerminalTab> {
		var failure = terminalCreationFailure();
		if (failure != null) { application.reportError("terminal", failure); return null; }
		var client = workbenchClient;
		if (client != null) {
			var catalog = client.terminalCatalog();
			var root = workspaceAttachment == null ? null : workspaceAttachment.fileScope();
			if (root == null && catalog != null) root = catalog.workspaceRoot;
			if (root == null) { application.reportError("terminal", "Workspace is not connected"); return null; }
			if (group == null && application.activeContext.kind == workspace.ContextKind.Group) group = application.activeContext.id;
			// The service resolves a missing group to Work (or its first group),
			// and resolves the group's inherited directory against the workspace root.
			if (!client.canCreateGroupedTerminals()) group = null;
			var cwd = application.activeContext.kind == workspace.ContextKind.Group ? application.activeContext.cwd : root;
			if (group != null && workbenchPanel != null) {
				var selected = workbenchPanel.model.groups.get(group);
				if (selected != null) {
					var directory = workbenchPanel.model.directory(selected);
					if (directory != null) cwd = directory;
				}
			}
			var resource = workspace.client.WorkspaceIds.create("workspace-terminal");
			return createTerminalTab(ResourceViewIdentity.view(root, resource), agentProvider == null ? "Terminal" : agentProvider,
				cwd, false, true, resource, root, group, null, agentProvider);
		}
		var number = allocateTerminalNumber(), title = "Terminal " + number;
		var id = createWorkspaceTerminal != null && application.workspace.activeProject != null
			? workspace.client.WorkspaceIds.create("workspace-terminal") : "terminal-" + number;
		return createTerminalTab(id, title, application.activeContext.cwd, false);
	}

	function allocateTerminalNumber():Int {
		var used:Map<String, Bool> = [];
		for (terminal in host.allTerminalTabs()) if (!terminal.disposed) used.set(terminal.title, true);
		var catalog = workbenchClient == null ? null : workbenchClient.terminalCatalog();
		if (catalog != null) for (record in catalog.terminals) used.set(record.name, true);
		while (used.exists("Terminal " + nextTerminalId) || host.terminalNumberInUse(nextTerminalId)) nextTerminalId++;
		return nextTerminalId++;
	}

	function restoreTerminalTab(id:String, title:String, cwd:String, remote:Bool,resource:String, workspaceRoot:String):Null<UiTerminalTab>
		{
            var terminal = createTerminalTab(id,title,cwd,true,remote,resource,workspaceRoot);
            if (terminal != null && remote) terminal.retainOnClose = true;
            return terminal;
        }

	function createTerminalTab(id:String, title:String, cwd:String, restored:Bool, ?remoteOwner:Bool, ?resource:String, ?workspaceRoot:String, ?group:String, ?directory:String, ?agentProvider:String):Null<UiTerminalTab> {
		var isRemote = remoteOwner == null ? StringTools.startsWith(id, "workspace-terminal-") : remoteOwner;
		if (restored && !isRemote && ~/^Terminal [1-9][0-9]*$/.match(title)) {
			for (existing in host.allTerminalTabs()) if (!existing.disposed && existing.title == title) {
				title = "Terminal " + allocateTerminalNumber();
				break;
			}
		}
		var create = createTerminal;
		var remote = createWorkspaceTerminal;
		if (isRemote ? remote == null : create == null) return null;
		var number = StringTools.startsWith(id, "terminal-") ? Std.parseInt(id.substring(9)) : null;
		if (number != null && number >= nextTerminalId) nextTerminalId = number + 1;
		var localDirectory = isRemote ? cwd : FileSystem.exists(cwd) && FileSystem.isDirectory(cwd) ? cwd : Sys.getCwd();
		try {
			var panel:TerminalPanel;
			if (remote != null && isRemote)
				panel = remote(resource == null ? id : resource, workspaceRoot == null ? cwd : workspaceRoot,
					restored, requestFrame, terminalPalette, group, directory);
			else if (create != null)
				panel = create(localDirectory, requestFrame, terminalPalette);
			else
				return null;
			if (agentProvider != null) {
				if (!Std.isOfType(panel, AgentTerminalPanel)) { panel.close(); throw "This terminal host cannot launch agent CLIs"; }
				var agentPanel:AgentTerminalPanel = cast panel;
				try agentPanel.configureAgent(agentProvider) catch (failure:Dynamic) { panel.close(); throw failure; }
			}
			return new UiTerminalTab(id, title, cwd, panel,isRemote,resource,workspaceRoot);
		} catch (error:Dynamic) {
			statusMessage = "Terminal: " + Std.string(error);
			application.reportError("terminal", Std.string(error));
			return null;
		}
	}

	public function moveTerminalToEditor():Bool {
        if (sidebar.activeId == "workbench") {
            var existing = host.activePanelTerminal();
            if (existing != null) showTerminalInEditor(existing);
            else if (host.activeTab() == null || UiEditorTabs.terminal(host.activeTab()) == null) openTerminal();
            return host.activeTab() != null && UiEditorTabs.terminal(host.activeTab()) != null;
        }
		openTerminalPanel();
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
		openTerminalPanel();
		return true;
	}

	function toggleTerminal():Void {
		if (dock.isOpen("terminal")) {
			dock.close("terminal");
			requestFrame();
		} else openTerminal();
	}

	function terminalCommandSkipsShell(id:String):Bool
		return TerminalShortcutPolicy.allows(id, application.settings.current.terminalCommandsToSkipShell);

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
			}, terminalCommandSkipsShell);
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
		host.closeCommandView();
		settingsPanel = new ExosuitSettingsPanel(application.settings.store, function() return settingsModels, requestFrame);
		settingsModels = [];
		settingsModelsNext = null;
		settingsModelsPending = false;
		settingsModelsError = null;
		loadSettingsModels(null);
		requestFrame();
	}

	function loadSettingsModels(cursor:Null<String>):Void {
		if (settingsModelsPending) return;
		var client = workbenchClient == null ? null : workbenchClient.agentService();
		if (client == null) {
			settingsModelsError = "Connect a workspace to load Codex models";
			requestFrame();
			return;
		}
		settingsModelsPending = true;
		settingsModelsError = null;
		var token = ++settingsModelsToken;
		client.listModels(cursor, function(page, error) {
			if (token != settingsModelsToken || settingsPanel == null) return;
			settingsModelsPending = false;
			if (error != null || page == null) settingsModelsError = error == null ? "Could not load Codex models" : error;
			else {
				if (cursor == null) settingsModels = [];
				for (model in page.models) {
					var found = false;
					for (existing in settingsModels) if (existing.model == model.model) found = true;
					if (!found) settingsModels.push(model);
				}
				settingsModelsNext = page.next;
			}
			requestFrame();
		});
	}

	public function setApplicationZoom(percent:Int):Void {
		application.settings.store.set("appearance/workbench/zoom_percent",
			haxeon.ui.properties.PropertyValue.Int(Std.int(Math.max(70, Math.min(200, percent)))));
		zoomOverlayUntil = Sys.time() + 2.0;
		requestFrame();
	}

	function updateEditorPalette():Void {
		var source = darkPalette ? application.theme : ExosuitPalette.lightEditor();
		// Retained editors and previews share this palette instance.
		for (field in Reflect.fields(source))
			Reflect.setField(editorPalette, field, Reflect.field(source, field));
	}

	public function setDarkTheme(dark:Bool):Void {
		if (darkPalette == dark) return;
		darkPalette = dark;
		ExosuitPalette.theme(dark, theme);
		ui.setTheme(theme);
		ui.buildContext.environment.colorScheme = dark ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		updateEditorPalette();
		terminalPalette.setDark(dark);
		requestFrame();
	}

	function installCommands():Void {
		application.commands.add("preferences:theme-dark", function(_) setDarkTheme(true), null, "Use Dark Theme");
		application.commands.add("preferences:theme-light", function(_) setDarkTheme(false), null, "Use Light Theme");
		var modifier = Sys.systemName() == "Mac" ? UiModifier.Super : UiModifier.Control;
		var zoomIn = new Command("view.zoom-in", "Zoom In", function() setApplicationZoom(application.settings.current.applicationZoom + 10), new Shortcut(61, modifier));
		zoomIn.addShortcut(new Shortcut(61, modifier | UiModifier.Shift));
		zoomIn.addShortcut(new Shortcut(43, modifier));
		zoomIn.addShortcut(new Shortcut(334, modifier));
		ui.commands.register(zoomIn);
		ui.commands.register(new Command("view.zoom-out", "Zoom Out", function() setApplicationZoom(application.settings.current.applicationZoom - 10), new Shortcut(45, modifier)).addShortcut(new Shortcut(333, modifier)));
		ui.commands.register(new Command("view.zoom-reset", "Reset Zoom", function() setApplicationZoom(100), new Shortcut(48, modifier)).addShortcut(new Shortcut(320, modifier)));
		ui.commands.register(new Command("view.notifications", "Show Notifications", function() showNotifications()));
		// Starts or pauses recording in a `haxeon run --profile` session; does nothing without one.
		ui.commands.register(new Command("profiler.toggle-recording", "Profiler: Toggle Recording", function() haxeon.ProfileRecording.toggle()));
		ui.commands.register(new Command("editor.toggle-tab-focus", "Toggle Tab Moves Focus", function() {
			ui.events.tabMovesFocus = !ui.events.tabMovesFocus;
			host.dismissLanguagePopup();
			host.getNotifications().publish(ui.events.tabMovesFocus ? "Tab moves focus" : "Tab inserts indentation");
			requestFrame();
		}, new Shortcut(77 /* M */, UiModifier.Control), null, function() return ui.events.tabMovesFocus));

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
		for (mode in [LayoutMode.Editor, LayoutMode.Agents]) {
			var selected = mode;
			ui.commands.register(new Command("view.mode-" + mode.id, "Use " + mode.label + " Layout", function() layoutModes.select(selected.id), null, function() return !phoneLayoutActive));
		}
		ui.commands.register(new Command("view.mode-auto", "Use Automatic Layout", layoutModes.automatic, null, function() return !phoneLayoutActive));
		ui.commands.register(new Command("view.layout-bottom", "Toggle Bottom Panel", function() { layoutControls.toggleBottom(); requestFrame(); },
			new Shortcut(UiKey.J, UiModifier.Control | UiModifier.Alt), function() return !phoneLayoutActive));
		if (capabilities.supports(HostCapability.Filesystem)) ui.commands.register(new Command("view.layout-right", "Toggle Right Panel",
			function() { layoutControls.toggleRight(); requestFrame(); }, new Shortcut(UiKey.B, UiModifier.Control | UiModifier.Alt), function() return !phoneLayoutActive));
		ui.commands.register(new Command("view.layout-menu", "Layout", showLayoutMenu,
			new Shortcut(76 /* L */, UiModifier.Control | UiModifier.Alt), function() return !phoneLayoutActive));
		ui.commands.register(new Command("view.toggle-palette", "Toggle Command Palette",
			togglePalette, new Shortcut(80 /* P */, UiModifier.Control | UiModifier.Shift)));
		if (terminalUiAvailable())
			ui.commands.register(new Command("view.terminal", "Toggle Terminal", toggleTerminal,
				new Shortcut(96 /* ` */, UiModifier.Control), canShowTerminal));
		if (terminalUiAvailable()) {
			ui.commands.register(new Command("terminal:new", "New Terminal", newTerminal,
				new Shortcut(96 /* ` */, UiModifier.Control | UiModifier.Shift), canCreateTerminal));
			ui.commands.register(new Command("terminal:browse", "Workspace Terminals…", openWorkspaceTerminals, null, function() return workbenchClient != null && workbenchClient.canReadTerminals()));
			ui.commands.register(new Command("terminal:terminate", "Terminate Active Terminal", function() {
				var terminal = activeTerminal();
				if (terminal != null) {
					try terminal.panel.terminate(true) catch (failure:Dynamic) application.reportError("terminal", Std.string(failure));
					requestFrame();
				}
			}, null, canTerminateTerminal));
			application.commands.add("terminal:move-to-editor", function(_) moveTerminalToEditor(),
				function(_) return host.activePanelTerminal() != null);
			application.commands.add("terminal:move-to-panel", function(_) moveTerminalToPanel(),
				function(_) { var tab = host.activeTab(); return tab != null && UiEditorTabs.terminal(tab) != null; });
		}
		application.commands.add("workspace:search", function(_) showSidebarMode("search"));
		application.commands.add("sidebar:files", function(_) showSidebarMode("files"));
		application.commands.add("sidebar:search", function(_) showSidebarMode("search"));
		application.commands.add("scm:next-hunk", function(_) host.moveActiveDiffHunk(1), function(_) return activeDiffView() != null);
		application.commands.add("scm:previous-hunk", function(_) host.moveActiveDiffHunk(-1), function(_) return activeDiffView() != null);
		application.commands.add("scm:stage-hunk", function(_) applyActiveScmHunk("stage"), function(_) return canApplyActiveScmHunk("stage"));
		application.commands.add("scm:unstage-hunk", function(_) applyActiveScmHunk("unstage"), function(_) return canApplyActiveScmHunk("unstage"));
		application.commands.add("scm:revert-hunk", function(_) applyActiveScmHunk("revert"), function(_) return canApplyActiveScmHunk("revert"));
		application.commands.add("scm:next-change", function(_) host.moveActiveGutterMarker(1), function(_) return host.canMoveActiveGutterMarker());
		application.commands.add("scm:previous-change", function(_) host.moveActiveGutterMarker(-1), function(_) return host.canMoveActiveGutterMarker());
		application.commands.add("scm:open-file-at-line", function(_) openActiveDiffSourceAtLine(), function(_) return activeDiffView() != null);
		application.commands.add("scm:refresh", function(_) refreshSourceControl(), function(_) return sourceControlSource() != null);
		application.commands.add("scm:fetch", function(_) applyPendingScmRemote(scm.ScmOperation.Fetch(null)), function(_) return canUsePendingScmRemotes());
		application.commands.add("scm:pull", function(_) applyPendingScmRemote(scm.ScmOperation.Pull), function(_) return canUsePendingScmRemotes());
		application.commands.add("scm:push", function(_) applyPendingScmRemote(scm.ScmOperation.Push), function(_) return canUsePendingScmRemotes());
		application.commands.add("scm:branches", function(_) openScmBranchPicker(null), function(_) return true, "Switch Git Branch…");
		application.commands.add("scm:checkout", function(_) openScmBranchPicker(null), function(_) return canCheckoutScmRepository(null));
		application.commands.add("scm:checkout-selected", function(_) openScmBranchPicker(pendingScmRepository), function(_) return canCheckoutScmRepository(pendingScmRepository));
		application.commands.add("scm:create-branch", function(_) openScmCreateBranchPrompt(null), function(_) return canCheckoutScmRepository(null));
		application.commands.add("scm:create-branch-selected", function(_) openScmCreateBranchPrompt(pendingScmRepository), function(_) return canCheckoutScmRepository(pendingScmRepository));
		application.commands.add("scm:trust-repository", function(_) {
			var source = pendingScmSource, repository = pendingScmRepository;
			if (source != null && repository != null && !source.isRemote()) trustScmRepository(repository);
		}, function(_) return canTrustPendingScmRepository());
		application.commands.add("scm:open-changes", function(_) {
			if (pendingScmSource != null && pendingScmRepository != null && pendingScmGroup != null && pendingScmResource != null)
				openScmResource(pendingScmSource, pendingScmRepository, pendingScmGroup, pendingScmResource);
		}, function(_) return pendingScmResource != null);
		application.commands.add("scm:open-side-by-side", function(_) {
			if (pendingScmSource != null && pendingScmRepository != null && pendingScmGroup != null && pendingScmResource != null)
				openScmResource(pendingScmSource, pendingScmRepository, pendingScmGroup, pendingScmResource, true);
		}, function(_) return pendingScmResource != null && pendingScmGroup != null && pendingScmGroup.id != ScmGroupId.Merge);
		application.commands.add("scm:open-file", function(_) openPendingScmFile(), function(_) return pendingScmResource != null);
		application.commands.add("scm:stage", function(_) applyPendingScmFile(true), function(_) return canStagePendingScmFile());
		application.commands.add("scm:unstage", function(_) applyPendingScmFile(false), function(_) return canUnstagePendingScmFile());
		application.commands.add("scm:resolve-ours", function(_) applyPendingScmConflict("ours"), function(_) return canResolvePendingScmConflict());
		application.commands.add("scm:resolve-theirs", function(_) applyPendingScmConflict("theirs"), function(_) return canResolvePendingScmConflict());
		application.commands.add("scm:resolve-both", function(_) applyPendingScmConflict("both"), function(_) return canResolvePendingScmConflict());
		application.commands.add("scm:stage-all", function(_) applyPendingScmGroup(true), function(_) return canStagePendingScmGroup());
		application.commands.add("scm:unstage-all", function(_) applyPendingScmGroup(false), function(_) return canUnstagePendingScmGroup());
		application.commands.add("scm:discard", function(_) discardPendingScmFile(), function(_) return canDiscardPendingScmFile());
		application.commands.add("scm:commit", function(_) {
			var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
			if (source != null && repository != null) commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), false, false);
		}, function(_) return canCommitStagedCurrentScmRepository());
		application.commands.add("scm:commit-amend", function(_) {
			var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
			if (source != null && repository != null) commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), true, false);
		}, function(_) return canAmendCurrentScmRepository());
		application.commands.add("scm:commit-all", function(_) {
			var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
			if (source != null && repository != null) commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), false, true);
		}, function(_) return canCommitAllCurrentScmRepository());
		application.keymap.add(UiKey.Enter, UiModifier.Control, ["scm:commit"]);
		application.commands.add("settings:open", function(_) openSettings());
		ui.commands.register(new Command("preferences.open", "Settings…", openSettings,
			new Shortcut(UiKey.Comma, UiModifier.Control)));
		CommandBridge.install(ui.commands, application.commands, application.keymap, application.context);
		application.workbench.commandPaletteSource = new commandview.CommandPaletteSource(paletteEntries,
			function(id) { ui.commands.executeContext(id, ui.commandContext); });
	}

	function resolveTrashConfirmation(confirmed:Bool):Void {
		var handler = trashConfirmationHandler;
		trashConfirmationHandler = null;
		trashConfirmation = null;
		if (confirmed && skipTrashConfirmation)
			application.settings.store.set("files/explorer/confirm_trash", haxeon.ui.properties.PropertyValue.Bool(false));
		if (handler != null) handler(confirmed);
		requestFrame();
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

	function keepSidebarFullHeight():Void {
		if (!dock.isOpen("explorer")) return;
		switch dock.root {
			case Split(Horizontal, _, Panel("explorer"), _): return;
			case Panel("explorer"): return;
			default:
		}
		var content = haxeon.ui.docking.DockNodeTools.remove(dock.root, "explorer");
		var width = Math.max(1.0, viewportWidth - ActivityBar.WIDTH - DockWorkspace.DividerExtent);
		dock.setRoot(DockNode.Split(DockSplitAxis.Horizontal, sidebar.width / width,
			DockNode.Panel("explorer"), content));
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
		workspaceView.headerActions = function(ids, _) return layoutControls.isToolGroup(ids) ? bottomPanelActions() : null;
		workspaceView.headerActionsRevision = Std.string(layoutControls.bottomMaximized);
		workspaceView.expandedGroup = layoutControls.expandedPanels();
		workspaceView.availableWidth = Math.max(0, viewportWidth - ActivityBar.WIDTH);
		workspaceView.availableHeight = Math.max(0.0, viewportHeight - TOOLBAR_HEIGHT - STATUS_HEIGHT);
		var workspace:View = new Row("workspace-with-activity-bar", [
			new KeyedView("activity-bar", new ActivityBar(sidebar, activityIcons, activateSidebarDestination,
				application.settings.current.tabTooltipDelay, showManageMenu, manageMenu != null && contextMenu == manageMenu)),
			new KeyedView("workspace:" + host.layoutContextKey, workspaceView)
		], fillStyle());
		var body = new Column("exosuit-body", [
			new KeyedView("workspace", workspace),
			new KeyedView("status", statusBar())
		], fillStyle());
		var shellStyle = fillStyle();
		shellStyle.background = theme.tokens.surface;
		var layers:Array<StackChild> = [new StackChild("shell", new AppShell("exosuit-shell", body,
			topBar(), null, null, shellStyle), 0.0, 0.0, 0, LayoutAxis.grow(), LayoutAxis.grow())];
		if (notificationsVisible && notificationPanel != null) {
			var width = Math.min(560.0, Math.max(240.0, viewportWidth - 24));
			var height = Math.min(Math.max(64.0, notificationPanel.preferredHeight),
				Math.min(520.0, Math.max(64.0, viewportHeight - TOOLBAR_HEIGHT - STATUS_HEIGHT - 16)));
			var style = new LayoutStyle(); style.width = LayoutAxis.fixed(width); style.height = LayoutAxis.fixed(height);
			var popup = new haxeon.ui.widgets.overlays.Popup("notifications-popup", notificationPanel,
				Math.max(0, viewportWidth - width - 8), Math.max(TOOLBAR_HEIGHT, viewportHeight - STATUS_HEIGHT - height - 4),
				style, hideNotifications);
			popup.dimBackdrop = false; popup.menuSurface = true; popup.label = "Notifications";
			layers.push(new StackChild("notifications", popup, 0, 0, 45, LayoutAxis.grow(), LayoutAxis.grow()));
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
				settingsPanel = new ExosuitSettingsPanel(application.settings.store, function() return settingsModels, requestFrame);
				settingsPanel.setShowAdvanced(advanced);
				settingsPanel.setFilter(filter);
				if (category != null) settingsPanel.select(category);
			}
			var panel:haxeon.ui.widgets.settings.SettingsPanel = cast settingsPanel;
			var settingsStyle = new LayoutStyle();
			settingsStyle.width = LayoutAxis.grow();
			settingsStyle.height = LayoutAxis.fixed(Math.max(180.0, Math.min(560.0, viewportHeight - 160.0)));
			var dismiss = function() { settingsPanel = null; settingsModelsToken++; settingsModelsPending = false; requestFrame(); };
			var footer:Array<KeyedView> = [];
			if (panel.selectedCategory == "workbench/codex") {
				var modelButton = new Button(settingsModelsNext != null ? "More models" : "Refresh models", null,
					function() loadSettingsModels(settingsModelsNext), "settings-codex-models-load");
				modelButton.enabled = !settingsModelsPending;
				footer.push(new KeyedView("models", modelButton));
				if (settingsModelsPending) footer.push(new KeyedView("status", new Text("Loading Codex models…")));
				else if (settingsModelsError != null) footer.push(new KeyedView("status", new Text(settingsModelsError)));
			}
			footer.push(new KeyedView("close", new Button("Close", null, dismiss, "settings-close")));
			var content = new Column("settings-content", [new KeyedView("panel", panel),
				new KeyedView("footer", new Row("settings-footer", footer))], settingsStyle);
			var dialog = new haxeon.ui.widgets.overlays.Dialog("settings-dialog", "Settings", content, dismiss,
				Math.max(240.0, Math.min(860.0, viewportWidth - 48.0)));
			layers.push(new StackChild("settings", dialog, 0.0, 0.0, 50, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		if (trashConfirmation != null) {
			var path = trashConfirmation;
			var displayPath = path;
			for (project in application.workspace.projects) {
				var relative = pathUnderScope(project.root, path);
				if (relative != null && relative.length > 0) { displayPath = relative; break; }
			}
			var contentStyle = new LayoutStyle();
			contentStyle.childGap = 12;
			var actionsStyle = new LayoutStyle();
			actionsStyle.childGap = 8;
			var content = new Column("trash-confirmation-content", [
				new KeyedView("path", new Text(displayPath)),
				new KeyedView("detail", new Text("This item and its contents will be moved to Exosuit’s recoverable trash.")),
				new KeyedView("remember", new haxeon.ui.widgets.controls.Checkbox("trash-confirmation-remember",
					"Do not ask me again", skipTrashConfirmation, function(value) { skipTrashConfirmation = value; requestFrame(); })),
				new KeyedView("actions", new Row("trash-confirmation-actions", [
					new KeyedView("cancel", new Button("Cancel", null, function() resolveTrashConfirmation(false), "trash-confirmation-cancel")),
					new KeyedView("move", new Button("Move to Trash", null, function() resolveTrashConfirmation(true), "trash-confirmation-move"))
				], actionsStyle))
			], contentStyle);
			var dialog = new haxeon.ui.widgets.overlays.Dialog("trash-confirmation",
				'Move "' + haxe.io.Path.withoutDirectory(path) + '" to Trash?', content,
				function() resolveTrashConfirmation(false), Math.max(240, Math.min(540, viewportWidth - 48)));
			dialog.dismissOnOutside = false;
			layers.push(new StackChild("trash-confirmation", dialog, 0, 0, 60, LayoutAxis.grow(), LayoutAxis.grow()));
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
		if (zoomOverlayUntil > Sys.time()) {
			var style = new LayoutStyle();
			style.padding = new Insets(16, 10, 16, 10);
			style.background = theme.tokens.surfaceRaised;
			style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 8;
			var label = new Text("Zoom " + application.settings.current.applicationZoom + "%", null,
				theme.tokens.textPrimary);
			layers.push(new StackChild("zoom-overlay", new Row("zoom-indicator", [new KeyedView("label", label)], style),
				Math.max(8, viewportWidth - 156), TOOLBAR_HEIGHT + 12, 80));
		}
		var menu = contextMenu;
		if (menu != null) {
			if (!menu.isCurrent()) contextMenu = null;
			else layers.push(new StackChild("context-menu", menu, 0.0, 0.0, 40));
		}
		var result:View = new TooltipOverlayHost(new Stack("exosuit-overlay-host", layers));
		return hostContext != null && hostContext.windowControls != null
			? new haxeon.ui.widgets.WindowFrame("exosuit-window", result, hostContext.windowControls) : result;
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
		layoutModes.suspend();
		syncResponsiveDockLayout();
		keepSidebarFullHeight();
		if (widthChanged && !phoneLayoutActive && dock.isOpen("explorer")) {
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, Math.max(0, viewportWidth - ActivityBar.WIDTH),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		layoutModes.resume();
		dock.setPanelBadge("problems", host.getProblems().values().length);
		var key = (hostContext == null || hostContext.windowControls == null ? 0 : hostContext.windowControls.revision) + ":" + viewRevision + ":" + dock.revision + ":" +
			(explorerModel == null ? -1 : explorerModel.revision()) + ":" +
			application.settings.current.minimapEnabled + ":problems=" + host.getProblems().revision + ":prefs=" + application.settings.store.revision +
			":decorations=" + host.getPluginDecorations().revision + ":gutter-markers=" + host.getPluginGutterMarkers().revision +
			":resource-decorations=" + host.getResourceDecorations().revision + ":status-items=" + host.getPluginStatusItems().revision +
			":panels=" + host.getPluginPanels().revision;
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
		var root = ui.submitCached(view, frame, key);
		if (explorerReturnPath != null && explorerRename == null && trashConfirmationHandler == null) {
			var target:Null<RenderNode> = null;
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem &&
					node.semantics.label == explorerReturnPath) target = node;
			});
			if (target != null) {
				explorerReturnPath = null;
				host.focusExplorer();
				ui.focusWidget(target.id);
			}
		}
		return root;
	}

	public function attachWorkbench(client:workspace.client.WorkspaceWorkbenchClient):Void {
		layoutModes.suspend();
		workbenchClient = client;
		terminalBrowserPanel = new WorkspaceTerminalsPanel(client, openCatalogTerminal, forgetCatalogTerminal, requestFrame);
		workbenchPanel = new WorkbenchPanel(client, openCatalogTerminal, newGroupedTerminal, editWorkspaceGroup,
			function(path) application.openArgument(path), openWorkspaceTerminals, requestFrame, openCodexAgent, showWorkbenchMenu,
			attachCodexThread, function(resource, workspaceRoot) host.closeAgentTabs(resource, workspaceRoot),
			createCodexAgent, createProviderAgent, canCreateAgentSession);
		host.onActiveTabChanged = syncWorkbenchAgentSelection;
		syncWorkbenchAgentSelection(host.activeTab());
		if (sidebar.find("workbench") == null)
			registerSidebarDestination("workbench", IconName.Terminal, function() return workbenchPanel == null ? new Text("Workspace disconnected") : workbenchPanel,
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Workbench", 20, true));
		layoutModes.resume(); layoutModes.refreshSidebar(); syncLayoutService();
	}

	public function detachWorkbench(client:workspace.client.WorkspaceWorkbenchClient):Void {
		if (workbenchClient != client) return;
		workbenchClient = null;
		layoutModes.setServiceAvailable(false);
		host.onActiveTabChanged = null;
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
  return new UiAgentTab(id,resource,root,title,new CodexSessionPanel(function() return workbenchClient==null?null:workbenchClient.agentService(),resource,root,requestFrame,editorPalette,application.syntaxes,showWorkbenchMenu,
   function(group:String) {
    createCodexAgent(group, openCodexAgent);
   }));
 }

 function createCodexAgent(group:String, created:String->Void):Void {
  if (application.settings.current.agentSessionMode == "terminal") { createAgentTerminal("codex", group); return; }
  var client = workbenchClient;
  if (client == null) return;
  var settings = application.settings.current;
  var model = StringTools.trim(settings.codexDefaultModel);
  var defaults:workspace.client.CodexSessionDefaults = {
   model: model == "" ? null : model,
   effort: settings.codexDefaultEffort == "model-default" ? null : settings.codexDefaultEffort,
   permissionProfile: settings.codexDefaultPermissions
  };
  client.agentService().createAgent(group, null, created, defaults);
 }

 function canCreateAgentSession():Bool {
  var client = workbenchClient;
  if (client == null) return false;
  if (application.settings.current.agentSessionMode == "terminal")
   return client.canCreateGroupedTerminals() && !client.terminalCatalogBusy();
  return client.agentService().canControlAgents() && !client.agentService().agentBusy();
 }

 function createProviderAgent(provider:String, group:String):Void {
  if (application.settings.current.agentSessionMode == "terminal") { createAgentTerminal(provider, group); return; }
  if (provider == "codex") { createCodexAgent(group, openCodexAgent); return; }
  if (workbenchClient != null) workbenchClient.agentService().createAgent(group, null, openCodexAgent,
   {provider:provider,model:null,effort:null,permissionProfile:provider == "claude" ? "default" : "supervised"});
 }

 function createAgentTerminal(provider:String, group:String):Void {
  var client = workbenchClient, catalog = client == null ? null : client.terminalCatalog();
  if (catalog == null || catalog.agentProviders == null || catalog.agentProviders.indexOf(provider) < 0) {
   application.reportError("agent", "Update the workspace service to launch interactive agent terminals"); return;
  }
  var terminal = newTerminalTab(group, provider);
  if (terminal != null) showTerminalInEditor(terminal);
 }

 function syncWorkbenchAgentSelection(tab:Null<UiEditorTab>):Void {
  var agent = tab == null ? null : UiEditorTabs.agent(tab);
  if (workbenchPanel == null) return;
  workbenchPanel.syncActiveAgent(agent == null ? null : agent.resource,
    agent == null ? null : agent.workspaceRoot);
 }

 function openCodexAgent(resource:String):Void {
  var client=workbenchClient, catalog=client==null?null:client.agentService().agents();
  if(catalog==null) return;
  for(record in catalog.records) if(record.id==resource) {
   var groups = client.terminalCatalog();
   if (groups != null && groups.workspaceRoot == catalog.root)
    application.activeContext.openSessionGroup(record.group, groups.groups, catalog.root);
   var id=ResourceViewIdentity.view(catalog.root,resource,"agent");
   host.attachAgent(makeAgentTab(id,resource,catalog.root,record.name));
   requestFrame();return;
  }
 }

	function newGroupedTerminal(group:String):Void {
		var terminal = newTerminalTab(group);
		if (terminal != null) showTerminalInEditor(terminal);
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
		var anchor = contextMenuAnchor(event);
		var actions:Array<haxeon.ui.widgets.overlays.MenuItem> = [];
		for (item in items) {
			var action = item;
			actions.push(new haxeon.ui.widgets.overlays.MenuItem(item.key, item.label, function() {
				contextMenu = null;
				if (valid() && action.enabled) action.onSelect();
				requestFrame();
			}, item.enabled));
		}
		contextMenu = new CommandMenu(application.commands, application.context, [], anchor.x, anchor.y, valid,
			function() { contextMenu = null; requestFrame(); }, actions, menuOpenedWithKeyboard(event));
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
			tab.updateWorkspaceName(record.name);
			var pane = host.terminalPaneFor(tab);
			if (sidebar.activeId == "workbench") showTerminalInEditor(tab);
            else if (pane != null) host.attachTerminal(tab);
			else {
                host.hiddenTerminals.remove(tab);
                if (host.panelTerminals.indexOf(tab) < 0) host.panelTerminals.push(tab);
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
        if (sidebar.activeId == "workbench") { showTerminalInEditor(terminal); return true; }
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
            host.hiddenTerminals.remove(tab);
			tab.dispose();
		}
		requestFrame();
	}

	public function attachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		clearSourceControlPanel();
		clearScmPresentation();
		clearExplorerModel();
		clearLocalScmSource();
		if (workbenchPanel != null) workbenchPanel.workspaceAttachmentChanged();
		if (workspaceAttachment != null)
			workspaceAttachment.dispose();
		workspaceAttachment = attachment;
		syncScmSidebar();
		workspaceFileLoader.clearCache();
		searchFileClient = null;
		pendingWorkspaceFolderReveal = null;
		searchPanel.workspaceAttachmentChanged();
		requestFrame();
	}

	public function detachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		if (workspaceAttachment != attachment) return;
		clearSourceControlPanel();
		clearScmPresentation();
		clearExplorerModel();
		clearLocalScmSource();
		if (workbenchPanel != null) workbenchPanel.workspaceAttachmentChanged();
		workspaceAttachment = null;
		syncScmSidebar();
		workspaceFileLoader.clearCache();
		searchFileClient = null;
		pendingWorkspaceFolderReveal = null;
		searchPanel.workspaceAttachmentChanged();
		workspaceStatus = "";
		workspaceError = null;
		requestFrame();
	}

	function syncLayoutService():Void {
		var client = workbenchClient;
		var catalog = client == null ? null : client.terminalCatalog();
		layoutModes.setServiceAvailable(client != null && client.canReadTerminals() && catalog != null && catalog.groups.length > 0);
	}

	/** Drain services without requesting a render merely because they are running. */
	function pollBackground():Void {
		// Terminal IO follows the host event pump. Filesystem/catalog maintenance
		// keeps its slower cadence without delaying asynchronous shell echo.
		pollTerminals();
		var now = Sys.time();
		if (now < nextBackgroundPoll) return;
		nextBackgroundPoll = now + 0.05;
		syncLayoutService();
		if (zoomOverlayUntil > 0 && now >= zoomOverlayUntil) {
			zoomOverlayUntil = 0;
			requestFrame();
		}
		if (host.syncSideBySidePanes()) requestFrame();
		if (contextFiles != null && dock.isOpen("context-panel")) contextFiles.poll(now);
		pumpApplication();
		syncScmDocumentMarkers(now);
		if (now >= nextScmPoll) {
			nextScmPoll = now + 0.5;
			var source = sourceControlSource();
			if (source != null) { source.poll(); syncScmPresentation(source); maybeAutoFetchScm(source, now); }
		}
		// Rendering hover/selection changes must not perform filesystem polling.
		// Watches make refresh a no-op until a change; unsupported backends poll
		// on a bounded cadence instead of once for every pointer movement.
		var model = explorerModel;
		if (model != null) {
			var localModel:Null<DirectoryTreeModel> = Std.isOfType(model, DirectoryTreeModel) ? cast model : null;
			if (localModel != null) {
				var applyStartedAt = Sys.time();
				var previousRevision = model.revision();
				var changedPaths = localModel.pollLoads();
				if (changedPaths.length > 0) {
					var tree = explorerTree;
					var treeStartedAt = Sys.time();
					if (tree != null) tree.refreshBranches(changedPaths, model.revision());
					var tracePath = Sys.getEnv("EXOSUIT_TREE_TRACE");
					var treeMs = Std.int((Sys.time() - treeStartedAt) * 1000);
					var applyMs = Std.int((Sys.time() - applyStartedAt) * 1000);
					if (tracePath != null && tracePath.length > 0 && (treeMs >= 50 || applyMs >= 50)) {
						try File.appendContent(tracePath,
							'ui-apply=${applyMs}ms tree-refresh=${treeMs}ms paths=${changedPaths.join(",")}\n') catch (_:Dynamic) {}
					}
					requestFrame();
				}
				var ready = localModel.readyExpansions(now);
				if (explorerTree != null) for (path in ready) explorerTree.setExpanded(path, true);
				if (ready.length > 0 || previousRevision != model.revision()) requestFrame();
			}
			if ((Std.isOfType(model, WorkspaceFileTreeModel) || (sidebar.visible && sidebar.activeId == "files")) &&
				(model.watchesChanges() || now >= nextExplorerPoll)) {
				model.refresh();
				nextExplorerPoll = now + 0.5;
			}
		}
	}

	function pumpApplication():Void {
		nextBackgroundPoll = Sys.time() + 0.05;
		if(workbenchClient!=null) {
   var agentService=workbenchClient.agentService();
   agentService.refreshAgents();
   if(agentRevision!=agentService.agentRevision()) {agentRevision=agentService.agentRevision();requestFrame();}
   var now=Sys.time(), catalog=agentService.agents();
   if(catalog!=null && catalog.records.length>0 && now>=codexPoll) {
    codexPoll=now+0.2;
    var active=host.activeTab(), activeAgent=active==null?null:UiEditorTabs.agent(active);
    var selected=activeAgent!=null && activeAgent.workspaceRoot==catalog.root && now>=nextActiveCodexRead
      ? activeAgent.resource : null;
    if(selected!=null) nextActiveCodexRead=now+1;
    else {
     var count=catalog.records.length;
     if(codexReadIndex>=count) codexReadIndex=0;
     selected=catalog.records[codexReadIndex++].id;
    }
    agentService.agentAction(selected,"read","",null);
   }
  }
        if((terminalBrowserVisible || groupEditor != null || (sidebar.visible && sidebar.activeId == "workbench")) && workbenchClient!=null) workbenchClient.refreshTerminals(false);
        if(workbenchClient!=null && workbenchClient.terminalCatalogRevision()!=terminalBrowserRevision) {
            terminalBrowserRevision=workbenchClient.terminalCatalogRevision();
            var catalog=workbenchClient.terminalCatalog();
            if(catalog!=null) for(record in catalog.terminals) for(tab in host.allTerminalTabs())
                if(tab.remote && tab.resourceId==record.id && tab.workspaceRoot==record.workspaceRoot) { tab.updateWorkspaceName(record.name); tab.cwd=record.cwd; }
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
			var fileClient = attachment.fileClient();
			if (fileClient != searchFileClient) {
				searchFileClient = fileClient;
				searchPanel.workspaceAttachmentChanged();
			}
			var failure = attachment.failure();
			if (failure != null && failure != workspaceError) application.reportError("workspace", failure);
			workspaceError = failure;
			var label = attachment.statusLabel();
			if (workspaceStatus != label) {
				workspaceStatus = label;
				requestFrame();
			}
		}
		remoteFileSearch.update(Sys.time());
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
		if (notificationRevision != host.getNotifications().revision) {
			notificationRevision = host.getNotifications().revision;
			requestFrame();
		}
		if (notificationsVisible && notificationPanel != null) notificationPanel.poll();
		ui.buildContext.environment.scrollbarVisibility = host.scrollbarVisibility;
	}

	function pollTerminals():Void {
		for (terminal in host.allTerminalTabs()) {
			if (terminal.disposed) continue;
			try {
				if (terminal.poll()) requestFrame();
				terminalErrors.remove(terminal.id);
			} catch (error:Dynamic) {
				statusMessage = "Terminal: " + Std.string(error);
				var message = Std.string(error);
				if (terminalErrors.get(terminal.id) != message) {
					terminalErrors.set(terminal.id, message);
					application.errors.record("terminal", message);
					var actions:Array<feedback.NotificationAction> = [];
					var terminalId = terminal.id;
					if (terminal.remote) actions.push(new feedback.NotificationAction("Open terminal", function() {
						for (target in host.allTerminalTabs()) if (target.id == terminalId && !target.disposed) {
							hideNotifications();
							var index = host.panelTerminals.indexOf(target);
							if (index >= 0) { host.activePanelTerminalIndex = index; openTerminalPanel(); }
							else showTerminalInEditor(target);
							return;
						}
					}));
					if (createTerminal != null || createWorkspaceTerminal != null)
						actions.push(new feedback.NotificationAction("Create terminal", function() {
							hideNotifications();
							var replacement = newTerminalTab();
							if (replacement != null) showTerminalInEditor(replacement);
						}));
					var explanation = terminal.title + ": " + message;
					if (terminal.remote) explanation += "\nWorkspace: " + terminal.workspaceRoot
						+ "\nSession: " + terminal.resourceId
						+ "\nThis view refers to the original session. Create a terminal to start a new shell in the current workspace.";
					host.getNotifications().publish(explanation, feedback.NotificationKind.Error, "terminal", actions);
				}
				if (terminal.remote) { requestFrame(); continue; }
				terminal.dispose();
                host.hiddenTerminals.remove(terminal);
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
		layoutModes.dispose();
		layoutControls.dispose();
		if (contextFiles != null) contextFiles.dispose();
		if (notificationPanel != null) notificationPanel.close();
		cancelScmBranchRequest();
		if (hostContext != null) hostContext.onPoll = null;
		application.onScmWatchPathsChanged = null;
		if (scmFocusSubscription != null) scmFocusSubscription.dispose();
		scmFocusSubscription = null;
		if (scmDirectoryWatch != null) scmDirectoryWatch.dispose();
		scmDirectoryWatch = null;
		clearLocalScmSource();
		clearExplorerModel();
		remoteFileSearch.cancel();
		if (workspaceAttachment != null) workspaceAttachment.dispose();
		application.shutdown();
		host.dispose();
		if (desktop != null) desktop.shutdown();
		ui.dispose();
	}

	function findStyleNode(node:Null<RenderNode>, key:String):Null<RenderNode> {
		if (node == null) return null;
		if (node.styleKey == key) return node;
		for (child in node.children) {
			var found = findStyleNode(child, key);
			if (found != null) return found;
		}
		return null;
	}

	function diagnosticTreeItems(node:Null<RenderNode>, result:Array<Dynamic>):Void {
		if (node == null) return;
		if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem)
			result.push({key: node.semantics.label, bounds: targetBounds(node)});
		for (child in node.children) diagnosticTreeItems(child, result);
	}

	public function diagnosticState():Dynamic {
		var treeItems:Array<Dynamic> = [];
		diagnosticTreeItems(ui.root, treeItems);
		var active = host.activeDocument();
		var activeView = host.activeView();
		var tab = host.activeTab();
		var source = sourceControlSource();
		var repositories = source == null ? [] : source.repositories();
		var firstRepository = repositories.length == 0 ? null : repositories[0];
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		var agent = tab == null ? null : UiEditorTabs.agent(tab);
		var agentClient = workbenchClient == null ? null : workbenchClient.agentService();
		var agentView = agent == null || agentClient == null ? null : agentClient.agentView(agent.resource);
		var agentRequest = agentView == null || agentView.requests.length == 0 ? null : agentView.requests[0];
		var agentItems = agentView == null || agentView.items == null ? [] : agentView.items;
		var agentSummary = agentView == null ? null : {
			id: agentView.record.id,
			workspaceRoot: agentView.record.workspaceRoot,
			thread: agentView.record.thread,
			state: agentView.record.state,
			itemCount: agentItems.length,
			messageCount: [for (item in agentItems) if (item.kind == "agentMessage") item].length,
			requestMethods: [for (request in agentView.requests) request.method]
		};
		if (terminal == null) terminal = host.activePanelTerminal();
		var panel = terminal == null ? null : terminal.panel;
		var target = function(id:String):Dynamic {
			var node = findStyleNode(ui.root, id);
			return targetBounds(node);
		};
		var targetByLabel = function(label:String):Dynamic return targetBounds(findSemanticsLabel(ui.root, label));
		var searchQueryNode = findSemanticsLabel(ui.root, "Search in projects");
		var remoteFileResultIndex = -1;
		var remoteDirectoryResultIndex = -1;
		for (index in 0...remoteFileSearch.results.length) {
			var match = remoteFileSearch.results[index];
			if (match.kind == "file" && remoteFileResultIndex < 0) remoteFileResultIndex = index;
			if (match.kind == "directory" && remoteDirectoryResultIndex < 0) remoteDirectoryResultIndex = index;
		}
		return {
			documents: [for (view in host.allViews()) view.document.title],
			editorSelections: [for (view in host.allViews()) {
				title:view.document.title, anchorLine:view.selection.anchor.line,
				anchorColumn:view.selection.anchor.column, cursorLine:view.selection.cursor.line,
				cursorColumn:view.selection.cursor.column, scrollY:view.scrollController.offsetY
			}],
			workspaceFileTabs: workspaceFileDiagnostics(),
			workspaceFileReads: {active: workspaceFileLoader.active, completed: workspaceFileLoader.completedReads,
				cacheHits: workspaceFileLoader.cacheHits, cachedBytes: workspaceFileLoader.cachedBytes, lastReadMs: workspaceFileLoader.lastReadMs},
			viewport: {width: viewportWidth, height: viewportHeight, phoneLayout: phoneLayoutActive,
				sidebarVisible: sidebar.visible, explorerOpen: dock.isOpen("explorer"), activePanel: dock.activePanelId},
			sourceControl: source == null ? null : {
				remote: source.isRemote(), connected: source.connected(), repositoryCount: repositories.length,
				canWrite: firstRepository != null && source.canWrite(firstRepository.id),
				canUseRemotes: firstRepository != null && source.canUseRemotes(firstRepository.id),
				commitMessage: target("scm-commit-message:" + (firstRepository == null ? "" : firstRepository.id)),
				commitButton: target("scm-commit-staged"), rowMutation: target("scm-row-action:file-mutation")
			},
			activeDiff: activeView != null && activeView.diffDocument != null,
			active: active == null ? -1 : active.id,
				documentsSource: "core.Application (via UiWorkbenchHost)",
			treeItems: treeItems,
			explorerRoot: explorerRoot,
			explorerIdentity: explorerModel == null ? null : explorerModel.rootIdentity(),
			explorerWatching: explorerModel != null && explorerModel.watchesChanges(),
			explorerRevision: explorerModel == null ? -1 : explorerModel.revision(),
			workspaceIndex: [for (project in application.workspace.projects) {
				root: project.root, files: project.files().length, indexing: project.indexing(), generation: project.indexGeneration()
			}],
			sidebarMode: sidebar.activeId,
            workbenchSelectedNode: workbenchPanel == null ? null : workbenchPanel.tree.selectedKey,
			sidebarState: sidebar.encode(),
			panels: dock.panelIds(),
			status: statusMessage,
			workspaceConnection: workspaceStatus,
			notificationCount: host.getNotifications().entries.length,
			unreadNotifications: host.getNotifications().unreadCount(),
			notificationsVisible: notificationsVisible,
			paletteCommandCount: ui.commands.ids().length,
			errors: [for (entry in application.errors.entries) {source: entry.source, message: entry.message}],
			plugins: application.plugins.enabledIds(),
			terminalIds: [for (terminal in host.allTerminalTabs()) terminal.id],
			terminalResourceIds: [for (terminal in host.allTerminalTabs()) terminal.resourceId],
			terminalBrowserVisible: terminalBrowserVisible,
			terminalCreationFailure: terminalCreationFailure(),
            terminalEditorTabs: host.terminalEditorResourceIds(),
            terminalPanelTabs: [for (terminal in host.panelTerminals) terminal.resourceId],
            terminalHiddenTabs: [for (terminal in host.hiddenTerminals) terminal.resourceId],
			agentCatalog:workbenchClient==null?null:workbenchClient.agentService().agents(),
	   agentTabs:host.agentResourceIds(),
			activeAgentSummary: agentSummary,
			testTargets: {
				newCodex: target("workbench-new-codex"),
				codexViewport: target("codex-session-viewport"),
				filesActivity: targetByLabel("Files"),
				sourceControlActivity: targetByLabel("Source Control"),
				sourceControlPanel: target("source-control-panel"),
				newTerminal: target("workbench-new-terminal"),
				terminalToolbar: target("toolbar-Terminal"),
				terminalPane: target("terminal-pane"),
				pairingUrl: target("remote-pairing-url"),
				pairingConnect: target("remote-pairing-connect"),
				pairingConfirm: target("remote-pairing-confirm-code"),
				prompt: target("codex-prompt"),
				send: target("codex-send"),
				approve: agentRequest == null ? null : target("codex-approve-" + agentRequest.id),
				answer: agentRequest == null ? null : target("codex-answer-" + agentRequest.id),
				searchActivity: targetByLabel("Search"),
				remoteAccessActivity: targetByLabel("Remote Access"),
				workbenchActivity: targetByLabel("Workbench"),
				localSearchResult: target("workspace-search-result-0"),
				remoteSearchQuery: targetByLabel("Search in projects"),
				remoteSearchQueryFocused: searchQueryNode != null && searchQueryNode.semantics != null
					&& (searchQueryNode.semantics.states & AccessibilityState.Focused) != 0,
				remoteSearchMode: target("workspace-search-remote-mode"),
				remoteSearchResult: target("workspace-remote-search-result-0"),
				remoteSearchResult1: target("workspace-remote-search-result-1"),
				remoteSearchFileResult: remoteFileResultIndex < 0 ? null : target("workspace-remote-search-result-" + remoteFileResultIndex),
				remoteSearchDirectoryResult: remoteDirectoryResultIndex < 0 ? null : target("workspace-remote-search-result-" + remoteDirectoryResultIndex),
				remoteSearchState: {
					active: remoteFileSearch.active, query: remoteFileSearch.query, mode: remoteFileSearch.mode,
					count: remoteFileSearch.results.length, complete: remoteFileSearch.complete,
					results: [for (match in remoteFileSearch.results) {kind: match.kind, path: match.path}],
					truncated: remoteFileSearch.truncated, scannedEntries: remoteFileSearch.scannedEntries,
					skippedEntries: remoteFileSearch.skippedEntries, error: remoteFileSearch.error
				}
			},
			terminalCatalog: workbenchClient == null ? null : workbenchClient.terminalCatalog(),
			terminal: panel == null ? "closed" : panel.status(),
			terminalColumns: panel == null ? 0 : panel.columns(),
			terminalControl: Std.isOfType(panel, TerminalPane) ? cast(panel, TerminalPane).controlStatus() : null,
			terminalRows: panel == null ? 0 : panel.rows(),
			terminalScreen: Std.isOfType(panel, TerminalPane) ? cast(panel, TerminalPane).diagnosticState() : null
		};
	}

	static function targetBounds(node:Null<RenderNode>):Dynamic {
		if (node == null) return null;
		var bounds = node.globalBounds();
		return {x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height};
	}

	static function findSemanticsLabel(node:Null<RenderNode>, label:String):Null<RenderNode> {
		if (node == null) return null;
		if (node.semantics != null && node.semantics.label == label) return node;
		for (child in node.children) {
			var found = findSemanticsLabel(child, label);
			if (found != null) return found;
		}
		return null;
	}

	function workspaceFileDiagnostics():Array<Dynamic> {
		var result:Array<Dynamic> = [];
		for (pane in host.panes) for (item in pane.items) {
			var file = UiEditorTabs.workspaceFile(item);
			if (file != null) result.push({scope: file.scope, root: file.rootName, path: file.path,
				revision: file.revision, preview: file.preview, syntax: file.textModel.syntax.name,
				loading: file.loading, loadError: file.loadError, contentReadyMs: file.contentReadyMs,
				diskChanged: file.diskChanged, searchSelection: file.searchSelection == null ? null : {
					start: file.searchSelection.anchor, end: file.searchSelection.focus
				}});
		}
		return result;
	}

	function contextPanel():View {
		if (contextFiles == null) contextFiles = new ContextFilesView(function() return application.activeContext.roots,
			function() return workspaceAttachment == null ? "local" : workspaceAttachment.fileWorkspace() + ":" + workspaceAttachment.fileScope(),
			function(roots) {
				var attachment = workspaceAttachment;
				if (attachment != null && !attachment.hasLocalFileAccess()) {
					var scope = attachment.fileScope(); if (scope == null) scope = roots[0];
					return new WorkspaceFileTreeModel(function() return workspaceAttachment == null ? null : workspaceAttachment.fileClient(),
						attachment.fileWorkspace(), scope, application.activeContext.label, theme, requestFrame,
						function(root) host.markWorkspaceFilesChanged(scope, root), attachment.sourceControlSource());
				}
				var model = new DirectoryTreeModel(roots[0], theme, roots);
				model.fontSize = application.settings.current.explorerFontSize;
				return model;
			}, function(model, path, pin) {
				if (Std.isOfType(model, WorkspaceFileTreeModel)) {
					var remote:WorkspaceFileTreeModel = cast model;
					if (remote.isMoreKey(path) || remote.isRetryKey(path)) remote.activateSpecial(path);
					else if (!remote.isDirectoryKey(path)) openWorkspaceFile(remote, path, pin);
				} else if (Std.isOfType(model, DirectoryTreeModel)) {
					var local:DirectoryTreeModel = cast model;
					if (local.isSyntheticRow(path)) local.activateSyntheticRow(path);
					else if (!local.isDirectoryPath(path)) application.openInBackground(path, !pin, pin);
				}
			}, host, requestFrame, function() return darkPalette, hostContext == null ? null : hostContext.events);
		var style = fillStyle(); style.childGap = 4;
		var captionStyle = new LayoutStyle(); captionStyle.padding = new Insets(10, 6, 10, 0);
		return new Column("context-panel-content", [
			new KeyedView("scope", new Text(application.activeContext.label, captionStyle, theme.tokens.textSecondary, TextStyleOverride.text(12))),
			new KeyedView("tabs", new Tabs("context-panel-tabs", [new TabItem("context-files", "Files", contextFiles),
				new TabItem("context-changes", "Changes", sourceControlPanel())], "context-files", function(_) requestFrame(), fillStyle()))
		], style);
	}

	function layoutShortcut(command:String):String return [for (shortcut in ui.commands.shortcutsFor(command)) shortcut.label()].join(", ");

	function layoutButton(region:String, label:String, command:String, selected:Bool):View {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH); style.height = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH);
		style.padding = new Insets(6, 6, 6, 6);
		var button = new Button("", style, function() { ui.commands.executeContext(command, ui.commandContext); requestFrame(); }, "layout-" + region);
		button.variant = ButtonVariant.Navigation; button.selected = selected;
		button.accessibilityLabel = label;
		if (region == "menu") button.leadingIcon = IconName.Grid;
		else button.leadingView = new LayoutControlIcon(region, theme.tokens.textSecondary);
		var shortcut = layoutShortcut(command);
		return new TabTooltip("layout-tooltip-" + region, button, new Text(label + (shortcut.length == 0 ? "" : " (" + shortcut + ")")),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), 0.5);
	}

	function showLayoutMenu():Void {
		var items:Array<haxeon.ui.widgets.overlays.MenuItem> = [];
		var commands = ["exosuit.workbench:toggle-sidebar", "view.layout-bottom", "view.layout-right"];
		var labels = [(dock.isOpen("explorer") ? "Hide" : "Show") + " Left Sidebar",
			(layoutControls.bottomOpen() ? "Hide" : "Show") + " Bottom Panel", (layoutControls.rightOpen() ? "Hide" : "Show") + " Right Panel"];
		for (index in 0...commands.length) {
			var command = commands[index];
			if (ui.commands.get(command) != null) items.push(new haxeon.ui.widgets.overlays.MenuItem(command, labels[index], function() {
				contextMenu = null; ui.commands.executeContext(command, ui.commandContext); requestFrame();
			}, true, layoutShortcut(command)));
		}
		for (mode in [LayoutMode.Editor, LayoutMode.Agents]) {
			var selected = mode;
			items.push(new haxeon.ui.widgets.overlays.MenuItem("view.mode-" + mode.id, (layoutModes.current.id == mode.id ? "✓ " : "") + mode.label + " Layout", function() { contextMenu = null; layoutModes.select(selected.id); requestFrame(); }));
		}
		items.push(new haxeon.ui.widgets.overlays.MenuItem("view.mode-auto", "Automatic Layout", function() { contextMenu = null; layoutModes.automatic(); requestFrame(); }));
		var anchor = findStyleNode(ui.root, "layout-menu");
		var x = Math.max(0, viewportWidth - 290), y = TOOLBAR_HEIGHT + 4;
		if (anchor != null) { var bounds = anchor.globalBounds(); x = Math.min(x, bounds.x); y = bounds.y + bounds.height + 4; }
		contextMenu = new CommandMenu(application.commands, application.context, [], x, y, function() return !phoneLayoutActive,
			function() { contextMenu = null; requestFrame(); }, items, true);
		requestFrame();
	}

	function topBar():View {
		return new RetainedView("toolbar", function(_) return buildTopBar(),
			function() return dock.revision + ":" + phoneLayoutActive + ":" + viewportWidth + ":" + application.activeContext.revision + ":" + application.savedWorkspaces.dirty + ":" + explorerRoot + ":" + workspaceStatus + ":" + canShowTerminal() + ":" + terminalCreationFailure() + ":" + (hostContext == null || hostContext.windowControls == null ? 0 : hostContext.windowControls.revision) + ":" + ui.animations.revision);
	}

	function buildTopBar():View {
		var custom = hostContext != null && hostContext.windowControls != null;
		var actions = toolbarActionCapacity();
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(TOOLBAR_HEIGHT);
		style.direction = LayoutDirection.LeftToRight;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = TOOLBAR_GAP;
		style.padding = new Insets(10.0, 4.0, 10.0, 4.0);
		style.background = theme.tokens.surfaceRaised;
		var titleStyle = new LayoutStyle();
		titleStyle.width = LayoutAxis.fixed(80.0);
		var brandStyle = new LayoutStyle();
		brandStyle.width = LayoutAxis.fixed(BRAND_WIDTH);
		brandStyle.childGap = 6;
		brandStyle.childAlignY = LayoutAlignmentY.Center;
		var items:Array<KeyedView> = [
			new KeyedView("brand", new Row("exosuit-brand", [
				new KeyedView("icon", new BrandingIcon(theme.tokens.surfaceRaised)),
				new KeyedView("name", new Text("EXOSUIT", titleStyle, theme.tokens.text,
					TextStyleOverride.text(13.0, 0.5)))
			], brandStyle))
		];
		// Commands stays available at every width. Drop optional shortcuts in
		// priority order while retaining their usual order when there is room.
		if (actions >= 4) items.push(new KeyedView("new", toolbarButton("New", IconName.NewFile, function() application.newDocument())));
		if (actions >= 1) items.push(new KeyedView("open", toolbarButton("Open", IconName.FolderOpen, openFileDialog)));
		if (actions >= 3) items.push(new KeyedView("open-folder", toolbarButton("Open Folder", IconName.FolderClosed, openFolderDialog)));
		if (actions >= 2) items.push(new KeyedView("save", toolbarButton("Save", IconName.Save,
			function() application.commands.perform("doc:save", application.context))));
		var workspaceTitleStyle = new LayoutStyle(); workspaceTitleStyle.width = LayoutAxis.grow();
		var savedWorkspace = application.savedWorkspaces.current;
		var workspaceTitle = savedWorkspace == null ? (explorerRoot == null ? "" : haxe.io.Path.withoutDirectory(explorerRoot)) :
			savedWorkspace.name + (application.savedWorkspaces.dirty ? " *" : "");
		if (application.activeContext.kind == workspace.ContextKind.Group) {
			workspaceTitle = application.activeContext.label;
			var back = new Button("Back to Workspace", null, function() {
				application.activeContext.useWorkspace(); requestFrame();
			}, "context-back-to-workspace");
			back.variant = ButtonVariant.Navigation;
			items.push(new KeyedView("context-back", back));
		}
		if (custom) {
			var caption = workspaceTitle + (workspaceStatus.length == 0 ? "" : (workspaceTitle.length == 0 ? "" : " · ") + workspaceStatus);
			items.push(new KeyedView("workspace-title", new haxeon.ui.widgets.text.MiddleEllipsisText("toolbar-workspace-title", caption, true,
				new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None, null, null, null, theme.tokens.textSecondary))));
		} else items.push(new KeyedView("workspace-title", new Text(workspaceTitle, workspaceTitleStyle, theme.tokens.textSecondary,
			new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None))));
		if (!custom && workspaceStatus.length > 0)
			items.push(new KeyedView("workspace-status", new Text(workspaceStatus, null, theme.tokens.textSecondary, TextStyleOverride.text(12.0))));
		items.push(new KeyedView("palette", toolbarButton("Commands", IconName.Search, togglePalette)));
		if (!phoneLayoutActive) {
			items.push(new KeyedView("layout-left", layoutButton("left", "Toggle Left Sidebar", "exosuit.workbench:toggle-sidebar", dock.isOpen("explorer"))));
			items.push(new KeyedView("layout-bottom", layoutButton("bottom", "Toggle Bottom Panel", "view.layout-bottom", layoutControls.bottomOpen())));
			if (capabilities.supports(HostCapability.Filesystem))
				items.push(new KeyedView("layout-right", layoutButton("right", "Toggle Right Panel", "view.layout-right", layoutControls.rightOpen())));
			items.push(new KeyedView("layout-menu", layoutButton("menu", "Layout", "view.layout-menu", false)));
		}
		var toolbar:View = new Row("exosuit-toolbar", items, style);
		return hostContext != null && hostContext.windowControls != null
			? new haxeon.ui.widgets.WindowTitleBar("exosuit-titlebar", toolbar, hostContext.windowControls, TOOLBAR_HEIGHT) : toolbar;
	}

	function toolbarActionCapacity():Int {
		if (hostContext == null || hostContext.windowControls == null) return 5;
		var available = viewportWidth - haxeon.ui.widgets.WindowTitleBar.CONTROLS_WIDTH - (phoneLayoutActive ? 0 : 4 * (TOOLBAR_BUTTON_WIDTH + TOOLBAR_GAP));
		// Brand, horizontal padding, Commands, two gaps and a small title area.
		var reserved = BRAND_WIDTH + 20.0 + TOOLBAR_BUTTON_WIDTH + 2 * TOOLBAR_GAP + 32.0;
		return Std.int(Math.max(0, Math.min(5, Math.floor((available - reserved) / (TOOLBAR_BUTTON_WIDTH + TOOLBAR_GAP)))));
	}

	function toolbarButton(label:String, icon:IconName, action:Void->Void):View {
		var custom = hostContext != null && hostContext.windowControls != null;
		var style = new LayoutStyle();
		if (custom) { style.width = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH); style.height = LayoutAxis.fixed(28); style.padding = new Insets(8, 0, 8, 0); }
		var button = new Button(custom ? "" : label, style, action, "toolbar-" + label);
		button.accessibilityLabel = label;
		if (label == "Terminal") button.enabled = canShowTerminal();
		button.variant = custom ? ButtonVariant.Navigation : ButtonVariant.Secondary;
		button.leadingIcon = icon;
		return custom || label == "Terminal" ? new TabTooltip("toolbar-tooltip:" + label, button,
			new Text(label == "Terminal" && !canShowTerminal() ? terminalCreationFailure() : label, null, theme.tokens.textPrimary, TextStyleOverride.text(12)),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), 0.5) : button;
	}

	function showNotifications(?entry:feedback.Notification):Void {
		if (notificationPanel == null) notificationPanel = new NotificationPanel(host.getNotifications(),
			function(text) ui.clipboard.writeText(text), requestFrame, hideNotifications, application.processes);
		notificationsVisible = true;
		notificationPanel.open(entry);
	}

	function hideNotifications():Void {
		notificationsVisible = false;
		if (notificationPanel != null) notificationPanel.close();
		requestFrame();
	}

	function statusBar():View {
		var active = host.activeDocument();
		var tab = host.activeTab();
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		// A diff view's document is generated, never saved, so it has no unsaved changes to flag.
		var activeView = host.activeView(), diff = activeView != null && activeView.diffDocument != null;
		var label = active == null ? (terminal == null ? "No document open" : terminal.title) :
			(active.title + (active.dirty && !diff ? " *" : "") + " - " + active.encodingLabel());
		var image = tab == null ? null : UiEditorTabs.image(tab);
		var unsupported = tab == null ? null : UiEditorTabs.unsupportedFile(tab);
		if (image != null) label = image.title;
		else if (unsupported != null) label = unsupported.title;
		var center = host.getNotifications();
		var notification = center.current();
		var languageStatus = application.language.statusLabel();
		var attachment = workspaceAttachment;
		var remote = attachment != null && !attachment.hasLocalFileAccess();
		var remoteDetails = remote ? "Remote workspace · " + attachment.statusLabel()
			+ (attachment.fileScope() == null ? "" : "\n" + attachment.fileScope())
			+ (attachment.failure() == null ? "" : "\n" + attachment.failure()) : "";
		var indentSettings = active == null ? null : application.configuration.settingsFor(active);
		var indentation = indentSettings == null ? "" : (indentSettings.insertSpaces ? "Spaces: " : "Tabs: ") + indentSettings.indentSize;
		var indentationDetails = active == null || indentSettings == null ? "" : indentation + " · Tab width: " + indentSettings.tabWidth + " · " + active.indentation.source;
		var trailing = languageStatus.length > 0 ? languageStatus : '${host.activePane.items.length} open';
		if (image != null) trailing = "Whole Image · " + image.image.width + " × " + image.image.height + " px · " + FileSizeLabel.format(image.sizeBytes);
		else if (unsupported != null) trailing = (unsupported.file.binary ? "Binary file" : "Unsupported encoding") + " · " + FileSizeLabel.format(unsupported.file.sizeBytes);
		return new RetainedView("status-bar", function(_) return new StatusBarView({
			document: label,
			indentation: active == null ? null : indentation,
			indentationDetails: indentationDetails,
			openIndentation: function() application.configuration.openIndentationCommandView(active),
			items: host.getPluginStatusItems().items(),
			runCommand: function(command) { application.commands.perform(command, application.context); requestFrame(); },
			status: trailing,
			remoteDetails: remoteDetails,
			notification: notification,
			notificationsVisible: notificationsVisible,
			unread: center.unreadCount(),
			viewport: function() return new Rect(0, 0, viewportWidth, viewportHeight),
			openRemote: function() showSidebarMode("remote-access"),
			showNotification: function(entry) showNotifications(entry),
			dismissNotification: function() { center.dismissToast(); requestFrame(); },
			toggleNotifications: function() { if (notificationsVisible) hideNotifications(); else showNotifications(); }
		}), function() return indentationDetails + ":" + remoteDetails + ":" + label + ":" + trailing + ":" +
			host.getPluginStatusItems().revision + ":" + (notification == null ? 0 : notification.id) + ":" + center.revision + ":" + notificationsVisible + ":" + ui.animations.revision);
	}

	function showFilesScope():Void {
		var entries = [new commandview.CommandViewEntry("Context", application.activeContext.label, "context"),
			new commandview.CommandViewEntry("Workspace", "All workspace roots", "workspace")];
		host.openCommandView(new commandview.CommandViewProvider("Files Scope: ", entries, _ -> {}, function(entry, _, _) {
			if (entry != null) {
				filesUseWorkspaceRoots = entry.value == "workspace";
				var roots = localExplorerRoots(); explorerRoot = roots.length == 0 ? null : roots[0];
				clearExplorerModel(); requestFrame();
			}
			host.closeCommandView();
		}));
	}

	function bottomPanelActions():View {
		var maximized = layoutControls.bottomMaximized;
		var style = new LayoutStyle();
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 2;
		style.padding = new Insets(0, 4, 0, 4);
		return new Row("bottom-panel-actions", [
			new KeyedView("maximize", bottomPanelButton("bottom-panel-maximize", maximized ? "Restore Panel" : "Maximize Panel",
				maximized ? IconName.ArrowDown : IconName.ArrowUp, function() { layoutControls.toggleBottomMaximized(); requestFrame(); })),
			new KeyedView("hide", bottomPanelButton("bottom-panel-hide", "Hide Panel", IconName.Close,
				function() { layoutControls.hideBottom(); requestFrame(); }))
		], style);
	}

	function bottomPanelButton(key:String, label:String, icon:IconName, action:Void->Void):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(28); style.height = LayoutAxis.fixed(28);
		style.padding = new Insets(6, 6, 6, 6);
		style.childAlignY = LayoutAlignmentY.Center;
		var button = new Button("", style, action, key);
		button.variant = ButtonVariant.Navigation;
		button.leadingIcon = icon; button.iconSize = 16;
		button.accessibilityLabel = label;
		return new TabTooltip(key + "-tooltip", button, new Text(label),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), application.settings.current.tabTooltipDelay);
	}

	function explorerHeaderActions():View {
		var remote = workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess();
		var available = explorerRoot != null;
		var style = new LayoutStyle();
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 2;
		style.padding = new Insets(2, 0, 6, 0);
		return new Row("explorer-header-actions", [
			new KeyedView("scope", explorerHeaderButton("Files scope", IconName.ChevronDown, showFilesScope, true)),
			new KeyedView("new-file", explorerHeaderButton("New File", IconName.NewFile,
				function() createExplorerEntry(false), available && !remote, remote)),
			new KeyedView("new-folder", explorerHeaderButton("New Folder", IconName.NewFolder,
				function() createExplorerEntry(true), available && !remote, remote)),
			new KeyedView("refresh", explorerHeaderButton("Refresh", IconName.Reset, function() {
				if (explorerModel != null) explorerModel.refreshAll();
				requestFrame();
			}, available)),
			new KeyedView("collapse", explorerHeaderButton("Collapse All", IconName.CollapseAll, function() {
				if (explorerTree != null) explorerTree.collapseAll(true);
				requestFrame();
			}, available))
		], style);
	}

	function explorerHeaderButton(label:String, icon:IconName, action:Void->Void, enabled:Bool, readOnly:Bool = false):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(24);
		style.height = LayoutAxis.fixed(24);
		style.padding = new Insets(4, 4, 4, 4);
		style.childDistribution = haxeon.ui.LayoutDistribution.Center;
		style.childAlignY = LayoutAlignmentY.Center;
		var button = new Button("", style, action, "explorer-action:" + label);
		button.enabled = enabled;
		button.variant = ButtonVariant.Navigation;
		button.leadingIcon = icon;
		button.iconSize = 16;
		button.accessibilityLabel = label;
		return new TabTooltip("explorer-action-tooltip:" + label, button,
			new Text(readOnly ? label + " (remote files are read-only)" : label, null, theme.tokens.textPrimary, TextStyleOverride.text(12)),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), 0.5);
	}

	function createExplorerEntry(folder:Bool):Void {
		if (explorerRoot == null || (workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess())) return;
		var base = explorerRoot;
		var selected = explorerTree == null ? null : explorerTree.selectedKey;
		var model:Null<DirectoryTreeModel> = Std.isOfType(explorerModel, DirectoryTreeModel) ? cast explorerModel : null;
		if (selected != null && model != null && !model.isSyntheticRow(selected))
			base = model.isDirectoryPath(selected) ? selected : haxe.io.Path.directory(selected);
		var refresh = function() {
			if (model != null) model.refreshDirectory(base);
			requestFrame();
		};
		if (folder) application.files.openCreateFolder(base, refresh);
		else application.files.openCreateFile(base, refresh);
	}

	function beginExplorerRename(path:String, rename:String->Bool):Bool {
		if (!sidebar.visible || sidebar.activeId != "files") return false;
		var tree = explorerTree;
		var model:Null<DirectoryTreeModel> = Std.isOfType(explorerModel, DirectoryTreeModel) ? cast explorerModel : null;
		if (tree == null || model == null || tree.selectedKey != path || model.isSyntheticRow(path)) return false;
		if (application.savedWorkspaces.roots().indexOf(path) >= 0) { application.reportError("files", "Project roots cannot be renamed while open."); return true; }
		host.closeCommandView();
		tree.scrollIntoView(path);
		host.focusExplorer();
		explorerRename = new ExplorerRename(path, model.isDirectoryPath(path), rename, function(destination) {
			if (explorerRename == null || explorerRename.path != path) return;
			explorerRename = null;
			if (destination != null) {
				renamedExplorerPath = destination;
				host.setSelectedExplorerPath(destination);
				model.refreshDirectory(haxe.io.Path.directory(path));
			}
			requestFrame();
		}, requestFrame, function(message) application.reportError("files", message), application.settings.current.explorerFontSize);
		requestFrame();
		return true;
	}

	function localExplorerRoots():Array<String> {
		var roots = filesUseWorkspaceRoots ? application.savedWorkspaces.roots() : application.activeContext.roots;
		if (filesUseWorkspaceRoots) return roots;
		return roots.length == 0 && explorerRoot != null ? [explorerRoot] : roots;
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
		var remoteFiles = attachment != null && !attachment.hasLocalFileAccess();
		var remoteScope:String = explorerRoot;
		var remoteWorkspace = attachment == null ? "" : attachment.fileWorkspace();
		if (attachment != null && attachment.fileScope() != null) remoteScope = attachment.fileScope();
		var remoteModelCurrent = explorerModel != null && Std.isOfType(explorerModel, WorkspaceFileTreeModel)
			&& (cast(explorerModel, WorkspaceFileTreeModel)).scopeId() == remoteScope
			&& (cast(explorerModel, WorkspaceFileTreeModel)).workspaceId() == remoteWorkspace;
		var localModelCurrent = explorerModel != null && Std.isOfType(explorerModel, DirectoryTreeModel)
			&& explorerModel.rootIdentity() == localExplorerRoots().join("\n");
		if (remoteFiles ? !remoteModelCurrent : !localModelCurrent) {
			clearExplorerModel();
			if (remoteFiles) {
				var rootName = remoteScope;
				var slash = rootName.lastIndexOf("/");
				if (slash >= 0 && slash + 1 < rootName.length) rootName = rootName.substring(slash + 1);
				explorerModel = new WorkspaceFileTreeModel(function()
					return workspaceAttachment == null ? null : workspaceAttachment.fileClient(),
					remoteWorkspace, remoteScope, rootName, theme, requestFrame,
					function(root) { workspaceFileLoader.clearCache(); host.markWorkspaceFilesChanged(remoteScope, root); },
					attachment == null || attachment.hasLocalFileAccess() ? null : attachment.sourceControlSource());
			} else explorerModel = new DirectoryTreeModel(explorerRoot, theme, localExplorerRoots());
		}
		if (explorerModel != null) explorerModel.setResourceDecorations(host.getResourceDecorations());
		var remoteModel:Null<WorkspaceFileTreeModel> = Std.isOfType(explorerModel, WorkspaceFileTreeModel)
			? cast explorerModel : null;
		var localModel:Null<DirectoryTreeModel> = Std.isOfType(explorerModel, DirectoryTreeModel)
			? cast explorerModel : null;
		if (remoteModel != null) remoteModel.fontSize = application.settings.current.explorerFontSize;
		if (localModel != null) localModel.fontSize = application.settings.current.explorerFontSize;
		if (explorerTree != null) {
			if (remoteModel != null) advanceWorkspaceFolderReveal(explorerTree, remoteModel);
			return new ExplorerTreeView(explorerTree, explorerModel, darkPalette, hostContext == null ? null : hostContext.events, explorerRename,
			host.focusExplorer, function(command) application.commands.perform(command, application.context));
		}
		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.grow();
		viewportStyle.height = LayoutAxis.grow();
		viewportStyle.clipHorizontal = true;
		var tree = new TreeView("exosuit-explorer-tree", explorerModel, viewportStyle, filesScroll, 640.0,
			null, [for (index in 0...explorerModel.rootCount()) explorerModel.rootKeyAt(index)], function(key) {
				if (localModel == null || !localModel.isSyntheticRow(key)) host.setSelectedExplorerPath(key);
			}, function(key) {
				if (remoteModel != null) {
					if (remoteModel.isMoreKey(key) || remoteModel.isRetryKey(key)) remoteModel.activateSpecial(key);
					else if (!remoteModel.isDirectoryKey(key)) openWorkspaceFile(remoteModel, key, true);
				} else if (localModel != null && !localModel.isSyntheticRow(key) && !localModel.isDirectoryPath(key)) application.openInBackground(key);
			}, null, null);
		tree.indentWidth = 10.0;
		tree.verticalGuidesOnly = true;
		tree.guidesOnInteraction = true;
		tree.compactLeafIndent = true;
		tree.expandOnSingleClick = true;
		if (remoteModel != null)
			tree.hasChildrenHint = function(key) return remoteModel.isDirectoryKey(key);
		if (localModel != null) {
			tree.onStateReady = function(current) {
				var path = renamedExplorerPath;
				if (path == null) return;
				var parent = haxe.io.Path.directory(path);
				for (index in 0...localModel.childCount(parent)) if (localModel.childKeyAt(parent, index) == path) {
					current.select(path);
					current.scrollIntoView(path);
					renamedExplorerPath = null;
					break;
				}
			};
			tree.hasChildrenHint = function(key) return localModel.hasChildrenHint(key);
			tree.onExpansionRequested = function(path, expanded, toggle) {
				var allowed = localModel.requestExpansion(path, expanded, toggle);
				requestFrame();
				return allowed;
			};
			tree.onCollapseAll = localModel.cancelRequestedExpansions;
			tree.onExpandedChanged = function(path, expanded) localModel.setDirectoryExpanded(path, expanded);
		}
		tree.onItemClicked = function(path, count) {
			if (remoteModel != null) {
				if (remoteModel.isMoreKey(path) || remoteModel.isRetryKey(path)) {
					if (count == 1) remoteModel.activateSpecial(path);
					return;
				}
				if (count == 1 && !remoteModel.isDirectoryKey(path)) openWorkspaceFile(remoteModel, path, false);
				return;
			}
			if (localModel != null && localModel.isSyntheticRow(path)) {
				if (count == 1 && localModel.activateSyntheticRow(path)) requestFrame();
				return;
			}
			if (count != 1 || (localModel != null && localModel.isDirectoryPath(path))) return;
			try {
				application.openInBackground(path, true, false);
			} catch (error:Dynamic) application.reportError("files", "Could not open file: " + Std.string(error));
		};
		if (localModel != null) tree.onItemRename = function(path) {
			if (explorerRename != null || localModel.isSyntheticRow(path)) return;
			tree.select(path);
			host.setSelectedExplorerPath(path);
			application.files.openRenameFile();
		};
		tree.onItemContextMenu = function(path, event) {
			if (remoteModel != null || (localModel != null && localModel.isSyntheticRow(path))) return;
			var menuRoot = explorerRoot;
			host.setSelectedExplorerPath(path);
			showContextMenu([
				new CommandMenuEntry("file:new", "New File…"),
				new CommandMenuEntry("folder:new", "New Folder…"),
				new CommandMenuEntry("file:rename", "Rename…"),
				new CommandMenuEntry("file:delete", "Delete…"),
				new CommandMenuEntry("workspace:remove-folder", "Remove Folder from Workspace…")
			], event, function() return explorerRoot == menuRoot && host.focusedFilePath() == path && FileSystem.exists(path));
		};
		explorerTree = tree;
		if (remoteModel != null) advanceWorkspaceFolderReveal(tree, remoteModel);
		return new ExplorerTreeView(tree, explorerModel, darkPalette, hostContext == null ? null : hostContext.events, explorerRename,
			host.focusExplorer, function(command) application.commands.perform(command, application.context));
	}

	function advanceWorkspaceFolderReveal(tree:TreeView, model:WorkspaceFileTreeModel):Void {
		var path = pendingWorkspaceFolderReveal;
		if (path == null || path.length == 0) return;
		var parts = path.split("/"), parentKey = model.rootKeyAt(0), currentPath = "";
		for (index in 0...parts.length) {
			if (parts[index].length == 0) { pendingWorkspaceFolderReveal = null; return; }
			currentPath = currentPath.length == 0 ? parts[index] : currentPath + "/" + parts[index];
			var key = model.keyForPath(currentPath), visible = false;
			try { tree.scrollTo(key); visible = true; } catch (_:Dynamic) {}
			if (!visible) {
				if (!tree.isExpanded(parentKey) && tree.setExpanded(parentKey, true)) requestFrame();
				return;
			}
			if (index + 1 < parts.length) {
				if (!tree.isExpanded(key)) {
					if (!tree.setExpanded(key, true)) { pendingWorkspaceFolderReveal = null; return; }
					requestFrame();
				}
				parentKey = key;
				return;
			}
			if (model.isDirectoryKey(key) && !tree.isExpanded(key) && tree.setExpanded(key, true))
				requestFrame();
			tree.select(key);
			tree.scrollTo(key);
			pendingWorkspaceFolderReveal = null;
			requestFrame();
			return;
		}
	}

	function openWorkspaceFile(model:WorkspaceFileTreeModel, key:String, sticky:Bool):Void {
		var path = model.relativePath(key), entry = model.entryForKey(key);
		if (path == null || path.length == 0 || entry == null) return;
		openWorkspaceFileSnapshot(workspaceAttachment, model.workspaceId(), model.scopeId(), model.rootId(),
			model.rootDisplayName(), path, entry.revision, WorkspaceFileReader.previewSize(entry.size), sticky, null, sticky);
	}

	function openWorkspaceSearchResult(match:FileSearchMatch):Void {
		if (match == null || match.path == null || match.path.length == 0) return;
		if (match.kind == "directory") {
			pendingWorkspaceFolderReveal = match.path;
			showSidebarMode("files");
			return;
		}
		if (match.kind != "file") return;
		var attachment = workspaceAttachment;
		var client = attachment == null ? null : attachment.fileClient();
		if (attachment == null || client == null) {
			application.reportError("search", "Workspace file service is not connected");
			return;
		}
		var scope = attachment.fileScope();
		if (scope == null || scope.length == 0) scope = explorerRoot;
		if (scope == null || scope.length == 0) scope = attachment.fileWorkspace();
		var root = "root";
		if (host.activateWorkspaceFile(scope, root, match.path, false)) {
			var existing = host.workspaceFile(scope, root, match.path);
			if (existing != null && match.line >= 0) existing.selectSearchMatch(match.line, match.column, match.length);
			requestFrame();
			return;
		}
		var workspace = attachment.fileWorkspace();
		client.stat(workspace, root, match.path, function(stat) {
			if (workspaceAttachment != attachment) return;
			if (stat == null || stat.workspace != workspace || stat.root != root || stat.path != match.path
				|| stat.entry == null || stat.entry.kind != "file" || stat.entry.revision == null) {
				application.reportError("search", "Workspace search result is no longer a file");
				return;
			}
			var rootName = scope;
			var slash = rootName.lastIndexOf("/");
			if (slash >= 0 && slash + 1 < rootName.length) rootName = rootName.substring(slash + 1);
			openWorkspaceFileSnapshot(attachment, workspace, scope, root, rootName, match.path, match.revision,
				WorkspaceFileReader.previewSize(stat.entry.size), false, match);
		}, function(error) {
			if (workspaceAttachment == attachment)
				application.reportError("search", error == null ? "Could not open workspace search result" : error.message);
		});
	}

	function openWorkspaceFileSnapshot(attachment:Null<workspace.client.WorkspaceAttachment>, workspace:String,
			scope:String, root:String, rootName:String, path:String, revision:Null<String>, sizeBytes:Null<Int>,
			sticky:Bool, match:Null<FileSearchMatch>, focusEditor:Bool = true):Void {
		if (host.activateWorkspaceFile(scope, root, path, sticky, focusEditor)) {
			var existing = host.workspaceFile(scope, root, path);
			if (existing != null && existing.loading)
				workspaceFileLoader.prioritize(workspaceFileKey(workspace, scope, root, path));
			if (existing != null && match != null && match.line >= 0)
				existing.selectSearchMatch(match.line, match.column, match.length);
			requestFrame();
			return;
		}
		if (sizeBytes == null) {
			application.reportError("files", "File exceeds the 16 MiB preview limit");
			return;
		}
		if (!host.canOpenWorkspaceFile(scope, root, path, sizeBytes)) {
			application.reportError("files", "Workspace file preview memory limit reached; close another file first");
			return;
		}
		var file = new UiWorkspaceFileTab(workspace, root, scope, rootName, path, revision == null ? "" : revision,
			"", sizeBytes, !sticky, application.syntaxes, editorPalette);
		file.loading = true;
		host.openWorkspaceFile(file, !sticky, focusEditor);
		if (focusEditor) host.focusActiveEditor();
		requestFrame();
		loadWorkspaceFile(file, attachment, revision, match);
	}

	function loadWorkspaceFile(file:UiWorkspaceFileTab, attachment:Null<workspace.client.WorkspaceAttachment>,
			revision:Null<String>, match:Null<FileSearchMatch>):Void {
		file.loading = true;
		file.loadError = null;
		var started = Sys.time();
		var key = workspaceFileKey(file.workspace, file.scope, file.root, file.path);
		workspaceFileLoader.load(key, revision, function(complete, wanted) {
			var client = attachment == null ? null : attachment.fileClient();
			if (workspaceAttachment != attachment || client == null || attachment.fileWorkspace() != file.workspace ||
				attachment.fileScope() != null && attachment.fileScope() != file.scope) {
				complete({contents: null, revision: null, sizeBytes: 0, error: "Workspace file service is not connected"});
				return;
			}
			WorkspaceFileReader.read(client, file.workspace, file.root, file.path, revision, complete, wanted);
		}, function() return host.hasWorkspaceFile(file), function(result) {
			file.loading = false;
			if (workspaceAttachment != attachment) {
				file.loadError = "Workspace is disconnected. Reconnect and retry.";
			} else if (result.error != null || result.contents == null || result.revision == null) {
				file.loadError = result.error == null ? "Could not read workspace file" : result.error;
			} else if (!host.canOpenWorkspaceFile(file.scope, file.root, file.path, result.sizeBytes)) {
				file.loadError = "Workspace file preview memory limit reached; close another file first";
			} else {
				var updated = new UiWorkspaceFileTab(file.workspace, file.root, file.scope, file.rootName,
					file.path, result.revision, result.contents, result.sizeBytes, file.preview, application.syntaxes, editorPalette);
				updated.contentReadyMs = (Sys.time() - started) * 1000;
				if (match != null && match.line >= 0) updated.selectSearchMatch(match.line, match.column, match.length);
				// Replace in place: an older response must never activate its tab again.
				host.replaceWorkspaceFileSnapshot(file, updated);
			}
			requestFrame();
		});
	}

	function refreshWorkspaceFile(file:UiWorkspaceFileTab):Void {
		if (file == null || file.loading || file.refreshing || !host.hasWorkspaceFile(file)) return;
		if (file.loadError != null) {
			loadWorkspaceFile(file, workspaceAttachment, null, null);
			requestFrame();
			return;
		}
		var key = workspaceFileKey(file.workspace, file.scope, file.root, file.path);
		if (workspaceFileRefreshPending.exists(key)) return;
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
			workspaceFileLoader.pump();
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
					workspaceFileLoader.clearCache();
					workspaceFileLoader.pump();
					file.refreshing = false;
					if (host.replaceWorkspaceFileSnapshot(file, updated)) requestFrame();
				});
		}, function(error) fail((error == null ? "Could not refresh file" : error.message) +
			"; showing the last loaded snapshot"));
	}

	function workspaceFileReadCount():Int {
		var count = workspaceFileLoader.active;
		for (_ in workspaceFileRefreshPending.keys()) count++;
		return count;
	}

	static function workspaceFileKey(workspace:String, scope:String, root:String, path:String):String
		return workspace.length + ":" + workspace + scope.length + ":" + scope + root.length + ":" + root + path;

	/** Register a destination once; the Activity Bar follows the sidebar's order and visibility. */
	public function registerSidebarDestination(id:String, icon:IconName, provider:Void->View,
			options:haxeon.ui.widgets.sidebar.SidebarModeOptions):Void {
		if (contextLayoutsReady) layoutModes.suspend();
		sidebar.register(id, provider, options);
		activityIcons.set(id, icon);
		if (contextLayoutsReady) { layoutModes.resume(); layoutModes.refreshSidebar(); }
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
		var tooltips:Map<String, String> = new Map();
		var tabColors:Map<String, haxeon.ui.Color> = new Map();
		for (item in editorPane.items) {
			var unsupported = UiEditorTabs.unsupportedFile(item);
			if (unsupported != null) {
				var key = UiEditorTabs.key(item);
				var fileTab = new TabItem(key, unsupported.title + (unsupported.preview ? " (preview)" : ""),
					new UnsupportedFileView(unsupported, function() requestFrame()), true);
				fileTab.onClose = function() host.closeTab(item, paneId, true);
				filenames.set(key, unsupported.file.path); items.push(fileTab); continue;
			}
			var image = UiEditorTabs.image(item);
			if (image != null) {
				var imageKey = UiEditorTabs.key(item);
				var imageTab = new TabItem(imageKey, image.title + (image.preview ? " (preview)" : ""),
					new ImagePreviewView(image, function() host.activateEditorTab(imageKey, paneId),
						function(bounds, id) host.editorResolved(paneId, bounds, id)), true);
				imageTab.onClose = function() host.closeTab(item, paneId, true);
				filenames.set(imageKey, image.path);
				items.push(imageTab);
				continue;
			}
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
						function() refreshWorkspaceFile(workspaceFile), application.settings.current.fontSize), true);
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
					function(bounds, id) host.editorResolved(paneId, bounds, id), null, terminalCommandSkipsShell), true, IconName.Terminal);
				terminalTab.onClose = function() host.closeTab(item, paneId, true);
				items.push(terminalTab);
				continue;
			}
			var documentView = UiEditorTabs.document(item);
			if (documentView == null) continue;
			var document = documentView.document;
			var diffDocument = documentView.diffDocument;
			if (document.path != null) {
				var decoration = host.getResourceDecorations().forPath(document.path);
				if (decoration != null) tabColors.set(UiEditorTabs.key(item),
					ResourceDecorationBadge.colorFor(decoration, theme));
			}
			// Reused across frames (not rebuilt each `view()` call) so its
			// `BufferSelection` (shared with `documentView`, see `UiDocumentView`'s
			// doc comment) persists between edits instead of resetting.
			var pane = editorPanes.get(documentView.id);
			if (pane == null) {
				pane = new EditorPane(document, theme, function() {
					requestFrame();
				}, documentView.selection, editorPalette,
					host.getPluginDecorations(), documentView.decorationSearchMatches, documentView.searchDecorationRevision,
					documentView.scrollController, host.getPluginGutterMarkers());
				editorPanes.set(documentView.id, pane);
			}
			pane.readOnly = documentView.readOnly;
			pane.onGutterMarkerClick = gutterMarkerClickHandler == null
				? function(marker) host.selectGutterMarker(marker) : gutterMarkerClickHandler;
			pane.setSemanticTokens(application.language.semanticTokensFor(document));
			var editSettings = application.configuration.settingsFor(document);
			if (documentView.sideBySideDiff) { editSettings = editSettings.copy(); editSettings.wordWrap = false; }
			pane.editSettings = editSettings;
			documentView.editSettings = pane.editSettings;
			documentView.deletionBoundary = pane.deletionBoundary;
			pane.minimapEnabled = application.settings.current.minimapEnabled;
			documentView.clipboard = ui.clipboard;
			documentView.onStateChanged = requestFrame;
			documentView.isActive = function() return host.activeView() == documentView;
			pane.onEditorAction = documentView.performEditorAction;
			pane.onNavigationKey = event -> CommandBridge.navigationKey(application.keymap, application.context, event.key, event.modifiers);
			pane.onDefinition = diffDocument == null ? function() {
				host.activateTab(document, paneId);
				application.commands.perform("language:go-to-definition", application.context);
			} : null;
			pane.requestCursorReveal = documentView.cursorChanged;
			pane.consumeCursorReveal = documentView.consumeCursorReveal;
			pane.applyRestoredScroll = documentView.applyRestoredScroll;
			pane.fontSize = application.settings.current.fontSize;
			pane.applicationZoom = application.settings.current.applicationZoom / 100.0;
			pane.onResolvedEditor = function(bounds, id) host.editorResolved(paneId, bounds, id);
			pane.onActivated = function() host.activateTab(document, paneId);
			pane.onContextMenu = function(event) {
				host.activateTab(document, paneId);
				if (diffDocument != null) {
					var entries = [new CommandMenuEntry("doc:copy", "Copy")];
					if (!documentView.sideBySideDiff) {
						entries.push(new CommandMenuEntry("scm:previous-hunk", "Previous Hunk"));
						entries.push(new CommandMenuEntry("scm:next-hunk", "Next Hunk"));
						entries.push(new CommandMenuEntry("scm:open-file-at-line", "Open File at Line"));
					}
					showContextMenu(entries, event, function() return host.activeView() == documentView);
					return;
				}
				showContextMenu([
					new CommandMenuEntry("doc:undo", "Undo"),
					new CommandMenuEntry("doc:redo", "Redo"),
					new CommandMenuEntry("doc:cut", "Cut"),
					new CommandMenuEntry("doc:copy", "Copy"),
					new CommandMenuEntry("doc:paste", "Paste"),
					new CommandMenuEntry("doc:select-all", "Select All"),
					new CommandMenuEntry("find:open", "Find…"),
					new CommandMenuEntry("find:replace", "Replace…"),
					new CommandMenuEntry("language:go-to-definition", "Go to Definition"),
					new CommandMenuEntry("language:go-to-type-definition", "Go to Type Definition"),
					new CommandMenuEntry("navigation:go-back", "Go Back"),
					new CommandMenuEntry("navigation:go-forward", "Go Forward")
				], event, function() return host.activeView() == documentView);
			};
			pane.onCaretRectChanged = function() {
				if (host.isLanguagePopupVisible()) {
					if (host.textInputArea() == null) host.dismissLanguagePopup();
					else requestFrame();
				}
			};
			var documentKey = UiEditorTabs.key(item);
			filenames.set(documentKey, diffDocument == null ? document.title : diffDocument.path);
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
			var contentItems:Array<KeyedView> = [];
			if (diffDocument == null) contentItems.push(new KeyedView("breadcrumbs", new EditorBreadcrumbs(document, breadcrumbRoot,
				theme.tokens.textSecondary, Color.fromBytes((editorPalette.editorBackground >>> 24) & 255,
					(editorPalette.editorBackground >>> 16) & 255, (editorPalette.editorBackground >>> 8) & 255,
					editorPalette.editorBackground & 255), darkPalette,
				function(path, event) showBreadcrumbMenu(document, paneId, path, event))));
			contentItems.push(new KeyedView("editor", pane));
			var content = new Column("document-content:" + documentView.id, contentItems, contentStyle);
			var title = diffDocument == null ? (document.dirty ? "* " : "") + document.title :
				documentView.sideBySideDiff ? document.title : haxe.io.Path.withoutDirectory(diffDocument.path) + " (diff)";
			if (diffDocument != null) {
				var path = diffDocument.path;
				var source = sourceControlSource();
				if (source != null) for (repository in source.repositories())
					if (repository.id == diffDocument.repositoryId) {
						var relative = pathUnderScope(repository.root, path);
						if (relative != null) path = relative;
					}
				tooltips.set(documentKey, path + "\n" + (diffDocument.reference == "HEAD→INDEX" ? "HEAD → Staged Changes" :
					diffDocument.reference == "INDEX→WORKTREE" ? "Staged Changes → Working Tree" :
					diffDocument.reference == "EMPTY→WORKTREE" ? "Empty → Working Tree" : diffDocument.reference));
			}
			if (diffDocument != null && !documentView.sideBySideDiff) {
				var parts = StringTools.replace(diffDocument.path, "\\", "/").split("/");
				var depth = 1;
				for (other in tabs) {
					if (other.diffDocument == null || other.diffDocument.path == diffDocument.path) continue;
					var otherParts = StringTools.replace(other.diffDocument.path, "\\", "/").split("/");
					var shared = 0;
					while (shared < parts.length && shared < otherParts.length &&
						parts[parts.length - 1 - shared] == otherParts[otherParts.length - 1 - shared]) shared++;
					if (shared > 0) depth = Std.int(Math.max(depth, shared + 1));
				}
				if (depth > 1) title = parts[parts.length - 1] + " — " + parts.slice(Std.int(Math.max(0, parts.length - depth)), parts.length - 1).join("/") + " (diff)";
			}
			var fileTab = new TabItem(documentKey, title + (documentView.preview ? " (preview)" : ""), content);
			fileTab.onClose = diffDocument != null ? function() host.closeTab(item, paneId, true) : function()
				application.files.requestCloseTab(host.documentsLostByClosingTab(item),
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
					var unsupported = UiEditorTabs.unsupportedFile(item);
					if (unsupported != null && UiEditorTabs.key(item) == key) { unsupported.preview = false; requestFrame(); }
					var image = UiEditorTabs.image(item);
					if (image != null && UiEditorTabs.key(item) == key) host.keepImage(image);
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
		return new EditorTabsView(widget, filenames, darkPalette, application.settings.current.tabTooltipDelay,
			tabColors, host.getResourceDecorations().revision, tooltips);
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
		if (host.isCommandViewActive()) host.closeCommandView();
		host.dismissLanguagePopup();
		var breadcrumbMenu:CommandMenu = null;
		breadcrumbMenu = new CommandMenu(application.commands, application.context, [], x, y,
			function() {
				var pane = host.paneById(paneId);
				if (pane == null) return false;
				var view = pane.activeView();
				return view != null && view.document == document;
			},
			function() { if (contextMenu == breadcrumbMenu) contextMenu = null; requestFrame(); }, items,
			menuOpenedWithKeyboard(event));
		contextMenu = breadcrumbMenu;
		requestFrame();
	}

	function showManageMenu(event:UiEvent):Void {
		if (manageMenu != null && contextMenu == manageMenu) {
			contextMenu = null;
			requestFrame();
			return;
		}
		var x = ActivityBar.WIDTH, y = viewportHeight - STATUS_HEIGHT - 8;
		if (ui.root != null) {
			ui.root.walk(function(node) {
				if (node.styleKey == "activity-manage" && node.resolved != null) {
					var bounds = node.globalBounds();
					x = bounds.x + bounds.width + 4;
					y = bounds.y + bounds.height;
				}
			});
		}
		var shortcut = function(id:String):Null<String> {
			var bindings = ui.commands.shortcutsFor(id);
			return bindings.length == 0 ? null : bindings[0].label();
		};
		var openPreferences = function(category:Null<String>, advanced:Bool):Void {
			openSettings();
			settingsPanel.setShowAdvanced(advanced);
			if (category != null) settingsPanel.select(category);
		};
		var actions = [
			new haxeon.ui.widgets.overlays.MenuItem("manage-palette", "Command Palette…", togglePalette,
				true, shortcut("view.toggle-palette")),
			new haxeon.ui.widgets.overlays.MenuItem("manage-settings", "Settings", openSettings,
				true, shortcut("preferences.open"), true),
			new haxeon.ui.widgets.overlays.MenuItem("manage-keyboard", "Keyboard Shortcuts",
				function() openPreferences("editor/keyboard", true)),
			new haxeon.ui.widgets.overlays.MenuItem("manage-themes", "Themes…",
				function() openPreferences("appearance/colors", true))
		];
		if (host.isCommandViewActive()) host.closeCommandView();
		host.dismissLanguagePopup();
		manageMenu = new CommandMenu(application.commands, application.context, [], x, y, function() return true,
			function() { contextMenu = null; requestFrame(); }, actions, menuOpenedWithKeyboard(event));
		contextMenu = manageMenu;
		requestFrame();
	}

	/** Context menus use viewport pointer coordinates; non-pointer requests anchor to the focused target. */
	function contextMenuAnchor(event:UiEvent):{x:Float, y:Float} {
		var anchor = {x: event.x, y: event.y};
		if (menuOpenedWithKeyboard(event) && ui.root != null) {
			var node = ui.root.find(event.target);
			if (node != null && node.resolved != null) {
				var bounds = node.globalBounds();
				anchor.x = bounds.x;
				anchor.y = bounds.y + bounds.height;
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TextField) {
					var caret = host.textInputArea();
					if (caret != null) { anchor.x = caret.x; anchor.y = caret.y + caret.height; }
				}
			}
		}
		return anchor;
	}

	function showContextMenu(entries:Array<CommandMenuEntry>, event:UiEvent, valid:Void->Bool):Void {
		var anchor = contextMenuAnchor(event);
		if (host.isCommandViewActive()) host.closeCommandView();
		host.dismissLanguagePopup();
		contextMenu = new CommandMenu(application.commands, application.context, entries, anchor.x, anchor.y, valid,
			function() { contextMenu = null; requestFrame(); }, null, menuOpenedWithKeyboard(event));
		requestFrame();
	}

	static function menuOpenedWithKeyboard(event:UiEvent):Bool {
		return event.kind == UiEventKind.KeyDown || event.kind == UiEventKind.KeyRepeat ||
			event.kind == UiEventKind.Activate;
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
		if (capabilities.supports(HostCapability.Filesystem)) {
			items.push(new KeyedView("open-workspace", new Button("Open Workspace…", null, application.savedWorkspaces.openPicker, "welcome-open-workspace")));
			items.push(new KeyedView("add-folder", new Button("Add Folder to Workspace…", null, application.savedWorkspaces.addPicker, "welcome-add-folder")));
			if (application.savedWorkspaces.roots().length > 0)
				items.push(new KeyedView("save-workspace", new Button("Save Workspace As…", null, application.savedWorkspaces.savePicker, "welcome-save-workspace")));
			for (index in 0...application.savedWorkspaces.recents.paths.length) {
				var file = application.savedWorkspaces.recents.paths[index];
				var available = FileSystem.exists(file);
				items.push(new KeyedView("workspace-recent-" + index, new Button(workspace.SavedWorkspace.nameFromPath(file) +
					(available ? "" : " (unavailable)"), null, function() application.savedWorkspaces.open(file), "welcome-workspace-recent-" + index)));
			}
		}
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
			var normalized = StringTools.replace(path, "\\", "/"), slash = normalized.lastIndexOf("/");
			if (slash > 0) {
				explorerRoot = normalized.substring(0, slash);
				openExplorer();
			}
		}
		application.openArgument(path);
		statusMessage = "Opened " + path;
	}

	function openFileDialog():Void {
		if (desktop == null) { application.workbench.openPathCommandView(false); requestFrame(); return; }
		desktop.openFile(function(accepted, paths) {
			if (accepted && paths.length > 0) application.openInBackground(paths[0]);
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
		application.workbench.openCommandView();
		requestFrame();
	}

	function paletteEntries():Array<commandview.CommandViewEntry> {
		// Include domain commands registered after startup (for example by plugins).
		CommandBridge.install(ui.commands, application.commands, application.keymap, application.context);
		var entries:Array<commandview.CommandViewEntry> = [];
		for (id in ui.commands.ids()) {
			var command = ui.commands.get(id);
			if (command == null || !command.isEnabled(ui.commandContext)) continue;
			var shortcuts = ui.commands.shortcutsFor(id);
			entries.push(new commandview.CommandViewEntry(command.label, "", id,
				[for (shortcut in shortcuts) shortcut.label()].join(", "), command.label + " " + id));
		}
		entries.sort(function(a, b) return Reflect.compare(a.label.toLowerCase(), b.label.toLowerCase()));
		return entries;
	}

	function clearExplorerModel():Void {
		explorerRename = null;
		renamedExplorerPath = null;
		if (explorerModel != null) explorerModel.dispose();
		explorerModel = null;
		explorerTree = null;
	}

	/** Select exactly the source owned by the active explorer root. */
	public function sourceControlSource():Null<ScmSource> {
		if (workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess()) {
			clearLocalScmSource();
			return workspaceAttachment.sourceControlSource();
		}
		if (!capabilities.supports(HostCapability.SourceControl) || explorerRoot == null) {
			clearLocalScmSource();
			return null;
		}
		var roots = [for (root in application.activeContext.roots) if (controller.SavedWorkspaceController.available(root)) root];
		if (roots.length == 0) { clearLocalScmSource(); return null; }
		if (localScmSource == null || localScmSource.identity() != LocalScmSource.identityFor(roots)) {
			clearLocalScmSource();
			localScmSource = new LocalScmSource(application.scm, roots[0], roots);
		}
		return localScmSource;
	}

	function syncScmSidebar():Void {
		var remoteRead = workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess()
			&& workspaceAttachment.sourceControlSource() != null;
		var enabled = capabilities.supports(HostCapability.SourceControl) || remoteRead;
		if (enabled && sidebar.find("scm") == null)
			registerSidebarDestination("scm", IconName.Hierarchy, sourceControlPanel,
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Source Control", 15, true));
		else if (!enabled && sidebar.find("scm") != null) {
			sidebar.unregister("scm");
			application.commands.remove("sidebar:scm");
			application.keymap.removeCommand("sidebar:scm");
		}
		if (enabled && application != null && !application.commands.contains("sidebar:scm")) {
			application.commands.add("sidebar:scm", function(_) { activateSidebarDestination("scm"); requestFrame(); });
			application.keymap.add(UiKey.G, UiModifier.Control | UiModifier.Shift, ["sidebar:scm"]);
		}
	}

	function sourceControlPanel():View {
		var source = sourceControlSource();
		if (source == null) {
			clearSourceControlPanel();
			return new Text(explorerRoot == null ? "Open a folder to view source control" : "Source control access is unavailable",
				null, theme.tokens.textSecondary, new TextStyleOverride(null, 13.0, null, haxeon.ui.TextWrap.WordCharacter));
		}
		if (sourceControlPanelValue == null || sourceControlPanelIdentity != source.identity()) {
			clearSourceControlPanel();
			sourceControlPanelIdentity = source.identity();
			sourceControlPanelValue = new SourceControlPanel(source, theme, function() {
				syncScmPresentation(source);
				requestFrame();
			}, function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
				openScmResource(source, repository, group, resource);
				requestFrame();
			}, showScmResourceMenu,
				function() { source.discover(_ -> requestFrame()); }, trustScmRepository,
			function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
				openScmSourceFile(source, repository, resource);
			}, function(repository, group, event) { showScmRepositoryMenu(source, repository, group, event); },
			function() return scmCommitRepository(source), function(repository) {
				var value = application.scmCommitDrafts.get(repository.id);
				return value == null ? "" : value;
			}, function(repository, value) {
				application.scmCommitDrafts.set(repository.id, value);
				requestFrame();
			}, function(repository, amend, all) {
				var value = application.scmCommitDrafts.get(repository.id);
				commitScmMessage(source, repository, value, amend, all);
			}, function(repository) return source.canWrite(repository.id) && hasStagedScmChanges(source, repository), function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
			if (resource != null && group != null) applyPendingScmFile(group.id != ScmGroupId.Index);
			else applyPendingScmGroup(group == null || group.id != ScmGroupId.Index);
			}, function(repository, event) showScmCommitMenu(source, repository, event));
			syncScmPresentation(source);
		}
		return sourceControlPanelValue;
	}

	function clearSourceControlPanel():Void {
		if (sourceControlPanelValue != null) sourceControlPanelValue.dispose();
		sourceControlPanelValue = null;
		sourceControlPanelIdentity = null;
	}

	function clearScmPresentation():Void {
		cancelScmBranchRequest();
		for (owner in [for (value in scmDecorationOwners.keys()) value]) host.getResourceDecorations().removeOwner(owner);
		scmDecorationOwners.clear(); scmDecorationRevisions.clear();
		scmPresentationSourceIdentity = null;
		host.getPluginStatusItems().removeOwner("scm");
		scmBranchStatus = null;
	}

	function syncScmPresentation(source:ScmSource):Void {
		if (source == null) return;
		var decorationRegistry = host.getResourceDecorations();
		var statusRegistry = host.getPluginStatusItems();
		var decorationRevisionBefore = decorationRegistry.revision;
		var statusRevisionBefore = statusRegistry.revision;
		if (scmPresentationSourceIdentity != null && scmPresentationSourceIdentity != source.identity()) clearScmPresentation();
		scmPresentationSourceIdentity = source.identity();
		var desired:Map<String, Bool> = [];
		var repositories = source.repositories();
		for (repository in repositories) {
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) continue;
			var owner = "scm:" + source.identity() + ":" + repository.id;
			desired.set(owner, true);
			var revision = haxe.Int64.toStr(snapshot.revision);
			if (scmDecorationRevisions.get(owner) == revision) continue;
			host.getResourceDecorations().removeOwner(owner);
			for (group in snapshot.groups) {
			for (resource in group.resources) {
				var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
				var path:String;
				if (source.isRemote()) {
					var scope = workspaceAttachment == null ? null : workspaceAttachment.fileScope();
					var repoRelative = scope == null ? null : pathUnderScope(scope, repository.root);
					if (repoRelative == null) continue;
					path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
				} else path = repository.root + "/" + relative;
				path = StringTools.replace(path, "\\", "/");
				var badge = scmStatusBadge(resource);
				var color = resource.conflictKind != null || resource.changeKind == scm.ScmChangeKind.Unmerged
					? plugin.PluginResourceDecorationColor.Danger
					: resource.changeKind == scm.ScmChangeKind.Added || resource.changeKind == scm.ScmChangeKind.Untracked
						? plugin.PluginResourceDecorationColor.Success
						: resource.changeKind == scm.ScmChangeKind.Deleted ? plugin.PluginResourceDecorationColor.Danger
						: resource.changeKind == scm.ScmChangeKind.Ignored ? plugin.PluginResourceDecorationColor.Secondary
						: plugin.PluginResourceDecorationColor.Warning;
				var priority = group.id == ScmGroupId.Merge ? 400 : group.id == ScmGroupId.Index ? 300 :
					group.id == ScmGroupId.WorkingTree ? 200 : group.id == ScmGroupId.Untracked ? 100 : 0;
				host.getResourceDecorations().add(owner, "resource:" + group.id + ":" + resource.pathBytes.length + ":" + resource.path,
					path, badge, color, "Source control · " + scmGroupLabel(group.id) + " · " + resource.path, true, priority);
			}
			}
			scmDecorationOwners.set(owner, true);
			scmDecorationRevisions.set(owner, revision);
		}
		for (owner in [for (owner in scmDecorationOwners.keys()) if (!desired.exists(owner)) owner]) {
			host.getResourceDecorations().removeOwner(owner);
			scmDecorationOwners.remove(owner); scmDecorationRevisions.remove(owner);
		}
		if (repositories.length == 0) {
			statusRegistry.removeOwner("scm"); scmBranchStatus = null;
			if (decorationRegistry.revision != decorationRevisionBefore || statusRegistry.revision != statusRevisionBefore) requestFrame();
			return;
		}
		var activeRepository = repositories[0], snapshot = source.snapshot(activeRepository.id);
		if (snapshot == null) return;
		var head = snapshot.head;
		var branch = head.branch != null ? head.branch : head.detachedCommit == null ? "No branch" : "detached " + head.detachedCommit.substr(0, 8);
		var text = branch;
		var tooltip = activeRepository.root + "\n" + text + (head.upstream == null ? "" : "\nUpstream: " + head.upstream)
			+ (head.operation == null ? "" : "\n" + Std.string(head.operation));
		var branchCommand = "scm:branches";
		var registry = statusRegistry;
		if (scmBranchStatus == null || registry.find("scm", "branch") == null)
			scmBranchStatus = registry.add("scm", "branch", text, 100, plugin.PluginStatusSide.Left,
				null, tooltip, branchCommand);
		else registry.update(scmBranchStatus, text, 100, plugin.PluginStatusSide.Left, null, tooltip, branchCommand);
		for (direction in ["ahead", "behind"]) {
			var count = direction == "ahead" ? head.ahead : head.behind;
			var id = "branch-" + direction;
			var item = registry.find("scm", id);
			if (count <= 0) {
				if (item != null) registry.remove(item);
				continue;
			}
			var icon = direction == "ahead" ? IconName.ArrowUp : IconName.ArrowDown;
			var priority = direction == "ahead" ? 99 : 98;
			var description = count + (count == 1 ? " commit " : " commits ") + direction
				+ (head.upstream == null ? "" : (direction == "ahead" ? " of " : " ") + head.upstream);
			if (item == null) registry.add("scm", id, Std.string(count), priority, plugin.PluginStatusSide.Left,
				icon, description, branchCommand);
			else registry.update(item, Std.string(count), priority, plugin.PluginStatusSide.Left,
				icon, description, branchCommand);
		}
		if (decorationRegistry.revision != decorationRevisionBefore || statusRegistry.revision != statusRevisionBefore) requestFrame();
	}

	function syncScmDocumentMarkers(now:Float):Void {
		var source = sourceControlSource();
		var desired:Map<Int, Bool> = [];
		if (source != null && !source.isRemote()) {
			var repositories = source.repositories();
			for (view in host.allViews()) {
				var document = view.document;
				if (view.diffDocument != null || document.path == null) continue;
				var repository:Null<scm.ScmRepository> = null, relative:Null<String> = null;
				for (candidate in repositories) {
					var candidatePath = scmRelativePath(candidate.root, document.path);
					if (candidatePath != null && (repository == null || candidate.root.length > repository.root.length)) {
						repository = candidate;
						relative = candidatePath;
					}
				}
				if (repository == null || relative == null || relative.length == 0) continue;
				var snapshot = source.snapshot(repository.id);
				if (snapshot == null) continue;
				var untracked = false, worktree = false;
				for (group in snapshot.groups) for (resource in group.resources) if (resource.path == relative) {
					if (group.id == ScmGroupId.Untracked) untracked = true;
					if (group.id == ScmGroupId.WorkingTree) worktree = true;
				}
				var identity = source.identity() + "|" + repository.id + "|" + relative;
				var previousIdentity = scmDocumentMarkerKeys.get(document.id);
				var tracker = scmDocumentMarkers.get(document.id);
				if (tracker != null && previousIdentity != identity) {
					tracker.dispose();
					scmDocumentMarkers.remove(document.id);
					scmDocumentMarkerKeys.remove(document.id);
					tracker = null;
				}
				if (tracker == null) {
					var documentId = document.id;
					tracker = new scm.ScmOpenDocumentMarkers(source, repository.id, haxe.io.Bytes.ofString(relative), document,
						"scm-open:" + documentId, host.getPluginGutterMarkers(), application.workspace.jobs,
						application.settings.current.scmDiffSizeLimit, requestFrame);
					scmDocumentMarkers.set(document.id, tracker);
					scmDocumentMarkerKeys.set(document.id, identity);
				}
				tracker.update(snapshot, document.dirty || worktree || untracked, untracked, now);
				desired.set(document.id, true);
			}
		}
		for (id in [for (id in scmDocumentMarkers.keys()) if (!desired.exists(id)) id]) {
			var tracker = scmDocumentMarkers.get(id);
			if (tracker != null) tracker.dispose();
			scmDocumentMarkers.remove(id);
			scmDocumentMarkerKeys.remove(id);
		}
	}

	function scmRelativePath(root:String, path:String):Null<String> {
		var base = StringTools.replace(application.workspace.fileSystem.normalize(root), "\\", "/");
		var full = StringTools.replace(application.workspace.fileSystem.normalize(path), "\\", "/");
		while (base.length > 1 && StringTools.endsWith(base, "/")) base = base.substr(0, base.length - 1);
		var compareBase = Sys.systemName() == "Windows" ? base.toLowerCase() : base;
		var compareFull = Sys.systemName() == "Windows" ? full.toLowerCase() : full;
		if (compareFull == compareBase) return "";
		var prefix = compareBase + "/";
		return StringTools.startsWith(compareFull, prefix) ? full.substring(prefix.length) : null;
	}

	static function scmStatusBadge(resource:scm.ScmResource):String {
		if (resource.conflictKind != null) return "!";
		return resource.changeKind == scm.ScmChangeKind.Added || resource.changeKind == scm.ScmChangeKind.Untracked ? "A" :
			resource.changeKind == scm.ScmChangeKind.Modified ? "M" : resource.changeKind == scm.ScmChangeKind.Deleted ? "D" :
			resource.changeKind == scm.ScmChangeKind.Renamed ? "R" : resource.changeKind == scm.ScmChangeKind.Copied ? "C" :
			resource.changeKind == scm.ScmChangeKind.TypeChanged ? "T" : resource.changeKind == scm.ScmChangeKind.Unmerged ? "!" :
			resource.changeKind == scm.ScmChangeKind.Ignored ? "I" : "?";
	}

	static function scmGroupLabel(group:ScmGroupId):String
		return group == ScmGroupId.Merge ? "Merge Changes" : group == ScmGroupId.Index ? "Staged Changes" :
			group == ScmGroupId.WorkingTree ? "Changes" : group == ScmGroupId.Untracked ? "Untracked" : Std.string(group);

	function trustScmRepository(repository:scm.ScmRepository):Void {
		var source = sourceControlSource();
		if (source == null || source.isRemote()) {
			application.reportError("source-control", "Trust this repository on the machine that runs Git");
			return;
		}
		source.trust(repository.id, function(result) {
			if (result.error != null || result.value != true)
				application.reportError("source-control", result.error == null ? "Could not trust repository" : result.error.message);
			else {
				source.refreshNow(repository.id);
				requestFrame();
			}
		});
	}

	function openScmResource(source:ScmSource, repository:scm.ScmRepository, group:scm.ScmGroup, resource:scm.ScmResource,
		sideBySide:Bool = false):Void {
		if (source == null || repository == null || group == null || resource == null) return;
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		if (group.id == ScmGroupId.Merge) {
			openScmWorktreeFile(source, repository, relative, function(path, contents, live) {
				if (source.isRemote()) openRemoteScmFile(repository, relative, -1);
				else if (path != null) application.open(path);
				closePhoneSidebarAfterOpen();
			});
			return;
		}
		var absolute = source.isRemote() ? null : repository.root + "/" + relative;
		var live = absolute == null ? null : findDocument(absolute);
		var snapshot = source.snapshot(repository.id);
		var revision = snapshot == null ? "" : haxe.Int64.toStr(snapshot.revision);
		var baseRef:scm.ScmRef = group.id == ScmGroupId.Index ? scm.ScmRef.Head : scm.ScmRef.Index;
		var refLabel = group.id == ScmGroupId.Index ? "HEAD→INDEX" : group.id == ScmGroupId.Untracked ? "EMPTY→WORKTREE" : "INDEX→WORKTREE";
		var open = function(oldText:String, newText:String):Void {
			var diffPath = absolute == null ? relative : absolute;
			if (sideBySide && !phoneLayoutActive) host.openScmSideBySide(repository.id, diffPath, refLabel, revision, oldText, newText, live);
			else host.openScmDiff(repository.id, diffPath, refLabel, revision, oldText, newText, live);
			closePhoneSidebarAfterOpen();
		};
		var loadCurrent = function(complete:String->Void):Void {
			if (group.id == ScmGroupId.Untracked) {
				openScmWorktreeFile(source, repository, relative, function(path, contents, _) {
					if (contents == null) reportScmReadError("Could not read untracked file " + resource.path);
					else open("", contents);
				});
				return;
			}
			if (group.id == ScmGroupId.Index) {
				readScmOriginal(source, repository.id, scm.ScmRef.Index, resource.pathBytes, function(contents, error) {
					if (error != null && error.code != "not_found" && error.code != "missing") reportScmReadError(error.message);
					else if (contents == null) open("", "");
					else open("", contents);
				});
				return;
			}
			openScmWorktreeFile(source, repository, relative, function(path, contents, live) {
				if (contents == null) reportScmReadError("Could not read changed file " + resource.path);
				else complete(contents);
			});
		};
		if (group.id == ScmGroupId.Index) {
			readScmOriginal(source, repository.id, baseRef, resource.pathBytes, function(base, error) {
				if (error != null && error.code != "not_found" && error.code != "missing") { reportScmReadError(error.message); return; }
				readScmOriginal(source, repository.id, scm.ScmRef.Index, resource.pathBytes, function(indexText, indexError) {
					if (indexError != null && indexError.code != "not_found" && indexError.code != "missing") { reportScmReadError(indexError.message); return; }
					open(base == null ? "" : base, indexText == null ? "" : indexText);
				});
			});
			return;
		}
		if (group.id == ScmGroupId.Untracked) { loadCurrent(function(_) {}); return; }
		readScmOriginal(source, repository.id, baseRef, resource.pathBytes, function(base, error) {
			if (error != null && error.code != "not_found" && error.code != "missing") { reportScmReadError(error.message); return; }
			loadCurrent(function(current) open(base == null ? "" : base, live != null ? live.buffer.text : current));
		});
	}

	function closePhoneSidebarAfterOpen():Void {
		if (phoneLayoutActive && sidebar.visible) sidebar.setVisible(false);
	}

	function readScmOriginal(source:ScmSource, repositoryId:String, reference:scm.ScmRef, path:haxe.io.Bytes,
		complete:Null<String>->Null<scm.ScmError>->Void):Void {
		source.originalBytes(repositoryId, reference, path, function(result) {
			if (result.error != null || result.value == null) { complete(null, result.error); return; }
			if (result.value.binary) { complete(null, new scm.ScmError("binary", "Binary files cannot be shown as text diffs")); return; }
			complete(result.value.bytes.toString(), null);
		});
	}

	function openScmWorktreeFile(source:ScmSource, repository:scm.ScmRepository, relative:String,
		complete:Null<String>->Null<String>->Null<editor.Document>->Void):Void {
		if (source.isRemote()) {
			var attachment = workspaceAttachment, client = attachment == null ? null : attachment.fileClient();
			var scope = attachment == null ? null : attachment.fileScope();
			if (attachment == null || client == null || scope == null) { complete(null, null, null); return; }
			var repoRelative = pathUnderScope(scope, repository.root);
			if (repoRelative == null) { complete(null, null, null); return; }
			var path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
			WorkspaceFileReader.read(client, attachment.fileWorkspace(), "root", path, null, function(result) {
				complete(null, result.error == null ? result.contents : null, null);
			});
			return;
		}
		var path = repository.root + "/" + relative;
		var live = findDocument(path);
		if (live != null && live.dirty) { complete(path, live.buffer.text, live); return; }
		if (!application.workspace.fileSystem.exists(path)) { complete(path, "", live); return; }
		try complete(path, application.workspace.fileSystem.read(path), live)
		catch (_:Dynamic) complete(path, null, live);
	}

	function findDocument(path:String):Null<editor.Document> {
		var normalized = StringTools.replace(application.workspace.fileSystem.normalize(path), "\\", "/");
		for (document in application.documents.documents) if (document.path != null &&
			StringTools.replace(application.workspace.fileSystem.normalize(document.path), "\\", "/") == normalized) return document;
		return null;
	}

	function openRemoteScmFile(repository:scm.ScmRepository, relative:String, line:Int):Void {
		var attachment = workspaceAttachment, client = attachment == null ? null : attachment.fileClient();
		var scope = attachment == null ? null : attachment.fileScope();
		if (attachment == null || client == null || scope == null) { reportScmReadError("Workspace file service is unavailable"); return; }
		var repoRelative = pathUnderScope(scope, repository.root);
		if (repoRelative == null) { reportScmReadError("Repository is outside the workspace file root"); return; }
		var path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
		var workspaceId = attachment.fileWorkspace();
		client.stat(workspaceId, "root", path, function(stat) {
			if (workspaceAttachment != attachment || stat == null || stat.entry == null || stat.entry.kind != "file") {
				reportScmReadError("The changed file is no longer available"); return;
			}
			var rootName = scope;
			var slash = rootName.lastIndexOf("/");
			if (slash >= 0) rootName = rootName.substring(slash + 1);
			openWorkspaceFileSnapshot(attachment, workspaceId, scope, "root", rootName, path, stat.entry.revision,
				WorkspaceFileReader.previewSize(stat.entry.size), false, null);
			if (line >= 0) {
				var existing = host.workspaceFile(scope, "root", path);
				if (existing != null) existing.selectSearchMatch(line, 0, 0);
			}
		}, function(error) reportScmReadError(error == null ? "Could not open changed workspace file" : error.message));
	}

	static function pathUnderScope(scope:String, root:String):Null<String> {
		var base = StringTools.replace(scope, "\\", "/"), full = StringTools.replace(root, "\\", "/");
		while (StringTools.endsWith(base, "/")) base = base.substr(0, base.length - 1);
		if (full == base) return "";
		var prefix = base + "/";
		if (!StringTools.startsWith(full, prefix)) return null;
		return full.substr(prefix.length);
	}

	function reportScmReadError(message:String):Void application.reportError("source-control", message);

	function rememberScmResource(source:Null<ScmSource>, repository:scm.ScmRepository, group:Null<scm.ScmGroup>,
		resource:Null<scm.ScmResource>):Void {
		pendingScmSource = source;
		pendingScmRepository = repository;
		pendingScmGroup = group;
		pendingScmResource = resource;
	}

	function showScmResourceMenu(repository:scm.ScmRepository, group:scm.ScmGroup, resource:scm.ScmResource, event:UiEvent):Void {
		rememberScmResource(sourceControlSource(), repository, group, resource);
		var entries = [
			new CommandMenuEntry("scm:open-changes", "Open Changes"),
			new CommandMenuEntry("scm:open-file", "Open File")
		];
		if (group.id != ScmGroupId.Merge)
			entries.push(new CommandMenuEntry("scm:open-side-by-side", "Compare Side by Side"));
		if (group.id == ScmGroupId.Merge && canResolvePendingScmConflict()) {
			entries.push(new CommandMenuEntry("scm:resolve-ours", "Accept Ours"));
			entries.push(new CommandMenuEntry("scm:resolve-theirs", "Accept Theirs"));
			entries.push(new CommandMenuEntry("scm:resolve-both", "Accept Both"));
		}
		if (canStagePendingScmFile()) entries.push(new CommandMenuEntry("scm:stage", group.id == ScmGroupId.Merge ? "Mark Resolved (Stage)" : "Stage File"));
		if (canUnstagePendingScmFile()) entries.push(new CommandMenuEntry("scm:unstage", "Unstage File"));
		if (canDiscardPendingScmFile()) entries.push(new CommandMenuEntry("scm:discard", "Discard Changes"));
		showContextMenu(entries, event, function() return true);
	}

	function showScmRepositoryMenu(source:ScmSource, repository:scm.ScmRepository, group:Null<scm.ScmGroup>, event:UiEvent):Void {
		rememberScmResource(source, repository, group, null);
		var entries:Array<CommandMenuEntry> = [];
		if (group == null && canCheckoutScmRepository(repository)) {
			entries.push(new CommandMenuEntry("scm:checkout-selected", "Switch Branch…"));
			entries.push(new CommandMenuEntry("scm:create-branch-selected", "Create Branch…"));
		}
		if (canStagePendingScmGroup()) entries.push(new CommandMenuEntry("scm:stage-all", group == null ? "Stage All Changes" : "Stage Group"));
		if (canUnstagePendingScmGroup()) entries.push(new CommandMenuEntry("scm:unstage-all", group == null ? "Unstage All Changes" : "Unstage Group"));
		if (group == null && source.canUseRemotes(repository.id)) {
			entries.push(new CommandMenuEntry("scm:fetch", "Fetch Remotes"));
			entries.push(new CommandMenuEntry("scm:pull", "Pull (Fast Forward Only)"));
			entries.push(new CommandMenuEntry("scm:push", "Push"));
		}
		if (entries.length == 0) return;
		showContextMenu(entries, event, function() return true);
	}

	function canCheckoutScmRepository(repository:Null<scm.ScmRepository>):Bool {
		var source = sourceControlSource();
		if (source == null) return false;
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null || !source.canWrite(target.id)) return false;
		var features = source.features(target.id);
		return features != null && features.branches;
	}

	function isScmSourceActive(identity:String):Bool {
		var source = sourceControlSource();
		return source != null && source.identity() == identity;
	}

	function cancelScmBranchRequest():Void {
		scmBranchRequestToken++;
		if (scmBranchJob != null) scmBranchJob.cancel();
		scmBranchJob = null;
	}

	function showScmBranchUnavailable(reason:String, label:String = "Branch switching unavailable"):Void {
		cancelScmBranchRequest();
		var entry = new commandview.CommandViewEntry(label, reason, "@unavailable");
		entry.enabled = false;
		host.openCommandView(new commandview.CommandViewProvider("Switch Branch: ", [entry], function(_) {}, function(_, _, _) {}, function() cancelScmBranchRequest()));
		requestFrame();
	}

	function openScmBranchPicker(repository:Null<scm.ScmRepository>):Void {
		var source = sourceControlSource();
		if (source == null) { showScmBranchUnavailable("No source control repository is available."); return; }
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null) { showScmBranchUnavailable("Repository discovery is still in progress."); return; }
		if (!source.connected()) { showScmBranchUnavailable("Reconnect the workspace to switch branches."); return; }
		var error = source.error(target.id);
		if (!canCheckoutScmRepository(target)) {
			var features = source.features(target.id);
			showScmBranchUnavailable(error != null ? error.message : !target.trusted ? "Trust this repository before switching branches." :
				features == null ? "Repository capabilities are still loading." : !features.branches ? "This source control provider does not support branch switching." :
				"Branch switching is unavailable with the current repository permissions.");
			return;
		}
		var selectedRepository:scm.ScmRepository = cast target;
		showScmBranchUnavailable("Reading repository branches.", "Loading branches…");
		var token = scmBranchRequestToken;
		var identity = source.identity();
		requestFrame();
		var job = source.branches(selectedRepository.id, function(result) {
			if (token != scmBranchRequestToken || !isScmSourceActive(identity)) return;
			scmBranchJob = null;
			if (result.error != null) {
				showScmBranchUnavailable(result.error.message);
				requestFrame();
				return;
			}
			showScmBranchPicker(source, selectedRepository, result.value == null ? [] : result.value);
		});
		if (!job.complete && !job.cancelled) scmBranchJob = job;
	}

	function showScmBranchPicker(source:ScmSource, repository:scm.ScmRepository, branches:Array<scm.ScmBranch>):Void {
		var entries:Array<commandview.CommandViewEntry> = [
			new commandview.CommandViewEntry("Create Branch…", "Create a branch from the current HEAD", "@create", null,
				"create branch new", "Actions"),
			new commandview.CommandViewEntry("Open Source Control", "Show repository changes", "@source-control", null,
				"open changes repository source control", "Actions")
		];
		for (branch in branches) {
			var section = branch.remote ? "Remote Branches" : "Local Branches";
			var detail = branch.current ? "Current branch" : branch.remote ? "Remote branch" : "Local branch";
			entries.push(new commandview.CommandViewEntry(branch.name, detail, branch.reference, null,
				branch.name + " " + branch.reference + " " + detail, section));
		}
		var valid = function() return isScmSourceActive(source.identity())
			&& canCheckoutScmRepository(repository);
		host.openCommandView(new commandview.CommandViewProvider("Switch Branch: ", entries, function(_) {}, function(entry, _, _) {
			if (!valid()) { host.closeCommandView(); return; }
			host.closeCommandView();
			if (entry == null) return;
			if (entry.value == "@create") openScmCreateBranchPrompt(repository);
			else if (entry.value == "@source-control") activateSidebarDestination("scm");
			else checkoutScmBranch(source, repository, entry.value);
		}, function() cancelScmBranchRequest()));
	}

	function openScmCreateBranchPrompt(repository:Null<scm.ScmRepository>):Void {
		var source = sourceControlSource();
		if (source == null) return;
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null || !canCheckoutScmRepository(target)) return;
		var selectedRepository:scm.ScmRepository = cast target;
		var identity = source.identity();
		var selected = selectedRepository;
		host.openCommandView(new commandview.CommandViewProvider("New Branch: ", [], function(_) {}, function(_, name, _) {
			host.closeCommandView();
			if (!isScmSourceActive(identity)) return;
			createScmBranch(source, selected, name);
		}, function() {}));
	}

	function checkoutScmBranch(source:ScmSource, repository:scm.ScmRepository, reference:String):Void {
		applyScmBranchOperation(source, repository, scm.ScmOperation.Checkout(reference), "Switched branch");
	}

	function createScmBranch(source:ScmSource, repository:scm.ScmRepository, name:String):Void {
		var branch = StringTools.trim(name);
		if (branch.length == 0) {
			application.reportError("source-control", "Enter a branch name");
			return;
		}
		applyScmBranchOperation(source, repository, scm.ScmOperation.CreateBranch(branch), "Created branch " + branch);
	}

	function applyScmBranchOperation(source:ScmSource, repository:scm.ScmRepository, operation:scm.ScmOperation, label:String):Void {
		if (!isScmSourceActive(source.identity()) || !canCheckoutScmRepository(repository)) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) {
			application.reportError("source-control", "Refresh the repository before changing branches");
			return;
		}
		host.getNotifications().publish(label + " in progress…", feedback.NotificationKind.Information, "source-control");
		var operationId = "ui-" + Std.string(nextScmOperationId++);
		source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
			if (result.error != null) {
				host.getNotifications().publish("Branch operation failed: " + result.error.message,
					feedback.NotificationKind.Error, "source-control");
				application.reportError("source-control", result.error.message);
			} else {
				host.getNotifications().publish(label, feedback.NotificationKind.Information, "source-control");
				source.refreshNow(repository.id);
			}
			requestFrame();
		});
	}

	function canUsePendingScmRemotes():Bool {
		var source = pendingScmSource, repository = pendingScmRepository;
		if (source == null || repository == null || !source.canUseRemotes(repository.id)) return false;
		var features = source.features(repository.id);
		return features != null && features.remotes;
	}

	function applyPendingScmRemote(operation:scm.ScmOperation):Void {
		if (!canUsePendingScmRemotes()) return;
		var source = pendingScmSource, repository = pendingScmRepository;
		if (source == null || repository == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) {
			application.reportError("source-control", "Refresh the repository before running a Git remote operation");
			return;
		}
		function start():Void {
			var label = switch operation {
				case Fetch(_): "Fetch";
				case Pull: "Pull";
				case Push: "Push";
				case _: "Git remote operation";
			};
			host.getNotifications().publish(label + " in progress…", feedback.NotificationKind.Information, "source-control");
			var operationId = "ui-" + Std.string(nextScmOperationId++);
			switch operation {
				case Fetch(_): scmAutoFetchLast.set(source.identity() + "\n" + repository.id, Sys.time());
				case _:
			}
			source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
				if (result.error != null) {
					host.getNotifications().publish(label + " failed: " + result.error.message,
						feedback.NotificationKind.Error, "source-control");
					application.reportError("source-control", result.error.message);
				} else {
					host.getNotifications().publish(label + " completed", feedback.NotificationKind.Information, "source-control");
					source.refreshNow(repository.id);
				}
				requestFrame();
			});
		}
		var isInitialPush = switch operation {
			case Push: snapshot.head.upstream == null;
			case _: false;
		};
		if (isInitialPush) {
			application.confirmations.choose('Push the current branch to origin and set its upstream?', ["push", "cancel"], function(answer) {
				if (answer == "push") start();
			});
		} else start();
	}

	function maybeAutoFetchScm(source:ScmSource, now:Float):Void {
		if (!application.settings.current.scmAutoFetch || !source.connected()) return;
		for (repository in source.repositories()) {
			if (!source.canUseRemotes(repository.id)) continue;
			var features = source.features(repository.id);
			if (features == null || !features.remotes) continue;
			var key = source.identity() + "\n" + repository.id;
			if (scmAutoFetchPending.exists(key)) continue;
			var last = scmAutoFetchLast.get(key);
			if (last == null) { scmAutoFetchLast.set(key, now); continue; }
			if (now - last < 300.0) continue;
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) continue;
			scmAutoFetchLast.set(key, now);
			scmAutoFetchPending.set(key, true);
			var operationId = "auto-fetch-" + Std.string(nextScmOperationId++);
			source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.Fetch(null), function(result) {
				scmAutoFetchPending.remove(key);
				if (result.error != null) {
					host.getNotifications().publish("Automatic fetch failed: " + result.error.message,
						feedback.NotificationKind.Warning, "source-control");
					application.reportError("source-control", result.error.message);
				} else source.refreshNow(repository.id);
				requestFrame();
			});
		}
	}

	function canStagePendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked || group.id == ScmGroupId.Merge);
	}

	function canResolvePendingScmConflict():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null || group.id != ScmGroupId.Merge
			|| !source.canWrite(repository.id)) return false;
		var features = source.features(repository.id);
		return features != null && features.staging;
	}

	function applyPendingScmConflict(choice:String):Void {
		if (!canResolvePendingScmConflict()) return;
		var source = pendingScmSource, repository = pendingScmRepository, resource = pendingScmResource;
		if (source == null || repository == null || resource == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { application.reportError("source-control", "Refresh the repository before resolving conflicts"); return; }
		host.getNotifications().publish("Resolving conflict in " + resource.path + "…", feedback.NotificationKind.Information, "source-control");
		var operationId = "ui-" + Std.string(nextScmOperationId++);
		source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.ResolveConflict(resource.path, choice), function(result) {
			if (result.error != null) {
				host.getNotifications().publish("Conflict resolution failed: " + result.error.message,
					feedback.NotificationKind.Error, "source-control");
				application.reportError("source-control", result.error.message);
			} else {
				host.getNotifications().publish("Resolved " + resource.path + " using " + choice,
					feedback.NotificationKind.Information, "source-control");
				source.refreshNow(repository.id);
			}
			requestFrame();
		});
	}

	function canTrustPendingScmRepository():Bool {
		var source = pendingScmSource, repository = pendingScmRepository;
		return source != null && repository != null && !source.isRemote() && !repository.trusted;
	}

	function refreshSourceControl():Void {
		var source = sourceControlSource();
		if (source == null) return;
		source.poll();
		for (repository in source.repositories()) source.refreshNow(repository.id);
		source.discover(function(result) {
			if (result.error != null) application.reportError("source-control", result.error.message);
			else for (repository in result.value) source.refreshNow(repository.id);
			source.poll();
			syncScmPresentation(source);
			requestFrame();
		});
	}

	function canUnstagePendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& group.id == ScmGroupId.Index;
	}

	function canDiscardPendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked);
	}

	function discardPendingScmFile():Void {
		if (!canDiscardPendingScmFile()) return;
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { application.reportError("source-control", "Refresh the repository before discarding changes"); return; }
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		var path = repository.root + "/" + StringTools.replace(relative, "\\", "/");
		var dirty = [for (document in application.documents.documents)
			if (document.dirty && document.hasBackingPath() && sameScmPath(document.requirePath(), path)) document];
		function confirmDiscard(reloadBuffers:Bool):Void {
			application.confirmations.choose("Discard changes to 1 file?",
				["discard", "cancel"], function(answer) {
					if (answer != "discard") return;
					if (group.id == ScmGroupId.Untracked && !source.isRemote()) {
						var removed = application.fileOperations.remove(path);
						if (!removed.success) { application.reportError("source-control", removed.detail); return; }
						application.workspace.refreshProjects();
						source.refreshNow(repository.id);
						var trashPath = removed.destination;
						host.getNotifications().publish("Moved " + relative + " to recoverable trash", feedback.NotificationKind.Information,
							"source-control", [new feedback.NotificationAction("Undo", function() {
								if (trashPath == null || application.workspace.fileSystem.exists(path)
									|| !application.workspace.fileSystem.rename(trashPath, path)) {
								application.reportError("source-control", "Could not restore " + relative + " from trash");
								return;
							}
							application.workspace.refreshProjects();
							source.refreshNow(repository.id);
							requestFrame();
							})]);
						if (reloadBuffers) for (document in dirty) document.reloadFromDisk();
						requestFrame();
						return;
					}
					var operationId = "ui-" + Std.string(nextScmOperationId++);
					source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.Discard(relative), function(result) {
						if (result.error != null) { application.reportError("source-control", result.error.message); return; }
						source.refreshNow(repository.id);
						if (reloadBuffers) for (document in dirty) document.reloadFromDisk();
						var token = result.value == null ? null : result.value.recoveryToken;
						if (token != null) host.getNotifications().publish("Discarded changes to " + relative,
							feedback.NotificationKind.Information, "source-control", [new feedback.NotificationAction("Undo", function() {
								var latest = source.snapshot(repository.id);
								if (latest == null) { application.reportError("source-control", "Refresh before undoing the discard"); return; }
								var undoId = "ui-" + Std.string(nextScmOperationId++);
								source.apply(repository.id, undoId, latest.revision, scm.ScmOperation.RestoreDiscard(relative, token), function(undo) {
									if (undo.error != null) application.reportError("source-control", undo.error.message);
									else source.refreshNow(repository.id);
									requestFrame();
								});
							})]);
						requestFrame();
					});
				});
		}
		if (dirty.length > 0) {
			application.confirmations.choose('An open buffer has unsaved edits. Choose reload after discard or keep the buffer: ',
				["reload", "keep", "cancel"], function(choice) {
					if (choice == "reload") confirmDiscard(true);
					else if (choice == "keep") confirmDiscard(false);
				});
		} else confirmDiscard(false);
	}

	static function sameScmPath(left:String, right:String):Bool {
		var a = StringTools.replace(left, "\\", "/"), b = StringTools.replace(right, "\\", "/");
		return Sys.systemName() == "Windows" ? a.toLowerCase() == b.toLowerCase() : a == b;
	}

	function canStagePendingScmGroup():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		if (group == null) return hasScmResources(snapshot, [ScmGroupId.WorkingTree, ScmGroupId.Untracked]);
		return (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked) && group.resources.length > 0;
	}

	function canUnstagePendingScmGroup():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		if (group == null) return hasScmResources(snapshot, [ScmGroupId.Index]);
		return group.id == ScmGroupId.Index && group.resources.length > 0;
	}

	static function hasScmResources(snapshot:scm.ScmSnapshot, ids:Array<ScmGroupId>):Bool {
		for (group in snapshot.groups) if (ids.indexOf(group.id) >= 0 && group.resources.length > 0) return true;
		return false;
	}

	function applyPendingScmGroup(stage:Bool):Void {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || (stage ? !canStagePendingScmGroup() : !canUnstagePendingScmGroup())) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return;
		if (group == null) {
			var operation = stage ? scm.ScmOperation.StageAll : scm.ScmOperation.UnstageAll;
			applyScmOperation(source, repository, snapshot, operation);
			return;
		}
		var paths = [for (resource in group.resources) resource.pathBytes.getString(0, resource.pathBytes.length)];
		var operation = stage ? scm.ScmOperation.StagePaths(paths) : scm.ScmOperation.UnstagePaths(paths);
		applyScmOperation(source, repository, snapshot, operation);
	}

	function applyScmOperation(source:ScmSource, repository:scm.ScmRepository, snapshot:scm.ScmSnapshot,
		operation:scm.ScmOperation):Void {
		var operationId = "ui-" + Std.string(nextScmOperationId++);
		source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
			if (result.error != null) application.reportError("source-control", result.error.message);
			source.refreshNow(repository.id);
			requestFrame();
		});
	}

	function scmCommitRepository(source:ScmSource):Null<scm.ScmRepository> {
		if (source == null) return null;
		if (pendingScmSource != null && pendingScmSource.identity() == source.identity() && pendingScmRepository != null)
			return pendingScmRepository;
		var repositories = source.repositories();
		return repositories.length == 0 ? null : repositories[0];
	}

	function hasStagedScmChanges(source:ScmSource, repository:scm.ScmRepository):Bool {
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		for (group in snapshot.groups)
			if (group.id == ScmGroupId.Index && group.resources.length > 0) return true;
		return false;
	}

	function canCommitStagedCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		return source != null && repository != null && source.canWrite(repository.id) && hasStagedScmChanges(source, repository)
			&& canCommitCurrentScmRepository();
	}

	function canAmendCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		if (source == null || repository == null || !source.canWrite(repository.id) || !canCommitCurrentScmRepository()) return false;
		var features = source.features(repository.id);
		return features != null && features.amend;
	}

	function canCommitAllCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		return application.settings.current.scmCommitAllWhenNothingStaged && source != null && repository != null
			&& source.canWrite(repository.id) && !hasStagedScmChanges(source, repository) && canCommitCurrentScmRepository();
	}

	function showScmCommitMenu(source:ScmSource, repository:scm.ScmRepository, event:UiEvent):Void {
		rememberScmResource(source, repository, null, null);
		var entries:Array<CommandMenuEntry> = [];
		if (hasStagedScmChanges(source, repository)) entries.push(new CommandMenuEntry("scm:commit", "Commit Staged"));
		var features = source.features(repository.id);
		if (features != null && features.amend) entries.push(new CommandMenuEntry("scm:commit-amend", "Amend Last Commit"));
		if (application.settings.current.scmCommitAllWhenNothingStaged && !hasStagedScmChanges(source, repository))
			entries.push(new CommandMenuEntry("scm:commit-all", "Commit All Changes"));
		if (entries.length == 0) return;
		showContextMenu(entries, event, function() return isScmSourceActive(source.identity()) && source.canWrite(repository.id));
	}

	function canCommitCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var message = application.scmCommitDrafts.get(repository.id);
		return message != null && StringTools.trim(message).length > 0;
	}

	function commitScmMessage(source:ScmSource, repository:scm.ScmRepository, message:Null<String>, amend:Bool, all:Bool):Void {
		if (source == null || repository == null || !source.canWrite(repository.id)) return;
		var commitMessage = message == null ? "" : message;
		if (StringTools.trim(commitMessage).length == 0) return;
		if (amend) {
			var features = source.features(repository.id);
			if (features == null || !features.amend) return;
		}
		function beginCommit():Void {
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) { application.reportError("source-control", "Refresh the repository before committing"); return; }
			function commitWithSnapshot(expected:scm.ScmSnapshot):Void {
				var operationId = "ui-" + Std.string(nextScmOperationId++);
				source.apply(repository.id, operationId, expected.revision, scm.ScmOperation.Commit(commitMessage, amend), function(result) {
					if (result.error != null) {
						application.build.output.reset(repository.root);
						application.build.output.append("Git commit failed\n" + result.error.message + "\n");
						application.build.output.finish();
						host.showBuildOutput("Source Control Commit", application.build.output);
						application.reportError("source-control", result.error.message);
						return;
					}
					application.scmCommitDrafts.set(repository.id, "");
					source.refreshNow(repository.id);
					host.getNotifications().publish(amend ? "Commit amended" : "Commit created",
						feedback.NotificationKind.Information, "source-control");
					requestFrame();
				});
			}
			if (!all) { commitWithSnapshot(snapshot); return; }
			var stageId = "ui-" + Std.string(nextScmOperationId++);
			source.apply(repository.id, stageId, snapshot.revision, scm.ScmOperation.StageAll, function(staged) {
				if (staged.error != null) { application.reportError("source-control", staged.error.message); return; }
				var refreshed = source.snapshot(repository.id);
				commitWithSnapshot(refreshed == null ? snapshot : refreshed);
			});
		}
		var dirtyDocuments = [for (document in application.documents.documents) if (document.dirty) document];
		if (dirtyDocuments.length == 0) { beginCommit(); return; }
		application.confirmations.choose('There are ' + dirtyDocuments.length + ' unsaved document(s). Save All before committing? ',
			["save-all", "commit-without-saving", "cancel"], function(answer) {
				if (answer == "save-all") application.files.saveAll(function(saved) {
					if (saved) beginCommit();
					else application.reportError("source-control", "Save All did not complete; commit cancelled");
				});
				else if (answer == "commit-without-saving") beginCommit();
			});
	}

	function applyPendingScmFile(stage:Bool):Void {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null
			|| (stage ? !canStagePendingScmFile() : !canUnstagePendingScmFile())) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { application.reportError("source-control", "Refresh the repository before changing its index"); return; }
		var path = resource.pathBytes.getString(0, resource.pathBytes.length);
		var operation = stage ? scm.ScmOperation.Stage(path) : scm.ScmOperation.Unstage(path);
		applyScmOperation(source, repository, snapshot, operation);
	}

	function openPendingScmFile():Void {
		var source = pendingScmSource;
		if (source == null) return;
		var repository = pendingScmRepository;
		if (repository == null) return;
		var resource = pendingScmResource;
		if (resource == null) return;
		openScmSourceFile(source, repository, resource);
	}

	function openScmSourceFile(source:ScmSource, repository:scm.ScmRepository, resource:scm.ScmResource):Void {
		if (source == null || repository == null || resource == null) return;
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		if (source.isRemote()) openRemoteScmFile(repository, relative, -1);
		else application.open(repository.root + "/" + relative);
		closePhoneSidebarAfterOpen();
	}

	function activeDiffView():Null<UiDocumentView> {
		var view = host.activeView();
		return view != null && view.diffDocument != null && !view.sideBySideDiff ? view : null;
	}

	function canApplyActiveScmHunk(action:String):Bool {
		var source = sourceControlSource(), view = host.activeView();
		if (source == null || view == null) return false;
		if (view.diffDocument != null) {
			if (view.sideBySideDiff) return false;
			var diff = view.diffDocument, repository = source.repository(diff.repositoryId);
			if (repository == null || !source.canWrite(repository.id)) return false;
			var features = source.features(repository.id), snapshot = source.snapshot(repository.id);
			if (features == null || !features.partialStaging || snapshot == null) return false;
			var staged = diff.reference == "HEAD→INDEX";
			if (action == "unstage" ? !staged : staged ||
				(diff.reference != "INDEX→WORKTREE" && diff.reference != "EMPTY→WORKTREE")) return false;
			var relative = source.isRemote() ? diff.path : pathUnderScope(repository.root, diff.path);
			var hunk = diff.hunkIndexAtLine(view.selection.cursor.line);
			return relative != null && hunk >= 0 && diff.patchForHunk(hunk, haxe.io.Bytes.ofString(relative)) != null;
		}
		if (action == "unstage") return false;
		var tracker = scmDocumentMarkers.get(view.document.id);
		if (tracker == null) return false;
		var repository = source.repository(tracker.getRepositoryId()), features = repository == null ? null : source.features(tracker.getRepositoryId());
		return repository != null && source.canWrite(repository.id) && features != null && features.partialStaging
			&& source.snapshot(repository.id) != null && tracker.patchForLine(view.selection.cursor.line) != null;
	}

	function applyActiveScmHunk(action:String):Void {
		if (!canApplyActiveScmHunk(action)) return;
		var source = sourceControlSource(), view = host.activeView();
		if (source == null || view == null) return;
		var repository:Null<scm.ScmRepository> = null, pathBytes:haxe.io.Bytes = null, patch:haxe.io.Bytes = null;
		if (view.diffDocument != null) {
			var diff = view.diffDocument;
			repository = source.repository(diff.repositoryId);
			if (repository == null) return;
			var relative = source.isRemote() ? diff.path : pathUnderScope(repository.root, diff.path);
			if (relative == null) return;
			pathBytes = haxe.io.Bytes.ofString(relative);
			patch = diff.patchForHunk(diff.hunkIndexAtLine(view.selection.cursor.line), pathBytes);
		} else {
			var tracker = scmDocumentMarkers.get(view.document.id);
			if (tracker == null) return;
			repository = source.repository(tracker.getRepositoryId());
			pathBytes = tracker.getPathBytes();
			patch = tracker.patchForLine(view.selection.cursor.line);
		}
		if (repository == null || pathBytes == null || patch == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return;
		var relativePath = pathBytes.toString();
		var operation:scm.ScmOperation = action == "stage" ? scm.ScmOperation.StagePatch(relativePath, patch) :
			action == "unstage" ? scm.ScmOperation.UnstagePatch(relativePath, patch) : scm.ScmOperation.RevertPatch(relativePath, patch);
		applyScmOperation(source, repository, snapshot, operation);
	}

	function openActiveDiffSourceAtLine():Void {
		var view = activeDiffView(), diff = view == null ? null : view.diffDocument;
		if (view == null || diff == null) return;
		var source = sourceControlSource();
		if (source != null && source.isRemote()) {
			var repository = source.repository(diff.repositoryId);
			if (repository != null) openRemoteScmFile(repository, diff.path, diff.sourceLine(view.selection.cursor.line));
		} else host.openDiffSourceAtLine();
	}

	function clearLocalScmSource():Void {
		if (localScmSource == null) return;
		cancelScmBranchRequest();
		localScmSource.dispose();
		localScmSource = null;
	}

	static function normalizedLocalRoot(path:String):String {
		var value = StringTools.replace(FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return Sys.systemName() == "Windows" ? value.toLowerCase() : value;
	}

	/** Invalidate application views as well as scheduling a host render. */
	public function requestFrame():Void {
		viewRevision++;
		if (hostContext != null) hostContext.requestFrame();
	}
}
