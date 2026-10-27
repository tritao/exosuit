import haxeon.ui.LayoutFrame;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.widgets.text.Text;
import ui.ExosuitApp;
import ui.TerminalPanel;
import ui.UiTerminalTab;

private class CountingTerminal implements TerminalPanel {
	public var polls = 0;
	public function new() {}
	public function poll():Void { polls++; }
	public function close():Void {}
	public function terminate(force:Bool):Void {}
	public function status():String return "running";
	public function workspaceName():Null<String> return null;
	public function columns():Int return 80;
	public function rows():Int return 24;
	public function build(context:BuildContext):RenderNode return new Text("Polling fixture").build(context);
}

@:access(ui.ExosuitApp)
private class PollingApp extends ExosuitApp {
	var checked = false;
	final fixtureHost:DesktopUiHostContext;
	public function new(context:DesktopUiHostContext) {
		super(context.fonts, null, context);
		fixtureHost = context;
	}
	override public function submit(frame:LayoutFrame):RenderNode {
		var root = super.submit(frame);
		if (!checked) {
			var panel = new CountingTerminal();
			var terminal = new UiTerminalTab("poll-test", "Poll test", ".", panel);
			host.panelTerminals.push(terminal);
			// Maintenance is deliberately not due, even between these two calls.
			nextBackgroundPoll = Sys.time() + 3600;
			pollBackground();
			pollBackground();
			if (panel.polls != 2) throw "Terminal IO waited for background maintenance";
			terminal.dispose();
			pollBackground();
			if (panel.polls != 2) throw "Disposed terminal was polled";
			host.panelTerminals.remove(terminal);
			checked = true;
			Sys.println("PASS: terminal IO runs on each host poll while maintenance is throttled; disposed sessions are skipped");
		}
		fixtureHost.requestFrame();
		return root;
	}
}

class TerminalPollingSmoke {
	static function main():Int {
		var options = new DesktopUiHostOptions();
		options.title = "Terminal polling regression";
		options.captureDirectory = Sys.args()[0];
		options.frameLimit = 3;
		return DesktopUiHost.run(options, function(context) return new PollingApp(context));
	}
}
