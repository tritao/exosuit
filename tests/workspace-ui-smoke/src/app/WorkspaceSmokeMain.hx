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
	var languageStage = 0;
	var languageSettings = "";
	var languageFeatureStage = 0;
	var languageOriginal = "";

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, phase == "scrollbar-visibility" ? path : phase == "explorer-preview" ? path.substring(0, path.lastIndexOf("/")) : phase == "language-folder" || phase == "editor-scroll" || phase == "write" || phase == "keyboard" || phase == "sidebar-write" || (phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) ? path : null,
			null, null, null, WorkspaceSmokeMain.createTerminal);
		this.phase = phase;
		this.path = path;
		if (phase == "language-folder" || phase == "sidebar-write" || phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) application.openArgument(path.substring(0, path.lastIndexOf("/")));
	}

	function require(value:Bool, message:String):Void { if (!value) throw message; }

	function palette(command:String):Void {
		paletteCommand = command;
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
	}

	override public function submit(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frames++;
		if (phase == "scrollbar-visibility") return scrollbarStep(frame);
		if (phase == "language-folder") languageStep();
		if (phase == "explorer-preview") explorerStep();
		if (phase == "editor-scroll") {
			frame.deltaSeconds = 1.0 / 60.0;
			var view = host.activeView();
			if (view == null) throw "scroll acceptance missing document";
			if (frames == 3) {
				view.restoreScroll(0, 0);
				var bounds = node("editor-scroll:" + view.document.id).globalBounds();
				ui.scroll(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0, 100);
				require(view.scrollController.offsetY == 0, "smooth wheel jumped immediately");
			}
			if (frames == 5) require(view.scrollController.offsetY > 40 && view.scrollController.offsetY < 100, "editor wheel did not animate");
			if (frames == 12) {
				require(view.scrollController.offsetY >= 99, "editor scroll did not settle");
				var settings = application.settings.current.copy(); settings.scrollAnimationType = "none";
				host.applySettings(settings);
				view.scrollController.scrollBy(0, 100);
				require(view.scrollController.offsetY >= 199, "live scroll setting did not become immediate");
				view.restoreScroll(0, 20);
				require(view.scrollController.offsetY == 20, "restored scroll was animated");
				trace("PASS: real editor wheel animates and motion configuration applies live");
			}
		}
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
	function scrollbarStep(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frame.deltaSeconds = frames == 5 ? 0.49 : frames == 6 ? 0.1 : frames == 7 ? 0.2 : 0;
		var view = host.activeView();
		if (view == null) throw "scrollbar acceptance missing editor";
		if (frames == 3) {
			var scroll = node("editor-scroll:" + view.document.id);
			var track = scroll.children[1].globalBounds();
			var color = scroll.children[1].children[0].layout.style.background;
			require(color != null && color.alpha == 0, "idle editor scrollbar is visible");
			ui.pointerMove(track.x + track.width / 2, track.y + track.height / 2);
		}
		if (frames == 4) ui.pointerMove(0, 0);
		if (frames == 8) {
			var bounds = node("editor-scroll:" + view.document.id).globalBounds();
			ui.scroll(bounds.x + 40, bounds.y + 40, 0, 50);
		}
		if (frames == 9 || frames == 10 || frames == 11) {
			var settings = application.settings.current.copy();
			settings.scrollbarVisibility = frames == 9 ? "always" : frames == 10 ? "hidden" : "auto";
			host.applySettings(settings);
		}
		var result = super.submit(frame);
		var scroll = node("editor-scroll:" + view.document.id);
		if (frames == 10) require(scroll.children.length == 1, "hidden policy retains scrollbar or hit target");
		else if (frames >= 3) {
			var color = scroll.children[1].children[0].layout.style.background;
			if (color == null) throw "scrollbar has no paint";
			if (frames == 3 || frames == 4 || frames == 5 || frames == 8 || frames == 9) require(color.alpha == 1, "hover/scroll/always did not reveal scrollbar");
			if (frames == 6) require(color.alpha > 0 && color.alpha < 1, "scrollbar did not fade");
			if (frames == 7 || frames == 11) require(color.alpha == 0, "idle scrollbar or restored auto did not hide");
		}
		if (frames == 11) trace("PASS: real editor scrollbar idle, edge hover, delayed fade, wheel reveal and live visibility settings");
		return result;
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
	static function treeRow(root:nativekit.ui.core.RenderNode, path:String):Null<nativekit.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.role == nativekit.ui.semantics.AccessibilityRole.TreeItem && root.semantics.label == path) return root;
		for (child in root.children) { var found = treeRow(child, path); if (found != null) return found; }
		return null;
	}
	function clickTree(path:String):Void {
		var row = treeRow(ui.root, path);
		require(row != null, "explorer row missing: " + path);
		var bounds = row.globalBounds();
		// Click the label, away from the independent disclosure control.
		ui.pointerDown(bounds.x + bounds.width - 10, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width - 10, bounds.y + bounds.height / 2, 0);
	}
	function activePreview():Bool { var view = host.activeView(); return view != null && view.preview; }
	function explorerStep():Void {
		var root = path.substring(0, path.lastIndexOf("/"));
		if (frames == 3) clickTree(root + "/folder");
		if (frames == 4) {
			require(treeRow(ui.root, root + "/folder/A.txt") != null, "folder single click did not expand");
			clickTree(root + "/folder");
			clickTree(root + "/folder/A.txt");
			require(activePreview() && host.tabs.length == 1, "single click did not open preview");
		}
		if (frames == 5) {
			require(treeRow(ui.root, root + "/folder/A.txt") != null, "second click toggled folder twice");
			clickTree(root + "/folder/B.txt");
			require(host.activeDocument().requirePath() == root + "/folder/B.txt" && host.tabs.length == 1, "preview did not replace previous file");
			clickTree(root + "/folder/B.txt");
			require(!activePreview(), "second click did not keep selected preview");
		}
		if (frames == 6) {
			clickTree(root + "/folder/A.txt");
			require(host.tabs.length == 2 && activePreview(), "permanent file was replaced");
			host.activeView().textInput("edit");
			require(!activePreview(), "edit did not promote preview");
			host.activeView().undo();
			require(!activePreview(), "undo demoted permanent tab");
		}
		if (frames == 7) {
			clickTree(root + "/folder/C.txt");
			require(host.tabs.length == 3 && activePreview(), "edited then undone tab was replaced");
		}
		if (frames == 8) {
			var document = host.activeDocument();
			if (document == null) throw "preview document missing";
			var tab = node("doc:" + document.id).globalBounds();
			for (_ in 0...2) { ui.pointerDown(tab.x + tab.width / 2, tab.y + tab.height / 2, 0); ui.pointerUp(tab.x + tab.width / 2, tab.y + tab.height / 2, 0); }
			require(!activePreview(), "tab double click did not keep preview");
		}
		if (frames == 9) {
			clickTree(root + "/folder"); clickTree(root + "/folder");
		}
		if (frames == 10) {
			require(treeRow(ui.root, root + "/folder/A.txt") == null, "folder double click did not collapse");
			require(host.splitActive(view.LayoutKind.Horizontal), "preview pane split failed");
			host.openPreview(application.workspace.documents.open(root + "/folder/A.txt"));
			host.openPreview(application.workspace.documents.open(root + "/folder/B.txt"));
			require(host.tabs.length == 2 && host.panes[0].tabs.length == 3, "preview replacement affected another pane");
			var shared = application.workspace.documents.open(root + "/folder/B.txt");
			host.activeView().textInput("edit");
			for (other in host.allViews()) if (other.document == shared) require(!other.preview, "shared edit left another preview replaceable");
			host.activeView().undo();
			host.openPreview(application.workspace.documents.open(root + "/folder/A.txt"));
		}
		if (frames == 11) {
			require(host.moveActiveTab(-1, 0), "preview move to neighboring pane failed");
			require(!activePreview() && host.tabs.length == 3, "moving preview duplicated or demoted existing permanent tab");
			trace("PASS: explorer folder single click and double-click suppression, file preview replacement, keep by double click and edit, pane ownership and shared edits");
		}
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
	function languageStep():Void {
		var service = application.language.client;
		var settingsPath = config.ConfigurationPaths.userSettings();
		if (languageStage == 0 && service != null && service.ready && ui.root != null && hasText(node("exosuit-status"), "Haxeon: ready")) {
			languageSettings = sys.io.File.getContent(settingsPath);
			sys.io.File.saveContent(settingsPath, "version=1\nplugins.haxeon.command=" + haxe.Json.stringify([path + "/missing-server"]) + "\n");
			languageStage = 1;
		} else if (languageStage == 1 && host.getProblems().values().length > 0 && ui.root != null && hasText(node("exosuit-status"), "language server")) {
			require(hasText(node("problems-scroll"), "language server"), "language failure did not render in Problems");
			sys.io.File.saveContent(settingsPath, languageSettings); languageStage = 2;
		} else if (languageStage == 2 && service != null && service.ready && host.getProblems().values().length == 0 && ui.root != null && hasText(node("exosuit-status"), "ready")) {
			languageStage = 3;
			trace("PASS: real window starts folder server, renders wrong-command status/Problems and recovers from settings reload");
		}
		if (languageStage == 3) languageFeatures();
		if (frames == 120) require(languageStage == 3 && languageFeatureStage == 9, "language folder UI acceptance did not complete: stage=" + languageStage + ", feature=" + languageFeatureStage + ", status=" + application.language.statusLabel() + ", problems=" + [for (problem in host.getProblems().values()) problem.message].join("; "));
	}
	function languageFeatures():Void {
		if (languageFeatureStage == 0) {
			require(ui.commands.shortcutsFor("exosuit.language:document-symbols").length == 1 &&
				ui.commands.shortcutsFor("exosuit.language:find-references").length == 1 &&
				ui.commands.shortcutsFor("exosuit.language:rename-symbol").length == 1, "language shortcuts were not bridged");
			require(ui.commands.execute("exosuit.language:document-symbols"), "graphical symbols command unavailable");
			languageFeatureStage = 1;
		} else if (languageFeatureStage == 1 && host.isCommandViewActive() && hasText(node("cv-content"), "Document Symbols")) {
			ui.text(UiEventKind.TextInput, "value"); languageFeatureStage = 2;
		} else if (languageFeatureStage == 2 && node("cv-rows").children.length == 1 && hasText(node("cv-row-0"), "value")) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter, 0); languageFeatureStage = 3;
		} else if (languageFeatureStage == 3 && !host.isCommandViewActive()) {
			require(ui.commands.execute("exosuit.language:find-references"), "graphical references command unavailable"); languageFeatureStage = 4;
		} else if (languageFeatureStage == 4 && host.isCommandViewActive() && hasText(node("cv-content"), "References")) {
			require(node("cv-rows").children.length == 2, "graphical references omitted closed file");
			ui.text(UiEventKind.TextInput, "Other.hx"); languageFeatureStage = 5;
		} else if (languageFeatureStage == 5 && node("cv-rows").children.length == 1 && hasText(node("cv-row-0"), "Other.hx")) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter, 0); languageFeatureStage = 6;
		} else if (languageFeatureStage == 6 && !host.isCommandViewActive()) {
			var referenced = host.activeDocument();
			require(referenced != null && StringTools.endsWith(referenced.requirePath(), "/Other.hx"), "graphical reference did not navigate");
			application.openArgument(path);
			var document = host.activeDocument(); if (document == null) throw "rename fixture lost document";
			languageOriginal = document.buffer.text;
			require(ui.commands.execute("exosuit.language:rename-symbol"), "graphical rename command unavailable"); languageFeatureStage = 7;
		} else if (languageFeatureStage == 7 && host.isCommandViewActive() && hasText(node("cv-content"), "Rename Symbol To")) {
			ui.text(UiEventKind.TextInput, "renamed"); ui.key(UiEventKind.KeyDown, UiKey.Enter, 0); languageFeatureStage = 8;
		} else if (languageFeatureStage == 8) {
			var document = host.activeDocument();
			if (document != null && document.buffer.text.indexOf("renamed") >= 0) {
				require(!host.isCommandViewActive(), "rename prompt remained open");
				require(application.commands.perform("doc:undo", application.context) && document.buffer.text == languageOriginal, "graphical rename did not undo as one transaction");
				languageFeatureStage = 9;
				trace("PASS: graphical capability-gated symbol filtering, closed-file references, rename input and transactional undo");
			}
		}
	}

	static function hasText(node:nativekit.ui.core.RenderNode, value:String):Bool {
		if (node.layout.text != null && node.layout.text.toLowerCase().indexOf(value.toLowerCase()) >= 0) return true;
		for (child in node.children) if (hasText(child, value)) return true;
		return false;
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
		platform.Platform.startHeadless();
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit workspace acceptance";
		options.width = 900; options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = args[2] == "scrollbar-visibility" ? 12 : args[2] == "explorer-preview" ? 12 : args[2] == "language-folder" ? 121 : args[2] == "editor-scroll" ? 13 : args[2] == "sidebar-preview" ? 18 : args[2] == "sidebar-search" || args[2] == "sidebar-stale-preview" ? 20 : args[2] == "sidebar-write" ? 11 : args[2] == "keyboard" ? 17 : args[2] == "write" ? 12 : 7;
		var status = DesktopUiHost.run(options, context -> new WorkspaceSmokeApp(context, args[0], args[2]));
		platform.Native.shutdown();
		return status;
	}
}
