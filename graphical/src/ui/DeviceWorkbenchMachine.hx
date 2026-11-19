package ui;

import exohost.MachineCatalog.MachineState;
import exohost.MachineCatalog.MachineWorkspace;
import workspace.client.MachineClient;
import workspace.client.RemoteMachine;
import workspace.client.RemoteMachines;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceServiceTarget;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.MachineDirectoryProtocol;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchRows.WorkbenchRowSource;

/**
	A device's Workbench machine (the phone's, the browser's): the workspaces a paired machine's exohost grants this device,
	from its directory (what RemoteMachines reads), and the device's links to them. The machine shown is the one whose
	workspace is open, else the first that listed its workspaces. Opening a row opens its workspace through that
	machine's RemoteMachine; the open workspace's rows are the lists the window shows it through, another's its link's
	lists or catalog. A device cannot change the machine's workspaces.
**/
class DeviceWorkbenchMachine implements WorkbenchMachine {
	final app:ExosuitApp;
	final remote:RemoteMachines;
	var viewKey = "";
	var shownView:WorkbenchMachineView;

	public function new(app:ExosuitApp, remote:RemoteMachines) {
		this.app = app;
		this.remote = remote;
		shownView = {machine: null, error: null, openWorkspace: null, revision: 0, manages: false};
	}

	final sessionSource:workspace.client.SessionIndexSource = new workspace.client.SessionIndexSource();

	final merged:workspace.sessions.SessionIndex = new workspace.sessions.SessionIndex();
	var mergedKey = "";

	/**
		The index from the catalogs this device reads (WorkbenchSessions), plus the machine's SESSIONS answer for
		workspaces whose catalog it has not read yet, so every readable session is listed before its workspace is linked.
	**/
	public function sessionIndex():workspace.sessions.SessionIndex {
		var own = WorkbenchSessions.of(this, sessionSource);
		var shown = machine();
		var device = shown == null ? null : shown.machine;
		var relay = device == null ? null : device.sessions;
		if (device == null || relay == null || relay.length == 0)
			return own;
		var key = own.revision + ":" + device.revision;
		if (key != mergedKey) {
			mergedKey = key;
			var covered:Map<String, Bool> = [];
			for (entry in own.entries)
				covered.set(entry.workspaceId, true);
			var entries = own.entries.copy();
			for (entry in relay)
				if (!covered.exists(entry.workspaceId))
					entries.push(entry);
			merged.replace(entries);
		}
		return merged;
	}

	public function exohost():Null<MachineClient>
		return null;

	/**
		Moves the device's machines along (RemoteMachines.pollMachines); call every frame. A running workspace whose row is
		expanded in the tree gets a link for its rows, as on the desktop.
	**/
	public function poll():Void {
		var panel = app.workbenchPanel;
		remote.pollMachines(panel == null ? [] : panel.expandedWorkspaceIds());
	}

	/** The paired machine the tree shows. */
	function machine():Null<RemoteMachine> {
		var open = remote.openMachine;
		if (open != null) return open;
		for (candidate in remote.machines) if (candidate.machine.directory != null) return candidate;
		return remote.machines.length == 0 ? null : remote.machines[0];
	}

	public function workspaceById(id:Null<String>):Null<MachineWorkspace> {
		var state = id == null ? null : view().machine;
		if (state != null) for (entry in state.workspaces) if (entry.id == id) return entry;
		return null;
	}

	public function current():Null<String>
		return remote.openId;

	public function open(entry:MachineWorkspace):Void {
		var shown = machine();
		if (shown != null) remote.openWorkspace(shown, entry.id);
		app.requestFrame();
	}

	public function linkOf(id:String):Null<WorkspaceLink> {
		var shown = machine();
		return shown == null ? null : shown.links.get(id);
	}

	public function useLink(entry:MachineWorkspace):Null<WorkspaceLink> {
		var shown = machine();
		return shown == null ? null : shown.links.use(WorkspaceServiceTarget.remote(entry.id), true);
	}

	public function readLink(entry:MachineWorkspace):Void {
		var shown = machine();
		if (shown != null) shown.readLink(entry.id);
	}

	public function shown(id:String):Null<WorkspaceWorkbenchClient> {
		var client = remote.workbenchService(), link = remote.open;
		return remote.openId == id && link != null && link.ready && app.workbenchClient == client ? client : null;
	}

	public function view():WorkbenchMachineView {
		var shownMachine = machine(), client = remote.workbenchService();
		var key = remote.revision + ":" + client.terminalCatalogRevision() + ":" + client.agentService().agentRevision()
			+ ":" + (shownMachine == null ? -1 : remote.machines.indexOf(shownMachine)) + ":" + (app.workbenchClient == client);
		if (key == viewKey) return shownView;
		viewKey = key;
		var directory = shownMachine == null ? null : shownMachine.machine.directory;
		var watched:Map<String, WorkbenchWorkspaceState> = [], rows:Map<String, WorkbenchRowSource> = [];
		var workspaces:Array<MachineWorkspace> = [];
		if (shownMachine != null && directory != null)
			for (entry in directory.workspaces) {
				var id = entry.workspace, link = shownMachine.links.get(id);
				var running = entry.status == MachineDirectoryProtocol.RUNNING, mirror = link == null ? null : link.catalogMirror();
				workspaces.push({id: id, name: entry.name, folders: [], scratch: null, revision: 0});
				watched.set(id, {running: running, live: link != null && link.catalogLive(), starting: link != null && !running && link.connecting(),
					catalog: mirror});
				var terminals = link == null ? null : link.terminalCatalog(), agents = link == null ? null : link.agentService().agents();
				if (agents != null && (terminals == null || agents.root != terminals.workspaceRoot)) agents = null;
				if (terminals != null || mirror != null)
					rows.set(id, {terminals: terminals, agents: agents, snapshot: mirror,
						revision: link == null ? 0 : link.terminalCatalogRevision() * 7919 + link.agentService().agentRevision()});
			}
		var state:Null<MachineState> = null, error:Null<String> = null;
		if (shownMachine != null) {
			error = shownMachine.refusal();
			if (error == null) error = shownMachine.machine.error;
			if (directory != null) state = {id: shownMachine.device.machineId, name: shownMachine.name(), workspaces: workspaces};
		}
		shownView = {machine: state, error: error, openWorkspace: remote.openId, manages: false, revision: remote.revision, watched: watched,
			rows: rows, watchRevision: remote.revision};
		return shownView;
	}
}
