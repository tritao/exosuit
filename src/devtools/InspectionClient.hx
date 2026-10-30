package devtools;

import haxe.io.Bytes;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.MessageTransport;
import haxeon.platform.event.EventPump;
import workspace.transport.NativeRpcHub;

/** Nonblocking inspection session, independent of its UI. One outstanding request bounds traffic. */
class InspectionClient {
	public var status(default, null) = "Disconnected";
	public var snapshot(default, null):Dynamic;
	public final nodes:Map<Int, Dynamic> = [];
	public var selected = 0;
	public var picking = false;
	public var paused = false;
	public var details = false;
	public var frameId = 0;
	public var revision(default, null) = 0;
	final hub:NativeRpcHub;
	final endpoint:String;
	var transport:Null<MessageTransport>;
	var attempt:Null<RpcConnectAttempt>;
	var connecting = false;
	var desired = true;
	var nextConnect = 0.0;
	var nextRequest = 0.0;
	var outstanding = false;
	var sentAt = 0.0;
	var full = true;
	var afterFrame = 0;
	var selectionGeneration = 0;
	var pendingSelectionGeneration = 0;
	final frames:Array<Dynamic> = [];

	public function new(events:EventPump, endpoint:String) {
		hub = new NativeRpcHub(events); this.endpoint = endpoint;
	}

	public function disconnect():Void {
		desired = false;
		if (attempt != null) attempt.cancel();
		attempt = null; connecting = false;
		if (transport != null) transport.close();
		transport = null; outstanding = false; status = "Disconnected"; revision++;
	}

	public function reconnect():Void {
		disconnect(); desired = true; nextConnect = 0;
	}

	public function saveCapture(path:String):Void {
		if (snapshot == null) throw "No inspection snapshot to save";
		sys.io.File.saveContent(path, haxe.Json.stringify({kind:"haxeon-ui-capture", version:InspectionModel.VERSION,
			snapshot:snapshot, nodes:[for (row in nodes) row]}, null, "  "));
	}

	public function select(id:Int):Void {
		selected = id;
		selectionGeneration++;
		if (!desired && snapshot != null) {
			var row = nodes.get(id);
			var styles:Array<Dynamic> = [];
			if (row != null) snapshot.selected = {id:id, bounds:{x:row.x, y:row.y, width:row.width, height:row.height},
				styles:styles, note:"Only the originally selected widget has computed properties in a saved inspection."};
		}
		revision++;
	}

	public function loadCapture(path:String):Void {
		var metadata = sys.FileSystem.metadata(path);
		if (metadata == null || metadata.size > 4 * 1024 * 1024) throw "Inspection capture missing or exceeds 4 MiB";
		var value:Dynamic = haxe.Json.parse(sys.io.File.getContent(path));
		if (value.kind != "haxeon-ui-capture" || value.version != InspectionModel.VERSION) throw "Unsupported inspection capture";
		var rows:Array<Dynamic> = value.nodes;
		var capturedFrames:Array<Dynamic> = value.snapshot.frames;
		if (rows.length > InspectionModel.NODE_LIMIT || capturedFrames.length > InspectionModel.FRAME_LIMIT) throw "Inspection capture exceeds history limits";
		disconnect(); nodes.clear();
		for (row in rows) nodes.set(row.id, row);
		snapshot = value.snapshot; selected = snapshot.selected == null ? 0 : snapshot.selected.id;
		status = "Offline inspection capture"; revision++;
	}

	public function poll():Void {
		var now = Sys.time();
		if (!desired) return;
		if (transport == null && !connecting && now >= nextConnect) {
			status = "Connecting"; revision++; nextConnect = now + 2;
			connecting = true;
			attempt = hub.connect(NativeRpcHub.local(endpoint), function(result) {
				attempt = null; connecting = false;
				switch result {
					case Opened(peer): transport = peer; full = true; frames.resize(0); afterFrame = 0; outstanding = false; status = "Connected";
					case Failed(error, _): status = error.message;
				}
				revision++;
			});
		}
		var peer = transport;
		if (peer == null) return;
		if (!peer.isOpen() || outstanding && now - sentAt > 5) {
			peer.close(); transport = null; outstanding = false; status = "Target unavailable; reconnecting"; revision++; return;
		}
		try {
			var bytes = peer.receive();
			if (bytes != null) {
				var value:Dynamic = haxe.Json.parse(bytes.toString());
				if (value.version != InspectionModel.VERSION) throw "Unsupported inspection protocol";
				if (value.full == true) nodes.clear();
				var removed:Array<Int> = value.removed;
				var changed:Array<Dynamic> = value.changed;
				for (id in removed) nodes.remove(id);
				for (row in changed) nodes.set(row.id, row);
				if (nodesCount() > InspectionModel.NODE_LIMIT) throw "Inspection node limit";
				var newFrames:Array<Dynamic> = value.frames;
				for (frame in newFrames) {
					var id:Int = frame.id;
					if (id > afterFrame) { frames.push(frame); afterFrame = id; }
				}
				while (frames.length > InspectionModel.FRAME_LIMIT) frames.shift();
				value.frames = frames.copy();
				snapshot = value;
				// A response to an older request must not overwrite a selection made while it was in flight.
				if (selectionGeneration == pendingSelectionGeneration) selected = value.selected == null ? 0 : value.selected.id;
				full = false; outstanding = false; status = "Connected"; revision++;
			}
			if (!outstanding && !paused && now >= nextRequest) {
				var request = Bytes.ofString(haxe.Json.stringify({version:InspectionModel.VERSION,
					full:full, selected:selected, pick:picking, details:details, frameId:frameId, afterFrame:afterFrame}));
				if (peer.send(request)) {
					outstanding = true; pendingSelectionGeneration = selectionGeneration; sentAt = now; nextRequest = now + 0.25;
				}
			}
		} catch (error:Dynamic) {
			peer.close(); transport = null; outstanding = false; status = Std.string(error); revision++;
		}
	}

	function nodesCount():Int { var count = 0; for (_ in nodes) count++; return count; }

	public function dispose():Void { disconnect(); hub.dispose(); }
}
