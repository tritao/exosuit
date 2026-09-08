package app;

import core.Application;
import editor.Document;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import view.LayoutKind;
import view.LayoutNode;
import editor.BufferSelection;

class ApplicationTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		Platform.startHeadless();
		var welcome = new view.WelcomeView(), welcomeActions = 0;
		welcome.newFile = function() { welcomeActions++; };
		require(welcome.mouseDown(146, 150, 0, 0, 640, 320) && welcomeActions == 1,
			"welcome action hit testing did not invoke its controller callback");
		var window = Native.window_create("application-test", 640, 320), renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application(renderer, 640, 320, null, new session.RecentProjects("")), first = new Document("first", "one", application.syntaxes),
			second = new Document("second", "two", application.syntaxes);
		var firstView = application.add(first), secondView = application.add(second);
		require(style.Theme.contrastRatio(application.theme.editorForeground, application.theme.editorBackground) >= 4.5
			&& style.Theme.contrastRatio(application.theme.editorBackground, application.theme.accent) >= 4.5
			&& style.Theme.contrastRatio(application.theme.foregroundMuted, application.theme.surface) >= 4.5,
			"default editor, active-row, or secondary text contrast was below WCAG AA");
		application.setComposition("に😀", 1, 1);
		var compositionArea = application.root.textInputArea();
		require(second.buffer.text == "two" && compositionArea != null,
			"document composition mutated text or lacked candidate placement");
		application.clearComposition();
		require(second.buffer.text == "two", "clearing document composition mutated text");
		application.root.displayScaleChanged(1750);
		require(application.root.displayScaleMilli == 1750 && application.root.node.width == 640 - view.Sidebar.WIDTH,
			"display-scale change altered the logical layout coordinate space");
		require(application.root.status.text(secondView).indexOf("second") >= 0
			&& application.root.status.text(secondView).indexOf("Ln 1, Col 1") >= 0
			&& application.root.status.text(secondView).indexOf("UTF-8") >= 0,
			"status did not expose document position and encoding");
		for (index in 0...120) application.root.notifications.publish("message " + index);
		var currentNotification = application.root.notifications.current();
		require(application.root.notifications.entries.length == 100 && currentNotification != null
			&& currentNotification.message == "message 119", "notification retention was not bounded");
		if (currentNotification == null) throw "missing current notification";
		require(application.root.notifications.current(currentNotification.createdAt + feedback.NotificationCenter.DISPLAY_SECONDS + 0.1) == null,
			"expired notification remained pinned over the editor");
		for (index in 0...220) application.errors.record("test", "error " + index);
		require(application.errors.entries.length == 200 && application.errors.entries[0].message == "error 20",
			"error-log retention was not bounded");
		var missingPluginLoaded = application.loadPluginManifest("/missing/plugin.conf"), pluginNotification = application.root.notifications.current();
		require(!missingPluginLoaded && application.errors.entries[199].source == "plugin"
			&& pluginNotification != null && pluginNotification.kind == feedback.NotificationKind.Error,
			"plugin failure did not reach the error log and notification center");
		application.openErrorLog();
		require(application.root.commandView.active && application.root.commandView.results.length == 200,
			"error log was not inspectable through command input");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		var untitledOne = application.documents.createUntitled(), untitledTwo = application.documents.createUntitled();
		require(untitledOne != untitledTwo && untitledOne.id != untitledTwo.id && !untitledOne.hasBackingPath() && !untitledOne.save(),
			"untitled documents were not distinct or attempted persistence without Save As");
		application.documents.close(untitledOne, true);
		application.documents.close(untitledTwo, true);
		require(application.documents.documents.length == 2 && application.root.tabs.views.length == 2, "documents did not open as tabs");
		require(application.root.reorderActiveTab(-1) && application.root.tabs.views[0] == secondView
			&& application.root.reorderActiveTab(1) && application.root.tabs.views[1] == secondView, "tab reordering failed");
		var tabY = 10, secondTabX = application.root.activeLeaf.x + view.RootView.TAB_WIDTH + 20,
			firstTabX = application.root.activeLeaf.x + 20;
		application.root.mouseDown(Platform.MOUSE_LEFT, secondTabX, tabY);
		application.root.mouseMove(firstTabX, tabY);
		application.root.mouseUp(Platform.MOUSE_LEFT);
		require(application.root.tabs.views[0] == secondView && application.root.reorderActiveTab(1),
			"mouse tab drag did not reorder within the pane");
		application.root.mouseDown(Platform.MOUSE_RIGHT, application.root.activeLeaf.x + 20, editor.EditorView.HEADER_HEIGHT + 20);
		require(application.root.contextMenu.visible, "editor right click did not open a context menu");
		application.root.mouseDown(Platform.MOUSE_LEFT, 0, 0);
		require(!application.root.contextMenu.visible, "outside click did not dismiss the context menu");
		require(application.add(second) == secondView && application.root.tabs.views.length == 2, "document tab was not reused");
		require(application.focus.activeView == secondView, "new tab did not receive focus");
		application.commands.perform("doc:newline", application.context);
		require(second.buffer.text == "\ntwo" && first.buffer.text == "one", "command did not target active document");
		require(application.root.status.text(secondView).indexOf("* second") >= 0
			&& application.root.status.text(secondView).indexOf("Ln 2") >= 0,
			"status did not update dirty state and caret position");
		var clipboardView = application.root.tabs.activeView;
		if (clipboardView == null) throw "clipboard test has no active view";
		require(Native.clipboard_set("Olá\r\n😀"), "headless clipboard write failed");
		clipboardView.selectAll();
		application.keyPressed(Platform.KEY_V, Platform.MOD_CTRL);
		require(second.buffer.text == "Olá\n😀", "clipboard paste did not normalize multiline Unicode text");
		clipboardView.undo();
		require(second.buffer.text == "\ntwo", "clipboard paste was not one undo unit");
		clipboardView.selectAll();
		application.keyPressed(Platform.KEY_C, Platform.MOD_CTRL);
		require(Native.clipboard_get() == "\ntwo", "clipboard copy did not preserve multiline text");
		application.keyPressed(Platform.KEY_X, Platform.MOD_CTRL);
		require(second.buffer.text == "", "clipboard cut did not remove the selection");
		application.keyPressed(Platform.KEY_V, Platform.MOD_CTRL);
		require(second.buffer.text == "\ntwo", "clipboard paste did not restore copied text");
		clipboardView.undo();
		require(second.buffer.text == "", "clipboard paste undo restored the wrong transaction");
		clipboardView.undo();
		require(second.buffer.text == "\ntwo", "clipboard cut undo did not restore the selection");
		var multipleView = application.newDocument(), multipleDocument = multipleView.getDocument(), multipleSelection = multipleView.getSelection();
		if (multipleDocument == null || multipleSelection == null) throw "multiple-selection view has no editor state";
		multipleView.textInput("one one one");
		multipleView.selectRange(new editor.BufferPosition(0, 0), new editor.BufferPosition(0, 3));
		require(multipleView.selectNextOccurrence() && multipleView.selectNextOccurrence()
			&& multipleSelection.rangeCount() == 3, "next occurrence did not build three selections");
		application.commands.perform("doc:copy", application.context);
		require(Native.clipboard_get() == "one\none\none", "multi-selection copy distribution failed");
		Native.clipboard_set("a\nb\nc");
		application.commands.perform("doc:paste", application.context);
		require(multipleDocument.buffer.text == "a b c", "multi-selection paste distribution failed");
		multipleView.undo();
		require(multipleDocument.buffer.text == "one one one" && multipleSelection.rangeCount() == 3,
			"multi-selection undo did not restore content and ranges");
		multipleView.redo();
		require(multipleDocument.buffer.text == "a b c" && multipleSelection.rangeCount() == 3,
			"multi-selection redo failed");
		require(application.root.closeActiveTab(true), "multiple-selection test tab did not close");
		require(application.keyPressed(Platform.KEY_G, Platform.MOD_CTRL) && application.root.commandView.active,
			"named go-to-line command did not open command input");
		application.textInput("2:2");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(clipboardView.cursorLine() == 1 && clipboardView.cursorColumn() == 1, "go-to-line/column did not restore the requested caret");
		application.commands.perform("root:switch-to-previous-tab", application.context);
		require(application.focus.activeView == firstView, "tab switch did not update focus");
		application.commands.perform("doc:newline", application.context);
		require(first.buffer.text == "\none", "command context captured the wrong document");
		application.root.mouseDown(Platform.MOUSE_LEFT, application.root.activeLeaf.x + view.RootView.TAB_WIDTH - 5, 10);
		require(application.root.commandView.active, "tab close control bypassed the dirty-document coordinator");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		require(!application.root.commandView.active && application.documents.documents.indexOf(first) >= 0,
			"Escape did not cancel the close transaction");
		application.root.mouseDown(Platform.MOUSE_LEFT, application.root.activeLeaf.x + view.RootView.TAB_WIDTH - 5, 10);
		require(application.root.commandView.active, "close coordinator remained pending after Escape cancellation");
		application.textInput("cancel");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.indexOf(first) >= 0, "cancelled document close released the document");
		require(first.buffer.text == "\none", "prompt input mutated the inactive document");
		require(!application.root.commandView.active, "cancelled document close left its prompt active");
		require(application.requestCloseActiveTab(), "document close could not restart after cancellation");
		application.textInput("discard");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.length == 1 && application.focus.activeView == secondView,
			"closing a tab did not reconcile ownership and focus");
		application.commands.perform("root:split-right", application.context);
		require(!application.root.node.isLeaf() && application.root.node.requireFirst().width + application.root.node.requireSecond().width
			+ LayoutNode.DIVIDER_SIZE == 640 - view.Sidebar.WIDTH, "horizontal split did not assign recursive bounds");
		require(application.documents.documents.length == 1 && application.root.node.containsDocument(second),
			"split duplicated document ownership");
		var leftView = application.root.node.requireFirst().tabs.activeView, rightView = application.root.node.requireSecond().tabs.activeView;
		if (leftView == null || rightView == null) throw "split views are missing";
		require(application.root.focusPane(-1, 0) && application.root.activeLeaf == application.root.node.requireFirst()
			&& application.root.focusPane(1, 0) && application.root.activeLeaf == application.root.node.requireSecond(),
			"directional pane focus failed");
		var movable = application.newDocument();
		require(application.root.moveActiveTab(-1, 0) && application.root.activeLeaf == application.root.node.requireFirst()
			&& application.root.tabs.activeView == movable, "moving a tab to the left pane failed");
		require(application.root.moveActiveTab(1, 0) && application.root.activeLeaf == application.root.node.requireSecond()
			&& application.root.closeActiveTab(true), "moving a tab back or closing it failed");
		leftView.restoreCursor(1, 1);
		rightView.restoreCursor(1, 2);
		application.root.activateLeaf(application.root.node.requireFirst());
		require(leftView.cursorLine() == 1 && leftView.cursorColumn() == 1, "left pane did not restore its cursor");
		application.root.activateLeaf(application.root.node.requireSecond());
		require(rightView.cursorLine() == 1 && rightView.cursorColumn() == 2, "right pane did not retain an independent cursor");
		rightView.restoreCursor(0, 0);
		application.commands.perform("doc:newline", application.context);
		application.root.activateLeaf(application.root.node.requireFirst());
		require(leftView.cursorLine() == 2 && leftView.cursorColumn() == 1,
			"edit in one pane did not transform the other pane's cursor");
		application.root.activateLeaf(application.root.node.requireSecond());
		var divider = application.root.node.requireFirst().x + application.root.node.requireFirst().width;
		application.root.mouseDown(Platform.MOUSE_LEFT, divider + 1, 100);
		application.root.mouseMove(520, 100);
		application.root.mouseUp(Platform.MOUSE_LEFT);
		require(application.root.node.divider > 600, "divider drag did not resize panes");
		application.root.mouseDown(Platform.MOUSE_LEFT, application.root.sidebar.width, 100);
		application.root.mouseMove(260, 100);
		application.root.mouseUp(Platform.MOUSE_LEFT);
		require(application.root.sidebar.width == 260, "sidebar drag resize failed");
		require(application.root.toggleSidebar() && !application.root.sidebarVisible && application.root.node.x == 0,
			"sidebar toggle did not release editor space");
		application.root.resize(200, 180);
		require(application.root.node.width == 200, "narrow hidden-sidebar layout became inoperable");
		application.root.resize(640, 320);
		application.root.toggleSidebar();
		application.root.setSidebarWidth(220);
		application.commands.perform("root:split-up", application.context);
		require(!application.root.node.requireSecond().isLeaf()
			&& application.root.node.requireSecond().kind == LayoutKind.Vertical, "nested vertical split was not created");
		renderer.begin();
		application.root.draw();
		renderer.present();
		require(application.requestCloseActivePane() && !application.root.commandView.active && !application.root.node.isLeaf(),
			"shared-document pane close prompted or failed to collapse");
		require(application.root.closeActivePane(true) && application.root.node.isLeaf(), "closing final pane did not collapse layout root");
		var failing = new Document("/missing-parent/failure.txt", "clean", application.syntaxes);
		failing.insert(new BufferSelection(), "dirty");
		application.add(failing);
		require(application.requestCloseActiveTab(), "failed-save close did not start");
		application.textInput("save");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.indexOf(failing) >= 0 && failing.dirty && !application.root.commandView.active,
			"failed save closed or cleaned the document");
		var quitOther = application.documents.createUntitled();
		quitOther.insert(new BufferSelection(), "quit dirty");
		require(application.requestQuit(), "quit coordination did not start");
		application.textInput("discard");
		application.keyPressed(Platform.KEY_ENTER, 0);
		application.textInput("cancel");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(!application.quitReady && application.documents.documents.indexOf(failing) >= 0
			&& application.documents.documents.indexOf(quitOther) >= 0, "cancel during multi-document quit released state");
		renderer.begin();
		application.root.draw();
		renderer.present();
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy application test window");
		Native.shutdown();
		Sys.println("PASS: application document, tab, focus, command, and close ownership");
		return 0;
	}
}
