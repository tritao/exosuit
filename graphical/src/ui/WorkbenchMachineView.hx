package ui;

import suit.MachineCatalog.MachineState;
import workspace.client.WorkspaceCatalogMirror;
import ui.WorkbenchRows.WorkbenchRowSource;

/**
	What a workspace's row says of it: whether its service runs, whether the window's link to it is live, and its
	catalog as last read (the link's copy, else the snapshot its service left).
**/
typedef WorkbenchWorkspaceState = {
	/** suit reports the workspace's service as running. */
	var running:Bool;
	/** The catalog connection is open with a complete copy. */
	var live:Bool;
	/** The window's link is starting the service, which was idle. */
	var starting:Bool;
	var catalog:Null<WorkspaceCatalogMirror>;
}

/** A machine as the Workbench tree shows it (docs/architecture/0006-workspaces-without-folders.md); see WorkbenchMachine. */
typedef WorkbenchMachineView = {
	/** The machine's name and workspaces; null until suit answers. */
	var machine:Null<MachineState>;
	/** Why suit did not answer, or null. */
	var error:Null<String>;
	/** The machine workspace open in this window, or null when it shows none. */
	var openWorkspace:Null<String>;
	/** Changes whenever `machine` or `error` does. */
	var revision:Int;
	/** The window may change the machine's workspaces (create, rename, folders, remove): suit's on this machine, not a device's. */
	var manages:Bool;
	/** Per workspace id (M19 Phase 6). */
	@:optional var watched:Map<String, WorkbenchWorkspaceState>;
	/** Each workspace's rows, by id: the lists of the window's link to it, else a copy of its catalog. */
	@:optional var rows:Map<String, WorkbenchRowSource>;
	/** Changes whenever a link, its lists or a catalog does. */
	@:optional var watchRevision:Int;
	/** Where the other editor windows are focused (M19 Phase 8): this window's own is left out. */
	@:optional var windows:Array<suit.WindowFocus>;
}
