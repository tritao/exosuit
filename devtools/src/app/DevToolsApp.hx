package app;

import devtools.InspectionClient;
import haxeon.ui.*;
import haxeon.ui.core.*;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;

/** Standalone viewer: no target rendering or event processing takes place in this process. */
class DevToolsApp implements DesktopUiApplication {
	final ui:UiContext;
	final host:DesktopUiHostContext;
	final client:InspectionClient;
	final profiler:Null<devtools.ProfilerProcess>;
	final capturePath:String;
	final profileCapture:String;
	var profilerRevision = -1;
	var seenRevision = -1;
	var selectedFrame:Dynamic;
	var message = "";

	public function new(host:DesktopUiHostContext, endpoint:String, profilerPort:Int, capturePath:String, inspectionCapture:String, profileCapture:String) {
		this.host = host;
		ui = new UiContext(null, host.fonts, Theme.dark());
		client = new InspectionClient(host.events, endpoint);
		if (endpoint.length == 0) client.disconnect();
		if (inspectionCapture.length > 0) client.loadCapture(inspectionCapture);
		this.capturePath = capturePath;
		this.profileCapture = profileCapture;
		profiler = profilerPort > 0 || profileCapture.length > 0 ? new devtools.ProfilerProcess(profilerPort) : null;
		if (profiler != null && profileCapture.length > 0) profiler.command("report", {path:profileCapture});
		host.onPoll = function() {
			client.poll();
			if (profiler != null) {
				profiler.poll();
				if (profilerRevision != profiler.revision) { profilerRevision = profiler.revision; host.requestFrame(); }
			}
			if (seenRevision != client.revision) { seenRevision = client.revision; host.requestFrame(); }
		};
	}

	public function context():UiContext return ui;
	public function diagnosticState():Dynamic return {status:client.status, snapshot:client.snapshot,
		profiler:profiler == null ? null : profiler.snapshot, profilerStatus:profiler == null ? "" : profiler.status};
	public function hasInspection():Bool return client.snapshot != null;
	public function saveInspection(path:String):Void client.saveCapture(path);
	public function startSampling():Void { if (profiler != null) profiler.command("start", {sampleRate:250, pollIntervalMs:250}); }
	public function dispose():Void { host.onPoll = null; client.dispose(); if (profiler != null) profiler.dispose(); ui.dispose(); }

	static function style(height:Float = 0):LayoutStyle {
		var s = new LayoutStyle(); s.width = LayoutAxis.grow();
		s.childGap = 8;
		if (height > 0) s.height = LayoutAxis.fixed(height);
		return s;
	}
	static function key(id:String, view:View):KeyedView return new KeyedView(id, view);
	static function text(value:String):Text return new Text(value);
	static function ms(value:Float):String return Std.string(Math.round(value * 100) / 100) + " ms";
	static function dirtyNames(flags:Int):String {
		var names = ["build", "style", "text layout", "layout", "paint", "composite", "semantics", "hit geometry"];
		return [for (i in 0...names.length) if ((flags & (1 << i)) != 0) names[i]].join(", ");
	}

	public function submit(frame:LayoutFrame):RenderNode {
		var snapshot = client.snapshot;
		var frames:Array<Dynamic> = snapshot == null ? [] : snapshot.frames;
		var latest:Dynamic = frames.length == 0 ? null : frames[frames.length - 1];
		var current:Dynamic = selectedFrame == null ? latest : selectedFrame;
		var toolbar = new Row("toolbar", [
			key("title", text("Haxeon DevTools  ·  " + client.status)),
			key("connect", new Button("Reconnect", null, function() client.reconnect())),
			key("disconnect", new Button("Disconnect", null, function() client.disconnect())),
			key("freeze", new Button(client.paused ? "Resume" : "Freeze", null, function() { client.paused = !client.paused; host.requestFrame(); })),
			key("pick", new Button(client.picking ? "Stop picking" : "Follow hovered widget", null, function() { client.picking = !client.picking; host.requestFrame(); })),
			key("live", new Button("Latest frame", null, function() { selectedFrame = null; client.frameId = 0; host.requestFrame(); })),
			key("save", new Button("Save inspection", null, function() {
				try { client.saveCapture(capturePath + ".ui.json"); message = "Saved " + capturePath + ".ui.json"; }
				catch (error:Dynamic) message = Std.string(error);
				host.requestFrame();
			}))
		], style(38));
		var chart = new CanvasView("frames", function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0, 0, geometry.width, geometry.height), Color.fromBytes(28, 31, 38));
			var maximum = 33.34;
			for (f in frames) maximum = Math.max(maximum, f.totalMs);
			var width = geometry.width / Math.max(1, frames.length);
			for (i in 0...frames.length) {
				var f = frames[i]; var height:Float = f.totalMs / maximum * (geometry.height - 8);
				canvas.fillRectIfPositive(new Rect(i * width, geometry.height - height, Math.max(1, width - 1), height),
					selectedFrame != null && selectedFrame.id == f.id ? Color.fromBytes(255, 200, 80) : Color.fromBytes(80, 180, 255));
			}
			var budgetY = geometry.height - 16.67 / maximum * (geometry.height - 8);
			canvas.fillRectIfPositive(new Rect(0, budgetY, geometry.width, 1), Color.fromBytes(220, 110, 100));
		}, style(120), "Frame CPU duration history");
		chart.on("pointerDown", function(event) {
			var geometry = ui.root == null ? null : ui.root.find(event.currentTarget);
			if (frames.length > 0 && geometry != null && geometry.resolved != null) {
				var index = Std.int(event.localX / geometry.resolved.width * frames.length);
				if (index >= 0 && index < frames.length) { selectedFrame = frames[index]; client.frameId = selectedFrame.id; }
				host.requestFrame();
			}
		});
		var summary = current == null ? "Waiting for target frames" : "Frame " + current.id + "  ·  CPU " + ms(current.totalMs)
			+ "  ·  " + current.nodes + " nodes  ·  heap " + Math.round(current.heapBytes / 1048576) + " MiB  ·  GC " + current.collections;
		var timing:Array<KeyedView> = [];
		var phases = ["viewMs", "styleMs", "layoutMs", "reconcileMs", "paintMs", "renderMs"];
		var phaseNames = ["View", "Tree/style", "Layout", "Reconcile", "Custom paint", "Native render"];
		var phaseColors = [Color.fromBytes(127, 167, 255), Color.fromBytes(178, 142, 238), Color.fromBytes(237, 180, 102),
			Color.fromBytes(110, 205, 177), Color.fromBytes(226, 123, 155), Color.fromBytes(95, 191, 221)];
		if (current != null) {
			for (i in 0...phases.length)
				timing.push(key(phases[i], new Text(phaseNames[i] + ": " + ms(Reflect.field(current, phases[i])), null, phaseColors[i])));
			timing.push(key("invalidations", text("Invalidated: layout " + current.layoutInvalidated + ", paint " + current.paintInvalidated)));
		}
		var phaseChart = new CanvasView("phase-timeline", function(canvas, geometry) {
			if (current == null) return;
			var total = 0.0; for (name in phases) total += Reflect.field(current, name);
			var x = 0.0;
			for (i in 0...phases.length) {
				var duration:Float = Reflect.field(current, phases[i]);
				var width = total <= 0 ? 0.0 : duration / total * geometry.width;
				canvas.fillRectIfPositive(new Rect(x, 0, width, geometry.height), phaseColors[i]); x += width;
			}
		}, style(18), "Selected frame CPU phase durations", false);
		var rows = [for (row in client.nodes) row];
		rows.sort(function(a, b) return a.order - b.order);
		var tree:Array<KeyedView> = [];
		for (row in rows) {
			var id:Int = row.id;
			var indent = ""; for (_ in 0...Std.int(Math.min(row.depth, 20))) indent += "  ";
			var button = new Button(indent + "#" + id + " " + row.type + " " + row.label, style(25), function() {
				client.select(id); client.picking = false; client.paused = false; host.requestFrame();
			}, "node-" + id);
			button.selected = client.selected == id;
			button.ellipsizeLabel = true;
			tree.push(key("node-" + id, button));
		}
		var properties:Array<KeyedView> = [key("notice", text("Properties describe the current UI tree. Frame timings can be historical."))];
		properties.push(key("details", new Button(client.details ? "Stop tracking widget work" : "Track widget invalidations and paint", null,
			function() { client.details = !client.details; host.requestFrame(); })));
		var frameEvents:Dynamic = snapshot == null ? null : snapshot.frameEvents;
		if (frameEvents != null) {
			properties.push(key("events-title", text("Widget work in frame " + frameEvents.id + (frameEvents.truncated == true ? " (truncated)" : ""))));
			var events:Array<Dynamic> = frameEvents.events;
			for (i in 0...events.length) {
				var event = events[i]; var widgetId:Int = event.id;
				properties.push(key("event-" + i, new Button("#" + widgetId + " " + event.kind + " "
					+ (event.kind == "paint" ? ms(event.milliseconds) : dirtyNames(event.flags)), null,
					function() { client.select(widgetId); client.picking = false; host.requestFrame(); })));
			}
		}
		if (profiler != null) {
			var activeProfiler:devtools.ProfilerProcess = cast profiler;
			properties.push(key("profiler-state", text("HLDI profiler: " + activeProfiler.status)));
			properties.push(key("profiler-controls", new Row("profiler-controls", [
				key("start", new Button("Start sampling", null, function() activeProfiler.command("start", {sampleRate:250, pollIntervalMs:250}))),
				key("pause", new Button("Pause sampling", null, function() activeProfiler.command("pause"))),
				key("capture", new Button(activeProfiler.recording ? "Stop capture" : "Record HLPC", null, function() {
					if (activeProfiler.recording) activeProfiler.command("pause");
					activeProfiler.command(activeProfiler.recording ? "captureStop" : "captureStart", {path:capturePath});
				}))
			])));
			properties.push(key("capture-path", text("Capture: " + capturePath)));
			properties.push(key("export", new Button("Export Perfetto trace", null, function() {
				var path = profileCapture.length > 0 ? profileCapture : capturePath;
				activeProfiler.command("export", {path:path, output:path + ".pftrace"});
			})));
			if (activeProfiler.report.length > 0) properties.push(key("report", text(activeProfiler.report)));
			var profile:Dynamic = activeProfiler.snapshot;
			if (profile != null && profile.functions != null) {
				properties.push(key("samples", text("Samples: " + profile.samples + " · buffer " + profile.bufferUtilization + " · stalls " + profile.stalls)));
				var functions:Array<Dynamic> = profile.functions;
				for (i in 0...functions.length) {
					var f = functions[i];
					properties.push(key("function-" + i, text(f.name + " · self " + f.selfSamples + " · total " + f.totalSamples)));
				}
			}
		} else properties.push(key("profiler-help", text("Pass --profiler-port=<HLDI port> for function sampling and HLPC recording.")));
		var selected:Dynamic = snapshot == null ? null : snapshot.selected;
		if (selected != null) {
			properties.push(key("selection", text("Widget #" + selected.id)));
			if (selected.note != null) properties.push(key("selection-note", text(selected.note)));
			for (name in ["bounds", "clip", "content", "enabled", "focused", "hovered", "pressed", "effects", "isolation", "estimatedBytes"])
				properties.push(key(name, text(name + ": " + haxe.Json.stringify(Reflect.field(selected, name)))));
			var entries:Array<Dynamic> = selected.styles;
			for (entry in entries) properties.push(key("style-" + entry.name, text(entry.name + ": " + entry.value + "  (" + entry.source + ")")));
		}
		var pane = style(); pane.height = LayoutAxis.grow();
		var body = new Row("body", [
			key("tree", new ScrollView("tree-scroll", new Column("tree", tree), pane)),
			key("properties", new ScrollView("properties-scroll", new Column("properties", properties), pane))
		], pane);
		var root = style(); root.height = LayoutAxis.grow(); root.padding = new Insets(12, 12, 12, 12); root.childGap = 8;
		var notice = snapshot != null && snapshot.truncated == true ? "Tree truncated by the inspection payload limit" : "UI inspection · 4 updates/sec · last 240 frames · red line: 16.67 ms CPU budget";
		if (snapshot != null && snapshot.historyGap == true) notice += " · frame history gap";
		if (message.length > 0) notice = message;
		return ui.submit(new Column("devtools", [key("toolbar", toolbar), key("chart", chart), key("summary", text(summary)),
			key("phase-chart", phaseChart), key("timing", new Row("timing", timing, style())), key("notice", text(notice)), key("body", body)], root), frame);
	}
}
