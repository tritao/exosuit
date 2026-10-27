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
	final fonts:haxeon.ui.FontCollection;
	final mode:String;
	var unchangedRowRevision = -1;
	var frames = 0;

	public function new(host:DesktopUiHostContext, mode:String, dark:Bool) {
		this.host = host;
		this.mode = mode;
		ui = new UiContext(null, host.fonts);
		backend = new QuietBackend();
		var emulator = terminalkit.Emulator.open(80, 24);
		emulator.feedString("\x1b[?1004hWi.i prompt$ ");
		if (mode == "hidden") emulator.feedString("\x1b[?25l");
		// Match the browser: proportional UI default plus a separate monospace face.
		fonts = haxeon.ui.FontCollection.create();
		var fontDirectory = "haxeon/packages/ui/vendor/skribidi/example/data/";
		fonts.add(fontDirectory + "IBMPlexSans-Regular.ttf");
		fonts.add(fontDirectory + "IBMPlexMono-Regular.ttf", haxeon.ui.FontFamily.Monospace);
		if (mode == "system-symbols") fonts.addSystemFallbacks();
		else ui.TerminalSymbolFont.addTo(fonts);
		TerminalPollTests.run(fonts);
		TerminalGridTests.run(fonts);
		TerminalShortcutTests.run(fonts);
		TerminalPointerTests.run(fonts);
		TerminalSelectionTests.run(fonts);
		pane = new ui.TerminalPane(new TerminalSession(backend, emulator), host.requestFrame,
			new ui.TerminalPalette(dark), fonts);
		TerminalNameTests.run();
		if (mode == "symbols" || mode == "system-symbols") {
			emulator.feedString("\x1b[2J\x1b[H\x1b[?25l⠁⠂⠄⠈⠐⠠⡀⢀⣿\r\n⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏\r\n░▒▓█▁▂▃▄▅▆▇");
		}
		if (mode == "system-symbols") emulator.feedString("\x1b[2;1H🬀🬁🬂🬃🬄🬅🬆🬇🬈\x1b[4;1H⣿ ⣿  ⣿    ⣿ ASCII");
		if (mode == "colors") {
			emulator.feedString("\x1b[2J\x1b[H\x1b[31mRED RED\x1b[0m gap \x1b[31mRED\x1b[32mGREEN\x1b[0m"
				+ "\r\n\x1b[38;5;196mINDEXED\x1b[38;2;255;0;0m TRUECOLOR\x1b[0m"
				+ "\r\n\x1b[7mINVERSE\x1b[0m plain \x1b[31;7mINVERSE RED\x1b[0m"
				+ "\r\n\x1b[32m日本語 e\u0301 café λ\x1b[0m gap \x1b[34mBLUE\x1b[0m");
		}
		if (mode == "selection") {
			emulator.feedString("\r\n\x1b[32mGREEN\x1b[0m plain selected text\r\nsecond selected row");
			emulator.selectionStart(0, 1);
			emulator.selectionTarget(18, 2);
		}
	}

	public function context():UiContext return ui;

	public function diagnosticState():Dynamic return {
		cursorX: 8.0 + pane.cursorColumn * pane.cellWidth,
		cursorY: 4.0 + pane.cursorRow * pane.rowHeight,
		cursorWidth: pane.cellWidth,
		cursorHeight: pane.rowHeight,
		focused: pane.focused,
		lines: [for (row in pane.renderedRows) row.text],
		focusReports: backend.replies,
		cellWidth: pane.cellWidth,
		rowHeight: pane.rowHeight,
		selectionText: mode == "selection" ? pane.session.emulator.selectionText() : null,
		selectionColor: {red:pane.selectionColor.red,green:pane.selectionColor.green,blue:pane.selectionColor.blue,alpha:pane.selectionColor.alpha}
	};

	public function submit(frame:LayoutFrame):RenderNode {
		pane.poll();
		var root = ui.submit(pane, frame);
		var rowCache = Sys.getEnv("EXOSUIT_TERMINAL_ROW_CACHE");
		if (rowCache == "none" || rowCache == "raster") root.walk(function(node) {
			if (node.styleKey != null && StringTools.startsWith(node.styleKey, "terminal-row-"))
				node.cachePolicy = rowCache == "none" ? haxeon.ui.core.CachePolicy.None : haxeon.ui.core.CachePolicy.Raster;
		});
		frames++;
		if (frames == 3) ui.focusWidget(root.id);
		if (frames == 4) {
			unchangedRowRevision = pane.revisions[1];
			for (column in 0...14) {
				var caret = pane.renderedRows[0].layout.caret(new haxeon.ui.TextLayout.TextPosition(column, 0));
				if (Math.abs(caret.x - column * pane.cellWidth) > 0.1)
					throw "Terminal text and cursor grid disagree at column " + column;
			}
			if (mode == "symbols") for (row in 0...2) for (column in 0...10) {
				var caret = pane.renderedRows[row].layout.caret(new haxeon.ui.TextLayout.TextPosition(column, 0));
				if (Math.abs(caret.x - column * pane.cellWidth) > 0.1)
					throw "Terminal symbol fallback drifted from the cell grid";
			}
		}
		if (frames == 5 && (mode == "unfocused" || mode == "refocused" || mode == "hidden")) ui.clearFocus();
		if (frames == 5 && (mode == "window-blur" || mode == "window-refocused")) ui.windowFocusLost();
		if (frames == 7 && mode == "refocused") ui.focusWidget(root.id);
		if (frames == 7 && mode == "window-refocused") ui.windowFocusGained();
		if (frames == 9 && mode == "window-refocused" &&
			(!pane.focused || !ui.textInput.isOwner(root.id)))
			throw "Window activation did not restore terminal keyboard/text input ownership";
		if (frames == 9 && pane.revisions[1] != unchangedRowRevision)
			throw "Focus change repainted an unrelated terminal row";
		host.requestFrame();
		return root;
	}

	public function dispose():Void {
		pane.close();
		ui.dispose();
		fonts.dispose();
	}
}

class TerminalCursorSmoke {
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "Expected capture directory, focus mode and theme";
		if (args[1] == "row-reuse") return TerminalRowReuseSmoke.run(args[0], args[2] == "dark");
		if (args[1] == "async-echo") return TerminalAsyncEchoSmoke.run(args[0], args[2] == "dark");
		var options = new DesktopUiHostOptions();
		options.width = 360;
		options.height = 140;
		options.title = "Terminal cursor fixture";
		options.captureDirectory = args[0];
		options.frameLimit = 10;
		return DesktopUiHost.run(options, function(host) return new CursorApp(host, args[1], args[2] == "dark"));
	}
}
