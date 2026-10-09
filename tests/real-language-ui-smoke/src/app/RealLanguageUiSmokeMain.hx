package app;

import ui.ExosuitApp;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;

class RealLanguageUiApp extends ExosuitApp {
	public var completed(default, null):Bool = false;
	final desktopContext:DesktopUiHostContext;
	final deadline:Float;
	final repository:Bool;
	final projectOwnership:Bool;
	final projectPath:String;
	var definitionChecked:Bool = false;
	final original:String;
	final symbol:String;
	final renamed:String;
	var stage:Int = 0;
	var stageFrame:Int = 0;
	var frames:Int = 0;
	var popupFrame:Int = -1;
	var declaration = new editor.BufferPosition(0, 0);
	var accepted:String = "";

	public function new(context:DesktopUiHostContext, project:String, mode:String) {
		super(context.fonts, null, context, project + (mode == "overlapping" || mode == "nested" ? "/graphical/src/ui/EditorMinimap.hx" : mode == "repository" ? "/src/config/ApplicationPaths.hx" : "/Main.hx"));
		this.desktopContext = context;
		this.repository = mode == "repository";
		this.projectOwnership = mode == "overlapping" || mode == "nested";
		this.projectPath = project;
		symbol = repository ? "slash" : "answer";
		renamed = repository ? "folderSeparator" : "result";
		var view = host.activeView();
		if (view == null) throw "real graphical language test lacks initial source";
		original = view.document.buffer.text;
		if (repository) view.replaceAllText(StringTools.replace(original, 'var slash = path.lastIndexOf("/")', 'var slash:Int = "wrong"'));
		deadline = Sys.time() + 90;
		application.openArgument(project);
		if (mode == "overlapping") {
			application.openArgument(project + "/src");
			application.openArgument(project + "/graphical");
			application.openArgument(project + "/graphical/src");
		}
	}

	function advance():Void { stage++; stageFrame = frames; popupFrame = -1; Sys.println("real language UI stage " + stage); Sys.stdout().flush(); }
	// Server callbacks can open an overlay immediately before submit. Let UIKit
	// build it and apply deferred focus before sending the next key.
	function popupReady(visible:Bool):Bool {
		if (!visible) { popupFrame = -1; return false; }
		if (popupFrame < 0) popupFrame = frames;
		return frames > popupFrame + 1;
	}
	function command(name:String):Void {
		if (!ui.commands.execute("exosuit.language:" + name)) throw "real graphical language command unavailable: " + name;
	}

	override public function submit(frame:LayoutFrame):RenderNode {
		if (completed) return super.submit(frame);
		requestFrame();
		frames++;
		var view = host.activeView(), service = application.language.client;
		if (Sys.time() > deadline) throw "real graphical language timeout at stage " + stage + ": " + application.language.statusLabel()
			+ "; document: " + (view == null ? "none" : view.document.path)
			+ "; notifications: " + [for (notification in host.getNotifications().entries) notification.message].join("; ")
			+ "; Problems: " + [for (problem in host.getProblems().values()) problem.message].join("; ");
		if (view == null) throw "real graphical language test lost editor";
		if (application.language.statusLabel().indexOf("disabled after repeated failures") >= 0)
			throw "real graphical language startup failed: " + [for (problem in host.getProblems().values()) problem.message].join("; ");
		if (projectOwnership && service != null && service.ready) {
			if (stage == 0 && service.hasReceivedDiagnostics(view.document) && service.semanticTokensFor(view.document) != null) {
				var snapshot = service.semanticTokensFor(view.document);
				var entity = view.document.buffer.positionFromOffset(original.indexOf("document:Document") + "document:".length);
				var offset = editor.EditorCoordinates.codepoint(view.document, entity);
				if (snapshot == null || [for (token in snapshot.tokens) if (token.start == offset && token.type == "class") token].length == 0)
					throw "real server did not classify Document as a class: " + (snapshot == null ? "no snapshot" : [for (token in snapshot.tokens) if (token.start >= offset - 12 && token.start <= offset + 12) token.type + "@" + token.start].join(", "));
				var pane:ui.EditorPane = @:privateAccess editorPanes.get(view.id);
				var painted:Null<language.LanguageSemanticSnapshot> = @:privateAccess pane.semanticSnapshot;
				if (painted != snapshot) return super.submit(frame);
				var ranges = @:privateAccess pane.provideForeground(offset, offset + "Document".length);
				var palette:style.Theme = @:privateAccess pane.editorTheme;
				var expected = palette.semanticColor("class", []);
				var actual = ranges.length == 0 ? null : ranges[0].color;
				var expectedColor = expected == null ? null : new haxeon.ui.Color(((expected >>> 24) & 255) / 255.0, ((expected >>> 16) & 255) / 255.0, ((expected >>> 8) & 255) / 255.0, (expected & 255) / 255.0);
				if (actual == null || expectedColor == null || actual.red != expectedColor.red || actual.green != expectedColor.green || actual.blue != expectedColor.blue) throw "semantic class color did not reach renderer";
				if (ranges.length != 1 || ranges[0].start != offset || ranges[0].end != offset + "Document".length)
					throw "semantic class range did not reach editor renderer";
				var position = view.document.buffer.positionFromOffset(original.indexOf("document:Document") + "document:".length + 2);
				if (!service.requestDefinition(view.document, position, Sys.time(), locations -> {
					if (locations.length == 0 || locations[0].path != projectPath + "/src/editor/Document.hx")
						throw "EditorMinimap dependency definition was not resolved: " + [for (location in locations) location.path].join(", ")
						+ "; diagnostics: " + [for (diagnostic in service.diagnosticsFor(view.document)) diagnostic.message].join("; ");
					definitionChecked = true;
				})) throw "project ownership definition request rejected";
				advance();
			} else if (stage == 1 && definitionChecked) {
				var position = view.document.buffer.positionFromOffset(original.indexOf("document:Document") + "document:".length + 2);
				view.restoreCursor(position.line, position.column); view.cursorChanged();
				ui.key(UiEventKind.KeyDown, UiKey.F12); advance();
			} else if (stage == 2 && frames > stageFrame + 2 && view.document.path == projectPath + "/src/editor/Document.hx") {
				if (view.document.buffer.line(view.cursorLine()).indexOf("class Document") < 0) throw "definition cursor missed declaration";
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 3 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx") {
				var position = view.document.buffer.positionFromOffset(original.indexOf("document:Document") + "document:".length + 2);
				if (view.cursorLine() != position.line || view.cursorColumn() != position.column) throw "Go Back lost origin cursor";
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Alt); advance();
			} else if (stage == 4 && frames > stageFrame + 2 && view.document.path == projectPath + "/src/editor/Document.hx") {
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 5 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx") {
				advance();
			} else if (stage == 6 && frames > stageFrame + 2) {
				var area = host.textInputArea(); if (area == null) throw "definition pointer lacks caret geometry";
				var pane:ui.EditorPane = @:privateAccess editorPanes.get(view.id);
				var before = view.cursorColumn();
				ui.pointerMove(area.x + 2, area.y + area.height / 2, UiModifier.Control);
				var underlined = @:privateAccess pane.provideDecorations(0, view.document.buffer.document.codepointCount);
				var found = false;
				for (decoration in underlined) if (decoration.kind == haxeon.ui.widgets.text.TextDecorationKind.Underline) found = true;
				if (!found || view.cursorColumn() != before) throw "Ctrl-hover failed to underline without moving caret";
				var position = view.document.buffer.positionFromOffset(original.indexOf("document:Document") + "document:".length);
				var expected = editor.EditorCoordinates.codepoint(view.document, position);
				for (decoration in underlined) if (decoration.kind == haxeon.ui.widgets.text.TextDecorationKind.Underline &&
					(decoration.start != expected || decoration.end != expected + "Document".length)) throw "Ctrl-hover underlined wrong symbol range";
				ui.key(UiEventKind.KeyUp, 341, 0);
				var cleared = @:privateAccess pane.provideDecorations(0, view.document.buffer.document.codepointCount);
				for (decoration in cleared) if (decoration.kind == haxeon.ui.widgets.text.TextDecorationKind.Underline) throw "Ctrl release retained underline";
				ui.key(UiEventKind.KeyDown, 341, UiModifier.Control);
				var stationary = @:privateAccess pane.provideDecorations(0, view.document.buffer.document.codepointCount);
				var restored = false;
				for (decoration in stationary) if (decoration.kind == haxeon.ui.widgets.text.TextDecorationKind.Underline) restored = true;
				if (!restored) throw "Stationary Ctrl press did not restore underline";
				ui.pointerMove(0, 0, UiModifier.Control);
				var left = @:privateAccess pane.provideDecorations(0, view.document.buffer.document.codepointCount);
				for (decoration in left) if (decoration.kind == haxeon.ui.widgets.text.TextDecorationKind.Underline) throw "Pointer leave retained underline";
				ui.pointerMove(area.x + 2, area.y + area.height / 2, UiModifier.Control);
				ui.pointerDown(area.x + 2, area.y + area.height / 2, 0, UiModifier.Control);
				ui.pointerUp(area.x + 2, area.y + area.height / 2, 0, UiModifier.Control); advance();
			} else if (stage == 7 && frames > stageFrame + 2 && view.document.path == projectPath + "/src/editor/Document.hx") {
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 8 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx" && frames > stageFrame + 2) {
				var area = host.textInputArea(); if (area == null) throw "context menu lacks caret geometry";
				ui.pointerDown(area.x + 2, area.y + area.height / 2, 1);
				ui.pointerUp(area.x + 2, area.y + area.height / 2, 1); advance();
			} else if (stage == 9 && frames > stageFrame + 2) {
				var entry:Null<RenderNode> = null;
				ui.root.walk(node -> { if (node.semantics != null && node.semantics.label == "Go to Definition" && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.MenuItem) entry = node; });
				if (entry == null) throw "editor context menu lacks Go to Definition";
				var bounds = entry.resolved.viewportBounds();
				ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
				ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0); advance();
			} else if (stage == 10 && frames > stageFrame + 2 && view.document.path == projectPath + "/src/editor/Document.hx") {
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 11 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx") {
				view.replaceAllText(original + "\nclass NativeDefinitionProbe { static function take(image:haxeon.platform.GraphicsImageRef, surface:nativekit.ffi.NativeKitTypes.SurfaceHandle):Void {} }\n");
				if (service.semanticTokensFor(view.document) != null) throw "editing retained stale semantic colors";
				var position = view.document.buffer.positionFromOffset(view.document.buffer.text.lastIndexOf("GraphicsImageRef") + 2);
				view.restoreCursor(position.line, position.column); view.cursorChanged(); advance();
			} else if (stage == 12 && frames > stageFrame + 2) {
				ui.key(UiEventKind.KeyDown, UiKey.F12); advance();
			} else if (stage == 13 && frames > stageFrame + 2 && view.document.path == projectPath + "/haxeon/packages/platform/src/haxeon/platform/GraphicsImageRef.hx") {
				if (view.document.buffer.line(view.cursorLine()).indexOf("GraphicsImageRef") < 0) throw "native wrapper definition missed declaration";
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 14 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx") {
				var position = view.document.buffer.positionFromOffset(view.document.buffer.text.lastIndexOf("SurfaceHandle") + 2);
				view.restoreCursor(position.line, position.column); view.cursorChanged(); advance();
			} else if (stage == 15 && frames > stageFrame + 2) {
				ui.key(UiEventKind.KeyDown, UiKey.F12); advance();
			} else if (stage == 16 && view.document.path == projectPath + "/haxeon/packages/platform/bindings/nativekit.hxi") {
				if (view.document.buffer.line(view.cursorLine()).indexOf("handle nk_surface") < 0) throw "FFI handle definition missed ABI declaration";
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt); advance();
			} else if (stage == 17 && view.document.path == projectPath + "/graphical/src/ui/EditorMinimap.hx") {
				view.undo(); advance();
			} else if (stage == 18 && service.diagnosticsFor(view.document).length == 0 && service.semanticTokensFor(view.document) != null) {
				for (diagnostic in service.diagnosticsFor(view.document))
					if (diagnostic.message.indexOf("Missing module") >= 0) throw "false import diagnostic: " + diagnostic.message;
				if (view.document.buffer.text != original || sys.io.File.getContent(view.document.requirePath()) != original)
					throw "project ownership test changed repository source";
				completed = true;
				Sys.println("PASS: EditorMinimap imports, F12/Ctrl+click/context-menu definitions, native wrapper, projected FFI handle and back/forward history with " + (application.workspace.projects.length > 1 ? "overlapping source folders" : "a nested project under the repository root"));
				desktopContext.onCloseRequested = function(close) close();
				desktopContext.requestClose();
			}
		} else if (service != null && service.ready) {
			if (stage == 0 && service.diagnosticsFor(view.document).length > 0 && host.getProblems().values().length > 0) {
				view.replaceAllText(repository ? StringTools.replace(original, "slash >", "sl >") : "function main():Int { var answer = 42; return ans; }\n");
				var text = view.document.buffer.text;
				declaration = view.document.buffer.positionFromOffset(text.indexOf(symbol + " ="));
				var cursor = view.document.buffer.positionFromOffset(repository ? text.indexOf("sl >") + 2 : text.lastIndexOf("ans") + 3);
				view.restoreCursor(cursor.line, cursor.column);
				view.cursorChanged();
				advance();
			} else if (stage == 1 && frames > stageFrame && [for (diagnostic in service.diagnosticsFor(view.document)) if (diagnostic.message.indexOf(repository ? '"sl"' : '"ans"') >= 0) diagnostic].length > 0) {
				ui.key(UiEventKind.KeyDown, UiKey.Space, UiModifier.Control); advance();
			} else if (stage == 2 && popupReady(host.isLanguagePopupVisible())) {
				ui.key(UiEventKind.KeyDown, UiKey.Tab);
				accepted = view.document.buffer.text;
				if ((repository ? accepted != original : accepted.indexOf("return answer;") < 0) || host.isLanguagePopupVisible()) throw "real graphical completion did not replace prefix: popup=" + host.isLanguagePopupVisible() + ", text=" + accepted;
				var cursor = view.document.buffer.positionFromOffset(repository ? accepted.indexOf("slash >") + 1 : accepted.lastIndexOf("answer") + 1);
				view.restoreCursor(cursor.line, cursor.column);
				ui.key(UiEventKind.KeyDown, UiKey.G, UiModifier.Control | UiModifier.Alt); advance();
			} else if (stage == 3 && view.cursorLine() == declaration.line && view.cursorColumn() == declaration.column) {
				ui.key(UiEventKind.KeyDown, UiKey.Space, UiModifier.Control | UiModifier.Alt); advance();
			} else if (stage == 4 && popupReady(host.isLanguagePopupVisible())) {
				ui.key(UiEventKind.KeyDown, UiKey.Escape);
				if (host.isLanguagePopupVisible() || view.document.buffer.text != accepted)
					throw "real graphical hover did not dismiss without editing";
				command("rename-symbol"); advance();
			} else if (stage == 5 && popupReady(host.isCommandViewActive())) {
				ui.text(UiEventKind.TextInput, renamed);
				ui.key(UiEventKind.KeyDown, UiKey.Enter); advance();
			} else if (stage == 6 && view.document.buffer.text.indexOf(repository ? "folderSeparator >" : "return result;") >= 0 && service.diagnosticsFor(view.document).length == 0 && [for (problem in host.getProblems().values()) if (problem.path == view.document.requirePath()) problem].length == 0) {
				if (view.document.buffer.text.indexOf("var " + renamed + " =") < 0 || host.isCommandViewActive()) throw "real graphical rename was incomplete";
				view.undo();
				if (view.document.buffer.text != accepted) throw "real graphical rename did not undo transactionally";
				view.redo();
				if (repository) {
					view.undo();
					if (view.document.buffer.text != original || sys.io.File.getContent(view.document.requirePath()) != original)
						throw "real graphical repository test changed checkout content";
				} else if (!view.document.save()) throw "real graphical language fixture did not save";
				completed = true;
				Sys.println("PASS: real graphical diagnose, keyboard completion, definition, hover/dismiss, rename, clear Problems, undo/redo " + (repository ? "through repository unsaved overlays" : "and save"));
				// Repository overlays are deliberately unsaved; assertions above verify
				// their restoration. Do not open the interactive dirty-close dialog.
				desktopContext.onCloseRequested = function(close) close();
				desktopContext.requestClose();
			}
		}
		desktopContext.requestFrame();
		return super.submit(frame);
	}
}

class RealLanguageUiSmokeMain {
	static function main():Int {

		var args = Sys.args();
		if (args.length < 1 || args.length > 2) throw "expected language project and optional repository mode";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit real language UI smoke";
		options.width = 900; options.height = 600;
		var app:Null<RealLanguageUiApp> = null;
		var status = DesktopUiHost.run(options, function(context) {
			app = new RealLanguageUiApp(context, args[0], args.length == 2 ? args[1] : "fixture");
			return app;
		});

		if (status == 0 && (app == null || !app.completed)) throw "real language UI closed before acceptance";
		return status;
	}
}
