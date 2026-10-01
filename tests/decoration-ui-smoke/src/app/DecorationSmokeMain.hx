package app;

import ui.ExosuitApp;
import LayoutFrame;
import nativekit.ui.host.DesktopUiHost;
import nativekit.ui.host.DesktopUiHostOptions;
import plugin.PluginDecorationKind;
import search.DocumentSearch;
import search.SearchOptions;
import editor.BufferSelection;
import editor.BufferPosition;
import platform.Native;

/** Warms the editor's retained layout before editing or clearing its decorations. */
class DecorationSmokeApp extends ExosuitApp {
	final phase:String;
	var frames = 0;

	public function new(context:nativekit.ui.host.DesktopUiHostContext, path:String, phase:String) {
		super(context.fonts, null, context, path);
		this.phase = phase;
		installMarks(0);
	}

	function installMarks(line:Int):Void {
		var document = host.activeDocument();
		if (document == null) throw "decoration fixture did not open";
		application.theme.searchMatch = 0xffff00ff;
		var registry = host.getPluginDecorations();
		registry.removeOwner("smoke");
		registry.add("smoke", "diagnostic", document, line, 6, 10, 0xff0000ff, WavyUnderline);
		host.setDocumentSearchMatches(DocumentSearch.find(document, "return", new SearchOptions()));
	}

	override public function submit(frame:LayoutFrame):nativekit.ui.core.RenderNode {
		frames++;
		if (frames == 4) {
			var document = host.activeDocument();
			if (document == null) throw "decoration fixture document disappeared";
			if (phase == "moved") {
				document.buffer.replaceRange(new BufferSelection(), new BufferPosition(0, 0), new BufferPosition(0, 0), "// inserted é🙂\n");
				installMarks(1);
			} else if (phase == "cleared") {
				host.getPluginDecorations().removeOwner("smoke");
				host.setDocumentSearchMatches([]);
			}
		}
		return super.submit(frame);
	}
}

/** Real renderer coverage for the EditorPane's public presentation providers. */
class DecorationSmokeMain {
	static function main():Int {
		var args = Sys.args();
		if (args.length != 3) throw "expected source path, capture directory and phase";
		var options = new DesktopUiHostOptions();
		options.title = "exosuit decoration smoke";
		options.width = 900;
		options.height = 600;
		options.captureDirectory = args[1];
		options.frameLimit = 7;
		var status = DesktopUiHost.run(options, function(context) {
			return new DecorationSmokeApp(context, args[0], args[2]);
		});
		Native.shutdown();
		return status;
	}
}
