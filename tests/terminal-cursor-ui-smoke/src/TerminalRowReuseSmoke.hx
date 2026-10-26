import haxeon.ui.FontCollection;
import haxeon.ui.FontFamily;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import terminalsession.TerminalSession;
import TerminalCursorSmoke.QuietBackend;

/** Compare moving retained rows with a fully rebuilt reference in every frame. */
@:access(ui.TerminalPane)
class RowReuseApp implements DesktopUiApplication {
	public var frame = 0;
	final ui:UiContext;
	final panes:Array<ui.TerminalPane> = [];
	final fonts:FontCollection;
	final dark:Bool;
	var checks = 0;
	final rowWidgets:Map<Int, Bool> = new Map();
	function rowWidgetCount():Int { var count = 0; for (_ in rowWidgets.keys()) count++; return count; }

	public function new(host:DesktopUiHostContext, dark:Bool) {
		this.dark = dark;
		ui = new UiContext(null, host.fonts);
		fonts = FontCollection.create();
		fonts.add("haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexMono-Regular.ttf", FontFamily.Monospace);
		for (_ in 0...2) panes.push(new ui.TerminalPane(
			new TerminalSession(new QuietBackend(), terminalkit.Emulator.open(80, 24)),
			host.requestFrame, new ui.TerminalPalette(dark), fonts));
	}
	public function context():UiContext return ui;
	public function diagnosticState():Dynamic return {rowReuseChecks: checks, frames: frame, stableRowWidgets: rowWidgetCount()};

	function scenario(pane:ui.TerminalPane):Void {
		var emulator = pane.session.emulator;
		switch frame {
			case 4:
				emulator.feedString("\x1b[2J\x1b[H\x1b[?25l");
				for (line in 0...6) emulator.feedString((line == 0 ? "" : "\r\n")
					+ "\x1b[" + (31 + line) + "mrow " + line + " 日本語 e\u0301 café\x1b[0m");
			case 5, 6, 7, 8, 9: emulator.feedString("\r\n\x1b[32mnew " + frame + " 界 e\u0301\x1b[0m");
			case 10: emulator.scrollback(2);
			case 11: emulator.scrollback(4);
			case 12: emulator.scrollback(1);
			case 13: emulator.scrollback(0);
			case 14: emulator.feedString("\x1b[2;1H\x1b[35mEDITED LINE\x1b[0m\x1b[K");
			case 15: emulator.selectionStart(0, 0); emulator.selectionTarget(9, 2);
			case 16: emulator.selectionClear();
			case 17: pane.palette.setDark(!dark);
			case 18: pane.palette.fontSize = 16;
			case 19: pane.palette.fontSize = 14;
			case 20: emulator.feedString("\x1b[?1049h\x1b[H\x1b[36mALTERNATE 日本語\x1b[0m");
			case 21: emulator.feedString("\x1b[?1049l");
			case 22: emulator.resize(34, 5);
			case 23: emulator.resize(40, 6);
			case 24: emulator.feedString("\x1b[?25h\x1b[2;3H");
			case 26: emulator.scrollback(1);
			case 27: emulator.scrollback(0);
			default:
		}
	}

	public function submit(layout:LayoutFrame):RenderNode {
		var previous = frame >= 5 && frame <= 9 ? panes[0].renderedRows[1].layout : null;
		for (pane in panes) { scenario(pane); pane.poll(); }
		if (previous != null && panes[0].renderedRows[0].layout != previous)
			throw "Scrolling rebuilt a retained line instead of moving its layout";
		// The reference ignores row matching and rebuilds all text and colors.
		panes[1].refreshRows(true);
		for (pane in panes) {
			var owned = new haxe.ds.ObjectMap<haxeon.ui.TextLayout, Bool>();
			if (pane.renderedRows.length != pane.rows()) throw "Row storage escaped viewport bounds";
			for (row in 0...pane.rows()) {
				var entry = pane.renderedRows[row];
				if (owned.exists(entry.layout)) throw "Two rows share a mutable layout";
				owned.set(entry.layout, true);
				if (entry.text != pane.session.emulator.rowText(row)) throw "Stale rendered terminal text";
			}
		}
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		var root = ui.submit(new Stack("row-reuse-comparison", [
			new StackChild("retained", panes[0], 0.0, 0.0, 0, LayoutAxis.fixed(360), LayoutAxis.grow()),
			new StackChild("reference", panes[1], 360.0, 0.0, 0, LayoutAxis.fixed(360), LayoutAxis.grow())
		], style), layout);
		if (frame >= 4 && frame <= 9) {
			root.walk(function(node) {
				if (node.styleKey != null && StringTools.startsWith(node.styleKey, "terminal-row-")
					&& node.globalBounds().x < 360) rowWidgets.set(node.id.value, true);
			});
			if (rowWidgetCount() != 6) throw "Scrolling grew row widget identities beyond viewport storage";
		}
		// Both panes need the same cursor presentation despite the single UI focus owner.
		for (pane in panes) pane.setFocused(frame != 24 && frame != 25);
		if (frame >= 4) checks++;
		frame++;
		return root;
	}
	public function dispose():Void {
		for (pane in panes) pane.close();
		ui.dispose(); fonts.dispose();
	}
}

class TerminalRowReuseSmoke {
	public static function run(directory:String, dark:Bool):Int {
		if (!sys.FileSystem.exists(directory)) sys.FileSystem.createDirectory(directory);
		var options = new DesktopUiHostOptions();
		options.title = "Terminal row reuse fixture";
		options.width = 720; options.height = 140;
		options.captureDirectory = directory;
		options.frameLimit = 29;
		var app:RowReuseApp = null;
		options.onFrameRendered = function() {
			if (app != null && app.frame >= 5 && Sys.command("import", ["-window", options.title,
				directory + "/comparison-" + app.frame + ".png"]) != 0) throw "Row comparison capture failed";
		};
		return DesktopUiHost.run(options, function(host) { app = new RowReuseApp(host, dark); return app; });
	}
}
