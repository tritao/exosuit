package ui.shell;

import haxeon.ui.core.View;
import haxeon.ui.docking.DockNodeTools;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.docking.DockPanelContent;
import haxeon.ui.widgets.docking.DockWorkspace;
import haxeon.ui.widgets.layout.AppShell;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.MenuItem;
import ui.ActivityBar;
import ui.CommandMenu;
import ui.ExosuitApp;
import ui.UiEditorTab;
import ui.UiEditorTabs;
import ui.UiEditorPane;
import ui.WorkbenchSurface;
import ui.shell.Shell;

/**
	Today's window (ADR 0007): the activity rail, the dock with its tab strips, the title bar and the status bar, and the
	ResponsiveLayout that makes the dock follow the window's width. The code moved here from ExosuitApp without a
	change in behaviour; it still reads the application's dock, sidebar and layout state (ExosuitApp allows this class
	to), which the core keeps because documents, terminals and sessions live in the dock's panes.
**/
class DesktopShell implements Shell {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	public function kind():ShellKind return Desktop;

	/** The tab with this id: its key, or the id of the agent session or terminal it shows. */
	function find(id:String):Null<{item:UiEditorTab, pane:UiEditorPane}> {
		for (pane in app.host.panes) for (item in pane.items) {
			var agent = UiEditorTabs.agent(item);
			var terminal = UiEditorTabs.terminal(item);
			if (UiEditorTabs.key(item) == id || agent != null && (agent.resource == id || agent.id == id)
				|| terminal != null && terminal.id == id) return {item: item, pane: pane};
		}
		return null;
	}

	/** A sidebar destination (files, search, workbench...) shows in the sidebar; any other id is an open tab. */
	public function open(view:ShellView):Void
		focus(view.id);

	public function focus(id:String):Void {
		if (app.sidebar.find(id) != null) {
			app.showSidebarMode(id);
			return;
		}
		var found = find(id);
		if (found != null) app.host.activateEditorTab(UiEditorTabs.key(found.item), found.pane.id);
		app.requestFrame();
	}

	public function close(id:String):Void {
		var found = find(id);
		if (found != null) app.host.closeTab(found.item, found.pane.id, false);
		app.requestFrame();
	}

	/** The active tab of the active editor group; with none, the sidebar destination shown. */
	public function focusedView():Null<String> {
		var tab = app.host.activeTab();
		if (tab != null) {
			var agent = UiEditorTabs.agent(tab);
			if (agent != null) return agent.resource;
			var terminal = UiEditorTabs.terminal(tab);
			return terminal != null ? terminal.id : UiEditorTabs.key(tab);
		}
		return app.sidebar.visible && app.sidebar.activeId != "" ? app.sidebar.activeId : null;
	}

	/** The status bar shows the notice; it has no action there. */
	public function notice(text:String, ?actionLabel:String, ?action:Void->Void):Void {
		app.statusMessage = text;
		app.requestFrame();
	}

	/** A menu below the title bar. A multiple choice toggles the picked entry and reports the new selection. */
	public function choose(title:String, choices:Array<ShellChoice>, selected:Array<String>, multi:Bool,
			done:Array<String>->Void):Void {
		var items:Array<MenuItem> = [];
		for (choice in choices) {
			var picked = choice;
			var label = (selected.indexOf(picked.id) >= 0 ? "✓ " : "") + picked.label;
			items.push(new MenuItem(picked.id, label, function() {
				app.contextMenu = null;
				var result = [picked.id];
				if (multi) {
					result = selected.copy();
					if (!result.remove(picked.id)) result.push(picked.id);
				}
				done(result);
				app.requestFrame();
			}));
		}
		var x = Math.max(0, app.viewportWidth / 2 - 120), y = ExosuitApp.TOOLBAR_HEIGHT + 4;
		app.contextMenu = new CommandMenu(app.application.commands, app.application.context, [], x, y,
			function() return true, function() { app.contextMenu = null; app.requestFrame(); }, items, true);
		app.requestFrame();
	}

	/** The window's layout followed to its width, once per frame before the build (this was ExosuitApp.submit's). */
	public function fitWindow(widthChanged:Bool):Void {
		app.layoutModes.suspend();
		app.responsive.syncResponsiveDockLayout();
		app.keepSidebarFullHeight();
		if (widthChanged && !app.phoneLayoutActive && app.dock.isOpen("explorer")) {
			var mode = app.sidebar.selected();
			if (mode != null) app.dock.setPanelWidth("explorer", app.sidebar.width, app.workbenchAvailableWidth(),
				DockWorkspace.DividerExtent, DockWorkspace.MinimumHorizontalExtent);
		}
		app.responsive.syncResponsiveRightLayout();
		app.layoutModes.resume();
	}

	/** The dock, rail, title bar and status bar (this was the first half of ExosuitApp.view). */
	public function build():View {
		for (pane in app.host.panes) {
			var found = false;
			for (content in app.dockPanelContents) if (content.panelId == pane.id) { found = true; break; }
			if (!found) {
				var paneId = pane.id;
				app.dockPanelContents.push(new DockPanelContent(paneId, function(_) return app.editorPanel(paneId)));
			}
		}
		var workspaceView = new DockWorkspace("exosuit-workspace", app.dock, app.dockPanelContents);
		workspaceView.headerActions = function(ids, _) return app.layoutControls.isToolGroup(ids) ? app.bottomPanelActions() : null;
		workspaceView.headerActionsRevision = Std.string(app.layoutControls.bottomMaximized);
		workspaceView.expandedGroup = app.layoutControls.expandedPanels();
		workspaceView.hiddenPanels = app.responsiveRightHidden ? ["context-panel"] : [];
		var surfaceInset = app.phoneLayoutActive ? 0.0 : WorkbenchSurface.INSET * 2;
		workspaceView.availableWidth = app.workbenchAvailableWidth();
		workspaceView.availableHeight = Math.max(0.0,
			app.viewportHeight - ExosuitApp.TOOLBAR_HEIGHT - ExosuitApp.STATUS_HEIGHT - surfaceInset);
		var activityBar = new ActivityBar(app.sidebar, app.activityIcons, app.activateSidebarDestination,
			app.application.settings.current.tabTooltipDelay, app.showManageMenu,
			app.manageMenu != null && app.contextMenu == app.manageMenu);
		activityBar.onContextMenu = app.showActivityBarMenu;
		activityBar.onMove = app.activityMenu.move;
		activityBar.hiddenIds = app.layoutModes.hiddenOnRail();
		var workspace:View = new Row("workspace-with-activity-bar", [
			new KeyedView("activity-bar", activityBar),
			new KeyedView("workspace:" + app.host.layoutContextKey,
				app.phoneLayoutActive ? workspaceView : new WorkbenchSurface(workspaceView))
		], ExosuitApp.fillStyle());
		var body = new Column("exosuit-body", [
			new KeyedView("workspace", workspace),
			new KeyedView("status", app.statusBar())
		], ExosuitApp.fillStyle());
		var shellStyle = ExosuitApp.fillStyle();
		shellStyle.background = app.theme.tokens.surface;
		return new AppShell("exosuit-shell", body, app.topBar(), null, null, shellStyle);
	}

	public function dispose():Void {}
}
