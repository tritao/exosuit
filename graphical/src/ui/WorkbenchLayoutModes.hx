package ui;

import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockNodeTools;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.widgets.sidebar.SidebarModel;

/** Window mode plus context-owned manual-region flags. All automatic layout edits are guarded. */
class WorkbenchLayoutModes {
	public var current(default, null):LayoutMode = LayoutMode.Editor;
	public var choice(default, null):String = "auto";
	public var leftChanged(default, null):Bool = false;
	public var bottomChanged(default, null):Bool = false;
	public var rightChanged(default, null):Bool = false;
	final dock:DockWorkspaceModel;
	final sidebar:SidebarModel;
	final regions:WorkbenchLayoutControls;
	final changed:Void->Void;
	final release:Void->Void;
	var preference:String = "auto";
	var serviceAvailable:Bool = false;
	var ready:Bool = false;
	var depth:Int = 0;
	var previous:Array<String> = [];
	var applied:String = "";
	public var beforeApply:Void->Void = function() {};
	public var afterApply:Void->Void = function() {};
	public function new(dock:DockWorkspaceModel, sidebar:SidebarModel, regions:WorkbenchLayoutControls, changed:Void->Void) {
		this.dock = dock; this.sidebar = sidebar; this.regions = regions; this.changed = changed;
		previous = signatures();
		release = dock.listen(observe);
	}
	public function dispose():Void release();
	public function suspend():Void depth++;
	public function resume():Void { if (depth > 0) depth--; previous = signatures(); }
	public function markLeft():Void { if (ready && depth == 0) leftChanged = true; }
	function signature(node:DockNode, region:String):String {
		return switch node {
			case Split(Horizontal, ratio, Panel("explorer"), _) if (region == "left"): "open:" + ratio;
			case Split(Horizontal, ratio, _, Panel("context-panel")) if (region == "right"): "open:" + ratio;
			case Split(Vertical, ratio, _, second) if (region == "bottom" && onlyTools(second)): "open:" + ratio;
			case Split(_, _, first, second): var found = signature(first, region); found == "" ? signature(second, region) : found;
			case _: "";
		};
	}
	static function onlyTools(node:DockNode):Bool {
		var ids = DockNodeTools.panelIds(node); if (ids.length == 0) return false;
		for (id in ids) if (["problems", "build", "terminal"].indexOf(id) < 0) return false;
		return true;
	}
	function signatures():Array<String> return [
		(dock.isOpen("explorer") ? "1:" : "0:") + signature(dock.root, "left"),
		(regions.bottomOpen() ? "1:" : "0:") + signature(dock.root, "bottom"),
		(regions.rightOpen() ? "1:" : "0:") + signature(dock.root, "right")];
	function observe():Void {
		var next = signatures();
		if (ready && depth == 0 && previous.length == 3) {
			if (next[0] != previous[0]) leftChanged = true;
			if (next[1] != previous[1]) bottomChanged = true;
			if (next[2] != previous[2]) rightChanged = true;
		}
		previous = next;
	}
	public function start(setting:String):Void { preference = validChoice(setting) ? setting : "auto"; ready = true; reconcile(); }
	static function validChoice(value:String):Bool return value == "auto" || LayoutMode.find(value) != null;
	public function setPreference(value:String):Void {
		if (!validChoice(value) || preference == value) return;
		preference = value; choice = "auto"; if (ready) reconcile();
	}
	public function setServiceAvailable(value:Bool):Void {
		if (serviceAvailable == value) return;
		serviceAvailable = value; if (ready && choice == "auto" && preference == "auto") reconcile();
	}
	public function select(id:String):Void {
		if (LayoutMode.find(id) == null) return;
		choice = id; if (ready) reconcile();
	}
	public function automatic():Void { choice = "auto"; if (ready) reconcile(); }
	function reconcile():Void {
		var id = choice != "auto" ? choice : preference != "auto" ? preference : serviceAvailable ? "agents" : "editor";
		var mode = LayoutMode.find(id); if (mode == null) return;
		current = mode; apply(); changed();
	}
	public function refreshContext():Void { if (ready) { apply(); changed(); } }
	public function refreshSidebar():Void { if (ready) { apply(); changed(); } }
	/** The preset supplies the default order; a user's Activity Bar order still wins. */
	function orderSidebar():Void {
		var order = current.sidebarOrder;
		sidebar.setDefaultOrder(function(a, b) {
			var ai = order.indexOf(a.id), bi = order.indexOf(b.id);
			if (ai < 0) ai = order.length + a.order; if (bi < 0) bi = order.length + b.order;
			return ai == bi ? a.sequence - b.sequence : ai - bi;
		});
	}
	function apply():Void {
		suspend(); beforeApply(); orderSidebar();
		if (!leftChanged) {
			var selected = sidebar.find(current.selectedSidebar);
			if (selected == null || !selected.visible) selected = sidebar.find("files");
			if (selected != null && selected.visible) sidebar.select(selected.id);
			sidebar.setVisible(current.left);
			if (current.left && !dock.isOpen("explorer")) dock.dock("explorer", DockNodeTools.firstPanel(dock.root), haxeon.ui.docking.DockDropZone.Left);
			else if (!current.left && dock.isOpen("explorer")) dock.close("explorer");
		}
		if (!bottomChanged && regions.bottomOpen() != current.bottom) regions.toggleBottom();
		if (!rightChanged && regions.rightOpen() != current.right) regions.toggleRight();
		applied = current.id; afterApply(); resume();
	}
	public function captureContext():String return "N\tlayout-mode\t1\t" + applied + "\t" + (leftChanged ? "1" : "0") + "\t" + (bottomChanged ? "1" : "0") + "\t" + (rightChanged ? "1" : "0");
	public function restoreContext(lines:Array<String>):Void {
		leftChanged = false; bottomChanged = false; rightChanged = false; applied = "";
		var legacy = false;
		for (line in lines) if (StringTools.startsWith(line, "D\tdock\t")) legacy = true;
		for (line in lines) {
			var f = line.split("\t");
			if (f.length != 7 || f[0] != "N" || f[1] != "layout-mode" || f[2] != "1" || f[3] != "" && LayoutMode.find(f[3]) == null) continue;
			var valid = true; for (i in 4...7) if (f[i] != "0" && f[i] != "1") valid = false;
			if (!valid) continue;
			applied = f[3]; leftChanged = f[4] == "1"; bottomChanged = f[5] == "1"; rightChanged = f[6] == "1";
			previous = signatures(); return;
		}
		// Infer deviations from the pre-mode defaults when migrating an older window.
		if (legacy) {
			leftChanged = !dock.isOpen("explorer") || sidebar.activeId != "files" || Math.abs(sidebar.width - 220) > 0.5;
			bottomChanged = !regions.bottomOpen(); rightChanged = regions.rightOpen();
			for (line in lines) {
				var f = line.split("\t");
				if (f.length != 6 || f[0] != "L" || f[1] != "regions") continue;
				var below = Std.parseFloat(f[3]), right = Std.parseFloat(f[4]);
				if (Math.isFinite(below) && Math.abs(below - 0.72) > 0.00001) bottomChanged = true;
				if (Math.isFinite(right) && Math.abs(right - 0.75) > 0.00001) rightChanged = true;
			}
		}
		previous = signatures();
	}
	public function captureWindow():String return "M\tlayout-mode\t1\t" + choice;
	public function restoreWindow(lines:Array<String>):Void {
		for (line in lines) { var f = line.split("\t"); if (f.length == 4 && f[0] == "M" && f[1] == "layout-mode" && f[2] == "1" && validChoice(f[3])) choice = f[3]; }
	}
}
