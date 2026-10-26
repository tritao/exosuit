package app;

import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.docking.DockPanelDescriptor;
import ui.WorkbenchLayoutControls;

class LayoutControlsTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function model():DockWorkspaceModel {
		var model = new DockWorkspaceModel();
		for (id in ["explorer", "editor", "problems", "build", "terminal", "context-panel"])
			model.register(new DockPanelDescriptor(id, id));
		model.setDefaultLayout(Split(Horizontal, 0.22, Panel("explorer"), Split(Vertical, 0.72, Panel("editor"), Tabs(["problems", "build"], "build"))));
		return model;
	}
	static function main():Int {
		var first = model(), controls = new WorkbenchLayoutControls(first);
		controls.toggleRight(); require(controls.rightOpen(), "right toggle failed to open a dock region");
		first.setSplitRatio([1], 0.63);
		controls.toggleRight(); require(!controls.rightOpen(), "right toggle failed to close");
		controls.toggleBottom(); require(!controls.bottomOpen() && first.isOpen("editor") && first.isOpen("explorer"), "bottom toggle removed an unrelated region");
		var metadata = controls.capture(), snapshot = first.snapshotJson();
		var second = model(); require(second.restoreJson(snapshot), "dock snapshot restore failed");
		var restored = new WorkbenchLayoutControls(second); restored.restore([metadata]);
		restored.toggleRight();
		var ratio = switch second.root { case Split(Horizontal, _, _, Split(Horizontal, value, _, Panel("context-panel"))): value; case _: -1.0; };
		require(ratio == 0.63, "closed right panel forgot its resized ratio across restart");
		restored.toggleBottom();
		require(second.isOpen("problems") && second.isOpen("build") && second.isOpen("context-panel"), "bottom restore lost tabs or right region");
		var before = restored.capture(); restored.restore(["L\tregions\t1\t0.2\t0.2\tinvalid-base64"]);
		require(restored.capture() == before, "corrupt optional region metadata changed layout");
		var windowSession = new session.WorkspaceSession(); windowSession.layout.push(metadata);
		require(session.WorkspaceSession.decode(windowSession.encode()).layout[0] == metadata, "session codec discarded region metadata");
		controls.dispose(); restored.dispose();
		trace("PASS: dock-region toggles, closed-region size persistence, bottom tab restoration and defensive session metadata");
		return 0;
	}
}
