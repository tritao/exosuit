package app;

import haxeon.ui.TextLayout.TextPosition;

import ui.ExosuitApp;
import ui.ExosuitPalette;
import ui.UiEditorTabs;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Color;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import plugin.PluginDecorationKind;
import search.DocumentSearch;
import search.SearchOptions;
import editor.BufferSelection;
import editor.BufferPosition;
import editor.EditorCoordinates;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.widgets.text.TextEditorState;
import nativekit.ffi.NativeKitTypes.TextEditAction;
import haxeon.platform.NativeKitEventValue.NativeKitTextEdit;

/** Warms the editor's retained layout before editing or clearing its decorations. */
class DecorationSmokeApp extends ExosuitApp {
	final phase:String;
	var frames = 0;
	var transferredTerminal:Null<ui.UiTerminalTab> = null;
	var menuRuns:Int = 0;
	var menuAllowed:Bool = true;
	var menuDocument:Null<editor.Document> = null;
	var firstPopupY:Float = -1.0;
	var savedPaneLines:Array<String> = [];
	var popupScrollController:Null<haxeon.ui.widgets.scroll.ScrollController> = null;

	public function new(context:haxeon.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, phase == "popup-completion-light" ? ExosuitPalette.theme(false) : null, context, path, null, null, phase == "popup-completion-light" ? false : null, DecorationSmokeMain.createTerminal);
		this.phase = phase;
		installMarks(0);
		if (phase == "ime-selection-affinity") {
			var view = host.activeView();
			if (view == null) throw "IME regression has no document";
			var text = "";
			for (_ in 0...5) text += "ab é á 👩‍💻 אבג العربية ﬁ ffi\t0123456789 long wrapping text long wrapping text\n";
			view.document.buffer.replaceAllText(text, view.selection);
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
		}

		if (phase == "gutter-aligned") {
			var view = host.activeView();
			if (view == null) throw "gutter fixture has no view";
			var text = "x\nx\n\n";
			for (_ in 0...300) text += "x";
			text += "\n\n";
			for (_ in 0...40) text += "x\n";
			view.document.buffer.replaceAllText(text, view.selection);
			application.theme.foregroundMuted = 0xff0000ff;
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
		}
		if (phase == "selection-clipped") {
			var view = host.activeView();
			if (view == null) throw "clipping fixture has no view";
			var text = "";
			for (_ in 0...100) text += "selected text beyond the viewport\n";
			view.document.buffer.replaceAllText(text, view.selection);
			theme.textSelection = Color.fromBytes(0, 255, 0);
			theme.textSelectionInactive = Color.fromBytes(0, 255, 0);
			view.selectAll();
		}
		if (phase == "pane-selection-model") {
			var document = new editor.Document(null, "abc\ndef", new syntax.SyntaxRegistry());
			var first = new ui.UiDocumentView(document, new BufferSelection());
			var second = new ui.UiDocumentView(document, new BufferSelection());
			if (first.id == second.id) throw "shared-document views have the same identity";
			first.selection.restore(document.buffer, new BufferPosition(0, 1), new BufferPosition(0, 1));
			second.selection.restore(document.buffer, new BufferPosition(1, 2), new BufferPosition(1, 2));
			first.textInput("X\n");
			if (second.cursorLine() != 2 || second.cursorColumn() != 2)
				throw "passive pane caret did not follow shared edit";
			if (first.cursorLine() != 1 || first.cursorColumn() != 0)
				throw "active pane caret was transformed twice";
			first.undo();
			if (second.cursorLine() != 1 || second.cursorColumn() != 2)
				throw "passive pane caret did not follow shared undo";
			second.dispose();
			first.selection.restore(document.buffer, new BufferPosition(0, 0), new BufferPosition(0, 0));
			first.textInput("\n");
			if (second.cursorLine() != 1 || second.cursorColumn() != 2)
				throw "disposed pane kept a buffer subscription";
			first.dispose();
			menuDocument = host.activeDocument();
			var reopened = menuDocument;
			if (reopened == null) throw "identity fixture has no document";
			host.closeActiveTab(true);
			host.openDocument(reopened);
			application.newDocument();
		}
		if (StringTools.startsWith(phase, "menu-")) {
			menuDocument = host.activeDocument();
			if (menuDocument == null) throw "menu fixture has no document";
			if (phase == "menu-tab" || phase == "menu-tab-keyboard" || phase == "menu-dirty-close") {
				application.newDocument();
				if (phase == "menu-dirty-close") {
					var first = menuDocument;
					if (first == null) throw "missing first menu document";
					first.buffer.replaceAllText("unsaved", null);
				}
			}
			if (phase == "menu-predicate" || phase == "menu-stale")
				application.commands.add("doc:select-all", function(_) { menuRuns++; }, function(_) return menuAllowed);
		}

		if (StringTools.startsWith(phase, "popup-")) {
			var view = host.activeView();
			if (view == null) throw "popup fixture has no view";
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
			var text = "return 1;\nreturn 2;\nreturn 3;";
			if (phase == "popup-edge" || phase == "popup-scroll" || phase == "popup-clipped") {
				text = "";
				for (_ in 0...30) text += "return aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\n";
			}
			view.document.buffer.replaceAllText(text, view.selection);
			var position = phase == "popup-edge" ? new BufferPosition(3, 70) :
				(phase == "popup-scroll" || phase == "popup-clipped") ? new BufferPosition(3, 3) : new BufferPosition(2, 3);
			view.selection.restore(view.document.buffer, position, position);
		}

		if (phase == "syntax-open" || phase == "syntax-closed" || phase == "syntax-restored") {
			var view = host.activeView();
			if (view == null) throw "syntax fixture has no view";
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
			view.document.buffer.replaceAllText("/*\nreturn 42;\n*/\nreturn 43;", view.selection);
		}

		if (phase == "multi-selected" || phase == "multi-typed" || phase == "multi-pasted" || phase == "multi-navigation" || phase == "multi-wrapped") {
			var view = host.activeView();
			if (view == null) throw "multi fixture has no view";
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
			theme.textSelection = Color.fromBytes(0, 255, 0);
			theme.textCaret = Color.fromBytes(0, 255, 0);
			var text = phase == "multi-navigation" ? "é🙂 x\né🙂 y\né🙂 z" : "é🙂 x\né🙂 y";
			if (phase == "multi-wrapped") {
				text = "";
				for (_ in 0...400) text += "a";
			}
			view.document.buffer.replaceAllText(text, view.selection);
			var anchor = phase == "multi-navigation" ? 3 : 0;
			if (phase == "multi-wrapped") {
				view.selection.restore(view.document.buffer, new BufferPosition(0, 2), new BufferPosition(0, 2));
				view.selection.addRange(view.document.buffer, new BufferPosition(0, 12), new BufferPosition(0, 12));
			} else {
				view.selection.restore(view.document.buffer, new BufferPosition(0, 3), new BufferPosition(0, anchor));
				view.selection.addRange(view.document.buffer, new BufferPosition(1, 3), new BufferPosition(1, anchor));
			}
		}
		if (phase == "caret" || phase == "caret-moved" || phase == "caret-empty") {
			var view = host.activeView();
			if (view == null) throw "caret fixture has no view";
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
			application.theme.currentLine = 0xff00ffff;
			application.theme.bracketMatch = 0x00ffffff;
			view.document.buffer.replaceRange(view.selection, new BufferPosition(0, 0), view.document.buffer.endPosition(), "é🙂(x)\n\n// (ignored)");
			view.selection.restore(view.document.buffer, new BufferPosition(0, 3), new BufferPosition(0, 3));
		}
	}

	function installMarks(line:Int):Void {
		var document = host.activeDocument();
		if (document == null) throw "decoration fixture did not open";
		application.theme.searchMatch = 0xffff00ff;
		var registry = host.getPluginDecorations();
		registry.removeOwner("smoke");
		registry.add("smoke", "diagnostic", document, line, 6, 10, 0xff0000ff, WavyUnderline);
		host.setDocumentSearchMatches(DocumentSearch.find(document, "return", new SearchOptions()));
	}

	function editingSettingsStep():Void {
		var view = host.activeView();
		if (view == null || ui.root == null) throw "editing settings lost the editor";
		var node = findEditor(ui.root, "editor:" + view.document.id);
		if (node == null) throw "editing settings lost the widget";
		ui.focusWidget(node.id);
		var buffer = view.document.buffer;
		if (frames == 2) {
			application.settings.store.set("editor/indentation/tab_width", haxeon.ui.properties.PropertyValue.Int(2));
			buffer.replaceAllText(" a", view.selection); view.restoreCursor(0, 1);
		} else if (frames == 3) {
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			if (buffer.text != "  a" || view.selection.cursor.column != 2) throw "Tab ignored live tab-width settings";
			view.backspace();
			if (buffer.text != "a" || view.selection.cursor.column != 0) throw "command Backspace ignored live tab width";
			buffer.replaceAllText("  {}", view.selection); view.restoreCursor(0, 3);
		} else if (frames == 4) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (buffer.text != "  {\n    \n  }" || view.selection.cursor.column != 4) throw "Enter ignored the configured indentation width";
			application.settings.store.set("editor/indentation/insert_spaces", haxeon.ui.properties.PropertyValue.Bool(false));
			buffer.replaceAllText("\t{}", view.selection); view.restoreCursor(0, 2);
		} else if (frames == 5) {
			view.insertNewline();
			if (buffer.text != "\t{\n\t\t\n\t}" || view.selection.cursor.line != 1 || view.selection.cursor.column != 2) throw "command Enter ignored hard-tab settings";
			view.undo(); view.restoreCursor(0, 0);
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			if (buffer.text != "\t\t{}") throw "keyboard Tab ignored hard-tab settings";
			trace("PASS: live tab width and hard-tab settings shared by widget and command edits");
		}
	}

	function editingPolicyStep():Void {
		var view = host.activeView();
		if (view == null || ui.root == null) throw "editing policy lost its view";
		var node = findEditor(ui.root, "editor:" + view.document.id);
		if (node == null) throw "editing policy lost its editor";
		ui.focusWidget(node.id);
		var buffer = view.document.buffer;
		if (frames == 2) {
			buffer.replaceAllText("  alpha", view.selection);
			view.restoreCursor(0, 2);
		} else if (frames == 3) {
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			if (buffer.text != "    alpha" || view.selection.cursor.column != 4) throw "Tab did not insert at its caret";
			ui.key(UiEventKind.KeyRepeat, UiKey.Tab);
			if (buffer.text != "        alpha" || view.selection.cursor.column != 8 || (ui.focus.focusedId == null || !ui.focus.focusedId.equals(node.id))) throw "held Tab moved focus or failed to repeat";
			ui.key(UiEventKind.KeyDown, UiKey.Tab, UiModifier.Shift);
			ui.key(UiEventKind.KeyRepeat, UiKey.Tab, UiModifier.Shift);
			if (buffer.text != "alpha" || view.selection.cursor.column != 0) throw "held Shift+Tab did not unindent";
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			ui.key(UiEventKind.KeyDown, UiKey.Backspace);
			if (buffer.text != "alpha" || view.selection.cursor.column != 0) throw "smart Backspace did not undo one indentation level";
			var runs = 0;
			ui.commands.register(new haxeon.ui.core.Command("test.repeat", "Repeat test", function() runs++, new haxeon.ui.core.Shortcut(UiKey.F5)));
			ui.key(UiEventKind.KeyDown, UiKey.F5); ui.key(UiEventKind.KeyRepeat, UiKey.F5);
			if (runs != 1) throw "command repeats ran an action without repeat opt-in";
			buffer.replaceAllText("    {}", view.selection); view.restoreCursor(0, 5);
		} else if (frames == 4) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (buffer.text != "    {\n        \n    }" || view.selection.cursor.line != 1 || view.selection.cursor.column != 8) throw "graphical Enter misplaced the indented caret";
			view.undo();
			if (buffer.text != "    {}" || view.selection.cursor.column != 5) throw "graphical Enter was not atomic";
			buffer.replaceAllText("á👩‍💻\ná👩‍💻", view.selection);
			var end = "á👩‍💻".length;
			view.selection.setCursor(buffer, new BufferPosition(1, end));
			view.selection.addRange(buffer, new BufferPosition(0, end), new BufferPosition(0, end));
		} else if (frames == 5) {
			ui.key(UiEventKind.KeyDown, UiKey.Backspace);
			if (buffer.text != "á\ná" || view.selection.rangeCount() != 2) throw "multi-caret Backspace split an emoji grapheme";
			ui.key(UiEventKind.KeyDown, UiKey.Backspace);
			if (buffer.text != "\n") throw "multi-caret Backspace split a combining grapheme";
			view.undo(); view.undo();
			if (buffer.text != "á👩‍💻\ná👩‍💻" || view.selection.rangeCount() != 2) throw "multi-caret deletion undo lost text or carets";
			view.selection.setCursor(buffer, new BufferPosition(0, "á👩‍💻".length));
			view.backspace();
			if (buffer.text != "á\ná👩‍💻") throw "command Backspace differed from widget grapheme deletion";
			buffer.replaceAllText("  a\n      b", view.selection);
			view.selection.setCursor(buffer, new BufferPosition(1, 6));
			view.selection.addRange(buffer, new BufferPosition(0, 2), new BufferPosition(0, 2));
		} else if (frames == 6) {
			ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (buffer.text != "  \n  a\n      \n      b" || view.selection.cursor.line != 3 || view.selection.cursor.column != 6) throw "graphical multi-caret Enter lost indentation";
			var accepted = 0;
			for (modifiers in [platform.Platform.MOD_SHIFT, platform.Platform.MOD_CTRL]) {
				host.openLanguageCompletion(new platform.TextInputArea(0, 0, 1, 1), [new completion.CompletionItem("test")], function(_) accepted++);
				if (host.handleLanguagePopupKey(platform.Platform.KEY_TAB, modifiers) || accepted != 0 || host.isLanguagePopupVisible()) throw "modified Tab accepted a completion";
			}
			host.openLanguageCompletion(new platform.TextInputArea(0, 0, 1, 1), [new completion.CompletionItem("test")], function(_) accepted++);
			if (!host.handleLanguagePopupKey(platform.Platform.KEY_TAB, 0) || accepted != 1) throw "plain Tab failed to accept completion";
			var beforeFocusMode = buffer.text;
			ui.focusWidget(node.id);
			ui.key(UiEventKind.KeyDown, 77 /* M */, UiModifier.Control);
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			if (buffer.text != beforeFocusMode || ui.focus.focusedId == null || ui.focus.focusedId.equals(node.id)) throw "Tab focus mode edited text or trapped focus";
			ui.key(UiEventKind.KeyDown, 77 /* M */, UiModifier.Control);
			ui.focusWidget(node.id);
			ui.key(UiEventKind.KeyDown, UiKey.Tab);
			if (buffer.text == beforeFocusMode || ui.focus.focusedId == null || !ui.focus.focusedId.equals(node.id)) throw "disabling Tab focus mode did not restore indentation";
			trace("PASS: editor indentation stops, key repeats, grapheme deletion, Enter placement, undo and completion modifiers");
		}
	}

	override public function submit(frame:LayoutFrame):haxeon.ui.core.RenderNode {
		frames++;
		if (phase == "editing-policy" && frames >= 2 && frames <= 6) editingPolicyStep();
		if (phase == "editing-settings" && frames >= 2 && frames <= 5) editingSettingsStep();
		if (phase == "ime-selection-affinity" && frames == 4) {
			var view = host.activeView(), previous = ui.root;
			if (view == null || previous == null) throw "IME regression lost editor";
			var node = findEditor(previous, "editor:" + view.document.id);
			if (node == null) throw "IME regression missing text field";
			ui.focusWidget(node.id);
			var bounds = node.globalBounds();
			ui.pointerDown(bounds.x + 198, bounds.y + 105, 0);
			ui.pointerMove(bounds.x + 89, bounds.y + 48);
			ui.pointerUp(bounds.x + 89, bounds.y + 48, 0);
			var state:State<TextEditorState> = ui.buildContext.existingState(node.id);
			var editor = state.value;
			if (editor.selectionStart == editor.selectionEnd ||
				editor.focusPosition().offset == editor.selectionStart)
				throw "IME regression did not exercise visual affinity";
			var rects = editor.layout.selectionRangeRects(editor.anchorPosition(), editor.focusPosition());
			if (rects.length == 0) throw "IME regression discarded geometry";
			for (rect in rects) if (rect.start < editor.selectionStart || rect.end > editor.selectionEnd)
				throw "IME range rectangle falls outside logical selection";
		}

		if (phase == "terminal-editor-transfer" && frames == 4) {
			openTerminal();
			transferredTerminal = host.activePanelTerminal();
			if (transferredTerminal == null || !moveTerminalToEditor()) throw "terminal transfer failed";
			var tab = host.activeTab();
			if (tab == null || UiEditorTabs.terminal(tab) != transferredTerminal || host.activeView() != null)
				throw "terminal editor tab lost ownership or document isolation";
			if (host.panelTerminals.length != 0 || (transferredTerminal == null || transferredTerminal.disposed)) throw "transfer closed terminal";
		}
		if (phase == "terminal-editor-transfer" && frames == 5) {
			if (!host.switchActiveTab(-1) || host.activeView() == null) throw "cannot switch to document";
			if (!host.switchActiveTab(1) || host.activeView() != null) throw "cannot switch to terminal";
			var saved = session.WorkspaceSession.decode(session.WorkspaceSession.capture(application).encode());
			saved.restore(application);
			var tab = host.activeTab();
			if (tab == null || UiEditorTabs.terminal(tab) != transferredTerminal)
				throw "session restore replaced live terminal";
			if (!moveTerminalToPanel() || host.activePanelTerminal() != transferredTerminal)
				throw "return to panel lost terminal";
		}
		if (phase == "terminal-editor-transfer" && frames == 6) {
			if (!moveTerminalToEditor()) throw "second transfer failed";
			openTerminal();
			if (host.activePanelTerminal() == transferredTerminal) throw "new terminal reused moved owner";
			if (!moveTerminalToPanel() || host.panelTerminals.length != 2) throw "multiple panel terminals lost";
			if (DecorationSmokeMain.terminalStarts != 2 || transferredTerminal == null || (transferredTerminal == null || transferredTerminal.disposed))
				throw "terminal transfer restarted session";
			if (!moveTerminalToEditor() || !host.canCloseActiveTab()) throw "terminal cannot close";
			application.requestCloseActiveTab();
			if (!(transferredTerminal == null || transferredTerminal.disposed) || host.allViews().length != 1 || host.panelTerminals.length != 1)
				throw "terminal close damaged document or another session";
			trace("PASS: live terminal transfers, typed tab switching, session restore, multiple owners and close");
		}
		if (StringTools.startsWith(phase, "terminal-group-") && frames == 4) {
			var saved = session.WorkspaceSession.capture(application);
			var editor = haxeon.ui.docking.DockNode.Panel("editor");
			var layout = phase == "terminal-group-no-tools" ? editor :
				haxeon.ui.docking.DockNode.Split(haxeon.ui.docking.DockSplitAxis.Vertical, 0.72,
					editor, haxeon.ui.docking.DockNode.Panel("problems"));
			if (phase == "terminal-group-migrate") {
				openTerminal();
				saved = session.WorkspaceSession.capture(application);
				layout = haxeon.ui.docking.DockNode.Tabs(["editor", "terminal"], "terminal");
			}
			var snapshot = new haxeon.ui.docking.DockWorkspaceSnapshot(layout, "editor");
			for (index in 0...saved.layout.length) if (StringTools.startsWith(saved.layout[index], "D\t"))
				saved.layout[index] = "D\tdock\t1\t" + haxeon.ui.docking.DockWorkspaceSnapshotCodec.encode(snapshot);
			saved.restore(application);
			openTerminal();
		}
		if (phase == "gutter-aligned" && frames == 5) {
			var view = host.activeView();
			if (view == null) throw "gutter fixture lost its view";
			// Keep the wrapped paragraph and its preceding line visible together.
			view.restoreScroll(0, 20);
		}
		if (phase == "gutter-aligned" && frames == 6) {
			var view = host.activeView();
			if (view == null) throw "gutter fixture lost its view";
			view.restoreCursor(0, 0);
			view.textInput("\n");
		}
		if ((StringTools.startsWith(phase, "pane-split-") || StringTools.startsWith(phase, "pane-close-") || StringTools.startsWith(phase, "pane-move-") || phase == "pane-session-roundtrip") && frames == 4) {
			var direction = phase == "pane-split-down" ? "down" : "right";
			if (!application.commands.perform("root:split-" + direction, application.context))
				throw "UIKit split command was unavailable";
		}
		if (phase == "pane-selection-model" && frames == 4) {
			var previousRoot = ui.root, document = menuDocument;
			if (previousRoot == null || document == null) throw "identity fixture has no tab";
			var tab = findEditor(previousRoot, "doc:" + document.id);
			var geometry = tab == null ? null : tab.resolved;
			if (geometry == null) throw "identity fixture tab is unresolved";
			var x = geometry.x + 10.0, y = geometry.y + 8.0;
			ui.pointerDown(x, y, 0);
			ui.pointerUp(x, y, 0);
			var active = host.activeView();
			if (active == null || active.document != document || active.id == document.id)
				throw "tab selection confused view identity with document identity";
			trace("PASS: independent shared-document selections, disposal and reopened-view tab activation");
		}
		if (StringTools.startsWith(phase, "menu-") && frames == 4) {
			var previousRoot = ui.root;
			var document = menuDocument;
			if (previousRoot == null || document == null) throw "menu fixture has no resolved target";
			var target:Null<RenderNode> = null;
			if (phase == "menu-tab" || phase == "menu-tab-keyboard" || phase == "menu-dirty-close")
				target = findEditor(previousRoot, "doc:" + document.id);
			else if (phase == "menu-tree" || phase == "menu-tree-keyboard")
				target = findTreeFile(previousRoot);
			else target = findEditor(previousRoot, "editor:" + document.id);
			if (target == null) throw "menu fixture target is missing";
			var targetGeometry = target.resolved;
			if (targetGeometry == null) throw "menu fixture target is unresolved";
			if (phase == "menu-keyboard" || phase == "menu-tab-keyboard" || phase == "menu-tree-keyboard") {
				if (!ui.focusWidget(target.id)) throw "could not focus context-menu target";
				ui.key(UiEventKind.KeyDown, phase == "menu-tree-keyboard" ? UiKey.Menu : UiKey.F10,
					phase == "menu-tree-keyboard" ? 0 : UiModifier.Shift);
			} else {
				var x = phase == "menu-edge" ? frame.width - 12.0 : targetGeometry.x + 10.0;
				var y = targetGeometry.y + 8.0;
				ui.pointerDown(x, y, 1);
				ui.pointerUp(x, y, 1);
			}
		}
		if (phase == "menu-escape" && frames == 5) ui.key(UiEventKind.KeyDown, UiKey.Escape);
		if (phase == "menu-outside" && frames == 5) {
			ui.pointerDown(10.0, 10.0, 0);
			ui.pointerUp(10.0, 10.0, 0);
		}
		if (phase == "menu-switch" && frames == 5) application.newDocument();
		if (StringTools.startsWith(phase, "menu-") && frames == 5 && phase != "menu-switch" && phase != "menu-capture" && phase != "menu-escape" && phase != "menu-outside") {
			var previousRoot = ui.root;
			if (previousRoot == null) throw "missing menu root";
			if (phase == "menu-stale") application.newDocument();
			if (phase == "menu-predicate") menuAllowed = false;
			var command = phase == "menu-tab" || phase == "menu-tab-keyboard" || phase == "menu-dirty-close" ? "root:close" :
				phase == "menu-tree" || phase == "menu-tree-keyboard" ? "file:rename" : "doc:select-all";
			if (phase == "menu-keyboard" || phase == "menu-tab-keyboard") {
				// The editor menu starts at Undo. Navigate to Select All with the keyboard.
				for (_ in 0...(phase == "menu-tab-keyboard" ? 2 : 5)) ui.key(UiEventKind.KeyDown, UiKey.Down);
				ui.key(UiEventKind.KeyDown, UiKey.Enter);
			} else {
				var button = findEditor(previousRoot, command);
				if (button == null) throw "missing command menu item " + command;
				var buttonGeometry = button.resolved;
				if (buttonGeometry == null) throw "unresolved command menu item " + command;
				ui.pointerDown(buttonGeometry.x + 8.0, buttonGeometry.y + 8.0, 0);
				ui.pointerUp(buttonGeometry.x + 8.0, buttonGeometry.y + 8.0, 0);
			}
		}

		if (frames == 4 && phase != "terminal-editor-transfer") {
			var document = host.activeDocument();
			if (document == null) throw "decoration fixture document disappeared";
			if (phase == "caret-moved" || phase == "caret-empty") {
				var view = host.activeView();
				if (view == null) throw "caret fixture view disappeared";
				var position = phase == "caret-empty" ? new BufferPosition(1, 0) : new BufferPosition(2, 3);
				view.selection.restore(document.buffer, position, position);
			} else if (phase == "selection") {
				var view = host.activeView();
				if (view == null) throw "selection fixture has no view";
				document.buffer.replaceRange(view.selection, new BufferPosition(0, 0), document.buffer.endPosition(), "a🙂bc\né");
				view.selection.restore(document.buffer, new BufferPosition(0, 1), new BufferPosition(0, 5));
			} else if (phase == "moved") {
				document.buffer.replaceRange(new BufferSelection(), new BufferPosition(0, 0), new BufferPosition(0, 0), "// inserted é🙂\n");
				installMarks(1);
			} else if (phase == "cleared") {
				host.getPluginDecorations().removeOwner("smoke");
				host.setDocumentSearchMatches([]);
			}
		}
		if (frames == 4 && (phase == "syntax-closed" || phase == "syntax-restored")) {
			var view = host.activeView();
			if (view == null) throw "syntax fixture disappeared";
			view.document.buffer.replaceRange(view.selection, new BufferPosition(0, 2), new BufferPosition(0, 2), " */");
		}
		if (frames == 5 && phase == "syntax-restored") {
			var view = host.activeView();
			if (view == null) throw "syntax undo fixture disappeared";
			view.undo();
		}
		if (frames == 4 && StringTools.startsWith(phase, "popup-")) {
			var area = host.textInputArea();
			if (area == null) throw "popup fixture lacks resolved caret geometry";
			if (phase == "popup-live-completion" || phase == "popup-ime" || phase == "popup-completion-mouse" || phase == "popup-completion-dismiss") {
				var view = host.activeView();
				if (view == null) throw "live completion lacks editor";
				view.document.buffer.replaceAllText("", view.selection);
				view.restoreCursor(0, 0);
				new completion.ActiveCompletion(host, view, view.document, new BufferPosition(0, 0), new BufferPosition(0, 0),
					[new completion.CompletionItem("alpha", "alpha", null, null, 6), new completion.CompletionItem("beta", "():Int", null, null, 3, "Returns the answer.")], () -> host.activeView() == view).show();
			} else if ((phase == "popup-completion-long" || phase == "popup-completion-wrap" || phase == "popup-completion-page")) {
				var items:Array<completion.CompletionItem> = [];
				for (index in 0...40) items.push(new completion.CompletionItem("suggestion" + index));
				host.openLanguageCompletion(area, items, function(_) {});
			} else if (phase == "popup-completion" || phase == "popup-completion-light")
				host.openLanguageCompletion(area, [new completion.CompletionItem("example", "(value:Int):String", null, null, 3, "Example documentation")], function(_) {});
			else if (phase == "popup-signature")
				host.openLanguageSignature(area, new language.SignatureHelp("example(value:Int)", "signature documentation", "value"));
			else {
				var information = "hover information";
				if (phase == "popup-large")
					for (_ in 0...80) information += "\nadditional documentation";
				host.openLanguageInformation(area, information);
			}
		}
		if (frames == 5 && StringTools.startsWith(phase, "popup-")) {
			if ((phase == "popup-completion-long" || phase == "popup-completion-wrap" || phase == "popup-completion-page"))
				for (_ in 0...(phase == "popup-completion-wrap" ? 1 : 39)) ui.key(UiEventKind.KeyDown, phase == "popup-completion-wrap" ? UiKey.Up : UiKey.Down);
			if (phase == "popup-completion-page") ui.key(UiEventKind.KeyDown, UiKey.PageUp);
			var view = host.activeView();
			if (view == null) throw "popup fixture lost active document";
			if (phase == "popup-ime") {
				ui.text(UiEventKind.TextEdit, "日", new NativeKitTextEdit(TextEditAction.Compose, "日", 0, 0, 1, 1, 0, 1));
				if (host.isLanguagePopupVisible() || view.document.buffer.line(0) != "日") throw "completion popup lost IME composition handoff: visible=" + host.isLanguagePopupVisible() + " text=" + view.document.buffer.line(0);
			} else if (phase == "popup-live-completion") {
				ui.text(UiEventKind.TextInput, "al");
				if (view.document.buffer.line(0) != "al" || !host.isLanguagePopupVisible()) throw "graphical completion lost typed prefix";
				ui.key(UiEventKind.KeyDown, UiKey.Backspace);
				if (view.document.buffer.line(0) != "a") throw "graphical completion lost backspace";
			} else if (phase == "popup-switch")
				host.openDocument(new editor.Document(null, "other", application.syntaxes));
			else if (phase == "popup-scroll" || phase == "popup-clipped") {
				if (popupScrollController == null || !popupScrollController.jumpTo(0.0, phase == "popup-clipped" ? 350.0 : 24.0))
					throw "popup fixture could not scroll retained editor";
			} else if (phase != "popup-edge" && phase != "popup-large")
				view.selection.restore(view.document.buffer, new BufferPosition(0, 7), new BufferPosition(0, 7));
		}
		if (frames == 6 && (phase == "popup-completion-mouse" || phase == "popup-completion-dismiss")) {
			var view = host.activeView();
			if (phase == "popup-completion-mouse") {
				var row = findEditor(ui.root, "lang-row-1");
				if (row == null) throw "completion mouse target missing";
				var bounds = row.globalBounds();
				ui.pointerMove(bounds.x + 10, bounds.y + 10);
				ui.pointerDown(bounds.x + 10, bounds.y + 10, 0);
				ui.pointerUp(bounds.x + 10, bounds.y + 10, 0);
			} else ui.key(UiEventKind.KeyDown, UiKey.Escape);
			if (view == null || host.isLanguagePopupVisible() || view.document.buffer.text != (phase == "popup-completion-mouse" ? "beta" : ""))
				throw "completion pointer acceptance or Escape dismissal failed";
		}
		if (frames == 6 && phase == "popup-live-completion") {
			var view = host.activeView();
			ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (view == null || view.document.buffer.line(0) != "alpha" || host.isLanguagePopupVisible())
				throw "graphical completion failed to accept narrowed suggestion";
		}
		if (frames == 6 && phase == "popup-ime") {
			ui.text(UiEventKind.TextEdit, "日本", new NativeKitTextEdit(TextEditAction.Commit, "日本", 0, 1, 2, 2, -1, -1));
			var view = host.activeView();
			if (view == null || view.document.buffer.line(0) != "日本") throw "IME handoff lost or duplicated committed text";
		}
		if (StringTools.startsWith(phase, "pane-close-") && frames == 5) {
			if (phase != "pane-close-shared") application.newDocument();
			var active = host.activeView();
			if (active == null) throw "pane close fixture has no active view";
			active.textInput("unsaved");
			menuDocument = active.document;
			if (!application.requestCloseActivePane()) throw "pane close request was unavailable";
			if (phase == "pane-close-shared") {
				if (host.panes.length != 1 || host.commandView.active || host.activeDocument() != menuDocument ||
					!application.documents.documents.contains(active.document)) throw "shared dirty document was lost or prompted";
			} else if (host.panes.length != 2 || !host.commandView.active) throw "unique dirty pane bypassed confirmation";
		}
		if (StringTools.startsWith(phase, "pane-close-") && phase != "pane-close-shared" && frames == 6) {
			if (phase == "pane-close-cancel") ui.key(UiEventKind.KeyDown, UiKey.Escape);
			else { ui.text(UiEventKind.TextInput, "discard"); ui.key(UiEventKind.KeyDown, UiKey.Enter); }
		}
		if (StringTools.startsWith(phase, "pane-move-") && frames == 5) {
			if (phase == "pane-move-unique") application.newDocument();
			var active = host.activeView();
			if (active == null) throw "pane move fixture has no active view";
			menuDocument = active.document;
			var sourceId = active.id;
			if (!host.moveActiveTab(-1, 0) || host.activePane != host.panes[0]) throw "tab movement missed destination pane";
			var moved = host.activeView();
			if (moved == null || moved.document != menuDocument) throw "tab movement changed document";
			if (phase == "pane-move-unique" ? moved.id != sourceId : moved.id == sourceId)
				throw "tab movement did not preserve or deduplicate the view correctly";
		}
		if (phase == "pane-session-roundtrip" && frames == 5) {
			var first = host.panes[0].activeView(), second = host.panes[1].activeView();
			if (first == null || second == null) throw "session fixture lost split views";
			var text = "";
			for (_ in 0...100) text += "return 42;\n";
			first.document.buffer.replaceAllText(text, first.selection);
			first.restoreCursor(10, 3);
			second.restoreCursor(14, 2);
		}
		if (phase == "pane-session-roundtrip" && frames == 6) {
			var first = host.panes[0].activeView(), second = host.panes[1].activeView();
			if (first == null || second == null) throw "session fixture lost scroll owners";
			first.restoreScroll(0, 120);
			second.restoreScroll(0, 240);
			savedPaneLines = host.sessionLines();
			var portable = Sys.getEnv("PRAGTICAL_PORTABLE");
			if (portable == null) throw "session fixture has no isolated storage";
			var recovery = new recovery.RecoveryStore(portable + "/pane-recovery.conf", application.workspace.fileSystem);
			if (!recovery.save(application)) throw "session recovery snapshot did not save";
			var session = session.WorkspaceSession.decode(session.WorkspaceSession.capture(application).encode());
			session.restore(application, recovery);
		}
        if (phase == "terminal-editor-transfer" && frames == 8) {
            var previous = ui.root;
            var button = previous == null ? null : findEditor(previous, "terminal:move-to-editor");
            if (button == null) throw "terminal transfer context action is missing";
            var bounds = button.globalBounds();
            ui.pointerDown(bounds.x + 8, bounds.y + 8, 0);
            ui.pointerUp(bounds.x + 8, bounds.y + 8, 0);
            var tab = host.activeTab();
            if (tab == null || UiEditorTabs.terminal(tab) == null || host.panelTerminals.length != 0 || DecorationSmokeMain.terminalStarts != 2)
                throw "context transfer replaced or lost terminal";
            trace("PASS: terminal panel pointer context menu transfers existing session");
        }
        if (phase == "terminal-editor-transfer" && frames == 7) {
            var previous = ui.root;
            var terminal = previous == null ? null : findEditor(previous, "terminal-backdrop");
            if (terminal == null) throw "terminal panel backdrop missing";
            var bounds = terminal.globalBounds();
            ui.pointerDown(bounds.x + 20, bounds.y + 20, 1);
            ui.pointerUp(bounds.x + 20, bounds.y + 20, 1);
        }
		var root = super.submit(frame);
		if (phase == "ime-selection-affinity" && frames == 5)
			trace("PASS: real GTK pointer selection publishes logical IME range tags with visual affinity");


		if (phase == "terminal-group-migrate" && frames == 6) {
			var terminalTab:Null<RenderNode> = null;
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tab &&
					node.semantics.label == "Terminal") terminalTab = node;
			});
			var bounds = host.activePane.bounds;
			if (terminalTab == null || bounds == null) throw "grouping drag fixture has no resolved target";
			var header = terminalTab.globalBounds();
			var before = host.sessionLines()[0];
			ui.pointerDown(header.x + header.width / 2.0, header.y + header.height / 2.0, 0);
			ui.pointerMove(bounds.x + bounds.width / 2.0, bounds.y + bounds.height / 2.0);
			ui.pointerUp(bounds.x + bounds.width / 2.0, bounds.y + bounds.height / 2.0, 0);
			if (host.sessionLines()[0] != before) throw "terminal drag regrouped the editor dock pane";
			trace("PASS: incompatible terminal-to-editor tab drop leaves layout unchanged");
		}
		if ((phase == "editor-header" || StringTools.startsWith(phase, "terminal-group-") || StringTools.startsWith(phase, "pane-split-")) && frames == 7) {
			var dockEditorTabs = 0, documentTabs = 0;
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tab &&
					node.semantics.label == "Editor") dockEditorTabs++;
				if (node.styleKey != null && StringTools.startsWith(node.styleKey, "doc:")) documentTabs++;
			});
			if (dockEditorTabs != 0 || documentTabs != host.allViews().length)
				throw "editor panes must expose document tabs without a redundant dock header";
			trace("PASS: editor panes have one document tab row and no redundant dock header");
			if (StringTools.startsWith(phase, "terminal-group-")) {
				var terminalTabs = 0;
				root.walk(function(node) {
					if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tab &&
						node.semantics.label == "Terminal") terminalTabs++;
				});
				if (terminalTabs != 1) throw "terminal did not reopen in its tool group";
				if (DecorationSmokeMain.terminalStarts != 1)
					throw "layout restoration restarted the terminal session";
				trace("PASS: terminal tool grouping " + phase);
			}
		}
		if (phase == "gutter-aligned" && frames == 7) {
			var view = host.activeView();
			if (view == null) throw "gutter fixture lost its view";
			var node = findEditor(root, "editor:" + view.document.id);
			if (node == null) throw "gutter fixture lost its editor";
			var state:State<TextEditorState> = ui.buildContext.existingState(node.id);
			var editor = state.value;
			var bounds = host.activePane.bounds;
			if (bounds == null) throw "gutter fixture has no viewport";
			var baselines:Array<Float> = [];
			// EditorPane supplies a field style with no text padding.
			for (index in 0...editor.layout.paragraphCount) {
				var y = bounds.y + editor.layout.paragraphCaret(index).y - view.scrollY();
				if (y > bounds.y + 14.0 && y < bounds.y + bounds.height) baselines.push(y);
			}
			var portable = Sys.getEnv("PRAGTICAL_PORTABLE");
			if (portable == null) throw "gutter fixture has no storage";
			if (!sys.FileSystem.exists(portable)) sys.FileSystem.createDirectory(portable);
			sys.io.File.saveContent(portable + "/gutter-baselines.json", haxe.Json.stringify({
				baselines: baselines, left: bounds.x, right: bounds.x + 34.0
			}));
		}
		if (phase == "selection-clipped" && frames == 7) {
			var bounds = host.activePane.bounds;
			if (bounds == null) throw "clipping fixture has no resolved editor viewport";
			var portable = Sys.getEnv("PRAGTICAL_PORTABLE");
			if (portable == null) throw "clipping fixture has no storage";
			if (!sys.FileSystem.exists(portable)) sys.FileSystem.createDirectory(portable);
			sys.io.File.saveContent(portable + "/editor-bounds.json", haxe.Json.stringify({
				x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height
			}));
		}
		if (phase == "pane-session-roundtrip" && frames == 7) {
			var first = host.panes[0].activeView(), second = host.panes[1].activeView();
			if (host.panes.length != 2 || first == null || second == null || first.document != second.document ||
				first.selection == second.selection || first.cursorLine() != 10 || second.cursorLine() != 14 ||
				first.scrollY() != 120 || second.scrollY() != 240 || host.activePane != host.panes[1])
				throw "session lost pane membership, active view, shared buffer, caret or scroll";
			if (host.sessionLines().join("\n") != savedPaneLines.join("\n")) {
				trace("session before restore:\n" + savedPaneLines.join("\n"));
				trace("session after restore:\n" + host.sessionLines().join("\n"));
				throw "dock snapshot or session metadata changed on restore";
			}
			trace("PASS: dock split, shared dirty recovery, independent carets/scroll and active pane survive session roundtrip");
		}

		if (StringTools.startsWith(phase, "pane-close-") && frames == 7) {
			if (host.commandView.active) throw "pane confirmation did not finish";
			if (phase == "pane-close-cancel") {
				if (host.panes.length != 2 || host.activeDocument() != menuDocument) throw "cancel lost pane or document";
			} else if (host.panes.length != 1) throw "confirmed pane did not collapse";
			if (phase == "pane-close-discard" && menuDocument != null && application.documents.documents.contains(menuDocument))
				throw "discarded unique document stayed registered";
			trace("PASS: pane close lifecycle " + phase);
		}
		if (StringTools.startsWith(phase, "pane-move-") && frames == 6) {
			var active = host.activeView();
			if (active == null) throw "moved view disappeared";
			var editorNode = findEditor(root, "editor:" + active.document.id);
			if (editorNode == null || !ui.focusWidget(editorNode.id)) throw "moved editor did not accept real focus";
			if (host.activePane != host.panes[0] || host.activeDocument() != menuDocument)
				throw "moved editor retained source-pane callbacks";
			trace("PASS: tab movement and destination focus " + phase);
		}

		if (StringTools.startsWith(phase, "pane-split-") && frames == 5) {
			var editors:Array<RenderNode> = [];
			root.walk(function(node) {
				if (node.focusable && node.styleKey != null && StringTools.startsWith(node.styleKey, "editor:")) editors.push(node);
			});
			if (editors.length != 2 || host.panes.length != 2) throw "split did not render two editor controls";
			var first = host.panes[0].activeView(), second = host.panes[1].activeView();
			if (first == null || second == null || first.document != second.document || first.selection == second.selection)
				throw "split copied document text or shared selection state";
			var left = host.panes[0].bounds, right = host.panes[1].bounds;
			if (left == null || right == null) throw "split editor geometry was not reported";
			if (phase == "pane-split-down" ? right.y <= left.y : right.x <= left.x)
				throw "split orientation does not match command";
			if (!host.focusPane(phase == "pane-split-down" ? 0 : -1, phase == "pane-split-down" ? -1 : 0))
				throw "directional focus missed neighboring pane";
			if (host.activeView() != first) throw "pane focus did not activate its core view";
			first.textInput("X");
			if (second.document.buffer != first.document.buffer || second.cursorColumn() == first.cursorColumn())
				throw "shared edit collapsed independent pane selections";
			trace("PASS: visible split orientation, shared buffer, independent selections and directional focus");
		}
		if (phase == "selection" && frames == 4) {
			var view = host.activeView();
			if (view == null) throw "selection fixture view disappeared";
			var node = findEditor(root, "editor:" + view.document.id);
			if (node == null) throw "selection fixture editor disappeared";
			var state:State<TextEditorState> = ui.buildContext.existingState(node.id);
			var editor:TextEditorState = state.value;
			if (editor.selectionAnchor != 4 || editor.selectionFocus != 1)
				throw "model backward selection did not reach the real widget";
			ui.focusWidget(node.id);
			ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Shift);
			if (view.selection.anchor.column != 5 || view.selection.cursor.column != 3)
				throw "widget emoji navigation did not update shared UTF-16 selection";
			ui.text(UiEventKind.TextInput, "x");
			if (view.document.buffer.text != "a🙂x\né" || view.selection.cursor.column != 4)
				throw "controlled widget edit used a stale selection or coordinate map";
			trace("PASS: real EditorPane controlled selection, Unicode navigation and replacement");
		}
		if ((phase == "multi-selected" || phase == "multi-typed" || phase == "multi-pasted" || phase == "multi-navigation" || phase == "multi-wrapped") && frames == 4) {
			var view = host.activeView();
			if (view == null) throw "multi fixture view disappeared";
			var node = findEditor(root, "editor:" + view.document.id);
			if (node == null) throw "multi fixture editor disappeared";
			ui.focusWidget(node.id);
			if (phase == "multi-wrapped") {
				var state:State<TextEditorState> = ui.buildContext.existingState(node.id);
				var editor = state.value;
				var before = view.selection.allRanges();
				var firstY = editor.layout.caret(new TextPosition(
					EditorCoordinates.codepoint(view.document, before[0].cursor), 0)).y;
				var secondY = editor.layout.caret(new TextPosition(
					EditorCoordinates.codepoint(view.document, before[1].cursor), 0)).y;
				ui.key(UiEventKind.KeyDown, UiKey.Down);
				var after = view.selection.allRanges();
				if (after.length != 2 || after[0].cursor.line != 0 || after[1].cursor.line != 0 ||
					editor.layout.caret(new TextPosition(EditorCoordinates.codepoint(view.document, after[0].cursor), 0)).y <= firstY ||
					editor.layout.caret(new TextPosition(EditorCoordinates.codepoint(view.document, after[1].cursor), 0)).y <= secondY)
					throw "multi-caret Down did not move both carets within a wrapped paragraph";
				trace("PASS: real multi-caret visual navigation within one wrapped paragraph");
			} else if (phase == "multi-navigation") {
				ui.key(UiEventKind.KeyDown, UiKey.Left);
				var ranges = view.selection.allRanges();
				if (ranges.length != 2 || ranges[0].cursor.column != 1 || ranges[1].cursor.column != 1)
					throw "multi-caret Left split a grapheme or moved only the primary";
				ui.key(UiEventKind.KeyDown, UiKey.Right);
				ranges = view.selection.allRanges();
				if (ranges[0].cursor.column != 3 || ranges[1].cursor.column != 3)
					throw "multi-caret Right did not restore both grapheme boundaries";
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Shift);
				ranges = view.selection.allRanges();
				if (ranges[0].cursor.column != 4 || ranges[0].anchor.column != 3 ||
					ranges[1].cursor.column != 4 || ranges[1].anchor.column != 3)
					throw "shift navigation did not extend both selections";
				ui.key(UiEventKind.KeyDown, UiKey.End);
				ranges = view.selection.allRanges();
				if (ranges[0].cursor.column != 5 || ranges[1].cursor.column != 5)
					throw "End did not move both carets";
				ui.key(UiEventKind.KeyDown, UiKey.Down);
				ranges = view.selection.allRanges();
				if (ranges.length != 2 || ranges[0].cursor.line != 1 || ranges[1].cursor.line != 2)
					throw "visual Down did not move both carets";
				trace("PASS: real multi-caret grapheme, selection and visual-line navigation");
			} else if (phase == "multi-pasted") {
				ui.clipboard.writeText("α\nβ");
				ui.key(UiEventKind.KeyDown, UiKey.V, UiModifier.Control);
			} else if (phase == "multi-selected") {
				ui.key(UiEventKind.KeyDown, UiKey.X, UiModifier.Control);
				if (view.document.buffer.text != " x\n y") throw "multi-selection cut missed a range";
				view.undo();
				if (view.selection.rangeCount() != 2) throw "cut undo lost additional selection";
			} else if (phase == "multi-typed") {
				ui.text(UiEventKind.TextInput, "Z");
				if (view.document.buffer.text != "Z x\nZ y" || view.selection.rangeCount() != 2)
					throw "multi-caret replacement changed only one range or duplicated edits";
				ui.key(UiEventKind.KeyDown, UiKey.Backspace);
				if (view.document.buffer.text != " x\n y" || view.selection.rangeCount() != 2)
					throw "multi-caret backspace changed only one range";
				view.undo();
				if (view.document.buffer.text != "Z x\nZ y" || view.selection.rangeCount() != 2)
					throw "multi-caret undo lost a transaction or its selection set";
				ui.key(UiEventKind.KeyDown, UiKey.Delete);
				if (view.document.buffer.text != "Zx\nZy") throw "multi-caret forward deletion missed a range";
				view.undo();
				ui.key(UiEventKind.KeyDown, UiKey.X, UiModifier.Control);
				if (view.document.buffer.text != "Z x\nZ y") throw "cut at collapsed carets changed the document";
				trace("PASS: real multi-caret Unicode replacement, backward/forward deletion and transactional undo");
			}
		}
		if (phase == "multi-pasted" && frames == 7) {
			var view = host.activeView();
			if (view == null || view.document.buffer.text != "α x\nβ y" || view.selection.rangeCount() != 2)
				throw "asynchronous multi-selection paste did not distribute clipboard lines";
			trace("PASS: real asynchronous multi-selection clipboard distribution");
		}
		if (StringTools.startsWith(phase, "popup-")) {
			var panel = findPopup(root);
			if (frames == 4 && panel != null && panel.resolved != null) {
				firstPopupY = panel.resolved.y;
				var active = host.activeDocument();
				if (active == null) throw "popup fixture lost document";
				var editorNode = findEditor(root, "editor-scroll:" + active.id);
				if (editorNode == null) throw "popup fixture lost editor node";
				var activeView = host.activeView();
				if (activeView == null) throw "popup fixture lost editor view";
				popupScrollController = activeView.scrollController;
			}
			if (frames == 6) {
				if (phase == "popup-switch" || phase == "popup-clipped" || phase == "popup-live-completion" || phase == "popup-ime" || phase == "popup-completion-mouse" || phase == "popup-completion-dismiss") {
					if (host.isLanguagePopupVisible() || panel != null) throw "popup survived document switch";
				} else {
					var area = host.textInputArea();
					if (panel == null || panel.resolved == null || area == null) throw "missing resolved popup or caret";
					var bounds = panel.resolved;
					if (phase == "popup-completion" || phase == "popup-completion-light") {
						var row = findEditor(root, "lang-row-0");
						if (row == null || row.semantics == null || (row.semantics.states & haxeon.ui.semantics.AccessibilityState.Selected) == 0)
							throw "completion selection lacks accessibility state";
						if (!containsText(panel, "(value:Int):String\nExample documentation") || !containsText(panel, "Up/Down select · Tab / Enter accept · Esc dismiss"))
							throw "completion documentation or keyboard hint missing";
					}
					if ((phase == "popup-completion-long" || phase == "popup-completion-wrap" || phase == "popup-completion-page")) {
						var selected = findEditor(root, phase == "popup-completion-page" ? "lang-row-31" : "lang-row-39");
						var viewport = findEditor(root, "language-scroll");
						if (selected == null || viewport == null || selected.semantics == null || (selected.semantics.states & haxeon.ui.semantics.AccessibilityState.Selected) == 0) throw "completion lost selected row or scroll viewport";
						var row = selected.globalBounds();
						var visible = viewport.globalBounds();
						if (row.y < visible.y - 0.1 || row.y + row.height > visible.y + visible.height + 0.1)
							throw "keyboard-selected completion escaped popup viewport";
						if (visible.height > 236.1) throw "completion list exceeded bounded height: " + visible.height;
					}
					if (bounds.width <= 0 || bounds.height <= 0 || bounds.x < -0.1 || bounds.y < -0.1 ||
						bounds.x + bounds.width > frame.width + 0.1 || bounds.y + bounds.height > frame.height + 0.1)
						throw "popup escaped viewport bounds";
					var expectedY:Float = area.y + area.height;
					if (expectedY + bounds.height > frame.height) expectedY = area.y - bounds.height;
					expectedY = Math.max(0.0, Math.min(expectedY, frame.height - bounds.height));
					if (phase == "popup-large" && bounds.height < frame.height / 2) throw "large popup was truncated instead of scroll-constrained";
					if (Math.abs(bounds.y - expectedY) > 1.1) throw "popup is detached from caret";
					if (phase != "popup-edge" && phase != "popup-large" && (firstPopupY < 0 || Math.abs(bounds.y - firstPopupY) < 10))
						throw "popup did not track caret movement";
				}
				trace("PASS: resolved language popup " + phase);
			}
		}
		if (StringTools.startsWith(phase, "menu-")) {
			var panel = findContextPanel(root);
			if (frames == 4) {
				if (panel == null || panel.resolved == null) throw "context menu did not open";
				if ((phase == "menu-tab" || phase == "menu-tab-keyboard" || phase == "menu-dirty-close") &&
					(menuDocument == null || findEditor(root, "editor:" + menuDocument.id) == null))
					throw "tab menu target did not become the visible editor";
				var bounds = panel.resolved;
				if (bounds.x < -0.1 || bounds.y < -0.1 || bounds.x + bounds.width > frame.width + 0.1 ||
					bounds.y + bounds.height > frame.height + 0.1) throw "context menu escaped viewport";
			}
			if (frames == 6 && phase == "menu-capture") {
				if (panel == null) throw "context menu disappeared before capture";
				trace("PASS: retained context-menu visual capture");
			}
			if (frames == 6 && phase != "menu-capture") {
				if (panel != null) throw "context menu did not retire after activation";
				if (phase == "menu-predicate" || phase == "menu-stale" || phase == "menu-switch" || phase == "menu-escape" || phase == "menu-outside") {
					if (menuRuns != 0) throw "context command ran against an invalid predicate/target";
				} else if (phase == "menu-tab" || phase == "menu-tab-keyboard") {
					if (host.tabs.length != 1 || host.activeDocument() == menuDocument) throw "tab menu closed the wrong document";
				} else if (phase == "menu-dirty-close") {
					if (host.tabs.length != 2 || !host.commandView.active) throw "tab menu bypassed dirty-close confirmation";
				} else if (phase == "menu-tree" || phase == "menu-tree-keyboard") {
					if (!host.commandView.active || menuDocument == null || host.focusedFilePath() != menuDocument.path)
						throw "tree menu did not dispatch rename for its selected file";
				} else {
					var active = host.activeView();
					if (active == null || !active.selection.anchor.equals(new BufferPosition(0, 0)) ||
						!active.selection.cursor.equals(active.document.buffer.endPosition())) throw "menu Select All did not reach the registry";
				}
				trace("PASS: routed command context menu " + phase);
			}
		}
		return root;
	}
	static function findContextPanel(node:RenderNode):Null<RenderNode> {
		if (node.styleType == "popup-content" && node.styleKey == "command-context-menu") return node;
		for (child in node.children) {
			var found = findContextPanel(child);
			if (found != null) return found;
		}
		return null;
	}

	static function findTreeFile(node:RenderNode):Null<RenderNode> {
		if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem && hasFileLabel(node)) return node;
		for (child in node.children) {
			var found = findTreeFile(child);
			if (found != null) return found;
		}
		return null;
	}

	static function hasFileLabel(node:RenderNode):Bool {
		if (node.semantics != null && node.semantics.label != null && StringTools.endsWith(node.semantics.label, "Main.hx")) return true;
		for (child in node.children) if (hasFileLabel(child)) return true;
		return false;
	}

	static function containsText(node:RenderNode, text:String):Bool {
		if (node.layout.text == text) return true;
		for (child in node.children) if (containsText(child, text)) return true;
		return false;
	}

	static function findPopup(node:RenderNode):Null<RenderNode> {
		if (node.styleType == "popup-content" && node.styleKey == "language-popup") return node;
		for (child in node.children) {
			var found = findPopup(child);
			if (found != null) return found;
		}
		return null;
	}
	static function findEditor(node:RenderNode, key:String):Null<RenderNode> {
		if (node.styleKey == key) return node;
		for (child in node.children) {
			var found = findEditor(child, key);
			if (found != null) return found;
		}
		return null;
	}
}

/** Real renderer coverage for the EditorPane's public presentation providers. */
class DecorationSmokeMain {
	public static var terminalStarts:Int = 0;

	public static function createTerminal(cwd:String, requestFrame:Void->Void,
			palette:ui.TerminalPalette):ui.TerminalPanel {
		var terminal = ui.TerminalPane.open(cwd, requestFrame, palette);
		terminalStarts++;
		return terminal;
	}

	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit decoration smoke";
		options.width = 900;
		options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = args[2] == "terminal-editor-transfer" ? 9 : 7;
		var status = DesktopUiHost.run(options, function(context) {
			return new DecorationSmokeApp(context, args[0], args[2]);
		});

		return status;
	}
}
