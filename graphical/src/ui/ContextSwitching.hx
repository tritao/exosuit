package ui;





import sys.FileSystem;
import feedback.NotificationKind;

/**
	Moving the window between workspaces and groups: switching to a context, the recent contexts and the switcher,
	opening one in a new window, the start context `--context=` asks for, and leaving a group or workspace that was
	removed. ExosuitApp owns one.
**/
@:allow(ui)
class ContextSwitching {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	/** The context a window opened by Open in New Window was asked for (`--context=`), until it is applied. */
	var startContext:Null<workspace.ContextInfo>;
	/**
		A group context whose group the workspace no longer has goes back to the workspace. The group was removed, or
		an earlier run saved it and it is gone now; otherwise the window keeps the group's name as its title and offers
		"Back to Workspace" from a group that does not exist. Only a fully loaded catalog can tell, and an action waiting
		to take the window to another workspace (WorkbenchActions.goTo) is left to finish.
	**/
	function leaveMissingGroup():Void {
		var active = app.application.activeContext;
		if (active.kind != workspace.ContextKind.Group || app.workbenchActions.isWaiting()) return;
		var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		if (catalog == null || catalog.next != null) return;
		for (group in catalog.groups) if (group.id == active.id) return;
		active.useWorkspace();
		app.requestFrame();
	}
	/** A deleted workspace: leave it first if it is on screen, then close its contexts, keeping every unsaved tab. */
	function removeWorkspaceContexts(id:String):Void {
		var active = app.application.activeContext;
		if (active.contextWorkspaceId == id) {
			if (app.pendingForgetWorkspaces.indexOf(id) < 0) app.pendingForgetWorkspaces.push(id);
			var other = previousContext(id);
			if (other != null) switchToContext(other); else app.application.savedWorkspaces.close();
		}
		forgetDeletedWorkspace(id);
	}
	function forgetDeletedWorkspace(id:String):Void {
		if (app.application.activeContext.contextWorkspaceId == id) return;
		app.pendingForgetWorkspaces.remove(id);
		var moved = app.host.forgetWorkspaceContexts(id);
		app.application.activeContext.forgetWorkspace(id);
		if (moved > 0) app.host.getNotifications().publish(moved + (moved == 1 ? " unsaved tab" : " unsaved tabs") + " from the deleted workspace moved to this one.", feedback.NotificationKind.Warning, "workspace");
		app.requestFrame();
	}
	/** Takes the window to `info`; a switch still waiting for another workspace's rows is dropped. */
	public function switchToContext(info:workspace.ContextInfo):Void {
		app.workbenchActions.cancelWaiting();
		var active = app.application.activeContext;
		if (info.workspace == active.contextWorkspaceId) {
			if (info.isRoot()) active.useWorkspace();
			else if (info.directory.length > 0) active.focusGroup(info.group, info.label, info.directory);
		} else {
			var known = app.workbenchActions.workspaceById(info.workspace);
			if (known == null) return;
			if (info.isRoot()) app.workbenchActions.open(known);
			else app.workbenchActions.goTo(known, function() focusGroupIfKnown(info.group));
		}
		app.requestFrame();
	}
	/** Enters group `id` of the open workspace if its catalog still has it. */
	function focusGroupIfKnown(id:String):Void {
		var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		if (catalog != null && Lambda.exists(catalog.groups, function(group) return group.id == id)) app.focusGroupById(id);
	}
	/** The editor window `--context=` asked for: once exohost lists the machine's workspaces, opens that workspace and group. */
	public function startInContext(key:Null<String>):Void {
		var parsed = key == null ? null : workspace.ContextKey.parse(key);
		if (parsed != null) startContext = new workspace.ContextInfo(parsed.machine, parsed.workspace, parsed.group, "", "", "");
	}
	function applyStartContext():Void {
		var target = startContext, machine = app.machineClient;
		if (target == null || machine == null) return;
		if (machine.machine == null) { if (machine.error != null) startContext = null; return; }
		startContext = null;
		if (machine.workspaceById(target.workspace) == null) { app.application.reportError("workspace", "This workspace is not on this machine."); return; }
		var active = app.application.activeContext;
		if (active.contextWorkspaceId != target.workspace) switchToContext(target);
		else if (target.isRoot()) active.useWorkspace();
		else {
			var known = app.workbenchActions.workspaceById(target.workspace);
			if (known != null) app.workbenchActions.goTo(known, function() focusGroupIfKnown(target.group));
		}
	}
	/** Starts another editor window on a workspace, or on one of its groups (Open in New Window). */
	function openContextInNewWindow(workspaceId:String, group:Null<String>):Void {
		var failure = workspace.NewWindow.open(workspace.ContextKey.make(app.application.activeContext.machineId, workspaceId, group == null ? "" : group));
		if (failure != null) app.application.reportError("workspace", failure);
		app.requestFrame();
	}
	function openActiveContextInNewWindow():Void {
		var active = app.application.activeContext;
		openContextInNewWindow(active.contextWorkspaceId, active.kind == workspace.ContextKind.Group ? active.id : null);
	}
	/** Ctrl+Tab: back to the context used before this one. */
	public function switchToPreviousContext():Void {
		var target = previousContext();
		if (target != null) switchToContext(target);
	}
	/** The most recent context before this one that can still be entered; stale entries are skipped. */
	function previousContext(?excludingWorkspace:String):Null<workspace.ContextInfo> {
		var active = app.application.activeContext, activeKey = active.key();
		for (info in active.recent) {
			if (info.key() == activeKey || excludingWorkspace != null && info.workspace == excludingWorkspace) continue;
			if (contextStillExists(info) && (info.workspace == active.contextWorkspaceId || app.machineClient != null && app.machineClient.workspaceById(info.workspace) != null)) return info;
		}
		return null;
	}
	/**
		Whether a remembered context can still be entered: its workspace was not deleted (listed by the catalog before, not
		now) and a group's folder exists. A workspace the catalog never listed stays.
	**/
	function contextStillExists(info:workspace.ContextInfo):Bool {
		return app.application.activeContext.stillExists(info, function(path) return sys.FileSystem.exists(path));
	}
	/** Forgets recents of deleted workspaces and vanished group folders; runs whenever the catalog changes. */
	function pruneRecentContexts():Void {
		var machine = app.machineClient == null ? null : app.machineClient.machine;
		if (machine == null) return;
		app.application.activeContext.catalogChanged([for (entry in machine.workspaces) entry.id], function(path) return sys.FileSystem.exists(path));
	}
	/** The quick switch: recent contexts first, then the machine's workspaces and the current workspace's groups. */
	public function openContextSwitcher():Void {
		var entries:Array<commandview.CommandViewEntry> = [];
		var active = app.application.activeContext, activeKey = active.key();
		var recent = active.recent;
		for (index in 0...recent.length) {
			var info = recent[index];
			if (info.key() == activeKey || !contextStillExists(info)) continue;
			var name = info.isRoot() ? info.workspaceLabel : info.workspaceLabel + " / " + info.label;
			entries.push(new commandview.CommandViewEntry(name, app.host.contextIsWarm(info.key()) ? "open" : "", "ctx:" + info.key(), null, null, "Recent"));
		}
		var machine = app.machineClient == null ? null : app.machineClient.machine;
		if (machine != null) for (entry in machine.workspaces)
			entries.push(new commandview.CommandViewEntry(entry.name, "workspace", "ws:" + entry.id, null, null, "Workspaces"));
		for (key in app.host.recoveredContextKeys())
			entries.push(new commandview.CommandViewEntry("Recovered: " + key.split("#")[0], app.host.recoveredSummary(key), "rec:" + key, null, null, "Recovered"));
		var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		if (catalog != null) for (group in catalog.groups)
			entries.push(new commandview.CommandViewEntry(group.name, "group", "grp:" + group.id, null, null, "Groups"));
		app.host.openCommandView(new commandview.CommandViewProvider("Switch to: ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			app.host.closeCommandView();
			var value = entry.value;
			if (StringTools.startsWith(value, "rec:")) {
				// Opening a recovered layout merges its tabs into the context on screen.
				var moved = app.host.mergeContext(value.substr(4), false);
				app.host.getNotifications().publish(moved + (moved == 1 ? " recovered tab" : " recovered tabs") + " opened here.", feedback.NotificationKind.Information, "workspace");
			} else if (StringTools.startsWith(value, "ctx:")) {
				for (info in app.application.activeContext.recent) if ("ctx:" + info.key() == value) { switchToContext(info); break; }
			} else if (StringTools.startsWith(value, "ws:")) {
				var id = value.substr(3);
				var root:Null<workspace.ContextInfo> = null;
				for (info in app.application.activeContext.recent) if (info.workspace == id && info.isRoot()) root = info;
				var known = app.machineClient == null ? null : app.machineClient.workspaceById(id);
				if (root != null) switchToContext(root);
				else if (known != null) switchToContext(new workspace.ContextInfo(active.machineId, id, "", known.name, known.name, ""));
			} else if (StringTools.startsWith(value, "grp:") && catalog != null) {
				app.application.activeContext.openSessionGroup(value.substr(4), catalog.groups, catalog.workspaceRoot);
			}
			app.requestFrame();
		}));
	}
}
