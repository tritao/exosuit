package ui;

import exohost.MachineCatalog.MachineWorkspace;
import workspace.client.MachineClient;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceWorkbenchClient;

/**
	The machine whose workspaces the Workbench shows, and how the window reaches each one: exohost on this machine (the
	desktop, ExohostWorkbenchMachine) or a paired machine's directory over the relay (the phone and the browser,
	DeviceWorkbenchMachine). The tree, its menus and WorkbenchActions see only this, so they have one path.
**/
interface WorkbenchMachine {
	/** The tree's view: the machine's workspaces and each one's rows. */
	function view():WorkbenchMachineView;

	function workspaceById(id:Null<String>):Null<MachineWorkspace>;

	/** The workspace this window shows, or null. */
	function current():Null<String>;

	/** Shows workspace `entry` in this window; the connection is made behind it. */
	function open(entry:MachineWorkspace):Void;

	/** The link the window holds to workspace `id`, or null; asking makes none. */
	function linkOf(id:String):Null<WorkspaceLink>;

	/** Workspace `entry`'s link, made when the window holds none (its service starts if idle), kept for this turn. */
	function useLink(entry:MachineWorkspace):Null<WorkspaceLink>;

	/**
		Keeps workspace `entry`'s link for reading its catalog, as an expanded tree row does: an existing link is marked
		used now; a new one is made only for a running service (never starting one) and within the row-link limits.
		Call it every time the catalog is read; a link nobody reads closes after WorkspaceLinks.LINGER_MS.
	**/
	function readLink(entry:MachineWorkspace):Void;

	/** The client the window shows workspace `id` through, once the window shows it; null before. */
	function shown(id:String):Null<WorkspaceWorkbenchClient>;

	/** exohost's list of this machine's workspaces, which the window may change (create, rename, folders, remove); null on a device. */
	function exohost():Null<MachineClient>;

	/** Every session and terminal of the machine's workspaces, built from the catalogs the window holds (WorkbenchSessions); works on a device too. */
	function sessionIndex():workspace.sessions.SessionIndex;
}
