import haxe.io.Bytes;
import haxeon.ui.FontCollection;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;
import TerminalCursorSmoke.QuietBackend;

/** Echo arrives after input handling has returned, as it does through a PTY/RPC. */
class DelayedEchoBackend implements TerminalBackend {
	final pending:Array<TerminalEvent> = [];
	var offset:haxe.Int64 = 0;
	public function new() {}
	public function id():String return "delayed-echo";
	public function write(bytes:Bytes):Void {}
	public function output(text:String):Void {
		var bytes = Bytes.ofString(text);
		pending.push(TerminalEvent.output(offset, bytes));
		offset += bytes.length;
	}
	public function resize(columns:Int, rows:Int):Void pending.push(TerminalEvent.geometry(columns, rows));
	public function pollEvents(emit:TerminalEvent->Void):Void {
		for (event in pending) emit(event);
		pending.resize(0);
	}
	public function requestReplay(offset:haxe.Int64):Void throw "Unexpected replay";
	public function terminate(force:Bool):Void {}
	public function detach():Void {}
	public function close():Void {}
}

@:access(ui.TerminalPane)
class TerminalPollTests {
	static function defaultColors(fonts:FontCollection):Void {
		var backend = new QuietBackend();
		var emulator = terminalkit.Emulator.open(80, 24);
		emulator.feedString("KEEP");
		var palette = new ui.TerminalPalette(false);
		var pane = new ui.TerminalPane(new TerminalSession(backend, emulator), function() {}, palette, fonts);
		for (dark in [false, true, false]) {
			palette.setDark(dark);
			pane.poll();
			backend.replies = "";
			emulator.feedString("\033]10;?\033\\\033]11;?\033\\");
			pane.poll();
			var expected = dark
				? "\033]10;rgb:dcdc/e3e3/ecec\033\\\033]11;rgb:1717/1c1c/2323\033\\"
				: "\033]10;rgb:2020/2a2a/3636\033\\\033]11;rgb:ffff/ffff/ffff\033\\";
			if (backend.replies != expected) throw "Terminal pane reported colours from another theme";
			if (!StringTools.startsWith(emulator.rowText(0), "KEEP")) throw "Theme change erased terminal content";
		}
		pane.close();
	}

	public static function run(fonts:FontCollection):Void {
		defaultColors(fonts);
		var backend = new DelayedEchoBackend();
		var requests = 0;
		var pane = new ui.TerminalPane(new TerminalSession(backend, terminalkit.Emulator.open(80, 24)),
			function() { requests++; }, new ui.TerminalPalette(true), fonts);
		pane.poll();
		requests = 0;
		pane.poll();
		if (requests != 0) throw "Idle terminal requested a frame";
		// No key dispatch or other UI activity may be needed to display shell echo.
		backend.output("hello");
		pane.poll();
		if (requests == 0) throw "Delayed terminal echo did not request a frame";
		if (pane.cursorColumn != 5 || !StringTools.startsWith(pane.renderedRows[0].text, "hello"))
			throw "Delayed echo text and cursor disagree";
		requests = 0;
		backend.output("\x1b[2D");
		pane.poll();
		if (requests == 0 || pane.cursorColumn != 3) throw "Cursor-only output did not request a frame";
		// Several output chunks may arrive together during fast typing.
		requests = 0;
		backend.output("\x1b[2C");
		for (_ in 0...20) backend.output("x");
		pane.poll();
		if (requests == 0 || pane.cursorColumn != 25
			|| !StringTools.startsWith(pane.renderedRows[0].text, "helloxxxxxxxxxxxxxxxxxxxx"))
			throw "Batched echo left text or cursor behind";
		requests = 0;
		for (_ in 0...10) pane.poll();
		if (requests != 0) throw "Settled terminal kept requesting frames";
		pane.close();
	}
}
