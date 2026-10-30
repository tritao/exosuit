package ui;

import suit.MachineCatalog.MachineState;

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
}
