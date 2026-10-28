package suit;

import suit.SuitGroup;
import suit.SuitInventory.SuitProcess;

/** The process selections behind the menu items and CLI verbs. Bulk selections hold only exosuit's processes. */
class SuitActions {
	public static function orphans(inventory:SuitInventory):Array<SuitProcess>
		return inventory.orphans();

	/** Every background process; editors keep running. */
	public static function background(inventory:SuitInventory):Array<SuitProcess>
		return inventory.background();

	/** Quit: exosuit's background services first so editors do not respawn them, then the editors. */
	public static function everything(inventory:SuitInventory):Array<SuitProcess>
		return inventory.background().concat(inventory.editors());

	/**
		The processes serving relay hosting for one workspace root, or, when root is null, for every hosted
		workspace exosuit started (a bulk stop leaves the others alone).
	**/
	public static function hosting(inventory:SuitInventory, ?root:String):Array<SuitProcess> {
		var result:Array<SuitProcess> = [];
		for (hosted in inventory.hosted())
			if (root == null ? hosted.source != Scanned : matchesWorkspace(hosted, root))
				result.push(hosted);
		return result;
	}

	/** Matches a root path or a workspace's folder name. */
	public static function matchesWorkspace(process:SuitProcess, query:String):Bool {
		if (process.root == null)
			return false;
		if (SuitInventory.rootKey(process.root) == SuitInventory.rootKey(query))
			return true;
		var name = SuitInventory.workspaceName(process.root);
		return Sys.systemName() == "Windows" ? name.toLowerCase() == query.toLowerCase() : name == query;
	}
}
