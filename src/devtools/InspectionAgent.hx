package devtools;

import haxe.io.Bytes;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.WidgetId;
import haxeon.ui.host.DesktopUiHostContext;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/** Opt-in, single-client inspection endpoint. All work is polled at UI-thread safe points. */
class InspectionAgent {
	public final path:String;
	final hub:NativeRpcHub;
	final ui:UiContext;
	final host:DesktopUiHostContext;
	final model = new InspectionModel();
	var peer:Null<NativeRpcTransport>;
	var previous:Map<Int, String> = [];
	var lastFrame = -1;
	var lastFrameAt = 0.0;
	var lastRequest = 0.0;
	var selectedId = 0;
	var disposed = false;
	var detailed = false;
	var paintEvents:Array<Dynamic> = [];
	var paintTruncated = false;
	final frameEvents:Map<Int, Dynamic> = [];

	public function new(path:String, host:DesktopUiHostContext, ui:UiContext) {
		this.path = path; this.host = host; this.ui = ui;
		hub = new NativeRpcHub(host.events);
		hub.listen(NativeRpcHub.local(path), function(transport) {
			if (peer != null && peer.isOpen()) { transport.close(); return; }
			peer = transport; previous = []; lastRequest = 0;
			model.frames.resize(0); model.droppedFrames = 0; frameEvents.clear();
			lastFrame = -1; recordFrame(lastFrameAt);
		});
	}

	public function recordFrame(at:Float = 0):Void {
		lastFrameAt = at <= 0 ? Sys.time() : at;
		if (peer == null || !peer.isOpen()) return;
		var metrics = ui.frameMetrics;
		if (metrics == null || metrics.frameNumber == lastFrame) return;
		lastFrame = metrics.frameNumber;
		if (detailed) {
			var events = paintEvents; paintEvents = [];
			var truncated = paintTruncated; paintTruncated = false;
			if (ui.root != null && !metrics.reusedSubmission) ui.root.walk(function(node) {
				if (node.styleType == "devtools-overlay") return;
				if (node.invalidationFlags == 0) return;
				if (events.length >= 64) { truncated = true; return; }
				events.push({id:node.id.value, kind:"invalidation", flags:node.invalidationFlags, type:node.styleType});
			});
			frameEvents.set(lastFrame, {id:lastFrame, events:events, truncated:truncated});
		}
		if (model.frames.length == InspectionModel.FRAME_LIMIT) {
			var oldest:Int = model.frames[0].id; frameEvents.remove(oldest);
		}
		model.addFrame({id:lastFrame, at:lastFrameAt, totalMs:metrics.totalSeconds * 1000,
			viewMs:metrics.viewSeconds * 1000, styleMs:metrics.treeAndStyleSeconds * 1000,
			layoutMs:metrics.nativeLayoutSeconds * 1000, reconcileMs:metrics.reconcileSeconds * 1000,
			paintMs:metrics.customPaintSeconds * 1000, renderMs:metrics.nativeRenderSeconds * 1000,
			nodes:metrics.nodeCount, layoutInvalidated:metrics.layoutInvalidatedNodes,
			paintInvalidated:metrics.paintInvalidatedNodes, reused:metrics.reusedSubmission,
			heapBytes:hl.Gc.heapBytes(), allocatedBytes:hl.Gc.totalAllocated(), collections:hl.Gc.collections()});
	}

	public function poll():Void {
		if (disposed || peer == null) return;
		var transport = peer;
		if (!transport.isOpen()) { disconnect(); return; }
		// The client uses request/response. At most one snapshot every 250ms, without queued snapshots.
		var bytes = transport.receive();
		if (bytes == null) return;
		try {
			var request:Dynamic = haxe.Json.parse(bytes.toString());
			if (request.version != InspectionModel.VERSION || Sys.time() - lastRequest < 0.2) {
				transport.close(); disconnect(); return;
			}
			lastRequest = Sys.time();
			detailed = request.details == true;
			if (!detailed) { paintEvents = []; paintTruncated = false; }
			ui.onInspectionPaint = detailed ? function(id, seconds) {
				if (paintEvents.length < 64) paintEvents.push({id:id, kind:"paint", milliseconds:seconds * 1000});
				else paintTruncated = true;
			} : null;
			var id = Std.parseInt(Std.string(request.selected));
			selectedId = id == null || id < 1 ? 0 : id;
			if (request.pick == true) {
				var hovered = ui.events.hoveredId();
				if (hovered != null) selectedId = hovered.value;
			}
			if (ui.inspectionHighlight != selectedId) { ui.inspectionHighlight = selectedId; host.requestFrame(); }
			var rows:Array<Dynamic> = [];
			model.selected = null;
			// Keep the live tree compact; compute detailed styles/effects only for the selected node.
			if (ui.root != null) ui.root.walk(function(renderNode) {
				if (renderNode.styleType == "devtools-overlay") return;
				if (rows.length <= InspectionModel.NODE_LIMIT && renderNode.resolved != null) {
					var geometry = renderNode.resolved;
					var depth = 0; var parent = renderNode.parent;
					while (parent != null) { depth++; parent = parent.parent; }
					var label = renderNode.semantics == null ? "" : renderNode.semantics.label;
					rows.push({id:renderNode.id.value, order:rows.length, parentId:renderNode.parent == null ? 0 : renderNode.parent.id.value,
						depth:depth, type:renderNode.styleType == null ? "node" : renderNode.styleType,
						label:label == null ? "" : label.substr(0, 100), x:geometry.x, y:geometry.y,
						width:geometry.width, height:geometry.height, visible:geometry.visible,
						focused:ui.focus.focusedId != null && ui.focus.focusedId.equals(renderNode.id)});
				}
				if (renderNode.id.value != selectedId) return;
				var node = haxeon.ui.debug.UiInspector.nodeSnapshot(renderNode, ui.focus.focusedId);
				if (node.id == selectedId) model.selected = {id:node.id, bounds:node.bounds,
					clip:node.clipBounds, content:node.contentBounds, enabled:node.enabled, focused:node.focused,
					hovered:node.hovered, pressed:node.pressed, effects:node.effectDescriptions,
					isolation:node.isolationReasons, estimatedBytes:node.estimatedRenderTargetBytes,
					styles:[for (entry in node.styleEntries) {name:entry.name, value:entry.describe().substr(0, 300),
						source:entry.source == null ? "" : entry.source.toString().substr(0, 300)}]};
			});
			if (model.selected == null) { selectedId = 0; ui.inspectionHighlight = 0; }
			model.update(rows);
			var delta = model.delta(previous, request.full == true);
			var requestedFrame = Std.parseInt(Std.string(request.frameId));
			var events = frameEvents.get(requestedFrame == null || requestedFrame <= 0 ? lastFrame : requestedFrame);
			var afterFrame = Std.parseInt(Std.string(request.afterFrame));
			var newFrames:Array<Dynamic> = [for (frame in model.frames) if (afterFrame == null || frame.id > afterFrame) frame];
			var historyGap = newFrames.length > 60;
			if (historyGap) newFrames = newFrames.slice(newFrames.length - 60);
			var payload:Dynamic = {version:InspectionModel.VERSION, sequence:model.sequence,
				at:Sys.time(), frames:newFrames, droppedFrames:model.droppedFrames, historyGap:historyGap,
				frameEvents:events,
				full:delta.full, changed:delta.changed, removed:delta.removed,
				truncated:model.truncated, selected:model.selected};
			var response = Bytes.ofString(haxe.Json.stringify(payload));
			while (response.length > 262144 && model.nodes.length > 1) {
				model.update(model.nodes.slice(0, Std.int(model.nodes.length / 2))); model.truncated = true;
				delta = model.delta(previous, request.full == true);
				payload.changed = delta.changed; payload.removed = delta.removed; payload.truncated = true;
				response = Bytes.ofString(haxe.Json.stringify(payload));
			}
			if (response.length > 262144 || !transport.send(response)) {
				transport.close(); disconnect();
			} else previous = delta.next;
		} catch (_:Dynamic) { transport.close(); disconnect(); }
	}

	function disconnect():Void {
		peer = null; previous = []; ui.inspectionHighlight = 0; ui.onInspectionPaint = null; detailed = false;
		paintEvents = []; host.requestFrame();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true; ui.inspectionHighlight = 0; ui.onInspectionPaint = null; hub.dispose(); peer = null;
	}
}
