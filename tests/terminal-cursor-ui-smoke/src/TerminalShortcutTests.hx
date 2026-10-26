import haxeon.ui.LayoutFrame;
import haxeon.ui.core.Command;
import haxeon.ui.core.Shortcut;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import terminalsession.TerminalSession;
import TerminalCursorSmoke.QuietBackend;

/** Exercise the real focused terminal and dispatcher, including bytes sent to the PTY. */
class TerminalShortcutTests {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	public static function run(fonts:haxeon.ui.FontCollection):Void {
		var ui = new UiContext(null, fonts);
		var backend = new QuietBackend();
		var pane = new ui.TerminalPane(new TerminalSession(backend, terminalkit.Emulator.open(80, 24)),
			function() {}, new ui.TerminalPalette(true), fonts);
		var paletteRuns = 0, quickOpenRuns = 0, editorRuns = 0, scopedRuns = 0;
		var control = UiModifier.Control, chord = control | UiModifier.Shift;
		ui.commands.register(new Command("view.toggle-palette", "Palette", function() paletteRuns++, new Shortcut(UiKey.P, chord)));
		ui.commands.register(new Command("exosuit.files:open", "Quick Open", function() quickOpenRuns++, new Shortcut(UiKey.P, control)));
		// Editor commands must not act on an inactive document, even with identical modifiers.
		for (key in [UiKey.C, UiKey.D, UiKey.R, UiKey.Z])
			ui.commands.register(new Command("editor." + key, "Editor action", function() editorRuns++, new Shortcut(key, control)));
		ui.commands.register(new Command("editor.delete-line", "Delete line", function() editorRuns++, new Shortcut(UiKey.K, chord)));
		var overrides:Array<String> = [];
		var tab = new ui.UiTerminalTab("test", "Terminal", "/", pane);
		var view = new ui.TerminalTabView(tab, function() {}, function(_, _) {}, null,
			function(id) return ui.TerminalShortcutPolicy.allows(id, overrides));
		var root = ui.submit(view, new LayoutFrame(640, 400));
		require(ui.focus.focus(root.id), "Terminal shortcut fixture did not focus");
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.P, chord | UiModifier.CapsLock);
		ui.key(UiEventKind.KeyRepeat, UiKey.P, chord);
		ui.key(UiEventKind.KeyDown, UiKey.P, control);
		require(paletteRuns == 1 && quickOpenRuns == 1 && backend.replies == "", "Palette or Quick Open leaked to PTY or repeated");
		for (key in [UiKey.C, UiKey.D, UiKey.R, UiKey.Z]) ui.key(UiEventKind.KeyDown, key, control);
		ui.key(UiEventKind.KeyDown, UiKey.K, chord);
		require(backend.replies == "\x03\x04\x12\x1a\x0b" && editorRuns == 0, "Editor shortcuts stole shell input");
		// Rebinding to a plain Ctrl letter follows the command, not a modifier heuristic.
		backend.replies = "";
		ui.commands.setShortcuts("exosuit.files:open", [new Shortcut(UiKey.K, control)]);
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		ui.key(UiEventKind.KeyDown, UiKey.P, control);
		require(quickOpenRuns == 2 && backend.replies == "\x10", "Custom binding did not follow Quick Open");
		// Live removals accept either bridged or domain IDs; later additions win.
		overrides = ["-files:open"];
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(quickOpenRuns == 2 && backend.replies == "\x0b", "Removed command did not return to shell");
		overrides.push("exosuit.files:open");
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(quickOpenRuns == 3 && backend.replies == "", "Live override addition did not apply");
		ui.commands.register(new Command("scoped", "Scoped", function() scopedRuns++, new Shortcut(UiKey.K, control)), "terminal-test");
		root.commandScope = "terminal-test";
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(scopedRuns == 0 && quickOpenRuns == 3 && backend.replies == "\x0b", "Filtered scope exposed a lower-priority binding");
		overrides.push("scoped");
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(scopedRuns == 1 && quickOpenRuns == 3 && backend.replies == "", "Allowed focused scope lost priority");
		root.focusTrap = true;
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(scopedRuns == 1 && backend.replies == "\x0b", "Command escaped modal focus trap");
		root.focusTrap = false;
		root.commandScope = null;
		var disabledAttempts = 0;
		ui.commands.setShortcuts("exosuit.files:open", []);
		ui.commands.register(new Command("disabled", "Disabled", function() throw "Disabled command ran",
			new Shortcut(UiKey.K, control), function() { disabledAttempts++; return false; }));
		overrides.push("disabled");
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.K, control);
		require(disabledAttempts == 1 && backend.replies == "\x0b", "Disabled command did not fall back exactly once");
		// Terminal clipboard handling keeps its defaults; excluded editor commands cannot steal them.
		ui.commands.setShortcuts("editor." + UiKey.C, [new Shortcut(UiKey.C, chord)]);
		backend.replies = "";
		ui.key(UiEventKind.KeyDown, UiKey.C, chord);
		require(editorRuns == 0 && backend.replies == "", "Terminal copy chord escaped");
		var applicationRuns = 0;
		ui.commands.register(new Command("view.terminal", "Toggle terminal", function() applicationRuns++, new Shortcut(96, control)));
		ui.commands.register(new Command("view.layout-bottom", "Toggle panel", function() applicationRuns++, new Shortcut(UiKey.J, control | UiModifier.Alt)));
		ui.commands.register(new Command("preferences.open", "Settings", function() applicationRuns++, new Shortcut(UiKey.P, UiModifier.Super)));
		ui.commands.register(new Command("exosuit.root:switch-to-next-tab", "Next tab", function() applicationRuns++, new Shortcut(UiKey.Tab, control)));
		ui.commands.register(new Command("exosuit.root:switch-to-previous-tab", "Previous tab", function() applicationRuns++, new Shortcut(UiKey.Tab, chord)));
		ui.commands.register(new Command("exosuit.workbench:toggle-sidebar", "Sidebar", function() applicationRuns++, new Shortcut(UiKey.B, control)));
		ui.key(UiEventKind.KeyDown, 96, control);
		ui.key(UiEventKind.KeyDown, UiKey.J, control | UiModifier.Alt);
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Super);
		ui.key(UiEventKind.KeyUp, UiKey.P, UiModifier.Super);
		ui.key(UiEventKind.KeyDown, UiKey.Tab, control);
		ui.key(UiEventKind.KeyDown, UiKey.Tab, chord);
		ui.key(UiEventKind.KeyDown, UiKey.B, control);
		require(applicationRuns == 6 && backend.replies == "", "Application commands did not skip the shell");
		// Even an unconsumed key must not retry unrestricted command dispatch afterward.
		ui.commands.register(new Command("editor.function", "Editor function", function() editorRuns++, new Shortcut(UiKey.F12)));
		ui.key(UiEventKind.KeyDown, UiKey.F12);
		require(editorRuns == 0, "Unconsumed terminal key bypassed command filter");
		root.commandShortcutFilter = null;
		ui.key(UiEventKind.KeyDown, UiKey.F12);
		require(editorRuns == 1, "Default widget command routing changed");
		tab.dispose();
		ui.dispose();
	}
}
