package ui;

import haxeon.ui.widgets.sidebar.SidebarModel;

/**
	The user's Activity Bar choices (shown icons and order), kept in one setting for every window and folder like VS
	Code's. Writes the rail after each change, applies the setting when it changes, migrates the rail older layouts
	saved, and repairs a setting it cannot read.
**/
class ActivityRailPreference {
	final sidebar:SidebarModel;
	final write:String->Void;
	final report:String->Void;
	/**
		The setting's value as this window last applied or wrote it. A window can know destinations the setting does not
		mention yet, so comparing with the rail's own encoding would never match; this does.
	**/
	var known:Null<String> = null;

	/** `write` stores a value in the setting; `report` tells the user about one that could not be read. */
	public function new(sidebar:SidebarModel, write:String->Void, report:String->Void) {
		this.sidebar = sidebar; this.write = write; this.report = report;
	}

	/** Keep the rail as it is now for every window. */
	public function save():Void {
		var value = sidebar.encodeDestinations();
		known = value;
		write(value);
	}

	/**
		After a window layout's own sidebar restore, put back the user's rail from `saved` (the setting). Layouts saved
		before the rail was kept for every window carry their own order and hidden icons: while the setting is still
		empty, the first such layout restored becomes the user's rail, once.
	**/
	public function restore(saved:String, layoutSaved:Bool):Void {
		if (saved != "") applySetting(saved);
		else if (layoutSaved && sidebar.customDestinations) save();
		else known = saved;
	}

	/** The setting changed, from this window or another: applies it only when its value did. */
	public function settingChanged(value:String):Void {
		if (value == known) return;
		if (value == "") { known = value; return; }
		applySetting(value);
	}

	function applySetting(value:String):Void {
		known = value;
		if (sidebar.restoreDestinations(value)) return;
		var shown = value.length > 80 ? value.substring(0, 80) + "…" : value;
		report("The Activity Bar setting could not be read, so it was replaced with the current icons and order: " + shown);
		save();
	}
}
