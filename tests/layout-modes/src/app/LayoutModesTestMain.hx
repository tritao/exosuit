package app;

import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.widgets.sidebar.SidebarModel;
import haxeon.ui.widgets.sidebar.SidebarModeOptions;
import haxeon.ui.widgets.text.Text;
import ui.WorkbenchLayoutControls;
import ui.WorkbenchLayoutModes;

class LayoutModesTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function model():DockWorkspaceModel {
		var dock = new DockWorkspaceModel();
		for (id in ["explorer", "editor", "problems", "build", "terminal", "context-panel"]) dock.register(new DockPanelDescriptor(id, id));
		dock.setDefaultLayout(Split(Horizontal, 0.22, Panel("explorer"), Split(Vertical, 0.72, Panel("editor"), Tabs(["problems", "build"], "problems"))));
		return dock;
	}
	static function sidebar(dock:DockWorkspaceModel):SidebarModel {
		var sidebar = new SidebarModel();
		var order = 0;
		for (id in ["files", "search", "scm", "workbench"]) { var key = id; sidebar.register(key, function() return new Text(key), new SidebarModeOptions(key, order++, true)); }
		sidebar.onChange = function() {
			if (!sidebar.visible && dock.isOpen("explorer")) dock.close("explorer");
			else if (sidebar.visible && !dock.isOpen("explorer")) dock.dock("explorer", "editor", haxeon.ui.docking.DockDropZone.Left);
		};
		return sidebar;
	}
	static function main():Int {
		var dock = model(), side = sidebar(dock), regions = new WorkbenchLayoutControls(dock), modes = new WorkbenchLayoutModes(dock, side, regions, function() {});
		modes.start("auto");
		require(modes.current.id == "editor" && !regions.bottomOpen() && !regions.rightOpen() && side.activeId == "files", "disconnected default is not Editor");
		var editor = dock.snapshotJson(), editorSidebar = side.encode();
		modes.setServiceAvailable(true);
		require(modes.current.id == "agents" && regions.rightOpen() && !regions.bottomOpen() && side.activeId == "workbench" && side.modes[0].id == "workbench", "connected group default is not Agents");
		modes.setServiceAvailable(false);
		require(dock.snapshotJson() == editor && side.encode() == editorSidebar && !modes.leftChanged && !modes.rightChanged && !modes.bottomChanged, "automatic mode round trip changed layout or customization flags");
		modes.select("agents"); dock.setSplitRatio([1], 0.61);
		require(modes.rightChanged && !modes.leftChanged, "right resize marked the wrong region");
		var resized = dock.snapshotJson(); modes.select("editor");
		require(regions.rightOpen() && dock.snapshotJson() == resized, "mode switch changed a manually resized right region");
		regions.toggleBottom(); require(modes.bottomChanged, "manual bottom toggle was not tracked");
		modes.select("agents"); require(regions.bottomOpen(), "Agents hid a manually opened bottom region");
		modes.markLeft(); side.select("files"); modes.select("editor");
		require(side.activeId == "files" && !modes.hides("files"), "Editor replaced a manual sidebar selection or hid Files");
		modes.select("agents");
		// Agents keeps Files, Search and Source Control off the rail; the right panel shows the group's instead.
		require(side.activeId == "workbench" && modes.hides("files") && modes.hides("search") && modes.hides("scm") && !modes.hides("workbench"),
			"Agents left an editor-workspace destination selected or on the rail");
		var filesMode = side.find("files"), scmMode = side.find("scm");
		require(filesMode != null && filesMode.visible && scmMode != null && scmMode.visible, "Agents changed the user's own destination visibility");
		var context = modes.captureContext(), window = modes.captureWindow(), snapshot = dock.snapshotJson();
		var next = model(), nextSide = sidebar(next), nextRegions = new WorkbenchLayoutControls(next), nextModes = new WorkbenchLayoutModes(next, nextSide, nextRegions, function() {});
		next.restoreJson(snapshot); nextSide.restore(side.encode()); nextModes.restoreWindow([window]); nextModes.restoreContext([context]); nextModes.start("auto");
		require(nextModes.current.id == "agents" && nextModes.rightChanged && nextModes.bottomChanged && nextModes.leftChanged && next.snapshotJson() == snapshot, "restart lost mode or manual region state");
		nextModes.restoreContext([]); nextModes.refreshContext();
		require(!nextModes.rightChanged && !nextModes.bottomChanged && !nextRegions.bottomOpen(), "fresh context inherited manual flags");
		nextModes.restoreContext([context]); nextModes.refreshContext(); require(nextModes.rightChanged, "returning context lost flags");
		nextModes.setPreference("editor"); require(nextModes.current.id == "editor" && nextModes.choice == "auto", "live setting did not override window default");
		nextModes.select("agents"); nextModes.setServiceAvailable(false); require(nextModes.current.id == "agents", "disconnect overrode explicit window choice");
		var prefs = new config.Preferences(); prefs.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("agents"));
		require(prefs.current.layoutMode == "agents" && prefs.current.copy().layoutMode == "agents", "layout mode setting was not applied/copied");
		require(prefs.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("invalid")) != null && prefs.current.layoutMode == "agents", "invalid layout preset was accepted");
		var saved = new session.WorkspaceSession(); saved.layout.push(context); saved.layout.push(window);
		require(session.WorkspaceSession.decode(saved.encode()).layout.length == 2, "mode metadata was discarded by session codec");
		var offlineDock = model(), offlineSide = sidebar(offlineDock); offlineSide.unregister("workbench");
		var panelAvailable = true;
		var offlineRegions = new WorkbenchLayoutControls(offlineDock), offlineModes = new WorkbenchLayoutModes(offlineDock, offlineSide, offlineRegions,
			function() {}, function() return panelAvailable);
		offlineModes.start("agents");
		// Before a Workbench exists, hiding Files, Search and Source Control would leave the rail empty and the sidebar
		// closed, so the rail keeps them and Files opens.
		require(!offlineModes.hides("files") && !offlineModes.hides("search") && !offlineModes.hides("scm") && offlineSide.visible
			&& offlineSide.activeId == "files" && offlineDock.isOpen("explorer") && offlineRegions.rightOpen(),
			"Agents without a Workbench left the sidebar closed with nothing on the rail");
		offlineSide.register("workbench", function() return new Text("Workbench"), new SidebarModeOptions("Workbench", 20, true));
		offlineModes.refreshSidebar();
		require(offlineSide.activeId == "workbench" && offlineSide.visible && offlineModes.hides("files") && !offlineModes.leftChanged,
			"late Workbench provider did not activate the untouched default or take Files off the rail");
		// With the Workbench there but no right panel (phone width, a hidden panel, a remote workspace), Agents still
		// opens the Workbench and leaves Files on the rail.
		panelAvailable = false; offlineModes.refreshSidebar();
		require(offlineSide.activeId == "workbench" && !offlineModes.hides("files"), "Agents without a right panel hid Files or left the Workbench");
		// The panel coming and going without a mode change (a narrow window widening) re-applies the rail: Files, opened
		// while the rail had it, leaves the sidebar for the mode's default once the right panel shows it again.
		var inputs = function() return panelAvailable ? 1 : 0;
		offlineModes.syncRail(inputs());
		var computed = offlineModes.railComputations, hidden = offlineModes.hiddenOnRail();
		for (_ in 0...3) offlineModes.syncRail(inputs());
		require(offlineModes.railComputations == computed && offlineModes.hiddenOnRail() == hidden,
			"syncRail worked the rail out again, or rebuilt its list, with nothing changed");
		offlineModes.markLeft(); offlineSide.select("files");
		panelAvailable = true;
		offlineModes.syncRail(inputs());
		require(offlineModes.hiddenOnRail().join(",") == "files,search,scm", "widening the window did not re-apply the rail");
		require(offlineSide.activeId == "workbench" && offlineSide.visible, "the sidebar still showed Files after it left the rail");
		computed = offlineModes.railComputations;
		offlineModes.syncRail(inputs());
		require(offlineModes.railComputations == computed, "the rail was worked out twice for one change");
		// Closing the right panel by hand brings them back to the rail, and the sidebar keeps what it shows.
		offlineRegions.toggleRight();
		offlineModes.syncRail(inputs());
		require(offlineModes.hiddenOnRail().length == 0 && offlineSide.activeId == "workbench",
			"closing the right panel did not return Files to the rail");
		offlineModes.dispose(); offlineRegions.dispose();
		var legacyDock = model(), legacySide = sidebar(legacyDock), legacyRegions = new WorkbenchLayoutControls(legacyDock);
		var legacyModes = new WorkbenchLayoutModes(legacyDock, legacySide, legacyRegions, function() {});
		legacyModes.restoreContext(["D\tdock\t1\t" + legacyDock.snapshotJson(), legacyRegions.capture()]); legacyModes.start("auto");
		require(!legacyRegions.bottomOpen() && !legacyModes.bottomChanged, "legacy default bottom was mistaken for customization");
		legacyModes.suspend(); legacyDock.setSplitRatio([1], 0.5); legacyRegions.toggleBottom(); legacyModes.resume();
		legacyModes.restoreContext(["D\tdock\t1\t" + legacyDock.snapshotJson(), "L\tregions\t1\t0.5\t0.6\tunused"]);
		require(legacyModes.bottomChanged && legacyModes.rightChanged, "legacy saved region sizes were not protected");
		legacyModes.dispose(); legacyRegions.dispose();
		var userDock = model(), userSide = sidebar(userDock), userRegions = new WorkbenchLayoutControls(userDock);
		var userModes = new WorkbenchLayoutModes(userDock, userSide, userRegions, function() {});
		userModes.start("auto");
		require(userSide.moveMode("scm", "files") && userSide.modes[0].id == "scm", "Activity Bar move did not reorder");
		userModes.setServiceAvailable(true);
		require(userSide.modes[0].id == "scm" && userSide.modes[1].id == "files", "Agents preset overrode the user's Activity Bar order");
		require(userSide.resetOrder() && userSide.modes[0].id == "workbench", "reset did not return to the preset order");
		userModes.dispose(); userRegions.dispose();
		modes.dispose(); regions.dispose(); nextModes.dispose(); nextRegions.dispose();
		trace("PASS: user Activity Bar order over presets, mode defaults, automatic/explicit/preference precedence, reversible presets, manual resize/visibility, sidebar reachability with and without the right panel, context flags and restart metadata");
		return 0;
	}
}
