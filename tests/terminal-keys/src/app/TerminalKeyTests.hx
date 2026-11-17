package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import terminalsession.TerminalSession;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;

/** Records what the pane writes, with no process behind it. */
class RecordingBackend implements TerminalBackend {
	public var replies:String = "";
	public function new() {}
	public function id():String return "key-fixture";
	public function write(bytes:haxe.io.Bytes):Void { replies += bytes.toString(); }
	public function resize(columns:Int, rows:Int):Void {}
	public function pollEvents(emit:TerminalEvent->Void):Void {}
	public function requestReplay(offset:haxe.Int64):Void {}
	public function terminate(force:Bool):Void {}
	public function detach():Void {}
	public function close():Void {}
}

/** Keys reach the PTY as xterm sends them, modifiers included: Ctrl+Left is a word jump in the program. */
@:access(ui.TerminalPane)
class TerminalKeyTests {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function show(text:String):String
		return StringTools.replace(StringTools.replace(text, "\x1b", "ESC"), "\x7f", "DEL");

	public static function run(fonts:haxeon.ui.FontCollection):Void {
		var shift = UiModifier.Shift, control = UiModifier.Control, alt = UiModifier.Alt;
		// Pure encoding: the parameter is 1 + Shift 1 + Alt 2 + Control 4.
		var cases:Array<{key:Int, modifiers:Int, bytes:String}> = [
			{key: UiKey.Left, modifiers: control, bytes: "\x1b[1;5D"},
			{key: UiKey.Right, modifiers: control, bytes: "\x1b[1;5C"},
			{key: UiKey.Up, modifiers: shift, bytes: "\x1b[1;2A"},
			{key: UiKey.Down, modifiers: alt, bytes: "\x1b[1;3B"},
			{key: UiKey.Left, modifiers: shift | alt, bytes: "\x1b[1;4D"},
			{key: UiKey.Left, modifiers: control | shift, bytes: "\x1b[1;6D"},
			{key: UiKey.Right, modifiers: control | alt, bytes: "\x1b[1;7C"},
			{key: UiKey.Right, modifiers: control | alt | shift, bytes: "\x1b[1;8C"},
			{key: UiKey.Home, modifiers: control, bytes: "\x1b[1;5H"},
			{key: UiKey.End, modifiers: shift, bytes: "\x1b[1;2F"},
			{key: UiKey.Delete, modifiers: control, bytes: "\x1b[3;5~"},
			{key: UiKey.PageUp, modifiers: shift, bytes: "\x1b[5;2~"},
			{key: UiKey.PageDown, modifiers: control | shift, bytes: "\x1b[6;6~"},
			{key: UiKey.Insert, modifiers: alt, bytes: "\x1b[2;3~"},
			{key: 290, modifiers: control, bytes: "\x1b[1;5P"},
			{key: 296, modifiers: shift, bytes: "\x1b[18;2~"},
			// Lock keys and Super do not change the encoding.
			{key: UiKey.Left, modifiers: control | UiModifier.CapsLock | UiModifier.NumLock, bytes: "\x1b[1;5D"},
			{key: UiKey.Left, modifiers: UiModifier.Super, bytes: "\x1b[D"},
			// Unmodified keys keep their plain sequences.
			{key: UiKey.Left, modifiers: 0, bytes: "\x1b[D"},
			{key: UiKey.Right, modifiers: 0, bytes: "\x1b[C"},
			{key: UiKey.Up, modifiers: 0, bytes: "\x1b[A"},
			{key: UiKey.Down, modifiers: 0, bytes: "\x1b[B"},
			{key: UiKey.Home, modifiers: 0, bytes: "\x1b[H"},
			{key: UiKey.End, modifiers: 0, bytes: "\x1b[F"},
			{key: UiKey.Delete, modifiers: 0, bytes: "\x1b[3~"},
			{key: UiKey.PageUp, modifiers: 0, bytes: "\x1b[5~"},
			{key: UiKey.PageDown, modifiers: 0, bytes: "\x1b[6~"},
			{key: UiKey.Insert, modifiers: 0, bytes: "\x1b[2~"},
			{key: 290, modifiers: 0, bytes: "\x1bOP"},
			{key: 301, modifiers: 0, bytes: "\x1b[24~"},
		];
		for (item in cases) {
			var actual = ui.TerminalPane.encodeKey(item.key, item.modifiers);
			require(actual == item.bytes, 'Key ${item.key} with modifiers ${item.modifiers} encoded as ${show(actual)}, expected ${show(item.bytes)}');
		}
		require(ui.TerminalPane.encodeKey(UiKey.A, control) == null, "A letter was encoded as a cursor key");
		// The emulator wants xterm-style modifier bits, not UiModifier bits.
		require(ui.TerminalPane.terminalModifiers(shift | control | alt | UiModifier.Super | UiModifier.CapsLock) == 1 | 4 | 8 | 16,
			"Modifier bits were not translated for the emulator");

		// Through the focused pane and dispatcher, in normal and application cursor mode.
		var backend = new RecordingBackend();
		var emulator = terminalkit.Emulator.open(80, 24);
		var fixture = new Fixture(new TerminalSession(backend, emulator), fonts);
		for (applicationCursor in [false, true]) {
			emulator.feedString(applicationCursor ? "\x1b[?1h" : "\x1b[?1l");
			backend.replies = "";
			fixture.key(UiKey.Left, control);
			fixture.key(UiKey.Right, control, UiEventKind.KeyRepeat);
			fixture.key(UiKey.Delete, control | shift);
			fixture.key(UiKey.Home, shift | alt);
			require(backend.replies == "\x1b[1;5D\x1b[1;5C\x1b[3;6~\x1b[1;4H",
				"Modified keys reached the PTY as " + show(backend.replies) + " (application cursor " + applicationCursor + ")");
		}
		// Ctrl+Backspace deletes a word, so it must differ from Backspace (DEL): BS, or a Win32 key record under DECSET 9001.
		emulator.feedString("\x1b[?9001l");
		backend.replies = "";
		fixture.key(UiKey.Backspace, control);
		require(backend.replies == "\x08", "Ctrl+Backspace reached the PTY as " + show(backend.replies) + ", expected BS");
		emulator.feedString("\x1b[?9001h");
		backend.replies = "";
		fixture.key(UiKey.Backspace, control);
		require(backend.replies == "\x1b[8;14;127;1;8;1_\x1b[8;14;127;0;8;1_",
			"Ctrl+Backspace in win32-input-mode reached the PTY as " + show(backend.replies));
		backend.replies = "";
		fixture.key(UiKey.Backspace, control | shift);
		require(backend.replies.indexOf("\x1b[8;14;127;1;8;1_") < 0, "Ctrl+Shift+Backspace was taken for Ctrl+Backspace");
		emulator.feedString("\x1b[?9001l");
		// Plain Backspace is DEL in every keyboard mode: BS would be read as Ctrl+Backspace and delete a word. Kitty's
		// disambiguate mode (Claude Code turns it on) keeps the legacy byte; report-all-keys mode sends CSI 127 ; 1 u.
		for (mode in [{flags: "\x1b[<u", bytes: "\x7f"}, {flags: "\x1b[>1u", bytes: "\x7f"}, {flags: "\x1b[>8u", bytes: "\x1b[127;1u"}]) {
			emulator.feedString(mode.flags);
			backend.replies = "";
			fixture.key(UiKey.Backspace, 0);
			require(backend.replies == mode.bytes,
				"Backspace after " + show(mode.flags) + " reached the PTY as " + show(backend.replies) + ", expected " + show(mode.bytes));
		}
		emulator.feedString("\x1b[<u\x1b[<u");
		fixture.dispose();
	}

	static function find(name:String):Null<String> {
		var windows = Sys.systemName() == "Windows";
		for (directory in (Sys.getEnv("PATH") == null ? "" : Sys.getEnv("PATH")).split(windows ? ";" : ":")) {
			if (directory.length == 0) continue;
			var path = haxe.io.Path.join([directory, windows ? name + ".exe" : name]);
			if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path)) return sys.FileSystem.fullPath(path);
		}
		return null;
	}

	/** Run a real child behind a pseudoterminal (ConPTY on Windows), press keys, and return what the child reported. */
	static function child(fonts:haxeon.ui.FontCollection, program:String, script:String, keys:Array<{key:Int, modifiers:Int}>):Array<String> {
		var runtime = haxeon.platform.Runtime.start();
		var session = new TerminalSession(terminalsession.LocalPtyBackend.spawn(
			new terminalsession.TerminalProfile(program, [script], Sys.getCwd()), 100, 30), terminalkit.Emulator.open(100, 30, 8));
		var fixture = new Fixture(session, fonts);
		var screen = function() {
			session.pollEvents();
			session.emulator.snapshot();
			return [for (row in 0...session.emulator.rows()) StringTools.rtrim(session.emulator.rowText(row))].filter(function(line) return line.length > 0);
		};
		var wait = function(count:Int) {
			var deadline = Sys.time() + 10;
			var lines = screen();
			while (lines.length < count && Sys.time() < deadline) { Sys.sleep(0.02); lines = screen(); }
			return lines;
		};
		var lines = wait(1);
		var ready = lines.length > 0 && lines[0].indexOf("READY") >= 0;
		for (index in 0...keys.length) {
			if (!ready) break;
			fixture.key(keys[index].key, keys[index].modifiers);
			lines = wait(index + 2);
		}
		session.write(haxe.io.Bytes.ofString("q"));
		Sys.sleep(0.3);
		lines = screen();
		fixture.dispose();
		runtime.dispose();
		require(ready, "Child never reported READY: " + lines.join(" | "));
		return lines.slice(1);
	}

	/**
		What a child sees through the PTY. On Windows ConPTY turns the bytes into console key events, which is what
		a native console program reads; Node (Claude Code) reads the same bytes as VT text.
	**/
	public static function runChildren(fonts:haxeon.ui.FontCollection, fixtures:String):Void {
		var control = UiModifier.Control, shift = UiModifier.Shift, alt = UiModifier.Alt;
		var keys = [
			{key: UiKey.Left, modifiers: control},
			{key: UiKey.Right, modifiers: control},
			{key: UiKey.Left, modifiers: shift},
			{key: UiKey.Left, modifiers: alt},
			{key: UiKey.Home, modifiers: control},
			{key: UiKey.Delete, modifiers: control},
			{key: UiKey.PageUp, modifiers: shift},
			{key: UiKey.Left, modifiers: 0},
		];
		var node = find("node");
		if (node != null) {
			var seen = child(fonts, node, fixtures + "/raw_keys.js", keys);
			var expected = ["1b5b313b3544", "1b5b313b3543", "1b5b313b3244", "1b5b313b3344", "1b5b313b3548", "1b5b333b357e", "1b5b353b327e", "1b5b44"];
			for (index in 0...expected.length)
				require(seen.length > index && seen[index] == "DATA " + expected[index],
					"Node child key " + index + " arrived as " + (seen.length > index ? seen[index] : "nothing") + ", expected " + expected[index]);
		} else Sys.println("SKIP: node is not on PATH");
		var python = find("python");
		if (Sys.systemName() == "Windows" && python != null) {
			var seen = child(fonts, python, fixtures + "/console_keys.py", keys);
			var expected = ["vk=37 ctrl=1 shift=0 alt=0", "vk=39 ctrl=1 shift=0 alt=0", "vk=37 ctrl=0 shift=1 alt=0", "vk=37 ctrl=0 shift=0 alt=1",
				"vk=36 ctrl=1 shift=0 alt=0", "vk=46 ctrl=1 shift=0 alt=0", "vk=33 ctrl=0 shift=1 alt=0", "vk=37 ctrl=0 shift=0 alt=0"];
			for (index in 0...expected.length)
				require(seen.length > index && StringTools.startsWith(seen[index], "KEY " + expected[index]),
					"Console key event " + index + " was " + (seen.length > index ? seen[index] : "missing") + ", expected " + expected[index]);
		} else Sys.println("SKIP: console key events need Windows and python on PATH");
	}
}

/** A focused terminal pane in a dispatcher, as in the editor. */
@:access(ui.TerminalPane)
private class Fixture {
	final context:UiContext;
	final tab:ui.UiTerminalTab;

	public function new(session:TerminalSession, fonts:haxeon.ui.FontCollection) {
		context = new UiContext(null, fonts);
		tab = new ui.UiTerminalTab("keys", "Terminal", "/", new ui.TerminalPane(session, function() {}, new ui.TerminalPalette(true), fonts));
		var view = new ui.TerminalTabView(tab, function() {}, function(_, _) {}, null,
			function(id) return ui.TerminalShortcutPolicy.allows(id, []));
		// The pane learns its size while the first frame is laid out and asks for more, as the app does (size, then focus); the
		// retention check (HAXEON_UI_VERIFY_RETENTION) compares settled frames only.
		var verify = context.verifyRetentionEvery;
		context.verifyRetentionEvery = 0;
		for (_ in 0...3) context.submit(view, new LayoutFrame(640, 400));
		context.verifyRetentionEvery = verify;
		var root = context.submit(view, new LayoutFrame(640, 400));
		if (!context.focus.focus(root.id)) throw "Terminal key fixture did not focus";
	}

	public function key(key:Int, modifiers:Int, ?kind:String):Void context.key(kind == null ? UiEventKind.KeyDown : kind, key, modifiers);

	public function dispose():Void {
		tab.dispose();
		context.dispose();
	}
}
