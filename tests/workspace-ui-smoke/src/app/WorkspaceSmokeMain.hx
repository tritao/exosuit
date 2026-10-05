package app;

import haxeon.ui.FontCollection;
import haxeon.ui.FontFamily;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Path;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextLayout;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;

import ui.ExosuitApp;
import ui.UiEditorTabs;
import ui.UiDocumentView;
import ui.SetiIconData;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;

class WorkspaceSmokeApp extends ExosuitApp {
	final phase:String;
	final testFonts:FontCollection;
	final path:String;
	var frames = 0;
	var diagnosticActions = 0;
	var oldColumns = 0;
	var paletteCommand = "";
	var pointerCommand = "";
	var exitCount = 0;
	var saveAsSuccesses = 0;
	var saveAsCancellations = 0;
	final closeContext:haxeon.ui.host.DesktopUiHostContext;
	var pointerX:Float = 0;
	var pointerY:Float = 0;
	var sidebarWidth = 0.0;
	var languageStage = 0;
	var languageSettings = "";
	var languageFeatureStage = 0;
	var languageOriginal = "";
	var settingsTerminalColumns = 0;
	var closePrimary:UiDocumentView;
	var closeOther:UiDocumentView;
	var closeWidth:Float = 0;
	var selectionDragOffset:Float = 0.0;
	var selectionStoppedOffset:Float = 0.0;

	public function new(context:haxeon.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, (phase == "explorer-preview" || phase == "explorer-icons") ? path.substring(0, path.lastIndexOf("/")) : phase == "language-folder" || phase == "editor-scroll" || phase == "editor-resize" || phase == "editor-font" || phase == "editor-tabs" || phase == "zoom" || phase == "word-delete" || phase == "selection" || phase == "tab-close" || phase == "pointer-actions" || phase == "caret-follow" || phase == "exit-confirmation" || phase == "save-as" || phase == "tab-close-paint" || phase == "settings" || phase == "editor-minimap" || phase == "scrollbar-visibility" || phase == "write" || phase == "keyboard" || phase == "sidebar-write" || (phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) ? path : null,
			null, null, null, WorkspaceSmokeMain.createTerminal);
		this.phase = phase;
		closeContext = context;
		this.testFonts = context.fonts;
		this.path = path;
		if (phase == "language-folder" || phase == "sidebar-write" || phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) application.openArgument(path.substring(0, path.lastIndexOf("/")));
	}

	function require(value:Bool, message:String):Void { if (!value) throw message; }

	function palette(command:String):Void {
		paletteCommand = command;
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
	}

	override public function submit(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frames++;
		if (phase == "editor-font") return editorFontStep(frame);
		if (phase == "problems") return problemsStep(frame);
		if (phase == "activity-bar") return activityBarStep(frame);
		if (phase == "scrollbar-visibility") return scrollbarStep(frame);
		if (phase == "editor-resize") return resizeStep(frame);
		if (phase == "editor-minimap") return minimapStep(frame);
		if (phase == "editor-tabs") return tabsStep(frame);
		if (phase == "settings") return settingsStep(frame);
		if (phase == "zoom") return zoomStep(frame);
		if (phase == "word-delete") return wordDeleteStep(frame);
		if (phase == "selection") return selectionStep(frame);
		if (phase == "tab-close") return tabCloseStep(frame);
		if (phase == "pointer-actions") return pointerActionsStep(frame);
		if (phase == "caret-follow") return caretFollowStep(frame);
		if (phase == "exit-confirmation") return exitConfirmationStep(frame);
		if (phase == "save-as") return saveAsStep(frame);
		if (phase == "tab-close-paint") {
			if (frames >= 2) {
				var view = host.activeView();
				if (view == null) throw "close paint missing document";
				var bounds = node((frames == 5 ? "tab-close:doc:" : "doc:") + view.document.id).globalBounds();
				ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
			}
			var result = super.submit(frame);
			if (frames >= 3) {
				var view = host.activeView();
				if (view == null) throw "close paint missing document";
				var close = node("tab-close:doc:" + view.document.id);
				require((close.layout.style.background.alpha > 0) == (frames == 5), "close background must appear only over its own hit target");
			}
			if (frames == 6) {
				var view = host.activeView();
				if (view == null) throw "close paint missing document";
				var close = node("tab-close:doc:" + view.document.id);
				require(close.layout.style.visible, "hover close is not visible during pixel capture");
				var bounds = close.children[0].globalBounds();
				sys.FileSystem.createDirectory(config.ConfigurationPaths.stateRoot());
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/close-icon-bounds.json",
					haxe.Json.stringify({x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height}));
			}
			return result;
		}
		if (phase == "language-folder") languageStep();
		if (phase == "explorer-preview") explorerStep();
		if (phase == "editor-scroll") {
			frame.deltaSeconds = 1.0 / 60.0;
			var view = host.activeView();
			if (view == null) throw "scroll acceptance missing document";
			if (frames == 3) {
				view.restoreScroll(0, 0);
				var bounds = editorViewport(view.document.id).globalBounds();
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
		if (phase == "explorer-icons") {
			if (frames == 1) {
				var root = path.substring(0, path.lastIndexOf("/"));
				application.openArgument(root + "/Main.hx");
				application.openArgument(root + "/data.json");
			}
			if (frames == 4) { resizeSidebar(-80); frame.setViewport(500.0, 600.0); }
			if (frames >= 6) frame.setViewport(1400.0, 600.0);
			if (frames == 7) resizeSidebar(650);
			var addedPath = path.substring(0, path.lastIndexOf("/")) + "/added-after-render.txt";
			if (frames == 9) sys.io.File.saveContent(addedPath, "new file");
			if (frames == 11) sys.FileSystem.deleteFile(addedPath);
		}
		var result = super.submit(frame);
		if (phase == "explorer-icons" && (frames == 4 || frames == 5)) {
			var status = node("exosuit-status"), updated = false;
			status.walk(function(child) {
				if (child.layout.visualKind == LayoutVisualKind.Text &&
					StringTools.startsWith(child.layout.text, frames == 4 ? "data.json * - " : "Main.hx - ")) updated = true;
			});
			require(updated, "retained status bar did not update after editing or switching tabs");
		}

		if (phase == "explorer-icons" && (frames == 10 || frames == 12)) {
			var addedPath = path.substring(0, path.lastIndexOf("/")) + "/added-after-render.txt";
			var row = treeRow(ui.root, addedPath);
			require(frames == 10 ? row != null : row == null, "cached explorer did not reflect external file change");
			if (frames == 12) trace("PASS: retained explorer reflects external file creation and deletion");
		}

		if (phase == "explorer-icons" && (frames == 5 || frames == 8)) {
			var filename = "language-controller-test-with-an-extra-long-filename.hl";
			var root = path.substring(0, path.lastIndexOf("/"));
			var row = treeRow(ui.root, root + "/" + filename);
			var checked = false;
			row.walk(function(child) {
				if (child.layout.visualKind == LayoutVisualKind.Text && child.semantics != null && child.semantics.label == filename) {
					checked = true;
					if (frames == 5) require(StringTools.endsWith(child.layout.text, "…"), "narrow tree label has no ellipsis");
					else require(child.layout.text == filename, "wide tree label did not restore full filename: " + child.layout.text + " width=" + child.globalBounds().width);
				}
			});
			require(checked, "ellipsized label lost its full accessible filename");
			if (frames == 8) trace("PASS: tree ellipsis follows sidebar width and restores full filenames");
		}

		if (phase == "explorer-icons" && (frames == 3 || frames == 4)) {
			var root = path.substring(0, path.lastIndexOf("/"));
			var names = ["Main.hx", "data.json", "notes.md", "README.md", "tool.py", "Dockerfile", "mystery.wibble", "language-controller-test-with-an-extra-long-filename.hl"];
			var ids = ["_haxe", "_json", "_markdown", "_info", "_python", "_docker", "_default", "_default"];
			for (index in 0...names.length) {
				var row = treeRow(ui.root, root + "/" + names[index]);
				require(row != null, "icon row missing: " + names[index]);
				var found = false;
				row.walk(function(child) {
					if (child.styleType == "file-icon" && child.styleKey == ids[index]) found = true;
					if (child.layout.visualKind == LayoutVisualKind.Text && child.resolved != null)
						require(child.resolved.height <= row.globalBounds().height, "filename wrapped into neighboring rows: " + names[index]);
				});
				require(found, "wrong or missing Seti icon: " + names[index]);
				require(Math.abs(row.globalBounds().height - 26.0) < 0.01, "explorer row height regressed");
			}
			for (view in host.allViews()) {
				var tab = node("doc:" + view.document.id);
				var expected = SetiIconData.iconId(view.document.title);
				var found = false;
				tab.walk(function(child) { if (child.styleType == "file-icon" && child.styleKey == expected) found = true; });
				require(found, "document tab missing file icon: " + view.document.title);
				if (frames == 4 && view.document.title == "Main.hx") {
					tab.walk(function(child) {
						if (child.styleType == "file-icon") {
							var bounds = child.globalBounds();
							ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
							ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
						}
					});
					var activeDocument = host.activeDocument();
					require(activeDocument != null && activeDocument.title == "Main.hx", "clicking the tab icon did not activate its document");
				}
			}
			if (frames == 3) host.activeView().textInput("dirty");
			if (frames == 4) trace("PASS: tree labels stay on one line after resize and document tabs retain file icons after edits");
		}
		return result;
	}
	function resizeStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var view = host.activeView();
		if (view == null) throw "resize acceptance missing document";
		if (frames == 1) {
			var text = "";
			for (_ in 0...60) text += "Repeated wrapping text with enough words to cross the editor width while resizing the window.\n";
			view.document.buffer.replaceAllText(text, view.selection);
		}
		var sizes = [[1100, 760], [640, 480], [900, 600], [420, 320], [1200, 900], [700, 450]];
		var size = sizes[(frames - 1) % sizes.length];
		frame.setViewport(size[0], size[1]);
		if (frames > 1) view.scrollController.jumpTo(0, view.scrollController.maxScrollY);
		var result = super.submit(frame);
		var scroll = editorViewport(view.document.id);
		var controller = view.scrollController;
		var trackNode = editorScrollbar(view.document.id);
		var track:ResolvedLayoutItem = cast trackNode.resolved;
		var thumb:ResolvedLayoutItem = cast trackNode.children[0].resolved;
		require(Math.abs(track.height - Math.max(0, controller.viewportHeight - 4)) < 0.01, "resize left stale scrollbar track");
		require(controller.offsetY <= controller.maxScrollY, "resize left scroll beyond content");
		var expectedThumbY = track.y + (controller.maxScrollY == 0 ? 0 : controller.offsetY / controller.maxScrollY * (track.height - thumb.height));
		require(Math.abs(thumb.y - expectedThumbY) < 0.01, "resize left stale scrollbar thumb");
		var height = controller.contentHeight;
		var offset = controller.offsetY;
		result = super.submit(frame);
		require(Math.abs(controller.contentHeight - height) < 0.01 && Math.abs(controller.offsetY - offset) < 0.01,
			"editor layout did not settle on first resize frame: " + height + " -> " + controller.contentHeight);
		if (frames == 7) trace("PASS: repeated editor resizes settle wrapped content, offsets and scrollbar geometry in one frame");
		return result;
	}

	function tabsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 1) sidebar.setVisible(false);
		frame.setViewport(frames == 7 ? 640 : 900, 600);
		if (frames == 2) {
			var folder = path.substring(0, path.lastIndexOf("/"));
			for (name in ["NativeDesktopPlatform.hx", "Platform.hx", "README.md", "a-very-long-Unicode-🙂-filename-that-needs-an-ellipsis.hx", "Last.hx"])
				application.openArgument(folder + "/" + name);
		}
		if (frames == 4) {
			var scroll = node("editor-tab-scroll");
			var bounds = scroll.globalBounds();
			ui.scroll(bounds.x + 20, bounds.y + 10, 0, -10000);
		}
		if (frames == 5) host.activateTab(host.allViews()[0].document);
		if (frames == 9) {
			var tabs = node("editor-tab-scroll").children[0].children[0].children;
			var bounds = tabs[tabs.length - 2].children[0].globalBounds();
			ui.pointerMove(bounds.x + 40, bounds.y + 10);
		}
		if (frames == 6) {
			var views = host.allViews();
			host.activateTab(views[views.length - 1].document);
		}
		var result = super.submit(frame);
		if (frames >= 3) {
			var scroll = node("editor-tab-scroll");
			var content = scroll.children[0].children[0];
			var previousRight = -100000.0;
			var truncated = false;
			for (tooltip in content.children) {
				var header = tooltip.children[0];
				var bounds = header.globalBounds();
				require(bounds.x >= previousRight - 0.01, "editor tab headers overlap");
				previousRight = bounds.x + bounds.width;
				header.walk(function(child) {
					if (child.layout.visualKind == LayoutVisualKind.Text) {
						require(child.globalBounds().width <= 181, "tab label exceeds width cap");
						if (child.layout.text.indexOf("…") >= 0) truncated = true;
					}
				});
				var semantics:Null<haxeon.ui.semantics.Semantics> = null;
				header.walk(function(child) {
					if (child.semantics != null && child.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tab) semantics = child.semantics;
				});
				if (semantics == null) throw "tab lost its accessible filename";
				require(tooltip.children[1].children[0].layout.text == semantics.label, "tooltip lost full filename");
			}
			require(truncated, "long filename was not ellipsized");
			if (frames == 5) require(content.children[0].globalBounds().x >= scroll.globalBounds().x - 1, "vertical wheel did not scroll tab rail back");
			if (frames == 8) {
				var last = content.children[content.children.length - 1].children[0].globalBounds();
				var bounds = scroll.globalBounds();
				require(last.x >= bounds.x - 1 && last.x + last.width <= bounds.x + bounds.width + 1,
					"active tab was not revealed after selection/resize");
				trace("PASS: crowded editor tabs do not overlap, long Unicode labels ellipsize, tooltips preserve filenames, wheel scrolling and active reveal work");
			}
		}
		return result;
	}

	function pointerActionsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) {
			application.commands.add("test:pointer-first", function(_) pointerCommand = "first", null, "Pointer palette first");
			application.commands.add("test:pointer-second", function(_) pointerCommand = "second", null, "Pointer palette second");
			ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
		}
		if (frames == 3) ui.text(UiEventKind.TextInput, "Pointer palette");
		if (frames == 4) {
			var bounds = node("cv-row-1").globalBounds();
			pointerX = bounds.x + 20; pointerY = bounds.y + bounds.height / 2;
			ui.pointerDown(pointerX, pointerY, 0, 0, 42);
		}
		if (frames == 5) {
			ui.pointerUp(pointerX, pointerY, 0, 0, 42);
			require(pointerCommand == "second" && !host.isCommandViewActive(), "pointer did not execute the clicked palette entry: " + pointerCommand);
			trace("PASS: command palette mouse click executes the requested entry across rendered frames");
		}
		var result = super.submit(frame);
		return result;
	}

	function saveAsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var destination = path + ".saved";
		if (frames == 2) {
			sys.io.File.saveContent(destination, "existing content");
			closeOther = cast host.openDocument(application.documents.createUntitled());
			closeOther.document.buffer.replaceAllText("saved through chooser", closeOther.selection);
			application.files.openSaveAs(closeOther.document, function() saveAsSuccesses++, function() saveAsCancellations++);
		}
		if (frames == 3 || frames == 7) {
			require(saveAsDestination != null && !host.isCommandViewActive(), "Save As used command input instead of a dialog");
			ui.focusWidget(node("save-as-path").id);
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.text(UiEventKind.TextInput, destination);
		}
		if (frames == 4 || frames == 8) {
			click("save-as-save");
			require(saveAsDestination != null && sys.io.File.getContent(destination) == "existing content",
				"Save As overwrote before confirmation");
		}
		if (frames == 5) {
			click("save-as-cancel");
			require(saveAsDestination == null && saveAsCancellations == 1 && closeOther.document.dirty && !closeOther.document.hasBackingPath(),
				"Save As cancellation changed the document");
		}
		if (frames == 6)
			application.files.openSaveAs(closeOther.document, function() saveAsSuccesses++, function() saveAsCancellations++);
		if (frames == 9) {
			click("save-as-save");
			require(saveAsDestination == null && saveAsSuccesses == 1 && !closeOther.document.dirty &&
				closeOther.document.requirePath() == destination && sys.io.File.getContent(destination) == "saved through chooser",
				"confirmed Save As did not update the file and document identity");
			trace("PASS: button-based Save As, overwrite confirmation, cancellation, retry, persisted content and document identity");
		}
		return super.submit(frame);
	}

	function requestTestExit():Void {
		var handler = closeContext.onCloseRequested;
		if (handler == null) throw "missing application close interception";
		handler(function() exitCount++);
	}

	function exitConfirmationStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) {
			closePrimary = host.activeView();
			closePrimary.document.buffer.replaceAllText("saved on exit\n", closePrimary.selection);
			closeOther = cast host.openDocument(application.documents.createUntitled());
			closeOther.document.buffer.replaceAllText("unsaved untitled", closeOther.selection);
			application.recovery.save(application);
		}
		if (frames == 3 || frames == 5 || frames == 9) requestTestExit();
		if (frames == 3) requestTestExit(); // A repeated window close must not duplicate the transaction.
		if (frames == 4) {
			require(saveConfirmation != null && exitCount == 0, "window close skipped unsaved confirmation");
			click("save-confirmation-cancel");
			require(exitCount == 0 && !application.files.quitReady && closePrimary.document.dirty, "cancel did not keep the app and edits");
		}
		if (frames == 6) {
			click("save-confirmation-save");
			require(!closePrimary.document.dirty && sys.io.File.getContent(path) == "saved on exit\n", "exit Save did not write the backing file");
			require(exitCount == 0 && saveConfirmation != null, "exit did not wait for all dirty documents");
		}
		if (frames == 7) {
			click("save-confirmation-save");
			require(saveAsDestination != null && !host.isCommandViewActive() && exitCount == 0, "untitled exit Save skipped Save As");
		}
		if (frames == 8) {
			ui.key(UiEventKind.KeyDown, UiKey.Escape);
			require(saveAsDestination == null && exitCount == 0 && !application.files.quitReady,
				"cancelling Save As did not cancel exit");
		}
		if (frames == 10) {
			click("save-confirmation-discard");
			require(exitCount == 1 && application.files.quitReady && saveConfirmation == null, "confirmed exit did not close exactly once");
			application.session.shutdown();
			require(application.recovery.load().length == 0, "discarded exit changes were recreated by shutdown recovery");
			trace("PASS: window exit confirms dirty documents, Cancel and Save As cancellation preserve edits, Save/Discard closes once without restoring discarded recovery");
		}
		return super.submit(frame);
	}

	function caretFollowStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var view = host.activeView();
		if (view == null) throw "caret follow missing editor";
		if (frames == 2) {
			setApplicationZoom(125);
			ui.focusWidget(node("editor:" + view.document.id).id);
			ui.key(UiEventKind.KeyDown, UiKey.End, UiModifier.Control);
		}
		if (frames >= 3 && frames <= 5) {
			for (_ in 0...35) ui.key(UiEventKind.KeyDown, UiKey.Enter);
		}
		if (frames == 6) view.scrollController.jumpTo(0, 0);
		var result = super.submit(frame);
		if (frames >= 3 && frames <= 5) {
			require(view.scrollController.offsetY > 0, "new lines did not scroll the editor");
			var caret = host.textInputArea();
			var bounds = node("editor-scroll:" + view.document.id).globalBounds();
			require(caret != null && caret.y >= bounds.y - 1 && caret.y + caret.height <= bounds.y + bounds.height + 2,
				"caret left the viewport after repeated Enter: frame=" + frames + ", caret=" + (caret == null ? "null" : caret.y + ":" + caret.height) + ", viewport=" + bounds.y + ":" + bounds.height + ", offset=" + view.scrollController.offsetY);
			require(caret != null && bounds.y + bounds.height - caret.y - caret.height >= Math.min(caret.height * 4, bounds.height * 0.35) - 2,
				"repeated Enter did not leave several visible lines below the caret");
		}
		if (frames == 6) {
			require(view.scrollController.offsetY == 0, "caret margin overrode manual scrolling");
			trace("PASS: repeated Enter keeps a five-line caret margin at fractional zoom and preserves manual scrolling");
		}
		return result;
	}

	function closeHeaderWidth(target:haxeon.ui.core.RenderNode):Float {
		var slot = target.parent;
		if (slot == null) throw "close target missing slot";
		var row = slot.parent;
		if (row == null) throw "close target missing row";
		return row.globalBounds().width;
	}
	function tabCloseStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) {
			setApplicationZoom(125);
			closePrimary = host.activeView();
			if (closePrimary == null) throw "close test missing primary";
			closeOther = cast host.openDocument(application.documents.createUntitled());
			host.activateTab(closePrimary.document);
		}
		if (frames == 5) {
			require(host.allViews().length == 1, "clean inactive tab did not close");
			closeOther = cast host.openDocument(application.documents.createUntitled());
			closeOther.document.buffer.replaceAllText("unsaved", closeOther.selection);
			host.activateTab(closePrimary.document);
			super.submit(frame);
		}
		if (frames == 3 || frames == 5 || frames == 8) {
			var target = node("tab-close:doc:" + closeOther.document.id);
			var bounds = target.globalBounds();
			closeWidth = closeHeaderWidth(target);
			ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		}
		if (frames == 4 || frames == 6 || frames == 9) {
			var target = node("tab-close:doc:" + closeOther.document.id);
			require(target.layout.style.visible && closeHeaderWidth(target) == closeWidth, "close hover changed width or failed to show at frame " + frames + ": visible=" + target.layout.style.visible + ", width=" + closeHeaderWidth(target) + ", previous=" + closeWidth);
			if (frames == 4 || frames == 6) {
				var bounds = node("doc:" + closeOther.document.id).globalBounds();
				ui.pointerDown(bounds.x + 20, bounds.y + bounds.height / 2, 2);
				ui.pointerUp(bounds.x + 20, bounds.y + bounds.height / 2, 2);
			} else click("tab-close:doc:" + closeOther.document.id);
			require(host.activeView() == closePrimary, "inactive tab close changed active editor");
		}
		if (frames == 7) {
			require(saveConfirmation != null && host.allViews().length == 2, "dirty close did not ask before removing tab");
			ui.key(UiEventKind.KeyDown, UiKey.Escape);
			require(saveConfirmation == null && host.allViews().length == 2, "cancel did not preserve dirty tab");
		}
		if (frames == 10) {
			require(saveConfirmation != null, "second dirty close did not ask");
			click("save-confirmation-discard");
			require(host.allViews().length == 1 && host.activeView() == closePrimary, "discard closed the wrong tab");
			setApplicationZoom(100);
		}
		if (frames == 11) {
			var bounds = node("tab-close:doc:" + closePrimary.document.id).globalBounds();
			ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		}
		if (frames == 12) {
			click("tab-close:doc:" + closePrimary.document.id);
			require(host.allViews().length == 0 && host.activeView() == null, "closing the last active file did not clear the editor");
			trace("PASS: zoomed hover close, stable width, inactive tab closing, dirty cancel/discard and last active tab closing");
		}
		return super.submit(frame);
	}

	function selectionStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frame.deltaSeconds = 0.05;
		var view = host.activeView();
		if (view == null) throw "Selection test missing editor";
		if (frames == 2) {
			setApplicationZoom(125);
			view.document.buffer.replaceAllText([for (line in 0...80) "row " + line].join("\n"), view.selection);
			view.selection.setCursor(view.document.buffer, new editor.BufferPosition(0, 0));
			view.scrollController.jumpTo(0, 0);
		}
		if (frames == 3) {
			var editorNode = node("editor:" + view.document.id);
			var bounds = editorNode.resolved;
			if (bounds == null) throw "Selection editor not resolved";
			var clip = bounds.clipBounds;
			var pointerX = Math.max(clip.x, editorNode.globalBounds().x) + 20;
			ui.pointerDown(pointerX, clip.y + 10, 0);
			ui.pointerMove(pointerX, clip.y + clip.height + 20);
			selectionDragOffset = view.scrollController.offsetY;
		}
		var result = super.submit(frame);
		if (frames == 7) {
			require(view.scrollController.offsetY > selectionDragOffset && view.selection.hasSelection(), "zoomed editor stationary drag did not scroll or extend selection");
			ui.pointerUp(0, 0, 0);
			selectionStoppedOffset = view.scrollController.offsetY;
		}
		if (frames == 9) {
			require(view.scrollController.offsetY == selectionStoppedOffset, "editor drag scrolling did not stop on release");
			setApplicationZoom(100);
			trace("PASS: selection drag scrolls external editor viewport at fractional zoom and stops on release");
		}
		return result;
	}

	function wordDeleteStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var view = host.activeView();
		if (view == null) throw "Word deletion test missing editor";
		if (frames == 2) {
			view.document.buffer.replaceAllText("hello world\nhello world", view.selection);
			view.selection.setCursor(view.document.buffer, new editor.BufferPosition(0, 11));
			view.selection.addRange(view.document.buffer, new editor.BufferPosition(1, 11), new editor.BufferPosition(1, 11));
		}
		if (frames == 3) {
			ui.focusWidget(node("editor:" + view.document.id).id);
			ui.key(UiEventKind.KeyDown, UiKey.Backspace, Sys.systemName() == "Mac" ? UiModifier.Alt : UiModifier.Control);
		}
		if (frames == 4) {
			require(view.document.buffer.text == "hello \nhello ", "multi-caret word backspace failed");
			view.document.undo(view.selection);
			require(view.document.buffer.text == "hello world\nhello world" &&
				view.selection.rangeCount() == 2 && view.selection.cursor.column == 11, "word deletion undo lost text or carets");
		}
		if (frames == 5) {
			view.document.redo(view.selection);
			require(view.document.buffer.text == "hello \nhello ", "word deletion redo failed");
			trace("PASS: editor multi-caret word deletion, undo and redo");
		}
		return super.submit(frame);
	}

	function zoomStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var modifier = Sys.systemName() == "Mac" ? UiModifier.Super : UiModifier.Control;
		if (frames == 2) ui.key(UiEventKind.KeyDown, 61, modifier);
		if (frames == 3) {
			require(application.settings.current.applicationZoom == 110, "zoom in shortcut failed");
			require(Math.abs(frame.width - 900 / 1.1) < 0.01, "zoom did not change host layout viewport");
			require(new config.Preferences(config.ConfigurationPaths.userSettings()).current.applicationZoom == 110, "zoom did not persist");
			ui.key(UiEventKind.KeyDown, 61, modifier | UiModifier.Shift);
		}
		if (frames == 4) {
			require(application.settings.current.applicationZoom == 120, "shift plus shortcut failed");
			ui.key(UiEventKind.KeyDown, 45, modifier);
		}
		if (frames == 5) {
			require(application.settings.current.applicationZoom == 110, "zoom out shortcut failed");
			ui.key(UiEventKind.KeyDown, 48, modifier);
		}
		if (frames == 6) {
			require(application.settings.current.applicationZoom == 100 && Math.abs(frame.width - 900) < 0.01, "zoom reset failed");
			setApplicationZoom(500);
			require(application.settings.current.applicationZoom == 200, "zoom upper bound failed");
			setApplicationZoom(10);
			require(application.settings.current.applicationZoom == 70, "zoom lower bound failed");
			setApplicationZoom(100);
			trace("PASS: application zoom shortcuts, host viewport, persistence, reset and bounds");
		}
		return super.submit(frame);
	}

	function settingsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frame.setViewport(1100, 760);
		var activeSettingsView = host.activeView();
		if (activeSettingsView == null) throw "Settings test missing editor";
		if (frames == 2) ui.key(UiEventKind.KeyDown, UiKey.Comma, UiModifier.Control);
		if (frames == 3) {
			require(node("settings-dialog") != null, "settings shortcut did not open modal");
			// The panel chooses a category from the user's search, as it does during typing.
			settingsPanel.setFilter("minimap");
		}
		if (frames == 4) click("editor:editor/display/minimap_enabled");
		if (frames == 5) {
			require(!application.settings.current.minimapEnabled, "settings checkbox did not apply immediately");
			require(!new config.Preferences(config.ConfigurationPaths.userSettings()).current.minimapEnabled,
				"settings checkbox did not persist");
			require(find(ui.root, "editor-minimap:" + activeSettingsView.document.id) == null, "minimap remained after preference edit");
			ui.key(UiEventKind.KeyDown, UiKey.Escape, 0);
		}
		if (frames == 6) {
			require(find(ui.root, "settings-dialog") == null, "Escape did not dismiss settings");
			application.commands.perform("settings:open", application.context);
			settingsPanel.setFilter("font size");
		}
		if (frames == 7) {
			var store = application.settings.store;
			store.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(22));
			click("settings-close");
			openTerminal();
		}
		var result = super.submit(frame);
		if (frames == 8) {
			var editor = node("editor:" + activeSettingsView.document.id);
			var fontApplied = false;
			editor.walk(function(child) {
				if (child.layout.visualKind == LayoutVisualKind.Custom && child.layout.textStyle.fontSize == 22 && child.layout.intrinsicContent != null) fontApplied = true;
			});
			require(fontApplied, "editor font size did not apply live");
			var gutter = node("gutter:" + activeSettingsView.document.id);
			var gutterProbe = TextLayout.create(testFonts, Std.string(activeSettingsView.document.buffer.lineCount()), 1.0,
				new TextStyle(22.0, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
			var gutterGeometry = gutter.resolved;
			if (gutterGeometry == null) throw "Settings test missing gutter geometry";
			require(Math.abs(gutterGeometry.width - (gutterProbe.measure().width + 12.0)) < 0.01,
				"gutter font size did not follow editor font size");
			gutterProbe.dispose();
			require(find(ui.root, "settings-dialog") == null, "Close did not dismiss settings");
			application.settings.store.reset("editor/display/minimap_enabled");
			var terminal = host.activePanelTerminal();
			if (terminal == null) throw "Settings test missing terminal";
			settingsTerminalColumns = terminal.panel.columns();
			application.settings.store.set("terminal/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(28));
		}
		if (frames == 9) {
			require(find(ui.root, "editor-minimap:" + activeSettingsView.document.id) != null, "reset did not restore minimap");
		}
		if (frames == 10) {
			var terminal = host.activePanelTerminal();
			if (terminal == null) throw "Settings test lost terminal";
			require(terminal.panel.columns() < settingsTerminalColumns, "terminal font size did not resize live");
			trace("PASS: settings shortcut, searchable panel, checkbox persistence, live editor and terminal font size, reset and modal dismissal");
		}
		return result;
	}

	function minimapStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var view = host.activeView();
		if (view == null) throw "minimap acceptance missing editor";
		if (frames == 2) {
			view.document.buffer.replaceAllText([for (index in 0...200)
				"class Line" + index + " { var text = \"wrapped 🙂 preview \"; } // " + [for (_ in 0...12) "long text "].join("")].join("\n"), view.selection);
		}
		if (frames == 3) {
			var bounds = node("editor-minimap:" + view.document.id).globalBounds();
			var y = Math.min(bounds.height, 400) - 4;
			ui.pointerDown(bounds.x + 30, bounds.y + y, 0);
			ui.pointerUp(bounds.x + 30, bounds.y + y, 0);
			var scale = 2.0 / (application.settings.current.fontSize * 1.4);
			var expected = Math.max(0, Math.min(view.scrollController.contentHeight - view.scrollController.viewportHeight,
				y / scale - view.scrollController.viewportHeight / 2));
			require(Math.abs(view.scrollController.offsetY - expected) < 0.01, "minimap click did not use wrapped content metrics");
		}
		if (frames == 4) {
			view.scrollController.jumpTo(0, 0);
			var bounds = node("editor-minimap:" + view.document.id).globalBounds();
			ui.pointerDown(bounds.x + 30, bounds.y + 2, 0);
			ui.pointerMove(bounds.x + 30, bounds.y + 150);
			ui.pointerUp(bounds.x + 30, bounds.y + 150, 0);
			require(view.scrollController.offsetY > 0, "minimap viewport drag did not scroll");
		}
		frame.setViewport(frames == 5 ? 420 : 900, 600);
		if (frames == 6) application.settings.current.minimapEnabled = false;
		if (frames == 7) application.settings.current.minimapEnabled = true;
		if (frames == 8) view.document.buffer.replaceAllText("", view.selection);
		if (frames == 9) view.document.undo(view.selection);
		if (frames == 10) view.scrollController.jumpTo(0, 0);
		var result = super.submit(frame);
		if (frames == 2 || frames == 7) {
			var preview = node("editor-minimap:" + view.document.id).globalBounds();
			var scroll = editorViewport(view.document.id).globalBounds();
			require(preview.width == 88 && preview.x >= scroll.x + scroll.width - 0.01, "minimap is not fixed to editor right edge");
		}
		if (frames == 5) require(node("editor-minimap:" + view.document.id).globalBounds().width == 0, "narrow editor retained minimap width");
		if (frames == 6) require(find(ui.root, "editor-minimap:" + view.document.id) == null, "disabled minimap retained its node");
		if (frames == 8) {
			require(view.scrollController.offsetY == 0, "empty document retained minimap scroll offset");
			trace("PASS: editor minimap right placement, wrapped navigation, pointer drag, narrow layout, live settings and empty document");
		}
		return result;
	}

	static function findViewport(root:haxeon.ui.core.RenderNode, documentId:Int):Null<haxeon.ui.core.RenderNode> {
		if (root.styleType == "scroll-view" && root.styleKey == "editor-scroll:" + documentId) return root;
		for (child in root.children) { var found = findViewport(child, documentId); if (found != null) return found; }
		return null;
	}
	function editorViewport(documentId:Int):haxeon.ui.core.RenderNode {
		var viewport = findViewport(ui.root, documentId);
		if (viewport == null) throw "editor viewport missing";
		return viewport;
	}
	static function findScrollbar(root:haxeon.ui.core.RenderNode, documentId:Int):Null<haxeon.ui.core.RenderNode> {
		if (root.styleType == "scrollbar-track" && root.styleKey == "editor-scroll:" + documentId) return root;
		for (child in root.children) { var found = findScrollbar(child, documentId); if (found != null) return found; }
		return null;
	}
	function editorScrollbar(documentId:Int):haxeon.ui.core.RenderNode {
		var track = findScrollbar(ui.root, documentId);
		if (track == null) throw "editor scrollbar missing";
		return track;
	}
	function scrollbarStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frame.deltaSeconds = frames == 5 ? 0.49 : frames == 6 ? 0.1 : frames == 7 ? 0.2 : 0;
		var view = host.activeView();
		if (view == null) throw "scrollbar acceptance missing editor";
		if (frames == 3) {
			var scroll = editorViewport(view.document.id);
			var trackNode = editorScrollbar(view.document.id);
			var track = trackNode.globalBounds();
			var color = editorScrollbar(view.document.id).children[0].layout.style.background;
			require(color != null && color.alpha == 0, "idle editor scrollbar is visible");
			ui.pointerMove(track.x + track.width / 2, track.y + track.height / 2);
		}
		if (frames == 4) ui.pointerMove(0, 0);
		if (frames == 8) {
			var bounds = editorViewport(view.document.id).globalBounds();
			ui.scroll(bounds.x + 40, bounds.y + 40, 0, 50);
		}
		if (frames == 9 || frames == 10 || frames == 11) {
			var settings = application.settings.current.copy();
			settings.scrollbarVisibility = frames == 9 ? "always" : frames == 10 ? "hidden" : "auto";
			host.applySettings(settings);
		}
		var result = super.submit(frame);
		var scroll = editorViewport(view.document.id);
		if (frames == 10) require(findScrollbar(ui.root, view.document.id) == null, "hidden policy retains scrollbar or hit target");
		else if (frames >= 3) {
			var trackNode = editorScrollbar(view.document.id);
			var bounds = trackNode.globalBounds();
			var pane = node("editor-container:" + view.document.id).globalBounds();
			require(Math.abs(bounds.x + bounds.width - (pane.x + pane.width - 2)) < 0.01, "scrollbar is not at editor pane right edge");
			require(scroll.children.length == 1, "duplicate scrollbar remains inside text viewport");
			var color = trackNode.children[0].layout.style.background;
			if (color == null) throw "scrollbar has no paint";
			if (frames == 3 || frames == 4 || frames == 5 || frames == 8 || frames == 9) require(color.alpha == 1, "hover/scroll/always did not reveal scrollbar");
			if (frames == 6) require(color.alpha > 0 && color.alpha < 1, "scrollbar did not fade");
			if (frames == 7 || frames == 11) require(color.alpha == 0, "idle scrollbar or restored auto did not hide");
		}
		if (frames == 11) trace("PASS: real editor scrollbar idle, edge hover, delayed fade, wheel reveal and live visibility settings");
		return result;
	}
	function node(key:String):haxeon.ui.core.RenderNode {
		var root = ui.root;
		if (root == null) throw "sidebar has no resolved UI";
		var found = find(root, key);
		if (found == null) throw "sidebar widget missing: " + key;
		return found;
	}
	static function find(root:haxeon.ui.core.RenderNode, key:String):Null<haxeon.ui.core.RenderNode> {
		if (root.styleKey == key) return root;
		for (child in root.children) { var found = find(child, key); if (found != null) return found; }
		return null;
	}
	static function findTree(root:haxeon.ui.core.RenderNode):Null<haxeon.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tree) return root;
		for (child in root.children) { var found = findTree(child); if (found != null) return found; }
		return null;
	}
	function click(key:String):Void {
		var bounds = node(key).globalBounds();
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
	}
	static function treeRow(root:haxeon.ui.core.RenderNode, path:String):Null<haxeon.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem && root.semantics.label == path) return root;
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
	function editorFontStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var result = super.submit(frame);
		if (frames == 3) {
			var fonts = ui.buildContext.fonts;
			if (fonts == null) throw "font acceptance missing font collection";
			var narrow = TextLayout.create(fonts, "iiii", 1000, new TextStyle(15, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
			var wide = TextLayout.create(fonts, "WWWW", 1000, new TextStyle(15, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
			require(Math.abs(narrow.measure().width - wide.measure().width) < 0.01 && narrow.measure().width > 0, "editor font is not fixed width");
			narrow.dispose(); wide.dispose();
			var narrowUi = TextLayout.create(fonts, "iiii", 1000, new TextStyle(15), new ParagraphStyle(TextWrap.None));
			var wideUi = TextLayout.create(fonts, "WWWW", 1000, new TextStyle(15), new ParagraphStyle(TextWrap.None));
			require(Math.abs(narrowUi.measure().width - wideUi.measure().width) > 1, "editor font replaced proportional UI font");
			narrowUi.dispose(); wideUi.dispose();
			var view = host.activeView();
			if (view == null) throw "font acceptance missing document";
			var monospace = false;
			node("editor:" + view.document.id).walk(function(child) {
				if (child.layout.textStyle.font == FontFamily.Monospace) monospace = true;
			});
			require(monospace, "editor widget did not request monospace family");
			trace("PASS: explicit fixed-width editor family, proportional UI family, native monospace shaping");
		}
		return result;
	}

	function problemsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frame.deltaSeconds = 1.0;
		var file = new feedback.Problem("test", "file", path, 2, 1, 3, "File warning", 2, null, "Test");
		var project = feedback.Problem.scoped("test", "project", feedback.ProblemScope.Project(haxe.io.Path.directory(path)), "Project issue", 1, "Test");
		var workspace = feedback.Problem.scoped("test", "workspace", feedback.ProblemScope.Workspace, "Workspace issue", 1, "Test",
			[new feedback.ProblemAction("Show status", "test:problem-action")]);
		if (frames == 2) {
			application.commands.add("test:problem-action", function(_) diagnosticActions++);
			host.getProblems().replaceOwner("test", [file, project, workspace]);
			host.showProblems();
		}
		if (frames == 3 || frames == 5) {
			var bounds = node("problems-scroll").globalBounds();
			ui.scroll(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0, frames == 3 ? 10000 : -10000);
		}
		if (frames == 4) click("problem:" + workspace.key());
		if (frames == 6) click("problem-group:" + file.scopeKey());
		if (frames == 7) host.getProblems().replaceOwner("test", [project, workspace, file, feedback.Problem.scoped("test", "extra", feedback.ProblemScope.Workspace, "Another workspace issue", 2)]);
		if (frames == 8) click("problem-group:" + file.scopeKey());
		if (frames == 9) click("problem:" + file.key());
		var result = super.submit(frame);
		if (frames == 2 || frames == 7) {
			var foundBadge = false;
			ui.root.walk(function(child) {
				if (child.styleKey == "count-badge" && child.children.length > 0 && child.children[0].layout.text == Std.string(frames == 2 ? 3 : 4)) foundBadge = true;
			});
			require(foundBadge, "Problems count did not render/update as a badge");
		}
		if (frames >= 2) { node("problem-group:" + project.scopeKey()); node("problem-group:workspace"); }
		if (frames == 4) {
			require(diagnosticActions == 1 && host.activeView() == null, "workspace action/navigation failed: " + diagnosticActions);
			node("problem-action:0");
		}
		if (frames == 7) {
			require(find(ui.root, "problem:" + file.key()) == null, "diagnostic refresh lost collapsed group");
			node("problem-action:0");
		}
		if (frames == 10) {
			var view = host.activeView();
			require(view != null && view.document.path == path && view.selection.cursor.line == 2, "file diagnostic navigation lost location");
			trace("PASS: scoped Problems groups, workspace actions, stable selection/collapse, file navigation");
		}
		return result;
	}

	function activityBarStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 3) click("activity:files");
		if (frames == 4) click("activity:search");
		if (frames == 5) {
			registerSidebarDestination("sessions", haxeon.ui.icons.IconName.Terminal,
				function() return new haxeon.ui.widgets.text.Text("Session list"),
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Sessions", 20));
			activateSidebarDestination("sessions");
		}
		if (frames == 6) click("activity:sessions");
		if (frames == 7) click("activity:sessions");
		var result = super.submit(frame);
		node("activity:files"); node("activity:search");
		if (frames == 2) require(!sidebar.visible, "empty startup unexpectedly opened sidebar");
		if (frames == 3) require(sidebar.visible && sidebar.activeId == "files", "activity bar did not open Files");
		if (frames == 4) require(sidebar.visible && sidebar.activeId == "search", "activity bar did not switch to Search");
		if (frames >= 5) node("activity:sessions");
		if (frames == 5) require(sidebar.visible && sidebar.activeId == "sessions", "registered destination did not activate");
		if (frames == 6) require(!sidebar.visible, "active destination did not collapse sidebar");
		if (frames == 7) {
			require(sidebar.visible && sidebar.activeId == "sessions", "collapsed destination did not reopen");
			trace("PASS: permanent Activity Bar opens, switches, collapses, reopens and follows destination registration");
		}
		return result;
	}

	function sidebarStep():Void {
		if (phase == "sidebar-write") {
			if (frames >= 2) { node("activity:files"); node("activity:search"); }
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
				require(files != null && sidebar.width > sidebarWidth + 20, "Files divider width was not retained");
				sidebarWidth = sidebar.width;
				click("search");
			}
			if (frames == 8) {
				require(sidebar.activeId == "search", "Search tab click failed");
				require(Math.abs(node("sidebar-modes").globalBounds().width - sidebarWidth) < 1, "destination switch changed shared width: " + node("sidebar-modes").globalBounds().width);
				resizeSidebar(40);
			}
			if (frames == 10) {
				var search = sidebar.find("search");
				require(search != null && sidebar.width > sidebarWidth + 30, "Search divider width lost");
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt", sidebar.encode());
				trace("PASS: sidebar commands, pointer tabs and shared dragged width");
			}
		} else if ((phase == "sidebar-read" || phase == "sidebar-hidden-read") && frames == 5) {
			require(sidebar.activeId == "search", "restart lost sidebar mode");
			require(sidebar.encode() == sys.io.File.getContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt"),
				"restart lost sidebar visibility or shared width");
			if (phase == "sidebar-read") {
				require(sidebar.visible, "restart hid sidebar");
				application.commands.perform("workbench:toggle-sidebar", application.context);
				host.sessionLines();
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt", sidebar.encode());
			} else { require(!sidebar.visible, "hidden sidebar reopened"); node("activity:search"); }
			trace("PASS: " + phase + " restores selected mode, visibility and shared width");
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
	static function invalidServerSettings(executable:String):String {
		var values:Dynamic = {};
		Reflect.setField(values, "languages/haxeon/command", haxe.Json.stringify([executable]));
		return haxe.Json.stringify({version: 1, values: values, state: {}});
	}
	function languageStep():Void {
		var service = application.language.client;
		var settingsPath = config.ConfigurationPaths.userSettings();
		if (languageStage == 0 && service != null && service.ready && ui.root != null && hasText(node("exosuit-status"), "Haxeon: ready")) {
			languageSettings = sys.io.File.getContent(settingsPath);
			sys.io.File.saveContent(settingsPath, invalidServerSettings(path + "/missing-server"));
			application.settings.reload(true);
			languageStage = 1;
		} else if (languageStage == 1 && host.getProblems().values().length > 0 && ui.root != null && hasText(node("exosuit-status"), "language server")) {
			require(hasText(node("problems-scroll"), "language server"), "language failure did not render in Problems");
			sys.io.File.saveContent(settingsPath, languageSettings); application.settings.reload(true); languageStage = 2;
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

	static function hasText(node:haxeon.ui.core.RenderNode, value:String):Bool {
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
		options.frameLimit = args[2] == "save-as" ? 10 : args[2] == "exit-confirmation" ? 11 : args[2] == "tab-close" ? 13 : args[2] == "selection" ? 10 : args[2] == "problems" ? 10 : args[2] == "settings" ? 11 : args[2] == "editor-tabs" ? 10 : args[2] == "explorer-icons" ? 14 : args[2] == "editor-minimap" ? 11 : args[2] == "scrollbar-visibility" ? 12 : args[2] == "explorer-preview" ? 12 : args[2] == "language-folder" ? 121 : args[2] == "editor-scroll" ? 13 : args[2] == "sidebar-preview" ? 18 : args[2] == "sidebar-search" || args[2] == "sidebar-stale-preview" ? 20 : args[2] == "sidebar-write" ? 11 : args[2] == "keyboard" ? 17 : args[2] == "write" ? 12 : 7;
		var status = DesktopUiHost.run(options, context -> new WorkspaceSmokeApp(context, args[0], args[2]));
		platform.Native.shutdown();
		return status;
	}
}
