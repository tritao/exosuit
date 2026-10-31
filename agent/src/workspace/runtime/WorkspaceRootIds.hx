package workspace.runtime;

import workspace.PathKey;

/**
	Root ids for a service whose folders change while it runs. A folder keeps its id for as long as the service lives,
	and an id is never given to another folder, so cursors, watches and searches keyed by it stay meaningful. The first
	folder is `root`, the next `root-1`, and so on. Callers that name `root` expect it to exist, so when its folder
	is detached the new first folder takes the id (the one case where a folder's id changes).
**/
class WorkspaceRootIds {
	/** The id callers that know of one folder use. It always names the first folder, even after the one that had it left. */
	public static inline final PRIMARY = "root";

	final ids:Map<String, String> = [];
	var next:Int = 0;

	public function new() {}

	public function idFor(path:String):String {
		var key = PathKey.of(path);
		var id = ids.get(key);
		if (id == null) {
			id = next == 0 ? PRIMARY : PRIMARY + "-" + next;
			next++;
			ids.set(key, id);
		}
		return id;
	}

	/** Gives the folder the id `root`, which the caller has freed (the folder that had it was detached). */
	public function promote(path:String):Void
		ids.set(PathKey.of(path), PRIMARY);

	/** Forgets the folder, so attaching it again gets a new id. */
	public function forget(path:String):Void
		ids.remove(PathKey.of(path));
}
