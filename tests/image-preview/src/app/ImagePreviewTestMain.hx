package app;

import ui.UiImageTab;
import ui.UiEditorTabs;
import ui.UiWorkbenchHost;
import ui.ImagePreviewView;

class ImagePreviewTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function main():Int {
		var syntax = new syntax.SyntaxRegistry();
		var workspace = new workspace.Workspace(syntax);
		var dock = new haxeon.ui.docking.DockWorkspaceModel();
		dock.register(new haxeon.ui.docking.DockPanelDescriptor("editor", "Editor"));
		dock.setDefaultLayout(haxeon.ui.docking.DockNode.Panel("editor"));
		var host = new UiWorkbenchHost(new style.Theme(), new core.FocusManager(), workspace,
			new config.Settings(), function() {}, {
				model: dock, focusEditor: function(_) {}, editorPreedit: function(_, _) {},
				toggleSidebar: function() return false, activateExplorer: function() {},
				activateProblems: function() {}, activateBuild: function() {}
			});
		var firstPath = "../../graphical/assets/icons/exosuit-32.png";
		var secondPath = "../../graphical/assets/icons/exosuit-64.png";
		require(UiImageTab.supports("IMAGE.PNG") && !UiImageTab.supports("source.hx"), "image routing");
		var first = host.openImage(firstPath, true);
		require(first.image.width == 32 && first.image.height == 32, "PNG decode dimensions");
		require(host.tabs.length == 0 && workspace.documents.documents.length == 0 && host.activeView() == null,
			"image was registered as an editable document");
		require(host.openImage(firstPath, true) == first, "reopening duplicated the image");
		var failed = false;
		try host.openImage("../../graphical/haxeon.json", true) catch (_:Dynamic) failed = true;
		require(failed && !first.image.isDisposed() && UiEditorTabs.image(host.activeTab()) == first,
			"failed decode replaced the existing preview");
		var second = host.openImage(secondPath, true);
		var pane = host.paneById("editor");
		if (pane == null) throw "missing editor pane";
		require(first.image.isDisposed() && pane.items.length == 1, "preview replacement leaked");
		host.keepImage(second);
		first = host.openImage(firstPath, true);
		require(!second.preview && pane.items.length == 2, "kept image was replaced");

		var bounds = ImagePreviewView.fittedBounds(400, 200, 100, 100);
		require(bounds.width == 100 && bounds.height == 50 && bounds.y == 25, "fit distorted aspect ratio");
		bounds = ImagePreviewView.fittedBounds(32, 32, 100, 100);
		require(bounds.width == 32 && bounds.x == 34, "small image was upscaled");
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var session = haxeon.ui.LayoutSession.create();
		var context = new haxeon.ui.core.UiContext(session, fonts);
		var root = context.submit(new ImagePreviewView(first, function() {}), new haxeon.ui.LayoutFrame(240, 180));
		var previewWidth = 0.0, previewHeight = 0.0;
		root.walk(function(node) {
			var geometry = node.resolved;
			if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.Image && geometry != null) {
				previewWidth = geometry.width; previewHeight = geometry.height;
			}
		});
		require(previewWidth > 100 && previewHeight > 100, "image surface collapsed during layout");
		context.dispose(); session.dispose(); fonts.dispose();

		require(host.splitActive(view.LayoutKind.Horizontal), "split editor pane");
		var right = host.paneById("editor-pane-1");
		if (right == null) throw "missing split pane";
		pane.bounds = new haxeon.ui.Rect(0, 0, 200, 200);
		right.bounds = new haxeon.ui.Rect(200, 0, 200, 200);
		var duplicate = host.openImage(firstPath);
		require(host.moveActiveTab(-1, 0) && duplicate.image.isDisposed() && pane.items.length == 2,
			"moving an image produced duplicate tab keys or leaked its resource");

		var saved = host.sessionLines();
		host.restoreSessionLines(saved);
		pane = host.paneById("editor");
		if (pane == null) throw "missing restored editor pane";
		require(first.image.isDisposed() && second.image.isDisposed(), "restore leaked old resources");
		require(pane.items.length == 2 && UiEditorTabs.image(host.activeTab()) != null,
			"image tabs or selection were not restored");
		var restored = UiEditorTabs.image(host.activeTab());
		if (restored == null) throw "missing restored image";
		require(host.closeTab(host.activeTab(), "editor") && restored.image.isDisposed(), "close leaked image resource");
		var remaining = UiEditorTabs.image(host.activeTab());
		if (remaining == null) throw "missing remaining image";
		host.dispose();
		require(remaining.image.isDisposed(), "shutdown leaked image resource");
		Sys.println("PASS: PNG image tabs, fit geometry, decode failure, preview replacement, session restore and resource cleanup");
		return 0;
	}
}
