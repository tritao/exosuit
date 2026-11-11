import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import ui.ExosuitApp;
import ui.UiEditorTabs;

/**
	Remembers the phone's last view (machine, workspace, and the terminal or session that was open) in the app's
	private files, and reopens it after a cold start. A target that is gone falls back to the machine list.

	Polled once per frame. While a saved view is waiting to be restored nothing is written, so a start that never
	reaches the target does not overwrite it; once the restore finished (or gave up) the view that is on screen is
	what gets saved, and leaving the workspace clears it.
**/
class PhoneLastView {
	/** Seconds a restore waits for the machine, its directory and the workspace catalog before giving up. */
	static inline final RESTORE_SECONDS = 40.0;

	final path:String;
	final remote:PhoneRemote;
	final app:ExosuitApp;
	final clock:Void->Float;
	var pending:Null<{machine:String, workspace:String, kind:String, id:String, controlling:Bool}>;
	/** A restored terminal that was controlled by this phone when it was killed: control is asked back once it is attached. */
	var reclaiming:Null<{id:String, since:Float}>;
	var startedAt = -1.0;
	var saved = "";
	var terminalShown = false;

	public function new(filesRoot:String, remote:PhoneRemote, app:ExosuitApp, clock:Void->Float) {
		this.path = filesRoot + "/last-view.json";
		this.remote = remote;
		this.app = app;
		this.clock = clock;
		try {
			if (FileSystem.exists(path)) {
				var value:Dynamic = Json.parse(File.getContent(path));
				if (value != null && value.machine != null && value.workspace != null) {
					pending = {machine: value.machine, workspace: value.workspace, kind: value.kind == null ? "" : value.kind, id: value.id == null ? "" : value.id,
						controlling: value.controlling == true};
					saved = File.getContent(path);
				}
			}
		} catch (_:Dynamic) pending = null;
	}

	public function poll():Void {
		releaseKeyboard();
		if (pending != null) restore();
		else {
			reclaim();
			save();
		}
	}

	/** Closing the terminal view must close the soft keyboard: the terminal's blur does not run when its view leaves the tree. */
	function releaseKeyboard():Void {
		var tab = app.host.activeTab();
		var shown = tab != null && UiEditorTabs.terminal(tab) != null && !app.sidebar.visible;
		if (terminalShown && !shown) app.context().textInput.deactivate();
		terminalShown = shown;
	}

	function give_up():Void pending = null;

	/** Seconds the restored terminal gets to attach before control is no longer asked for. */
	static inline final RECLAIM_SECONDS = 30.0;

	/** The terminal the phone controlled before it was killed asks for control back once. Someone else may hold it by now (the
	    editor claims a free lease); that client keeps its own pane's Take control, and this phone is the one whose person came back. */
	function reclaim():Void {
		var wanted = reclaiming;
		if (wanted == null) return;
		var tab = app.host.activeTab();
		var terminal = tab == null ? null : UiEditorTabs.terminal(tab);
		if (clock() - wanted.since > RECLAIM_SECONDS * 1000 || terminal == null || terminal.resourceId != wanted.id) {
			reclaiming = null;
			return;
		}
		if (Std.isOfType(terminal.panel, ui.TerminalPane) && !cast(terminal.panel, ui.TerminalPane).reclaimControl()) return;
		reclaiming = null;
	}

	function restore():Void {
		var wanted = pending;
		if (wanted == null) return;
		if (startedAt < 0) startedAt = clock();
		if (clock() - startedAt > RESTORE_SECONDS * 1000) return give_up();
		var machine:Null<PhoneMachine> = null;
		for (candidate in remote.machines) if (candidate.device.machineId == wanted.machine) machine = candidate;
		if (machine == null) return give_up();
		var directory = machine.machine.directory;
		if (directory == null) return;
		if (remote.open == null) {
			if (machine.machine.workspaceById(wanted.workspace) == null) return give_up();
			remote.openWorkspace(machine, wanted.workspace);
			return;
		}
		if (remote.open.id != wanted.workspace) return give_up();   // the user chose something else meanwhile
		if (wanted.kind == "") return give_up();
		var client = remote.workbenchService();
		if (wanted.kind == "terminal") {
			var catalog = client.terminalCatalog();
			if (catalog == null || !client.canReadTerminals()) return;
			for (record in catalog.terminals) if (record.id == wanted.id) {
				if (app.openCatalogTerminal(record)) {
					if (wanted.controlling) reclaiming = {id: wanted.id, since: clock()};
					give_up();
				}
				return;
			}
			give_up();
		} else if (wanted.kind == "agent") {
			var agents = client.agentService().agents();
			if (agents == null) return;
			for (record in agents.records) if (record.id == wanted.id) {
				app.openCodexAgent(record.id);
				return give_up();
			}
			give_up();
		} else give_up();
	}

	function save():Void {
		var open = remote.open;
		var machine = remote.openMachine;
		var text = "";
		if (open != null && machine != null) {
			var kind = "", id = "", controlling = false;
			var tab = app.host.activeTab();
			if (tab != null) {
				var terminal = UiEditorTabs.terminal(tab);
				var agent = UiEditorTabs.agent(tab);
				if (terminal != null && terminal.remote) {
					kind = "terminal"; id = terminal.resourceId;
					controlling = reclaiming != null || Std.isOfType(terminal.panel, ui.TerminalPane) && cast(terminal.panel, ui.TerminalPane).controlling();
				}
				else if (agent != null) { kind = "agent"; id = agent.resource; }
			}
			text = Json.stringify({machine: machine.device.machineId, workspace: open.id, kind: kind, id: id, controlling: controlling});
		}
		if (text == saved) return;
		saved = text;
		try {
			if (text == "") { if (FileSystem.exists(path)) FileSystem.deleteFile(path); }
			else File.saveContent(path, text);
		} catch (_:Dynamic) {}
	}
}
