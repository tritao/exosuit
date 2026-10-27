package ui;

import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockNodeTools;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.docking.DockWorkspaceSnapshot;
import haxeon.ui.docking.DockWorkspaceSnapshotCodec;

/** Region toggles retain closed content and sizes independently of dock visibility. */
class WorkbenchLayoutControls {
	final model:DockWorkspaceModel;
	final release:Void->Void;
	public var bottomMaximized(default, null):Bool = false;
	var bottom:DockNode;
	var bottomRatio:Float = 0.72;
	var rightRatio:Float = 0.75;
	var changing:Bool = false;
	static final tools = ["problems", "build", "terminal"];
	public function new(model:DockWorkspaceModel) {
		this.model = model;
		var ids = [for (id in tools) if (id != "terminal" && model.get(id) != null) id];
		bottom = ids.length == 1 ? DockNode.Panel(ids[0]) : DockNode.Tabs(ids, ids[0]);
		remember(model.root);
		release = model.listen(function() {
			if (!changing) remember(model.root);
			if (!bottomOpen()) bottomMaximized = false;
		});
	}
	public function dispose():Void release();
	public function bottomOpen():Bool { for (id in tools) if (model.isOpen(id)) return true; return false; }
	public function rightOpen():Bool return model.isOpen("context-panel");
	function onlyTools(node:DockNode):Bool {
		var ids = DockNodeTools.panelIds(node);
		if (ids.length == 0) return false;
		for (id in ids) if (tools.indexOf(id) < 0) return false;
		return true;
	}
	function onlyRight(node:DockNode):Bool {
		var ids = DockNodeTools.panelIds(node); return ids.length == 1 && ids[0] == "context-panel";
	}
	function remember(node:DockNode):Void {
		switch node {
			case Split(axis, ratio, first, second):
				if (axis == DockSplitAxis.Vertical && onlyTools(second)) { bottom = DockNodeTools.clone(second); bottomRatio = ratio; }
				if (axis == DockSplitAxis.Horizontal && onlyRight(second)) rightRatio = ratio;
				remember(first); remember(second);
			case _:
		}
	}
	public function isToolGroup(ids:Array<String>):Bool {
		if (ids.length == 0) return false;
		for (id in ids) if (tools.indexOf(id) < 0) return false;
		return true;
	}
	public function expandedPanels():Null<Array<String>> return bottomMaximized && bottomOpen() ? tools.copy() : null;
	public function toggleBottomMaximized():Void {
		if (bottomOpen()) bottomMaximized = !bottomMaximized;
	}
	public function hideBottom():Void {
		if (!bottomOpen()) return;
		remember(model.root); changing = true;
		bottomMaximized = false;
		for (id in tools) model.close(id);
		changing = false;
	}
	public function toggleBottom():Void {
		if (bottomOpen()) hideBottom();
		else {
			changing = true;
			model.setRoot(insertBottom(model.root));
			changing = false;
		}
	}
	function insertBottom(node:DockNode):DockNode {
		return switch node {
			case Split(Horizontal, ratio, Panel("explorer"), second):
				Split(Horizontal, ratio, Panel("explorer"), insertBottom(second));
			case Split(Horizontal, ratio, first, Panel("context-panel")):
				Split(Horizontal, ratio, insertBottom(first), Panel("context-panel"));
			case _: Split(Vertical, bottomRatio, DockNodeTools.clone(node), DockNodeTools.clone(bottom));
		};
	}
	public function toggleRight():Void {
		if (model.get("context-panel") == null) return;
		remember(model.root); changing = true;
		if (rightOpen()) model.close("context-panel");
		else model.setRoot(withRight(model.root));
		changing = false;
	}
	public function withRight(root:DockNode):DockNode {
		var hasSidebar = DockNodeTools.contains(root, "explorer");
		var leftRatio = switch root { case Split(Horizontal, ratio, Panel("explorer"), _): ratio; case _: 0.22; };
		var main = DockNode.Split(Horizontal, rightRatio, DockNodeTools.remove(root, "explorer"), Panel("context-panel"));
		return hasSidebar ? Split(Horizontal, leftRatio, Panel("explorer"), main) : main;
	}
	public function capture():String {
		remember(model.root);
		var snapshot = DockWorkspaceSnapshotCodec.encode(new DockWorkspaceSnapshot(bottom, DockNodeTools.firstPanel(bottom)));
		return "L\tregions\t1\t" + bottomRatio + "\t" + rightRatio + "\t" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(snapshot));
	}
	public function restore(lines:Array<String>):Void {
		bottomMaximized = false;
		for (line in lines) {
			var fields = line.split("\t");
			if (fields.length != 6 || fields[0] != "L" || fields[1] != "regions" || fields[2] != "1") continue;
			var below = Std.parseFloat(fields[3]), right = Std.parseFloat(fields[4]);
			if (!Math.isFinite(below) || !Math.isFinite(right) || below < 0.05 || below > 0.95 || right < 0.05 || right > 0.95) continue;
			try {
				var saved = DockWorkspaceSnapshotCodec.decode(haxe.crypto.Base64.decode(fields[5]).toString());
				if (saved == null || !onlyTools(saved.root)) continue;
				var valid = true;
				for (id in DockNodeTools.panelIds(saved.root)) if (model.get(id) == null) valid = false;
				if (!valid) continue;
				bottom = saved.root; bottomRatio = below; rightRatio = right;
			} catch (_:Dynamic) { /* Invalid optional region metadata falls back to the live dock layout. */ }
		}
	}
}
