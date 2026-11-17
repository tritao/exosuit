package ui;

import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import suit.MachineCatalog.MachineWorkspace;
import workspace.client.MachineClient;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceWorkbenchClient;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.core.UiEvent;

/**
	What the Workbench's rows do, in one place: open a workspace, act in one, create, rename, attach and detach folders,
	remove; and the folder picker and the text prompt every row action uses. ExosuitApp makes one for its window and
	gives it the machine whose workspaces the Workbench shows (`attach`, WorkbenchMachine): suit's on the desktop, a
	paired machine's on a device. Changing the machine's workspaces (create, rename, folders, remove) needs suit's.

	Every action takes the workspace it acts in. One on any workspace's row runs against that workspace's link
	(`inWorkspace`), which the window makes when it holds none (suit starts an idle workspace's service); the window
	stays where it is. Only what opens that workspace's tab takes the window there first (`goTo`; Workbench design Q2:
	the window goes where the session is made).
**/
class WorkbenchActions {
	/** The agent providers New Agent Session offers: the default one at once, the others in its submenu. */
	public static final PROVIDERS = ["claude", "codex", "pi"];

	public static function providerLabel(provider:String):String
		return provider == "claude" ? "Claude" : provider == "pi" ? "Pi" : provider == "codex" ? "Codex" : provider;

	/** How long an action waits for its workspace's rows before it is given up, with a message. */
	static inline final WAIT_SECONDS = 60.0;

	final app:ExosuitApp;
	/** The machine the Workbench shows; null until the window has one. */
	public var machine(default, null):Null<WorkbenchMachine>;
	/** suit's list of this machine's workspaces, when the window may change them; null on a device. */
	var suit(get, never):Null<MachineClient>;
	var waiting:Null<PendingAction>;
	/** What the tree shows before the window has a machine: no workspaces yet. */
	public static final NO_MACHINE:WorkbenchMachineView = {machine: null, error: null, openWorkspace: null, revision: 0, manages: false};

	public function new(app:ExosuitApp)
		this.app = app;

	public function attach(machine:WorkbenchMachine):Void
		this.machine = machine;

	function get_suit():Null<MachineClient> {
		var known = machine;
		return known == null ? null : known.suit();
	}

	/** The tree's view of the machine. */
	public function view():WorkbenchMachineView {
		var known = machine;
		return known == null ? NO_MACHINE : known.view();
	}

	/** The window may change the machine's workspaces: create, rename, attach and detach folders, remove. */
	public function manages():Bool
		return suit != null;

	/** A change to the machine's workspaces is on its way; renames, folder changes and removals wait for it. */
	public function busy():Bool {
		var known = suit;
		return known != null && known.busy();
	}

	public function workspaceById(id:Null<String>):Null<MachineWorkspace> {
		var known = machine;
		return known == null ? null : known.workspaceById(id);
	}

	/** The machine workspace this window is on. */
	public function currentWorkspace():Null<String> {
		var known = machine;
		return known == null ? null : known.current();
	}

	/** Opens the workspace in this window (WorkbenchMachine.open); the window's tabs follow at once. */
	public function open(entry:MachineWorkspace):Void {
		var known = machine;
		if (known != null) known.open(entry);
	}

	/** Opens the workspace with this id unless suit does not list it. */
	public function openById(id:String):Void {
		var entry = workspaceById(id);
		if (entry != null) open(entry);
	}

	/** The link the window holds to workspace `id`, or null; asking makes none. */
	public function linked(id:String):Null<WorkspaceWorkbenchClient>
		return linkOf(id);

	function linkOf(id:String):Null<WorkspaceLink> {
		var known = machine;
		return known == null ? null : known.linkOf(id);
	}

	function useLink(entry:MachineWorkspace):Null<WorkspaceLink> {
		var known = machine;
		return known == null ? null : known.useLink(entry);
	}

	/**
		Runs `action` with workspace `entry`'s link once it has read its lists (its session list too with `agents`),
		without moving the window: at once when it has, else when it does. A later action replaces one still waiting; one
		waiting ends with a message when the link fails or the wait runs out.
	**/
	public function inWorkspace(entry:MachineWorkspace, action:WorkspaceWorkbenchClient->Void, agents:Bool = false):Void {
		if (useLink(entry) == null) return;
		wait(new PendingAction(entry, function() {
			var link = linkOf(entry.id);
			if (link != null) action(link);
		}, agents, false, Sys.time() + WAIT_SECONDS));
	}

	/**
		Opens workspace `entry` in this window (unless it is there), then runs `action` once the window shows it with its
		rows in (its session list too with `agents`). A later action replaces one still waiting; one waiting ends with a
		message when the window could not connect or the wait runs out, and silently when the window has gone to another
		workspace since.
	**/
	public function goTo(entry:MachineWorkspace, action:Void->Void, agents:Bool = false):Void {
		if (currentWorkspace() != entry.id) open(entry);
		wait(new PendingAction(entry, action, agents, true, Sys.time() + WAIT_SECONDS));
	}

	function wait(pending:PendingAction):Void {
		waiting = null;
		if (ready(pending)) pending.action();
		else waiting = pending;
	}

	/** Whether the pending action can run: its workspace's link has read its lists, and with `follow` the window shows it. */
	function ready(pending:PendingAction):Bool {
		var known = machine, id = pending.entry.id;
		var client:Null<WorkspaceWorkbenchClient> = known == null ? null : pending.follow ? known.shown(id) : known.linkOf(id);
		return client != null && rowsRead(client, pending.agents);
	}

	/** Whether `client` has read its terminal list whole, and its session list (or why not) when `agents` asks for it. */
	public static function rowsRead(client:WorkspaceWorkbenchClient, agents:Bool):Bool {
		var catalog = client.terminalCatalog();
		if (catalog == null || catalog.next != null) return false;
		return !agents || client.agentService().agents() != null || client.agentService().agentError() != null;
	}

	/** Drops the action still waiting, if any: the user went somewhere else since. */
	public function cancelWaiting():Void
		waiting = null;

	/** Whether an action waits to take the window to its workspace; the window keeps its group context meanwhile. */
	public function isWaiting():Bool
		return waiting != null && waiting.follow;

	/** Runs the waiting action once its workspace's rows are in. Called by the app's pump. */
	public function poll():Void {
		var pending = waiting;
		if (pending == null) return;
		var id = pending.entry.id;
		if (pending.follow) {
			var on = currentWorkspace() == id;
			if (on) pending.reached = true;
			else if (pending.reached) { waiting = null; return; }
		} else if (useLink(pending.entry) == null) {
			waiting = null;
			return;
		}
		if (ready(pending)) {
			waiting = null;
			pending.action();
			app.requestFrame();
			return;
		}
		var link = linkOf(id), failure = link == null ? null : link.failure();
		if (failure != null) {
			waiting = null;
			app.application.reportError("workspace", "Could not reach " + pending.entry.name + ": " + failure);
		} else if (Sys.time() > pending.until) {
			waiting = null;
			app.application.reportError("workspace", "Reaching " + pending.entry.name + " took too long");
		}
		if (waiting == null) app.requestFrame();
	}

	/** Asks for a name, creates a workspace with no folders, then opens it. */
	public function create():Void {
		var known = suit;
		if (known == null || known.busy()) return;
		askText("New workspace name", null, function(name) known.create(name, [], function(created, failure) {
			if (!report(failure) && created != null) open(created);
		}));
	}

	public function rename(entry:MachineWorkspace):Void {
		var known = suit;
		if (known == null || known.busy()) return;
		askText("Rename workspace " + entry.name, entry.name, function(name) known.rename(entry.id, name, function(_, failure) { report(failure); }));
	}

	/** The scratch folder stays apart from the attached folders (ADR 0006). */
	public function attachFolder(entry:MachineWorkspace):Void {
		if (suit == null) return;
		chooseFolder("Attach Folder to " + entry.name, null, function(folder) addFolder(entry, folder));
	}

	/** Adds `folder` to the workspace; `done` gets why not, or null. The control plane's `project.add` runs this too. */
	public function addFolder(entry:MachineWorkspace, folder:String, ?done:Null<String>->Void):Void {
		var known = suit;
		if (known == null) {
			if (done != null) done("suit's list of workspaces is not loaded yet");
			return;
		}
		known.addFolder(entry.id, folder, function(updated, failure) {
			if (!report(failure) && updated != null) foldersChanged(updated);
			if (done != null) done(failure);
		});
	}

	/** Asks which of the workspace's folders to detach, then detaches it. */
	public function detachFolder(entry:MachineWorkspace):Void {
		var known = suit;
		if (known == null || entry.folders.length == 0) return;
		var host = app.host;
		var entries = [for (folder in entry.folders) new CommandViewEntry(haxe.io.Path.withoutDirectory(folder), folder, folder)];
		host.openCommandView(new CommandViewProvider("Detach folder from " + entry.name + ": ", entries, function(_) {}, function(chosen, _, _) {
			host.closeCommandView();
			if (chosen == null) return;
			known.removeFolder(entry.id, chosen.value, function(updated, failure) {
				if (!report(failure) && updated != null) foldersChanged(updated);
			});
		}));
	}

	/** The workspace's service follows its folders at once, with no restart; the open workspace's window follows them too. */
	function foldersChanged(updated:MachineWorkspace):Void {
		app.serveFolders(updated);
		if (currentWorkspace() == updated.id)
			app.application.savedWorkspaces.restore(new workspace.SavedWorkspace(updated.id, updated.name, updated.folders));
		app.requestFrame();
	}

	public function remove(entry:MachineWorkspace):Void {
		var known = suit;
		if (known == null) return;
		known.delete(entry.id, function(_, failure) {
			if (!report(failure)) app.contexts.removeWorkspaceContexts(entry.id);
		});
	}

	/** Starts another editor window on the workspace, or on its group `group` (null for the workspace itself). */
	public function openInNewWindow(entry:MachineWorkspace, group:Null<String>):Void
		app.contexts.openContextInNewWindow(entry.id, group);

	/**
		The workspace's scratch folder, from what suit already said when it can, else asked of suit once. `done` runs
		only with a folder; a failure is reported.
	**/
	public function scratch(entry:MachineWorkspace, done:String->Void):Void {
		var known = suit;
		if (known == null) return;
		var path = known.scratchOf(entry);
		if (path != null) { done(path); return; }
		known.scratch(entry.id, function(made, failure) {
			if (!report(failure) && made != null) done(made);
		});
	}

	/** Runs `next` once a workspace with no folders has its scratch folder; at once for any other. */
	public function scratchIfNeeded(entry:MachineWorkspace, next:Void->Void):Void {
		var known = suit;
		if (entry.folders.length > 0 || known == null || known.scratchOf(entry) != null) next();
		else scratch(entry, function(_) next());
	}

	/**
		The folder picker every Workbench action uses: the native picker when it shows the workspace's machine (one that
		waits for `exosuit.dialog.answer` while the window is driven, DrivenDialogs), else a prompt for a full path.
	**/
	public function chooseFolder(title:String, initial:Null<String>, chosen:String->Void):Void {
		var desktop = app.desktop, local = app.workspaceAttachment == null || app.workspaceAttachment.hasLocalFileAccess();
		if (desktop != null && local) {
			try {
				desktop.selectDirectory(function(accepted, paths) {
					if (accepted && paths.length > 0) chosen(paths[0]);
					app.requestFrame();
				}, title, initial);
				return;
			} catch (error:Dynamic) {
				app.application.reportError("workspace", "The folder picker failed (" + Std.string(error) + "). Type the folder's full path.");
			}
		}
		askText(title + " (full path)", initial, chosen);
	}

	/** The text prompt every Workbench action uses: `done` gets the trimmed text, and an empty answer does nothing. */
	public function askText(label:String, initial:Null<String>, done:String->Void):Void {
		var host = app.host;
		host.openCommandView(new CommandViewProvider(label + ": ", [], function(_) {}, function(_, value, _) {
			var text = value == null ? "" : StringTools.trim(value);
			if (text.length == 0) return;
			host.closeCommandView();
			done(text);
			app.requestFrame();
		}));
		if (initial != null) {
			host.commandViewTextInput(initial);
			host.commandView.input.selectAll();
		}
		app.requestFrame();
	}

	/** Reports a failed request to suit; true when there was one. */
	function report(failure:Null<String>):Bool {
		if (failure == null) return false;
		app.application.reportError("workspace", failure);
		app.requestFrame();
		return true;
	}

	/** Attach existing Codex thread…: picks a thread of `group`'s folder `cwd` for the workspace `client` is the link of. */
	function attachCodexThread(client:workspace.client.WorkspaceWorkbenchClient, group:workspace.service.WorkspaceProtocol.WorkspaceGroup, cwd:String):Void {
		app.agentAttach = new AgentAttachPanel(client, group, cwd,
			function() { app.agentAttach = null; app.requestFrame(); }, app.agentTabs.openCreatedAgent, app.requestFrame);
		app.requestFrame();
	}
	function showWorkbenchMenu(items:Array<MenuItem>, event:UiEvent, valid:Void->Bool):Void {
		var anchor = app.contextMenuAnchor(event);
		var actions:Array<MenuItem> = [];
		for (item in items) {
			var action = item;
			actions.push(new MenuItem(item.key, item.label, function() {
				app.contextMenu = null;
				if (valid() && action.enabled) action.onSelect();
				app.requestFrame();
			}, item.enabled, item.shortcut, item.separatorBefore));
		}
		// An item may open the next menu in place (New Agent Session With…); the closing of this one leaves that open.
		var shown:Null<CommandMenu> = null;
		shown = new CommandMenu(app.application.commands, app.application.context, [], anchor.x, anchor.y, valid,
			function() { if (app.contextMenu == shown) app.contextMenu = null; app.requestFrame(); }, actions, ExosuitApp.menuOpenedWithKeyboard(event));
		app.contextMenu = shown;
		app.requestFrame();
	}
	/** A group's own actions from its row menu: inherit, remove, parent, directory, order. */
	function editWorkspaceGroup(client:workspace.client.WorkspaceWorkbenchClient, target:workspace.service.WorkspaceProtocol.WorkspaceGroup, action:String):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		var group = target;
		var valid = function() {
			if (!client.canEditGroups() || client.terminalCatalogBusy()) return false;
			var current = client.terminalCatalog();
			if (current == null || current.instance != catalog.instance) return false;
			for (candidate in current.groups) if (candidate.id == group.id) return candidate.revision == group.revision;
			return false;
		};
		if (!valid()) return;
		var save = function(parent:Null<String>, cwd:Null<String>, order:Int) {
			if (!valid()) return;
			client.changeGroup(catalog.instance, group, group.name, parent, cwd, order, false);
			app.requestFrame();
		};
		switch action {
			case "inherit":
				if (GroupContextActions.canInherit(group)) save(group.parent, null, workspace.service.WorkspaceProtocol.order(group.order));
			case "remove":
				if (GroupContextActions.removal(group, client) == GroupRemoval.Allowed) {
					client.removeGroup(catalog.instance, group); app.requestFrame();
				}
			case "parent":
				var entries = [new commandview.CommandViewEntry("Top level", group.parent == null ? "Current parent" : "Move out of the current group", "")];
				for (candidate in catalog.groups) if (GroupContextActions.canParent(group.id, candidate.id, catalog.groups))
					entries.push(new commandview.CommandViewEntry(candidate.name, candidate.id == group.parent ? "Current parent" : "Move group here", candidate.id));
				app.host.openCommandView(new commandview.CommandViewProvider("Move Group: ", entries, function(_) {}, function(entry, _, _) {
					if (entry == null) return;
					app.host.closeCommandView();
					if (!valid()) return;
					var parent = entry.value == "" ? null : entry.value;
					var current = client.terminalCatalog();
					if (current != null && parent != group.parent && GroupContextActions.canParent(group.id,parent,current.groups))
						save(parent,group.cwd,workspace.service.WorkspaceProtocol.order(group.order));
				}));
			case "directory":
				// Use Inherited Working Directory clears it.
				var folder = workspace.service.GroupFolders.nearest(workspace.service.GroupFolders.byId(catalog.groups), group);
				app.workbenchActions.chooseFolder("Choose Group Working Directory", folder == null ? catalog.workspaceRoot : folder,
					function(path) save(group.parent, path, workspace.service.WorkspaceProtocol.order(group.order)));
			case "order":
				app.workbenchActions.askText("Group Sort Order (0–" + workspace.service.WorkspaceProtocol.MAX_ORDER + ")", Std.string(workspace.service.WorkspaceProtocol.order(group.order)), function(value) {
					var order = ~/^[0-9]+$/.match(value) ? Std.parseInt(value) : null;
					if (order == null || order < 0 || order > workspace.service.WorkspaceProtocol.MAX_ORDER)
						app.application.reportError("workspace", "A sort order is a whole number from 0 to " + workspace.service.WorkspaceProtocol.MAX_ORDER);
					else save(group.parent, group.cwd, order);
				});
		}
		app.requestFrame();
	}
	/** A catalog terminal's menu, acting through `client`, the link of the terminal's workspace. */
	function catalogTerminalActions(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Array<MenuItem> {
		var catalog = client.terminalCatalog();
		var owner = catalog == null ? null : catalog.instance;
		return TerminalContextActions.build(record, client.canReadTerminals(),
			client.canControlTerminals(), client.terminalCatalogBusy(), function(action) {
				if (!app.terminalTabs.currentCatalogTerminal(client, record, owner)) return;
				// Menus and command pickers can outlive a permission or state change.
				var allowed = false;
				for (item in TerminalContextActions.build(record, client.canReadTerminals(), client.canControlTerminals(),
					client.terminalCatalogBusy(), function(_) {})) if (item.key == "terminal-" + action) allowed = item.enabled;
				if (!allowed) return;
				switch action {
					case "open": app.terminalTabs.openCatalogTerminal(client, record);
					case "rename": renameCatalogTerminal(client, record);
					case "group": moveCatalogTerminalGroup(client, record);
					case "stop": client.stopTerminal(record);
					case "restart": client.restartTerminal(record);
					case "close": app.terminalTabs.closeCatalogTerminal(client, record);
					case "editor", "panel":
						if (app.terminalTabs.openCatalogTerminal(client, record)) for (tab in app.host.allTerminalTabs())
							if (TerminalTabs.matchesCatalogTerminal(tab, record)) { app.terminalTabs.placeTerminal(tab, action == "editor"); break; }
				}
				app.requestFrame();
			});
	}
	function renameCatalogTerminal(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		var owner = catalog.instance;
		app.workbenchActions.askText("Rename Terminal", record.name, function(name) {
			if (app.terminalTabs.currentCatalogTerminal(client, record, owner) && client.canControlTerminals() && !client.terminalCatalogBusy())
				client.renameTerminal(record, name, record.group);
		});
	}
	function moveCatalogTerminalGroup(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		var entries = groupChoices(record.group, record.name, catalog.groups);
		app.host.openCommandView(new commandview.CommandViewProvider("Move Terminal to Group: ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			app.host.closeCommandView();
			if (!app.terminalTabs.currentCatalogTerminal(client, record, catalog.instance) || !client.canControlTerminals() || client.terminalCatalogBusy()) return;
			var current = client.terminalCatalog();
			if (current != null && entry.value != record.group && workspace.service.WorkspaceProtocol.knownGroup(entry.value, current.groups))
				client.renameTerminal(record, record.name, entry.value);
			app.requestFrame();
		}));
		app.requestFrame();
	}
	/** A session's Move to Group…: the same choices as a terminal's, sent as the agent move. */
	function moveAgentGroup(client:workspace.client.WorkspaceWorkbenchClient, record:workspace.service.WorkspaceAgentProtocol.AgentRecord):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		var entries = groupChoices(record.group, record.name, catalog.groups);
		app.host.openCommandView(new commandview.CommandViewProvider("Move Session to Group: ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			app.host.closeCommandView();
			var current = client.terminalCatalog(), service = client.agentService();
			if (current == null || current.instance != catalog.instance || service.agentBusy()) return;
			if (entry.value != record.group && workspace.service.WorkspaceProtocol.knownGroup(entry.value, current.groups))
				service.agentAction(record.id, "move", entry.value, record.group);
			app.requestFrame();
		}));
		app.requestFrame();
	}
	/** Move to Group… choices: the workspace root, then every group, with `current` marked. */
	static function groupChoices(current:String, name:String, groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup>):Array<commandview.CommandViewEntry> {
		var root = workspace.service.WorkspaceProtocol.ROOT_GROUP;
		var entries = [new commandview.CommandViewEntry("Workspace", current == root ? "Current group" : "Move " + name + " out of its group", root)];
		for (group in groups) entries.push(new commandview.CommandViewEntry(group.name,
			group.id == current ? "Current group" : "Move " + name + " here", group.id));
		return entries;
	}
}

/** An action waiting for its workspace's rows; `follow` when it takes the window there. */
private class PendingAction {
	public final entry:MachineWorkspace;
	public final action:Void->Void;
	public final agents:Bool;
	public final follow:Bool;
	public final until:Float;
	/** The window reached the workspace once; leaving it afterwards ends the wait. */
	public var reached = false;

	public function new(entry:MachineWorkspace, action:Void->Void, agents:Bool, follow:Bool, until:Float) {
		this.entry = entry; this.action = action; this.agents = agents; this.follow = follow; this.until = until;
	}
}
