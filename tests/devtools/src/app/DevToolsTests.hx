package app;

import devtools.InspectionModel;
import devtools.InspectionAgent;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.host.*;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;

class DevToolsTests {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var args = Sys.args();
		if (args.length > 0 && (args[0] == "--fixture" || args[0] == "--idle-fixture")) {
			var options = new DesktopUiHostOptions(); options.title = "DevTools inspection fixture";
			options.width = 600; options.height = 400;
			options.continuousFrames = function() return args[0] != "--idle-fixture";
			if (args.length > 2) { options.captureDirectory = args[2]; options.captureSeconds = 9; }
			var count = args.length > 3 ? Std.parseInt(args[3]) : 1;
			var app:Null<InspectionFixture> = null;
			options.onFrameRendered = function() { if (app != null) app.agent.recordFrame(); };
			return DesktopUiHost.run(options, function(host) { app = new InspectionFixture(host, args[1], count); return app; });
		}
		var model = new InspectionModel();
		for (i in 0...300) model.addFrame({id:i});
		require(model.frames.length == 240 && model.frames[0].id == 60 && model.droppedFrames == 60, "Frame history is not bounded");
		model.update([{id:1, label:"old"}, {id:2, label:"keep"}]);
		var first = model.delta([], true);
		require(first.full == true && first.changed.length == 2 && first.removed.length == 0, "Full snapshot missing nodes");
		model.update([{id:1, label:"new"}, {id:3, label:"added"}]);
		var delta = model.delta(first.next, false);
		var removed:Array<Int> = delta.removed;
		require(delta.changed.length == 2 && removed.length == 1 && removed[0] == 2, "Delta lost a change or removal");
		var same = model.delta(delta.next, false);
		require(same.changed.length == 0 && same.removed.length == 0, "Unchanged tree produced a delta");
		var rows:Array<Dynamic> = [];
		for (i in 1...1100) rows.push({id:i});
		model.update(rows);
		require(model.nodes.length == 1000 && model.truncated, "Tree limit is not explicit");
		Sys.println("PASS: bounded frame history, full snapshots, changed/removed nodes, unchanged deltas, tree truncation");
		return 0;
	}
}

private class InspectionFixture implements DesktopUiApplication {
	final ui:UiContext;
	public final agent:InspectionAgent;
	final count:Int;
	final otherHub:workspace.transport.NativeRpcHub;
	public function new(host:DesktopUiHostContext, endpoint:String, count:Int) {
		ui = new UiContext(null, host.fonts);
		// A separate subsystem must not adopt/close this inspector's accepted transport.
		otherHub = new workspace.transport.NativeRpcHub(host.events);
		this.count = count;
		agent = new InspectionAgent(endpoint, host, ui);
		host.onPoll = agent.poll;
	}
	public function context():UiContext return ui;
	public function diagnosticState():Dynamic return {};
	public function dispose():Void { agent.dispose(); otherHub.dispose(); ui.dispose(); }
	public function submit(frame:LayoutFrame):RenderNode {
		var s = new LayoutStyle(); s.width = LayoutAxis.grow(); s.height = LayoutAxis.grow();
		var children = [new KeyedView("text", new Text("Inspect this target"))];
		for (i in 0...count) children.push(new KeyedView("button-" + i, new Button("Fixture action " + i, null, function() {})));
		return ui.submit(new Column("fixture", children, s), frame);
	}
}
