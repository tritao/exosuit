package app;

import ui.UiImageTab;
import ui.UiEditorTabs;
import ui.UiWorkbenchHost;
import ui.ImagePreviewView;
import workspace.TextFileContent;
import workspace.UnsupportedTextFile;

class ImagePreviewTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function checkUnsupportedFiles(host:UiWorkbenchHost, workspace:workspace.Workspace):Void {
		var previous = host.activeTab();
		var fixture = "build/binary-preview.bin";
		var bytes = haxe.io.Bytes.alloc(5000);
		bytes.set(0, 0x7f); bytes.set(1, 0x45); bytes.set(2, 0); bytes.set(3, 0x80);
		sys.io.File.saveBytes(fixture, bytes);
		var opened = host.openFile(fixture, true);
		var tab = UiEditorTabs.unsupportedFile(host.activeTab());
		if (tab == null) throw "binary file did not open a warning tab";
		require(tab.file.binary && tab.file.sizeBytes == 5000 && tab.file.previewBytes == 4096, "binary classification or bounded preview");
		require(tab.file.bytePreview.indexOf("7F 45 00 80") >= 0, "byte preview lost NUL or invalid bytes");
		require(workspace.documents.documents.length == 0 && host.openFile(fixture, false) == opened && !tab.preview,
			"binary file became editable or reopened as a duplicate");
		var invalid = haxe.io.Bytes.alloc(2); invalid.set(0, 0xc0); invalid.set(1, 0x80);
		var invalidEncoding = false;
		try TextFileContent.decode(invalid, "invalid") catch (error:Dynamic) {
			if (Std.isOfType(error, UnsupportedTextFile)) {
				var file:UnsupportedTextFile = cast error; invalidEncoding = !file.binary;
			}
		}
		require(invalidEncoding, "invalid UTF-8 reached the text decoder");
		require(TextFileContent.decode(haxe.io.Bytes.ofString("Hello 🙂\n"), "valid") == "Hello 🙂\n", "valid UTF-8 changed");
		require(ui.FileSizeLabel.format(1024) == "1.00 KB" && ui.FileSizeLabel.format(12) == "12 B", "file size status labels");
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf", haxeon.ui.FontFamily.Monospace);
		var session = haxeon.ui.LayoutSession.create(), context = new haxeon.ui.core.UiContext(session, fonts);
		var view = new ui.UnsupportedFileView(tab, function() {});
		var root = context.submit(view, new haxeon.ui.LayoutFrame(640, 480));
		var button:Null<haxeon.ui.Rect> = null;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.label == "View Bytes") button = node.globalBounds();
		});
		if (button == null) throw "byte preview action missing";
		context.pointerDown(button.x + button.width / 2, button.y + button.height / 2, 0);
		context.pointerUp(button.x + button.width / 2, button.y + button.height / 2, 0);
		require(tab.showBytes, "byte preview action did not activate");
		context.submit(view, new haxeon.ui.LayoutFrame(640, 480));
		context.dispose(); session.dispose(); fonts.dispose();
		var binaryItem = host.activeTab();
		require(host.sessionLines().join("\n").indexOf("B\teditor\t") >= 0, "binary tab not persisted");
		host.closeTab(binaryItem, "editor");
		if (previous != null) host.activateEditorTab(UiEditorTabs.key(previous), "editor");
		sys.FileSystem.deleteFile(fixture);
	}

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
		checkUnsupportedFiles(host, workspace);
		var remaining = UiEditorTabs.image(host.activeTab());
		if (remaining == null) throw "missing remaining image";
		host.dispose();
		require(remaining.image.isDisposed(), "shutdown leaked image resource");
		Sys.println("PASS: PNG image tabs, fit geometry, decode failure, preview replacement, session restore and resource cleanup");
		return 0;
	}
}
