package app;

import haxe.io.Bytes;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;

/** A backend whose next pollEvents fails once, as RpcTerminalBackend.pollEvents does when its terminal failed. */
private class FailingBackend implements TerminalBackend {
	public var armed = false;
	public var polls = 0;
	public var failures = 0;
	public function new() {}
	public function id():String return "failing";
	public var written = "";
	public function write(bytes:Bytes):Void { written += bytes.toString(); }
	public function resize(columns:Int, rows:Int):Void {}
	public function pollEvents(emit:TerminalEvent->Void):Void {
		polls++;
		if (armed) { armed = false; failures++; throw "terminal failed"; }
	}
	public function requestReplay(offset:haxe.Int64):Void {}
	public function terminate(force:Bool):Void {}
	public function detach():Void {}
	public function close():Void {}
}

/**
	Input runs in event handlers, where an exception ends the window. The terminal's failure that pollEvents raises while
	input is sent (a key the emulator encodes, a mouse report) must wait for the pane's next poll(), where TerminalTabs shows it.
**/
class TerminalInputFailureTests {
	static function require(ok:Bool, message:String):Void if (!ok) throw message;

	public static function run(fonts:haxeon.ui.FontCollection):Void {
		for (path in ["key", "mouse"]) {
			var backend = new FailingBackend();
			var session = new TerminalSession(backend, terminalkit.Emulator.open(80, 24), false);
			var pane = new ui.TerminalPane(session, function() {}, new ui.TerminalPalette(true), fonts);
			var context = new UiContext(null, fonts);
			var root:haxeon.ui.core.RenderNode = null;
			// The pane learns its size while the first frame is laid out; the retention check compares settled frames only.
			context.verifyRetentionEvery = 0;
			for (_ in 0...4) { pane.poll(); root = context.submit(pane, new LayoutFrame(640, 400)); }
			if (!context.focus.focus(root.id)) throw "the pane did not take focus";
			// The program asked for kitty's report-all-keys mode (so the emulator encodes keys) and for mouse reports.
			session.emulator.feedString("\x1b[>8u\x1b[?1000h\x1b[?1006h");
			pane.poll();
			backend.armed = true;
			var thrown:Null<String> = null;
			try {
				if (path == "key") for (key in [UiKey.Escape, UiKey.A, UiKey.Enter, UiKey.Up, UiKey.Tab, UiKey.Backspace, UiKey.Left, UiKey.Home, UiKey.Delete]) {
					context.key(UiEventKind.KeyDown, key);
					if (backend.failures > 0) break;
				} else {
					context.pointerDown(100.0, 100.0, 1);
					context.pointerUp(100.0, 100.0, 1);
				}
			} catch (e:Dynamic) thrown = Std.string(e);
			require(backend.failures == 1, path + ": the " + path + " input never reached pollEvents (" + backend.polls + " polls, wrote " + StringTools.replace(backend.written, "\x1b", "ESC") + "), so the test proves nothing");
			require(thrown == null, path + ": the failure ended the event handler: " + thrown);
			var surfaced:Null<String> = null;
			try pane.poll() catch (e:Dynamic) surfaced = Std.string(e);
			require(surfaced == "terminal failed", path + ": the failure did not wait for poll(): " + surfaced);
			var again:Null<String> = null;
			try pane.poll() catch (e:Dynamic) again = Std.string(e);
			require(again == null, path + ": the failure surfaced twice");
			context.dispose();
			pane.close();
		}
		trace("PASS: a terminal failure raised while input is sent waits for poll() and does not end the event handler");
	}
}
