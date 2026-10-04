package app;

import ui.ExosuitApp;
import ui.UiEditorTabs;
import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostOptions;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;

class WorkspaceSmokeApp extends ExosuitApp {
	final phase:String;
	final path:String;
	var frames = 0;
	var oldColumns = 0;
	var paletteCommand = "";

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, phase == "write" || phase == "keyboard" ? path : null,
			null, null, null, WorkspaceSmokeMain.createTerminal);
		this.phase = phase;
		this.path = path;
	}

	function require(value:Bool, message:String):Void { if (!value) throw message; }

	function palette(command:String):Void {
		paletteCommand = command;
		ui.key(UiEventKind.KeyDown, UiKey.P, UiModifier.Control | UiModifier.Shift);
	}

	override public function submit(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frames++;
		if (phase == "write") {
			if (frames == 3) {
				var first = host.activeView();
				if (first == null) throw "writer missing source";
				var text = "";
				for (_ in 0...100) text += "restart dirty text\n";
				first.document.buffer.replaceAllText(text, first.selection);
				require(host.splitActive(view.LayoutKind.Horizontal), "writer split failed");
				openTerminal();
				moveTerminalToEditor();
			}
			if (frames == 5) {
				var first = host.panes[0].tabs[0], second = host.panes[1].tabs[0];
				first.restoreCursor(10, 3); second.restoreCursor(14, 2);
				first.restoreScroll(0, 120); second.restoreScroll(0, 240);
				var terminal = host.allTerminalTabs()[0];
				oldColumns = terminal.panel.columns();
				require(oldColumns > 0 && terminal.panel.rows() > 0, "terminal has no grid");
				trace("PASS: split dirty document and editor terminal ready for shutdown");
			}
			if (frames == 6) moveTerminalToPanel();
			if (frames == 8) {
				require(host.allTerminalTabs()[0].panel.columns() > oldColumns, "terminal did not resize to wider panel");
				moveTerminalToEditor();
			}
			if (frames == 11) {
				require(host.allTerminalTabs()[0].panel.columns() == oldColumns, "terminal did not resize back to editor");
				require(WorkspaceSmokeMain.terminalStarts == 1, "resizing replaced terminal session");
				sys.io.File.saveContent(config.ConfigurationPaths.stateRoot() + "/expected-dock.txt", host.sessionLines()[0]);
				trace("PASS: terminal grid follows resolved viewport across transfers");
			}
		} else if (phase == "read" && frames == 5) {
			require(host.panes.length == 2, "restart lost panes");
			require(host.sessionLines()[0] == sys.io.File.getContent(config.ConfigurationPaths.stateRoot() + "/expected-dock.txt"),
				"restart changed dock layout");
			var first = host.panes[0].tabs[0], second = host.panes[1].tabs[0];
			require(first.document == second.document && first.selection != second.selection,
				"restart lost shared document or independent selections");
			require(first.document.buffer.text.indexOf("restart dirty text") == 0 && first.document.dirty,
				"restart lost dirty recovery");
			require(first.cursorLine() == 10 && first.cursorColumn() == 3 && second.cursorLine() == 14 && second.cursorColumn() == 2,
				"restart lost independent carets");
			require(first.scrollY() == 120 && second.scrollY() == 240, "restart lost scroll");
			require(host.activePane == host.panes[1] && UiEditorTabs.terminal(host.activeTab()) != null,
				"restart lost selected terminal");
			require(host.allTerminalTabs().length == 1 && WorkspaceSmokeMain.terminalStarts == 1,
				"restart did not recreate exactly one shell");
			require(host.allTerminalTabs()[0].panel.columns() > 0, "restored shell has no grid");
			trace("PASS: separate process restored split, dirty shared text, carets, scroll and terminal profile");
		} else if (phase == "legacy" && frames == 5) {
			var active = host.activeView();
			if (active == null) throw "legacy has no active document";
			require(host.panes.length == 1 && active != null && active.document.requirePath() == path,
				"legacy flat tabs did not reopen surviving document");
			require(active.cursorLine() == 0 && active.cursorColumn() == 3, "legacy caret lost");
			trace("PASS: legacy flat tabs restore while missing document is skipped");
		} else if ((phase == "corrupt" || phase == "missing" || phase == "invalid-dock") && frames == 5) {
			require(host.panes.length >= 1, "recovery has no usable editor pane");
			if (phase == "corrupt") require(sys.FileSystem.exists(config.ConfigurationPaths.session() + ".incompatible"),
				"corrupt session was not quarantined");
			if (phase == "invalid-dock") {
				var restored = host.activeView();
				require(restored != null && restored.document.requirePath() == path,
					"invalid dock snapshot lost valid document");
			}
			application.newDocument();
			var active = host.activeView();
			if (active == null) throw "recovery cannot create document";
			active.textInput("usable");
			require(active.document.buffer.text == "usable", "recovery cannot edit");
			trace("PASS: " + phase + " session leaves usable workspace");
		} else if (phase == "keyboard") {
			if (frames == 3) palette("root:split-right");
			if (frames == 4 || frames == 13) {
				ui.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
				ui.text(UiEventKind.TextInput, paletteCommand);
			}
			if (frames == 5 || frames == 14) ui.key(UiEventKind.KeyDown, UiKey.Enter);
			if (frames == 7) {
				require(host.panes.length == 2 && host.activePane == host.panes[1], "keyboard split failed");
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 8) {
				require(host.activePane == host.panes[0], "keyboard focus left failed");
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 9) {
				require(host.activePane == host.panes[1], "keyboard focus right failed");
				ui.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Control | UiModifier.Alt | UiModifier.Shift);
			}
			if (frames == 11) {
				require(host.activePane == host.panes[0] && host.panes[1].items.length == 0,
					"keyboard move did not deduplicate shared tab");
				ui.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Control | UiModifier.Alt);
			}
			if (frames == 12) palette("root:close-pane");
			if (frames == 16) {
				require(host.panes.length == 1 && host.activeView() != null, "keyboard close lost surviving document");
				trace("PASS: keyboard-only split, directional focus, tab move and pane close");
			}
		}
		return super.submit(frame);
	}
}

class WorkspaceSmokeMain {
	public static var terminalStarts = 0;
	public static function createTerminal(cwd:String, requestFrame:Void->Void, palette:ui.TerminalPalette):ui.TerminalPanel {
		var panel = ui.TerminalPane.open(cwd, requestFrame, palette);
		terminalStarts++;
		return panel;
	}
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit workspace acceptance";
		options.width = 900; options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = args[2] == "keyboard" ? 17 : args[2] == "write" ? 12 : 7;
		var status = DesktopUiHost.run(options, context -> new WorkspaceSmokeApp(context, args[0], args[2]));
		platform.Native.shutdown();
		return status;
	}
}
