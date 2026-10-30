package ui;

import suit.MachineCatalog.MachineWorkspace;

/** What the Workbench's machine rows do; ExosuitApp supplies it. */
typedef WorkbenchMachineActions = {
	var view:Void->WorkbenchMachineView;
	/** True while a request to suit is in flight; workspace edits wait. */
	var busy:Void->Bool;
	/** Opens the workspace in this window, switching from the one open now. */
	var open:MachineWorkspace->Void;
	/** Asks for a name, creates a workspace with no folders, then opens it. */
	var create:Void->Void;
	var rename:MachineWorkspace->Void;
	var attachFolder:MachineWorkspace->Void;
	var remove:MachineWorkspace->Void;
}
