package ui;

import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.sidebar.SidebarModel;

/**
	The Activity Bar's show/hide and order entries, for its own context menu and the Manage menu. The user's choices live
	in the sidebar model; `changed` runs after each one so the app can keep them for every window.
**/
class ActivityBarMenu {
	final sidebar:SidebarModel;
	/** Destinations the layout mode keeps off the rail, whatever the user chose. */
	final modeHides:String->Bool;
	final changed:Void->Void;

	public function new(sidebar:SidebarModel, modeHides:String->Bool, changed:Void->Void) {
		this.sidebar = sidebar; this.modeHides = modeHides; this.changed = changed;
	}

	/** Destinations on the rail now: shown by the user and not left out by the layout mode. */
	public function shownCount():Int {
		var shown = 0;
		for (mode in sidebar.modes) if (mode.visible && !modeHides(mode.id)) shown++;
		return shown;
	}

	/** Show/hide entries for every destination, so a hidden icon can always come back. A destination id adds a
		leading entry that hides it. The last destination on the rail cannot be hidden. */
	public function items(id:Null<String>):Array<MenuItem> {
		var shown = shownCount();
		var items:Array<MenuItem> = [];
		var target = id == null ? null : sidebar.find(id);
		if (target != null && target.visible) {
			var targetId = target.id;
			items.push(new MenuItem("activity-hide", "Hide '" + target.label + "'",
				function() setVisible(targetId, false), shown > 1));
		}
		var first = true;
		for (mode in sidebar.modes) {
			// The layout mode hides these regardless of the user's choice, so they are not offered here.
			if (modeHides(mode.id)) continue;
			var modeId = mode.id, visible = mode.visible;
			items.push(new MenuItem("activity-toggle:" + modeId,
				(visible ? "Hide " : "Show ") + mode.label, function() setVisible(modeId, !visible),
				!visible || shown > 1, null, first));
			first = false;
		}
		items.push(new MenuItem("activity-reset-order", "Reset Activity Bar Order", resetOrder, sidebar.customOrder, null, true));
		return items;
	}

	public function setVisible(id:String, visible:Bool):Void {
		var mode = sidebar.find(id);
		if (mode == null || mode.visible == visible || (!visible && shownCount() <= 1)) return;
		if (sidebar.setModeVisible(id, visible)) changed();
	}

	public function resetOrder():Void {
		if (sidebar.resetOrder()) changed();
	}

	/** A drag on the rail moved `id` before `before`, or to the end. */
	public function move(id:String, before:Null<String>):Void {
		if (sidebar.moveMode(id, before)) changed();
	}
}
