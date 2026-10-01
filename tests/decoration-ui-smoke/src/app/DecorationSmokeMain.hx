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

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, path);
		this.phase = phase;
		installMarks(0);
		if (phase == "multi-selected" || phase == "multi-typed" || phase == "multi-pasted") {
			var view = host.activeView();
			if (view == null) throw "multi fixture has no view";
			host.getPluginDecorations().removeOwner("smoke");
			host.setDocumentSearchMatches([]);
			theme.textSelection = Color.fromBytes(0, 255, 0);
			theme.textCaret = Color.fromBytes(0, 255, 0);
			view.document.buffer.replaceAllText("é🙂 x\né🙂 y", view.selection);
			view.selection.restore(view.document.buffer, new BufferPosition(0, 3), new BufferPosition(0, 0));
			view.selection.addRange(view.document.buffer, new BufferPosition(1, 3), new BufferPosition(1, 0));
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
		if ((phase == "multi-selected" || phase == "multi-typed" || phase == "multi-pasted") && frames == 4) {
			var view = host.activeView();
			if (view == null) throw "multi fixture view disappeared";
			var node = findEditor(root, "editor:" + view.document.id);
			if (node == null) throw "multi fixture editor disappeared";
			ui.focusWidget(node.id);
			if (phase == "multi-pasted") {
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
		return root;
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
