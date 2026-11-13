import workspace.client.WorkspaceWorkbenchClient;

/** How far a saved workspace is from being open again. */
enum PhoneReopen {
	/** It cannot come back: the machine or the workspace is gone, or the person opened something else meanwhile. */
	Gone;
	/** On its way: the machine's directory is not here yet, or the workspace was just asked for. */
	Waiting;
	/** It is the open workspace. */
	Open;
}

/**
	What PhoneLastView reads the view on screen from and restores it through: PhoneRemote on the phone, a stand-in in
	the headless test (tests/phone-last-view), which has no relay or machine to connect to.
**/
interface PhoneViewSource {
	/** The machine and workspace that are open, or null while none is. */
	function openView():Null<{machine:String, workspace:String}>;
	/** One step towards having that workspace of that machine open again; call until it is Open or Gone. */
	function reopen(machine:String, workspace:String):PhoneReopen;
	/** The open workspace's terminals and sessions. */
	function workbenchService():WorkspaceWorkbenchClient;
}
