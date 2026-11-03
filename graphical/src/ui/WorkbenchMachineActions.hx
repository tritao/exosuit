package ui;

import suit.MachineCatalog.MachineWorkspace;

/** What the Workbench's machine rows do; ExosuitApp supplies it. */
typedef WorkbenchMachineActions = {
	var view:Void->WorkbenchMachineView;
	/** True while a request to suit is in flight; workspace edits wait. */
	var busy:Void->Bool;
	/** Opens the workspace in this window, switching from the one open now. */
	var open:MachineWorkspace->Void;
	/** Starts an idle workspace's service without opening it here; its catalog then appears in the tree. */
	var start:MachineWorkspace->Void;
	/** Drops a start that is still queued (the workspace was collapsed); one already launched runs on. */
	@:optional var cancelStart:MachineWorkspace->Void;
	/** Asks for a name, creates a workspace with no folders, then opens it. */
	var create:Void->Void;
	var rename:MachineWorkspace->Void;
	var attachFolder:MachineWorkspace->Void;
	/** Asks which of the workspace's folders to detach, then detaches it. */
	var detachFolder:MachineWorkspace->Void;
	var remove:MachineWorkspace->Void;
	/** Starts another editor window on the workspace, or on its group `group` (null for the workspace itself). */
	@:optional var openInNewWindow:(MachineWorkspace, Null<String>)->Void;
}
