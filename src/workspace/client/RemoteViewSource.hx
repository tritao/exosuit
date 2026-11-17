package workspace.client;

/** How far a saved workspace is from being open again. */
enum RemoteReopen {
	/** It cannot come back: the machine or the workspace is gone, or the person opened something else meanwhile. */
	Gone;
	/** On its way: the machine's directory is not here yet, or the workspace was just asked for. */
	Waiting;
	/** It is the open workspace. */
	Open;
}

/**
	What a device's last-view keeper (the phone's PhoneLastView) reads the view on screen from and restores it through:
	RemoteMachines, or a stand-in in the headless test (tests/phone-last-view), which has no relay or machine.
**/
interface RemoteViewSource {
	/** The machine and workspace that are open, or null while none is. */
	function openView():Null<{machine:String, workspace:String}>;
	/** One step towards having that workspace of that machine open again; call until it is Open or Gone. */
	function reopen(machine:String, workspace:String):RemoteReopen;
	/** The open workspace's terminals and sessions. */
	function workbenchService():WorkspaceWorkbenchClient;
}
