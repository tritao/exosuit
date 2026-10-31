package ui;

import suit.MachineCatalog.MachineState;
import workspace.client.WorkspaceCatalogMirror;

/**
	What the tree shows of a workspace this window is not attached to: whether its service runs, whether its catalog
	connection is live, and the catalog last read (kept while the connection is down).
**/
typedef WorkbenchWorkspaceState = {
	/** suit reports the workspace's service as running. */
	var running:Bool;
	/** The catalog connection is open with a complete copy. */
	var live:Bool;
	/** The service is being started because the workspace was expanded while idle. */
	var starting:Bool;
	var catalog:Null<WorkspaceCatalogMirror>;
}

/** This machine as the Workbench tree shows it (docs/architecture/0006-workspaces-without-folders.md). */
typedef WorkbenchMachineView = {
	/** This machine's name and workspaces; null until suit answers. */
	var machine:Null<MachineState>;
	/** Why suit did not answer, or null. */
	var error:Null<String>;
	/** The machine workspace open in this window, or null when this window's folders are not one of them. */
	var openWorkspace:Null<String>;
	/** This window's folders: the attached service's groups are the open workspace's while it serves one of them. */
	var openRoots:Array<String>;
	/** Changes whenever `machine` or `error` does. */
	var revision:Int;
	/** Per workspace id (M19 Phase 6); absent in a view that knows only the attached workspace. */
	@:optional var watched:Map<String, WorkbenchWorkspaceState>;
	/** Changes whenever a catalog connection or a catalog does. */
	@:optional var watchRevision:Int;
}
