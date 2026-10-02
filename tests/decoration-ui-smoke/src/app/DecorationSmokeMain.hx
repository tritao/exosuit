package app;

import ui.ExosuitApp;
import LayoutFrame;
import Color;
import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostOptions;
import plugin.PluginDecorationKind;
import search.DocumentSearch;
import search.SearchOptions;
import editor.BufferSelection;
import editor.BufferPosition;
import editor.EditorCoordinates;
import platform.Native;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.State;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;
import nativekit.ui.widgets.text.TextEditorState;

/** Warms the editor's retained layout before editing or clearing its decorations. */
class DecorationSmokeApp extends ExosuitApp {
	final phase:String;
	var frames = 0;
	var firstPopupY:Float = -1.0;
	var popupScrollController:Null<nativekit.ui.widgets.scroll.ScrollController> = null;

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, path);
		this.phase = phase;
		installMarks(0);
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

	override public function submit(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frames++;
		if (frames == 4) {
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
			if (phase == "popup-completion")
				host.openLanguageCompletion(area, [new completion.CompletionItem("example")], function(_) {});
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
			var view = host.activeView();
			if (view == null) throw "popup fixture lost active document";
			if (phase == "popup-switch")
				host.openDocument(new editor.Document(null, "other", application.syntaxes));
			else if (phase == "popup-scroll" || phase == "popup-clipped") {
				if (popupScrollController == null || !popupScrollController.scrollBy(0.0, phase == "popup-clipped" ? 350.0 : 24.0))
					throw "popup fixture could not scroll retained editor";
			} else if (phase != "popup-edge" && phase != "popup-large")
				view.selection.restore(view.document.buffer, new BufferPosition(0, 7), new BufferPosition(0, 7));
		}
		var root = super.submit(frame);
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
				var stored:State<nativekit.ui.widgets.scroll.ScrollController> = ui.buildContext.existingState(editorNode.id);
				popupScrollController = stored.value;
			}
			if (frames == 6) {
				if (phase == "popup-switch" || phase == "popup-clipped") {
					if (host.isLanguagePopupVisible() || panel != null) throw "popup survived document switch";
				} else {
					var area = host.textInputArea();
					if (panel == null || panel.resolved == null || area == null) throw "missing resolved popup or caret";
					var bounds = panel.resolved;
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
		return root;
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
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit decoration smoke";
		options.width = 900;
		options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = 7;
		var status = DesktopUiHost.run(options, function(context) {
			return new DecorationSmokeApp(context, args[0], args[2]);
		});
		Native.shutdown();
		return status;
	}
}
