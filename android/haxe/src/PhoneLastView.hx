import workspace.client.RemoteViewSource;
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

	The saved view also says whether this phone controlled the terminal. A reopened terminal never takes control from
	another client by itself: when the phone held control before, its pane asks "Take control back?" (Take control /
	Not now) and the person decides. A phone that was an observer comes back as one, with no question.
**/
class PhoneLastView {
	/** Seconds a restore waits for the machine, its directory and the workspace catalog before giving up. */
	static inline final RESTORE_SECONDS = 40.0;

	final path:String;
	final remote:RemoteViewSource;
	final app:ExosuitApp;
	final clock:Void->Float;
	var pending:Null<{machine:String, workspace:String, kind:String, id:String, controlling:Bool}>;
	var startedAt = -1.0;
	var saved = "";
	var terminalShown = false;
	var holdUntilOpen = false;

	public function new(filesRoot:String, remote:RemoteViewSource, app:ExosuitApp, clock:Void->Float) {
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
		else save();
	}

	/** Closing the terminal view must close the soft keyboard: the terminal's blur does not run when its view leaves the tree. */
	function releaseKeyboard():Void {
		var tab = app.host.activeTab();
		var shown = tab != null && UiEditorTabs.terminal(tab) != null && !app.sidebar.visible;
		if (terminalShown && !shown) app.context().textInput.deactivate();
		terminalShown = shown;
	}

	function give_up():Void pending = null;

	/**
		An invitation link arrived (`AndroidExosuitFactory.prefillPairing`): the person came to pair, so a restore still
		waiting is given up for this start and the Remote panel stays on screen. Nothing is written until a workspace is open
		again, so the saved view is kept for the next start instead of being cleared by this one.
	**/
	public function yieldToPairing():Void {
		pending = null;
		holdUntilOpen = true;
	}

	/** The pane of an open workspace terminal, wherever it is shown: an editor tab, or the terminal panel when the Workbench
	    was not the sidebar's page as it opened. */
	function terminalPane(id:String):Null<ui.TerminalPane> {
		for (tab in app.host.allTerminalTabs())
			if (tab.remote && !tab.disposed && tab.resourceId == id && Std.isOfType(tab.panel, ui.TerminalPane)) return cast tab.panel;
		return null;
	}

	function restore():Void {
		var wanted = pending;
		if (wanted == null) return;
		if (startedAt < 0) startedAt = clock();
		if (clock() - startedAt > RESTORE_SECONDS * 1000) return give_up();
		switch remote.reopen(wanted.machine, wanted.workspace) {
			case Gone: return give_up();
			case Waiting: return;
			case Open:
		}
		if (wanted.kind == "") return give_up();
		var client = remote.workbenchService();
		if (wanted.kind == "terminal") {
			var catalog = client.terminalCatalog();
			if (catalog == null || !client.canReadTerminals()) return;
			for (record in catalog.terminals) if (record.id == wanted.id) {
				if (app.terminalTabs.openCatalogTerminal(client, record)) {
					// It opens as any terminal does. If another client took control while this phone was gone, the person is asked.
					var pane = wanted.controlling ? terminalPane(wanted.id) : null;
					if (pane != null) pane.offerControlBack();
					give_up();
				}
				return;
			}
			give_up();
		} else if (wanted.kind == "agent") {
			var agents = client.agentService().agents();
			if (agents == null) return;
			for (record in agents.records) if (record.id == wanted.id) {
				app.agentTabs.openCodexAgent(record.id);
				return give_up();
			}
			give_up();
		} else give_up();
	}

	function save():Void {
		var open = remote.openView();
		if (holdUntilOpen) {
			if (open == null) return;
			holdUntilOpen = false;
		}
		var text = "";
		if (open != null) {
			var kind = "", id = "", controlling = false;
			var tab = app.host.activeTab();
			if (tab != null) {
				var terminal = UiEditorTabs.terminal(tab);
				var agent = UiEditorTabs.agent(tab);
				if (terminal != null && terminal.remote) {
					kind = "terminal"; id = terminal.resourceId;
					// An unanswered question counts as control: a phone killed again before the answer asks again.
					if (Std.isOfType(terminal.panel, ui.TerminalPane)) {
						var pane:ui.TerminalPane = cast terminal.panel;
						controlling = pane.controlling() || pane.controlOfferOpen();
					}
				}
				else if (agent != null) { kind = "agent"; id = agent.resource; }
			}
			text = Json.stringify({machine: open.machine, workspace: open.workspace, kind: kind, id: id, controlling: controlling});
		}
		if (text == saved) return;
		saved = text;
		try {
			if (text == "") { if (FileSystem.exists(path)) FileSystem.deleteFile(path); }
			else File.saveContent(path, text);
		} catch (_:Dynamic) {}
	}
}
