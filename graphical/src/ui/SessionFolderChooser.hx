package ui;

import workspace.service.GroupFolders;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/**
	The folder a new session or terminal starts in (docs/architecture/0006-workspaces-without-folders.md): the group's
	own or inherited folder, else the workspace's first. The workspace service resolves and validates the folder
	again; this only previews it, and says when it must be sent explicitly. New Agent Session uses it at once; its
	Change Folder… starts the folder picker there.
**/
class SessionFolderChooser {
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

	/** A session tab's tooltip: its title, then the folder it runs in. */
	public static function tooltip(title:String, folder:Null<String>):String
		return folder == null || folder == "" ? title : title + "\n" + folder;

	/**
		The directory to send for a session the service would otherwise place: null to let it resolve one, or `resolved`
		when the service would pick another folder. A service keeps the folder it started in, so one started in the
		scratch folder puts root sessions there even after a folder is attached.
	**/
	public static function explicitFor(groups:Array<WorkspaceGroup>, group:String, resolved:Null<String>, serviceRoot:Null<String>):Null<String> {
		if (resolved == null) return null;
		var serviceChoice = preview(groups, group, serviceRoot, serviceRoot);
		return serviceChoice != null && workspace.PathKey.same(serviceChoice, resolved) ? null : resolved;
	}
}
