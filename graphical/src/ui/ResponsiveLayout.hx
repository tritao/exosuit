package ui;





import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockDropZone;
import haxeon.ui.widgets.docking.DockWorkspace;

/**
	How the window's dock follows its width: the right panel hides on a narrow window, and a phone-sized window shows
	one panel at a time and puts the desktop layout back when it widens. ExosuitApp owns one.
**/
@:allow(ui)
class ResponsiveLayout {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	static inline var MINIMUM_COMPACT_WIDTH:Float = 480.0;
	static inline var RESPONSIVE_RESTORE_MARGIN:Float = 48.0;
	static inline var MINIMUM_CONTENT_WIDTH:Float = 320.0;
	/** Evaluate the saved splits, even while secondary panels are suppressed. */
	function preferredContentWidth(node:DockNode, width:Float):Float {
		return switch node {
			case Split(axis, ratio, first, second):
				var firstWidth = width;
				var secondWidth = width;
				if (axis == DockSplitAxis.Horizontal) {
					var extent = switch first { case Panel("explorer"): app.sidebar.width; case _: ratio * width; };
					firstWidth = Math.max(DockWorkspace.MinimumHorizontalExtent,
						Math.min(extent,Math.max(DockWorkspace.MinimumHorizontalExtent,width-DockWorkspace.MinimumHorizontalExtent)));
					secondWidth = Math.max(0,width-firstWidth-DockWorkspace.DividerExtent);
				}
				haxeon.ui.docking.DockNodeTools.contains(first,app.host.activePane.id)
					? preferredContentWidth(first,firstWidth) : preferredContentWidth(second,secondWidth);
			case _: width;
		};
	}
	function syncResponsiveRightLayout():Void {
		if (app.phoneLayoutActive) { app.responsiveRightHidden = true; return; }
		var margin = app.responsiveRightHidden ? RESPONSIVE_RESTORE_MARGIN : 0;
		var open = app.dock.isOpen("context-panel");
		var workspaceWidth = Math.max(0,app.viewportWidth-ActivityBar.WIDTH);
		var available = preferredContentWidth(app.dock.root,workspaceWidth);
		// The panel's split cannot give either side less than DockWorkspace.MinimumHorizontalExtent, so the panel
		// needs room for its own minimum beside a usable content area; otherwise it would overflow the window.
		var region = contextRegionWidth(app.dock.root,workspaceWidth,workspaceWidth);
		app.responsiveRightHidden = open && (available < MINIMUM_CONTENT_WIDTH + margin
			|| region < MINIMUM_CONTENT_WIDTH + DockWorkspace.DividerExtent + DockWorkspace.MinimumHorizontalExtent + margin);
	}
	/** The width of the split that holds the right panel, after the splits above it (the sidebar) took their share. */
	function contextRegionWidth(node:DockNode, width:Float, parentWidth:Float):Float {
		return switch node {
			case Split(axis, ratio, first, second):
				var inFirst = haxeon.ui.docking.DockNodeTools.contains(first,"context-panel");
				if (!inFirst && !haxeon.ui.docking.DockNodeTools.contains(second,"context-panel")) return width;
				var firstWidth = width;
				var secondWidth = width;
				if (axis == DockSplitAxis.Horizontal) {
					var extent = switch first { case Panel("explorer"): app.sidebar.width; case _: ratio * width; };
					firstWidth = Math.max(DockWorkspace.MinimumHorizontalExtent,
						Math.min(extent,Math.max(DockWorkspace.MinimumHorizontalExtent,width-DockWorkspace.MinimumHorizontalExtent)));
					secondWidth = Math.max(0,width-firstWidth-DockWorkspace.DividerExtent);
				}
				var child = inFirst ? first : second;
				switch child {
					case Split(_, _, _, _): contextRegionWidth(child,inFirst ? firstWidth : secondWidth,width);
					case _: width;
				}
			case _: parentWidth;
		};
	}
	/** At phone width, show the sidebar or editor as one full-width workspace. */
	function syncResponsiveDockLayout():Void {
		var preferredSidebarWidth = app.phoneLayoutActive ? app.desktopSidebarWidth : app.sidebar.width;
		var prefersSidebar = app.phoneLayoutActive ? app.desktopSidebarVisible : app.sidebar.visible;
		var compactWidth = Math.max(MINIMUM_COMPACT_WIDTH, ActivityBar.WIDTH + MINIMUM_CONTENT_WIDTH
			+ (prefersSidebar ? preferredSidebarWidth + DockWorkspace.DividerExtent : 0));
		var phone = app.viewportWidth > 0 && app.viewportWidth <= compactWidth
			+ (app.phoneLayoutActive ? RESPONSIVE_RESTORE_MARGIN : 0);

		if (phone) {
			if (!app.phoneLayoutActive) {
				app.desktopSidebarWidth = app.sidebar.width;
				app.desktopSidebarVisible = app.sidebar.visible;
				app.desktopDockRoot = haxeon.ui.docking.DockNodeTools.clone(app.dock.root);
				app.desktopDockActivePanel = app.dock.activePanelId;
				app.phoneContentRoot = haxeon.ui.docking.DockNodeTools.remove(haxeon.ui.docking.DockNodeTools.remove(app.desktopDockRoot, "explorer"), "context-panel");
				app.phoneLayoutActive = true;
				// An open editor/agent/terminal remains the task when the window narrows.
				if ((app.host.activeTab() != null && app.desktopDockActivePanel != "explorer") || app.desktopDockActivePanel == "terminal") app.sidebar.setVisible(false);
			} else if (!app.sidebar.visible) {
				app.phoneContentRoot = haxeon.ui.docking.DockNodeTools.clone(app.dock.root);
			}
			syncPhoneDockRoot();
			return;
		}
		if (!app.phoneLayoutActive) return;

		if (!app.sidebar.visible) app.phoneContentRoot = haxeon.ui.docking.DockNodeTools.clone(app.dock.root);
		app.phoneLayoutActive = false;
		app.phoneModeApplying = true;
		app.sidebar.setVisible(app.desktopSidebarVisible);
		app.sidebar.rememberWidth(app.desktopSidebarWidth);
		app.phoneModeApplying = false;
		var restored = app.sidebar.visible ?
			(app.desktopDockRoot == null ? haxeon.ui.docking.DockNodeTools.clone(app.dock.root) :
				haxeon.ui.docking.DockNodeTools.clone(app.desktopDockRoot)) :
			(app.phoneContentRoot == null ? haxeon.ui.docking.DockNodeTools.remove(app.dock.root, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(app.phoneContentRoot));
		if (!app.sidebar.visible) restored = haxeon.ui.docking.DockNodeTools.remove(restored, "explorer");
		if (app.desktopDockRoot != null && haxeon.ui.docking.DockNodeTools.contains(app.desktopDockRoot, "context-panel") && !haxeon.ui.docking.DockNodeTools.contains(restored, "context-panel"))
			restored = app.layoutControls.withRight(restored);
		if (!haxeon.ui.docking.DockNodeTools.same(app.dock.root, restored)) app.dock.setRoot(restored);
		if (app.sidebar.visible && !app.dock.isOpen("explorer")) {
			var target = app.dock.isOpen(app.host.activePane.id) ? app.host.activePane.id :
				haxeon.ui.docking.DockNodeTools.firstPanel(app.dock.root);
			if (target == null) app.dock.open("explorer");
			else app.dock.dock("explorer", target, DockDropZone.Left);
		} else if (!app.sidebar.visible && app.desktopDockActivePanel != null && app.dock.isOpen(app.desktopDockActivePanel)) {
			app.dock.activate(app.desktopDockActivePanel);
		}
		app.desktopDockRoot = null;
		app.desktopDockActivePanel = null;
		app.phoneContentRoot = null;
	}
	function syncPhoneDockRoot():Void {
		if (!app.phoneLayoutActive) return;
		var target = app.sidebar.visible ? DockNode.Panel("explorer") :
			(app.phoneContentRoot == null ? haxeon.ui.docking.DockNodeTools.remove(app.dock.root, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(app.phoneContentRoot));
		if (!haxeon.ui.docking.DockNodeTools.same(app.dock.root, target)) app.dock.setRoot(target);
	}
	function captureDockLayout():String {
		if (!app.phoneLayoutActive || app.desktopDockRoot == null) return app.dock.snapshotJson();
		var layout:DockNode;
		var active:Null<String>;
		if (app.desktopSidebarVisible) {
			layout = haxeon.ui.docking.DockNodeTools.clone(app.desktopDockRoot);
			if (!haxeon.ui.docking.DockNodeTools.contains(layout, "explorer")) {
				var content = app.phoneContentRoot == null ?
					haxeon.ui.docking.DockNodeTools.remove(layout, "explorer") :
					haxeon.ui.docking.DockNodeTools.clone(app.phoneContentRoot);
				var width = Math.max(1.0, 1280.0 - ActivityBar.WIDTH - DockWorkspace.DividerExtent);
				layout = DockNode.Split(DockSplitAxis.Horizontal, Math.min(0.9, app.desktopSidebarWidth / width),
					DockNode.Panel("explorer"), content);
			}
			active = "explorer";
		} else {
			layout = app.phoneContentRoot == null ?
				haxeon.ui.docking.DockNodeTools.remove(app.desktopDockRoot, "explorer") :
				haxeon.ui.docking.DockNodeTools.clone(app.phoneContentRoot);
			active = app.desktopDockActivePanel;
		}
		if (haxeon.ui.docking.DockNodeTools.contains(app.desktopDockRoot, "context-panel") && !haxeon.ui.docking.DockNodeTools.contains(layout, "context-panel"))
			layout = app.layoutControls.withRight(layout);
		if (active != null && !haxeon.ui.docking.DockNodeTools.contains(layout, active))
			active = haxeon.ui.docking.DockNodeTools.firstPanel(layout);
		return haxeon.ui.docking.DockWorkspaceSnapshotCodec.encode(
			new haxeon.ui.docking.DockWorkspaceSnapshot(layout, active));
	}
}
