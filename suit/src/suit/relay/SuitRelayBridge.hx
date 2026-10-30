package suit.relay;

import suit.SuitRecord.SuitRecords;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import haxeon.wire.MessagePackFrame;
import processkit.Processes;
import suit.SuitClient;
import suit.SuitInventory;
import suit.relay.SuitRelayClients.SuitRelayClientView;
import suit.relay.SuitRelayHosts.SuitRelayHost;
import suit.relay.SuitRelayProtocol.SuitRelayLinkStatus;
import suit.relay.SuitRelayProtocol.SuitRelayOpen;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;
import workspace.transport.RelayFrame;
import workspace.transport.RelayFrameCodec;
import workspace.transport.RelayMachineConnector;
import workspace.transport.RelayMachineDialer;
import workspace.transport.RelaySocketLink;

/** What the tray, `suit relay list` and `relay-state.json` show for one hosted workspace. */
typedef SuitRelayHostView = {
	var root:String;
	var stateDir:String;
	var machineId:String;
	var origin:String;
	/**
		connected, connecting, error (retrying), failed (stopped until Retry: see `error`), direct (the
		workspace daemon holds the machine socket itself), paused, or not hosted (suit is not running).
	**/
	var state:String;
	var error:Null<String>;
	/** Whether a workspace daemon is attached, that is whether the workspace service is running. */
	var serviceRunning:Bool;
	var servicePid:Int;
	/** How many times suit started the workspace service for a device. */
	var starts:Int;
	/** Remote clients: on suit's machine socket, or the daemon's connected devices while it holds the socket. */
	var clients:Array<SuitRelayClientView>;
	/** What the workspace has open, from the attached daemon; null when unknown. */
	var open:Null<SuitRelayOpen>;
}

private typedef PendingFrame = {
	var frame:RelayFrame;
	var at:Float;
}

/** A refused daemon that dials the relay itself: suit leaves the machine socket to it while it runs. */
private typedef Holder = {
	var pid:Int;
	var reason:String;
}

/**
	One hosted workspace: suit's machine socket to the relay and the attached daemon's relay link.

	Frames pass through without being opened; suit reads only the 16-byte channel id. While no daemon is
	attached, frames wait in a bounded buffer for at most PENDING_MAX_AGE_SECONDS (a reset drops its
	channel's frames) and suit starts the workspace manager, at most once per START_COOLDOWN_SECONDS and
	MAX_STARTS times per START_WINDOW_SECONDS; past that it stops with `service_start_failed_repeatedly`
	until Retry. Every dial reads the bearer from the OS credential store and keeps it only for that attempt.

	The Worker keeps one machine socket per machine, so there is one dialer at a time: while a workspace
	daemon holds the socket itself (suit refused its attach, or it was hosting before suit started, as its
	`relay-status.json` shows), suit does not dial for that machine until that process exits or attaches.
**/
class SuitRelayBridge {
	static inline var MAX_PENDING_FRAMES:Int = 64;
	static inline var MAX_PENDING_BYTES:Int = 2097152;
	static inline var PENDING_MAX_AGE_SECONDS:Float = 30;
	static inline var START_COOLDOWN_SECONDS:Float = 30;
	/** An isolated test suit (EXOSUIT_SUIT_HOME set) may shorten the cooldown with EXOSUIT_SUIT_TEST_START_COOLDOWN. */
	static final startCooldown:Float = testCooldown();
	static inline var START_WINDOW_SECONDS:Float = 600;
	static inline var MAX_STARTS:Int = 5;
	static inline var MAX_RETRY_SECONDS:Float = 30;
	static inline var HOLDER_CHECK_SECONDS:Float = 5;
	/** A daemon's relay-status.json older than this is from a daemon that is gone. */
	static inline var STATUS_FRESH_SECONDS:Float = 90;

	public var host(default, null):SuitRelayHost;
	public var paused(default, null):Bool;
	/** Set when suit stopped trying: a retry cannot fix it until Retry or a daemon attaches. */
	public var failure(default, null):Null<String> = null;
	public var lastError(default, null):Null<String> = null;
	public var servicePid(default, null):Int = 0;
	public var starts(default, null):Int = 0;
	public final clients:SuitRelayClients = new SuitRelayClients();

	final dialer:RelayMachineDialer;
	final pending:Array<PendingFrame> = [];
	final startTimes:Array<Float> = [];
	var pendingBytes:Int = 0;
	var link:Null<RelaySocketLink> = null;
	var daemon:Null<NativeRpcTransport> = null;
	var holder:Null<Holder> = null;
	var holderCheckedAt:Float = -1e9;
	var directDevices:Array<String> = [];
	var sentStatus:String = "";
	var startedAt:Float = -1e9;
	var disposed:Bool = false;

	public function new(events:EventPump, hub:NativeRpcHub, host:SuitRelayHost, paused:Bool) {
		this.host = host;
		this.paused = paused;
		dialer = new RelayMachineDialer(new RelayMachineConnector(events, hub, Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1"), 1,
			MAX_RETRY_SECONDS);
	}

	public function connected():Bool {
		var current = link;
		return current != null && current.isOpen();
	}

	public function attached():Bool {
		var current = daemon;
		return current != null && current.isOpen();
	}

	/** suit keeps running for this workspace: not paused, not failed, and not left to a direct daemon. */
	public function hosting():Bool
		return !paused && failure == null && holder == null;

	/** Work the daemon loop should wake for promptly. */
	public function busy():Bool
		return attached() || pending.length > 0 || dialer.dialing();

	/** Connected clients: suit's own, or the direct daemon's connected devices. */
	public function clientCount():Int
		return holder != null ? directDevices.length : clients.count();

	public function view(now:Float):SuitRelayHostView {
		var held = holder;
		var direct = held != null;
		var heldPid = held == null ? 0 : held.pid;
		return {
			root: host.root,
			stateDir: host.stateDir,
			machineId: host.machineId,
			origin: host.origin,
			state: stateName(),
			error: paused ? null : failure != null ? failure : lastError,
			serviceRunning: attached() || direct,
			servicePid: attached() ? servicePid : heldPid,
			starts: starts,
			clients: direct ? [for (id in directDevices) directView(id)] : clients.views(now),
			open: attached() ? clients.open() : null
		};
	}

	function stateName():String {
		if (paused)
			return "paused";
		if (failure != null)
			return "failed";
		if (holder != null)
			return "direct";
		if (connected())
			return "connected";
		return lastError != null && !dialer.dialing() ? "error" : "connecting";
	}

	static function directView(id:String):SuitRelayClientView
		return {id: id, kind: "device", connectedAt: 0, lastActivity: 0, framesIn: 0, framesOut: 0, grants: [], route: "direct"};

	/** Takes over a daemon's link (closing an older one), answers its attach and hands it the waiting frames. */
	public function attach(transport:NativeRpcTransport, pid:Int, current:SuitRelayHost):Void {
		host = current;
		var previous = daemon;
		if (previous != null && previous != transport)
			previous.close();
		daemon = transport;
		servicePid = pid;
		sentStatus = "";
		holder = null;
		directDevices = [];
		clients.forgetReport();
		if (!transport.send(Bytes.ofString(Json.stringify({ok: true})))) {
			transport.close();
			daemon = null;
			return;
		}
		if (failure != null) {
			// A daemon that attaches has just stored the bearer and started: try again now.
			retry();
		}
		sendStatus();
		var waiting = pending.copy();
		pending.resize(0);
		pendingBytes = 0;
		for (item in waiting)
			if (!toDaemon(item.frame))
				break;
	}

	/**
		suit refused this machine's daemon, which now dials the relay itself: close suit's socket and leave
		the machine to that process until it exits or attaches.
	**/
	public function holdFor(pid:Int, reason:String):Void {
		holder = {pid: pid, reason: reason};
		holderCheckedAt = -1e9;
		lastError = reason;
		closeLink();
		clients.clear();
	}

	/** Stops hosting until `resume`: closes the machine socket and the daemon's link. */
	public function pause():Void {
		paused = true;
		closeLink();
		closeDaemon();
		dropAllPending();
		clients.clear();
	}

	public function resume():Void {
		paused = false;
		retry();
	}

	/** Clears a failure and dials again now. */
	public function retry():Void {
		failure = null;
		lastError = null;
		startTimes.resize(0);
		dialer.retryNow();
	}

	/**
		Cuts off one client (see SuitRelayClients): the Worker closes its socket, the daemon ends its session
		and suit refuses it for the cooldown. Returns its full id, or null when none matches.
	**/
	public function disconnect(query:String, now:Float):Null<String> {
		var id = clients.disconnect(query, now);
		if (id == null)
			return null;
		dropPending(id);
		closeClient(id);
		toDaemon(new RelayFrame(id, Bytes.alloc(0), true));
		return id;
	}

	function closeClient(id:String):Void {
		var socket = link;
		if (socket != null)
			socket.closeRouted(id);
	}

	public function poll(now:Float):Void {
		if (disposed || paused)
			return;
		clients.expire(now);
		expirePending(now);
		pollDaemon();
		var socket = link;
		if (socket != null) {
			socket.poll();
			if (!socket.isOpen()) {
				link = null;
				clients.clear();
				lastError = dialer.backOff(now, socket.failure);
			}
		}
		if (holder != null || (link == null && !attached() && now - holderCheckedAt >= HOLDER_CHECK_SECONDS))
			checkHolder(now);
		if (link == null && failure == null && holder == null && dialer.due(now))
			dial();
		sendStatus();
	}

	function pollDaemon():Void {
		var current = daemon;
		if (current == null)
			return;
		if (!current.isOpen()) {
			daemon = null;
			servicePid = 0;
			return;
		}
		for (_ in 0...64) {
			var message = current.receive();
			if (message == null)
				break;
			if (!fromDaemon(message)) {
				closeDaemon();
				break;
			}
		}
	}

	/**
		Whether a daemon holds this machine's socket itself: the refused holder while it runs, or, before suit
		dials, a live daemon whose relay-status.json says it is connected directly. Also reads its devices.
	**/
	function checkHolder(now:Float):Void {
		if (now - holderCheckedAt < HOLDER_CHECK_SECONDS)
			return;
		holderCheckedAt = now;
		var status:Dynamic = null;
		try status = SuitRelayHosts.readPrivateJson(Path.join([host.stateDir, "relay-status.json"])) catch (_:Dynamic) {}
		var statusPid = status == null ? null : SuitRecords.intField(status, "pid");
		var updatedAt = status == null ? null : SuitRecords.floatField(status, "updatedAt");
		var directStatus = status != null && Reflect.field(status, "viaSuit") == false && statusPid != null && updatedAt != null
			&& Date.now().getTime() - updatedAt < STATUS_FRESH_SECONDS * 1000 && alive(statusPid);
		var current = holder;
		if (current != null && !alive(current.pid)) {
			holder = null;
			current = null;
			lastError = null;
			dialer.retryNow();
		}
		if (current == null && directStatus && Reflect.field(status, "connected") == true)
			holder = current = {pid: (statusPid : Int), reason: "hosted_by_workspace_service"};
		directDevices = [];
		if (current != null && directStatus && statusPid == current.pid) {
			var listed:Dynamic = Reflect.field(status, "devices");
			if (Std.isOfType(listed, Array))
				for (device in (listed : Array<Dynamic>))
					if (Reflect.field(device, "connected") == true && Reflect.field(device, "revoked") != true) {
						var id = SuitRecords.stringField(device, "deviceId");
						if (id != null)
							directDevices.push(id);
					}
		}
	}

	static function alive(pid:Int):Bool
		return pid > 0 && Processes.started(pid) != -1;

	function dial():Void {
		var token:Null<String> = null;
		try {
			var stored = WorkspaceCredentialStores.relay().read(WorkspaceCredentialStores.machineAccount(SuitRelayHosts.endpoint(host)));
			if (stored != null) {
				token = stored.toString();
				for (index in 0...stored.length)
					stored.set(index, 0);
			}
		} catch (error:Dynamic) {
			lastError = dialer.backOff(Sys.time(), "relay_credential_unreadable");
			return;
		}
		if (token == null) {
			// The daemon stores the bearer on its first start; a daemon that attaches clears this.
			fail("relay_credential_missing");
			return;
		}
		dialer.dial(SuitRelayHosts.endpoint(host), token, function(opened, error) {
			if (disposed || paused || holder != null) {
				if (opened != null)
					opened.close();
				return;
			}
			if (opened == null) {
				if (RelayMachineDialer.isPermanent(error))
					fail(error);
				else
					lastError = dialer.backOff(Sys.time(), error);
				return;
			}
			opened.onFrame = onFrame;
			link = opened;
			lastError = null;
			dialer.connected();
		});
	}

	/** Stops trying until Retry (or a daemon attaches): suit no longer stays up for this workspace. */
	function fail(reason:String):Void {
		failure = reason;
		lastError = reason;
		closeLink();
		dropAllPending();
		clients.clear();
	}

	/** A frame from the relay: to the daemon, or into the buffer while the service starts. */
	function onFrame(frame:RelayFrame):Bool {
		var now = Sys.time();
		if (frame.reset)
			clients.reset(frame.channelId);
		else if (!clients.fromDevice(frame.channelId, now)) {
			// Disconnected and still in its cooldown: close it again.
			closeClient(frame.channelId);
			return true;
		}
		if (attached() && toDaemon(frame))
			return true;
		if (frame.reset) {
			dropPending(frame.channelId);
			return true;
		}
		// Over the bound the frame is dropped; the device's handshake times out and it retries.
		if (pending.length < MAX_PENDING_FRAMES && pendingBytes + frame.payload.length <= MAX_PENDING_BYTES) {
			pending.push({frame: frame, at: now});
			pendingBytes += frame.payload.length;
		}
		startService(now);
		return true;
	}

	function toDaemon(frame:RelayFrame):Bool {
		var current = daemon;
		if (current == null || !current.isOpen())
			return false;
		var packet = frame.reset ? RelayFrameCodec.encodeReset(frame.channelId) : RelayFrameCodec.encode(frame.channelId, frame.payload,
			RelaySocketLink.MAX_MESSAGE_BYTES);
		if (current.send(packet))
			return true;
		// The daemon is not keeping up; it reattaches and the device retries.
		closeDaemon();
		return false;
	}

	/** One relay envelope (or client report) from the daemon, checked and sent on; false for anything else. */
	function fromDaemon(message:Bytes):Bool {
		if (message.length > 0 && message.get(0) == SuitRelayProtocol.CLIENTS_KIND) {
			var report = null;
			try report = SuitRelayProtocol.parseClients(message) catch (_:Dynamic) {}
			if (report == null)
				return false;
			clients.setReport(report);
			return true;
		}
		if (message.length < RelayFrameCodec.ENVELOPE_BYTES + MessagePackFrame.HEADER_BYTES || message.get(0) != RelayFrameCodec.VERSION)
			return false;
		var channelId:String, payload:Bytes;
		try {
			var route = Bytes.alloc(RelayFrameCodec.ROUTE_BYTES);
			route.blit(0, message, 1, RelayFrameCodec.ROUTE_BYTES);
			channelId = RelayFrameCodec.encodeChannelId(route);
			payload = MessagePackFrame.unpack(Bytes.view(message, RelayFrameCodec.ENVELOPE_BYTES, message.length - RelayFrameCodec.ENVELOPE_BYTES),
				MessagePackFrame.CURRENT_VERSION, RelaySocketLink.MAX_MESSAGE_BYTES);
		} catch (_:Dynamic) {
			return false;
		}
		if (clients.isBlocked(channelId, Sys.time()))
			return true; // a disconnected client gets nothing more
		var socket = link;
		if (socket != null && socket.isOpen() && socket.sendRouted(channelId, payload)) // While reconnecting a frame is lost; Noise peers recover.
			clients.toDevice(channelId, Sys.time());
		return true;
	}

	/** Starts the workspace manager in the background, as an editor would, so its daemon attaches. */
	function startService(now:Float):Void {
		if (paused || failure != null || attached() || now - startedAt < startCooldown)
			return;
		while (startTimes.length > 0 && now - startTimes[0] > START_WINDOW_SECONDS)
			startTimes.shift();
		if (startTimes.length >= MAX_STARTS) {
			// Started this often without a daemon attaching: something is wrong with the workspace or its build.
			fail("service_start_failed_repeatedly");
			return;
		}
		startedAt = now;
		startTimes.push(now);
		starts++;
		try {
			// The manager finds its daemon bytecode through EXOSUIT_AGENT_LAUNCHER, as when an editor starts it.
			var keys = [SuitClient.libraryVariable(), "EXOSUIT_AGENT_LAUNCHER"];
			var values = [SuitClient.nativePath(host.launcher), host.launcher];
			var child = sys.io.Process.spawn(host.executable,
				[host.launcher, "--manager", host.root, "--state-dir", host.stateDir, "--detach"], host.root, keys, values, true);
			child.close();
		} catch (error:Dynamic) {
			lastError = "service_start_failed";
		}
	}

	static function testCooldown():Float {
		var home = Sys.getEnv("EXOSUIT_SUIT_HOME");
		var configured = Std.parseFloat(Sys.getEnv("EXOSUIT_SUIT_TEST_START_COOLDOWN"));
		return home != null && home.length > 0 && !Math.isNaN(configured) && configured >= 0 ? configured : START_COOLDOWN_SECONDS;
	}

	function expirePending(now:Float):Void {
		while (pending.length > 0 && now - pending[0].at > PENDING_MAX_AGE_SECONDS) {
			pendingBytes -= pending[0].frame.payload.length;
			pending.shift();
		}
	}

	function dropPending(id:String):Void {
		var index = pending.length;
		while (index-- > 0)
			if (pending[index].frame.channelId == id) {
				pendingBytes -= pending[index].frame.payload.length;
				pending.splice(index, 1);
			}
	}

	function dropAllPending():Void {
		pending.resize(0);
		pendingBytes = 0;
	}

	function sendStatus():Void {
		var current = daemon;
		if (current == null || !current.isOpen())
			return;
		var status:SuitRelayLinkStatus = {connected: connected(), error: connected() ? null : lastError};
		var text = Json.stringify(status);
		if (text == sentStatus)
			return;
		if (current.send(SuitRelayProtocol.statusMessage(status)))
			sentStatus = text;
	}

	function closeLink():Void {
		dialer.cancel();
		var socket = link;
		link = null;
		if (socket != null)
			socket.close();
	}

	function closeDaemon():Void {
		var current = daemon;
		daemon = null;
		servicePid = 0;
		if (current != null)
			current.close();
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		closeLink();
		closeDaemon();
		dialer.dispose();
	}
}
