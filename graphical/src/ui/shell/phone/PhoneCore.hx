package ui.shell.phone;

import exohost.MachineCatalog.MachineWorkspace;
import haxeon.ui.core.View;
import ui.ExosuitApp;
import ui.UiEditorTabs;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;
import workspace.sessions.SessionIndex;
import workspace.sessions.SessionIndex.SessionEntry;
import workspace.sessions.SessionIndex.SessionKind;

/** A group the person can move a session to; `depth` indents it in the sheet. */
typedef PhoneGroup = {id:String, name:String, depth:Int}

/**
	Everything PhoneShell needs from ExosuitApp, in one place: the machine and its workspaces, the session index, opening
	a session as a view, session operations, and the Files and Search panels. Screens never touch ExosuitApp directly.
**/
class PhoneCore {
	public final app:ExosuitApp;
	/** The session a tap asked for in a workspace that was not open yet; opened when its link is up. */
	var pending:Null<SessionEntry>;
	var pendingSince = 0.0;
	var knownIds:Null<Map<String, Bool>>;
	var knownSince = 0.0;
	static inline final WAIT_SECONDS = 20.0;

	public function new(app:ExosuitApp) {
		this.app = app;
	}

	// ---- machine and index

	function machineView():Null<ui.WorkbenchMachineView> {
		var machine = app.workbenchMachine();
		return machine == null ? null : machine.view();
	}

	public function machineName():String {
		var view = machineView();
		return view == null || view.machine == null ? "this machine" : view.machine.name;
	}

	public function machineOnline():Bool {
		var view = machineView();
		return view != null && view.machine != null && view.error == null;
	}

	public function workspaces():Array<MachineWorkspace> {
		var view = machineView();
		return view == null || view.machine == null ? [] : view.machine.workspaces;
	}

	public function workspaceName(id:Null<String>):String {
		if (id != null) for (workspace in workspaces()) if (workspace.id == id) return workspace.name;
		return id == null ? "All workspaces" : id;
	}

	/** The workspace the window has open, if any. */
	public function currentWorkspace():Null<String> {
		var machine = app.workbenchMachine();
		return machine == null ? null : machine.current();
	}

	/** Whether the workspace's service is running (a workspace that is not shows "idle"). */
	public function workspaceRunning(id:String):Bool {
		var view = machineView();
		if (view == null || view.watched == null) return id == currentWorkspace();
		var state = view.watched.get(id);
		return state != null && state.running;
	}

	/** Track D's index; cheap to call every frame (it rebuilds only when a catalog changed). */
	public function index():SessionIndex {
		var machine = app.workbenchMachine();
		return machine == null ? new SessionIndex() : machine.sessionIndex();
	}

	public function sessionCount(workspace:Null<String>):Int {
		var count = 0;
		for (entry in index().entries) if (workspace == null || entry.workspaceId == workspace) count++;
		return count;
	}

	/** Opens a workspace in the window (its link is made behind it). */
	public function openWorkspace(id:String):Void {
		var machine = app.workbenchMachine();
		if (machine == null || machine.current() == id) return;
		for (workspace in workspaces()) if (workspace.id == id) {
			machine.open(workspace);
			return;
		}
	}

	function clientOf(workspaceId:String):Null<WorkspaceWorkbenchClient> {
		var machine = app.workbenchMachine();
		var shown = machine == null ? null : machine.shown(workspaceId);
		if (shown != null) return shown;
		return machine != null && machine.current() == workspaceId ? app.workbenchClient : null;
	}

	// ---- opening sessions

	/** The session's view, or null when its workspace is not connected yet (it is asked to open, and `pollPending` finishes). */
	public function open(entry:SessionEntry):Null<View> {
		var panel = panelFor(entry);
		if (panel != null) return panel;
		if (clientOf(entry.workspaceId) == null) {
			pending = entry;
			pendingSince = Sys.time();
			openWorkspace(entry.workspaceId);
		}
		return null;
	}

	/** After `open` returned null: the session once its workspace is up, else null. Gives up after a while. */
	public function pollPending():Null<{entry:SessionEntry, view:View}> {
		var entry = pending;
		if (entry == null) return null;
		if (Sys.time() - pendingSince > WAIT_SECONDS) {
			pending = null;
			return null;
		}
		var panel = panelFor(entry);
		if (panel == null) return null;
		pending = null;
		return {entry: entry, view: panel};
	}

	public function cancelPending():Void pending = null;

	function panelFor(entry:SessionEntry):Null<View> {
		var found = existingPanel(entry.id);
		if (found != null) return found;
		var client = clientOf(entry.workspaceId);
		if (client == null) return null;
		var record = terminalRecord(client, entry.id);
		if (record != null) {
			if (app.terminalTabs.openCatalogTerminal(client, record)) return existingPanel(entry.id);
			return null;
		}
		var agents = client.agentService().agents();
		if (agents != null) for (agent in agents.records) if (agent.id == entry.id) {
			app.agentTabs.openCodexAgent(entry.id);
			return existingPanel(entry.id);
		}
		return null;
	}

	function existingPanel(id:String):Null<View> {
		for (tab in app.host.allTerminalTabs()) if (tab.remote && !tab.disposed && tab.resourceId == id) return tab.panel;
		for (pane in app.host.panes) for (item in pane.items) {
			var agent = UiEditorTabs.agent(item);
			if (agent != null && agent.resource == id) return agent.panel;
		}
		return null;
	}

	static function terminalRecord(client:WorkspaceWorkbenchClient, id:String):Null<TerminalRecord> {
		var catalog = client.terminalCatalog();
		if (catalog != null) for (record in catalog.terminals) if (record.id == id) return record;
		return null;
	}

	// ---- new sessions

	function openIds():Map<String, Bool> {
		var ids:Map<String, Bool> = [];
		for (tab in app.host.allTerminalTabs()) ids.set(tab.resourceId, true);
		for (pane in app.host.panes) for (item in pane.items) {
			var agent = UiEditorTabs.agent(item);
			if (agent != null) ids.set(agent.resource, true);
		}
		return ids;
	}

	/** Starts a session of `kind` in the open workspace; `pollNew` returns its view once it exists. */
	public function create(kind:SessionKind):Void {
		knownIds = openIds();
		knownSince = Sys.time();
		switch kind {
			case Terminal: app.terminalTabs.newTerminal();
			case Codex: app.agentTabs.createProviderAgent("codex", "");
			default: app.agentTabs.createProviderAgent("claude", "");
		}
	}

	/** The session `create` started, as soon as its tab exists (title and view), else null. */
	public function pollNew():Null<{id:String, title:String, view:View}> {
		var known = knownIds;
		if (known == null) return null;
		if (Sys.time() - knownSince > WAIT_SECONDS) {
			knownIds = null;
			return null;
		}
		for (tab in app.host.allTerminalTabs()) if (!tab.disposed && !known.exists(tab.resourceId)) {
			knownIds = null;
			return {id: tab.resourceId, title: tab.title, view: tab.panel};
		}
		for (pane in app.host.panes) for (item in pane.items) {
			var agent = UiEditorTabs.agent(item);
			if (agent != null && !known.exists(agent.resource)) {
				knownIds = null;
				return {id: agent.resource, title: agent.title, view: agent.panel};
			}
		}
		return null;
	}

	// ---- operations on a session (terminals; other kinds answer false)

	public function canOperate(entry:SessionEntry):Bool {
		var client = clientOf(entry.workspaceId);
		return client != null && client.canControlTerminals() && terminalRecord(client, entry.id) != null;
	}

	public function rename(entry:SessionEntry, name:String):Bool {
		var client = clientOf(entry.workspaceId);
		var record = client == null ? null : terminalRecord(client, entry.id);
		if (client == null || record == null || StringTools.trim(name) == "") return false;
		client.renameTerminal(record, StringTools.trim(name), record.group);
		return true;
	}

	public function restart(entry:SessionEntry):Bool {
		var client = clientOf(entry.workspaceId);
		var record = client == null ? null : terminalRecord(client, entry.id);
		if (client == null || record == null) return false;
		client.restartTerminal(record);
		return true;
	}

	public function stop(entry:SessionEntry):Bool {
		var client = clientOf(entry.workspaceId);
		var record = client == null ? null : terminalRecord(client, entry.id);
		if (client == null || record == null) return false;
		client.stopTerminal(record);
		return true;
	}

	public function move(entry:SessionEntry, group:String):Bool {
		var client = clientOf(entry.workspaceId);
		var record = client == null ? null : terminalRecord(client, entry.id);
		if (client == null || record == null) return false;
		client.renameTerminal(record, record.name, group);
		return true;
	}

	/** The workspace's groups, parents before children, for the "Move to group" sheet. */
	public function groupsOf(workspaceId:String):Array<PhoneGroup> {
		var client = clientOf(workspaceId);
		var catalog = client == null ? null : client.terminalCatalog();
		var result:Array<PhoneGroup> = [];
		if (catalog == null) return result;
		var add:(Null<String>, Int) -> Void = null;
		add = function(parent:Null<String>, depth:Int) {
			for (group in catalog.groups) {
				var own = group.parent == null || group.parent == "" ? null : group.parent;
				if (own == parent) {
					result.push({id: group.id, name: group.name, depth: depth});
					if (depth < 8) add(group.id, depth + 1);
				}
			}
		};
		add(null, 0);
		return result;
	}

	// ---- panels

	/** The Files or Search panel the sidebar shows ("files", "search"), or null. */
	public function panel(id:String):Null<View> {
		var mode = app.sidebar.find(id);
		return mode == null ? null : mode.provider();
	}
}
