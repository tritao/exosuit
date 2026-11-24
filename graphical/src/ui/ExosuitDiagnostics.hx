package ui;





import haxeon.ui.core.RenderNode;
import haxeon.ui.semantics.AccessibilityState;
import core.Application;
import ui.UiWorkbenchHost;

/**
	What a program driving the window reads of it: the automation state (contexts, tabs, the Workbench, links) and the
	diagnostic snapshot of the view tree. ExosuitApp owns one.
**/
@:allow(ui)
class ExosuitDiagnostics {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	/**
		The app's state for a program that drives the window (`exosuit.state.get` on the control plane, see
		ui.control.EditorControl; the phone's PhoneSnapshotFile): what is open, per context, and what the tree and the
		right panel show. Plain data; nothing here changes the app.
	**/
	public function automationState():Dynamic {
		var active = app.application.activeContext, current = app.application.savedWorkspaces.current;
		var machine = app.machineClient == null ? null : app.machineClient.machine;
		var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		var agents = client == null ? null : client.agentService().agents();
		var panes:Array<Dynamic> = [];
		for (pane in app.host.panes) {
			var tabs:Array<Dynamic> = [];
			for (item in pane.items) {
				var title = "", kind = "", lines:Null<Array<String>> = null, agentState:Null<String> = null, agentError:Null<String> = null;
				switch item {
					case Document(view): kind = "document"; title = view.document.hasBackingPath() ? view.document.requirePath() : "(untitled)";
					case Terminal(terminal):
						kind = "terminal"; title = terminal.title;
						// What the terminal shows, so a test can see input from another window arrive.
						if (Std.isOfType(terminal.panel, TerminalPane)) lines = cast(terminal.panel, TerminalPane).diagnosticState().lines;
					case Agent(agent):
						kind = "agent"; title = agent.title;
						// The conversation as items, so a test can see a reply arrive.
						var transcript = agent.panel.automationTranscript();
						lines = transcript.lines; agentState = transcript.state; agentError = transcript.error;
					case WorkspaceFile(file): kind = "workspace-file"; title = file.root + "|" + file.path;
					case Settings(_): kind = "settings";
					case Image(_): kind = "image";
					case UnsupportedFile(_): kind = "unsupported";
				}
				var tab:Dynamic = {kind: kind, title: title};
				if (lines != null) tab.lines = lines;
				if (kind == "agent") { tab.agentState = agentState; tab.agentError = agentError; }
				tabs.push(tab);
			}
			panes.push({id: pane.id, active: pane.activeIndex, tabs: tabs});
		}
		return {
			context: active.key(), hostContext: app.host.layoutContextKey, contextWorkspace: active.contextWorkspaceId,
			openWorkspace: app.workbenchActions.currentWorkspace(), savedWorkspace: current == null ? null : {id: current.id, name: current.name},
			machineWorkspaces: machine == null ? [] : [for (entry in machine.workspaces) {id: entry.id, name: entry.name, folders: entry.folders}],
			groups: catalog == null ? [] : [for (group in catalog.groups) {id: group.id, name: group.name, parent: group.parent, order: group.order, cwd: group.cwd}],
			terminals: catalog == null ? [] : [for (terminal in catalog.terminals) {id: terminal.id, name: terminal.name, group: terminal.group, order: terminal.order, state: terminal.state, agentProvider: terminal.agentProvider}],
			agents: agents == null ? [] : [for (record in agents.records) {id: record.id, name: record.name, group: record.group, state: record.state}],
			recent: [for (info in active.recent) info.key()],
			filesRoots: try app.contextRoots() catch (_:Dynamic) [],
			title: app.workspaceTitleText(), contextRoots: active.roots.copy(), projectRoots: [for (project in app.application.workspace.projects) project.root],
			panes: panes,
			sessionLines: app.host.sessionLines(),
			notifications: [for (entry in app.host.getNotifications().history()) entry.source + ": " + entry.message],
			sidebar: app.sidebar.activeId, contextTab: Std.string(app.contextTab), workspaceStatus: app.workspaceStatus, workspaceError: app.workspaceError, timeline: workspace.client.ConnectTimeline.snapshot(), links: app.links == null ? [] : app.links.ids(), watched: [for (id => w in app.watchedWorkspaces()) {workspace: id, running: w.running, live: w.live, starting: w.starting, hasCatalog: w.catalog != null, groups: w.catalog == null ? -1 : w.catalog.groupList().length, terminals: w.catalog == null ? -1 : w.catalog.terminalList().length}],
			commandViewActive: app.host.isCommandViewActive(),
			windowId: app.windowId(), otherWindows: app.otherWindows(), newWindowMs: Std.int(workspace.NewWindow.slowestOpen * 1000 * 10) / 10,
			contextKind: Std.string(active.kind), layoutMode: app.layoutModes.current.id, railHidden: app.layoutModes.hiddenOnRail().copy(),
			workbenchEmptyState: app.workbenchPanel != null && app.workbenchPanel.showsEmptyState(),
			workbench: workbenchAutomationState(),
			remoteAccess: app.remoteAccessPanel == null ? null : app.remoteAccessPanel.automationState()
		};
	}
	/** What the Workbench can create now and which workspace its rows belong to, for a test driver. */
	function workbenchAutomationState():Dynamic {
		var client = app.workbenchClient, panel = app.workbenchPanel;
		if (client == null || panel == null) return null;
		var catalog = client.terminalCatalog(), local = app.focus, rows = panel.model.open();
		var served = local == null ? null : local.servedWorkspace();
		return {catalog: catalog != null, catalogRoot: catalog == null ? null : catalog.workspaceRoot,
			agentsLoaded: client.agentService().agents() != null,
			canCreateTerminal: client.canCreateGroupedTerminals() && !client.terminalCatalogBusy(), canCreateAgent: app.agentTabs.canCreateAgentSession(),
			canEditGroups: client.canEditGroups(), openRow: panel.model.openRow, openRowsLive: rows != null && rows.live,
			selected: panel.tree.selectedKey, waitingToOpen: app.workbenchActions.isWaiting(),
			openRowChildren: panel.model.openRow == null ? [] : [for (index in 0...panel.model.childCount(panel.model.openRow)) panel.model.childKeyAt(panel.model.openRow, index)],
			openRowExpanded: panel.model.openRow != null && panel.tree.isExpanded(panel.model.openRow), servedWorkspace: served,
			catalogError: client.terminalCatalogError(), agentError: client.agentService().agentError()};
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
		diagnosticTreeItems(app.ui.root, treeItems);
		var active = app.host.activeDocument();
		var activeView = app.host.activeView();
		var tab = app.host.activeTab();
		var source = app.sourceControl.sourceControlSource();
		var repositories = source == null ? [] : source.repositories();
		var firstRepository = repositories.length == 0 ? null : repositories[0];
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		var agent = tab == null ? null : UiEditorTabs.agent(tab);
		var agentClient = app.workbenchClient == null ? null : app.workbenchClient.agentService();
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
		if (terminal == null) terminal = app.host.activePanelTerminal();
		var panel = terminal == null ? null : terminal.panel;
		var target = function(id:String):Dynamic {
			var node = findStyleNode(app.ui.root, id);
			return targetBounds(node);
		};
		var targetByLabel = function(label:String):Dynamic return targetBounds(findSemanticsLabel(app.ui.root, label));
		var searchQueryNode = findSemanticsLabel(app.ui.root, "Search in projects");
		var remoteFileResultIndex = -1;
		var remoteDirectoryResultIndex = -1;
		for (index in 0...app.remoteFileSearch.results.length) {
			var match = app.remoteFileSearch.results[index];
			if (match.kind == "file" && remoteFileResultIndex < 0) remoteFileResultIndex = index;
			if (match.kind == "directory" && remoteDirectoryResultIndex < 0) remoteDirectoryResultIndex = index;
		}
		return {
			documents: [for (view in app.host.allViews()) view.document.title],
			editorSelections: [for (view in app.host.allViews()) {
				title:view.document.title, anchorLine:view.selection.anchor.line,
				anchorColumn:view.selection.anchor.column, cursorLine:view.selection.cursor.line,
				cursorColumn:view.selection.cursor.column, scrollY:view.scrollController.offsetY
			}],
			workspaceFileTabs: workspaceFileDiagnostics(),
			workspaceFileReads: {active: app.workspaceFileLoader.active, completed: app.workspaceFileLoader.completedReads,
				cacheHits: app.workspaceFileLoader.cacheHits, cachedBytes: app.workspaceFileLoader.cachedBytes, lastReadMs: app.workspaceFileLoader.lastReadMs},
			viewport: {width: app.viewportWidth, height: app.viewportHeight, phoneLayout: app.phoneLayoutActive,
				sidebarVisible: app.sidebar.visible, explorerOpen: app.dock.isOpen("explorer"), activePanel: app.dock.activePanelId},
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
			explorerRoot: app.explorerRoot,
			explorerIdentity: app.explorerModel == null ? null : app.explorerModel.rootIdentity(),
			explorerWatching: app.explorerModel != null && app.explorerModel.watchesChanges(),
			explorerRevision: app.explorerModel == null ? -1 : app.explorerModel.revision(),
			workspaceIndex: [for (project in app.application.workspace.projects) {
				root: project.root, files: project.files().length, indexing: project.indexing(), generation: project.indexGeneration()
			}],
			sidebarMode: app.sidebar.activeId,
            workbenchSelectedNode: app.workbenchPanel == null ? null : app.workbenchPanel.tree.selectedKey,
			sidebarState: app.sidebar.encode(),
			panels: app.dock.panelIds(),
			status: app.statusMessage,
			workspaceConnection: app.workspaceStatus,
			notificationCount: app.host.getNotifications().entries.length,
			unreadNotifications: app.host.getNotifications().unreadCount(),
			notificationsVisible: app.notificationsVisible,
			paletteCommandCount: app.ui.commands.ids().length,
			errors: [for (entry in app.application.errors.entries) {source: entry.source, message: entry.message}],
			plugins: app.application.plugins.enabledIds(),
			terminalIds: [for (terminal in app.host.allTerminalTabs()) terminal.id],
			terminalResourceIds: [for (terminal in app.host.allTerminalTabs()) terminal.resourceId],
			terminalCreationFailure: app.terminalTabs.terminalCreationFailure(),
            terminalEditorTabs: app.host.terminalEditorResourceIds(),
            terminalPanelTabs: [for (terminal in app.host.panelTerminals) terminal.resourceId],
            terminalHiddenTabs: [for (terminal in app.host.hiddenTerminals) terminal.resourceId],
			agentCatalog:app.workbenchClient==null?null:app.workbenchClient.agentService().agents(),
            agentCreation:agentClient == null ? null : agentClient.agentCreation(),
	   agentTabs:app.host.agentResourceIds(),
			activeAgentSummary: agentSummary,
			testTargets: {
				newAgent: target("workbench-new-agent"),
				codexViewport: target("codex-session-viewport"),
				filesActivity: targetByLabel("Files"),
				sourceControlActivity: targetByLabel("Source Control"),
				sourceControlPanel: target("source-control-panel"),
				newTerminal: target("workbench-new-terminal"),
				terminalToolbar: target("toolbar-Terminal"),
				terminalPane: target("terminal-pane"),
				pairingUrl: target("phone-pairing-url"),
				pairingConnect: target("phone-pairing-start"),
				pairingConfirm: target("phone-pairing-confirm"),
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
					&& searchQueryNode.semantics.states.contains(AccessibilityState.Focused),
				remoteSearchMode: target("workspace-search-remote-mode"),
				remoteSearchResult: target("workspace-remote-search-result-0"),
				remoteSearchResult1: target("workspace-remote-search-result-1"),
				remoteSearchFileResult: remoteFileResultIndex < 0 ? null : target("workspace-remote-search-result-" + remoteFileResultIndex),
				remoteSearchDirectoryResult: remoteDirectoryResultIndex < 0 ? null : target("workspace-remote-search-result-" + remoteDirectoryResultIndex),
				remoteSearchState: {
					active: app.remoteFileSearch.active, query: app.remoteFileSearch.query, mode: app.remoteFileSearch.mode,
					count: app.remoteFileSearch.results.length, complete: app.remoteFileSearch.complete,
					results: [for (match in app.remoteFileSearch.results) {kind: match.kind, path: match.path}],
					truncated: app.remoteFileSearch.truncated, scannedEntries: app.remoteFileSearch.scannedEntries,
					skippedEntries: app.remoteFileSearch.skippedEntries, error: app.remoteFileSearch.error
				}
			},
			terminalCatalog: app.workbenchClient == null ? null : app.workbenchClient.terminalCatalog(),
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
		for (pane in app.host.panes) for (item in pane.items) {
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
}
