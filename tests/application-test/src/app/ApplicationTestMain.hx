package app;

import testing.model.ModelClipboard;

import testing.model.ModelSidebar;

import testing.model.ModelWelcomeView;

import testing.model.EditorViewportModel;

import core.Application;
import editor.Document;
import platform.Platform;
import testing.model.ModelTextMetrics;
import view.LayoutKind;
import testing.model.ModelLayoutNode;
import testing.model.ModelWorkbenchHost;
import editor.BufferSelection;

class ApplicationTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {

		var welcome = new testing.model.ModelWelcomeView(), welcomeActions = 0;
		welcome.newFile = function() { welcomeActions++; };
		require(welcome.mouseDown(146, 150, 0, 0, 640, 320) && welcomeActions == 1,
			"welcome action hit testing did not invoke its controller callback");
		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings),
				null, new session.RecentProjects("")),
			root:ModelWorkbenchHost = cast application.root,
			first = new Document("first", "one", application.syntaxes),
			second = new Document("second", "two", application.syntaxes);
		var firstView = application.add(first), secondView = application.add(second);
		require(style.Theme.contrastRatio(application.theme.editorForeground, application.theme.editorBackground) >= 4.5
			&& style.Theme.contrastRatio(application.theme.editorBackground, application.theme.accent) >= 4.5
			&& style.Theme.contrastRatio(application.theme.foregroundMuted, application.theme.surface) >= 4.5,
			"default editor, active-row, or secondary text contrast was below WCAG AA");
		application.setComposition("に😀", 1, 1);
		var compositionArea = root.textInputArea();
		require(second.buffer.text == "two" && compositionArea != null,
			"document composition mutated text or lacked candidate placement");
		application.clearComposition();
		require(second.buffer.text == "two", "clearing document composition mutated text");
		root.displayScaleChanged(1750);
		require(root.displayScaleMilli == 1750 && root.node.width == 640 - testing.model.ModelSidebar.WIDTH,
			"display-scale change altered the logical layout coordinate space");
		require(root.status.text(secondView).indexOf("second") >= 0
			&& root.status.text(secondView).indexOf("Ln 1, Col 1") >= 0
			&& root.status.text(secondView).indexOf("UTF-8") >= 0,
			"status did not expose document position and encoding");
		for (index in 0...120) root.notifications.publish("message " + index);
		var currentNotification = root.notifications.current();
		require(root.notifications.entries.length == 100 && currentNotification != null
			&& currentNotification.message == "message 119", "notification retention was not bounded");
		if (currentNotification == null) throw "missing current notification";
		require(root.notifications.current(currentNotification.createdAt + feedback.NotificationCenter.DISPLAY_SECONDS + 0.1) == null,
			"expired notification remained pinned over the editor");
		require(root.notifications.unreadCount() == 100 && root.notifications.history()[0] == currentNotification,
			"expiration lost unread history or history order");
		root.notifications.dismissToast();
		require(root.notifications.current() == null && root.notifications.unreadCount() == 100,
			"hiding a toast deleted or read its history");
		root.notifications.markRead(currentNotification.id);
		require(root.notifications.unreadCount() == 99, "reading a notification did not update the badge");
		root.notifications.markAllRead();
		require(root.notifications.unreadCount() == 0 && root.notifications.entries.length == 100, "mark all read discarded history");
		var crash = root.notifications.publish("HashLink fatal error\nInspect a retained core with: coredumpctl debug 1234", feedback.NotificationKind.Error, "workspace");
		require(feedback.NotificationText.crashPid(crash) == 1234 && feedback.NotificationText.details(crash).indexOf("workspace") >= 0,
			"crash details lost source or safe PID action");
		var warning = root.notifications.publish("Warning", feedback.NotificationKind.Warning, "test");
		root.notifications.dismiss(crash.id);
		require(root.notifications.unreadCount() == 1 && root.notifications.history()[0] == warning, "dismiss removed the wrong notification");
		root.notifications.clear();
		require(root.notifications.unreadCount() == 0 && root.notifications.entries.length == 0, "clear left unread state behind");
		for (index in 0...220) application.errors.record("test", "error " + index);
		require(application.errors.entries.length == 200 && application.errors.entries[0].message == "error 20",
			"error-log retention was not bounded");
		root.problems.add(new feedback.Problem("test", "one", "/tmp/problem.hx", 2, 3, 4, "test problem", 1));
		require(application.commands.perform("workbench:show-problems", application.context), "problems command was not available");
		var problemView = root.tabs.activeView;
		if (problemView == null) throw "problems command did not open a view";
		require(problemView.title == "Problems", "problem registry was not exposed through a navigable view");
		require(root.closeActiveTab(true), "problems view did not close cleanly");
		var missingPluginLoaded = application.loadPluginManifest("/missing/plugin.conf"), pluginNotification = root.notifications.current();
		require(!missingPluginLoaded && application.errors.entries[199].source == "plugin"
			&& pluginNotification != null && pluginNotification.kind == feedback.NotificationKind.Error,
			"plugin failure did not reach the error log and notification center");
		application.openErrorLog();
		require(root.commandView.active && root.commandView.results.length == 200,
			"error log was not inspectable through command input");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		var untitledOne = application.documents.createUntitled(), untitledTwo = application.documents.createUntitled();
		require(untitledOne != untitledTwo && untitledOne.id != untitledTwo.id && !untitledOne.hasBackingPath() && !untitledOne.save(),
			"untitled documents were not distinct or attempted persistence without Save As");
		application.documents.close(untitledOne, true);
		application.documents.close(untitledTwo, true);
		require(application.documents.documents.length == 2 && root.tabs.views.length == 2, "documents did not open as tabs");
		require(root.reorderActiveTab(-1) && root.tabs.views[0] == secondView
			&& root.reorderActiveTab(1) && root.tabs.views[1] == secondView, "tab reordering failed");
		var tabY = 10, secondTabX = root.activeLeaf.x + testing.model.ModelWorkbenchHost.TAB_WIDTH + 20,
			firstTabX = root.activeLeaf.x + 20;
		root.mouseDown(Platform.MOUSE_LEFT, secondTabX, tabY);
		root.mouseMove(firstTabX, tabY);
		root.mouseUp(Platform.MOUSE_LEFT);
		require(root.tabs.views[0] == secondView && root.reorderActiveTab(1),
			"mouse tab drag did not reorder within the pane");
		root.mouseDown(Platform.MOUSE_RIGHT, root.activeLeaf.x + 20, testing.model.EditorViewportModel.HEADER_HEIGHT + 20);
		require(root.contextMenu.visible, "editor right click did not open a context menu");
		root.mouseDown(Platform.MOUSE_LEFT, 0, 0);
		require(!root.contextMenu.visible, "outside click did not dismiss the context menu");
		require(application.add(second) == secondView && root.tabs.views.length == 2, "document tab was not reused");
		require(application.focus.activeView == secondView, "new tab did not receive focus");
		application.commands.perform("doc:newline", application.context);
		require(second.buffer.text == "\ntwo" && first.buffer.text == "one", "command did not target active document");
		require(root.status.text(secondView).indexOf("* second") >= 0
			&& root.status.text(secondView).indexOf("Ln 2") >= 0,
			"status did not update dirty state and caret position");
		var clipboardView = root.tabs.activeView;
		if (clipboardView == null) throw "clipboard test has no active view";
		require(ModelClipboard.write("Olá\r\n😀"), "headless clipboard write failed");
		clipboardView.selectAll();
		application.keyPressed(Platform.KEY_V, Platform.MOD_CTRL);
		require(second.buffer.text == "Olá\n😀", "clipboard paste did not normalize multiline Unicode text");
		clipboardView.undo();
		require(second.buffer.text == "\ntwo", "clipboard paste was not one undo unit");
		clipboardView.selectAll();
		application.keyPressed(Platform.KEY_C, Platform.MOD_CTRL);
		require(ModelClipboard.read() == "\ntwo", "clipboard copy did not preserve multiline text");
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
		require(ModelClipboard.read() == "one\none\none", "multi-selection copy distribution failed");
		ModelClipboard.write("a\nb\nc");
		application.commands.perform("doc:paste", application.context);
		require(multipleDocument.buffer.text == "a b c", "multi-selection paste distribution failed");
		multipleView.undo();
		require(multipleDocument.buffer.text == "one one one" && multipleSelection.rangeCount() == 3,
			"multi-selection undo did not restore content and ranges");
		multipleView.redo();
		require(multipleDocument.buffer.text == "a b c" && multipleSelection.rangeCount() == 3,
			"multi-selection redo failed");
		require(root.closeActiveTab(true), "multiple-selection test tab did not close");
		require(application.keyPressed(Platform.KEY_G, Platform.MOD_CTRL) && root.commandView.active,
			"named go-to-line command did not open command input");
		application.textInput("2:2");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(clipboardView.cursorLine() == 1 && clipboardView.cursorColumn() == 1, "go-to-line/column did not restore the requested caret");
		application.commands.perform("root:switch-to-previous-tab", application.context);
		require(application.focus.activeView == firstView, "tab switch did not update focus");
		application.commands.perform("doc:newline", application.context);
		require(first.buffer.text == "\none", "command context captured the wrong document");
		root.mouseDown(Platform.MOUSE_LEFT, root.activeLeaf.x + testing.model.ModelWorkbenchHost.TAB_WIDTH - 5, 10);
		require(root.commandView.active, "tab close control bypassed the dirty-document coordinator");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		require(!root.commandView.active && application.documents.documents.indexOf(first) >= 0,
			"Escape did not cancel the close transaction");
		root.mouseDown(Platform.MOUSE_LEFT, root.activeLeaf.x + testing.model.ModelWorkbenchHost.TAB_WIDTH - 5, 10);
		require(root.commandView.active, "close coordinator remained pending after Escape cancellation");
		application.textInput("cancel");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.indexOf(first) >= 0, "cancelled document close released the document");
		require(first.buffer.text == "\none", "prompt input mutated the inactive document");
		require(!root.commandView.active, "cancelled document close left its prompt active");
		require(application.requestCloseActiveTab(), "document close could not restart after cancellation");
		application.textInput("discard");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.length == 1 && application.focus.activeView == secondView,
			"closing a tab did not reconcile ownership and focus");
		application.commands.perform("root:split-right", application.context);
		require(!root.node.isLeaf() && root.node.requireFirst().width + root.node.requireSecond().width
			+ ModelLayoutNode.DIVIDER_SIZE == 640 - testing.model.ModelSidebar.WIDTH, "horizontal split did not assign recursive bounds");
		require(application.documents.documents.length == 1 && root.node.containsDocument(second),
			"split duplicated document ownership");
		var leftView = root.node.requireFirst().tabs.activeView, rightView = root.node.requireSecond().tabs.activeView;
		if (leftView == null || rightView == null) throw "split views are missing";
		require(root.focusPane(-1, 0) && root.activeLeaf == root.node.requireFirst()
			&& root.focusPane(1, 0) && root.activeLeaf == root.node.requireSecond(),
			"directional pane focus failed");
		var movable = application.newDocument();
		require(root.moveActiveTab(-1, 0) && root.activeLeaf == root.node.requireFirst()
			&& root.tabs.activeView == movable, "moving a tab to the left pane failed");
		require(root.moveActiveTab(1, 0) && root.activeLeaf == root.node.requireSecond()
			&& root.closeActiveTab(true), "moving a tab back or closing it failed");
		leftView.restoreCursor(1, 1);
		rightView.restoreCursor(1, 2);
		root.activateLeaf(root.node.requireFirst());
		require(leftView.cursorLine() == 1 && leftView.cursorColumn() == 1, "left pane did not restore its cursor");
		root.activateLeaf(root.node.requireSecond());
		require(rightView.cursorLine() == 1 && rightView.cursorColumn() == 2, "right pane did not retain an independent cursor");
		rightView.restoreCursor(0, 0);
		application.commands.perform("doc:newline", application.context);
		root.activateLeaf(root.node.requireFirst());
		require(leftView.cursorLine() == 2 && leftView.cursorColumn() == 1,
			"edit in one pane did not transform the other pane's cursor");
		root.activateLeaf(root.node.requireSecond());
		var divider = root.node.requireFirst().x + root.node.requireFirst().width;
		root.mouseDown(Platform.MOUSE_LEFT, divider + 1, 100);
		root.mouseMove(520, 100);
		root.mouseUp(Platform.MOUSE_LEFT);
		require(root.node.divider > 600, "divider drag did not resize panes");
		root.mouseDown(Platform.MOUSE_LEFT, root.sidebar.width, 100);
		root.mouseMove(260, 100);
		root.mouseUp(Platform.MOUSE_LEFT);
		require(root.sidebar.width == 260, "sidebar drag resize failed");
		require(root.toggleSidebar() && !root.sidebarVisible && root.node.x == 0,
			"sidebar toggle did not release editor space");
		root.resize(200, 180);
		require(root.node.width == 200, "narrow hidden-sidebar layout became inoperable");
		root.resize(640, 320);
		root.toggleSidebar();
		root.setSidebarWidth(220);
		application.commands.perform("root:split-up", application.context);
		require(!root.node.requireSecond().isLeaf()
			&& root.node.requireSecond().kind == LayoutKind.Vertical, "nested vertical split was not created");

		root.update();

		require(application.requestCloseActivePane() && !root.commandView.active && !root.node.isLeaf(),
			"shared-document pane close prompted or failed to collapse");
		require(root.closeActivePane(true) && root.node.isLeaf(), "closing final pane did not collapse layout root");
		var failing = new Document("/missing-parent/failure.txt", "clean", application.syntaxes);
		failing.insert(new BufferSelection(), "dirty");
		application.add(failing);
		require(application.requestCloseActiveTab(), "failed-save close did not start");
		application.textInput("save");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.indexOf(failing) >= 0 && failing.dirty && !root.commandView.active,
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

		root.update();

		application.shutdown();
		Sys.println("PASS: application document, tab, focus, command, and close ownership");
		return 0;
	}
}
