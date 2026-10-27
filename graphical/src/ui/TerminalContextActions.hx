package ui;

import haxeon.ui.widgets.overlays.MenuItem;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;

/** Shared resource actions for Workbench nodes and attached terminal views. */
class TerminalContextActions {
	public static function isCurrent(record:TerminalRecord, catalog:Null<TerminalCatalog>, owner:Null<String>):Bool {
		if (catalog == null || (owner != null && catalog.instance != owner)) return false;
		for (current in catalog.terminals) if (current.id == record.id && current.workspaceRoot == record.workspaceRoot)
			return current.instance == record.instance && haxe.Int64.compare(current.revision, record.revision) == 0;
		return false;
	}

	public static function build(record:TerminalRecord, canRead:Bool, canControl:Bool, busy:Bool,
		run:String->Void):Array<MenuItem> {
		var readable = canRead && record.available && !busy;
		var editable = canControl && !busy;
		var live = record.state == "running" || record.state == "starting";
		var items:Array<MenuItem> = [];
		var add = function(id:String, label:String, enabled:Bool, separator:Bool = false) {
			items.push(new MenuItem("terminal-" + id, label, function() { if (enabled) run(id); }, enabled, null, separator));
		};
		if (canRead && record.available) add("open", "Open Terminal", readable);
		if (canControl) add("rename", "Rename Terminal…", editable);
		if (canControl) add("group", "Move to Group…", editable);
		if (canRead && record.available) add("editor", "Move Terminal to Editor", readable);
		if (canRead && record.available) add("panel", "Move Terminal to Panel", readable);
		if (canRead && canControl && !live) add("restart", "Restart Terminal", editable, true);
		if (canControl && live && record.available) add("stop", "Stop Terminal", editable, true);
		if (canControl) add("close", "Close Terminal", editable, true);
		return items;
	}
}
