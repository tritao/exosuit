package ui.shell.phone;

import workspace.sessions.SessionIndex.SessionEntry;

/** What the phone screens ask of PhoneShell: navigation, sheets and actions. Screens hold no state of their own. */
interface PhoneHost {
	function core():PhoneCore;
	function state():PhoneState;
	/** Opens the session full screen (pushes the terminal screen). */
	function openSession(entry:SessionEntry):Void;
	/** Switcher sheet: machines' workspaces and "All workspaces". */
	function chooseScope():Void;
	function chooseGroups():Void;
	function chooseKinds():Void;
	function chooseWorkspaces():Void;
	function chooseSectioning(all:Bool):Void;
	/** The session long-press sheet: Rename, Restart, Stop, Move to group. */
	function sessionMenu(entry:SessionEntry):Void;
	function newSession():Void;
	/** Switches the bottom bar destination: "sessions", "files", "search", "machines". */
	function showTab(id:String):Void;
	function back():Void;
	function refresh():Void;
	function notice(text:String, ?actionLabel:String, ?action:Void->Void):Void;
	/** Takes the person to the Sessions screen scoped to a workspace (Machines cards). */
	function scopeTo(workspaceId:Null<String>):Void;
}
