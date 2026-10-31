package workspace.client;

import sys.FileSystem;

/**
	Which workspace service an attachment follows. Before M19 Phase 4 that is always a folder's. With
	`EXOSUIT_WORKSPACE_IDENTITY=workspace` the editor follows a workspace in suit's machine catalog by its id: one
	service for all of its folders (docs/architecture/0006-workspaces-without-folders.md).
**/
class WorkspaceServiceTarget {
	public static inline final FLAG = "EXOSUIT_WORKSPACE_IDENTITY";

	/** Whether machine workspaces get a service of their own, keyed by id. */
	public static function enabled():Bool return Sys.getEnv(FLAG) == "workspace";

	/** The workspace's id in suit's catalog. */
	public final workspace:String;
	/** The workspace's folders that exist, in order, as the agent spells them. */
	public final folders:Array<String>;
	/** Its scratch folder, when suit made one and it exists. */
	public final scratch:Null<String>;

	function new(workspace:String, folders:Array<String>, scratch:Null<String>) {
		this.workspace = workspace;
		this.folders = folders;
		this.scratch = scratch;
	}

	/** A workspace's target; folders that are gone are left out, as a service cannot start on them. */
	public static function forWorkspace(id:String, folders:Array<String>, scratch:Null<String>):WorkspaceServiceTarget {
		var present:Array<String> = [];
		for (folder in folders) {
			var full = directory(folder);
			if (full != null && present.indexOf(full) < 0) present.push(full);
		}
		return new WorkspaceServiceTarget(id, present, scratch == null ? null : directory(scratch));
	}

	static function directory(path:String):Null<String> {
		try {
			if (FileSystem.exists(path) && FileSystem.isDirectory(path)) return FileSystem.fullPath(path);
		} catch (_:Dynamic) {}
		return null;
	}

	/** The folder the service starts in: the first folder, else the scratch folder; null when there is neither. */
	public function root():Null<String> return folders.length > 0 ? folders[0] : scratch;

	/** What the editor's manager choices and `WorkspaceManagerChoices` key this workspace's service by. */
	public function choiceKey():String return choiceKeyOf(workspace, "");

	/** The key for a service of workspace `id`, or of `root` when `id` is empty (a folder's service). */
	public static function choiceKeyOf(id:String, root:String):String return id.length > 0 ? "workspace:" + id : root;

	/** Changes whenever the id, the folders or the scratch folder do. */
	public function signature():String return workspace + "\n" + folders.join("\n") + "\n--\n" + (scratch == null ? "" : scratch);

	/** The agent's `--manager` arguments (without the launcher) that start or find this workspace's service. */
	public function managerArguments():Array<String> {
		var arguments = ["--manager", "--workspace", workspace];
		for (folder in folders) {
			arguments.push("--folder");
			arguments.push(folder);
		}
		var folder = scratch;
		if (folder != null) {
			arguments.push("--scratch");
			arguments.push(folder);
		}
		return arguments;
	}

	/**
		Why a discovery descriptor is not the service this editor looks for, or null when it is. A workspace's service
		names the workspace and may be rooted in any of its folders (its folders can change between starts); a folder's
		names no workspace and its folder.
	**/
	public static function endpointProblem(target:Null<WorkspaceServiceTarget>, root:Null<String>, workspaceId:Null<String>,
			endpointRoot:String):Null<String> {
		var id = workspaceId == null ? "" : workspaceId;
		if (target == null)
			return id.length == 0 && endpointRoot == root ? null : "Invalid workspace discovery descriptor";
		if (id != target.workspace) return "Workspace service belongs to another workspace";
		return endpointRoot.length == 0 ? "Invalid workspace discovery descriptor" : null;
	}
}
