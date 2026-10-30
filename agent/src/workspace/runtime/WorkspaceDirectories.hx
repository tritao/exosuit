package workspace.runtime;

import sys.FileSystem;
import haxe.io.Path;
import haxeon.rpc.RpcError;
import workspace.service.GroupFolders;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** A new session's resolved working directory, or why none could be chosen. */
typedef SessionDirectory = {path:Null<String>, error:Null<String>};

/**
 * Resolve directories on the owning machine, including symlink targets. Group and session directories may be any
 * existing folder, inside the workspace root or not; a relative value is taken from the workspace root.
 */
class WorkspaceDirectories {
	public final root:String;

	public function new(root:String) {
		this.root = FileSystem.fullPath(root);
		if (!FileSystem.isDirectory(this.root)) throw "Workspace root is not a directory";
	}

	/** The machine's full spelling of an existing directory, or null. */
	public function resolve(value:String):Null<String> {
		try {
			if (value == null || value.length == 0 || value.length > 1024)
				return null;
			var result = FileSystem.fullPath(Path.isAbsolute(value) ? value : Path.join([root, value]));
			if (result == null || !Path.isAbsolute(result) || !FileSystem.isDirectory(result))
				return null;
			return result;
		} catch (_:Dynamic)
			return null;
	}

	/** Whether a persisted session directory is well formed. It need not exist any more; launching checks that. */
	public static function persisted(path:Null<String>):Bool
		return path != null && path.length > 0 && path.length <= 1024 && Path.isAbsolute(path);

	/** The resolved directory for new work in `group`: its own, else the nearest ancestor's, else the root. */
	public function forGroup(groups:Array<WorkspaceGroup>, group:String):Null<String>
		return forSession(groups, group, null).path;

	/**
	 * The working directory for a new agent session or terminal (ADR 0006): `explicit`, else the group's folder or the
	 * nearest ancestor's, else the workspace's first folder (today the root). An explicit directory must be an existing
	 * folder, named by its full path or relative to the root; a group folder that no longer exists is refused, not
	 * skipped. Until a service is keyed by workspace id (M19 Phase 4) it always has a root, so the editor resolves the
	 * scratch folder and passes it as the explicit directory.
	 */
	public function forSession(groups:Array<WorkspaceGroup>, group:String, explicit:Null<String>):SessionDirectory {
		var chosen:Null<String> = null, groupFolder:Null<String> = null;
		if (explicit != null) {
			chosen = resolve(explicit);
			if (chosen == null) return refused("Choose an existing folder for the session: " + explicit);
		}
		var map = GroupFolders.byId(groups);
		var current = map.get(group);
		if (current == null) return refused("Unknown group: " + group);
		if (chosen == null) {
			var found = GroupFolders.owner(map, current);
			if (found.cycle) return refused("The group's parents form a cycle");
			var owner = found.group;
			if (owner != null) {
				groupFolder = owner.cwd == null ? null : resolve(owner.cwd);
				if (groupFolder == null) return refused("The folder of group " + owner.name + " no longer exists: " + owner.cwd);
			}
		}
		var path = choose(chosen, groupFolder, root, null);
		return path == null ? refused("This workspace has no folder; choose one for the session") : {path: path, error: null};
	}

	/**
	 * `forSession` for an agent provider's create: the directory, or null once `fail` has the reason, coded
	 * `invalid_directory` when the explicit directory was refused and `invalid_request` otherwise.
	 */
	public function forAgent(groups:Array<WorkspaceGroup>, group:String, explicit:Null<String>, fail:RpcError->Bool):Null<String> {
		var resolved = forSession(groups, group, explicit);
		if (resolved.path == null)
			fail({code: explicit == null ? "invalid_request" : "invalid_directory", message: resolved.error, ambiguous: false});
		return resolved.path;
	}

	/** Whether a retried create names another folder than the session it repeats: then it conflicts. */
	public function differs(explicit:Null<String>, recorded:String):Bool
		return explicit != null && resolve(explicit) != recorded;

	/** Resolution order for a session's directory, over candidates that are already resolved or null. */
	public static function choose(explicit:Null<String>, groupFolder:Null<String>, firstFolder:Null<String>, scratch:Null<String>):Null<String>
		return explicit != null ? explicit : groupFolder != null ? groupFolder : firstFolder != null ? firstFolder : scratch;

	static function refused(error:String):SessionDirectory
		return {path: null, error: error};

	/** Whether `path` is `root` or below it. Full paths on Windows use `\` and ignore case. */
	public static function contains(root:String, path:Null<String>, windows:Bool):Bool {
		if (path == null || root.length == 0) return false;
		var base = windows ? root.toLowerCase() : root, candidate = windows ? path.toLowerCase() : path;
		if (candidate == base) return true;
		if (!StringTools.startsWith(candidate, base)) return false;
		if (separator(base.charAt(base.length - 1), windows)) return true;
		return separator(candidate.charAt(base.length), windows);
	}

	static function separator(value:String, windows:Bool):Bool
		return value == "/" || windows && value == "\\";
}
