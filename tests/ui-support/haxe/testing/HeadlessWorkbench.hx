package testing;

import config.Settings;
import core.FocusManager;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.Rect;
import style.Theme;
import ui.UiWorkbenchHost;
import workspace.Workspace;

/**
	The editor's real workbench host, without a window: a dock with only the editor panel, nothing to do when the host
	asks for a frame, focus or a side panel, and, since no layout runs, a caret at a fixed place for language popups to
	open against. `create` fits `core.Application`'s host factory.
**/
class HeadlessWorkbench {
	public static function create(theme:Theme, focus:FocusManager, workspace:Workspace, settings:Settings):UiWorkbenchHost {
		var dock = new DockWorkspaceModel();
		dock.register(new DockPanelDescriptor("editor", "Editor"));
		dock.setDefaultLayout(DockNode.Panel("editor"));
		var host = new UiWorkbenchHost(theme, focus, workspace, settings == null ? new Settings() : settings, function() {}, {
			model: dock, focusEditor: function(_) {}, editorPreedit: function(_, _) {},
			toggleSidebar: function() return false, activateExplorer: function() {},
			activateProblems: function() {}, activateBuild: function() {}
		});
		host.caretRectProvider = function() return new Rect(0, 0, 1, 16);
		return host;
	}
}
