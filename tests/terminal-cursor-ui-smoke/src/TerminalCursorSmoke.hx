import haxe.io.Bytes;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;

/** Deterministic terminal output without a shell, process or workspace daemon. */
class QuietBackend implements TerminalBackend {
	public var replies:String = "";
	final geometry:Array<TerminalEvent> = [];
	public function new() {}
	public function id():String return "cursor-fixture";
	public function write(bytes:Bytes):Void { replies += bytes.toString(); }
	public function resize(columns:Int, rows:Int):Void geometry.push(TerminalEvent.geometry(columns, rows));
	public function pollEvents(emit:TerminalEvent->Void):Void {
		for (event in geometry) emit(event);
		geometry.resize(0);
	}
	public function requestReplay(offset:haxe.Int64):Void {}
	public function terminate(force:Bool):Void {}
	public function detach():Void {}
	public function close():Void {}
}

@:access(ui.TerminalPane)
class CursorApp implements DesktopUiApplication {
	final ui:UiContext;
	final pane:ui.TerminalPane;
	final host:DesktopUiHostContext;
	final backend:QuietBackend;
	final mode:String;
	var unchangedRowRevision = -1;
	var frames = 0;

	public function new(host:DesktopUiHostContext, mode:String, dark:Bool) {
		this.host = host;
		this.mode = mode;
		ui = new UiContext(null, host.fonts);
		backend = new QuietBackend();
		var emulator = terminalkit.Emulator.open(80, 24);
		emulator.feedString("\x1b[?1004hprompt$ ");
		if (mode == "hidden") emulator.feedString("\x1b[?25l");
		pane = new ui.TerminalPane(new TerminalSession(backend, emulator), host.requestFrame,
			new ui.TerminalPalette(dark), host.fonts);
	}

	public function context():UiContext return ui;

	public function diagnosticState():Dynamic return {
		cursorX: 8.0 + pane.cursorColumn * pane.cellWidth,
		cursorY: 4.0 + pane.cursorRow * pane.rowHeight,
		cursorWidth: pane.cellWidth,
		cursorHeight: pane.rowHeight,
		focused: pane.focused,
		focusReports: backend.replies
	};

	public function submit(frame:LayoutFrame):RenderNode {
		pane.poll();
		var root = ui.submit(pane, frame);
		frames++;
		if (frames == 3) ui.focusWidget(root.id);
		if (frames == 4) unchangedRowRevision = pane.revisions[1];
		if (frames == 5 && (mode == "unfocused" || mode == "refocused" || mode == "hidden")) ui.clearFocus();
		if (frames == 5 && mode == "window-blur") ui.windowFocusLost();
		if (frames == 7 && mode == "refocused") ui.focusWidget(root.id);
		if (frames == 9 && pane.revisions[1] != unchangedRowRevision)
			throw "Focus change repainted an unrelated terminal row";
		host.requestFrame();
		return root;
	}

	public function dispose():Void {
		pane.close();
		ui.dispose();
	}
}

class TerminalCursorSmoke {
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "Expected capture directory, focus mode and theme";
		var options = new DesktopUiHostOptions();
		options.width = 360;
		options.height = 140;
		options.title = "Terminal cursor fixture";
		options.captureDirectory = args[0];
		options.frameLimit = 10;
		return DesktopUiHost.run(options, function(host) return new CursorApp(host, args[1], args[2] == "dark"));
	}
}
