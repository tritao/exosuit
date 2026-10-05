package app;

import ui.ExosuitApp;
import LayoutFrame;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostContext;
import nativekit.ui.host.DesktopUiHostOptions;

class RealLanguageUiApp extends ExosuitApp {
	public var completed(default, null):Bool = false;
	final desktopContext:DesktopUiHostContext;
	final deadline:Float;
	final repository:Bool;
	final original:String;
	final symbol:String;
	final renamed:String;
	var stage:Int = 0;
	var stageFrame:Int = 0;
	var frames:Int = 0;
	var declaration = new editor.BufferPosition(0, 0);
	var accepted:String = "";

	public function new(context:DesktopUiHostContext, project:String, repository:Bool) {
		super(context.fonts, null, context, project + (repository ? "/src/config/ApplicationPaths.hx" : "/Main.hx"));
		this.desktopContext = context;
		this.repository = repository;
		symbol = repository ? "slash" : "answer";
		renamed = repository ? "folderSeparator" : "result";
		var view = host.activeView();
		if (view == null) throw "real graphical language test lacks initial source";
		original = view.document.buffer.text;
		if (repository) view.replaceAllText(StringTools.replace(original, 'var slash = path.lastIndexOf("/")', 'var slash:Int = "wrong"'));
		deadline = Sys.time() + 90;
		application.openArgument(project);
	}

	function advance():Void { stage++; stageFrame = frames; Sys.println("real language UI stage " + stage); Sys.stdout().flush(); }
	function command(name:String):Void {
		if (!ui.commands.execute("exosuit.language:" + name)) throw "real graphical language command unavailable: " + name;
	}

	override public function submit(frame:LayoutFrame):RenderNode {
		frames++;
		if (Sys.time() > deadline) throw "real graphical language timeout at stage " + stage + ": " + application.language.statusLabel();
		var view = host.activeView(), service = application.language.client;
		if (view == null) throw "real graphical language test lost editor";
		if (application.language.statusLabel().indexOf("disabled after repeated failures") >= 0)
			throw "real graphical language startup failed: " + [for (problem in host.getProblems().values()) problem.message].join("; ");
		if (service != null && service.ready) {
			if (stage == 0 && service.diagnosticsFor(view.document).length > 0 && host.getProblems().values().length > 0) {
				view.replaceAllText(repository ? StringTools.replace(original, "slash >", "sl >") : "function main():Int { var answer = 42; return ans; }\n");
				var text = view.document.buffer.text;
				declaration = view.document.buffer.positionFromOffset(text.indexOf(symbol + " ="));
				var cursor = view.document.buffer.positionFromOffset(repository ? text.indexOf("sl >") + 2 : text.lastIndexOf("ans") + 3);
				view.restoreCursor(cursor.line, cursor.column);
				view.cursorChanged();
				advance();
			} else if (stage == 1 && frames > stageFrame) {
				command("complete"); advance();
			} else if (stage == 2 && host.isLanguagePopupVisible() && frames > stageFrame + 1) {
				ui.key(UiEventKind.KeyDown, UiKey.Tab);
				accepted = view.document.buffer.text;
				if ((repository ? accepted != original : accepted.indexOf("return answer;") < 0) || host.isLanguagePopupVisible()) throw "real graphical completion did not replace prefix";
				var cursor = view.document.buffer.positionFromOffset(repository ? accepted.indexOf("slash >") + 1 : accepted.lastIndexOf("answer") + 1);
				view.restoreCursor(cursor.line, cursor.column);
				command("go-to-definition"); advance();
			} else if (stage == 3 && view.cursorLine() == declaration.line && view.cursorColumn() == declaration.column) {
				command("rename-symbol"); advance();
			} else if (stage == 4 && host.isCommandViewActive() && frames > stageFrame + 1) {
				ui.text(UiEventKind.TextInput, renamed);
				ui.key(UiEventKind.KeyDown, UiKey.Enter); advance();
			} else if (stage == 5 && view.document.buffer.text.indexOf(repository ? "folderSeparator >" : "return result;") >= 0 && service.diagnosticsFor(view.document).length == 0) {
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
				Sys.println("PASS: real graphical diagnose, complete, definition, rename, undo/redo " + (repository ? "through repository unsaved overlays" : "and save"));
				desktopContext.requestClose();
			}
		}
		desktopContext.requestFrame();
		return super.submit(frame);
	}
}

class RealLanguageUiSmokeMain {
	static function main():Int {
		platform.Platform.startHeadless();
		var args = Sys.args();
		if (args.length < 1 || args.length > 2) throw "expected language project and optional repository mode";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit real language UI smoke";
		options.width = 900; options.height = 600;
		var app:Null<RealLanguageUiApp> = null;
		var status = DesktopUiHost.run(options, function(context) {
			app = new RealLanguageUiApp(context, args[0], args.length == 2 && args[1] == "repository");
			return app;
		});
		platform.Native.shutdown();
		if (status == 0 && (app == null || !app.completed)) throw "real language UI closed before acceptance";
		return status;
	}
}
