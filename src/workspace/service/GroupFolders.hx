package workspace.service;

import haxe.io.Path;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** The group that gives `start` its folder, or that the parents form a cycle before any does. */
typedef GroupFolderOwner = {group:Null<WorkspaceGroup>, cycle:Bool};

/**
	Where a group's folder comes from (docs/architecture/0006-workspaces-without-folders.md): its own, else its nearest
	ancestor's. The workspace service, the Workbench tree and the session folder preview all walk it here.
**/
class GroupFolders {
	/** `start` or its nearest ancestor with a folder; `group` is null when none has one. */
	public static function owner(groups:Map<String, WorkspaceGroup>, start:Null<WorkspaceGroup>):GroupFolderOwner {
		var current = start, seen:Map<String, Bool> = [];
		while (current != null) {
			if (seen.exists(current.id)) return {group: null, cycle: true};
			seen.set(current.id, true);
			if (current.cwd != null) return {group: current, cycle: false};
			current = current.parent == null ? null : groups.get(current.parent);
		}
		return {group: null, cycle: false};
	}

	/** The folder `start` inherits as stored: its own or its nearest ancestor's, possibly relative; null when none. */
	public static function nearest(groups:Map<String, WorkspaceGroup>, start:Null<WorkspaceGroup>):Null<String> {
		var found = owner(groups, start).group;
		return found == null ? null : found.cwd;
	}

	public static function byId(groups:Array<WorkspaceGroup>):Map<String, WorkspaceGroup> {
		var map:Map<String, WorkspaceGroup> = [];
		for (group in groups) map.set(group.id, group);
		return map;
	}

	/**
		A stored folder as the service resolves it: an absolute one as is, a relative one under `root`, in the root's
		spelling. Text only, so it works for a service on another machine; the service still checks that it exists.
	**/
	public static function absolute(root:Null<String>, folder:String):String {
		if (Path.isAbsolute(folder) || root == null || root.length == 0) return folder;
		var joined = Path.normalize(Path.join([root, folder]));
		return root.indexOf("\\") >= 0 ? StringTools.replace(joined, "/", "\\") : joined;
	}
}
