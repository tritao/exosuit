package ui;

import exohost.MachineCatalog.MachineWorkspace;
import workspace.client.ConnectTimeline;
import workspace.client.MachineClient;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceLinks;
import workspace.client.WorkspaceWorkbenchClient;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchRows.WorkbenchRowSource;

/**
	The desktop's Workbench machine: this machine's workspaces as exohost lists them over the window's link
	(docs/architecture/0006-workspaces-without-folders.md), and the window's links to their services.
**/
@:allow(ui.ExosuitApp)
class ExohostWorkbenchMachine implements WorkbenchMachine {
	final app:ExosuitApp;
	public final machine:MachineClient;
	final links:WorkspaceLinks;
	var watchedKey = "";
	var watchedStates:Map<String, WorkbenchWorkspaceState> = [];
	/** Each workspace's rows as `view` last gathered them. */
	var rowSources:Map<String, WorkbenchRowSource> = [];
	var shownRevision = -1;

	public function new(app:ExosuitApp, machine:MachineClient, links:WorkspaceLinks) {
		this.app = app;
		this.machine = machine;
		this.links = links;
	}

	public function exohost():Null<MachineClient>
		return machine;

	public function workspaceById(id:Null<String>):Null<MachineWorkspace>
		return id == null ? null : machine.workspaceById(id);

	public function current():Null<String> {
		var current = app.application.savedWorkspaces.current;
		return current == null ? null : current.id;
	}

	/**
		Opens the workspace in this window: its tabs, Files, Search and Changes follow at once, and the connection is
		made behind them. A workspace already open here takes the window back to its root. Nothing waits on exohost: a
		workspace with no folders is opened as it is, and its service asks for its scratch folder when it starts.
	**/
	public function open(entry:MachineWorkspace):Void {
		var application = app.application;
		if (current() == entry.id) {
			application.activeContext.useWorkspace();
			app.requestFrame();
			return;
		}
		ConnectTimeline.mark("open-workspace", entry.id, entry.name);
		app.pollEagerly(8.0, true);
		application.savedWorkspaces.restore(new workspace.SavedWorkspace(entry.id, entry.name, entry.folders));
		// Ask exohost for the service now, not on the loop turn after the frame this click draws.
		app.connectNow();
		app.requestFrame();
	}

	public function linkOf(id:String):Null<WorkspaceLink>
		return links.get(id);

	public function useLink(entry:MachineWorkspace):Null<WorkspaceLink>
		return links.use(machine.serviceTarget(entry), true);

	public function shown(id:String):Null<WorkspaceWorkbenchClient> {
		var link = links.get(id);
		return link != null && current() == id && app.workbenchClient == link ? link : null;
	}

	/**
		The tree's view of the machine: its workspaces, and each one's rows, by one rule: the lists of the window's link to
		it when it holds one, else a copy of its catalog (the link's, else the snapshot its service left).
	**/
	public function view():WorkbenchMachineView {
		var state = machine.machine, open = current();
		var revision = rowsRevision();
		var key = machine.revision + ":" + revision + ":" + open;
		if (key != watchedKey) {
			watchedKey = key;
			watchedStates = [];
			rowSources = [];
			if (state != null)
				for (entry in state.workspaces) {
					var service = machine.serviceOf(entry.id), link = links.get(entry.id), saved = app.snapshots;
					var running = service != null && service.running;
					var mirror = link == null ? null : link.catalogMirror();
					if (mirror == null && saved != null) mirror = saved.of(entry.id);
					if (mirror != null && ConnectTimeline.markOnce("rows-other:" + entry.id, "rows-visible", entry.id, "other"))
						ConnectTimeline.markAtNextFrame("rows-frame", entry.id, "other");
					watchedStates.set(entry.id, {running: running, live: link != null && link.catalogLive(),
						starting: link != null && !running && link.connecting(), catalog: mirror});
					var terminals = link == null ? null : link.terminalCatalog(), agents = link == null ? null : link.agents();
					if (agents != null && (terminals == null || agents.root != terminals.workspaceRoot)) agents = null;
					if (terminals != null || mirror != null)
						rowSources.set(entry.id, {terminals: terminals, agents: agents, snapshot: mirror,
							revision: link == null ? 0 : link.terminalCatalogRevision() * 7919 + link.agentRevision()});
				}
		}
		return {machine: state, error: machine.error != null ? machine.error : state == null ? machine.unreachable : null, openWorkspace: open, windows: app.otherWindows(), manages: true,
			revision: machine.revision, watched: watchedStates, rows: rowSources, watchRevision: revision};
	}

	/** Changes whenever a link comes or goes, a link's lists, catalog or connection do, or a snapshot is read. */
	function rowsRevision():Int {
		var saved = app.snapshots;
		var total = links.revision * 7919 + (saved == null ? 0 : saved.revision);
		for (id in links.ids()) {
			var link = links.get(id);
			if (link != null) total += link.terminalCatalogRevision() * 31 + link.agentRevision() * 17
				+ (link.catalogLive() ? 1 : 0) + (link.connecting() ? 2 : 0);
		}
		return total;
	}

	/**
		Moves exohost's list and the links along: the window keeps a link to each running workspace whose row is expanded,
		for its rows (one not used for WorkspaceLinks.LINGER_MS closes, so a collapsed workspace holds no connection).
		True when the rows changed.
	**/
	public function poll(expanded:Array<String>):Bool {
		machine.poll();
		if (machine.machine != null) {
			var shownId = current();
			for (id in expanded) {
				if (id == shownId || links.touch(id)) continue;
				var service = machine.serviceOf(id), entry = machine.workspaceById(id);
				if (service == null || !service.running || entry == null) continue;
				links.use(machine.serviceTarget(entry), false);
			}
		}
		links.poll();
		var revision = rowsRevision();
		if (shownRevision == revision) return false;
		shownRevision = revision;
		return true;
	}
}
