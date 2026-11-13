package suit;

import suit.SuitGroup;
import suit.SuitInventory.SuitProcess;

/** The process selections behind the menu items and CLI verbs. Bulk selections hold only exosuit's processes. */
class SuitActions {
	public static function orphans(inventory:SuitInventory):Array<SuitProcess>
		return inventory.orphans();

	/** Every background process, terminal hosts included; editors keep running. */
	public static function background(inventory:SuitInventory):Array<SuitProcess>
		return inventory.background();

	/**
		"End all terminals": every terminal host exosuit started, or those of one workspace (its id, a root path
		or a folder name). Only hosts.
	**/
	public static function terminals(inventory:SuitInventory, ?workspace:String):Array<SuitProcess>
		return [for (host in inventory.terminals()) if (workspace == null || host.workspace == workspace || matchesWorkspace(host, workspace)) host];

	/** The workspaces that have terminal hosts, as `{key, label, count}`: the key selects them in `terminals`. */
	public static function terminalWorkspaces(inventory:SuitInventory):Array<{key:String, label:String, count:Int}> {
		var result:Array<{key:String, label:String, count:Int}> = [];
		for (host in inventory.terminals()) {
			var key = host.workspace != null ? host.workspace : host.root;
			if (key == null)
				continue;
			var found = false;
			for (entry in result)
				if (entry.key == key) {
					entry.count++;
					found = true;
				}
			if (!found)
				result.push({key: key, label: SuitReport.workspace(host), count: 1});
		}
		return result;
	}

	/**
		The full Quit: everything exosuit started. Background processes (terminal hosts included) first so editors do not
		respawn them, then the editors.
	**/
	public static function everything(inventory:SuitInventory):Array<SuitProcess>
		return inventory.background().concat(inventory.editors());

	/** The polite quit: as `everything`, but terminal hosts keep running. */
	public static function everythingButTerminals(inventory:SuitInventory):Array<SuitProcess>
		return inventory.backgroundButTerminals().concat(inventory.editors());

	/** The full or the polite quit's selection. */
	public static function quit(inventory:SuitInventory, keepTerminals:Bool):Array<SuitProcess>
		return keepTerminals ? everythingButTerminals(inventory) : everything(inventory);

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
