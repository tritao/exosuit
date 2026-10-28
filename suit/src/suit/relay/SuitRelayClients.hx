package suit.relay;

import suit.SuitInventory;
import suit.SuitRecord.SuitRecords;

/** One remote client as suit shows it. Times are seconds since the epoch. */
typedef SuitRelayClientView = {
	/** The relay channel id; for a paired device it is the device id. */
	var id:String;
	/** device (paired), pairing (waiting for approval) or channel (not reported by the workspace service yet). */
	var kind:String;
	var connectedAt:Float;
	var lastActivity:Float;
	var framesIn:Int;
	var framesOut:Int;
	/** What the device may use, from the workspace service; empty when unknown. */
	var grants:Array<String>;
}

private typedef Client = {
	var id:String;
	var connectedAt:Float;
	var lastActivity:Float;
	var framesIn:Int;
	var framesOut:Int;
}

/**
	The remote clients of one hosted workspace, as suit sees them on its machine socket: a client appears
	with its first frame and goes with a reset, which the Worker sends when the device's socket closes or
	is replaced. The attached daemon's client report adds what suit cannot see in ciphertext: whether a
	channel is a paired device, its grants, and what the workspace has open.

	Disconnect ends a client's session: suit resets its channel in the daemon and drops its frames until
	the Worker resets the channel, which happens when the device reconnects. Revoking stays in the editor.
**/
class SuitRelayClients {
	final clients:Map<String, Client> = [];
	final dropped:Map<String, Bool> = [];
	var report:Dynamic = null;

	/** Bumped whenever a client appears or goes, so the tray can update at once. */
	public var revision(default, null):Int = 0;

	public function new() {}

	/** A frame from a device; false when the client was disconnected and the frame must be dropped. */
	public function fromDevice(id:String, now:Float):Bool {
		if (dropped.exists(id))
			return false;
		var client = clients.get(id);
		if (client == null) {
			client = {id: id, connectedAt: now, lastActivity: now, framesIn: 0, framesOut: 0};
			clients.set(id, client);
			revision++;
		}
		client.framesIn++;
		client.lastActivity = now;
		return true;
	}

	public function toDevice(id:String, now:Float):Void {
		var client = clients.get(id);
		if (client == null)
			return;
		client.framesOut++;
		client.lastActivity = now;
	}

	/** The Worker reset the channel: the client's socket closed or was replaced. */
	public function reset(id:String):Void {
		dropped.remove(id);
		if (clients.remove(id))
			revision++;
	}

	/** Disconnects the client whose id is or starts with `query`; returns its full id, or null when none matches. */
	public function disconnect(query:String):Null<String> {
		var match:Null<String> = null;
		for (id in clients.keys())
			if (id == query || (query.length >= 4 && StringTools.startsWith(id, query.toLowerCase()))) {
				if (match != null)
					return null; // ambiguous prefix
				match = id;
			}
		if (match == null)
			return null;
		clients.remove(match);
		dropped.set(match, true);
		revision++;
		return match;
	}

	/** The machine socket closed: every channel on it is gone. */
	public function clear():Void {
		var had = clients.keys().hasNext();
		clients.clear();
		dropped.clear();
		if (had)
			revision++;
	}

	public function setReport(value:Dynamic):Void
		report = value;

	public function count():Int {
		var total = 0;
		for (_ in clients)
			total++;
		return total;
	}

	/** What the workspace has open, from the daemon's report: `{terminals, agents}`, or null when unknown. */
	public function open():Dynamic {
		var value:Dynamic = report == null ? null : Reflect.field(report, "open");
		if (value == null)
			return null;
		var terminals = SuitRecords.intField(value, "terminals"), agents = SuitRecords.intField(value, "agents");
		return {terminals: terminals == null ? 0 : terminals, agents: agents == null ? 0 : agents};
	}

	public function views():Array<SuitRelayClientView> {
		var result:Array<SuitRelayClientView> = [];
		for (client in clients) {
			var kind = "channel", grants:Array<String> = [];
			var devices:Dynamic = report == null ? null : Reflect.field(report, "devices");
			if (Std.isOfType(devices, Array))
				for (device in (devices : Array<Dynamic>))
					if (SuitRecords.stringField(device, "deviceId") == client.id) {
						kind = "device";
						var listed:Dynamic = Reflect.field(device, "grants");
						if (Std.isOfType(listed, Array))
							grants = [for (grant in (listed : Array<Dynamic>)) if (Std.isOfType(grant, String)) (grant : String)];
					}
			var waiting:Dynamic = report == null ? null : Reflect.field(report, "pending");
			if (kind == "channel" && Std.isOfType(waiting, Array) && (waiting : Array<Dynamic>).indexOf(client.id) >= 0)
				kind = "pairing";
			result.push({
				id: client.id, kind: kind, connectedAt: client.connectedAt, lastActivity: client.lastActivity,
				framesIn: client.framesIn, framesOut: client.framesOut, grants: grants
			});
		}
		result.sort(function(left, right) return Reflect.compare(left.connectedAt, right.connectedAt));
		return result;
	}
}
