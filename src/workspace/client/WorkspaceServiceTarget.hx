package workspace.client;

import sys.FileSystem;

/**
	A workspace as its service is started: its id in suit's machine catalog, with one service for all of its folders
	(docs/architecture/0006-workspaces-without-folders.md), and the folders that exist.
**/
class WorkspaceServiceTarget {
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

	/** A workspace of another machine, opened over its relay: its folders are not on this device, so none are named. */
	public static function remote(id:String):WorkspaceServiceTarget
		return new WorkspaceServiceTarget(id, [], null);

	static function directory(path:String):Null<String> {
		try {
			if (FileSystem.exists(path) && FileSystem.isDirectory(path)) return FileSystem.fullPath(path);
		} catch (_:Dynamic) {}
		return null;
	}

	/** The folder the service starts in: the first folder, else the scratch folder; null when there is neither. */
	public function root():Null<String> return folders.length > 0 ? folders[0] : scratch;

	/** Changes whenever the id, the folders or the scratch folder do. */
	public function signature():String return workspace + "\n" + folders.join("\n") + "\n--\n" + (scratch == null ? "" : scratch);

	/** The service's arguments after the agent bytecode: `--workspace ID [--folder F]... [--scratch S]` (AgentMain). */
	public function serviceArguments():Array<String> {
		var arguments = ["--workspace", workspace];
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
}
