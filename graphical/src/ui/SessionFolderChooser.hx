package ui;

import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import platform.HostFileDialogs;
import platform.UserFolders;
import suit.MachineCatalog.MachineWorkspace;
import workspace.client.MachineClient;
import workspace.service.GroupFolders;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** What the chooser needs from the editor; every member is read when used, so it follows the open workspace. */
typedef SessionFolderHost = {
	var host:UiWorkbenchHost;
	var desktop:Null<HostFileDialogs>;
	/** Whether the native folder picker shows the workspace's machine. */
	var localFiles:Void->Bool;
	var machine:Void->Null<MachineClient>;
	/** The id of the machine workspace open in this window, if any. */
	var workspaceId:Void->Null<String>;
	var report:String->Void;
}

/**
	New Agent Session… and New Terminal… (docs/architecture/0006-workspaces-without-folders.md): show the
	folder a session will start in, with Change… to pick another through the folder picker groups use. The workspace
	service resolves and validates the folder again; this only previews its order and passes an explicit choice. When
	nothing gives a folder, the session goes to the workspace's scratch folder, which suit creates on demand.
**/
class SessionFolderChooser {
	final context:SessionFolderHost;

	public function new(context:SessionFolderHost)
		this.context = context;

	/**
		The folder the service picks when no folder is chosen: the group's own or its nearest ancestor's, else the
		workspace's first folder. A group folder stored relative to the service's `root` is shown resolved, as the
		service will use it. Null means the scratch folder.
	**/
	public static function preview(groups:Array<WorkspaceGroup>, group:String, firstFolder:Null<String>, root:Null<String>):Null<String> {
		var byId = GroupFolders.byId(groups);
		var folder = GroupFolders.nearest(byId, byId.get(group));
		return folder == null ? firstFolder : GroupFolders.absolute(root, folder);
	}

	/** The command view row for the folder. */
	public static function folderLabel(folder:Null<String>):String
		return "Folder: " + (folder == null ? "the workspace's scratch folder" : folder);

	/** A session tab's tooltip: its title, then the folder it runs in. */
	public static function tooltip(title:String, folder:Null<String>):String
		return folder == null || folder == "" ? title : title + "\n" + folder;

	/**
		The workspace's first folder, as the service sees it: `serviceRoot`, unless the open machine workspace has no
		folders, in which case there is none and sessions without a group folder use the scratch folder.
	**/
	public function firstFolder(serviceRoot:Null<String>):Null<String> {
		var entry = openWorkspace();
		return entry != null && entry.folders.length == 0 ? null : serviceRoot;
	}

	/**
		New Agent Session…: the providers, then "Folder: <path>" with Change…. `start(provider, directory)` gets an
		explicit directory, or null to let the service resolve it.
	**/
	public function newAgentSession(providers:Array<{label:String, value:String}>, resolved:Null<String>,
			start:(String, Null<String>) -> Void, ?explicit:String):Void {
		var folder = explicit != null ? explicit : resolved;
		var entries = [for (provider in providers) new CommandViewEntry(provider.label, "New agent session", provider.value)];
		entries.push(new CommandViewEntry(folderLabel(folder), "Change…", "@folder"));
		var host = context.host;
		host.openCommandView(new CommandViewProvider("New Agent Session: ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			host.closeCommandView();
			if (entry.value == "@folder") {
				change("Choose the Session's Folder", folder, function(chosen) newAgentSession(providers, resolved, start, chosen));
				return;
			}
			var provider = entry.value;
			begin(explicit, resolved, function(directory) start(provider, directory));
		}));
	}

	/** New Terminal…: "Open terminal", then "Folder: <path>" with Change…, as New Agent Session… does. */
	public function newTerminal(resolved:Null<String>, start:Null<String>->Void, ?explicit:String):Void {
		var folder = explicit != null ? explicit : resolved;
		var host = context.host;
		var entries = [
			new CommandViewEntry("Open terminal", "New terminal", "@open"),
			new CommandViewEntry(folderLabel(folder), "Change…", "@folder")
		];
		host.openCommandView(new CommandViewProvider("New Terminal: ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			host.closeCommandView();
			if (entry.value == "@folder") change("Choose the Terminal's Folder", folder, function(chosen) newTerminal(resolved, start, chosen));
			else begin(explicit, resolved, start);
		}));
	}

	/**
		Change…: a short list. "Choose folder…" opens the native folder picker, and "Home folder (<path>)" is offered,
		when they show the workspace's machine; "Current: <path>" keeps the folder. A typed full path is taken as is,
		the same fallback the group folder uses. The service refuses anything that is not a folder.
	**/
	public function change(title:String, initial:Null<String>, chosen:String->Void, ?pickerFailed:Bool):Void {
		var host = context.host, local = context.localFiles();
		var entries:Array<CommandViewEntry> = [];
		if (context.desktop != null && local && pickerFailed != true)
			entries.push(new CommandViewEntry("Choose folder…", "Open the folder picker", "@picker"));
		var home = local ? UserFolders.home() : null;
		if (home != null) entries.push(new CommandViewEntry("Home folder (" + home + ")", "", home));
		if (initial != null) entries.push(new CommandViewEntry("Current: " + initial, "", initial));
		host.openCommandView(new CommandViewProvider(title + " (or type a full path): ", entries, function(_) {}, function(entry, typed, _) {
			// A typed full path wins; otherwise the highlighted entry.
			var path = StringTools.trim(typed == null ? "" : typed);
			if (!haxe.io.Path.isAbsolute(path)) path = entry == null ? "" : entry.value;
			if (path == "") return;
			host.closeCommandView();
			if (path == "@picker") pick(title, initial, chosen);
			else chosen(path);
		}));
	}

	/** The native folder picker; when it fails, the error is reported and Change… opens again without it. */
	function pick(title:String, initial:Null<String>, chosen:String->Void):Void {
		var desktop = context.desktop;
		if (desktop == null) { change(title, initial, chosen, true); return; }
		try {
			desktop.selectDirectory(function(accepted, paths) {
				if (accepted && paths.length > 0) chosen(paths[0]);
			}, title, initial);
		} catch (error:Dynamic) {
			context.report("The folder picker failed (" + Std.string(error) + "). Choose a folder from the list or type its full path.");
			change(title, initial, chosen, true);
		}
	}

	/** Gives `start` the explicit directory, or null when the service will resolve one, or else the scratch folder. */
	function begin(explicit:Null<String>, resolved:Null<String>, start:Null<String>->Void):Void {
		if (explicit != null) { start(explicit); return; }
		if (resolved != null) { start(null); return; }
		scratch(function(path, failure) {
			if (path != null) start(path);
			else context.report(failure == null ? "Choose a folder for the session" : failure);
		});
	}

	/** The open workspace's scratch folder, asking suit to create it when it has none yet. */
	public function scratch(done:(Null<String>, Null<String>) -> Void):Void {
		var machine = context.machine();
		var id = context.workspaceId();
		if (machine == null || !machine.enabled || id == null) {
			done(null, "This workspace has no folder. Choose one with Change…, or turn on suit for a scratch folder.");
			return;
		}
		var entry = openWorkspace();
		if (entry != null && entry.scratch != null) { done(entry.scratch, null); return; }
		machine.scratch(id, done);
	}

	function openWorkspace():Null<MachineWorkspace> {
		var machine = context.machine(), id = context.workspaceId();
		var state = machine == null ? null : machine.machine;
		if (state == null || id == null) return null;
		for (entry in state.workspaces) if (entry.id == id) return entry;
		return null;
	}
}
