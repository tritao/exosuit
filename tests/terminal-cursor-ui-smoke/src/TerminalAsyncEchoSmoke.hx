import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import terminalsession.TerminalSession;
import TerminalPollTests.DelayedEchoBackend;

/** No continuous frame requests: delayed output must wake the real host. */
@:access(ui.TerminalPane)
class TerminalAsyncEchoSmoke implements DesktopUiApplication {
	final ui:UiContext;
	final pane:ui.TerminalPane;
	final backend:DelayedEchoBackend;
	final host:DesktopUiHostContext;
	final started:Float;
	var nextOutput:Float;
	var batches = 0;
	var renderedBatches = 0;
	var renderedColumn = -1;
	var renderedText = "";
	var outputAt = 0.0;
	final echoToSubmitMs:Array<Float> = [];

	public function new(host:DesktopUiHostContext, dark:Bool) {
		this.host = host;
		ui = new UiContext(null, host.fonts);
		backend = new DelayedEchoBackend();
		pane = new ui.TerminalPane(new TerminalSession(backend, terminalkit.Emulator.open(80, 24)),
			host.requestFrame, new ui.TerminalPalette(dark));
		started = Sys.time();
		nextOutput = started + 0.3;
		host.onPoll = function() {
			var now = Sys.time();
			if (batches < 10 && now >= nextOutput) {
				// Several chunks in one host tick, then a pause with no new input.
				for (_ in 0...3) backend.output("x");
				batches++;
				outputAt = now;
				nextOutput = now + 0.035;
			}
			pane.poll();
		};
	}
	public function context():UiContext return ui;
	public function diagnosticState():Dynamic {
		if (batches != 10 || renderedBatches != 10 || renderedColumn != 30
			|| StringTools.rtrim(renderedText) != "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
			throw "Asynchronous echo did not reach a rendered frame: " + renderedBatches + "/" + batches;
		return {batches: batches, renderedBatches: renderedBatches, renderedColumn: renderedColumn,
			echoToSubmitMs: echoToSubmitMs, cursorX: 8.0 + renderedColumn * pane.cellWidth,
			cursorY: 4.0, cursorWidth: pane.cellWidth, cursorHeight: pane.rowHeight};
	}
	public function submit(frame:LayoutFrame):RenderNode {
		var node = ui.submit(pane, frame);
		if (!pane.focused) ui.focusWidget(node.id);
		if (renderedBatches != batches) echoToSubmitMs.push((Sys.time() - outputAt) * 1000);
		renderedBatches = batches;
		renderedColumn = pane.cursorColumn;
		renderedText = pane.renderedRows[0].text;
		return node;
	}
	public function dispose():Void {
		host.onPoll = null;
		pane.close();
		ui.dispose();
	}
	public static function run(directory:String, dark:Bool):Int {
		var options = new DesktopUiHostOptions();
		options.width = 360;
		options.height = 140;
		options.title = "Terminal asynchronous echo fixture";
		options.captureDirectory = directory;
		options.captureSeconds = 1.5;
		return DesktopUiHost.run(options, function(host) return new TerminalAsyncEchoSmoke(host, dark));
	}
}
