package suit.relay;

import suit.relay.SuitRelayProtocol.SuitRelayClientReport;
import suit.relay.SuitRelayProtocol.SuitRelayOpen;

/** One remote client as suit shows it. Times are seconds since the epoch. */
typedef SuitRelayClientView = {
	/** The relay channel id; for a paired device it is the device id. */
	var id:String;
	/**
		device (paired), pairing (waiting for approval), channel (not reported by the workspace service yet)
		or disconnected (Disconnect was used; listed until DISCONNECTED_LISTED_SECONDS pass).
	**/
	var kind:String;
	var connectedAt:Float;
	var lastActivity:Float;
	var framesIn:Int;
	var framesOut:Int;
	/** What the device may use, from the workspace service; empty when unknown. */
	var grants:Array<String>;
	/** Through suit's machine socket, or `direct` while the workspace daemon holds it itself. */
	var route:String;
}

private typedef Client = {
	var id:String;
	var connectedAt:Float;
	var lastActivity:Float;
	var framesIn:Int;
	var framesOut:Int;
}

/** A client Disconnect cut off: refused until `until`, listed as disconnected until `listedUntil`. */
private typedef Blocked = {
	var client:Client;
	var until:Float;
	var listedUntil:Float;
	var listed:Bool;
}

/**
	The remote clients of one hosted workspace, as suit sees them on its machine socket: a client appears
	with its first frame and goes with a reset, which the Worker sends when the device's socket closes or
	is replaced. The attached daemon's client report adds what suit cannot see in ciphertext: whether a
	channel is a paired device, its grants, and what the workspace has open.

	Disconnect cuts a client off: the Worker closes its socket (close code 4001, disconnected_by_host), suit
	resets its channel in the daemon, and for COOLDOWN_SECONDS suit refuses it again whenever it reconnects.
	It is listed as disconnected for DISCONNECTED_LISTED_SECONDS. Revoking the device, in the editor's
	Remote Access panel, is the permanent cut-off.
**/
class SuitRelayClients {
	public static inline var COOLDOWN_SECONDS:Float = 60;
	public static inline var DISCONNECTED_LISTED_SECONDS:Float = 20;

	final clients:Map<String, Client> = [];
	final blocked:Map<String, Blocked> = [];
	var report:Null<SuitRelayClientReport> = null;

	/** Bumped whenever a client appears, goes or is disconnected, so the tray can update at once. */
	public var revision(default, null):Int = 0;

	public function new() {}

	/** A frame from a device; false while the client is cut off, and the caller must close it again. */
	public function fromDevice(id:String, now:Float):Bool {
		if (isBlocked(id, now))
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

	public function isBlocked(id:String, now:Float):Bool {
		var entry = blocked.get(id);
		return entry != null && now < entry.until;
	}

	public function toDevice(id:String, now:Float):Void {
		var client = clients.get(id);
		if (client == null)
			return;
		client.framesOut++;
		client.lastActivity = now;
	}

	/** The Worker reset the channel: the client's socket closed or was replaced. A cooldown stays in force. */
	public function reset(id:String):Void {
		if (clients.remove(id))
			revision++;
	}

	/**
		Cuts off the client whose id is, or starts with, `query` (4+ characters, ignoring case); returns its
		full id, or null when none or more than one matches.
	**/
	public function disconnect(query:String, now:Float):Null<String> {
		var wanted = query.toLowerCase();
		var match:Null<String> = null;
		for (id in clients.keys()) {
			var key = id.toLowerCase();
			if (key == wanted || (wanted.length >= 4 && StringTools.startsWith(key, wanted))) {
				if (match != null)
					return null; // ambiguous prefix
				match = id;
			}
		}
		if (match == null)
			return null;
		var client = clients.get(match);
		clients.remove(match);
		blocked.set(match, {client: client, until: now + COOLDOWN_SECONDS, listedUntil: now + DISCONNECTED_LISTED_SECONDS, listed: true});
		revision++;
		return match;
	}

	/** Drops expired cooldowns and disconnected listings. */
	public function expire(now:Float):Void {
		for (id in [for (key in blocked.keys()) key]) {
			var entry = blocked.get(id);
			if (entry.listed && now >= entry.listedUntil) {
				entry.listed = false;
				revision++;
			}
			if (!entry.listed && now >= entry.until)
				blocked.remove(id);
		}
	}

	/** The machine socket closed: every channel on it is gone. Cooldowns stay. */
	public function clear():Void {
		var had = clients.keys().hasNext();
		clients.clear();
		if (had)
			revision++;
	}

	public function setReport(value:SuitRelayClientReport):Void
		report = value;

	public function forgetReport():Void
		report = null;

	/** Connected clients (disconnected ones are not counted). */
	public function count():Int {
		var total = 0;
		for (_ in clients)
			total++;
		return total;
	}

	/** What the workspace has open, from the daemon's report; null when unknown. */
	public function open():Null<SuitRelayOpen>
		return report == null ? null : report.open;

	public function views(now:Float):Array<SuitRelayClientView> {
		var result:Array<SuitRelayClientView> = [];
		for (client in clients)
			result.push(viewOf(client, kindOf(client.id)));
		for (entry in blocked)
			if (entry.listed && now < entry.listedUntil)
				result.push(viewOf(entry.client, "disconnected"));
		result.sort(function(left, right) return Reflect.compare(left.connectedAt, right.connectedAt));
		return result;
	}

	function kindOf(id:String):String {
		var current = report;
		if (current == null)
			return "channel";
		for (device in current.devices)
			if (device.deviceId == id)
				return "device";
		return current.pending.indexOf(id) >= 0 ? "pairing" : "channel";
	}

	function viewOf(client:Client, kind:String):SuitRelayClientView {
		var grants:Array<String> = [];
		var current = report;
		if (current != null)
			for (device in current.devices)
				if (device.deviceId == client.id)
					grants = device.grants.copy();
		return {
			id: client.id, kind: kind, connectedAt: client.connectedAt, lastActivity: client.lastActivity,
			framesIn: client.framesIn, framesOut: client.framesOut, grants: grants, route: "suit"
		};
	}
}
