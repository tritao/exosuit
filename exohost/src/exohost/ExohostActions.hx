package exohost;

import exohost.ExohostGroup;
import exohost.ExohostInventory.ExohostProcess;

/** The process selections behind the menu items and CLI verbs. Bulk selections hold only exosuit's processes. */
class ExohostActions {
	public static function orphans(inventory:ExohostInventory):Array<ExohostProcess>
		return inventory.orphans();

	/** Every background process, terminal hosts included; editors keep running. */
	public static function background(inventory:ExohostInventory):Array<ExohostProcess>
		return inventory.background();

	/**
		"End all terminals": every terminal host exosuit started, or those of one workspace (its id, a root path
		or a folder name). Only hosts.
	**/
	public static function terminals(inventory:ExohostInventory, ?workspace:String):Array<ExohostProcess>
		return [for (host in inventory.terminals()) if (workspace == null || host.workspace == workspace || matchesWorkspace(host, workspace)) host];

	/** The workspaces that have terminal hosts, as `{key, label, count}`: the key selects them in `terminals`. */
	public static function terminalWorkspaces(inventory:ExohostInventory):Array<{key:String, label:String, count:Int}> {
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
				result.push({key: key, label: ExohostReport.workspace(host), count: 1});
		}
		return result;
	}

	/**
		The full Quit: everything exosuit started. Background processes (terminal hosts included) first so editors do not
		respawn them, then the editors.
	**/
	public static function everything(inventory:ExohostInventory):Array<ExohostProcess>
		return inventory.background().concat(inventory.editors());

	/** The polite quit: as `everything`, but terminal hosts keep running. */
	public static function everythingButTerminals(inventory:ExohostInventory):Array<ExohostProcess>
		return inventory.backgroundButTerminals().concat(inventory.editors());

	/** The full or the polite quit's selection. */
	public static function quit(inventory:ExohostInventory, keepTerminals:Bool):Array<ExohostProcess>
		return keepTerminals ? everythingButTerminals(inventory) : everything(inventory);

	/** Matches a root path or a workspace's folder name. */
	public static function matchesWorkspace(process:ExohostProcess, query:String):Bool {
		if (process.root == null)
			return false;
		if (ExohostInventory.rootKey(process.root) == ExohostInventory.rootKey(query))
			return true;
		var name = ExohostInventory.workspaceName(process.root);
		return Sys.systemName() == "Windows" ? name.toLowerCase() == query.toLowerCase() : name == query;
	}
}
