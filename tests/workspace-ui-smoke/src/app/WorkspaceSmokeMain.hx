package app;

import editor.EditorCoordinates;

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
import ui.ExosuitPalette;
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
	var settingsSourceView:Null<UiDocumentView>;
	var closePrimary:UiDocumentView;
	var closeOther:UiDocumentView;
	var closeWidth:Float = 0;
	var selectionDragOffset:Float = 0.0;
	var selectionStoppedOffset:Float = 0.0;
	var panelControlsLayout = "";
	var responsiveTerminal:ui.UiTerminalTab;
	var responsiveSidebarWidth:Float = 0;
	var responsiveRightWidth:Float = 0;
	var panelControlsHeight = 0.0;
	var panelControlsTerminal:Null<ui.TerminalPanel>;
	var remoteOpenTests:Null<RemoteFileOpenTests>;

	public function new(context:haxeon.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, (phase == "mode-write" || phase == "mode-phone-default" || phase == "context-layout-write" || StringTools.startsWith(phase, "layout-") || phase == "active-context" || phase == "saved-workspace" || phase == "divider-chrome" || phase == "explorer-rename" || phase == "explorer-preview" || phase == "explorer-icons") ? path.substring(0, path.lastIndexOf("/")) : phase == "language-folder" || phase == "editor-geometry" || phase == "editor-scroll" || phase == "editor-resize" || phase == "editor-font" || phase == "editor-tabs" || phase == "zoom" || phase == "word-delete" || phase == "selection" || phase == "tab-close" || phase == "pointer-actions" || phase == "blank-editor-click" || phase == "caret-follow" || phase == "exit-confirmation" || phase == "save-as" || phase == "tab-close-paint" || phase == "settings" || phase == "editor-minimap" || phase == "toolbar-tooltip" || phase == "scrollbar-visibility" || phase == "write" || phase == "keyboard" || phase == "sidebar-write" || (phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) ? path : null,
			null, null, null, WorkspaceSmokeMain.createTerminal);
		this.phase = phase;
		closeContext = context;
		this.testFonts = context.fonts;
		this.path = path;
		if (phase == "context-layout-write" || StringTools.startsWith(phase, "layout-") || phase == "mode-write" || phase == "mode-phone-default") application.open(path);
		if (phase == "layout-write" && !layoutControls.bottomOpen()) layoutControls.toggleBottom();
		if (phase == "divider-chrome") application.open(path);
		if (phase == "explorer-rename") {
			var folder = haxe.io.Path.directory(path) + "/folder.old";
			sys.FileSystem.createDirectory(folder);
			sys.io.File.saveContent(folder + "/Child.hx", "class Child {}\n");
		}
		if (phase == "zoom" || phase == "language-folder" || phase == "sidebar-write" || phase == "sidebar-search" || (phase == "sidebar-preview" || phase == "sidebar-stale-preview")) application.openArgument(path.substring(0, path.lastIndexOf("/")));
	}

	function require(value:Bool, message:String):Void { if (!value) throw message; }

	function themePaletteStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 1) {
			application.commands.add("test:late-palette", function(_) {}, null, "Late Palette Command");
			ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
		}
		if (frames == 2) {
			for (id in ["exosuit.preferences:theme-dark", "exosuit.preferences:theme-light", "view.zoom-in", "exosuit.test:late-palette"])
				require([for (entry in host.commandView.results) if (entry.value == id) entry].length == 1,
					"keyboard palette missing " + id);
			host.commandView.setQuery("Use Light Theme");
			ui.key(UiEventKind.KeyDown, UiKey.Enter, 0);
		}
		if (frames == 3) {
			require(!host.isCommandViewActive() && theme.tokens.surface.red == ExosuitPalette.theme(false).tokens.surface.red,
				"keyboard palette did not apply light theme");
			require(ui.commands.execute("view.toggle-palette"), "toolbar palette command unavailable");
		}
		if (frames == 4) {
			var recent = [for (entry in host.commandView.results) if (entry.value == "exosuit.preferences:theme-light") entry];
			require(recent.length == 1 && recent[0].section == "Recently Used", "toolbar palette did not share keyboard palette history");
			host.commandView.setQuery("Use Dark Theme");
			ui.key(UiEventKind.KeyDown, UiKey.Enter, 0);
		}
		if (frames == 5) {
			require(!host.isCommandViewActive() && theme.tokens.surface.red == ExosuitPalette.theme(true).tokens.surface.red,
				"toolbar palette did not apply dark theme");
			application.commands.add("test:late-palette", function(_) {}, null, "Renamed Palette Command");
			application.commands.perform("commands:open", application.context);
			var renamed = [for (entry in host.commandView.results) if (entry.value == "exosuit.test:late-palette") entry];
			require(renamed.length == 1 && renamed[0].label == "Renamed Palette Command", "palette retained an old command label");
			host.closeCommandView();
			application.commands.remove("test:late-palette");
			application.commands.perform("commands:open", application.context);
			require([for (entry in host.commandView.results) if (entry.value == "exosuit.test:late-palette") entry].length == 0,
				"removed command remained in the shared palette");
			host.closeCommandView();
			trace("PASS: keyboard and toolbar palettes share theme commands, recent history and live plugin commands");
		}
		return super.submit(frame);
	}

	function palette(command:String):Void {
		paletteCommand = command;
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
	}

	override public function submit(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frames++;
		if (phase == "theme-palette") return themePaletteStep(frame);
		if (phase == "file-deletion") return fileDeletionStep(frame);
		if (phase == "explorer-rename") return explorerRenameStep(frame);
		if (phase == "divider-chrome") return dividerChromeStep(frame);
		if (phase == "saved-workspace") return savedWorkspaceStep(frame);
		if (phase == "active-context") return activeContextStep(frame);
		if (StringTools.startsWith(phase, "mode-")) return modeStep(frame);
		if (StringTools.startsWith(phase, "context-layout-")) return contextLayoutStep(frame);
		if (phase == "layout-responsive") return responsiveLayoutStep(frame);
		if (phase == "layout-panel-controls") return bottomPanelControlsStep(frame);
		if (StringTools.startsWith(phase, "layout-")) return layoutControlsStep(frame);
		if (phase == "remote-open") {
			if (frames == 1) { remoteOpenTests = new RemoteFileOpenTests(this); remoteOpenTests.start(); }
			if (frames == 2) {
				var loadingFile:ui.UiWorkspaceFileTab = cast UiEditorTabs.workspaceFile(host.activeTab());
				var loading = find(ui.root, "workspace-file-preview:" + loadingFile.id);
				require(loading != null, "loading preview was not rendered before the response");
				remoteOpenTests.finish();
			}
			return super.submit(frame);
		}
		if (phase == "large-picker") return largePickerStep(frame);
		if (phase == "editor-font") return editorFontStep(frame);
		if (phase == "problems") return problemsStep(frame);
		if (phase == "activity-bar") return activityBarStep(frame);
		if (phase == "scrollbar-visibility") return scrollbarStep(frame);
		if (phase == "editor-resize") return resizeStep(frame);
		if (phase == "editor-minimap") return minimapStep(frame);
		if (phase == "editor-geometry") return geometryStep(frame);
		if (phase == "toolbar-tooltip") return toolbarTooltipStep(frame);
		if (phase == "editor-tabs") return tabsStep(frame);
		if (phase == "settings") return settingsStep(frame);
		if (phase == "zoom") return zoomStep(frame);
		if (phase == "word-delete") return wordDeleteStep(frame);
		if (phase == "selection") return selectionStep(frame);
		if (phase == "tab-close") return tabCloseStep(frame);
		if (phase == "pointer-actions") return pointerActionsStep(frame);
		if (phase == "blank-editor-click") return blankEditorClickStep(frame);
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
			// Resolve the resized layout before injecting the tab-icon click on
			// frame 4; hit testing still uses the preceding submitted frame.
			if (frames == 3) { resizeSidebar(-80); frame.setViewport(500.0, 600.0); }
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
			var names = ["Main.hx", "Main.hxi", "data.json", "notes.md", "README.md", "tool.py", "Dockerfile", "mystery.wibble", "language-controller-test-with-an-extra-long-filename.hl"];
			var ids = ["_haxe", "_haxe", "_json", "_markdown", "_info", "_python", "_docker", "_default", "_default"];
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
		require(Math.abs(thumb.y - expectedThumbY) < 0.01, "resize left stale scrollbar thumb: frame=" + frames + ", actual=" + thumb.y + ", expected=" + expectedThumbY + ", offset=" + controller.offsetY + ", content=" + controller.contentHeight);
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
		frame.setViewport(frames >= 10 ? 4000 : frames == 7 ? 640 : 900, 600);
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
						if (frames < 10) require(child.globalBounds().width <= 181, "crowded tab label exceeds width cap");
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
			if (frames < 10) require(truncated, "long filename was not ellipsized");
			else if (frames >= 11) require(!truncated, "tab title was truncated despite spare rail width");
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

	function largePickerStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) {
			var store = new haxeon.ui.core.StateStore();
			var prefix = "4:root|20:exosuit-overlay-host|12:host-overlay|12:command-view|7:content|10:cv-content|4:list|9:cv-scroll|7:content|7:cv-rows|";
			var firstPath = prefix + "8:row24263|12:cv-row-24263|6:button";
			var secondPath = prefix + "8:row29451|12:cv-row-29451|5:label|5:label";
			require(haxeon.ui.core.KeyScope.widgetIdForPath(firstPath).value == haxeon.ui.core.KeyScope.widgetIdForPath(secondPath).value, "fixture no longer reproduces original collision");
			var first = store.resolveWidgetId(firstPath), second = store.resolveWidgetId(secondPath);
			require(first.value != second.value && store.resolveWidgetId(secondPath).value == second.value, "colliding paths alias widget identity");
			var build = new haxeon.ui.core.BuildContext(store);
			build.id("duplicate");
			var rejected = false;
			try { build.id("duplicate"); } catch (_:Dynamic) { rejected = true; }
			require(rejected, "duplicate widget keys were silently accepted");
			var entries:Array<commandview.CommandViewEntry> = [];
			for (index in 0...50000) entries.push(new commandview.CommandViewEntry("file-" + index, "", Std.string(index)));
			host.openCommandView(new commandview.CommandViewProvider("", entries, function(_) {}, function(entry, query, backwards) {
				pointerCommand = entry == null ? "" : entry.value;
				host.closeCommandView();
			}));
		}
		if (frames == 3) ui.key(UiEventKind.KeyDown, UiKey.Up, 0);
		if (frames == 4) {
			var bounds = node("cv-row-49999").globalBounds();
			require(bounds.y >= 40 && bounds.y + bounds.height <= 420, "keyboard selection was not revealed");
			ui.text(UiEventKind.TextInput, "file-49999");
		}
		if (frames == 5) click("cv-row-0");
		if (frames == 6) {
			require(pointerCommand == "49999" && !host.isCommandViewActive(), "filtered pointer result was not accepted");
			trace("PASS: 50000 picker results, keyboard reveal, filtering, pointer acceptance and widget hash collisions");
		}
		var result = super.submit(frame);
		if (frames >= 2 && frames <= 4) {
			var built = 0;
			var pending = [result];
			while (pending.length > 0) {
				var current = pending.pop();
				if (current.styleKey != null && StringTools.startsWith(current.styleKey, "cv-row-")) built++;
				for (child in current.children) pending.push(child);
			}
			require(built > 0 && built < 40, "picker materialized an unbounded number of rows: " + built);
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
			require(host.isCommandViewActive() && host.commandView.results.length == 2,
				"pointer palette query did not match two commands: " + host.commandView.query + " / " + host.commandView.results.length);
			var row = findLabel(ui.root, "Pointer palette second");
			if (row == null) throw "second palette command was not rendered";
			var bounds = row.globalBounds();
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

	function blankEditorClickStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var view = host.activeView();
		if (view == null) throw "blank click missing editor";
		if (frames == 7) {
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.key(UiEventKind.KeyDown, UiKey.Backspace);
		}
		if (frames == 3 || frames == 5 || frames == 9) {
			var editor = node("editor:" + view.document.id);
			var viewport = node("editor-scroll:" + view.document.id).globalBounds();
			ui.focusWidget(editor.id);
			var x = editor.globalBounds().x + 12;
			var y = viewport.y + viewport.height - 12;
			ui.pointerDown(x, y, 0); ui.pointerUp(x, y, 0);
		}
		var result = super.submit(frame);
		if (frames == 4 || frames == 6 || frames == 10) {
			var editor = node("editor:" + view.document.id);
			require(ui.focus.focusedId != null && ui.focus.focusedId.equals(editor.id), "click below last line lost editor focus");
			require(host.textInputArea() != null, "click below last line lost caret");
			require(EditorCoordinates.codepoint(view.document, view.selection.cursor) == view.document.buffer.document.codepointCount,
				"click below last line did not place caret at document end");
			if (frames == 4) {
				ui.key(UiEventKind.KeyDown, UiKey.End, UiModifier.Control);
				for (_ in 0...60) ui.key(UiEventKind.KeyDown, UiKey.Enter);
			}
			if (frames == 6) {
				ui.text(UiEventKind.TextInput, "typed");
				require(StringTools.endsWith(view.document.buffer.document.text, "typed"), "blank click did not retain text input");
			}
			if (frames == 10) trace("PASS: short, long and empty editor blank space retains focus, document-end caret and text input");
		}
		return result;
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
		// Allow the native window's initial scale/size events to settle before
		// checking viewport ratios. GDK_SCALE can resize it after the first frame.
		if (frames <= 6) return super.submit(frame);
		if (frames == 7) WorkspaceSmokeMain.zoomWidth = Std.int(frame.width);
		var zoomFrame = frames - 6;
		var modifier = Sys.systemName() == "Mac" ? UiModifier.Super : UiModifier.Control;
		if (zoomFrame == 2) ui.key(UiEventKind.KeyDown, 61, modifier);
		if (zoomFrame == 3) {
			require(application.settings.current.applicationZoom == 110, "zoom in shortcut failed");
			require(Math.abs(frame.width - WorkspaceSmokeMain.zoomWidth / 1.1) < 0.01, "zoom did not change host layout viewport");
			require(new config.Preferences(config.ConfigurationPaths.userSettings()).current.applicationZoom == 110, "zoom did not persist");
			ui.key(UiEventKind.KeyDown, 61, modifier | UiModifier.Shift);
		}
		if (zoomFrame == 4) {
			require(application.settings.current.applicationZoom == 120, "shift plus shortcut failed");
			ui.key(UiEventKind.KeyDown, 45, modifier);
		}
		if (zoomFrame == 5) {
			require(application.settings.current.applicationZoom == 110, "zoom out shortcut failed");
			ui.key(UiEventKind.KeyDown, 48, modifier);
		}
		if (zoomFrame == 6) {
			// GTK can deliver an initial HiDPI resize while these shortcuts run.
			// Reset must restore host zoom without forcing the window's old size.
			require(application.settings.current.applicationZoom == 100 && closeContext.zoom == 1.0 && frame.width > 0,
				"zoom reset failed: percent=" + application.settings.current.applicationZoom + ", viewport=" + frame.width);
			setApplicationZoom(500);
			require(application.settings.current.applicationZoom == 200, "zoom upper bound failed");
			setApplicationZoom(10);
			require(application.settings.current.applicationZoom == 70, "zoom lower bound failed");
			setApplicationZoom(100);
			trace("PASS: application zoom shortcuts, host viewport, persistence, reset and bounds");
		}
		if (zoomFrame >= 7 && zoomFrame < 67) {
			var step = (zoomFrame - 7) % 30;
			ui.key(UiEventKind.KeyDown, step < 15 ? 61 : 45, modifier);
			var percent = application.settings.current.applicationZoom;
			require(percent >= 70 && percent <= 200, "repeated zoom escaped supported bounds");
			trace("zoom stress frame=" + zoomFrame + " percent=" + percent);
		}
		if (zoomFrame == 67) {
			ui.key(UiEventKind.KeyDown, 48, modifier);
			trace("PASS: repeated zoom shortcuts render both limits and recover");
		}
		return super.submit(frame);
	}

	function settingsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frame.setViewport(1100, 760);
		if (frames == 1) settingsSourceView = host.activeView();
		var activeSettingsView = settingsSourceView;
		if (activeSettingsView == null) throw "Settings test missing editor";
		if (frames == 2) ui.key(UiEventKind.KeyDown, UiKey.Comma, UiModifier.Control);
		if (frames == 3) {
			require(UiEditorTabs.settings(host.activeTab()) != null && find(ui.root,"settings-dialog") == null,
				"settings shortcut did not open a normal editor tab");
			application.commands.perform("settings:open",application.context);
			require([for (item in host.activePane.items) if (UiEditorTabs.settings(item) != null) item].length == 1,
				"opening settings twice created duplicate tabs");
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
			require(UiEditorTabs.settings(host.activeTab()) != null,"Escape unexpectedly closed the settings tab");
			host.closeActiveTab(true);
			application.commands.perform("settings:open", application.context);
			settingsPanel.setFilter("font size");
		}
		if (frames == 7) {
			var store = application.settings.store;
			store.set("editor/fonts/font_size", haxeon.ui.properties.PropertyValue.Int(22));
			host.closeActiveTab(true);
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
			var gutter:Null<haxeon.ui.core.RenderNode> = null;
			ui.root.walk(function(child) {
				if (child.styleKey != null && StringTools.startsWith(child.styleKey,"gutter:"+activeSettingsView.document.id+":markers:")) gutter = child;
			});
			if (gutter == null) throw "Settings test missing retained gutter";
			var gutterProbe = TextLayout.create(testFonts, Std.string(activeSettingsView.document.buffer.lineCount()), 1.0,
				new TextStyle(22.0, FontFamily.Monospace), new ParagraphStyle(TextWrap.None));
			var gutterGeometry = gutter.resolved;
			if (gutterGeometry == null) throw "Settings test missing gutter geometry";
			require(Math.abs(gutterGeometry.width - (gutterProbe.measure().width + 12.0)) < 0.01,
				"gutter font size did not follow editor font size");
			gutterProbe.dispose();
			require(find(ui.root, "settings-dialog") == null, "Closing the settings tab left a modal");
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
			trace("PASS: settings shortcut, searchable panel, checkbox persistence, live editor and terminal font size, reset and normal settings-tab lifecycle");
		}
		return result;
	}

	function toolbarTooltipStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) ui.pointerMove(240, 60);
		if (frames == 3) {
			var bounds = node("explorer-action:Collapse All").globalBounds();
			ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		}
		if (frames == 4) ui.animations.advance(0.6);
		var result = super.submit(frame);
		if (frames >= 4) {
			var tip = node("explorer-action-tooltip:Collapse All");
			var geometry:haxeon.ui.ResolvedLayoutItem = cast tip.resolved;
			var sidebarBounds = node("sidebar-modes").globalBounds();
			require(tip.layout.style.visible && geometry.x + geometry.width > sidebarBounds.x + sidebarBounds.width,
				"Collapse All tooltip did not overlap the editor in acceptance fixture");
			require(geometry.clipBounds.x + geometry.clipBounds.width >= geometry.x + geometry.width,
				"Collapse All tooltip surface is clipped at sidebar boundary");
			if (frames == 7) trace("PASS: Files toolbar tooltip surface escapes sidebar clipping over editor");
		}
		return result;
	}

	function geometryStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 1) GutterGeometryTests.run();
		frame.deltaSeconds = 1.0 / 60.0;
		var view = host.activeView();
		if (view == null) throw "geometry acceptance missing editor";
		var controller = view.scrollController;
		controller.configureAnimation(false, 0);
		if (frames == 2) {
			view.document.buffer.replaceAllText([for (index in 0...200) "line" + index + " " + [for (_ in 0...150) "x"].join("")].join("\n"), view.selection);
		}
		if (frames == 3) {
			require(controller.maxScrollY > 1000 && controller.maxScrollX > 0, "long source lost intrinsic scroll ranges: " + controller.contentWidth + ":" + controller.contentHeight + " viewport=" + controller.viewportWidth + ":" + controller.viewportHeight);
			ui.focusWidget(node("editor:" + view.document.id).id);
			ui.key(UiEventKind.KeyDown, UiKey.Home, UiModifier.Control);
			for (_ in 0...100) ui.key(UiEventKind.KeyDown, UiKey.Down);
		}
		if (frames == 4) {
			require(controller.offsetY > 0, "keyboard Down did not scroll source: cursor=" + view.selection.cursor.line + ":" + view.selection.cursor.column + " content=" + controller.contentHeight + " viewport=" + controller.viewportHeight + " offset=" + controller.offsetY);
			selectionStoppedOffset = controller.offsetY;
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
		}
		if (frames == 5) {
			require(Math.abs(controller.offsetY - selectionStoppedOffset) < 0.01, "select all moved viewport");
			ui.key(UiEventKind.KeyDown, UiKey.Escape);
			controller.jumpTo(0, 0);
			var bounds = editorViewport(view.document.id).globalBounds();
			ui.pointerDown(bounds.x + 20, bounds.y + 20, 0);
			ui.pointerMove(bounds.x + 20, bounds.y + bounds.height + 40);
		}
		if (frames == 9) {
			var bounds = editorViewport(view.document.id).globalBounds();
			ui.pointerUp(bounds.x + 20, bounds.y + bounds.height + 40, 0);
			require(controller.offsetY > 0 && view.selection.hasSelection(), "selection drag did not autoscroll");
			controller.jumpTo(0, 0);
			var map = node("editor-minimap:" + view.document.id).globalBounds();
			ui.pointerDown(map.x + 20, map.y + map.height * 0.7, 0);
			ui.pointerUp(map.x + 20, map.y + map.height * 0.7, 0);
			require(controller.offsetY > 0, "minimap did not scroll source");
			selectionStoppedOffset = controller.offsetY;
		}
		if (frames == 10) require(Math.abs(controller.offsetY - selectionStoppedOffset) < 0.01, "rebuild reset minimap scroll");
		if (frames == 11) {
			ui.focusWidget(node("editor:" + view.document.id).id);
			ui.key(UiEventKind.KeyDown, UiKey.Home, UiModifier.Control);
			ui.key(UiEventKind.KeyDown, UiKey.End);
		}
		if (frames == 12) {
			require(controller.offsetX > 0, "long-line caret did not reveal horizontally");
			pointerX = node("gutter:" + view.document.id).globalBounds().x;
			ui.key(UiEventKind.KeyDown, UiKey.Z, UiModifier.Alt);
		}
		if (frames == 14) {
			require(application.settings.current.wordWrap && controller.offsetX == 0 && controller.maxScrollX == 0, "Alt+Z did not enable wrap and clear horizontal range");
			require(node("gutter:" + view.document.id).globalBounds().x == pointerX, "gutter moved with horizontal scroll");
			ui.key(UiEventKind.KeyDown, UiKey.End, UiModifier.Control);
		}
		if (frames == 16) {
			require(controller.offsetY > 0, "wrapped caret did not scroll vertically");
			ui.key(UiEventKind.KeyDown, UiKey.Z, UiModifier.Alt);
		}
		if (frames == 18) {
			require(!application.settings.current.wordWrap && controller.maxScrollY > 0 && controller.maxScrollX > 0, "unwrap lost scroll ranges");
			var before = view.selection.snapshot();
			application.settings.reload(true);
			require(!application.settings.current.wordWrap, "wrap preference was not persisted");
			require(view.selection.cursor.equals(before.ranges[0].cursor), "wrap changed cursor");
			controller.jumpTo(0, 0);
			var bounds = editorViewport(view.document.id).globalBounds();
			ui.scroll(bounds.x + 20, bounds.y + 100, 0, 100);
		}
		var result = super.submit(frame);
		if (frames == 20) {
			require(controller.offsetY > 0, "mouse wheel did not scroll source");
			var caret = host.textInputArea(), bounds = editorViewport(view.document.id).globalBounds();
			require(bounds.height < controller.contentHeight, "viewport grew to full source height");
			trace("PASS: keyboard, selection drag, minimap, horizontal caret, fixed gutter, wrap persistence and mouse wheel");
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
			var mapping = new editor.MinimapGeometry(bounds.height, view.scrollController.contentHeight,
				view.scrollController.viewportHeight, scale);
			var expected = mapping.scrollAt(y - mapping.thumbHeight / 2);
			require(Math.abs(view.scrollController.offsetY - expected) < 0.01, "minimap click did not use wrapped content metrics");
		}
		if (frames == 4) {
			view.scrollController.jumpTo(0, 0);
			var bounds = node("editor-minimap:" + view.document.id).globalBounds();
			ui.pointerDown(bounds.x + 30, bounds.y + 2, 0);
			ui.pointerMove(bounds.x + 30, bounds.y + 150);
			ui.pointerUp(bounds.x + 30, bounds.y + 150, 0);
			var mapping = new editor.MinimapGeometry(bounds.height, view.scrollController.contentHeight,
				view.scrollController.viewportHeight, 2.0 / (application.settings.current.fontSize * 1.4));
			require(Math.abs(mapping.thumbTop(view.scrollController.offsetY) - 148) < 0.01,
				"minimap thumb drifted away from grabbed pointer position");
			ui.pointerDown(bounds.x + 30, bounds.y + 150, 0);
			ui.pointerMove(bounds.x + 30, bounds.y + 60);
			ui.pointerUp(bounds.x + 30, bounds.y + 60, 0);
			require(Math.abs(mapping.thumbTop(view.scrollController.offsetY) - 58) < 0.01,
				"minimap reverse drag or re-grab lost pointer position");
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
	static function findLabel(root:haxeon.ui.core.RenderNode, label:String):Null<haxeon.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.label == label) return root;
		for (child in root.children) { var found = findLabel(child, label); if (found != null) return found; }
		return null;
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
		var longMessage = "Workspace issue\n" + StringTools.rpad("Unicode diagnostic: Olá 世界 😀 ", "long diagnostic text ", 2000);
		var workspace = feedback.Problem.scoped("test", "workspace", feedback.ProblemScope.Workspace, longMessage, 1, "Test",
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
		if (frames == 3) {
			var problemRow = node("problem:" + workspace.key()), summaryFound = false;
			problemRow.walk(function(child) {
				var text = child.layout.text;
				if (text != null && StringTools.startsWith(text, "Workspace issue")) {
					summaryFound = true;
					require(text.indexOf("\n") < 0 && text.length < longMessage.length && StringTools.endsWith(text, "…"),
						"long multiline diagnostic did not fit into a single-line summary");
				}
			});
			require(summaryFound && problemRow.globalBounds().height <= 28.1, "long diagnostic overflowed its Problems row");
		}
		if (frames == 4) {
			require(diagnosticActions == 1 && host.activeView() == null, "workspace action/navigation failed: " + diagnosticActions);
			require(hasText(node("problems-scroll"), longMessage), "selected diagnostic lost its full multiline message");
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

	var deletedDocument:editor.Document;
	var deletedPane:String;
	var modeDocument:editor.Document;
	var modeEditorDock:String;
	function modeStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var widthFile = config.ConfigurationPaths.stateRoot() + "/mode-right-width.txt";
		if (frames == 2) {
			layoutModes.suspend();
			registerSidebarDestination("workbench", haxeon.ui.icons.IconName.Terminal, function() return new haxeon.ui.widgets.text.Text("Workbench fixture"),
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Workbench", 20, true));
			layoutModes.resume(); layoutModes.refreshContext();
		}
		if (phase == "mode-write") {
			if (frames == 2) {
				var active = host.activeView(); if (active == null) throw "mode test missing document";
				modeDocument = active.document; modeDocument.insert(new editor.BufferSelection(), "// dirty\n");
				require(layoutModes.current.id == "editor" && !layoutControls.bottomOpen() && !layoutControls.rightOpen(), "fresh Editor defaults incorrect");
				modeEditorDock = dock.snapshotJson();
			}
			if (frames == 3 || frames == 7) ui.commands.execute("view.mode-agents");
			if (frames == 4) {
				require(layoutModes.current.id == "agents" && layoutControls.rightOpen() && !layoutControls.bottomOpen() && sidebar.activeId == "workbench" && sidebar.modes[0].id == "workbench", "Agents preset not rendered");
				click("layout-menu");
			}
			if (frames == 5) {
				require(hasText(ui.root, "Editor Layout") && hasText(ui.root, "✓ Agents Layout"), "Layout menu omitted mode choices/current marker");
				ui.key(UiEventKind.KeyDown, UiKey.Escape); ui.commands.execute("view.mode-editor");
			}
			if (frames == 6) require(dock.snapshotJson() == modeEditorDock && sidebar.activeId == "files" && sidebar.modes[0].id == "files", "mode round trip changed untouched layout");
			if (frames == 8) {
				var bounds = node("context-panel-content").globalBounds();
				closeWidth = bounds.width;
				ui.pointerDown(bounds.x - 4, bounds.y + 80, 0); ui.pointerMove(bounds.x - 44, bounds.y + 80); ui.pointerUp(bounds.x - 44, bounds.y + 80, 0);
			}
			if (frames == 9) {
				require(layoutModes.rightChanged && node("context-panel-content").globalBounds().width > closeWidth + 20, "real right resize did not set manual flag");
				closeWidth = node("context-panel-content").globalBounds().width;
				ui.commands.execute("view.mode-editor");
			}
			if (frames == 10) {
				require(layoutControls.rightOpen() && Math.abs(node("context-panel-content").globalBounds().width - closeWidth) < 2, "Editor changed custom right region");
				ui.commands.execute("view.layout-bottom"); ui.commands.execute("view.mode-agents");
			}
			if (frames == 11) {
				require(layoutModes.bottomChanged && layoutControls.bottomOpen(), "Agents hid custom bottom region");
				sys.io.File.saveContent(widthFile, Std.string(closeWidth));
				application.activeContext.focusGroup("mode-b", "Mode B", haxe.io.Path.directory(path));
				require(!layoutModes.rightChanged && !layoutModes.bottomChanged && !layoutControls.bottomOpen() && layoutControls.rightOpen(), "new context inherited A's custom flags");
			}
			if (frames == 12) ui.commands.execute("view.mode-editor");
			if (frames == 13) application.activeContext.useWorkspace();
			if (frames == 14) {
				require(layoutModes.current.id == "editor" && layoutModes.rightChanged && layoutModes.bottomChanged && layoutControls.rightOpen() && layoutControls.bottomOpen(), "return to A lost manual flags or followed old mode");
				var active = host.activeView(); require(active != null && active.document == modeDocument && modeDocument.dirty, "mode/context switch changed dirty document ownership");
				ui.commands.execute("view.mode-agents");
				trace("PASS: mode commands/menu, reversible presets, actual divider resize, custom panel visibility and context isolation");
			}
		} else if (phase == "mode-read") {
			if (frames == 3) {
				require(layoutModes.choice == "agents" && layoutModes.current.id == "agents" && layoutModes.rightChanged && layoutModes.bottomChanged && layoutControls.rightOpen() && layoutControls.bottomOpen(), "restart lost window mode or context flags");
				var expected = Std.parseFloat(sys.io.File.getContent(widthFile));
				require(Math.abs(node("context-panel-content").globalBounds().width - expected) < 2, "restart lost custom right width");
				application.settings.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("editor"));
			}
			if (frames == 4) {
				require(layoutModes.current.id == "editor" && layoutControls.rightOpen() && layoutControls.bottomOpen(), "setting changed manual regions or did not apply");
				application.settings.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("agents"));
			}
			if (frames == 5) require(layoutModes.current.id == "agents" && sidebar.find("files") != null && sidebar.find("workbench") != null, "mode setting hid a sidebar destination");
			if (frames >= 6 && frames <= 8) frame.setViewport(480, 720);
			if (frames == 7) application.settings.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("editor"));
			if (frames == 10) {
				require(dock.isOpen("context-panel") && layoutModes.rightChanged && layoutModes.bottomChanged, "phone round trip lost custom regions");
				trace("PASS: window mode/region restart, live preference, destination reachability and phone transition");
			}
		}
		if (phase == "mode-phone-default") {
			if (frames >= 3 && frames <= 5) frame.setViewport(480, 720);
			if (frames == 4) application.settings.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("agents"));
			if (frames == 7) {
				require(layoutModes.current.id == "agents" && layoutControls.rightOpen() && !layoutControls.bottomOpen() && !layoutModes.rightChanged && !layoutModes.bottomChanged,
					"phone preference did not update untouched desktop preset");
				application.settings.store.set("appearance/workbench/layout_mode", haxeon.ui.properties.PropertyValue.Enum("editor"));
			}
			if (frames == 8) {
				require(!layoutControls.rightOpen() && !layoutModes.rightChanged, "phone transition marked an untouched region as manual");
				trace("PASS: mode change on phone updates desktop preset without leaking regions or customization flags");
			}
		}
		var result = super.submit(frame);
		if ((phase == "mode-read" && frames >= 6 && frames <= 8) || (phase == "mode-phone-default" && frames >= 3 && frames <= 5)) require(!dock.isOpen("context-panel") && find(ui.root, "layout-menu") == null, "mode preference leaked desktop regions/controls onto phone");
		return result;
	}

	var contextAView:UiDocumentView;
	var contextBView:UiDocumentView;
	var contextADock:String;
	var contextBDock:String;
	function contextLayoutStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var groupRoot = haxe.io.Path.directory(path) + "-context-b";
		var expected = config.ConfigurationPaths.stateRoot() + "/context-layout-a.txt";
		if (phase == "context-layout-write") {
			if (frames == 2) {
				var text = ""; for (i in 0...150) text += "workspace line " + i + "\n";
				contextAView = host.activeView(); require(contextAView != null, "context A has no document");
				contextAView.document.buffer.replaceAllText(text, contextAView.selection);
				require(host.splitActive(view.LayoutKind.Horizontal), "context A split failed");
				contextAView = host.activeView();
				newTerminal();
				layoutControls.toggleRight(); layoutControls.toggleBottom();
			}
			if (frames == 4) {
				contextAView.restoreCursor(30, 4); contextAView.restoreScroll(0, 320);
				host.activateTab(contextAView.document, host.activePane.id);
				require(application.savedWorkspaces.saveAs(config.ConfigurationPaths.stateRoot() + "/A.exosuit-workspace") && host.activeView() == contextAView, "first workspace save replaced visible tabs");
				contextADock = dock.snapshotJson();
				sys.io.File.saveContent(expected, contextADock);
			}
			if (frames == 5) {
				sys.FileSystem.createDirectory(groupRoot);
				sys.io.File.saveContent(groupRoot + "/B.txt", "group line\n");
				application.activeContext.focusGroup("context-layout-b", "Group B", groupRoot);
				require(host.panes.length == 1 && host.activePane.items.length == 0, "new context inherited A's tabs");
				require(!dock.isOpen("context-panel") && !layoutControls.bottomOpen(), "new context inherited A's panels");
				application.open(groupRoot + "/B.txt"); contextBView = host.activeView();
				var text = ""; for (i in 0...150) text += "group B dirty line " + i + "\n";
				contextBView.document.buffer.replaceAllText(text, contextBView.selection);
				// Closing a shared dirty tab in B must retain A's document and view.
				application.open(path);
				var shared = host.activeView();
				require(shared != null && shared.document == contextAView.document && host.closeActiveTab(), "shared dirty tab could not close independently");
				require(application.documents.documents.indexOf(contextAView.document) >= 0, "B closed A's document");
				newTerminal(); host.activateTab(contextBView.document, host.activePane.id);
				require(WorkspaceSmokeMain.terminalStarts == 2 && host.allTerminalTabs().length == 2, "context switch terminated or duplicated a shell");
			}
			if (frames == 7) { contextBView.restoreCursor(42, 6); contextBView.restoreScroll(0, 480); contextBDock = dock.snapshotJson(); }
			if (frames == 8) application.activeContext.useWorkspace();
			if (frames == 10) {
				require(host.activeView() == contextAView && host.panes.length == 2, "switch lost A's live views or split");
				require(contextAView.document.dirty && contextAView.cursorLine() == 30 && contextAView.cursorColumn() == 4 && contextAView.scrollY() == 320, "switch lost A's dirty text, caret or scroll: " + contextAView.document.dirty + ":" + contextAView.cursorLine() + ":" + contextAView.cursorColumn() + ":" + contextAView.scrollY());
				require(dock.snapshotJson() == contextADock, "switch lost A's panel visibility or layout");
				application.activeContext.focusGroup("context-layout-b", "Group B", groupRoot);
			}
			if (frames == 12) {
				require(host.activeView() == contextBView && contextBView.document.dirty && contextBView.cursorLine() == 42 && contextBView.scrollY() == 480, "switch lost B's independent view");
				require(dock.snapshotJson() == contextBDock, "switch lost B's dock");
				require(WorkspaceSmokeMain.terminalStarts == 2 && host.panelTerminals.length == 1, "returning to B recreated its shell");
				trace("PASS: context A/B independent tabs, splits, panel layouts, dirty shared ownership, carets and scroll");
			}
		} else if (phase == "context-layout-read") {
			if (frames == 3) {
				require(application.activeContext.id == "context-layout-b" && application.activeContext.cwd == groupRoot, "restart lost focused group context");
				contextBView = host.activeView();
				require(contextBView != null && contextBView.document.dirty && contextBView.document.buffer.text.indexOf("group B dirty") == 0 && contextBView.cursorLine() == 42 && contextBView.scrollY() == 480, "restart lost B's dirty tab/caret/scroll");
				require(application.documents.documents.length == 2, "inactive dirty documents were not hydrated");
				require(WorkspaceSmokeMain.terminalStarts == 1 && host.terminalNumberInUse(1) && host.terminalNumberInUse(2), "inactive terminal identity was not reserved");
				application.activeContext.useWorkspace();
			}
			if (frames == 5) {
				contextAView = host.activeView();
				require(host.panes.length == 2 && contextAView != null && contextAView.document.dirty && contextAView.document.buffer.text.indexOf("workspace line") == 0,
					"restart lost inactive A's split or dirty document");
				require(contextAView.cursorLine() == 30 && contextAView.cursorColumn() == 4 && contextAView.scrollY() == 320, "restart lost A's caret/scroll");
				require(dock.snapshotJson() == sys.io.File.getContent(expected), "restart lost A's dock sizes/visibility");
				require(WorkspaceSmokeMain.terminalStarts == 2 && host.panelTerminals.length == 1, "inactive A terminal was not restored exactly once");
				application.activeContext.focusGroup("context-layout-b", "Group B", groupRoot);
			}
			if (frames == 7) {
				require(host.activeView() == contextBView, "restored B view did not survive return");
				application.activeContext.focusGroup("missing-layout", "Fresh context", groupRoot);
				require(host.activePane.items.length == 0 && host.panes.length == 1, "missing snapshot did not use defaults");
				application.activeContext.focusGroup("context-layout-b", "Group B", groupRoot);
				trace("PASS: process restart restores active group plus inactive dirty context, caret/scroll, dock, and missing-context defaults");
			}
		} else if (phase == "context-layout-save-inactive" && frames == 3) {
			var inactive:Null<editor.Document> = null;
			for (document in application.documents.documents) if (document.path == path) inactive = document;
			require(inactive != null && inactive.dirty, "inactive dirty document was not available to Save All");
			if (inactive == null) throw "missing inactive document";
			require(application.documents.saveAs(inactive, config.ConfigurationPaths.stateRoot() + "/saved-inactive.txt"), "inactive Save As failed");
			trace("PASS: inactive document can be saved/renamed before its context is visited");
		} else if (phase == "context-layout-read-inactive-save" && frames == 3) {
			application.activeContext.useWorkspace();
		} else if (phase == "context-layout-read-inactive-save" && frames == 5) {
			var active = host.activeView();
			require(active != null && active.document.path == config.ConfigurationPaths.stateRoot() + "/saved-inactive.txt" && !active.document.dirty
				&& active.document.buffer.text.indexOf("workspace line") == 0 && active.cursorLine() == 30 && active.scrollY() == 320,
				"inactive snapshot kept a stale recovery/path reference after Save As");
			trace("PASS: saved inactive tab survives another process with current path and view state");
		} else if (phase == "context-layout-corrupt" && frames == 3) {
			var active = host.activeView();
			require(active != null && active.document.dirty, "corrupt inactive snapshot damaged the active context");
			application.activeContext.useWorkspace();
			require(host.panes.length == 1 && host.activePane.items.length == 0, "corrupt inactive snapshot did not use defaults");
			trace("PASS: corrupt context snapshot falls back independently without losing the active dirty tab");
		}
		return super.submit(frame);
	}

	function bottomPanelControlsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var result = super.submit(frame);
		if (frames == 2) openTerminal();
		if (frames == 4) {
			panelControlsLayout = dock.snapshotJson();
			panelControlsHeight = node("bottom-panel-hide").globalBounds().y;
			panelControlsTerminal = host.allTerminalTabs()[0].panel;
			click("bottom-panel-maximize");
		}
		if (frames == 5) {
			var semantics = node("bottom-panel-maximize").semantics;
			require(layoutControls.bottomMaximized && semantics != null && semantics.label == "Restore Panel", "maximize action missing");
			require(node("bottom-panel-hide").globalBounds().y < panelControlsHeight - 100, "panel did not expand vertically");
			require(dock.snapshotJson() == panelControlsLayout, "maximization rewrote saved layout");
			click("bottom-panel-maximize");
		}
		if (frames == 6) {
			require(Math.abs(node("bottom-panel-hide").globalBounds().y - panelControlsHeight) < 1, "restore changed panel height");
			click("bottom-panel-hide");
		}
		if (frames == 7) {
			require(!layoutControls.bottomOpen() && !layoutControls.bottomMaximized, "hide did not close the region");
			require(host.allTerminalTabs().length == 1 && host.allTerminalTabs()[0].panel == panelControlsTerminal, "hide terminated the shell");
			layoutControls.toggleBottom();
		}
		if (frames == 8) {
			require(find(ui.root, "bottom-panel-hide") != null && host.allTerminalTabs()[0].panel == panelControlsTerminal, "reopen replaced terminal");
			dock.activate("problems");
		}
		if (frames == 9) {
			require(find(ui.root, "bottom-panel-hide") != null, "Problems lacks shared controls");
			dock.activate("build");
		}
		if (frames == 10) {
			require(find(ui.root, "bottom-panel-hide") != null, "Build Output lacks shared controls");
			click("bottom-panel-maximize");
		}
		if (frames == 11) click("bottom-panel-hide");
		if (frames == 12) {
			require(!layoutControls.bottomMaximized && host.allTerminalTabs()[0].panel == panelControlsTerminal, "hiding maximized panel lost state");
			layoutControls.toggleBottom(); dock.activate("terminal");
		}
		if (frames == 13) {
			require(Math.abs(node("bottom-panel-hide").globalBounds().y - panelControlsHeight) < 1, "reopen retained maximized height");
			dock.close("problems"); dock.close("build");
		}
		if (frames == 14) {
			require(find(ui.root, "bottom-panel-hide") != null, "single-panel header lost controls");
			click("bottom-panel-maximize");
		}
		if (frames == 15) {
			require(layoutControls.bottomMaximized, "single panel did not maximize");
			click("bottom-panel-maximize");
			trace("PASS: shared and single-panel controls maximize, restore and hide without replacing terminal sessions or saved layout");
		}
		return result;
	}

	function responsiveLayoutStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var widths = [1200.0,1200,713,700,640,660,660,680,700,1200,1200,713,1200];
		frame.setViewport(widths[Std.int(Math.min(frames-1,widths.length-1))],720);
		if (frames == 1) {
			openTerminal(); moveTerminalToEditor();
			responsiveTerminal = UiEditorTabs.terminal(host.activeTab());
			require(responsiveTerminal != null,"Responsive fixture did not open a terminal");
			showSidebarMode("files");
			sidebar.rememberWidth(260);
			dock.setRoot(haxeon.ui.docking.DockNode.Split(haxeon.ui.docking.DockSplitAxis.Horizontal,260.0/1144,
				haxeon.ui.docking.DockNode.Panel("explorer"),
				haxeon.ui.docking.DockNode.Split(haxeon.ui.docking.DockSplitAxis.Horizontal,0.72,
					haxeon.ui.docking.DockNode.Panel(host.activePane.id),haxeon.ui.docking.DockNode.Panel("context-panel"))));
			dock.activate(host.activePane.id);
		}
		if (frames == 6) activateSidebarDestination("files");
		if (frames == 7) showTerminalInEditor(responsiveTerminal);
		var result = super.submit(frame);
		if (frames == 2) {
			responsiveSidebarWidth = node("sidebar-modes").globalBounds().width;
			responsiveRightWidth = node("context-panel-content").globalBounds().width;
		}
		if (frames == 3 || frames == 4 || frames == 9 || frames == 12) {
			require(!phoneLayoutActive && responsiveRightHidden,"Intermediate width did not collapse the secondary region: frame="+frames+", width="+frame.width+", sidebar="+sidebar.width+", phone="+phoneLayoutActive+", hidden="+responsiveRightHidden+", dock="+dock.snapshotJson());
			require(dock.isOpen("context-panel") && find(ui.root,"context-panel-content")==null,"Responsive collapse changed the saved region or kept rendering it");
			require(node("terminal-pane").globalBounds().width >= 320,"Responsive layout squeezed the terminal below its usable width");
			require(Math.abs(node("sidebar-modes").globalBounds().width-responsiveSidebarWidth)<2,"Workbench width followed content or window resizing");
			var saved=haxeon.ui.docking.DockWorkspaceSnapshotCodec.decode(captureDockLayout());
			if (saved == null) throw "Responsive layout snapshot did not decode";
			require(haxeon.ui.docking.DockNodeTools.contains(saved.root,"context-panel"),"Responsive collapse leaked into persisted layout");
		}
		if (frames == 5 || frames == 7 || frames == 8) {
			require(phoneLayoutActive && !sidebar.visible,"Narrow layout replaced the active terminal with navigation");
			require(find(ui.root,"terminal-pane")!=null,"Narrow layout lost the active terminal");
			require(UiEditorTabs.terminal(host.activeTab())==responsiveTerminal,"Responsive layout recreated the terminal session");
			var saved=haxeon.ui.docking.DockWorkspaceSnapshotCodec.decode(captureDockLayout());
			if (saved == null) throw "Responsive layout snapshot did not decode";
			require(haxeon.ui.docking.DockNodeTools.contains(saved.root,"explorer") && haxeon.ui.docking.DockNodeTools.contains(saved.root,"context-panel"),"Narrow layout lost desktop region preferences");
			var capture:Void->String = cast host.captureSidebar;
			var savedSidebar=capture().split("|");
			require(savedSidebar[2]=="1" && Math.abs(Std.parseFloat(savedSidebar[3])-responsiveSidebarWidth)<2,"Narrow navigation state overwrote saved sidebar visibility/width");
		}
		if (frames == 6) require(phoneLayoutActive && sidebar.visible && find(ui.root,"sidebar-modes")!=null,"Collapsed navigation was unreachable from the activity button");
		if (frames == 10 || frames == 11 || frames == 13) {
			require(!phoneLayoutActive && !responsiveRightHidden && sidebar.visible,"Growing the window did not restore preferred regions");
			require(Math.abs(node("context-panel-content").globalBounds().width-responsiveRightWidth)<2,"Growing the window lost the right region width");
			require(Math.abs(node("sidebar-modes").globalBounds().width-responsiveSidebarWidth)<2,"Growing the window lost the sidebar width");
		}
		if (frames == 13) trace("PASS: responsive right-first collapse, active terminal, navigation drawer, hysteresis, restored widths and saved layout");
		return result;
	}

	function layoutControlsStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var expectedFile = config.ConfigurationPaths.stateRoot() + "/layout-controls-width.txt";
		if (phase == "layout-phone") frame.setViewport(480, 720);
		if (phase == "layout-read" && frames >= 10 && frames <= 12) frame.setViewport(480, 720);
		if (phase == "layout-write") {
			if (frames == 2) {
				require(find(ui.root, "layout-left") != null && find(ui.root, "layout-bottom") != null && find(ui.root, "layout-right") != null && find(ui.root, "layout-menu") != null,
					"desktop title bar omitted a layout control");
				require(find(ui.root, "toolbar-Terminal") == null, "standalone Terminal toolbar button remained");
				click("layout-right");
			}
			if (frames == 3) {
				require(dock.isOpen("context-panel") && find(ui.root, "context-panel-content") != null, "right panel was not a real rendered dock region");
				var bounds = node("context-panel-content").globalBounds();
				closeWidth = bounds.width;
				ui.pointerDown(bounds.x - 4, bounds.y + 80, 0); ui.pointerMove(bounds.x - 44, bounds.y + 80); ui.pointerUp(bounds.x - 44, bounds.y + 80, 0);
			}
			if (frames == 4) {
				require(node("context-panel-content").globalBounds().width > closeWidth + 20, "right region divider did not resize");
				click("layout-left");
			}
			if (frames == 5) { require(!dock.isOpen("explorer"), "left toggle did not hide sidebar"); click("layout-left"); }
			if (frames == 6) { require(dock.isOpen("explorer"), "left toggle did not restore sidebar"); ui.key(UiEventKind.KeyDown, UiKey.J, UiModifier.Control | UiModifier.Alt); }
			if (frames == 7) { require(!layoutControls.bottomOpen() && dock.isOpen("context-panel"), "bottom toggle lost right region or retained tools"); click("layout-bottom"); }
			if (frames == 8) { require(layoutControls.bottomOpen(), "bottom toggle did not restore tools"); click("layout-menu"); }
			if (frames == 9) { require(hasText(ui.root, "Hide Right Panel"), "Layout menu did not show region actions"); ui.key(UiEventKind.KeyDown, UiKey.Escape); }
			if (frames == 10) click("layout-bottom");
			if (frames == 11) {
				require(dock.isOpen("context-panel") && !layoutControls.bottomOpen(), "written layout visibility was incorrect");
				sys.io.File.saveContent(expectedFile, Std.string(node("context-panel-content").globalBounds().width));
				trace("PASS: title-bar layout controls, right-region resize, region toggles, keyboard and Layout menu");
			}
		} else if (phase == "layout-read") {
			if (frames == 3 || frames == 6) {
				require(dock.isOpen("context-panel") && !layoutControls.bottomOpen(), "restart did not preserve right/bottom visibility");
				var expected = Std.parseFloat(sys.io.File.getContent(expectedFile));
				require(Math.abs(node("context-panel-content").globalBounds().width - expected) < 2,
					"right region did not retain resized width");
			}
			if (frames == 4 || frames == 5) ui.key(UiEventKind.KeyDown, UiKey.B, UiModifier.Control | UiModifier.Alt);
			if (frames == 7 || frames == 8) click("layout-bottom");
		}
		var result = super.submit(frame);
		if (phase == "layout-phone" || (phase == "layout-read" && frames >= 10 && frames <= 12)) {
			require(find(ui.root, "layout-right") == null && find(ui.root, "layout-left") == null && find(ui.root, "layout-bottom") == null && find(ui.root, "layout-menu") == null,
				"desktop layout controls leaked into phone toolbar");
			require(!dock.isOpen("context-panel"), "right region leaked into phone's single-pane layout");
		}
		if (phase == "layout-read" && frames == 14) {
			require(dock.isOpen("context-panel"), "returning from phone lost the desktop right region");
			trace("PASS: layout visibility/size restart, right toggle, bottom restore and desktop/phone round trip");
		}
		return result;
	}

	function activeContextStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var root = haxe.io.Path.directory(path), group = root + "-group";
		if (frames == 2) {
			sys.FileSystem.createDirectory(group);
			sys.io.File.saveContent(group + "/inside.txt", "needle\n");
			host.getProblems().replaceOwner("context-test", [
				feedback.Problem.scoped("context-test", "inside", feedback.ProblemScope.File(group + "/inside.txt"), "inside context", 1, "test"),
				feedback.Problem.scoped("context-test", "outside", feedback.ProblemScope.File(path), "outside context", 1, "test")]);
			var output = new build.BuildOutput(); output.reset(root); output.append("outside build\n"); output.finish();
			host.showBuildOutput("Build Output", output);
			application.activeContext.openSessionGroup("test-group", [{id:"test-group", name:"Test Group", cwd:group, parent:null, revision:1, order:0}], root);
			host.showProblems(); requestFrame();
		}
		if (frames == 4) {
			require(hasText(ui.root, "Test Group") && find(ui.root, "context-back-to-workspace") != null, "group scope or return action was hidden");
			require(treeRow(ui.root, group) != null && treeRow(ui.root, root) == null, "Files did not follow ActiveContext");
			require(hasText(ui.root, "inside context") && !hasText(ui.root, "outside context"), "Problems escaped ActiveContext");
			var source = sourceControlSource();
			require(source != null && source.identity() == scm.LocalScmSource.identityFor([group]), "SCM did not use context roots");
			var current = host.currentBuildOutput; if (current == null) throw "missing build output";
			host.showBuildOutput("Build Output", current); requestFrame();
		}
		if (frames == 5) {
			require(!hasText(ui.root, "outside build"), "Build output escaped ActiveContext");
			newTerminal();
		}
		if (frames == 6) {
			require(host.panelTerminals.length == 1 && host.panelTerminals[0].cwd == group, "new terminal ignored context cwd");
			require(application.workspace.projects.length == 1 && application.workspace.projects[0].root == root, "group focus changed saved roots");
			click("context-back-to-workspace");
		}
		var result = super.submit(frame);
		if (frames == 8) {
			require(treeRow(ui.root, root) != null && application.activeContext.cwd == root, "workspace context failed to restore normal scope");
			trace("PASS: one context scopes Files, SCM, Problems, Build output and terminal cwd without changing saved roots");
		}
		return result;
	}

	function savedWorkspaceStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var directory = haxe.io.Path.directory(path), file = directory + "/Named.exosuit-workspace";
		if (frames == 2) {
			for (name in ["second", "third"]) {
				var root = directory + "/" + name;
				sys.FileSystem.createDirectory(root); application.savedWorkspaces.addFolder(root);
			}
			require(application.savedWorkspaces.saveAs(file), "UI workspace save failed");
			application.savedWorkspaces.restore(new workspace.SavedWorkspace("fixture", "Named", [directory, directory + "/second", directory + "/unavailable"]), file);
		}
		var result = super.submit(frame);
		if (frames == 4) {
			require(treeRow(ui.root, directory) != null && treeRow(ui.root, directory + "/second") != null &&
				treeRow(ui.root, directory + "/unavailable") != null, "Files did not show all workspace roots");
			require(hasText(ui.root, "unavailable"), "missing root was not identified");
			require(hasText(ui.root, "Named"), "saved workspace name was absent from title bar");
			application.savedWorkspaces.close();
		}
		if (frames == 6) {
			require(find(ui.root, "welcome-open-workspace") != null && find(ui.root, "welcome-workspace-recent-0") != null,
				"welcome did not expose Open Workspace and workspace recents");
			click("welcome-workspace-recent-0");
		}
		if (frames == 8) {
			require(application.workspace.projects.length == 3, "recent workspace did not restore its three roots");
			trace("PASS: named workspace title, multi-root Files, unavailable root, welcome actions and recent reopen");
		}
		return result;
	}

	static function dockDivider(root:haxeon.ui.core.RenderNode):Null<haxeon.ui.core.RenderNode> {
		if (root.semantics != null && root.semantics.role == haxeon.ui.semantics.AccessibilityRole.Separator
			&& root.children.length == 1 && root.children[0].layout.visualKind == LayoutVisualKind.Custom) return root;
		for (child in root.children) { var found = dockDivider(child); if (found != null) return found; }
		return null;
	}
	function dividerChromeStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		if (frames == 2) {
			var zoom = Sys.getEnv("EXOSUIT_DIVIDER_ZOOM");
			setApplicationZoom(zoom == null ? 100 : Std.parseInt(zoom));
			setDarkTheme(Sys.getEnv("EXOSUIT_DIVIDER_DARK") == "1");
			layoutControls.toggleBottom(); layoutControls.toggleRight();
			if (Sys.getEnv("EXOSUIT_DIVIDER_TERMINAL") == "1") { openTerminal(); moveTerminalToEditor(); }
		}
		if (frames == 4) {
			var checked = 0;
			ui.root.walk(function(node) {
				if (node.semantics == null || node.semantics.role != haxeon.ui.semantics.AccessibilityRole.Separator
					|| node.children.length != 1 || node.children[0].layout.visualKind != LayoutVisualKind.Custom) return;
				var anchor = node.parent;
				if (anchor == null || anchor.parent == null) throw "missing dock boundary anchor";
				var split = anchor.parent;
				var first = split.children[0].globalBounds(), second = split.children[2].globalBounds();
				var bounds = node.globalBounds();
				var horizontal = bounds.width == 8;
				var end = horizontal ? first.x + first.width : first.y + first.height;
				var start = horizontal ? second.x : second.y;
				var center = horizontal ? bounds.x + bounds.width / 2 : bounds.y + bounds.height / 2;
				require(Math.abs(end - start) < 0.01 && Math.abs(center - start) < 0.01,
					"dock panes have a gap or displaced resize target");
				checked++;
			});
			require(checked >= 3, "missing left, bottom or right dock boundary coverage");
			var divider = dockDivider(ui.root);
			if (divider == null) throw "missing dock divider";
			require(divider != null, "missing dock hairline");
			var bounds = divider.globalBounds();
			require(Math.abs(bounds.width - 8) < 0.01, "divider resize target changed");
			var anchor = divider.parent;
			if (anchor == null || anchor.parent == null) throw "divider lacks boundary anchor";
			var split = anchor.parent;
			var before = split.children[0].globalBounds(), after = split.children[2].globalBounds();
			require(Math.abs(before.x + before.width - after.x) < 0.01, "divider left a layout gutter");
			require(Math.abs(bounds.x + bounds.width / 2 - after.x) < 0.01, "resize target is not centered on pane edge");
			var visual = divider.children[0].globalBounds();
			require(visual.width == bounds.width && visual.height == bounds.height,
				"divider drawing child collapsed with an editor open");
			// Both halves of the target must beat floating terminal rows.
			for (offset in [1.0, 5.0, 7.0]) {
				var path = haxeon.ui.core.HitTest.path(ui.root, bounds.x + offset, bounds.y + bounds.height / 2);
				require(path.length > 0 && path[path.length - 1] == divider, "pane content covered divider hit target");
			}
			if (Sys.getEnv("EXOSUIT_DIVIDER_TERMINAL") == "1")
				require(host.allTerminalTabs().length == 1, "terminal coverage missing");
			ui.pointerMove(bounds.x + 5, bounds.y + bounds.height / 2);
		}
		if (frames == 5 || frames == 6) {
			var divider = dockDivider(ui.root);
			if (divider == null) throw "missing dock divider";
			var color:haxeon.ui.Color = divider.computedStyle.get(haxeon.ui.style.StyleProperty.Background);
			var expected = frames == 5 ? theme.tokens.accentHover : theme.tokens.accentPressed;
			require(color.red == expected.red && color.green == expected.green && color.blue == expected.blue,
				"divider highlight missing at frame " + frames + ": color=" + color.red + "," + color.green + "," + color.blue + " expected=" + expected.red + "," + expected.green + "," + expected.blue + " states=" + divider.states);
			var bounds = divider.globalBounds();
			if (frames == 5) ui.pointerDown(bounds.x + 5, bounds.y + bounds.height / 2, 0);
			else {
				ui.pointerMove(bounds.x + 24, bounds.y + bounds.height / 2);
				ui.pointerUp(bounds.x + 24, bounds.y + bounds.height / 2, 0);
				ui.pointerDown(frame.width - 40, 100, 0); ui.pointerUp(frame.width - 40, 100, 0);
				ui.pointerMove(frame.width - 40, 100);
			}
		}
		var result = super.submit(frame);
		if (frames == 8) {
			var divider = dockDivider(ui.root);
			if (divider == null) throw "missing dock divider";
			var color:haxeon.ui.Color = divider.computedStyle.get(haxeon.ui.style.StyleProperty.Background);
			require(color.red == theme.tokens.textPrimary.red && color.green == theme.tokens.textPrimary.green && color.blue == theme.tokens.textPrimary.blue && color.alpha == 0.14,
				"divider did not return to neutral border");
			trace("PASS: hairline dock separator keeps resize target, hover, drag, and neutral resting color");
		}
		return result;
	}

	var renameStage:Int = 0;
	function explorerRenameStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var destination = haxe.io.Path.directory(path) + "/Renamed.hx";
		if (renameStage == 0 && ui.root != null && treeRow(ui.root, path) != null) {
			clickTree(path); renameStage++;
		} else if (renameStage == 1) {
			ui.key(UiEventKind.KeyDown, UiKey.F2); renameStage++;
		} else if (renameStage == 2) {
			require(!host.isCommandViewActive(), "inline rename opened command picker");
			ui.text(UiEventKind.TextInput, "Renamed");
			ui.key(UiEventKind.KeyDown, UiKey.Enter); renameStage++;
		} else if (renameStage == 3) {
			require(!sys.FileSystem.exists(path) && sys.FileSystem.exists(destination), "inline rename did not preserve extension and rename file");
			var active = host.activeView();
			require(active != null && active.document.path == destination, "rename lost open document path");
			renameStage++;
		} else if (renameStage == 4 && treeRow(ui.root, destination) != null) {
			clickTree(destination); application.files.openRenameFile(); renameStage++;
		} else if (renameStage == 5) {
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.text(UiEventKind.TextInput, "cancelled.hx");
			ui.key(UiEventKind.KeyDown, UiKey.Escape); renameStage++;
		} else if (renameStage == 6) {
			require(sys.FileSystem.exists(destination) && !sys.FileSystem.exists(haxe.io.Path.directory(path) + "/cancelled.hx"), "Escape renamed the file");
			sys.io.File.saveContent(haxe.io.Path.directory(path) + "/Taken.hx", "keep me");
			clickTree(destination); application.files.openRenameFile(); renameStage++;
		} else if (renameStage == 7) {
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.text(UiEventKind.TextInput, "../invalid.hx");
			ui.key(UiEventKind.KeyDown, UiKey.Enter); renameStage++;
		} else if (renameStage == 8) {
			require(sys.FileSystem.exists(destination), "invalid name moved the source");
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.text(UiEventKind.TextInput, "Taken.hx");
			ui.key(UiEventKind.KeyDown, UiKey.Enter); renameStage++;
		} else if (renameStage == 9) {
			require(sys.FileSystem.exists(destination) && sys.io.File.getContent(haxe.io.Path.directory(path) + "/Taken.hx") == "keep me", "name collision overwrote an existing file");
			ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
			ui.text(UiEventKind.TextInput, "Final.hx");
			ui.key(UiEventKind.KeyDown, UiKey.Enter); renameStage++;
		} else if (renameStage == 10) {
			require(!sys.FileSystem.exists(destination) && sys.FileSystem.exists(haxe.io.Path.directory(path) + "/Final.hx"), "rename field did not allow correction after validation failures");
			renameStage++;
		} else if (renameStage == 11) {
			var folder = haxe.io.Path.directory(path) + "/folder.old";
			application.open(folder + "/Child.hx");
			clickTree(folder); application.files.openRenameFile(); renameStage++;
		} else if (renameStage == 12) {
			ui.text(UiEventKind.TextInput, "RenamedFolder");
			ui.key(UiEventKind.KeyDown, UiKey.Enter); renameStage++;
		} else if (renameStage == 13) {
			var child = haxe.io.Path.directory(path) + "/RenamedFolder/Child.hx";
			require(sys.FileSystem.exists(child), "folder rename did not select the whole dotted name or preserve contents");
			var active = host.activeView();
			require(active != null && active.document.path == child, "folder rename lost child document path");
			renameStage++;
			trace("PASS: inline file and folder rename, extension selection, open-document paths, Escape, invalid names and collision correction");
		}
		if (frames == 39) require(renameStage == 14, "inline rename scenario did not complete: " + renameStage);
		return super.submit(frame);
	}

	function fileDeletionStep(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		var cleanPath = path + ".delete-clean.hx", dirtyPath = path + ".delete-dirty.hx";
		if (frames == 2) {
			sys.io.File.saveContent(cleanPath, "");
			application.open(cleanPath);
			var active = host.activeView();
			if (active == null) throw "deletion fixture did not open an editor";
			deletedDocument = active.document;
			host.splitActive(view.LayoutKind.Horizontal);
			deletedPane = host.activePane.id;
		}
		if (frames == 3 || frames == 5) {
			application.files.openDeleteFile();
		}
		if (frames == 4) {
			click("trash-confirmation-move");
			require(!sys.FileSystem.exists(cleanPath) && !deletedDocument.dirty
				&& host.allViews().length == 0 && !application.documents.documents.contains(deletedDocument)
				&& host.activePane.id == deletedPane && !host.isCommandViewActive(),
				"clean Explorer deletion retained tabs, changed pane, or opened a save prompt");
			sys.io.File.saveContent(dirtyPath, "class Dirty {}\n");
			application.open(dirtyPath);
			var active = host.activeView();
			if (active == null) throw "deletion fixture did not open an editor";
			deletedDocument = active.document;
			deletedDocument.insert(new editor.BufferSelection(), "// unsaved\n");
		}
		if (frames == 6) {
			click("trash-confirmation-move");
			require(!sys.FileSystem.exists(dirtyPath) && deletedDocument.dirty && deletedDocument.path == null
				&& host.allViews().length == 1 && host.activeView() != null,
				"dirty Explorer deletion lost its editor");
			application.files.requestCloseActiveTab();
		}
		if (frames == 7) click("save-confirmation-cancel");
		if (frames == 8) {
			require(host.allViews().length == 1, "Cancel lost deleted edits");
			application.files.requestCloseActiveTab();
		}
		if (frames == 9) click("save-confirmation-discard");
		var result = super.submit(frame);
		if (frames == 10) {
			require(host.allViews().length == 0 && !application.documents.documents.contains(deletedDocument),
				"Discard retained deleted editor");
			trace("PASS: clean deletion closes split editors, dirty deletion retains edits and confirms Cancel/Discard");
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
			if (frames == 4) { require(sidebar.activeId == "search", "search shortcut did not select mode"); click("activity:files"); }
			if (frames == 5) {
				require(sidebar.activeId == "files", "Files activity click did not select mode");
				sidebarWidth = node("sidebar-modes").globalBounds().width;
				var tree = findTree(ui.root);
				require(tree != null, "Files tree missing");
				var bounds = tree.globalBounds();
				ui.scroll(bounds.x + 20, bounds.y + 40, 0, 180);
				resizeSidebar(30);
			}
			if (frames == 7) {
				require(filesScroll.offsetY > 0, "wheel did not reach Files tree: viewport=" +
					filesScroll.viewportHeight + ", content=" + filesScroll.contentHeight +
					", maximum=" + filesScroll.maxScrollY);
				var files = sidebar.find("files");
				require(files != null && sidebar.width > sidebarWidth + 20, "Files divider width was not retained");
				sidebarWidth = sidebar.width;
				click("activity:search");
			}
			if (frames == 8) {
				require(sidebar.activeId == "search", "Search activity click failed");
				require(Math.abs(node("sidebar-modes").globalBounds().width - sidebarWidth) < 1, "destination switch changed shared width: " + node("sidebar-modes").globalBounds().width);
				resizeSidebar(40);
			}
			if (frames == 10) {
				var search = sidebar.find("search");
				require(search != null && sidebar.width > sidebarWidth + 30, "Search divider width lost");
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-sidebar.txt", sidebar.encode());
				trace("PASS: sidebar commands, activity buttons and shared dragged width");
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
		} else if (languageFeatureStage == 2 && find(ui.root, "cv-row-1") == null && hasText(node("cv-row-0"), "value")) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter, 0); languageFeatureStage = 3;
		} else if (languageFeatureStage == 3 && !host.isCommandViewActive()) {
			require(ui.commands.execute("exosuit.language:find-references"), "graphical references command unavailable"); languageFeatureStage = 4;
		} else if (languageFeatureStage == 4 && host.isCommandViewActive() && hasText(node("cv-content"), "References")) {
			require(find(ui.root, "cv-row-1") != null && find(ui.root, "cv-row-2") == null, "graphical references omitted closed file");
			ui.text(UiEventKind.TextInput, "Other.hx"); languageFeatureStage = 5;
		} else if (languageFeatureStage == 5 && find(ui.root, "cv-row-1") == null && hasText(node("cv-row-0"), "Other.hx")) {
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
	public static var zoomWidth = 900;
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
		if (args[2] == "divider-chrome") { options.width = 1600; options.height = 900; }
		if (args[2] == "zoom") {
			var width = Sys.getEnv("EXOSUIT_ZOOM_TEST_WIDTH");
			var height = Sys.getEnv("EXOSUIT_ZOOM_TEST_HEIGHT");
			if (width != null) options.width = Std.parseInt(width);
			if (height != null) options.height = Std.parseInt(height);
			zoomWidth = options.width;
		}
		options.captureDirectory = args[1];
		options.frameLimit = args[2] == "layout-responsive" ? 13 : args[2] == "mode-write" ? 16 : args[2] == "mode-read" ? 12 : args[2] == "mode-phone-default" ? 10 : args[2] == "context-layout-write" ? 14 : args[2] == "context-layout-read" ? 9 : StringTools.startsWith(args[2], "context-layout-") ? 7 : args[2] == "layout-panel-controls" ? 17 : args[2] == "layout-read" ? 15 : args[2] == "layout-write" ? 13 : args[2] == "layout-phone" ? 6 : args[2] == "active-context" ? 10 : args[2] == "saved-workspace" ? 10 : args[2] == "divider-chrome" ? 10 : args[2] == "explorer-rename" ? 40 : args[2] == "editor-geometry" ? 25 : args[2] == "file-deletion" ? 10 : args[2] == "blank-editor-click" ? 11 : args[2] == "zoom" ? 75 : args[2] == "save-as" ? 10 : args[2] == "exit-confirmation" ? 11 : args[2] == "tab-close" ? 13 : args[2] == "selection" ? 10 : args[2] == "problems" ? 10 : args[2] == "settings" ? 11 : args[2] == "editor-tabs" ? 11 : args[2] == "explorer-icons" ? 14 : args[2] == "editor-minimap" ? 11 : args[2] == "scrollbar-visibility" ? 12 : args[2] == "explorer-preview" ? 12 : args[2] == "language-folder" ? 121 : args[2] == "editor-scroll" ? 13 : args[2] == "sidebar-preview" ? 18 : args[2] == "sidebar-search" || args[2] == "sidebar-stale-preview" ? 20 : args[2] == "sidebar-write" ? 11 : args[2] == "keyboard" ? 17 : args[2] == "write" ? 12 : 7;
		var status = DesktopUiHost.run(options, context -> new WorkspaceSmokeApp(context, args[0], args[2]));

		return status;
	}
}
