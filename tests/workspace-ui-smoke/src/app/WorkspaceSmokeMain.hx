package app;

import ui.ExosuitApp;
import ui.UiEditorTabs;
import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostOptions;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;

class WorkspaceSmokeApp extends ExosuitApp {
	final phase:String;
	final path:String;
	var frames = 0;
	var oldColumns = 0;
	var paletteCommand = "";
	var sidebarWidth = 0.0;

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, phase == "write" || phase == "keyboard" || phase == "sidebar-write" || (phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) ? path : null,
			null, null, null, WorkspaceSmokeMain.createTerminal);
		this.phase = phase;
		this.path = path;
		if (phase == "sidebar-write" || phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) application.openArgument(path.substring(0, path.lastIndexOf("/")));
	}

	function require(value:Bool, message:String):Void { if (!value) throw message; }

	function palette(command:String):Void {
		paletteCommand = command;
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
	}

	override public function submit(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frames++;
		if (StringTools.startsWith(phase, "sidebar-")) sidebarStep();
		if (phase == "write") {
			if (frames == 3) {
				var first = host.activeView();
				if (first == null) throw "writer missing source";
				var text = "";
				for (_ in 0...100) text += "restart dirty text\n";
				first.document.buffer.replaceAllText(text, first.selection);
				require(host.splitActive(view.LayoutKind.Horizontal), "writer split failed");
				openTerminal();
				moveTerminalToEditor();
			}
			if (frames == 5) {
				var first = host.panes[0].tabs[0], second = host.panes[1].tabs[0];
				first.restoreCursor(10, 3); second.restoreCursor(14, 2);
				first.restoreScroll(0, 120); second.restoreScroll(0, 240);
				var terminal = host.allTerminalTabs()[0];
				oldColumns = terminal.panel.columns();
				require(oldColumns > 0 && terminal.panel.rows() > 0, "terminal has no grid");
				trace("PASS: split dirty document and editor terminal ready for shutdown");
			}
			if (frames == 6) moveTerminalToPanel();
			if (frames == 8) {
				require(host.allTerminalTabs()[0].panel.columns() > oldColumns, "terminal did not resize to wider panel");
				moveTerminalToEditor();
			}
			if (frames == 11) {
				require(host.allTerminalTabs()[0].panel.columns() == oldColumns, "terminal did not resize back to editor");
				require(WorkspaceSmokeMain.terminalStarts == 1, "resizing replaced terminal session");
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-dock.txt", host.sessionLines()[0]);
				trace("PASS: terminal grid follows resolved viewport across transfers");
			}
		} else if (phase == "read" && frames == 5) {
			require(host.panes.length == 2, "restart lost panes");
			require(host.sessionLines()[0] == sys.io.File.getContent(config.ConfigurationPaths.stateRoot() + "/expected-dock.txt"),
				"restart changed dock layout");
			var first = host.panes[0].tabs[0], second = host.panes[1].tabs[0];
			require(first.document == second.document && first.selection != second.selection,
				"restart lost shared document or independent selections");
			require(first.document.buffer.text.indexOf("restart dirty text") == 0 && first.document.dirty,
				"restart lost dirty recovery");
			require(first.cursorLine() == 10 && first.cursorColumn() == 3 && second.cursorLine() == 14 && second.cursorColumn() == 2,
				"restart lost independent carets");
			require(first.scrollY() == 120 && second.scrollY() == 240, "restart lost scroll");
			require(host.activePane == host.panes[1] && UiEditorTabs.terminal(host.activeTab()) != null,
				"restart lost selected terminal");
			require(host.allTerminalTabs().length == 1 && WorkspaceSmokeMain.terminalStarts == 1,
				"restart did not recreate exactly one shell");
			require(host.allTerminalTabs()[0].panel.columns() > 0, "restored shell has no grid");
			trace("PASS: separate process restored split, dirty shared text, carets, scroll and terminal profile");
		} else if (phase == "legacy" && frames == 5) {
			var active = host.activeView();
			if (active == null) throw "legacy has no active document";
			require(host.panes.length == 1 && active != null && active.document.requirePath() == path,
				"legacy flat tabs did not reopen surviving document");
			require(active.cursorLine() == 0 && active.cursorColumn() == 3, "legacy caret lost");
			trace("PASS: legacy flat tabs restore while missing document is skipped");
		} else if ((phase == "corrupt" || phase == "missing" || phase == "invalid-dock") && frames == 5) {
			require(host.panes.length >= 1, "recovery has no usable editor pane");
			if (phase == "corrupt") require(sys.FileSystem.exists(config.ConfigurationPaths.session() + ".incompatible"),
				"corrupt session was not quarantined");
			if (phase == "invalid-dock") {
				var restored = host.activeView();
				require(restored != null && restored.document.requirePath() == path,
					"invalid dock snapshot lost valid document");
			}
			application.newDocument();
			var active = host.activeView();
			if (active == null) throw "recovery cannot create document";
			active.textInput("usable");
			require(active.document.buffer.text == "usable", "recovery cannot edit");
			trace("PASS: " + phase + " session leaves usable workspace");
		} else if (phase == "keyboard") {
			if (frames == 3) palette("root:split-right");
			if (frames == 4 || frames == 13) {
				ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
				ui.text(UiEventKind.TextInput, paletteCommand);
			}
			if (frames == 5 || frames == 14) ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (frames == 7) {
				require(host.panes.length == 2 && host.activePane == host.panes[1], "keyboard split failed");
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 8) {
				require(host.activePane == host.panes[0], "keyboard focus left failed");
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 9) {
				require(host.activePane == host.panes[1], "keyboard focus right failed");
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Control | UiModifier.Alt | UiModifier.Shift);
			}
			if (frames == 11) {
				require(host.activePane == host.panes[0] && host.panes[1].items.length == 0,
					"keyboard move did not deduplicate shared tab");
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 12) palette("root:close-pane");
			if (frames == 16) {
				require(host.panes.length == 1 && host.activeView() != null, "keyboard close lost surviving document");
				trace("PASS: keyboard-only split, directional focus, tab move and pane close");
			}
		}
		return super.submit(frame);
	}
	function node(key:String):nativekit.ui.core.RenderNode {
		var root = ui.root;
		if (root == null) throw "sidebar has no resolved UI";
		var found = find(root, key);
		if (found == null) throw "sidebar widget missing: " + key;
		return found;
	}
	static function find(root:nativekit.ui.core.RenderNode, key:String):Null<nativekit.ui.core.RenderNode> {
		if (root.styleKey == key) return root;
		for (child in root.children) { var found = find(child, key); if (found != null) return found; }
		return null;
	}
	static function findTree(root:nativekit.ui.core.RenderNode):Null<nativekit.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.role == nativekit.ui.semantics.AccessibilityRole.Tree) return root;
		for (child in root.children) { var found = findTree(child); if (found != null) return found; }
		return null;
	}
	function click(key:String):Void {
		var bounds = node(key).globalBounds();
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
	}
	function sidebarStep():Void {
		if (phase == "sidebar-write") {
			if (frames == 3) ui.key(UiEventKind.KeyDown, UiKey.F, UiModifier.Control | UiModifier.Shift);
			if (frames == 4) { require(sidebar.activeId == "search", "search shortcut did not select mode"); click("files"); }
			if (frames == 5) {
				require(sidebar.activeId == "files", "Files tab click did not select mode");
				sidebarWidth = node("sidebar-modes").globalBounds().width;
				var tree = findTree(ui.root);
				require(tree != null, "Files tree missing");
				var bounds = tree.globalBounds();
				ui.scroll(bounds.x + 20, bounds.y + 40, 0, 180);
				resizeSidebar(30);
			}
			if (frames == 7) {
				require(filesScroll.offsetY > 0, "wheel did not reach Files tree");
				var files = sidebar.find("files");
				require(files != null && files.width > sidebarWidth + 20, "Files divider width was not retained");
				click("search");
			}
			if (frames == 8) {
				require(sidebar.activeId == "search", "Search tab click failed");
				require(Math.abs(node("sidebar-modes").globalBounds().width - 320) < 1, "mode did not restore its own width");
				resizeSidebar(40);
			}
			if (frames == 10) {
				var search = sidebar.find("search");
				require(search != null && search.width > 350, "Search divider width lost");
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt", sidebar.encode());
				trace("PASS: sidebar commands, pointer tabs and independent dragged widths");
			}
		} else if ((phase == "sidebar-read" || phase == "sidebar-hidden-read") && frames == 5) {
			require(sidebar.activeId == "search", "restart lost sidebar mode");
			require(sidebar.encode() == sys.io.File.getContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt"),
				"restart lost sidebar visibility or mode widths");
			if (phase == "sidebar-read") {
				require(sidebar.visible, "restart hid sidebar");
				application.commands.perform("workbench:toggle-sidebar", application.context);
				host.sessionLines();
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt", sidebar.encode());
			} else { require(!sidebar.visible, "hidden sidebar reopened"); node("rail-search"); }
			trace("PASS: " + phase + " restores selected mode, visibility and per-mode widths");
		} else if (phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) {
			if (frames == 3) ui.key(UiEventKind.KeyDown, UiKey.F, UiModifier.Control | UiModifier.Shift);
			if (frames == 4) ui.text(UiEventKind.TextInput, "needle");
			if (frames == 5) {
				application.search.workspaceSearch.flush();
				for (_ in 0...100) if (!application.search.workspaceSearch.complete) application.workspace.jobs.update(32);
			}
			if (frames == 6) {
				require(host.workspaceSearchResults.length == 100, "sidebar search lost cooperative results");
				var bounds = node("workspace-search-result-0").globalBounds();
				ui.scroll(bounds.x + 20, bounds.y + 10, 0, 180);
			}
			if (frames == 8) {
				require(searchPanel.scroll.offsetY > 0, "wheel did not reach search results");
				searchPanel.scroll.jumpTo(0, 0);
			}
			if (frames == 9) click("workspace-search-result-0");
			if (frames == 10) {
				var view = host.activeView();
				if (view == null) throw "search navigation lost document";
				require(view.cursorLine() == 0, "result click did not navigate");
				view.restoreCursor(0, 0); view.textInput("new first line\n");
			}
			if (frames == 12) {
				application.search.workspaceSearch.flush();
				for (_ in 0...100) if (!application.search.workspaceSearch.complete) application.workspace.jobs.update(32);
			}
			if (frames == 13) {
				require(host.workspaceSearchResults.length == 100 && host.workspaceSearchResults[0].line == 1,
					"search results did not repair after edit");
				click("workspace-search-result-0");
			}
			if (frames == 14) {
				var view = host.activeView();
				require(view != null && view.cursorLine() == 1, "updated search result navigated to stale position");
				var input = node("workspace-search-replacement"); ui.focusWidget(input.id);
				ui.text(UiEventKind.TextInput, "replacement");
			}
			if (frames == 15) click("workspace-search-preview");
			if (frames == 17) {
				var preview = application.search.replacementPreview;
				require(preview != null && preview.matchCount == 100 && searchPanel.previewVisible, "replacement preview missing");
				var view = host.activeView();
				require(view != null && view.document.buffer.text.indexOf("needle") >= 0, "preview changed text before apply");
				if (phase == "sidebar-search") click("workspace-search-apply");
				if (phase == "sidebar-stale-preview") {
					searchPanel.search("match"); application.search.workspaceSearch.flush();
					for (_ in 0...100) if (!application.search.workspaceSearch.complete) application.workspace.jobs.update(32);
					require(searchPanel.preview("new proposal"), "stale button fixture could not create newer proposal");
					click("workspace-search-apply");
				}
			}
			if (frames == 19) {
				var view = host.activeView();
				if (phase == "sidebar-stale-preview") {
					require(view != null && view.document.buffer.text.indexOf("needle match") >= 0 &&
						view.document.buffer.text.indexOf("new proposal") < 0, "stale Apply button applied a different proposal");
					trace("PASS: stale replacement UI cannot apply a newer proposal");
					return;
				}
				require(view != null && view.document.buffer.text.indexOf("needle") < 0 &&
					view.document.buffer.text.indexOf("replacement") >= 0, "preview apply did not use transactional replacement");
				trace("PASS: search input, virtualized wheel, result clicks, edit repair and preview/apply");
			}
		}
	}
	function resizeSidebar(delta:Float):Void {
		var bounds = node("sidebar-modes").globalBounds();
		var x = bounds.x + bounds.width + 4, y = bounds.y + bounds.height / 2;
		ui.pointerDown(x, y, 0); ui.pointerMove(x + delta, y); ui.pointerUp(x + delta, y, 0);
	}

}

class WorkspaceSmokeMain {
	public static var terminalStarts = 0;
	public static function createTerminal(cwd:String, requestFrame:Void->Void, palette:ui.TerminalPalette):ui.TerminalPanel {
		var panel = ui.TerminalPane.open(cwd, requestFrame, palette);
		terminalStarts++;
		return panel;
	}
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit workspace acceptance";
		options.width = 900; options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = args[2] == "sidebar-preview" ? 18 : args[2] == "sidebar-search" || args[2] == "sidebar-stale-preview" ? 20 : args[2] == "sidebar-write" ? 11 : args[2] == "keyboard" ? 17 : args[2] == "write" ? 12 : 7;
		var status = DesktopUiHost.run(options, context -> new WorkspaceSmokeApp(context, args[0], args[2]));
		platform.Native.shutdown();
		return status;
	}
}
