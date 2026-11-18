package ui;

import haxeon.ui.widgets.overlays.TooltipOverlayHost;

import haxeon.ui.widgets.overlays.TooltipPlacement;
import haxeon.ui.widgets.overlays.MenuItem;

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
import haxeon.ui.component.TrackedScope;
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
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.event.EventSubscription;
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
import editor.BufferPosition;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;
import workspace.PathKey;
import controller.WorkspaceFileSearchController;
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
@:allow(ui.WorkbenchActions, ui.ExohostWorkbenchMachine, ui.ScmPanelController, ui.AgentTabs, ui.TerminalTabs, ui.RemoteFileTabs, ui.ExosuitDiagnostics, ui.ExplorerPanelController, ui.ServedFolders, ui.SettingsTab, ui.ResponsiveLayout, ui.ContextSwitching, ui.DeviceWorkbenchMachine)
class ExosuitApp implements DesktopUiApplication {
	public final ui:UiContext;

	/** Let go of every retained UI tree before a guarded live patch: the context's, and the nodes session panels keep. */
	public function releaseRetained():Void {
		for (pane in host.panes) for (item in pane.items) {
			var agent = UiEditorTabs.agent(item);
			if (agent != null) agent.panel.releaseRetained();
		}
		if (scopedSearch != null) scopedSearch.releaseRetained();
		ui.releaseRetained();
	}
	public final theme:Theme;
	var darkPalette:Bool;
	final editorPalette:style.Theme;
	final terminalPalette:TerminalPalette;
	public final application:Application;
	public final capabilities:HostCapabilities;
	public final host:UiWorkbenchHost;
	final desktop:Null<HostFileDialogs>;
	/** The client the Workbench shows the window's workspace through. */
	public var workbenchClient(default, null):Null<workspace.client.WorkspaceWorkbenchClient>;
	var remoteAccessPanel:Null<RemoteAccessPanel>;
	var machineClient:Null<workspace.client.MachineClient>;
	/** The desktop's Workbench machine: exohost's list of this machine's workspaces and the window's links to them. */
	var exohostWorkbench:Null<ExohostWorkbenchMachine>;
	/** What the Workbench's rows do to workspaces, on the machine the window is given (exohost's, or a device's paired one). */
	final workbenchActions:WorkbenchActions;
	/** The Source Control view, the Changes tab and the editor's and sessions' source control. */
	final sourceControl:ScmPanelController;
	/** Agent session tabs and creating sessions. */
	public final agentTabs:AgentTabs;
	/** Terminal tabs, in the editor and the bottom panel. */
	public final terminalTabs:TerminalTabs;
	/** Tabs of files read through a workspace's service. */
	final remoteFileTabs:RemoteFileTabs;
	/** The automation state and diagnostic snapshot programs read. */
	public final diagnostics:ExosuitDiagnostics;
	/** The Files view. */
	final explorer:ExplorerPanelController;
	/** The folders the workspace service serves. */
	final servedFolders:ServedFolders;
	/** The Settings tab. */
	public final settingsTab:SettingsTab;
	/** How the dock follows the window's width. */
	final responsive:ResponsiveLayout;
	/** Moving the window between workspaces and groups. */
	public final contexts:ContextSwitching;
	/** The context last told to exohost over the window's link, so other windows can mark it (M19 Phase 8). */
	var presenceRevision = -1;
	var presenceWorkspace:Null<String>;
	var presenceMachine:Null<String>;
	var machineClientRevision = -1;
	/** The folder this window last asked exohost to open as a workspace (`openFolderWorkspace`); it is asked once. */
	var folderOpening:Null<String>;
	/** A quit exohost asked for over the link: its answer, and whether it keeps unsaved work for the next start. */
	var quitAnswer:Null<(Null<Dynamic>, Null<exohost.control.ControlError>) -> Void>;
	var quitRecovering = false;
	/**
		The window's links, one per workspace in use (desktop): the one it shows (`focus`), the running workspaces whose
		rows are expanded, the workspaces with terminals here. A switch moves the focus between links that stay connected.
	**/
	var links:Null<workspace.client.WorkspaceLinks>;
	var focus:Null<workspace.client.WorkspaceLink>;
	/** The catalogs idle workspaces had when their services last ran: their rows, with nothing started. */
	var snapshots:Null<workspace.client.CatalogSnapshots>;
	/** The terminal list revision last applied to the tabs, by the workspace root of the link that read it. */
	final terminalNameRevisions:Map<String, Int> = [];
	var workbenchPanel:Null<WorkbenchPanel>;
	/** The catalog instance that last had a group (the Agents layout stays while that workspace is open). */
	var agentsLayoutInstance:String = "";
	/** Group ids the last complete catalog of `knownGroupsInstance` listed; a focused group that left it was removed. */
	var knownGroupsInstance:String = "";
	final knownGroups:Map<String, Bool> = [];

 var agentRevision=-1;
	var agentAttach:Null<AgentAttachPanel>;
	var workspaceAttachment:Null<workspace.client.WorkspaceAttachment>;
	var searchFileClient:Null<workspace.client.WorkspaceFileClient>;
	var remoteFileSearch:WorkspaceFileSearchController;
	var pendingWorkspaceFolderReveal:Null<String>;
	var workspaceStatus:String = "";
	/** Frames rendered per second, shown in the title bar. Made on first use, so a live patch that adds it needs no initializer. */
	var frameRate:Null<FrameRateMeter>;
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
	var scmFocusSubscription:Null<EventSubscription>;
	final dock:DockWorkspaceModel;
	final layoutControls:WorkbenchLayoutControls;
	final layoutModes:WorkbenchLayoutModes;
	final activityMenu:ActivityBarMenu;
	final activityRail:ActivityRailPreference;
	var contextFiles:Null<ContextFilesView>;
	/** The Workbench group the Agents layout's right panel works in; it stays when the selection has no folder. */
	var agentScopes:Null<AgentScopeTracker>;
	var contextTab:ContextPanelTab = ContextPanelTab.Files;
	var scopedSearch:Null<ScopedSearchPanel>;
	var contextLayoutsReady:Bool = false;
	var dockPanelContents:Array<DockPanelContent>;
	final editorPanes:Map<Int, EditorPane> = new Map();
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
	final scmBranches:ScmBranchController;
	public var gutterMarkerClickHandler:Null<plugin.PluginGutterMarker->Void>;
	final workspaceFileLoader = new WorkspaceFileLoader();
	final workspaceFileRefreshPending:Map<String, Bool> = new Map();
	final tabClicks = new haxeon.ui.core.PointerClickSequence();
	var statusMessage:String = "Ready";
	var explorerReturnPath:Null<String>;
	var zoomOverlayUntil:Float = 0.0;
	var settingsPanel:Null<haxeon.ui.widgets.settings.SettingsPanel>;
	var settingsClosePending:Bool = false;
	var closingSettingsTab:Null<UiSettingsTab>;
	var contextMenu:Null<CommandMenu> = null;
	var manageMenu:Null<CommandMenu> = null;
	var layoutMenu:Null<CommandMenu> = null;
	/**
		The root build's own invalidation: `view` reads it first, `requestFrame` and the change detector bump it. Exosuit's
		state is mostly plain fields that a build cannot track, so a change to it asks for a full build through this signal.
	**/
	final frameTick = new haxeon.reactive.Signal<Int>(0);
	/** The plain values the root build shows, compared before each frame (see submit). */
	final rootChanges = new RootChangeDetector();
	/** `view` as one closure for every frame: the cached submission reuses an idle frame only with the same build callback. */
	final viewBuilder:Void->View;
	/** The problems revision the Problems tab's badge counts; the count is taken again only when it moves. */
	var badgedProblems:Int = -1;
	/** Whether a frame was built yet; a repaint-only frame before the first one builds in full. */
	var rootSubmitted:Bool = false;
	/** The cache key of every root submission: what invalidates the root is `frameTick` and the tracked reads of its build. */
	static inline final ROOT_KEY = "exosuit-root";
	/** The title bar's frames-per-second reading, written once a second by pollBackground and read by the toolbar. */
	final frameRateLabel = new haxeon.reactive.Signal<String>("");
	var nextBackgroundPoll:Float = 0.0;
	/**
		Until then the background poll runs on every turn of the host loop instead of twenty times a second. Connecting to a
		workspace is a chain of small replies (pipe, handshake, identity, catalog, first reads), each handled by a poll: at
		50 ms a step the chain alone took 0.3 to 0.5 s. Set when a workspace is opened or its status changes, for a few seconds.
	**/
	var eagerPollUntil:Float = 0.0;
	var nextExplorerPoll:Float = 0.0;
	var visibleNotification:Null<feedback.Notification>;
	var notificationPanel:Null<NotificationPanel>;
	var notificationsVisible:Bool = false;
	var notificationRevision:Int = -1;
	var viewportWidth:Float = 1280.0;
	var viewportHeight:Float = 840.0;
	var responsiveRightHidden:Bool = false;
	var desktopSidebarVisible:Bool = true;
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
		viewBuilder = view;
		workbenchActions = new WorkbenchActions(this);
		sourceControl = new ScmPanelController(this);
		agentTabs = new AgentTabs(this);
		terminalTabs = new TerminalTabs(this);
		remoteFileTabs = new RemoteFileTabs(this);
		diagnostics = new ExosuitDiagnostics(this);
		explorer = new ExplorerPanelController(this);
		servedFolders = new ServedFolders(this);
		settingsTab = new SettingsTab(this);
		responsive = new ResponsiveLayout(this);
		contexts = new ContextSwitching(this);
		this.capabilities = capabilities == null ? HostCapabilities.desktop() : capabilities;
		this.hostContext = hostContext;
		if (hostContext != null) hostContext.onBack = phoneBack;
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
		ui.setStyleSheet(ExosuitPalette.styleSheet(this.theme, darkPalette));
		// Menus, toolbar buttons and palette rows work out whether a command is enabled from plain state while building, so
		// the frame after a command ran is a full build (haxeon's registry used to force one itself).
		ui.commands.onInvoked = function(_, result) { if (result.succeeded) requestFrame(); };
		ui.onModifiersChanged = function(modifiers) {
			for (pane in editorPanes) pane.pointerModifiersChanged(modifiers);
		};
		ui.buildContext.environment.colorScheme = darkPalette ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		desktop = fileDialogs;
		registerSidebarDestination("files", IconName.FolderOpen, explorer.explorerPanel, new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files", 0, true));
		registerSidebarDestination("search", IconName.Search, function() return searchPanel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search", 10, true));
		if (this.capabilities.supports(HostCapability.SourceControl))
			registerSidebarDestination("scm", IconName.Hierarchy, sourceControl.sourceControlPanel, new haxeon.ui.widgets.sidebar.SidebarModeOptions("Source Control", 15, true));
		dock = makeDock();
		layoutControls = new WorkbenchLayoutControls(dock);
		layoutModes = new WorkbenchLayoutModes(dock, sidebar, layoutControls, requestFrame, contextPanelProvidesDestinations);
		activityRail = new ActivityRailPreference(sidebar, saveActivityBar, function(message) application.reportError("activity-bar", message),
			function() return application.settings.current.activityBar);
		activityMenu = new ActivityBarMenu(sidebar, layoutModes.hides, activityRail.save);
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
		scmBranches = new ScmBranchController(host, sourceControl.sourceControlSource,
			function(repository, through) return sourceControl.canCheckoutScmRepository(repository, through),
			activateSidebarDestination, requestFrame, function(message) application.reportError("source-control", message),
			function() return "ui-" + Std.string(sourceControl.nextScmOperationId++));
		if (hostContext != null) {
			scmDirectoryWatch = new ScmDirectoryWatch(application.scm, hostContext.events);
			application.onScmWatchPathsChanged = function(root, paths, excluded) {
				if (scmDirectoryWatch != null) scmDirectoryWatch.update(root, paths, excluded);
			};
			scmFocusSubscription = hostContext.events.listen(function(event) {
				switch event {
					case WindowStateChanged(_, flags) if (flags.contains(WindowStateFlags.Active)):
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
			settingsTab.openSettings();
			settingsPanel.setShowAdvanced(true);
			settingsPanel.select("editor/keyboard");
		};
		if (hostContext != null) hostContext.onCloseRequested = function(close) {
			// A quit exohost asked for with `recover` closes at once: unsaved work stays in the recovery store for the next start.
			if (quitRecovering) {
				answerQuit();
				close();
				return;
			}
			application.files.requestQuit(function() {
				answerQuit();
				close();
			}, function() {
				// The user chose Cancel in a save prompt: the window stays, and exohost is told so.
				var answer = quitAnswer;
				quitAnswer = null;
				if (answer != null) answer(null, new exohost.control.ControlError("permission_denied", "the user cancelled the quit"));
			});
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
		application.files.renameInPlace = explorer.beginExplorerRename;
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
			remoteFileSearch, remoteFileTabs.openWorkspaceSearchResult);
		host.captureSidebar = function() {
			if (phoneLayoutActive) {
				var saved = sidebar.encode().split("|");
				saved[2] = desktopSidebarVisible ? "1" : "0";
				saved[3] = Std.string(desktopSidebarWidth);
				return "B\tsidebar\t1\t" + saved.join("|");
			}
			sidebar.setVisible(dock.isOpen("explorer"));
			return "B\tsidebar\t1\t" + sidebar.encode();
		};
		host.captureDockLayout = responsive.captureDockLayout;
		host.captureExtraLayout = function() return [layoutControls.capture(), layoutModes.captureContext()];
		host.restoreExtraLayout = function(lines) { layoutControls.restore(lines); layoutModes.restoreContext(lines); };
		host.captureWindowLayout = function() return [layoutModes.captureWindow()];
		host.restoreWindowLayout = layoutModes.restoreWindow;
		host.beforeContextDetach = layoutModes.suspend;
		layoutModes.beforeApply = function() {
			if (!phoneLayoutActive) return;
			var saved = haxeon.ui.docking.DockWorkspaceSnapshotCodec.decode(responsive.captureDockLayout());
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
			phoneLayoutActive = true; phoneModeApplying = false; responsive.syncPhoneDockRoot();
		};
		host.afterContextRestore = function() { layoutModes.resume(); layoutModes.refreshContext(); };
		// A context shown for the first time keeps the side bar the window has now: its destination, width and whether
		// it shows, and whether the user chose that by hand (then the layout mode leaves it alone). A workspace made or
		// opened from the Workbench tree opens with the tree still there. The bottom and right regions start from the mode.
		host.firstContextLines = function(leaving) {
			var kept:Array<String> = [];
			for (line in leaving) {
				if (StringTools.startsWith(line, "B\tsidebar\t")) kept.push(line);
				else if (StringTools.startsWith(line, "N\tlayout-mode\t")) {
					var fields = line.split("\t");
					if (fields.length == 7) { fields[5] = "0"; fields[6] = "0"; kept.push(fields.join("\t")); }
				}
			}
			return kept;
		};
		var defaultSidebar = sidebar.encode();
		host.restoreSidebar = function(lines) {
			var saved = defaultSidebar, layoutSaved = false;
			for (line in lines) if (StringTools.startsWith(line, "B\tsidebar\t1\t")) { saved = line.substring(12); layoutSaved = true; }
			sidebar.restore(saved);
			activityRail.restore(application.settings.current.activityBar, layoutSaved);
		};
		host.activateSearch = function() showSidebarMode("search");
		host.restoreAgent=agentTabs.makeAgentTab;
  if (this.createTerminal != null || this.createWorkspaceTerminal != null) host.restoreTerminal = terminalTabs.restoreTerminalTab;
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
		sourceControl.syncScmSidebar();
		var previousSidebarWidth = application.settings.current.sidebarWidth;
		sidebar.rememberWidth(previousSidebarWidth);
		application.settings.subscribe(function(value) {
			updateEditorPalette();
			layoutModes.setPreference(value.layoutMode);
			// Another window changed the rail.
			activityRail.settingChanged(value.activityBar);
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
		host.initializeContext(application.activeContext.key());
		host.beforeContextRestore = function() {
			phoneLayoutActive = false; responsiveRightHidden = false; desktopDockRoot = null; desktopDockActivePanel = null; phoneContentRoot = null;
			contextMenu = null;
		};
		application.activeContext.subscribe(function() {
			var key = application.activeContext.key();
			devtools.SwitchTrace.mark("S", key);
			if (contextLayoutsReady) {
				host.switchContext(key); pendingTerminalFocus = dock.activePanelId == "terminal";
				devtools.SwitchTrace.mark("E", key + " " + (host.lastSwitchCold ? "1" : "0"));
			}
			else host.initializeContext(key);
			var roots = filesUseWorkspaceRoots ? application.savedWorkspaces.roots() : application.activeContext.roots;
			explorerRoot = roots.length == 0 ? null : roots[0];
			clearExplorerModel(); sourceControl.clearLocalScmSource();
			for (root in roots) if (controller.SavedWorkspaceController.available(root)) application.scm.discover(root, _ -> requestFrame());
			requestFrame();
			for (id in pendingForgetWorkspaces.copy()) contexts.forgetDeletedWorkspace(id);
		});
		application.activeContext.onMachineAssigned = function(id) host.renameMachine(id);
		application.savedWorkspaces.onChanged = function() {
			var roots = filesUseWorkspaceRoots ? application.savedWorkspaces.roots() : application.activeContext.roots;
			explorerRoot = roots.length == 0 ? null : roots[0];
			clearExplorerModel(); filesScroll.jumpTo(0, 0);
			if (roots.length > 0 && !contextLayoutsReady) openExplorer();
			// A workspace without folders keeps the side bar: the Workbench is where its terminals, sessions and groups are made.
			else if (roots.length == 0 && application.savedWorkspaces.current == null) { sidebar.setVisible(false); dock.close("explorer"); }
			requestFrame();
		};
		if (desktop != null) {
			application.savedWorkspaces.chooseFolder = function() desktop.selectDirectory(function(accepted, paths) {
				if (accepted && paths.length > 0) application.savedWorkspaces.addFolder(paths[0]);
				requestFrame();
			}, "Add Folder to Workspace");
		}
		application.session.start();
		contextLayoutsReady = true;
		if (openPath != null) openArgument(openPath);
		if (dock.isOpen("terminal") && host.panelTerminals.length == 0) terminalTabs.openTerminal();
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
				view.headerActions = function(id) return id == "files" ? explorer.explorerHeaderActions()
					: id == "workbench" && workbenchPanel != null ? workbenchPanel.headerActions(sidebar.width) : null;
				view.headerActionsVisible = function(node) {
					if (sidebar.activeId == "workbench") return true;
					var focused = ui.focus.focusedId;
					return node.states.contains(haxeon.ui.style.StyleState.Hovered)
						|| (focused != null && node.find(focused) != null);
				};
				return new SidebarHoverRebuild(view, requestFrame);
			}),
			new DockPanelContent("editor", function(_) return editorPanel("editor")),
			// Retained by what it reads: the problems and the active context are plain, and every change to them bumps
			// frameTick (the change detector watches the registry's revision; a context switch calls requestFrame).
			DockPanelContent.observing("problems", function(_) {
				frameTick.value;
				return new ProblemsPanel(host, application.activeContext.roots, application.activeContext.kind == workspace.ContextKind.Group);
			})
		];
		if (capabilities.supports(HostCapability.Filesystem))
			dockPanelContents.push(new DockPanelContent("context-panel", function(_) return contextPanel()));
		if (capabilities.supports(Processes))
			dockPanelContents.push(new DockPanelContent("build", function(_) return new BuildOutputPanel(host, application.activeContext.kind == workspace.ContextKind.Group ? application.activeContext.roots : null)));
		if (terminalUiAvailable)
			dockPanelContents.push(new DockPanelContent("terminal", function(_) return terminalTabs.terminalPanel()));
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
		if (layoutModes.hides(id)) return showContextTab(id);
		if (!sidebar.select(id)) return false;
		layoutModes.markLeft();
		if (!dock.isOpen("explorer")) return false;
		if (id == "search") searchPanel.focusQuery = true;
		dock.activate("explorer"); requestFrame(); return true;
	}

	/**
		System Back on a touch host: dismiss the topmost surface, then return from phone content to the sidebar. False
		means nothing is left to go back to and the host may leave the app.
	**/
	public function phoneBack():Bool {
		if (saveAsHandler != null) { resolveSaveAs(true); return true; }
		if (saveConfirmation != null) { resolveSaveConfirmation("cancel"); return true; }
		if (trashConfirmation != null) { resolveTrashConfirmation(false); return true; }
		if (settingsClosePending) { settingsClosePending = false; closingSettingsTab = null; requestFrame(); return true; }
		if (contextMenu != null) { contextMenu = null; requestFrame(); return true; }
		if (agentAttach != null) { agentAttach = null; requestFrame(); return true; }
		if (layoutMenu != null) { layoutMenu = null; requestFrame(); return true; }
		if (notificationsVisible) { hideNotifications(); return true; }
		if (host.overlayView() != null) { ui.key(UiEventKind.KeyDown, UiKey.Escape); requestFrame(); return true; }
		if (!phoneLayoutActive || sidebar.visible) return false;
		ui.clearFocus();
		return showSidebarMode(sidebar.find("workbench") == null ? "files" : "workbench");
	}

	function syncSidebar():Void {
		layoutModes.invalidateRail();
		if (phoneModeApplying) { requestFrame(); return; }
		if (phoneLayoutActive) {
			responsive.syncPhoneDockRoot();
		} else if (!sidebar.visible) {
			if (dock.isOpen("explorer")) dock.close("explorer");
		} else {
			if (!dock.isOpen("explorer")) dock.dock("explorer", host.activePane.id, DockDropZone.Left);
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, workbenchAvailableWidth(),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		requestFrame();
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
		ui.setStyleSheet(ExosuitPalette.styleSheet(theme, dark));
		ui.buildContext.environment.colorScheme = dark ? EnvironmentColorScheme.Dark : EnvironmentColorScheme.Light;
		updateEditorPalette();
		terminalPalette.setDark(dark);
		requestFrame();
	}

	/** New Chat with <provider>: a session in the open workspace, in the chat view (the Workbench's New Chat With…). */
	function installChatCommands():Void {
		for (provider in WorkbenchActions.PROVIDERS) {
			var chosen = provider;
			application.commands.add("agent:new-chat-" + chosen, function(_) {
				if (workbenchPanel != null) workbenchPanel.makeChat(null, workspace.service.WorkspaceProtocol.ROOT_GROUP, chosen);
			}, function(_) return workbenchPanel != null && workbenchPanel.model.openWorkspace != null,
				"New Chat with " + WorkbenchActions.providerLabel(chosen));
		}
	}

	function installCommands():Void {
		installChatCommands();
		application.commands.add("preferences:theme-toggle", function(_) setDarkTheme(!darkPalette), null, "Toggle Light/Dark Theme");
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
		ui.commands.register(new Command("file.reopen-closed-tab", "Reopen Closed Tab", function() host.reopenClosedTab(),
			new Shortcut(84 /* T */, UiModifier.Control | UiModifier.Shift), function() return host.canReopenClosedTab()));
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
		if (terminalTabs.terminalUiAvailable())
			ui.commands.register(new Command("view.terminal", "Toggle Terminal", terminalTabs.toggleTerminal,
				new Shortcut(96 /* ` */, UiModifier.Control), terminalTabs.canShowTerminal));
		if (terminalTabs.terminalUiAvailable()) {
			ui.commands.register(new Command("terminal:new", "New Terminal", terminalTabs.newTerminal,
				new Shortcut(96 /* ` */, UiModifier.Control | UiModifier.Shift), terminalTabs.canCreateTerminal));
			ui.commands.register(new Command("terminal:browse", "Show Workspace Terminals", terminalTabs.openWorkspaceTerminals, null, function() return workbenchClient != null && workbenchClient.canReadTerminals()));
			ui.commands.register(new Command("terminal:terminate", "Terminate Active Terminal", function() {
				var terminal = terminalTabs.activeTerminal();
				if (terminal != null) {
					try terminal.panel.terminate(true) catch (failure:Dynamic) application.reportError("terminal", Std.string(failure));
					requestFrame();
				}
			}, null, terminalTabs.canTerminateTerminal));
			ui.commands.register(new Command("terminal:copy-selection", "Copy Selection", terminalTabs.copyTerminalSelection, null, terminalTabs.canCopyTerminalSelection));
			application.commands.add("terminal:move-to-editor", function(_) terminalTabs.moveTerminalToEditor(),
				function(_) return host.activePanelTerminal() != null);
			application.commands.add("terminal:move-to-panel", function(_) terminalTabs.moveTerminalToPanel(),
				function(_) { var tab = host.activeTab(); return tab != null && UiEditorTabs.terminal(tab) != null; });
		}
		application.commands.add("workspace:search", function(_) showSidebarMode("search"));
		application.commands.add("sidebar:files", function(_) showSidebarMode("files"));
		application.commands.add("sidebar:search", function(_) showSidebarMode("search"));
		application.commands.add("scm:next-hunk", function(_) host.moveActiveDiffHunk(1), function(_) return sourceControl.activeDiffView() != null);
		application.commands.add("scm:previous-hunk", function(_) host.moveActiveDiffHunk(-1), function(_) return sourceControl.activeDiffView() != null);
		application.commands.add("scm:stage-hunk", function(_) sourceControl.applyActiveScmHunk("stage"), function(_) return sourceControl.canApplyActiveScmHunk("stage"));
		application.commands.add("scm:unstage-hunk", function(_) sourceControl.applyActiveScmHunk("unstage"), function(_) return sourceControl.canApplyActiveScmHunk("unstage"));
		application.commands.add("scm:revert-hunk", function(_) sourceControl.applyActiveScmHunk("revert"), function(_) return sourceControl.canApplyActiveScmHunk("revert"));
		application.commands.add("scm:next-change", function(_) host.moveActiveGutterMarker(1), function(_) return host.canMoveActiveGutterMarker());
		application.commands.add("scm:previous-change", function(_) host.moveActiveGutterMarker(-1), function(_) return host.canMoveActiveGutterMarker());
		application.commands.add("scm:open-file-at-line", function(_) sourceControl.openActiveDiffSourceAtLine(), function(_) return sourceControl.activeDiffView() != null);
		application.commands.add("scm:refresh", function(_) sourceControl.refreshSourceControl(), function(_) return sourceControl.sourceControlSource() != null);
		application.commands.add("scm:fetch", function(_) sourceControl.applyPendingScmRemote(scm.ScmOperation.Fetch(null)), function(_) return sourceControl.canUsePendingScmRemotes());
		application.commands.add("scm:pull", function(_) sourceControl.applyPendingScmRemote(scm.ScmOperation.Pull), function(_) return sourceControl.canUsePendingScmRemotes());
		application.commands.add("scm:push", function(_) sourceControl.applyPendingScmRemote(scm.ScmOperation.Push), function(_) return sourceControl.canUsePendingScmRemotes());
		application.commands.add("scm:branches", function(_) scmBranches.open(null), function(_) return true, "Switch Git Branch…");
		application.commands.add("scm:checkout", function(_) scmBranches.open(null), function(_) return sourceControl.canCheckoutScmRepository(null));
		application.commands.add("scm:checkout-selected", function(_) scmBranches.open(sourceControl.pendingScmRepository), function(_) return sourceControl.canCheckoutScmRepository(sourceControl.pendingScmRepository));
		application.commands.add("scm:create-branch", function(_) scmBranches.createPrompt(null), function(_) return sourceControl.canCheckoutScmRepository(null));
		application.commands.add("scm:create-branch-selected", function(_) scmBranches.createPrompt(sourceControl.pendingScmRepository), function(_) return sourceControl.canCheckoutScmRepository(sourceControl.pendingScmRepository));
		application.commands.add("scm:trust-repository", function(_) {
			var source = sourceControl.pendingScmSource, repository = sourceControl.pendingScmRepository;
			if (source != null && repository != null && !source.isRemote()) sourceControl.trustScmRepository(repository);
		}, function(_) return sourceControl.canTrustPendingScmRepository());
		application.commands.add("scm:open-changes", function(_) {
			if (sourceControl.pendingScmSource != null && sourceControl.pendingScmRepository != null && sourceControl.pendingScmGroup != null && sourceControl.pendingScmResource != null)
				sourceControl.openScmResource(sourceControl.pendingScmSource, sourceControl.pendingScmRepository, sourceControl.pendingScmGroup, sourceControl.pendingScmResource);
		}, function(_) return sourceControl.pendingScmResource != null);
		application.commands.add("scm:open-side-by-side", function(_) {
			if (sourceControl.pendingScmSource != null && sourceControl.pendingScmRepository != null && sourceControl.pendingScmGroup != null && sourceControl.pendingScmResource != null)
				sourceControl.openScmResource(sourceControl.pendingScmSource, sourceControl.pendingScmRepository, sourceControl.pendingScmGroup, sourceControl.pendingScmResource, true);
		}, function(_) return sourceControl.pendingScmResource != null && sourceControl.pendingScmGroup != null && sourceControl.pendingScmGroup.id != ScmGroupId.Merge);
		application.commands.add("scm:open-file", function(_) sourceControl.openPendingScmFile(), function(_) return sourceControl.pendingScmResource != null);
		application.commands.add("scm:stage", function(_) sourceControl.applyPendingScmFile(true), function(_) return sourceControl.canStagePendingScmFile());
		application.commands.add("scm:unstage", function(_) sourceControl.applyPendingScmFile(false), function(_) return sourceControl.canUnstagePendingScmFile());
		application.commands.add("scm:resolve-ours", function(_) sourceControl.applyPendingScmConflict("ours"), function(_) return sourceControl.canResolvePendingScmConflict());
		application.commands.add("scm:resolve-theirs", function(_) sourceControl.applyPendingScmConflict("theirs"), function(_) return sourceControl.canResolvePendingScmConflict());
		application.commands.add("scm:resolve-both", function(_) sourceControl.applyPendingScmConflict("both"), function(_) return sourceControl.canResolvePendingScmConflict());
		application.commands.add("scm:stage-all", function(_) sourceControl.applyPendingScmGroup(true), function(_) return sourceControl.canStagePendingScmGroup());
		application.commands.add("scm:unstage-all", function(_) sourceControl.applyPendingScmGroup(false), function(_) return sourceControl.canUnstagePendingScmGroup());
		application.commands.add("scm:discard", function(_) sourceControl.discardPendingScmFile(), function(_) return sourceControl.canDiscardPendingScmFile());
		application.commands.add("scm:commit", function(_) {
			var source = sourceControl.sourceControlSource(), repository = source == null ? null : sourceControl.scmCommitRepository(source);
			if (source != null && repository != null) sourceControl.commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), false, false);
		}, function(_) return sourceControl.canCommitStagedCurrentScmRepository());
		application.commands.add("scm:commit-amend", function(_) {
			var source = sourceControl.sourceControlSource(), repository = source == null ? null : sourceControl.scmCommitRepository(source);
			if (source != null && repository != null) sourceControl.commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), true, false);
		}, function(_) return sourceControl.canAmendCurrentScmRepository());
		application.commands.add("scm:commit-all", function(_) {
			var source = sourceControl.sourceControlSource(), repository = source == null ? null : sourceControl.scmCommitRepository(source);
			if (source != null && repository != null) sourceControl.commitScmMessage(source, repository, application.scmCommitDrafts.get(repository.id), false, true);
		}, function(_) return sourceControl.canCommitAllCurrentScmRepository());
		application.keymap.add(platform.Platform.KEY_ENTER, platform.Platform.MOD_CTRL, ["scm:commit"]);
		application.commands.add("context:previous", function(_) contexts.switchToPreviousContext(), function(_) return contexts.previousContext() != null, "Goto Previous Workspace");
		application.commands.add("context:switch", function(_) contexts.openContextSwitcher(), null, "Switch Workspace or Group…");
		application.commands.add("context:new-window", function(_) contexts.openActiveContextInNewWindow(), function(_) return machineClient != null, "Open Current Workspace or Group in New Window");
		// The keymap takes platform key codes; UiKey.A (65) matches nothing, so these chords did nothing until now.
		application.keymap.add(platform.Platform.KEY_D, platform.Platform.MOD_CTRL | platform.Platform.MOD_SHIFT, ["context:previous"]);
		application.keymap.add(platform.Platform.KEY_A, platform.Platform.MOD_CTRL | platform.Platform.MOD_SHIFT, ["context:switch"]);
		application.commands.add("settings:open", function(_) settingsTab.openSettings());
		ui.commands.register(new Command("preferences.open", "Settings", settingsTab.openSettings,
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
		// The split's ratio is of the whole width: the dock's dividers are hairlines laid over the split and take no room
		// (DockWorkspace, dividerHairline). A divider taken off here made the side bar ~0.66 % wider at each show.
		var width = Math.max(1.0, workbenchAvailableWidth());
		dock.setRoot(DockNode.Split(DockSplitAxis.Horizontal, sidebar.width / width,
			DockNode.Panel("explorer"), content));
	}

	function workbenchAvailableWidth():Float
		return Math.max(0, viewportWidth - ActivityBar.WIDTH - (phoneLayoutActive ? 0 : WorkbenchSurface.INSET * 2));

	function hasSafeArea():Bool
		return hostContext != null && (hostContext.safeLeft > 0 || hostContext.safeTop > 0 || hostContext.safeRight > 0 || hostContext.safeBottom > 0);

	public function view():View {
		// Read first, so every root build depends on it: a bump makes the next frame a full build.
		frameTick.value;
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
		workspaceView.hiddenPanels = responsiveRightHidden ? ["context-panel"] : [];
		var surfaceInset = phoneLayoutActive ? 0.0 : WorkbenchSurface.INSET * 2;
		workspaceView.availableWidth = workbenchAvailableWidth();
		workspaceView.availableHeight = Math.max(0.0, viewportHeight - TOOLBAR_HEIGHT - STATUS_HEIGHT - surfaceInset);
		var activityBar = new ActivityBar(sidebar, activityIcons, activateSidebarDestination,
			application.settings.current.tabTooltipDelay, showManageMenu, manageMenu != null && contextMenu == manageMenu);
		activityBar.onContextMenu = showActivityBarMenu;
		activityBar.onMove = activityMenu.move;
		activityBar.hiddenIds = layoutModes.hiddenOnRail();
		var workspace:View = new Row("workspace-with-activity-bar", [
			new KeyedView("activity-bar", activityBar),
			new KeyedView("workspace:" + host.layoutContextKey, phoneLayoutActive ? workspaceView : new WorkbenchSurface(workspaceView))
		], fillStyle());
		var body = new Column("exosuit-body", [
			new KeyedView("workspace", workspace),
			new KeyedView("status", statusBar())
		], fillStyle());
		var shellStyle = fillStyle();
		shellStyle.background = theme.tokens.surface;
		var shell:View = new AppShell("exosuit-shell", body, topBar(), null, null, shellStyle);
		var safe = hostContext;
		var shellChild = new StackChild("shell", shell, 0.0, 0.0, 0, LayoutAxis.grow(), LayoutAxis.grow());
		if (safe != null && hasSafeArea()) {
			// System bars, a display cutout or the keyboard cover part of the surface: the shell stays inside what is left.
			shellChild = new StackChild("shell", shell, safe.safeLeft, safe.safeTop, 0,
				LayoutAxis.fixed(viewportWidth), LayoutAxis.fixed(viewportHeight));
		}
		var layers:Array<StackChild> = [shellChild];
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

		if (agentAttach != null) {
			if (!agentAttach.isCurrent()) agentAttach = null;
			else {
				var dismiss = function() { agentAttach = null; requestFrame(); };
				layers.push(new StackChild("attach-agent-dialog", new haxeon.ui.widgets.overlays.Dialog(
					"attach-agent-dialog", "Attach Codex thread", agentAttach, dismiss,
					Math.max(240, Math.min(560, viewportWidth - 48))), 0, 0, 60, LayoutAxis.grow(), LayoutAxis.grow()));
			}
		}

		if (settingsClosePending && closingSettingsTab != null) {
			var tab = closingSettingsTab;
			var keepEditing = function() { settingsClosePending = false; closingSettingsTab = null; requestFrame(); };
			var discard = function() {
				tab.allowClose = true;
				for (pane in host.panes.copy()) for (item in pane.items.copy()) if (UiEditorTabs.settings(item) == tab)
					host.closeTab(item, pane.id, true);
				keepEditing();
			};
			var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.childGap = 8;
			var content = new Column("settings-unsaved", [
				new KeyedView("message", new Text("Lists have unsaved changes. Keep editing to apply them, or discard the drafts.", style, null,
					haxeon.ui.core.TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter))),
				new KeyedView("keep", new Button("Keep editing", null, keepEditing, "settings-keep-editing")),
				new KeyedView("discard", new Button("Discard and close", null, discard, "settings-discard-close"))
			], style);
			var dialog = new haxeon.ui.widgets.overlays.Dialog("settings-close-dialog", "Unsaved settings changes", content, keepEditing,
				Math.max(240, Math.min(560, viewportWidth - 48)));
			layers.push(new StackChild("settings-confirmation", dialog, 0, 0, 50, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		if (trashConfirmation != null) {
			var path = trashConfirmation;
			var displayPath = path;
			for (project in application.workspace.projects) {
				var relative = ScmPanelController.pathUnderScope(project.root, path);
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
			else {
				menu.onOutsideClick = handleMenuTriggerClick;
				layers.push(new StackChild("context-menu", menu, 0.0, 0.0, 40));
			}
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
		if (hostContext != null && hostContext.repaintOnly && rootSubmitted)
			return ui.submitCached(viewBuilder, frame, ROOT_KEY);
		// The application's viewport is the safe area: system bars, a cutout and the keyboard are not ours to draw under.
		var safeWidth = hostContext == null ? frame.width : Math.max(1.0, frame.width - hostContext.safeLeft - hostContext.safeRight);
		var safeHeight = hostContext == null ? frame.height : Math.max(1.0, frame.height - hostContext.safeTop - hostContext.safeBottom);
		var widthChanged = viewportWidth != safeWidth;
		viewportWidth = safeWidth;
		viewportHeight = safeHeight;
		layoutModes.suspend();
		responsive.syncResponsiveDockLayout();
		keepSidebarFullHeight();
		if (widthChanged && !phoneLayoutActive && dock.isOpen("explorer")) {
			var mode = sidebar.selected();
			if (mode != null) dock.setPanelWidth("explorer", sidebar.width, workbenchAvailableWidth(),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		responsive.syncResponsiveRightLayout();
		layoutModes.resume();
		var problems = host.getProblems();
		if (problems.revision != badgedProblems) {
			badgedProblems = problems.revision;
			dock.setPanelBadge("problems", problems.values().length);
		}
		// The trees' models apply what their loads and decorations changed here, outside the build, which may not write them.
		if (explorerModel != null) explorerModel.prepareBuild();
		if (contextFiles != null) contextFiles.prepareBuild();
		// The same for the Workbench rows and drafts, a Settings tab whose store was reloaded, and a language popup whose
		// document stopped being the active one: each writes state or requests a frame, which the build may not. The
		// Workbench only while its sidebar mode is shown, as when it synced in its build: hidden, it neither reports errors
		// nor asks for frames.
		if (workbenchPanel != null && sidebar.visible && sidebar.activeId == "workbench") workbenchPanel.prepareBuild();
		settingsTab.syncStore();
		host.dismissStaleLanguagePopup();
		// Plain state the root build shows, which it cannot track: a change makes this frame a full build. A document view's
		// scroll offset, queued reveal and search marks run only its pane's scope, and its caret, selection and text only that
		// scope and the status bar's, unless something built at the root reads them too: the language popup (placed at the
		// caret), the command view and a context menu do.
		var overlayOpen = host.isLanguagePopupVisible() || host.isCommandViewActive() || contextMenu != null;
		if (rootChanges.changed(host, hostContext, application.settings.current.minimapEnabled, application.settings.store.revision,
			responsiveRightHidden, overlayOpen))
			frameTick.value = frameTick.value + 1;
		rootSubmitted = true;
		var root = ui.submitCached(viewBuilder, frame, ROOT_KEY);
		if (explorerReturnPath != null && explorerRename == null && trashConfirmationHandler == null) {
			var target:Null<RenderNode> = null;
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem &&
					node.semantics.label == explorerReturnPath) target = node;
			});
			var returned = target;
			if (returned != null) {
				explorerReturnPath = null;
				host.focusExplorer();
				ui.focusWidget(returned.id);
			}
		}
		return root;
	}

	public function attachWorkbench(client:workspace.client.WorkspaceWorkbenchClient):Void {
		layoutModes.suspend();
		workbenchClient = client;
		workbenchPanel = new WorkbenchPanel(function() return workbenchClient, terminalTabs.openCatalogTerminal, terminalTabs.newGroupedTerminal, workbenchActions.editWorkspaceGroup,
			workbenchActions.catalogTerminalActions, requestFrame, agentTabs.openCodexAgent, workbenchActions.showWorkbenchMenu,
			workbenchActions.attachCodexThread, function(resource, workspaceRoot) host.closeAgentTabs(resource, workspaceRoot),
			agentTabs.createProviderAgent, agentTabs.canCreateAgentSession, function() return application.settings.current.tabTooltipDelay);
		workbenchPanel.defaultProvider = function() return application.settings.current.defaultAgentProvider;
		workbenchPanel.chooseSessionFolder = agentTabs.chooseSessionFolder;
		workbenchPanel.onError = function(message) {
			host.getNotifications().publish(message, feedback.NotificationKind.Error, "workbench");
			requestFrame();
		};
		workbenchPanel.closeTerminal = terminalTabs.closeCatalogTerminal;
		// A switch made from a tree row leaves the keyboard on the row, whatever the context's saved focus was.
		workbenchPanel.focusRoot = function() { host.keepFocusOnSwitch = true; application.activeContext.useWorkspace(); host.keepFocusOnSwitch = false; requestFrame(); };
		workbenchPanel.focusGroup = function(id) {
			host.keepFocusOnSwitch = true;
			focusGroupById(id);
			host.keepFocusOnSwitch = false;
		};
		workbenchPanel.moveAgent = workbenchActions.moveAgentGroup;
		workbenchPanel.actions = workbenchActions;
		workbenchPanel.connectionFailure = function() return workspaceError;
		host.onActiveTabChanged = agentTabs.syncWorkbenchSessionSelection;
		agentTabs.syncWorkbenchSessionSelection(host.activeTab());
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
		if (agentScopes != null) agentScopes.reset();
		agentAttach = null;
		agentRevision = -1;
		requestFrame();
	}

	/** The Remote Access panel: this machine's relay, pairing and devices, from exohost (ADR 0005 section 4). */
	function attachRemoteAccess(machine:workspace.client.MachineClient):Void {
		if (remoteAccessPanel != null) return;
		remoteAccessPanel = new RemoteAccessPanel(new workspace.client.MachineRemoteAccess(machine, requestFrame), requestFrame, function(value) {
			try {
				ui.clipboard.writeText(value);
				return true;
			} catch (_:Dynamic) return false;
		});
		remoteAccessPanel.relayUrlSetting = function() return application.settings.store.getString(config.RelayUrl.SETTING);
		remoteAccessPanel.saveRelayUrl = function(origin) {
			// A relay the user typed is remembered; choosing the default again leaves the setting alone.
			if (origin == config.RelayUrl.resolve(application.settings.store.getString(config.RelayUrl.SETTING))) return;
			var error = application.settings.store.set(config.RelayUrl.SETTING, haxeon.ui.properties.PropertyValue.Text(origin == config.RelayUrl.DEFAULT ? "" : origin));
			if (error != null) application.reportError("remote-access", "Could not save the relay URL: " + error);
		};
		registerSidebarDestination("remote-access", IconName.Radar, function() return remoteAccessPanel,
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Remote Access", 30, true));
	}

	/**
		This machine's workspaces as the Workbench tree's top level, from exohost (docs/architecture/0006-workspaces-without-folders.md),
		and the window's link to exohost, over which exohost pushes them and asks the window to quit. Needs the window's links
		(`attachLinks`) first.
	**/
	public function attachMachineWorkspaces(machine:workspace.client.MachineClient):Void {
		var all = links;
		if (all == null) throw "The window's workspace links are needed before exohost's machine";
		machineClient = machine;
		attachRemoteAccess(machine);
		var shown = new ExohostWorkbenchMachine(this, machine, all);
		exohostWorkbench = shown;
		workbenchActions.attach(shown);
		requestFrame();
	}

	/** A device's Workbench machine (the phone, the browser: DeviceWorkbenchMachine), made by the device's factory. */
	public function attachWorkbenchMachine(machine:WorkbenchMachine):Void {
		workbenchActions.attach(machine);
		requestFrame();
	}

	/**
		exohost asks the window to quit (`exosuit.quit`, docs/design/exohostctl/TDD-exosuit-ctl.md Q4): `prompt` asks about
		unsaved work as closing the window does, `recover` keeps it for the next start and closes at once, `save` saves
		every document first. `answer` gets `{closing: true}` once the window has committed to closing, or why not.
	**/
	public function quitWindow(mode:String, answer:(Null<Dynamic>, Null<exohost.control.ControlError>) -> Void):Void {
		var context = hostContext;
		if (context == null) {
			answer(null, new exohost.control.ControlError("unsupported", "this window cannot be closed"));
			return;
		}
		if (mode != "prompt" && mode != "recover" && mode != "save") {
			answer(null, new exohost.control.ControlError("invalid_argument", 'unknown quit mode "$mode"'));
			return;
		}
		if (mode == "save") {
			application.files.saveAll(function(saved) {
				if (!saved) answer(null, new exohost.control.ControlError("permission_denied", "a document was not saved; the window stays open"));
				else quitWindow("recover", answer);
			});
			requestFrame();
			return;
		}
		quitAnswer = answer;
		quitRecovering = mode == "recover";
		context.requestClose();
		requestFrame();
	}

	/** The window has committed to closing: exohost's quit request, if one asked, is answered. */
	function answerQuit():Void {
		var answer = quitAnswer;
		quitAnswer = null;
		if (answer != null) answer({closing: true}, null);
	}

	/**
		Opens a folder as a workspace (INTENT 3; Workbench design Q10): the workspace that holds it, or a new one named after
		it when none does. Every folder a window shows belongs to a workspace, so this is the one rule for opening a folder;
		a window that ends up on loose folders (Open Folder, a folder on the command line, an older session) comes here
		from its poll. The "open a folder and just edit" use (`exosuit <folder>`) is this with the Workbench out of the way.
		`always` opens the new workspace even when the window is on one (a program asked for the folder).
	**/
	function openFolderWorkspace(folder:String, always = false):Void {
		var machine = machineClient;
		if (machine == null || machine.machine == null || folderOpening == folder) return;
		folderOpening = folder;
		var found = machine.workspaceHolding(folder);
		if (found != null) {
			workbenchActions.open(found);
			return;
		}
		machine.create(null, [folder], function(created, failure) {
			if (failure != null) application.reportError("workspace", "Could not make a workspace of " + folder + ": " + failure);
			else if (created != null && (always || application.savedWorkspaces.current == null)) workbenchActions.open(created);
			requestFrame();
		});
	}

	/**
		A workspace's service follows its folders at once, with no restart, when the window holds a link to it: file roots,
		watchers and repositories; the window's own file roots follow for the workspace it shows.
	**/
	function serveFolders(entry:exohost.MachineCatalog.MachineWorkspace):Void {
		var link = linkOf(entry.id);
		if (link == null) return;
		var skipped = workspace.WorkspaceFolders.select(entry.folders).skipped;
		link.setServedFolders(entry.folders, function(failure) {
			if (failure != null) { application.reportError("workspace", failure); requestFrame(); return; }
			if (skipped.length > 0) application.reportError("workspace", "Folders not served: " + skipped.join("; "));
			if (link == focus) servedFolders.refreshServedRoots(link);
		});
	}

	/** The link the window holds to workspace `id`, or null; asking makes none. */
	public function linkOf(id:String):Null<workspace.client.WorkspaceLink> {
		var all = links;
		return all == null ? null : all.get(id);
	}

	/** The name the ConnectTimeline files the attached workspace under: its id once the attachment knows it. */
	function currentWorkspaceName():String {
		var local = focus;
		return local == null ? "" : local.timelineName();
	}

	/**
		Gives the window its links to workspace services (desktop). The window starts on the link of no workspace; the
		workspace it opens then takes the focus.
	**/
	public function attachLinks(all:workspace.client.WorkspaceLinks):Void {
		links = all;
		snapshots = new workspace.client.CatalogSnapshots(exohost.MachineCatalog.agentStateBase(), function() return Sys.time() * 1000);
		focus = all.none;
		attachWorkspace(all.none);
		attachWorkbench(all.none);
	}

	/**
		Shows `link`'s workspace in the window: the attachment and the Workbench follow it at once, and
		the link the window leaves stays connected (WorkspaceLinks closes it once unused).
	**/
	function focusLink(link:workspace.client.WorkspaceLink):Void {
		if (link == focus) return;
		focus = link;
		// A link that stayed connected shows its rows, files and changes again without "Connecting"; time them anew.
		for (key in ["rows-own:", "files:", "scm:"]) workspace.client.ConnectTimeline.rearm(key + link.timelineName());
		sourceControl.clearSourceControlPanel();
		sourceControl.clearScmPresentation();
		clearExplorerModel();
		sourceControl.clearLocalScmSource();
		workspaceAttachment = link;
		workbenchClient = link;
		if (workbenchPanel != null) workbenchPanel.focusChanged();
		sourceControl.syncScmSidebar();
		workspaceFileLoader.clearCache();
		searchFileClient = null;
		pendingWorkspaceFolderReveal = null;
		searchPanel.workspaceAttachmentChanged();
		workspaceStatus = "";
		workspaceError = null;
		requestFrame();
	}

	/**
		The connection a terminal under `root` uses: the link of the workspace that root belongs to (made when the window
		has none), or null while the machine's workspaces are not known or no workspace holds the root.
	**/
	public function terminalEndpoint(root:String, ?resource:String):Null<workspace.client.WorkspaceRpcEndpoint> {
		var all = links;
		if (all == null || machineWorkspacesPending()) return null;
		var target = terminalServiceTarget(root, resource == null ? null : terminalWorkspaces.get(resource));
		return target == null ? null : all.use(target, true);
	}

	/** Terminals open under `roots` keep their workspaces' links (and services) this turn. */
	public function useTerminalRoots(roots:Array<String>):Void {
		var all = links;
		if (all == null || machineWorkspacesPending()) return;
		for (root in roots) {
			var target = terminalServiceTarget(root);
			if (target != null) all.use(target, true);
		}
	}

	/** Deleted workspaces still on screen; their contexts close once the window has left them. */
	final pendingForgetWorkspaces:Array<String> = [];

	/** Each workspace's state as the Workbench's rows last showed it. */
	function watchedWorkspaces():Map<String, WorkbenchWorkspaceState> {
		var watched = workbenchActions.view().watched;
		return watched == null ? [] : watched;
	}

	/** The focus of every editor window but this one. */
	function otherWindows():Array<exohost.WindowFocus>
		return machineClient == null ? [] : exohost.WindowFocus.WindowFocuses.others(machineClient.windows, windowId());

	/** This window's id in exohost (`w<pid>-<seconds>`); null on a host without exohost (the phone). */
	function windowId():Null<String> {
		var link = exohost.ExohostLink.instance;
		return link == null ? null : link.windowId;
	}

	/**
		The service the window attaches to by workspace id: the open machine workspace's, else the one that holds the active
		project's folder. `target` is null when exohost knows no workspace for it (the folder is then opened as one:
		`openFolderWorkspace`). `waiting` is true while exohost's answer is awaited.
	**/
	function workspaceServiceTarget(projectRoot:Null<String>):{target:Null<workspace.client.WorkspaceServiceTarget>, waiting:Bool} {
		var open = application.savedWorkspaces.current, machine = machineClient;
		var none:{target:Null<workspace.client.WorkspaceServiceTarget>, waiting:Bool} = {target: null, waiting: false};
		if (machine == null) return none;
		if (machine.machine == null) return {target: null, waiting: machine.error == null && (open != null || projectRoot != null)};
		var known:Null<exohost.MachineCatalog.MachineWorkspace> = open == null ? null : machine.workspaceById(open.id);
		if (known == null && projectRoot != null) known = machine.workspaceHolding(projectRoot);
		if (known == null) return none;
		if (known.folders.length == 0 && machine.scratchOf(known) == null) {
			if (!machine.busy()) workbenchActions.scratch(known, function(_) requestFrame());
			return {target: null, waiting: true};
		}
		return {target: machine.serviceTarget(known), waiting: false};
	}

	/** Whether the machine's workspaces are not known yet, so a root cannot say yet which service it belongs to. */
	public function machineWorkspacesPending():Bool {
		var machine = machineClient;
		return machine != null && machine.machine == null && machine.error == null;
	}

	/** The workspace service a terminal root belongs to (that of workspace `workspaceId` when it is known), or null for a folder's own. */
	public function terminalServiceTarget(root:String, ?workspaceId:String):Null<workspace.client.WorkspaceServiceTarget> {
		var machine = machineClient;
		return machine == null ? null : machine.serviceTargetFor(root, workspaceId);
	}

	/**
		The workspace each terminal tab was made in, by its resource id. Two workspaces may share a first folder, so the
		terminal's root alone cannot say which service holds it.
	**/
	public final terminalWorkspaces:Map<String, String> = [];

	/** The folder an agent or terminal tab's session runs in, as its service reports it. */
	function sessionFolder(resource:String, root:String, terminal:Bool):Null<String> {
		if (!terminal) { var record = agentTabs.sessionRecord(resource, root); return record == null ? null : record.cwd; }
		var catalog = workbenchClient == null ? null : workbenchClient.terminalCatalog();
		if (catalog == null || catalog.workspaceRoot != root) return null;
		for (record in catalog.terminals) if (record.id == resource) return record.cwd;
		return null;
	}

	public function attachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		sourceControl.clearSourceControlPanel();
		sourceControl.clearScmPresentation();
		clearExplorerModel();
		sourceControl.clearLocalScmSource();
		if (workbenchPanel != null) workbenchPanel.focusChanged();
		if (workspaceAttachment != null)
			workspaceAttachment.dispose();
		workspaceAttachment = attachment;
		sourceControl.syncScmSidebar();
		workspaceFileLoader.clearCache();
		searchFileClient = null;
		pendingWorkspaceFolderReveal = null;
		searchPanel.workspaceAttachmentChanged();
		requestFrame();
	}

	public function detachWorkspace(attachment:workspace.client.WorkspaceAttachment):Void {
		if (workspaceAttachment != attachment) return;
		sourceControl.clearSourceControlPanel();
		sourceControl.clearScmPresentation();
		clearExplorerModel();
		sourceControl.clearLocalScmSource();
		if (workbenchPanel != null) workbenchPanel.focusChanged();
		workspaceAttachment = null;
		sourceControl.syncScmSidebar();
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
		// The Agents layout belongs to a workspace service that holds groups, even with none yet: the workspace itself
		// takes sessions and terminals. Once it had one, removing the last group does not take the layout (and the
		// Activity Rail's destinations) away: the workspace still has its sessions.
		if (client == null || catalog == null || !client.canReadTerminals()) {
			// A machine workspace always has such a service. While the window is on its way to it (a new workspace's takes
			// seconds to start; every switch drops the catalog for a moment) the layout stays, or the Workbench the workspace
			// was opened from would give way to Files, where nothing reads the catalog that brings the layout back.
			layoutModes.setServiceAvailable(client != null && awaitingWorkspaceService());
			return;
		}
		var hasGroups = catalog.groups.length > 0 || client.canEditGroups();
		if (hasGroups) agentsLayoutInstance = catalog.instance;
		layoutModes.setServiceAvailable(hasGroups || catalog.instance == agentsLayoutInstance);
		leaveRemovedGroup(client, catalog);
	}

	/** Whether the window is on a machine workspace with a service of its own that it has not attached to yet, and has not failed to. */
	function awaitingWorkspaceService():Bool {
		var machine = machineClient;
		return machine != null && application.savedWorkspaces.current != null && machine.workspaceById(application.savedWorkspaces.current.id) != null
			&& workspaceError == null;
	}

	/** The group the window works in was removed (here or from another window): the window moves to the workspace root. */
	function leaveRemovedGroup(client:Null<workspace.client.WorkspaceWorkbenchClient>, catalog:Null<workspace.service.WorkspaceTerminalProtocol.TerminalCatalog>):Void {
		if (client == null || catalog == null || catalog.next != null || client != workbenchClient) return;
		var active = application.activeContext;
		if (catalog.instance == knownGroupsInstance && active.kind == workspace.ContextKind.Group && knownGroups.exists(active.id)) {
			var present = false;
			for (group in catalog.groups) if (group.id == active.id) present = true;
			if (!present) { active.useWorkspace(); requestFrame(); }
		}
		knownGroupsInstance = catalog.instance;
		knownGroups.clear();
		for (group in catalog.groups) knownGroups.set(group.id, true);
	}

	/** Drain services without requesting a render merely because they are running. */
	function pollBackground():Void {
		// Terminal IO follows the host event pump. Filesystem/catalog maintenance
		// keeps its slower cadence without delaying asynchronous shell echo.
		terminalTabs.pollTerminals();
		// The window size, the right panel and the workspace decide what the rail hides.
		layoutModes.syncRail((phoneLayoutActive ? 1 : 0) | (responsiveRightHidden ? 2 : 0) | (remoteAgentsLayout() ? 4 : 0));
		var now = Sys.time();
		var meter = frameRateMeter();
		if (meter.sample(now)) {
			// The toolbar reads the label: a new reading rebuilds it, an equal one changes nothing. The frame comes every
			// second either way, and is counted, so an idle window reads about 1 fps.
			frameRateLabel.value = meter.label();
			scheduleFrame();
		}
		if (now < nextBackgroundPoll) {
			// While a workspace connects, its attachment (and exohost's link, which answers the open) is polled on every turn;
			// everything else keeps its cadence.
			if (now < eagerPollUntil) {
				var machine = machineClient;
				if (machine != null) machine.poll();
				pollWorkspaceAttachment();
			}
			return;
		}
		nextBackgroundPoll = now + 0.05;
		syncLayoutService();
		if (zoomOverlayUntil > 0 && now >= zoomOverlayUntil) {
			zoomOverlayUntil = 0;
			requestFrame();
		}
		if (host.syncSideBySidePanes()) requestFrame();
		if (contextFiles != null && dock.isOpen("context-panel")) contextFiles.poll(now);
		if (scopedSearch != null) scopedSearch.update(now);
		pumpApplication();
		sourceControl.syncScmDocumentMarkers(now);
		if (now >= sourceControl.nextScmPoll) {
			sourceControl.nextScmPoll = now + 0.5;
			var source = sourceControl.sourceControlSource();
			if (source != null) { source.poll(); sourceControl.syncScmPresentation(source); sourceControl.maybeAutoFetchScm(source, now); }
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
					// The tree flattens its rows again in the next build: what its model read there changed.
					var tracePath = Sys.getEnv("EXOSUIT_TREE_TRACE");
					var applyMs = Std.int((Sys.time() - applyStartedAt) * 1000);
					if (tracePath != null && tracePath.length > 0 && applyMs >= 50) {
						try File.appendContent(tracePath,
							'ui-apply=${applyMs}ms paths=${changedPaths.join(",")}\n') catch (_:Dynamic) {}
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

	/**
		How long one open may poll eagerly in all, and how long after a budget ended a status change may begin another:
		a connection that flaps between reconnecting and connected does not keep the eager cadence on.
	**/
	static inline final EAGER_BUDGET = 10.0;
	static inline final EAGER_REST = 60.0;
	var eagerBudgetEnd:Float = 0.0;

	/** Polls eagerly for `seconds` more, within the budget of the open (or status change) that began it. */
	function pollEagerly(seconds:Float, begins:Bool):Void {
		var now = Sys.time();
		if (begins || now >= eagerBudgetEnd + EAGER_REST) eagerBudgetEnd = now + EAGER_BUDGET;
		eagerPollUntil = Math.min(now + seconds, eagerBudgetEnd);
		workspace.transport.FineTimer.hold(eagerPollUntil - now);
	}

	/** Moves the window's connection along now: an open asks exohost for its workspace's service at once. */
	public function connectNow():Void {
		pollWorkspaceAttachment();
	}

	/**
		The window's attachment to its workspace service: selects the service, drives the connection and follows its
		status. Called with the application's poll, and alone on every loop turn while a workspace connects (see
		`eagerPollUntil`), so the rest of the background work keeps its cadence.
	**/
	function pollWorkspaceAttachment():Void {
		var attachment = workspaceAttachment;
		if (attachment != null) {
			var project = application.workspace.activeProject;
			var all = links;
			if (all != null) {
				// A folder the window shows with no workspace open (the command line, Open Folder, an older session) opens
				// the workspace that holds it, or a new one; until then the window serves the folder's workspace, if any.
				if (project != null && application.savedWorkspaces.current == null) openFolderWorkspace(project.root);
				var service = workspaceServiceTarget(project == null ? null : project.root);
				var target = service.target;
				// The window's workspace: its link, kept connected; a switch is a change of focus to another link.
				if (target != null) focusLink(all.use(target, true));
				else if (!service.waiting) focusLink(all.none);
				attachment = workspaceAttachment;
			}
			attachment.poll();
			var fileClient = attachment.fileClient();
			servedFolders.reconcileServedFolders(attachment, fileClient);
			servedFolders.pollServedRoots(attachment);
			if (fileClient != searchFileClient) {
				searchFileClient = fileClient;
				searchPanel.workspaceAttachmentChanged();
			}
			var failure = attachment.failure();
			if (failure != null && failure != workspaceError) application.reportError("workspace", failure);
			workspaceError = failure;
			var label = attachment.statusLabel();
			if (workbenchClient != null && workbenchClient.terminalCatalog() != null)
				if (workspace.client.ConnectTimeline.markOnce("rows-own:" + currentWorkspaceName(), "rows-visible", currentWorkspaceName(), "own"))
					workspace.client.ConnectTimeline.markAtNextFrame("rows-frame", currentWorkspaceName(), "own");
			markFirstViews(attachment);
			if (workspaceStatus != label) {
				// Connecting: poll eagerly until it is done; connected: a little longer, for the first catalog and file reads.
				pollEagerly(StringTools.startsWith(label, "Connecting") || label == "Workspace reconnecting" ? 8.0 : 1.5, false);
				workspace.client.ConnectTimeline.mark("status", currentWorkspaceName(), label);
				if (StringTools.startsWith(label, "Connecting"))
					for (key in ["rows-own:", "files:", "scm:"]) workspace.client.ConnectTimeline.rearm(key + currentWorkspaceName());
				workspaceStatus = label;
				requestFrame();
			}
			contexts.leaveMissingGroup();
		}
	}

	/**
		Marks in the connect timeline when the open workspace's file tree first lists its root and when its source control
		first has a snapshot (terminal tabs mark their screens themselves, document tabs their reads: `tab-file-read`).
	**/
	function markFirstViews(attachment:workspace.client.WorkspaceAttachment):Void {
		var name = currentWorkspaceName();
		if (!workspace.client.ConnectTimeline.marked("files:" + name) && Std.isOfType(explorerModel, WorkspaceFileTreeModel)
			&& (cast(explorerModel, WorkspaceFileTreeModel)).rootListed())
			workspace.client.ConnectTimeline.markOnce("files:" + name, "files-visible", name);
		if (!workspace.client.ConnectTimeline.marked("scm:" + name)) {
			var source = attachment.sourceControlSource();
			if (source != null)
				for (repository in source.repositories())
					if (source.snapshot(repository.id) != null) {
						workspace.client.ConnectTimeline.markOnce("scm:" + name, "scm-visible", name, source.repositories().length + " repositories");
						break;
					}
		}
	}

	function pumpApplication():Void {
		var pumpedAt = Sys.time();
		nextBackgroundPoll = pumpedAt + 0.05;
		// The workspace client reads its lists when the service pushes a change; here only what they changed is applied.
		if(workbenchClient!=null) {
   var agentService=workbenchClient.agentService();
   if(agentRevision!=agentService.agentRevision()) {
    agentRevision=agentService.agentRevision();
    var names=agentService.agents();
    if(names!=null) {
     UiEditorTabs.syncAgentNames(host.panes,names);
     agentService.showAgents(UiEditorTabs.agentResources(host.panes,names.root));
    }
    requestFrame();
   }
  }
		// Terminal names and folders reach the tabs of every workspace the window holds a link to, not only the open one.
		var clients:Array<workspace.client.WorkspaceWorkbenchClient> = workbenchClient == null ? [] : [workbenchClient];
		var held = links;
		if (held != null)
			for (id in held.ids()) {
				var link = held.get(id);
				if (link != null && link != workbenchClient) clients.push(link);
			}
		for (client in clients) {
			var catalog = client.terminalCatalog();
			var root = catalog == null || catalog.workspaceRoot == null ? "" : catalog.workspaceRoot;
			if (catalog == null || terminalNameRevisions.get(root) == client.terminalCatalogRevision()) continue;
			terminalNameRevisions.set(root, client.terminalCatalogRevision());
			for (record in catalog.terminals) for (tab in host.allTerminalTabs())
				if (tab.remote && tab.resourceId == record.id && tab.workspaceRoot == record.workspaceRoot) { tab.updateWorkspaceName(record.name); tab.cwd = record.cwd; }
			requestFrame();
		}
		var previousLanguageStatus = application.language.statusLabel();
		var previousProblems = host.getProblems().revision;
		var previousNotification = visibleNotification;
		var previousBuildBytes = application.build.output.byteCount;
		var liveFeed = application.build.live;
		var previousLiveEvents = liveFeed == null ? 0 : liveFeed.applied;
		var previousBuild = application.build.active;
		var previousDecorations = host.getPluginDecorations().revision;
		var previousPluginStatus = host.getPluginStatusItems().revision;
		var previousPluginPanels = host.getPluginPanels().revision;
		var previousExternal = application.documents.externalRevision;
		application.update();
		pollWorkspaceAttachment();
		workbenchActions.poll();
		remoteFileSearch.update(Sys.time());
		// O(1) per frame: the key (strings built and escaped) is made only when the context, workspace or machine id changed.
		var shown = application.activeContext, link = exohost.ExohostLink.instance;
		if (link != null && (shown.revision != presenceRevision || shown.contextWorkspaceId != presenceWorkspace || shown.machineId != presenceMachine)) {
			presenceRevision = shown.revision; presenceWorkspace = shown.contextWorkspaceId; presenceMachine = shown.machineId;
			link.setContext(shown.key());
		}
		var workspaces = machineClient, shownMachine = exohostWorkbench;
		if (workspaces != null && shownMachine != null) {
			// exohost pushes every change to the machine over the link; polling only moves the link along.
			var panel = workbenchPanel;
			if (shownMachine.poll(panel == null ? [] : panel.expandedWorkspaceIds())) requestFrame();
			contexts.applyStartContext();
			if (machineClientRevision != workspaces.revision) {
				machineClientRevision = workspaces.revision;
				var named = workspaces.machine;
				if (named != null && named.id.length > 0 && named.id != application.activeContext.machineId) {
					// Saved contexts move from the placeholder machine to the catalog's id before anything switches.
					application.activeContext.assignMachine(named.id);
				}
				// Another window may have attached or detached a folder; its change reaches the service shortly after.
				servedFolders.startServedRefresh();
				contexts.pruneRecentContexts();
				requestFrame();
			}
		}
		if (previousLanguageStatus != application.language.statusLabel() ||
			previousProblems != host.getProblems().revision ||
			previousNotification != host.getNotifications().current() ||
			previousBuildBytes != application.build.output.byteCount || previousBuild != application.build.active ||
			(liveFeed != null && previousLiveEvents != liveFeed.applied) ||
			previousDecorations != host.getPluginDecorations().revision ||
			previousPluginStatus != host.getPluginStatusItems().revision ||
			previousPluginPanels != host.getPluginPanels().revision ||
			previousExternal != application.documents.externalRevision)
			requestFrame();
		visibleNotification = host.getNotifications().current();
		if (notificationRevision != host.getNotifications().revision) {
			notificationRevision = host.getNotifications().revision;
			requestFrame();
		}
		if (notificationsVisible && notificationPanel != null) notificationPanel.poll();
		ui.buildContext.environment.scrollbarVisibility = host.scrollbarVisibility;
	}

	public function context():UiContext return ui;

	/** The view tree and window state a host's diagnostics read (DesktopUiApplication); see ExosuitDiagnostics. */
	public function diagnosticState():Dynamic
		return diagnostics.diagnosticState();

	public function dispose():Void {
		layoutModes.dispose();
		layoutControls.dispose();
		if (contextFiles != null) contextFiles.dispose();
		if (scopedSearch != null) scopedSearch.dispose();
		if (notificationPanel != null) notificationPanel.close();
		scmBranches.cancel();
		if (hostContext != null) hostContext.onPoll = null;
		application.onScmWatchPathsChanged = null;
		if (scmFocusSubscription != null) scmFocusSubscription.dispose();
		scmFocusSubscription = null;
		if (scmDirectoryWatch != null) scmDirectoryWatch.dispose();
		scmDirectoryWatch = null;
		sourceControl.clearLocalScmSource();
		clearExplorerModel();
		remoteFileSearch.cancel();
		if (links != null) links.dispose();
		else if (workspaceAttachment != null) workspaceAttachment.dispose();
		application.shutdown();
		host.dispose();
		if (desktop != null) desktop.shutdown();
		ui.dispose();
	}

	function contextPanel():View {
		if (remoteAgentsLayout()) return unscopedRemoteContextPanel();
		if (contextFiles == null) contextFiles = new ContextFilesView(contextRoots,
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
					else if (!remote.isDirectoryKey(path)) remoteFileTabs.openWorkspaceFile(remote, path, pin);
				} else if (Std.isOfType(model, DirectoryTreeModel)) {
					var local:DirectoryTreeModel = cast model;
					if (local.isSyntheticRow(path)) local.activateSyntheticRow(path);
					else if (!local.isDirectoryPath(path)) application.openInBackground(path, !pin, pin);
				}
			}, host, requestFrame, function() return darkPalette, hostContext == null ? null : hostContext.events);
		if (scopedSearch == null) scopedSearch = new ScopedSearchPanel(application.workspace, function() {
			return contextScope() == null ? [] : contextRoots();
		}, openScopedSearchResult, requestFrame, function() return application.settings.current.searchMaxResults);
		var scope = contextScope();
		var style = fillStyle(); style.childGap = 4;
		var folders = scope != null && scope.isWorkspace() ? contextRoots() : [];
		var caption = scope == null ? application.activeContext.label
			: folders.length > 1 ? scope.label + " — " + folders.length + " folders" : scope.caption();
		// Search here follows the scope; outside the Agents layout it is the workspace's Search, unless the sidebar shows it.
		var searchContent:View = scope != null ? scopedSearch : sidebar.visible && sidebar.activeId == "search"
			? new Text("Search is open in the sidebar.", null, theme.tokens.textSecondary, TextStyleOverride.text(12)) : searchPanel;
		// Icons go first and labels last as the panel narrows: Files, Search and Changes with their icons need about
		// 252 px; the labels alone fit from about 200 px (the default 1280 px window gives the panel 248 px).
		var contextWidth = dock.isOpen("context-panel") ? contextPanelWidth() : 1000.0;
		var compact = contextWidth < 200, withIcons = contextWidth >= 258;
		var tab = function(key:ContextPanelTab, label:String, icon:IconName, content:View):TabItem
			return new TabItem(key, label, content, true, compact || withIcons ? icon : null, compact ? "" : null);
		var tabs = new Tabs("context-panel-tabs", [tab(ContextPanelTab.Files, "Files", IconName.FolderOpen, contextFiles),
			tab(ContextPanelTab.Search, "Search", IconName.Search, searchContent),
			tab(ContextPanelTab.Changes, "Changes", IconName.Hierarchy, sourceControl.sourceControlPanel())], contextTab,
			function(next) {
				var selected = ContextPanelTabs.fromKey(next);
				if (selected != null) contextTab = selected;
				requestFrame();
			}, fillStyle(), null, null, null, null, TabsSelectionMode.Controlled);
		return new Column("context-panel-content", [
			new KeyedView("scope", contextCaption(caption)),
			new KeyedView("tabs", tabs)
		], style);
	}

	function contextCaption(caption:String):View {
		var captionStyle = new LayoutStyle(); captionStyle.padding = new Insets(10, 6, 10, 0); captionStyle.width = LayoutAxis.grow();
		return new Column("context-panel-scope", [new KeyedView("caption",
			new haxeon.ui.widgets.text.MiddleEllipsisText("context-panel-scope-text", caption, true,
				new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None, null, null, null, theme.tokens.textSecondary)))], captionStyle);
	}

	/**
		A remote workspace's file, search and change services cannot narrow to a folder yet, so the Agents layout's right
		panel says so instead of showing the whole workspace as if it were the group's. The rail keeps Files, Search and
		Source Control for that workspace (see contextPanelProvidesDestinations).
	**/
	function unscopedRemoteContextPanel():View {
		var style = fillStyle(); style.childGap = 6;
		var bodyStyle = new LayoutStyle(); bodyStyle.padding = new Insets(10, 0, 10, 0); bodyStyle.width = LayoutAxis.grow();
		var text = new TextStyleOverride(null, 13.0, null, haxeon.ui.TextWrap.WordCharacter);
		return new Column("context-panel-content", [
			new KeyedView("scope", contextCaption("Not scoped for remote workspaces")),
			new KeyedView("body", new Column("context-panel-remote", [
				new KeyedView("reason", new Text("Files, Search and Changes follow the selected group only in local workspaces.", null, null, text)),
				new KeyedView("hint", new Text("Use Files, Search and Source Control on the Activity Bar for the whole remote workspace.",
					null, theme.tokens.textSecondary, text))
			], bodyStyle))
		], style);
	}

	/** The Agents layout over a workspace without local file access: the right panel cannot follow the group's folder. */
	function remoteAgentsLayout():Bool
		return layoutModes.current == LayoutMode.Agents && workspaceAttachment != null && !workspaceAttachment.hasLocalFileAccess();

	/**
		Whether the right panel can stand in for the rail's Files, Search and Source Control: it is registered, shown at
		this window size, and can follow the group's folder. Otherwise the rail keeps them, so files stay reachable.
	**/
	function contextPanelProvidesDestinations():Bool
		return dock.get("context-panel") != null && !phoneLayoutActive && !responsiveRightHidden && !remoteAgentsLayout();

	/** The title bar's workspace name. */
	function workspaceTitleText():String {
		if (application.activeContext.kind == workspace.ContextKind.Group) return application.activeContext.label;
		var named = application.savedWorkspaces.displayName();
		if (named != null) return named;
		return explorerRoot == null ? "" : haxe.io.Path.withoutDirectory(explorerRoot);
	}

	/**
		"Open folder" on a group: the window works in that group's folder (its context), as a switch to the group does. It
		never adds the folder to the open workspace, which keeps the folders it was given.
	**/
	function focusGroupById(id:String):Void {
		var client = workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		if (catalog != null) application.activeContext.openSessionGroup(id, catalog.groups, catalog.workspaceRoot);
		requestFrame();
	}

	/** Folders the right panel's Files and Changes show: the Agents scope's folder, else the active context's roots. */
	function contextRoots():Array<String> {
		var scope = contextScope(), panel = workbenchPanel;
		if (scope == null || panel == null) return application.activeContext.roots;
		if (!scope.isWorkspace()) return [scope.directory];
		// The panel asks on every frame; the folders are worked out again only when their inputs change.
		var attached = application.activeContext.roots;
		var key = panel.model.revision() + "|" + scope.directory + "|" + attached.join("|");
		if (key == contextRootsKey) return contextRootsValue;
		// The workspace itself works in every attached folder and in each group folder outside them.
		var folders = attached.copy(), own = scope.directory;
		if (!Lambda.exists(folders, function(root) return PathKey.within(root, own))) folders.push(own);
		contextRootsValue = AgentScope.workspaceFolders(panel.model, folders, normalizedContextFolder);
		contextRootsKey = key;
		return contextRootsValue;
	}

	var contextRootsKey:Null<String>;
	var contextRootsValue:Array<String> = [];
	var contextFolders:Map<String, String> = [];

	/** A group folder as the file system spells it; remembered, since the panel asks on every frame. */
	function normalizedContextFolder(path:String):String {
		var known = contextFolders.get(path);
		if (known != null) return known;
		// Bounded: a long session with many group folders must not grow it without end.
		if (Lambda.count(contextFolders) >= 256) contextFolders = [];
		var value = path;
		try value = application.workspace.fileSystem.normalize(path) catch (_:Dynamic) value = path;
		contextFolders.set(path, value);
		return value;
	}

	/**
		The right panel's scope in the Agents layout (see AgentScope.resolve). Null outside that layout, without a Workbench,
		and for a workspace without local file access (see unscopedRemoteContextPanel).
	**/
	function contextScope():Null<AgentScope> {
		var panel = workbenchPanel;
		if (layoutModes.current != LayoutMode.Agents || panel == null || remoteAgentsLayout()) return null;
		if (agentScopes == null) agentScopes = new AgentScopeTracker(application.workspace.fileSystem.normalize);
		return agentScopes.resolve(panel.model, panel.tree.selectedKey);
	}

	/** The right panel's approximate width, from the split ratios on its path (dividers ignored). */
	function contextPanelWidth():Float return panelWidth(dock.root, Math.max(0, viewportWidth - ActivityBar.WIDTH), "context-panel");

	static function panelWidth(node:DockNode, available:Float, id:String):Float {
		return switch node {
			case Split(axis, ratio, first, second):
				var inFirst = haxeon.ui.docking.DockNodeTools.contains(first, id);
				var share = axis == DockSplitAxis.Horizontal ? (inFirst ? ratio : 1 - ratio) : 1.0;
				panelWidth(inFirst ? first : second, available * share, id);
			case _: available;
		};
	}

	/** In the Agents layout the rail's Files, Search and Source Control open the right panel's tab instead. */
	function showContextTab(destination:String):Bool {
		contextTab = ContextPanelTabs.forDestination(destination);
		if (!layoutControls.rightOpen()) layoutControls.toggleRight();
		if (contextTab == ContextPanelTab.Search) {
			if (contextScope() == null) searchPanel.focusQuery = true;
			else if (scopedSearch != null) scopedSearch.focusQuery = true;
		}
		dock.activate("context-panel");
		requestFrame();
		return true;
	}

	function openScopedSearchResult(match:search.SearchMatch):Void {
		var document = application.workspace.documents.open(match.path);
		if (!search.DocumentSearch.valid(document, match)) { if (scopedSearch != null) scopedSearch.rerun(); return; }
		var view = host.openDocument(document);
		view.selectRange(new BufferPosition(match.line, match.column), new BufferPosition(match.line, match.column + match.length));
		view.cursorChanged(); requestFrame();
	}

	function layoutShortcut(command:String):String return [for (shortcut in ui.commands.shortcutsFor(command)) shortcut.label()].join(", ");

	function layoutButton(region:String, label:String, command:String, selected:Bool):View {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH); style.height = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH);
		style.padding = new Insets(6, 6, 6, 6);
		var button = new Button("", style, function() { ui.commands.executeContext(command, ui.commandContext); requestFrame(); }, "layout-" + region,
			null, ButtonVariant.Navigation, selected, ["chrome-action"], region == "menu" ? IconName.Grid : null, null,
			region == "menu" ? null : new LayoutControlIcon(region, theme.tokens.textSecondary), null, null, null, null, label);
		var shortcut = layoutShortcut(command);
		return new TabTooltip("layout-tooltip-" + region, button, new Text(label + (shortcut.length == 0 ? "" : " (" + shortcut + ")")),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), application.settings.current.tabTooltipDelay);
	}

	/** Menu backdrops consume outside clicks, except for explicit menu triggers. */
	function handleMenuTriggerClick(event:UiEvent):Bool {
		if (event.button != 0 || ui.root == null) return false;
		var point = new haxeon.ui.Point(event.x, event.y);
		var layout = diagnostics.findStyleNode(ui.root, "layout-menu");
		if (!phoneLayoutActive && layout != null && layout.enabled && layout.resolved != null && layout.containsGlobalPoint(point)) {
			ui.commands.executeContext("view.layout-menu", ui.commandContext);
			return true;
		}
		var manage = diagnostics.findStyleNode(ui.root, "activity-manage");
		if (manage != null && manage.enabled && manage.resolved != null && manage.containsGlobalPoint(point)) {
			showManageMenu(event);
			return true;
		}
		return false;
	}

	function showLayoutMenu():Void {
		if (layoutMenu != null && contextMenu == layoutMenu) {
			contextMenu = null;
			requestFrame();
			return;
		}
		var items:Array<MenuItem> = [];
		var commands = ["exosuit.workbench:toggle-sidebar", "view.layout-bottom", "view.layout-right"];
		var labels = [(dock.isOpen("explorer") ? "Hide" : "Show") + " Left Sidebar",
			(layoutControls.bottomOpen() ? "Hide" : "Show") + " Bottom Panel", (layoutControls.rightOpen() ? "Hide" : "Show") + " Right Panel"];
		for (index in 0...commands.length) {
			var command = commands[index];
			if (ui.commands.get(command) != null) items.push(new MenuItem(command, labels[index], function() {
				contextMenu = null; ui.commands.executeContext(command, ui.commandContext); requestFrame();
			}, true, layoutShortcut(command)));
		}
		for (mode in [LayoutMode.Editor, LayoutMode.Agents]) {
			var selected = mode;
			items.push(new MenuItem("view.mode-" + mode.id, (layoutModes.current.id == mode.id ? "✓ " : "") + mode.label + " Layout", function() { contextMenu = null; layoutModes.select(selected.id); requestFrame(); }));
		}
		items.push(new MenuItem("view.mode-auto", "Automatic Layout", function() { contextMenu = null; layoutModes.automatic(); requestFrame(); }));
		var anchor = diagnostics.findStyleNode(ui.root, "layout-menu");
		var x = Math.max(0, viewportWidth - 290), y = TOOLBAR_HEIGHT + 4;
		if (anchor != null) { var bounds = anchor.globalBounds(); x = Math.min(x, bounds.x); y = bounds.y + bounds.height + 4; }
		layoutMenu = new CommandMenu(application.commands, application.context, [], x, y, function() return !phoneLayoutActive,
			function() { contextMenu = null; requestFrame(); }, items, true);
		contextMenu = layoutMenu;
		requestFrame();
	}

	function topBar():View {
		// The dock's open regions and the frame rate are tracked reads of buildTopBar; the string holds the plain inputs.
		return new RetainedView("toolbar", function(_) return buildTopBar(),
			function() return phoneLayoutActive + ":" + viewportWidth + ":" + application.activeContext.revision + ":" + explorerRoot + ":" + workspaceStatus + ":" + terminalTabs.canShowTerminal() + ":" + terminalTabs.terminalCreationFailure() + ":" + (hostContext == null || hostContext.windowControls == null ? 0 : hostContext.windowControls.revision) + ":" + ui.animations.revision);
	}

	function buildTopBar():View {
		// A touch host has no hover labels: toolbar buttons are icons at every width, so the bar fits a phone and an unfolded screen.
		var custom = hostContext != null && (hostContext.windowControls != null || hostContext.touchPrimary);
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
		var workspaceTitle = workspaceTitleText();
		var fps = frameRateLabel.value;
		if (fps.length > 0) workspaceTitle = workspaceTitle.length == 0 ? fps : workspaceTitle + " · " + fps;
		if (application.activeContext.kind == workspace.ContextKind.Group) {
			var back = new Button("Back to Workspace", null, function() {
				application.activeContext.useWorkspace(); requestFrame();
			}, "context-back-to-workspace", null, ButtonVariant.Navigation);
			items.push(new KeyedView("context-back", back));
		}
		if (custom) {
			var caption = workspaceTitle + (workspaceStatus.length == 0 ? "" : (workspaceTitle.length == 0 ? "" : " · ") + workspaceStatus);
			items.push(new KeyedView("workspace-title", new haxeon.ui.widgets.text.MiddleEllipsisText("toolbar-workspace-title", caption, true,
				new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None, null, null, null, theme.tokens.textSecondary))));
		} else items.push(new KeyedView("workspace-title", new Text(workspaceTitle, workspaceTitleStyle, theme.tokens.textSecondary,
			new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None))));
		if (!custom && !phoneLayoutActive && workspaceStatus.length > 0)
			items.push(new KeyedView("workspace-status", new Text(workspaceStatus, null, theme.tokens.textSecondary, new TextStyleOverride(null, 12, null, haxeon.ui.TextWrap.None))));
		items.push(new KeyedView("palette", toolbarButton("Commands", IconName.Search, togglePalette)));
		if (!phoneLayoutActive) {
			items.push(new KeyedView("layout-left", layoutButton("left", "Toggle Left Sidebar", "exosuit.workbench:toggle-sidebar", dock.isOpen("explorer"))));
			items.push(new KeyedView("layout-bottom", layoutButton("bottom", "Toggle Bottom Panel", "view.layout-bottom", layoutControls.bottomOpen())));
			if (capabilities.supports(HostCapability.Filesystem))
				items.push(new KeyedView("layout-right", layoutButton("right", "Toggle Right Panel", "view.layout-right", layoutControls.rightOpen())));
			items.push(new KeyedView("layout-menu", layoutButton("menu", "Layout", "view.layout-menu", false)));
		}
		var toolbar:View = new Row("exosuit-toolbar", items, style);
		return new WorkbenchBoundary(hostContext != null && hostContext.windowControls != null
			? new haxeon.ui.widgets.WindowTitleBar("exosuit-titlebar", toolbar, hostContext.windowControls, TOOLBAR_HEIGHT) : toolbar);
	}

	function toolbarActionCapacity():Int {
		if (phoneLayoutActive) return 0;
		if (hostContext == null || hostContext.windowControls == null) return 5;
		var available = viewportWidth - haxeon.ui.widgets.WindowTitleBar.CONTROLS_WIDTH - (phoneLayoutActive ? 0 : 4 * (TOOLBAR_BUTTON_WIDTH + TOOLBAR_GAP));
		// Brand, horizontal padding, Commands, two gaps and a small title area.
		var reserved = BRAND_WIDTH + 20.0 + TOOLBAR_BUTTON_WIDTH + 2 * TOOLBAR_GAP + 32.0;
		return Std.int(Math.max(0, Math.min(5, Math.floor((available - reserved) / (TOOLBAR_BUTTON_WIDTH + TOOLBAR_GAP)))));
	}

	function toolbarButton(label:String, icon:IconName, action:Void->Void):View {
		var custom = phoneLayoutActive || hostContext != null && (hostContext.touchPrimary || hostContext.windowControls != null);
		var style = new LayoutStyle();
		if (custom) { style.width = LayoutAxis.fixed(TOOLBAR_BUTTON_WIDTH); style.height = LayoutAxis.fixed(28); style.padding = new Insets(8, 0, 8, 0); }
		var button = new Button(custom ? "" : label, style, action, "toolbar-" + label,
			label == "Terminal" ? terminalTabs.canShowTerminal() : null, custom ? ButtonVariant.Navigation : ButtonVariant.Secondary,
			null, custom ? ["chrome-action"] : null, icon, null, null, null, null, null, null, label);
		return custom || label == "Terminal" ? new TabTooltip("toolbar-tooltip:" + label, button,
			new Text(label == "Terminal" && !terminalTabs.canShowTerminal() ? terminalTabs.terminalCreationFailure() : label),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), application.settings.current.tabTooltipDelay) : button;
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

	/**
		The status bar, in a scope of its own: it runs in every root build, and alone when the active view's `editing` signal
		moves (RootChangeDetector before a frame), so a caret move, a selection or typing does not build the root.
	**/
	function statusBar():View
		return new TrackedScope("status-bar-scope", statusBarContent);

	function statusBarContent():View {
		var active = host.activeDocument();
		var tab = host.activeTab();
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		// A diff view's document is generated, never saved, so it has no unsaved changes to flag.
		var activeView = host.activeView(), diff = activeView != null && activeView.diffDocument != null;
		// The read is the subscription.
		if (activeView != null) activeView.editing.value;
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
		var cursor = active == null || activeView == null || image != null || unsupported != null ? null
			: StatusBarCursor.label(active.buffer, activeView.selection);
		var trailing = languageStatus.length > 0 ? languageStatus : '${host.activePane.items.length} open';
		if (image != null) trailing = "Whole Image · " + image.image.width + " × " + image.image.height + " px · " + FileSizeLabel.format(image.sizeBytes);
		else if (unsupported != null) trailing = (unsupported.file.binary ? "Binary file" : "Unsupported encoding") + " · " + FileSizeLabel.format(unsupported.file.sizeBytes);
		return new RetainedView("status-bar", function(_) return new StatusBarView({
			document: label,
			cursor: cursor,
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
			tooltipDelay: application.settings.current.tabTooltipDelay,
			openRemote: function() showSidebarMode("remote-access"),
			showNotification: function(entry) showNotifications(entry),
			dismissNotification: function() { center.dismissToast(); requestFrame(); },
			toggleNotifications: function() { if (notificationsVisible) hideNotifications(); else showNotifications(); }
		}), function() return cursor + ":" + indentationDetails + ":" + remoteDetails + ":" + label + ":" + trailing + ":" +
			host.getPluginStatusItems().revision + ":" + (notification == null ? 0 : notification.id) + ":" + center.revision + ":" + notificationsVisible + ":" + ui.animations.revision + ":" + application.settings.current.tabTooltipDelay);
	}

	function showFilesScope():Void {
		var entries = [new commandview.CommandViewEntry("Context", application.activeContext.label, "context"),
			new commandview.CommandViewEntry("Workspace", "All workspace roots", "workspace")];
		host.openCommandView(new commandview.CommandViewProvider("Files Scope: ", entries, _ -> {}, function(entry, _, _) {
			if (entry != null) {
				filesUseWorkspaceRoots = entry.value == "workspace";
				var roots = explorer.localExplorerRoots(); explorerRoot = roots.length == 0 ? null : roots[0];
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
		var button = new Button("", style, action, key, null, ButtonVariant.Navigation, null, null, icon, null, null, null, null, null,
			16, label);
		return new TabTooltip(key + "-tooltip", button, new Text(label),
			function() return new Rect(0, 0, viewportWidth, viewportHeight), application.settings.current.tabTooltipDelay);
	}

	function commandMenuItem(command:String, label:String, separatorBefore:Bool = false, enabled:Bool = true):Null<MenuItem> {
		if (!application.commands.contains(command)) return null;
		return new MenuItem(command, label, function() application.commands.perform(command, application.context),
			enabled && application.commands.isValid(command, application.context), null, separatorBefore);
	}

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
		if (layoutModes.hides(id)) { showContextTab(id); return; }
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
			var settings = UiEditorTabs.settings(item);
			if (settings != null) {
				var tab = new TabItem(UiSettingsTab.KEY, "Settings", settings.content(paneId), true, IconName.Settings);
				tab.onClose = function() host.closeTab(item, paneId, true);
				items.push(tab); continue;
			}
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
    tooltips.set(key, SessionFolderChooser.tooltip(agent.title, sessionFolder(agent.resource, agent.workspaceRoot, false)));
    tab.onClose=function() host.closeTab(item,paneId,true);
    items.push(tab);continue;
   }
			var workspaceFile = UiEditorTabs.workspaceFile(item);
			if (workspaceFile != null) {
				var fileKey = UiEditorTabs.key(item);
				var fileTab = new TabItem(fileKey,
					workspaceFile.title + (workspaceFile.preview ? " (preview)" : ""),
					new WorkspaceFilePreviewView(workspaceFile, theme, editorPalette,
						function() remoteFileTabs.refreshWorkspaceFile(workspaceFile), application.settings.current.fontSize), true);
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
					function(bounds, id) host.editorResolved(paneId, bounds, id),
					function(event) terminalTabs.showTerminalContextMenu(terminal, event), terminalTabs.terminalCommandSkipsShell), true, IconName.Terminal);
				terminalTab.onClose = function() host.closeTab(item, paneId, true);
				tooltips.set(terminalKey, SessionFolderChooser.tooltip(terminal.title, terminal.remote
					? sessionFolder(terminal.resourceId, terminal.workspaceRoot, true) : terminal.cwd));
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
			configureDocumentPane(documentView, paneId);
			// The pane's own changes (scroll, reveal, search marks, definition underline) run only this scope again; see documentContent.
			var content = new TrackedScope("document-scope:" + documentView.id, function() return documentContent(documentView, paneId));
			var documentKey = UiEditorTabs.key(item);
			filenames.set(documentKey, diffDocument == null ? document.title : diffDocument.path);
			var title = diffDocument == null ? (document.dirty ? "* " : "") + document.title :
				documentView.sideBySideDiff ? document.title : haxe.io.Path.withoutDirectory(diffDocument.path) + " (diff)";
			// A document's tab shows only the file's name; its tooltip says where the file is.
			if (diffDocument == null && document.path != null)
				tooltips.set(documentKey, document.path.indexOf("\\") >= 0 ? StringTools.replace(document.path, "/", "\\") : document.path);
			if (diffDocument != null) {
				var path = diffDocument.path;
				var source = sourceControl.editorSourceControlSource();
				if (source != null) for (repository in source.repositories())
					if (repository.id == diffDocument.repositoryId) {
						var relative = ScmPanelController.pathUnderScope(repository.root, path);
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
		// A tab dragged along the strip and dropped on another tab takes that tab's place.
		var headers:Map<String, RenderNode> = new Map();
		options.onTabDragEnd = function(key, event) {
			for (target => node in headers) {
				if (target == key) continue;
				var bounds = node.globalBounds();
				if (event.globalX >= bounds.x && event.globalX < bounds.x + bounds.width
					&& event.globalY >= bounds.y - 12 && event.globalY < bounds.y + bounds.height + 12) {
					host.moveEditorTab(paneId, key, target);
					return;
				}
			}
		};
		var widget = Tabs.withOptions("exosuit-editor-tabs:" + paneId, items, active == null ? "" : UiEditorTabs.key(active),
			function(key) host.activateEditorTab(key, paneId), options);
		widget.onTabHeaderBuilt = function(key, node) {
			headers.set(key, node);
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
				terminalTabs.showTerminalContextMenu(terminal, event);
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

	/**
		Sets up the editor pane of one document tab from the current settings, language and host state, making the pane the
		first time. editorPanel runs it for every document tab of a pane in each root build, and documentContent again for the
		tab it shows, so a frame in which only that scope runs sees current semantic tokens and indentation.
	**/
	function configureDocumentPane(documentView:UiDocumentView, paneId:String):EditorPane {
		var document = documentView.document;
		var diffDocument = documentView.diffDocument;
		// Reused across frames (not rebuilt each `view()` call) so its
		// `BufferSelection` (shared with `documentView`, see `UiDocumentView`'s
		// doc comment) persists between edits instead of resetting.
		var pane = editorPanes.get(documentView.id);
		if (pane == null) {
			// Its own state (the definition underline) runs its scope again; what it edits, the detector sees before the frame.
			pane = new EditorPane(document, theme, documentView.invalidate, documentView.selection, editorPalette,
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
		return pane;
	}

	/**
		The body of a document tab's scope: breadcrumbs over the editor pane. It runs in every root build that builds the tab,
		and alone when the view's `presentation` or `editing` signal moves (RootChangeDetector before a frame, or the pane
		itself).
	**/
	function documentContent(documentView:UiDocumentView, paneId:String):View {
		// The reads are the subscriptions.
		documentView.presentation.value;
		documentView.editing.value;
		var document = documentView.document;
		var diffDocument = documentView.diffDocument;
		var pane = configureDocumentPane(documentView, paneId);
		var breadcrumbRoot:Null<String> = null;
		if (document.path != null) for (project in application.workspace.projects) {
			var root = StringTools.replace(project.root, "\\", "/");
			var path = StringTools.replace(document.path, "\\", "/");
			var prefix = StringTools.endsWith(root, "/") ? root : root + "/";
			if (StringTools.startsWith(path, prefix) && (breadcrumbRoot == null || root.length > breadcrumbRoot.length))
				breadcrumbRoot = root;
		}
		// The file explorer can also own a local folder outside a saved workspace.
		if (breadcrumbRoot == null && document.path != null && explorerRoot != null) {
			var root = StringTools.replace(explorerRoot, "\\", "/");
			var path = StringTools.replace(document.path, "\\", "/");
			var prefix = StringTools.endsWith(root, "/") ? root : root + "/";
			if (StringTools.startsWith(path, prefix)) breadcrumbRoot = root;
		}
		var contentStyle = new LayoutStyle();
		// Stretch, as Tabs sets on the panel content it builds: when this scope runs alone, its new root keeps it.
		contentStyle.width = LayoutAxis.stretch();
		contentStyle.height = LayoutAxis.grow();
		var contentItems:Array<KeyedView> = [];
		if (diffDocument == null) contentItems.push(new KeyedView("breadcrumbs", new EditorBreadcrumbs(document, breadcrumbRoot,
			theme.tokens.textSecondary, Color.fromBytes((editorPalette.editorBackground >>> 24) & 255,
				(editorPalette.editorBackground >>> 16) & 255, (editorPalette.editorBackground >>> 8) & 255,
				editorPalette.editorBackground & 255), darkPalette,
			function(path, event) showBreadcrumbMenu(document, paneId, path, event))));
		contentItems.push(new KeyedView("editor", pane));
		return new Column("document-content:" + documentView.id, contentItems, contentStyle);
	}

	function showBreadcrumbMenu(document:editor.Document, paneId:String, path:String, event:UiEvent):Void {
		var directory = haxe.io.Path.directory(path);
		var items:Array<MenuItem> = [];
		try {
			var entries = FileSystem.readDirectory(directory);
			entries.sort(function(a, b) {
				var ad = FileSystem.isDirectory(directory + "/" + a), bd = FileSystem.isDirectory(directory + "/" + b);
				return ad != bd ? (ad ? -1 : 1) : Reflect.compare(a.toLowerCase(), b.toLowerCase());
			});
			for (name in entries) {
				var target = directory + "/" + name;
				var folder = FileSystem.isDirectory(target);
				items.push(new MenuItem(target, name + (folder ? "  ›" : ""), function() {
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
			settingsTab.openSettings();
			settingsPanel.setShowAdvanced(advanced);
			if (category != null) settingsPanel.select(category);
		};
		var actions = [
			new MenuItem("manage-palette", "Command Palette…", togglePalette,
				true, shortcut("view.toggle-palette")),
			new MenuItem("manage-settings", "Settings", settingsTab.openSettings,
				true, shortcut("preferences.open"), true),
			new MenuItem("manage-keyboard", "Keyboard Shortcuts",
				function() openPreferences("editor/keyboard", true)),
			new MenuItem("manage-themes", "Themes…",
				function() openPreferences("appearance/colors", true))
		];
		for (item in activityMenu.items(null)) actions.push(item);
		if (host.isCommandViewActive()) host.closeCommandView();
		host.dismissLanguagePopup();
		manageMenu = new CommandMenu(application.commands, application.context, [], x, y, function() return true,
			function() { contextMenu = null; requestFrame(); }, actions, menuOpenedWithKeyboard(event));
		contextMenu = manageMenu;
		requestFrame();
	}

	/** Stores the rail's shown destinations and order for every window (see ActivityRailPreference). */
	function saveActivityBar(value:String):Void {
		application.settings.store.set("appearance/workbench/activity_bar", haxeon.ui.properties.PropertyValue.Text(value));
	}

	function showActivityBarMenu(id:Null<String>, event:UiEvent):Void {
		var anchor = contextMenuAnchor(event);
		if (host.isCommandViewActive()) host.closeCommandView();
		host.dismissLanguagePopup();
		contextMenu = new CommandMenu(application.commands, application.context, [], anchor.x, anchor.y,
			function() return true, function() { contextMenu = null; requestFrame(); }, activityMenu.items(id),
			menuOpenedWithKeyboard(event));
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
		var newButton = new Button("New File", null, function() application.newDocument(), "welcome-new", null, ButtonVariant.Primary);
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
			items.push(new KeyedView("add-folder", new Button("Add Folder to Workspace…", null, application.savedWorkspaces.addPicker, "welcome-add-folder")));
			if (application.savedWorkspaces.isOpen())
				items.push(new KeyedView("close-workspace", new Button("Close Workspace", null, function() {
					application.savedWorkspaces.close(); requestFrame();
				}, "welcome-close-workspace")));
		}
		if (actions != null && actions.recentProjects.length > 0) {
			var recentStyle = new LayoutStyle();
			recentStyle.width = LayoutAxis.grow();
			recentStyle.direction = LayoutDirection.TopToBottom;
			recentStyle.childGap = 4.0;
			var recentRows:Array<KeyedView> = [];
			for (index in 0...actions.recentProjects.length) {
				var path = actions.recentProjects[index];
				// A folder path can be wider than the editor area: the button fills at most the panel and the path ellipsizes in the middle.
				var buttonStyle = new LayoutStyle();
				buttonStyle.width = LayoutAxis.grow(0, path.length * 8.0 + 32); buttonStyle.clipHorizontal = true;
				var recent = new Button(path, buttonStyle, function() actions.openRecent(path), "welcome-recent-" + index, null, null, null,
					null, null, null, null, null, new haxeon.ui.widgets.text.MiddleEllipsisText("welcome-recent-label", path, true,
						new TextStyleOverride(null, null, null, haxeon.ui.TextWrap.None)), null, null, path);
				recentRows.push(new KeyedView("recent" + index, recent));
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

	/**
		A folder opens as a workspace (`openFolderWorkspace`, once the window polls); a file opens in a tab, with the
		cursor on `line` and `column` (1-based) when given.
	**/
	@:allow(app.GraphicalMain)
	function openArgument(path:String, ?line:Int, ?column:Int):Void {
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
		var view = application.openArgument(path);
		if (view != null && line != null && line > 0) {
			view.restoreCursor(line - 1, column == null || column < 1 ? 0 : column - 1);
			view.cursorChanged();
		}
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
			if (accepted && paths.length > 0) openArgument(paths[0]);
			requestFrame();
		});
	}

	function togglePalette():Void {
		contextMenu = null;
		application.workbench.openCommandView();
		requestFrame();
	}

	function paletteEntries():Array<commandview.CommandViewEntry> {
		// Include domain commands registered after startup (for example by plugins, or by a live patch).
		installChatCommands();
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

	function closePhoneSidebarAfterOpen():Void {
		if (phoneLayoutActive && sidebar.visible) sidebar.setVisible(false);
	}

	function findDocument(path:String):Null<editor.Document> {
		var normalized = normalizedPath(path);
		for (document in application.documents.documents) if (document.path != null && PathKey.same(normalizedPath(document.path), normalized)) return document;
		return null;
	}

	/** An open document whose folder was deleted or renamed cannot be normalized; compare it as written rather than fail the lookup. */
	function normalizedPath(path:String):String return try application.workspace.fileSystem.normalize(path) catch (_:Dynamic) path;

	/** The host calls this after each frame it renders. */
	public function frameRendered():Void
		frameRateMeter().frameRendered();

	function frameRateMeter():FrameRateMeter {
		var meter = frameRate;
		if (meter == null) frameRate = meter = new FrameRateMeter();
		return meter;
	}

	/**
		Invalidate application views as well as scheduling a host render: the next frame is a full root build. On the UI
		thread and never inside a build (a tracked write there throws); a caller that runs in a build fixes its call site.
	**/
	public function requestFrame():Void {
		frameTick.value = frameTick.value + 1;
		scheduleFrame();
	}

	/**
		Schedule a host render without invalidating anything. For writes to tracked sources whose readers are the root or
		retained builds, which do not ask for a frame themselves (a poll, a timer, a callback).
	**/
	public function scheduleFrame():Void {
		if (hostContext != null) hostContext.requestFrame();
	}
}

/** A document's resolved repository, with the snapshot scan cached so unchanged state costs nothing per poll. */
private typedef ScmMarkerTarget = {
	final path:String;
	final sourceIdentity:String;
	final repositories:Array<scm.ScmRepository>;
	final repository:Null<scm.ScmRepository>;
	final relative:Null<String>;
	final identity:String;
	var snapshot:Null<scm.ScmSnapshot>;
	var untracked:Bool;
	var worktree:Bool;
}

/**
	The side bar, whose header actions show while the pointer is over it or the keyboard is in it
	(`SidebarHost.headerActionsVisible`, read while building). Hover and focus alone change only how nodes look, which
	haxeon updates without a build, so when entering, leaving, focusing or blurring changes whether they show, the side
	bar asks for one.
**/
private class SidebarHoverRebuild implements View {
	final host:haxeon.ui.widgets.sidebar.SidebarHost;
	final rebuild:Void->Void;

	public function new(host:haxeon.ui.widgets.sidebar.SidebarHost, rebuild:Void->Void) {
		this.host = host;
		this.rebuild = rebuild;
	}

	public function build(context:haxeon.ui.core.BuildContext):RenderNode {
		var node = host.build(context);
		var visible = host.headerActionsVisible;
		if (visible == null) return node;
		var shown = visible(node);
		var changed = function(_:UiEvent) {
			if (visible(node) != shown) { shown = !shown; rebuild(); }
		};
		node.on(UiEventKind.HoverEnter, changed, haxeon.ui.core.UiEventPhase.Target);
		node.on(UiEventKind.HoverLeave, changed, haxeon.ui.core.UiEventPhase.Target);
		node.on(UiEventKind.Focus, changed, haxeon.ui.core.UiEventPhase.Capture);
		node.on(UiEventKind.Blur, changed, haxeon.ui.core.UiEventPhase.Capture);
		return node;
	}
}
