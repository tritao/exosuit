package suit.relay;

import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import haxeon.wire.MessagePackFrame;
import suit.SuitClient;
import suit.relay.SuitRelayHosts.SuitRelayHost;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;
import workspace.transport.RelayFrame;
import workspace.transport.RelayFrameCodec;
import workspace.transport.RelayMachineConnectAttempt;
import workspace.transport.RelayMachineConnector;
import workspace.transport.RelaySocketLink;

/** What the tray, `suit relay list` and `relay-state.json` show for one hosted workspace. */
typedef SuitRelayHostView = {
	var root:String;
	var stateDir:String;
	var machineId:String;
	var origin:String;
	/** connected, connecting, error or paused. */
	var state:String;
	var error:Null<String>;
	/** Whether a workspace daemon is attached, that is whether the workspace service is running. */
	var serviceRunning:Bool;
	var servicePid:Int;
	/** How many times suit started the workspace service for a device. */
	var starts:Int;
}

/**
	One hosted workspace: suit's machine socket to the relay and the attached daemon's relay link.

	Frames pass through without being opened; suit reads only the 16-byte channel id. While no daemon is
	attached, frames wait in a bounded buffer (a reset drops its channel's frames) and suit starts the
	workspace manager, at most once per START_COOLDOWN_SECONDS. The daemon gets them in order once it
	attaches. Every (re)connect reads the bearer from the OS credential store and keeps it only for that
	attempt.
**/
class SuitRelayBridge {
	static inline var MAX_PENDING_FRAMES:Int = 64;
	static inline var MAX_PENDING_BYTES:Int = 2097152;
	static inline var START_COOLDOWN_SECONDS:Float = 30;
	static inline var MAX_RETRY_SECONDS:Float = 30;

	public var host(default, null):SuitRelayHost;
	public var paused(default, null):Bool;
	public var lastError(default, null):Null<String> = null;
	public var servicePid(default, null):Int = 0;
	public var starts(default, null):Int = 0;

	final connector:RelayMachineConnector;
	final pending:Array<RelayFrame> = [];
	var pendingBytes:Int = 0;
	var link:Null<RelaySocketLink> = null;
	var attempt:Null<RelayMachineConnectAttempt> = null;
	var daemon:Null<NativeRpcTransport> = null;
	var sentStatus:String = "";
	var retryAt:Float = 0;
	var retryDelay:Float = 1;
	var startedAt:Float = -1e9;
	var permanent:Bool = false;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, hub:NativeRpcHub, host:SuitRelayHost, paused:Bool) {
		this.host = host;
		this.paused = paused;
		connector = new RelayMachineConnector(events, hub, Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1");
	}

	public function connected():Bool {
		var current = link;
		return current != null && current.isOpen();
	}

	public function attached():Bool {
		var current = daemon;
		return current != null && current.isOpen();
	}

	/** Work the daemon loop should wake for promptly. */
	public function busy():Bool
		return attached() || pending.length > 0 || attempt != null;

	public function view():SuitRelayHostView {
		var state = paused ? "paused" : connected() ? "connected" : permanent ? "error" : lastError != null && attempt == null ? "error" : "connecting";
		return {
			root: host.root,
			stateDir: host.stateDir,
			machineId: host.machineId,
			origin: host.origin,
			state: state,
			error: paused ? null : lastError,
			serviceRunning: attached(),
			servicePid: attached() ? servicePid : 0,
			starts: starts
		};
	}

	/** Takes over a daemon's link (closing an older one), answers its attach and hands it the waiting frames. */
	public function attach(transport:NativeRpcTransport, pid:Int, current:SuitRelayHost):Void {
		host = current;
		var previous = daemon;
		if (previous != null && previous != transport)
			previous.close();
		daemon = transport;
		servicePid = pid;
		sentStatus = "";
		if (!transport.send(Bytes.ofString(haxe.Json.stringify({ok: true})))) {
			transport.close();
			daemon = null;
			return;
		}
		if (permanent && lastError == "relay_credential_missing") {
			// The daemon just stored the bearer; try again now.
			permanent = false;
			retryAt = 0;
		}
		sendStatus();
		var waiting = pending.copy();
		pending.resize(0);
		pendingBytes = 0;
		for (frame in waiting)
			if (!toDaemon(frame))
				break;
	}

	/** Stops hosting until `resume`: closes the machine socket and the daemon's link. */
	public function pause():Void {
		paused = true;
		closeLink();
		var current = daemon;
		daemon = null;
		servicePid = 0;
		if (current != null)
			current.close();
		pending.resize(0);
		pendingBytes = 0;
	}

	public function resume():Void {
		paused = false;
		permanent = false;
		lastError = null;
		retryAt = 0;
		retryDelay = 1;
	}

	public function poll(now:Float):Void {
		if (disposed || paused)
			return;
		var current = daemon;
		if (current != null) {
			if (!current.isOpen()) {
				daemon = null;
				servicePid = 0;
			} else
				for (_ in 0...64) {
					var message = current.receive();
					if (message == null)
						break;
					if (!fromDaemon(message)) {
						current.close();
						daemon = null;
						servicePid = 0;
						break;
					}
				}
		}
		var socket = link;
		if (socket != null) {
			socket.poll();
			if (!socket.isOpen()) {
				link = null;
				scheduleRetry(now, socket.failure);
			}
		}
		if (link == null && attempt == null && !permanent && now >= retryAt)
			connect();
		sendStatus();
	}

	function connect():Void {
		var token:Null<String> = null;
		try {
			var stored = WorkspaceCredentialStores.relay().read(WorkspaceCredentialStores.machineAccount(SuitRelayHosts.endpoint(host)));
			if (stored != null) {
				token = stored.toString();
				for (index in 0...stored.length)
					stored.set(index, 0);
			}
		} catch (error:Dynamic) {
			lastError = "relay_credential_unreadable";
			scheduleRetry(Sys.time(), lastError);
			return;
		}
		if (token == null) {
			// The daemon stores the bearer on its first start; it is retried when a daemon attaches.
			lastError = "relay_credential_missing";
			permanent = true;
			return;
		}
		var completedSynchronously = false;
		var returned:Null<RelayMachineConnectAttempt> = null;
		returned = connector.connect(SuitRelayHosts.endpoint(host), token, function(opened, error) {
			completedSynchronously = true;
			if (returned != null && attempt == returned)
				attempt = null;
			if (disposed || paused) {
				if (opened != null)
					opened.close();
				return;
			}
			if (opened == null) {
				lastError = error == null ? "relay_connect_failed" : error;
				if (lastError == "relay_unauthorized" || lastError == "machine_identity_conflict") {
					permanent = true;
					return;
				}
				scheduleRetry(Sys.time(), lastError);
				return;
			}
			opened.onFrame = onFrame;
			link = opened;
			lastError = null;
			retryDelay = 1;
			retryAt = 0;
		});
		if (!completedSynchronously)
			attempt = returned;
	}

	/** A frame from the relay: to the daemon, or into the buffer while the service starts. */
	function onFrame(frame:RelayFrame):Bool {
		if (attached() && toDaemon(frame))
			return true;
		if (frame.reset) {
			var index = pending.length;
			while (index-- > 0)
				if (pending[index].channelId == frame.channelId) {
					pendingBytes -= pending[index].payload.length;
					pending.splice(index, 1);
				}
			return true;
		}
		// Over the bound the frame is dropped; the device's handshake times out and it retries.
		if (pending.length < MAX_PENDING_FRAMES && pendingBytes + frame.payload.length <= MAX_PENDING_BYTES) {
			pending.push(frame);
			pendingBytes += frame.payload.length;
		}
		startService();
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
		current.close();
		daemon = null;
		servicePid = 0;
		return false;
	}

	/** One relay envelope from the daemon, checked and sent on; false for anything that is not one. */
	function fromDaemon(message:Bytes):Bool {
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
		var socket = link;
		if (socket != null && socket.isOpen())
			socket.sendRouted(channelId, payload); // While reconnecting a frame is lost; Noise peers recover by reconnecting.
		return true;
	}

	/** Starts the workspace manager in the background, as an editor would, so its daemon attaches. */
	function startService():Void {
		var now = Sys.time();
		if (paused || attached() || now - startedAt < START_COOLDOWN_SECONDS)
			return;
		startedAt = now;
		starts++;
		try {
			// The manager finds its daemon bytecode through EXOSUIT_AGENT_LAUNCHER, as when an editor starts it.
			var keys = [SuitClient.libraryVariable(), "EXOSUIT_RELAY_VIA_SUIT", "EXOSUIT_AGENT_LAUNCHER"];
			var values = [SuitClient.nativePath(host.launcher), "1", host.launcher];
			var child = sys.io.Process.spawn(host.executable,
				[host.launcher, "--manager", host.root, "--state-dir", host.stateDir, "--detach"], host.root, keys, values, true);
			child.close();
		} catch (error:Dynamic) {
			lastError = "service_start_failed";
		}
	}

	function sendStatus():Void {
		var current = daemon;
		if (current == null || !current.isOpen())
			return;
		var status:SuitRelayProtocol.SuitRelayLinkStatus = {connected: connected(), error: connected() ? null : lastError};
		var text = haxe.Json.stringify(status);
		if (text == sentStatus)
			return;
		if (current.send(SuitRelayProtocol.statusMessage(status)))
			sentStatus = text;
	}

	function scheduleRetry(now:Float, reason:Null<String>):Void {
		lastError = reason == null || reason == "closed" ? "relay_disconnected" : reason;
		retryAt = now + retryDelay;
		retryDelay = Math.min(retryDelay * 2, MAX_RETRY_SECONDS);
	}

	function closeLink():Void {
		var pendingAttempt = attempt;
		attempt = null;
		if (pendingAttempt != null)
			pendingAttempt.cancel();
		var socket = link;
		link = null;
		if (socket != null)
			socket.close();
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		closeLink();
		var current = daemon;
		daemon = null;
		if (current != null)
			current.close();
		connector.dispose();
	}
}
