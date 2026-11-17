package workspace.service;

/**
	What the owner can grant a device in one workspace, and the presets the Remote Access panel offers. exohost keeps the
	grants per device and workspace; a workspace service enforces them per request on the stream exohost forwards, and
	drops any it does not offer. The list is the panel's former one (it lived in RemoteAccessPanel), plus the catalog
	watch a remote client reads its workspace with.
**/
class MachineGrants {
	public static inline final PRESET_READ = "read";
	public static inline final PRESET_EDIT = "edit";
	public static inline final PRESET_ALL = "all";

	/** Every capability a device may be granted for a workspace. */
	public static function all():Array<String>
		return [
			WorkspaceProtocol.IDENTITY_CAPABILITY,
			WorkspaceProtocol.ORDER,
			WorkspaceProtocol.READ,
			WorkspaceProtocol.WRITE,
			WorkspaceProtocol.TREE,
			WorkspaceFileProtocol.READ,
			WorkspaceTerminalProtocol.READ,
			WorkspaceTerminalProtocol.CATALOG,
			WorkspaceTerminalProtocol.CONTROL,
			WorkspaceAgentProtocol.READ,
			WorkspaceAgentProtocol.CONTROL,
			WorkspaceScmProtocol.READ,
			WorkspaceScmProtocol.WRITE,
			WorkspaceScmProtocol.REMOTE,
			WorkspaceCatalogProtocol.CAPABILITY
		];

	/** Reading: files, updates, terminals and sessions, and the catalog; no editing and no control. */
	static function reading():Array<String>
		return [
			WorkspaceProtocol.IDENTITY_CAPABILITY,
			WorkspaceProtocol.ORDER,
			WorkspaceProtocol.READ,
			WorkspaceProtocol.TREE,
			WorkspaceFileProtocol.READ,
			WorkspaceTerminalProtocol.READ,
			WorkspaceTerminalProtocol.CATALOG,
			WorkspaceAgentProtocol.READ,
			WorkspaceScmProtocol.READ,
			WorkspaceCatalogProtocol.CAPABILITY
		];

	/** The capabilities of a preset (`read`, `edit` or `all`); null for any other name. */
	public static function preset(name:String):Null<Array<String>> {
		switch name {
			case PRESET_READ:
				return reading();
			case PRESET_EDIT:
				return reading().concat([WorkspaceProtocol.WRITE]);
			case PRESET_ALL:
				return all();
			default:
				return null;
		}
	}

	/** The preset that names exactly `grants`, else "custom". */
	public static function presetOf(grants:Array<String>):String {
		for (name in [PRESET_READ, PRESET_EDIT, PRESET_ALL])
			if (same(grants, preset(name)))
				return name;
		return "custom";
	}

	/** Whether `grants` is a bounded list of known capabilities with no repeats. */
	public static function valid(grants:Null<Array<String>>):Bool {
		if (grants == null || grants.length > 32)
			return false;
		var known = all(), seen:Array<String> = [];
		for (grant in grants) {
			if (grant == null || known.indexOf(grant) < 0 || seen.indexOf(grant) >= 0)
				return false;
			seen.push(grant);
		}
		return true;
	}

	public static function same(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		var a = left.copy(), b = right.copy();
		a.sort(Reflect.compare);
		b.sort(Reflect.compare);
		for (index in 0...a.length)
			if (a[index] != b[index])
				return false;
		return true;
	}
}
