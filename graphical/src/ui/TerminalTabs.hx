package ui;


import haxeon.ui.widgets.overlays.MenuItem;



import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import sys.FileSystem;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.docking.DockDropZone;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabsOptions;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import feedback.NotificationKind;

/**
	The window's terminal tabs: making, restoring and placing them (in the editor or the bottom panel), the panel's
	terminal list, a workspace terminal's tab and context menu, and polling them. ExosuitApp owns one.
**/
@:allow(ui)
class TerminalTabs {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	var nextTerminalId:Int = 1;
	final terminalErrors:Map<String, String> = [];
	function terminalUiAvailable():Bool return app.createTerminal != null || app.createWorkspaceTerminal != null;
	/**
		Why no terminal can be made now: in the workspace the window shows, or in the one `other` is the link of. A remote
		attachment must never fall back to a browser/local shell.
	**/
	public function terminalCreationFailure(?other:workspace.client.WorkspaceWorkbenchClient):Null<String> {
		var client = other != null ? other : app.workbenchClient;
		if (client != null) {
			if (app.createWorkspaceTerminal == null) return "This host cannot display workspace terminals";
			if (!client.canReadTerminals()) return "Workspace disconnected or terminal read permission was not granted";
			if (!client.canControlTerminals()) return "Terminal creation requires terminal control permission";
			if (!client.canCreateTerminals()) return "Terminal creation is unavailable for this workspace";
			return null;
		}
		if (app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess())
			return "Connect to a workspace with terminal control permission";
		return app.capabilities.supports(Processes) && terminalUiAvailable() ? null : "Connect to a workspace to create a terminal";
	}
	function canCreateTerminal():Bool return terminalCreationFailure() == null;
	function canShowTerminal():Bool return app.host.activePanelTerminal() != null || canCreateTerminal();
	function activeTerminal():Null<UiTerminalTab> {
		var active = app.host.activeTab(), terminal = active == null ? null : UiEditorTabs.terminal(active);
		return terminal == null ? app.host.activePanelTerminal() : terminal;
	}
	function terminalPaneOf(terminal:Null<UiTerminalTab>):Null<TerminalPane>
		return terminal == null || terminal.disposed ? null : Std.downcast(terminal.panel, TerminalPane);
	function canCopyTerminalSelection():Bool {
		var pane = terminalPaneOf(activeTerminal());
		return pane != null && pane.selectedText() != null;
	}
	function copyTerminalSelection():Void {
		var pane = terminalPaneOf(activeTerminal());
		if (pane != null) pane.copySelection(app.ui.buildContext.clipboard);
	}
	function canTerminateTerminal():Bool {
		var terminal = activeTerminal();
		return terminal != null && (!terminal.remote || (app.workbenchClient != null && app.workbenchClient.canControlTerminals()));
	}
	public function newTerminal():Void {
		var terminal = newTerminalTab();
		if (terminal == null) return;
		if (app.sidebar.activeId == "workbench") showTerminalInEditor(terminal);
		else {
			app.host.panelTerminals.push(terminal);
			app.host.activePanelTerminalIndex = app.host.panelTerminals.length - 1;
			openTerminalPanel();
		}
	}
	public function openTerminal():Void {
        if (app.sidebar.activeId == "workbench") {
            var terminal = newTerminalTab();
            if (terminal != null) showTerminalInEditor(terminal);
            return;
        }
        openTerminalPanel();
    }
    function openTerminalPanel():Void {
		if (!terminalUiAvailable()) return;
		if (app.host.panelTerminals.length == 0) {
			var terminal = newTerminalTab();
			if (terminal == null) return;
			app.host.panelTerminals.push(terminal);
			app.host.activePanelTerminalIndex = 0;
		}
		if (!app.layoutControls.bottomOpen()) app.layoutControls.toggleBottom();
		if (!app.dock.isOpen("terminal")) {
			if (app.dock.isOpen("build")) app.dock.open("terminal", "build");
			else if (app.dock.isOpen("problems")) app.dock.open("terminal", "problems");
			else app.dock.dock("terminal", app.host.activePane.id, DockDropZone.Bottom);
		}
		app.dock.activate("terminal");
		app.pendingTerminalFocus = true;
		app.requestFrame();
	}
    function showTerminalInEditor(terminal:UiTerminalTab):Void {
        terminal.retainOnClose = true;
        app.host.attachTerminal(terminal);
        if (app.phoneLayoutActive && app.sidebar.visible) app.sidebar.setVisible(false);
        if (app.workbenchPanel != null && app.sidebar.activeId == "workbench") app.workbenchPanel.revealNode(terminalRow(terminal));
        app.dock.close("terminal");
        app.pendingTerminalFocus = false;
        app.requestFrame();
    }
	/**
		A new terminal in a tab here, in `group`: of the workspace the window shows, or of workspace `workspaceId` (New
		Terminal on its row), whose link the window holds and which keeps the terminal.
	**/
	function newTerminalTab(?group:String, ?agentProvider:String, ?directory:String, ?workspaceId:String):Null<UiTerminalTab> {
		var here = workspaceId == null;
		var client = here ? app.workbenchClient : app.linkOf(workspaceId);
		if (!here && client == null) { app.application.reportError("terminal", "Workspace is not connected"); return null; }
		var failure = terminalCreationFailure(client);
		if (failure != null) { app.application.reportError("terminal", failure); return null; }
		if (client != null) {
			var catalog = client.terminalCatalog();
			var root = here && app.workspaceAttachment != null ? app.workspaceAttachment.fileScope() : null;
			if (root == null && catalog != null) root = catalog.workspaceRoot;
			if (root == null) { app.application.reportError("terminal", "Workspace is not connected"); return null; }
			var inContext = here && app.application.activeContext.kind == workspace.ContextKind.Group;
			if (group == null && inContext) group = app.application.activeContext.id;
			// The service puts a terminal with no group at the workspace root,
			// and resolves the group's inherited directory against the workspace root.
			if (!client.canCreateGroupedTerminals()) group = null;
			var cwd = inContext ? app.application.activeContext.cwd : root;
			var shown = app.workbenchPanel == null ? null : app.workbenchPanel.model;
			var id = here ? (shown == null ? null : shown.openWorkspace) : workspaceId;
			if (shown != null && id != null) {
				var rows = shown.rows(id), selected = group == null || rows == null ? null : rows.groups.get(group);
				var folder = selected != null ? shown.directory(id, selected) : here ? null : shown.firstFolder(id);
				if (folder != null) cwd = folder;
			}
			if (directory != null) cwd = directory;
			var resource = workspace.client.WorkspaceIds.create("workspace-terminal");
			return createTerminalTab(ResourceViewIdentity.view(root, resource), agentProvider == null ? "Terminal" : agentProvider,
				cwd, false, true, resource, root, group, directory, agentProvider);
		}
		var number = allocateTerminalNumber(), title = "Terminal " + number;
		var id = app.createWorkspaceTerminal != null && app.application.workspace.activeProject != null
			? workspace.client.WorkspaceIds.create("workspace-terminal") : "terminal-" + number;
		return createTerminalTab(id, title, app.application.activeContext.cwd, false);
	}
	function allocateTerminalNumber():Int {
		var used:Map<String, Bool> = [];
		for (terminal in app.host.allTerminalTabs()) if (!terminal.disposed) used.set(terminal.title, true);
		var catalog = app.workbenchClient == null ? null : app.workbenchClient.terminalCatalog();
		if (catalog != null) for (record in catalog.terminals) used.set(record.name, true);
		while (used.exists("Terminal " + nextTerminalId) || app.host.terminalNumberInUse(nextTerminalId)) nextTerminalId++;
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
			for (existing in app.host.allTerminalTabs()) if (!existing.disposed && existing.title == title) {
				title = "Terminal " + allocateTerminalNumber();
				break;
			}
		}
		var create = app.createTerminal;
		var remote = app.createWorkspaceTerminal;
		if (isRemote ? remote == null : create == null) return null;
		// A terminal of a workspace with a service of its own belongs to that service, whichever of the workspace's
		// folders it was made under: the service names its own root. That is the folder the running service started in
		// (a scratch folder, say, before a folder was attached), once this window is attached to it.
		if (isRemote && workspaceRoot != null) {
			var service = app.terminalServiceTarget(workspaceRoot), serviceRoot = service == null ? null : service.root();
			var all = app.links;
			if (service != null && all != null) {
				var link = all.get(service.workspace);
				if (link != null && link.servedWorkspace() == service.workspace && link.rootPath() != null) serviceRoot = link.rootPath();
			}
			if (serviceRoot != null) workspaceRoot = serviceRoot;
		}
		var number = StringTools.startsWith(id, "terminal-") ? Std.parseInt(id.substring(9)) : null;
		if (number != null && number >= nextTerminalId) nextTerminalId = number + 1;
		var localDirectory = isRemote ? cwd : FileSystem.exists(cwd) && FileSystem.isDirectory(cwd) ? cwd : Sys.getCwd();
		try {
			var panel:TerminalPanel;
			if (remote != null && isRemote)
				panel = remote(resource == null ? id : resource, workspaceRoot == null ? cwd : workspaceRoot,
					restored, app.requestFrame, app.terminalPalette, group, directory);
			else if (create != null)
				panel = create(localDirectory, app.requestFrame, app.terminalPalette);
			else
				return null;
			if (agentProvider != null) {
				if (!Std.isOfType(panel, AgentTerminalPanel)) { panel.close(); throw "This terminal host cannot launch agent CLIs"; }
				var agentPanel:AgentTerminalPanel = cast panel;
				try agentPanel.configureAgent(agentProvider) catch (failure:Dynamic) { panel.close(); throw failure; }
			}
			return new UiTerminalTab(id, title, cwd, panel,isRemote,resource,workspaceRoot);
		} catch (error:Dynamic) {
			app.statusMessage = "Terminal: " + Std.string(error);
			app.application.reportError("terminal", Std.string(error));
			return null;
		}
	}
	public function moveTerminalToEditor():Bool {
        if (app.sidebar.activeId == "workbench") {
            var existing = app.host.activePanelTerminal();
            if (existing != null) showTerminalInEditor(existing);
            else if (app.host.activeTab() == null || UiEditorTabs.terminal(app.host.activeTab()) == null) openTerminal();
            return app.host.activeTab() != null && UiEditorTabs.terminal(app.host.activeTab()) != null;
        }
		openTerminalPanel();
		var terminal = app.host.activePanelTerminal();
		if (terminal == null) return false;
		app.host.panelTerminals.splice(app.host.activePanelTerminalIndex, 1);
		app.host.activePanelTerminalIndex = Std.int(Math.min(app.host.activePanelTerminalIndex, app.host.panelTerminals.length - 1));
		if (app.host.panelTerminals.length == 0) app.dock.close("terminal");
		app.host.attachTerminal(terminal);
		app.pendingTerminalFocus = false;
		app.requestFrame();
		return true;
	}
	public function moveTerminalToPanel():Bool {
		var item = app.host.activeTab();
		var terminal = item == null ? null : UiEditorTabs.terminal(item);
		if (terminal == null || !app.host.detachTerminal(terminal)) return false;
		app.host.panelTerminals.push(terminal);
		app.host.activePanelTerminalIndex = app.host.panelTerminals.length - 1;
		openTerminalPanel();
		return true;
	}
	function toggleTerminal():Void {
		if (app.dock.isOpen("terminal")) {
			app.dock.close("terminal");
			app.requestFrame();
		} else openTerminal();
	}
	function terminalCommandSkipsShell(id:String):Bool
		return TerminalShortcutPolicy.allows(id, app.application.settings.current.terminalCommandsToSkipShell);
	function terminalPanel():View {
		if (app.host.panelTerminals.length == 0) return app.placeholderPanel("Terminal is closed.");
		var items:Array<TabItem> = [];
		for (terminal in app.host.panelTerminals) {
			var view = new TerminalTabView(terminal, function() {
				app.host.deactivateDocumentFocus();
			}, function(_, id) {
				if (app.pendingTerminalFocus && app.host.activePanelTerminal() == terminal) {
					app.ui.buildContext.requestFocusAfterLayout(id);
					app.pendingTerminalFocus = false;
					app.requestFrame();
				}
			}, function(event) {
				app.host.activePanelTerminalIndex = app.host.panelTerminals.indexOf(terminal);
				showTerminalContextMenu(terminal, event);
			}, terminalCommandSkipsShell);
			if (app.host.panelTerminals.length == 1) return view;
			items.push(new TabItem("terminal:" + terminal.id, terminal.title, view));
		}
		var options = terminalTabsOptions();
		options.onTabContextMenu = function(key, event) {
			for (terminal in app.host.panelTerminals) if (key == "terminal:" + terminal.id) {
				app.host.activePanelTerminalIndex = app.host.panelTerminals.indexOf(terminal);
				showTerminalContextMenu(terminal, event);
				return;
			}
		};
		var active = app.host.activePanelTerminal();
		return Tabs.withOptions("terminal-sessions", items, active == null ? "" : "terminal:" + active.id, function(key) {
			for (index in 0...app.host.panelTerminals.length) if (key == "terminal:" + app.host.panelTerminals[index].id) {
				app.host.activePanelTerminalIndex = index;
				app.pendingTerminalFocus = true;
				app.requestFrame();
			}
		}, options);
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
	/** The row of a terminal tab: in the workspace whose service holds its root, else the one the window shows. */
	function terminalRow(terminal:UiTerminalTab):String {
		var target = terminal.workspaceRoot == null ? null : app.terminalServiceTarget(terminal.workspaceRoot);
		var id = target != null ? target.workspace : app.workbenchActions.currentWorkspace();
		return WorkbenchRowKey.terminal(id == null ? "" : id, terminal.resourceId);
	}
	/** New Terminal on a row of workspace `id`, in a tab here; a workspace the window does not show keeps the terminal. */
	function newGroupedTerminal(id:String, group:String):Void {
		var terminal = newTerminalTab(group, null, null, id == "" || id == app.workbenchActions.currentWorkspace() ? null : id);
		if (terminal != null) showTerminalInEditor(terminal);
	}
	public function openWorkspaceTerminals():Void {
		app.showSidebarMode("workbench");
		if (app.workbenchClient != null) app.workbenchClient.refreshTerminals(true);
		app.requestFrame();
	}
	/** Opens catalog terminal `record` of the workspace `client` is the link of in a tab here, or shows its tab. */
	public function openCatalogTerminal(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Bool {
		if (!client.canReadTerminals() || !record.available) return false;
		for (tab in app.host.allTerminalTabs()) if (tab.resourceId == record.id && tab.workspaceRoot == record.workspaceRoot && tab.remote && !tab.disposed) {
			tab.updateWorkspaceName(record.name);
			var pane = app.host.terminalPaneFor(tab);
			if (app.sidebar.activeId == "workbench") showTerminalInEditor(tab);
            else if (pane != null) app.host.attachTerminal(tab);
			else {
                app.host.hiddenTerminals.remove(tab);
                if (app.host.panelTerminals.indexOf(tab) < 0) app.host.panelTerminals.push(tab);
				app.host.activePanelTerminalIndex = app.host.panelTerminals.indexOf(tab);
				app.dock.open("terminal");
				app.dock.activate("terminal");
				app.pendingTerminalFocus = true;
			}
			app.requestFrame();
			return true;
		}
		var terminal = createTerminalTab(ResourceViewIdentity.view(record.workspaceRoot == null ? record.cwd : record.workspaceRoot, record.id), record.name, record.cwd, true, true, record.id, record.workspaceRoot);
		if (terminal == null) return false;
        if (app.sidebar.activeId == "workbench") { showTerminalInEditor(terminal); return true; }
		app.host.panelTerminals.push(terminal);
		app.host.activePanelTerminalIndex = app.host.panelTerminals.length - 1;
		app.dock.open("terminal");
		app.dock.activate("terminal");
		app.pendingTerminalFocus = true;
		app.requestFrame();
		return true;
	}
	function currentCatalogTerminal(client:Null<workspace.client.WorkspaceWorkbenchClient>, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord, ?owner:String):Bool
		return TerminalContextActions.isCurrent(record, client == null ? null : client.terminalCatalog(), owner);
	static function matchesCatalogTerminal(tab:UiTerminalTab, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Bool
		return tab.remote && !tab.disposed && tab.resourceId == record.id &&
			tab.workspaceRoot == (record.workspaceRoot == null ? record.cwd : record.workspaceRoot);
	function placeTerminal(terminal:UiTerminalTab, editor:Bool):Void {
		if (terminal.disposed) return;
		if (editor) {
			app.host.attachTerminal(terminal);
			if (app.host.panelTerminals.length == 0) app.dock.close("terminal");
			app.pendingTerminalFocus = false;
		} else {
			app.host.detachTerminal(terminal);
			app.host.hiddenTerminals.remove(terminal);
			if (app.host.panelTerminals.indexOf(terminal) < 0) app.host.panelTerminals.push(terminal);
			app.host.activePanelTerminalIndex = app.host.panelTerminals.indexOf(terminal);
			openTerminalPanel();
		}
		app.requestFrame();
	}
	function closeTerminalView(terminal:UiTerminalTab):Void {
		var pane = app.host.terminalPaneFor(terminal);
		if (pane != null) {
			for (item in pane.items) if (UiEditorTabs.terminal(item) == terminal) { app.host.closeTab(item, pane.id, true); break; }
		} else {
			var index = app.host.panelTerminals.indexOf(terminal);
			if (index < 0) return;
			app.host.panelTerminals.splice(index, 1);
			if (index < app.host.activePanelTerminalIndex) app.host.activePanelTerminalIndex--;
			else if (index == app.host.activePanelTerminalIndex)
				app.host.activePanelTerminalIndex = Std.int(Math.min(index, app.host.panelTerminals.length - 1));
			if (terminal.retainOnClose) app.host.hiddenTerminals.push(terminal); else terminal.dispose();
			if (app.host.panelTerminals.length == 0) app.dock.close("terminal");
		}
		app.requestFrame();
	}
	function showTerminalContextMenu(terminal:UiTerminalTab, event:UiEvent):Void {
		var client = terminalClient(terminal);
		if (terminal.remote && client != null) client.refreshTerminals(false);
		var record:Null<workspace.service.WorkspaceTerminalProtocol.TerminalRecord> = null;
		var catalog = client == null ? null : client.terminalCatalog();
		if (catalog != null) for (candidate in catalog.terminals) if (matchesCatalogTerminal(terminal, candidate)) { record = candidate; break; }
		var items:Array<MenuItem> = [];
		var inEditor = app.host.terminalPaneFor(terminal) != null;
		if (record != null && client != null) items = app.workbenchActions.catalogTerminalActions(client, record).filter(function(item)
			return item.key != "terminal-open" && item.key != (inEditor ? "terminal-editor" : "terminal-panel"));
		else {
			if (terminal.remote) items.push(new MenuItem("terminal-unavailable",
				client == null ? "Workspace disconnected" : "Terminal details unavailable", null, false));
			if (!terminal.remote) items.push(new MenuItem("terminal-rename", "Rename Terminal…", function() {
				app.workbenchActions.askText("Rename Terminal", terminal.title, function(name) { if (!terminal.disposed) terminal.title = name; });
			}));
			if (!inEditor) items.push(new MenuItem("terminal-editor", "Move Terminal to Editor", function() placeTerminal(terminal, true)));
			if (inEditor) items.push(new MenuItem("terminal-panel", "Move Terminal to Panel", function() placeTerminal(terminal, false)));
			if (!terminal.remote) items.push(new MenuItem("terminal-stop", "Stop Terminal", function() {
				try terminal.panel.terminate(true) catch (failure:Dynamic) app.application.reportError("terminal", Std.string(failure));
				app.requestFrame();
			}));
		}
		if (!terminal.remote) items.push(new MenuItem("terminal-close", "Close Terminal", function() {
			if (terminal.disposed) return;
			try {
				var state=terminal.panel.status();
				if(state=="running" || state=="starting") terminal.panel.terminate(true);
				terminal.retainOnClose=false;closeTerminalView(terminal);
			} catch (failure:Dynamic) app.application.reportError("terminal",Std.string(failure));
		},true,null,true));
		var pane = terminalPaneOf(terminal);
		if (pane != null && pane.selectedText() != null) {
			var clipboard = app.ui.buildContext.clipboard;
			if (items.length > 0) items[0] = new MenuItem(items[0].key, items[0].label, items[0].onSelect, items[0].enabled, items[0].shortcut, true);
			items.unshift(new MenuItem("terminal-copy", "Copy Selection", function() pane.copySelection(clipboard), true, "Ctrl+Shift+C"));
		}
		var selectedRecord = record;
		var owner = catalog == null ? null : catalog.instance;
		app.workbenchActions.showWorkbenchMenu(items, event, function() return !terminal.disposed &&
			(selectedRecord == null || currentCatalogTerminal(client, selectedRecord, owner)));
	}
	/** The client of a terminal tab's workspace: the link of the workspace whose service holds its root, else the window's. */
	function terminalClient(terminal:UiTerminalTab):Null<workspace.client.WorkspaceWorkbenchClient> {
		var target = terminal.workspaceRoot == null ? null : app.terminalServiceTarget(terminal.workspaceRoot);
		var link = target == null ? null : app.linkOf(target.workspace);
		return link != null ? link : app.workbenchClient;
	}
	function closeCatalogTerminal(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
		if(!client.canControlTerminals()) return;
		client.closeTerminal(record,function() {
			// Dispose views only after the owning service confirms permanent removal.
			for(tab in app.host.allTerminalTabs()) if(matchesCatalogTerminal(tab,record)) {
				tab.retainOnClose=false;
				for(pane in app.host.panes.copy()) for(item in pane.items.copy())
					if(UiEditorTabs.terminal(item)==tab) app.host.closeTab(item,pane.id,true);
				var index=app.host.panelTerminals.indexOf(tab);
				if(index>=0) {
					app.host.panelTerminals.splice(index,1);
					if(index<app.host.activePanelTerminalIndex) app.host.activePanelTerminalIndex--;
					else if(index==app.host.activePanelTerminalIndex) app.host.activePanelTerminalIndex=Std.int(Math.min(index,app.host.panelTerminals.length-1));
				}
				app.host.hiddenTerminals.remove(tab);tab.dispose();
			}
			if(app.host.panelTerminals.length==0) app.dock.close("terminal");
			app.requestFrame();
		});
		app.requestFrame();
	}
	function pollTerminals():Void {
		for (terminal in app.host.allTerminalTabs()) {
			if (terminal.disposed) continue;
			try {
				if (terminal.poll()) app.requestFrame();
				terminalErrors.remove(terminal.id);
			} catch (error:Dynamic) {
				app.statusMessage = "Terminal: " + Std.string(error);
				var message = Std.string(error);
				if (terminalErrors.get(terminal.id) != message) {
					terminalErrors.set(terminal.id, message);
					app.application.errors.record("terminal", message);
					var actions:Array<feedback.NotificationAction> = [];
					var terminalId = terminal.id;
					if (terminal.remote) actions.push(new feedback.NotificationAction("Open terminal", function() {
						for (target in app.host.allTerminalTabs()) if (target.id == terminalId && !target.disposed) {
							app.hideNotifications();
							var index = app.host.panelTerminals.indexOf(target);
							if (index >= 0) { app.host.activePanelTerminalIndex = index; openTerminalPanel(); }
							else showTerminalInEditor(target);
							return;
						}
					}));
					if (app.createTerminal != null || app.createWorkspaceTerminal != null)
						actions.push(new feedback.NotificationAction("Create terminal", function() {
							app.hideNotifications();
							var replacement = newTerminalTab();
							if (replacement != null) showTerminalInEditor(replacement);
						}));
					var explanation = terminal.title + ": " + message;
					if (terminal.remote) explanation += "\nWorkspace: " + terminal.workspaceRoot
						+ "\nSession: " + terminal.resourceId
						+ "\nThis view refers to the original session. Create a terminal to start a new shell in the current workspace.";
					app.host.getNotifications().publish(explanation, feedback.NotificationKind.Error, "terminal", actions);
				}
				if (terminal.remote) { app.requestFrame(); continue; }
				terminal.dispose();
                app.host.hiddenTerminals.remove(terminal);
				app.host.detachTerminal(terminal);
				var index = app.host.panelTerminals.indexOf(terminal);
				if (index >= 0) {
					app.host.panelTerminals.splice(index, 1);
					if (app.host.activePanelTerminalIndex > index) app.host.activePanelTerminalIndex--;
					else if (app.host.activePanelTerminalIndex == index)
						app.host.activePanelTerminalIndex = Std.int(Math.min(index, app.host.panelTerminals.length - 1));
				}
				app.requestFrame();
			}
		}

	}
}
