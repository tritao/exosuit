package workspace.runtime;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import sys.io.ChildProcess;
import terminalsession.TerminalEvent;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	The service's connection to one terminal host (app.TerminalHostMain). Closing it while its program runs only
	detaches: the host keeps the program, and the next service adopts it (TerminalHosts.adopt).

	It reports what the host sends as events (`pollEvents`): output, the host's size (geometry), the end of the program
	(status), and the host's screen: a history event with the rendered scrollback, then a snapshot event with the exact
	screen. The screen comes on every attach (on a connection opened again, preceded by a reset event: the output stream
	starts again there), and after each `requestSnapshot`, in order with the output.
**/
class HostedPtyBackend {
	static var nextId:Int = 1;

	final idValue:String;
	final hub:NativeRpcHub;
	final pipe:String;
	final token:String;
	final hosts:TerminalHosts;
	/** The host's protocol (TerminalHostProtocol.VERSION); a version 1 host knows no SNAPSHOT or THEME. */
	final protocol:Int;
	/** True for a host found running at service start; false for one this service started. */
	public final adopted:Bool;
	/** The host's folder: its spec is removed when a host this service started never became ready. */
	final folder:Null<String>;
	/** An adopted host's process, as its `host.json` names it (0: unknown). */
	final hostPid:Int;
	final hostExecutable:Null<String>;
	var child:Null<ChildProcess>;
	var transport:Null<MessageTransport>;
	var attempt:Null<RpcConnectAttempt>;
	var connecting:Bool = false;
	var connectAt:Float = 0;
	/** When the pipe opened; the host's screen must follow within LIVE_SECONDS. */
	var openedAt:Float = 0;
	/** Nonzero while the connection to a host is being opened again after it broke: when to give up. */
	var reconnectUntil:Float = 0;
	/** Starts of the reconnects in the last minute: a connection that keeps breaking is opened again more slowly. */
	final reconnects:Array<Float> = [];
	static inline final RECONNECT_SECONDS = 20.0;
	static inline final LIVE_SECONDS = 30.0;
	final deadline:Float;
	final outgoing:Array<Bytes> = [];
	var outgoingBytes:Int = 0;
	/** The cost of the messages taken from the host since the last CREDIT: acknowledged at the end of each poll. */
	var taken:Int = 0;
	var wantedColumns:Int = 0;
	var wantedRows:Int = 0;
	var hostColumns:Int = 0;
	var hostRows:Int = 0;
	var history:Null<BytesOutput>;
	var screen:Null<BytesOutput>;
	var offset:haxe.Int64 = 0;
	var live:Bool = false;
	/** The host was live on an earlier connection of this backend. */
	var wasLive:Bool = false;
	/** The screen that comes next answers a request, not an attach: the output stream goes on. */
	var requested:Bool = false;
	var ended:Bool = false;
	var exitSeen:Bool = false;
	var killed:Bool = false;
	var closed:Bool = false;

	public function new(hosts:TerminalHosts, hub:NativeRpcHub, pipe:String, token:String, protocol:Int, child:Null<ChildProcess>,
			adopted:Bool, ?folder:String, hostPid:Int = 0, ?hostExecutable:String) {
		this.folder = folder;
		this.hostPid = hostPid;
		this.hostExecutable = hostExecutable;
		this.hosts = hosts;
		this.hub = hub;
		this.pipe = pipe;
		this.token = token;
		this.protocol = protocol;
		this.child = child;
		this.adopted = adopted;
		idValue = "hosted-" + nextId++;
		// A host being started needs its runtime to load. An adopted one is known to run (TerminalHosts.adopt), and a machine
		// that is busy right after a start must not cost a running terminal.
		deadline = Sys.time() + 20;
		outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.ATTACH, Bytes.ofString(token)));
		// This service acknowledges what it takes in, so the host sends no more than its pipe holds (TerminalHostProtocol).
		outgoing.push(TerminalHostProtocol.number(TerminalHostProtocol.CREDIT, 0));
	}

	/** True once the host's screen arrived on the current connection; output then follows it. */
	public function isLive():Bool return live;

	function connect():Void {
		connecting = true;
		var started:Null<RpcConnectAttempt> = null;
		try {
			started = hub.connect(NativeRpcHub.local(pipe), function(result) {
				connecting = false;
				attempt = null;
				switch result {
					case Opened(opened):
						if (closed) opened.close();
						else {
							transport = opened;
							openedAt = Sys.time();
						}
					case Failed(_, _):
						connectAt = Sys.time() + 0.1;
				}
			});
		} catch (_:Dynamic) {
			connecting = false;
			connectAt = Sys.time() + 0.5;
		}
		if (connecting) attempt = started;
	}

	function flush():Void {
		var link = transport;
		if (link == null) return;
		while (outgoing.length > 0 && link.send(outgoing[0])) outgoingBytes -= outgoing.shift().length;
		if (outgoingBytes < 0) outgoingBytes = 0;
	}

	function queue(message:Bytes):Void {
		outgoing.push(message);
		outgoingBytes += message.length;
		flush();
	}

	function fail(emit:TerminalEvent->Void, state:String, reason:String):Void {
		ended = true;
		// A host this service started that never became ready may not have read its spec: the program's environment and the
		// token must not stay behind (and a host that loads late finds nothing to start).
		var started = folder;
		if (!adopted && !live && started != null) TerminalHosts.removeSpec(started);
		ServiceLog.note("terminal host " + idValue + ": " + reason);
		emit(TerminalEvent.status(state, 0));
	}

	public function write(bytes:Bytes):Void {
		ensureOpen();
		if (bytes == null || bytes.length == 0 || ended) return;
		if (outgoingBytes + bytes.length > 1048576) throw "PTY input queue is full";
		var position = 0;
		while (position < bytes.length) {
			var count = bytes.length - position > 60000 ? 60000 : bytes.length - position;
			outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.INPUT, bytes, position, count));
			outgoingBytes += count + 1;
			position += count;
		}
		flush();
	}

	public function resize(columns:Int, rows:Int):Void {
		ensureOpen();
		if (columns < 1 || columns > TerminalHostProtocol.MAX_COLUMNS || rows < 1 || rows > TerminalHostProtocol.MAX_ROWS)
			throw "Terminal size is outside the terminal host's limits";
		queue(TerminalHostProtocol.pair(TerminalHostProtocol.RESIZE, columns, rows));
		wantedColumns = columns;
		wantedRows = rows;
	}

	/** The terminal's default colours (0xRRGGBB): the host's emulator takes them and tells a program that asked. */
	public function theme(foreground:Int, background:Int):Void {
		ensureOpen();
		if (!ended && protocol >= 2) queue(TerminalHostProtocol.numbers(TerminalHostProtocol.THEME, foreground, background));
	}

	/**
		Asks the host for its screen: it arrives as history and snapshot events, in order with the output. Before the
		screen of the current connection arrived nothing is asked: that one comes anyway. A version 1 host is attached
		to again, which sends it.
	**/
	public function requestSnapshot():Void {
		ensureOpen();
		if (ended || !live || requested) return;
		requested = true;
		if (protocol >= 2) queue(TerminalHostProtocol.message(TerminalHostProtocol.SNAPSHOT));
		else reopen(Sys.time(), "a version 1 host sends its screen on attach");
	}

	/**
		Geometry events here are only the host's: the size its screen had when this service attached, and, once the screen
		has arrived, the size this service asked for meanwhile (the host applies that request after sending its screen).
	**/
	public function pollEvents(emit:TerminalEvent->Void):Void {
		ensureOpen();
		if (ended) return;
		var now = Sys.time();
		var link = transport;
		if (link == null) {
			if (!connecting && now >= connectAt) connect();
			link = transport;
			if (link == null) {
				var process = child;
				if (process != null && process.pollExit() >= 0)
					fail(emit, reconnectUntil > 0 ? "lost" : "failed", reconnectUntil > 0 ? "the host ended while its connection was down"
						: "the host exited before it was ready (see host.log in the terminal's host folder)");
				else if (reconnectUntil > 0) {
					if (now >= reconnectUntil) fail(emit, "lost", "the connection to the host closed and could not be opened again");
				} else if (now >= deadline) {
					// A host that runs but did not answer in time (a busy machine, a suspended process) is lost for now: the
					// service tries it again (WorkspaceTerminalManager.readopt).
					fail(emit, adopted ? "lost" : "failed", !adopted ? "the host did not become ready"
						: !hostRuns() ? "the host left by an earlier service is gone"
						: "the host left by an earlier service runs but did not answer; it is tried again later");
				}
				return;
			}
		}
		flush();
		for (_ in 0...16) {
			var message = link.receive();
			if (message == null || message.length == 0) break;
			taken += TerminalHostProtocol.cost(message);
			var kind = message.get(0);
			if (kind == TerminalHostProtocol.GEOMETRY) {
				var columns = TerminalHostProtocol.pairFirst(message), rows = TerminalHostProtocol.pairSecond(message);
				if (columns >= 1 && rows >= 1) {
					hostColumns = columns;
					hostRows = rows;
					emit(TerminalEvent.geometry(columns, rows));
				}
			} else if (kind == TerminalHostProtocol.HISTORY) {
				var buffer = history;
				if (buffer == null) {
					buffer = new BytesOutput();
					history = buffer;
				}
				if (message.length > 1) buffer.writeBytes(message, 1, message.length - 1);
			} else if (kind == TerminalHostProtocol.OUTPUT) {
				if (message.length > 1) {
					var data = message.sub(1, message.length - 1);
					emit(TerminalEvent.output(offset, data, data.length));
					offset += data.length;
				}
			} else if (kind == TerminalHostProtocol.SCREEN) {
				var buffer = screen;
				if (buffer == null) {
					buffer = new BytesOutput();
					screen = buffer;
				}
				if (message.length > 1) buffer.writeBytes(message, 1, message.length - 1);
			} else if (kind == TerminalHostProtocol.LIVE) {
				if (!live && !requested && wasLive) emit(TerminalEvent.resetReplay());
				live = true;
				wasLive = true;
				requested = false;
				if (reconnectUntil > 0) {
					reconnectUntil = 0;
					ServiceLog.note("terminal host " + idValue + ": connected again; the screen was taken from the host anew");
				}
				var rendered = history == null ? null : history.getBytes();
				var exact = screen == null ? null : screen.getBytes();
				history = null;
				screen = null;
				if (rendered != null && rendered.length > 0) emit(TerminalEvent.history(rendered));
				if (exact != null && exact.length > 0) emit(TerminalEvent.screenSnapshot(offset, exact));
				if (wantedColumns > 0 && (wantedColumns != hostColumns || wantedRows != hostRows))
					emit(TerminalEvent.geometry(wantedColumns, wantedRows));
			} else if (kind == TerminalHostProtocol.EXITED) {
				ended = true;
				exitSeen = true;
				emit(TerminalEvent.status("exited", TerminalHostProtocol.numberOf(message)));
				return;
			}
		}
		if (taken > 0 && link.isOpen()) {
			queue(TerminalHostProtocol.number(TerminalHostProtocol.CREDIT, taken));
			taken = 0;
		}
		if (!link.isOpen() && !ended) {
			// Whatever broke the connection, a host that still runs keeps the program: this service takes it back, also
			// when the break came before the host's screen did (on the first attach or during a reconnect).
			if (hostRuns()) {
				reconnect(now);
				return;
			}
			fail(emit, live || adopted ? "lost" : "failed", "the connection to the host closed" + why(link));
		}
		else if (!live && !ended && now - openedAt >= LIVE_SECONDS)
			// The pipe opened but the screen never came: not shown as a running, blank terminal for ever. The record stays.
			fail(emit, "lost", "the host accepted the connection but did not send its screen");
	}

	/**
		Whether the host process still runs: the one this service started, or the one an adopted `host.json` names. True
		when that cannot be told (an adopted host whose record names no process).
	**/
	function hostRuns():Bool {
		var process = child;
		if (process != null) return process.pollExit() < 0;
		return hostPid <= 0 || app.AgentNative.processAlive(hostPid, hostExecutable);
	}

	/**
		The connection to a host that runs closed while this service runs (the host dropped a service that took no output
		for a minute, another connection took the host for a moment, or the pipe failed): open it again in place. The host
		then sends its size, history and screen as on any attach, and the terminal stays running for its views. A
		connection that keeps breaking is opened again more slowly, ten seconds apart after five breaks in a minute, but
		not given up on: given up, the terminal would be shown ended while its host kept the program running with nothing
		attached. It is given up only when the host ends, or does not take a connection for RECONNECT_SECONDS (lost: the
		service tries it again later).
	**/
	function reconnect(now:Float):Void {
		while (reconnects.length > 0 && now - reconnects[0] > 60) reconnects.shift();
		reconnects.push(now);
		reopen(now + (reconnects.length > 5 ? 10.0 : 0.2 * reconnects.length), "the connection closed while the program runs" + why(transport));
		requested = false;
		reconnectUntil = connectAt + RECONNECT_SECONDS;
	}

	/** Drops the current connection and opens another at `at`, which the host answers with its screen as on any attach. */
	function reopen(at:Float, reason:String):Void {
		var link = transport;
		transport = null;
		if (link != null) link.close();
		live = false;
		history = null;
		screen = null;
		connecting = false;
		var started = attempt;
		attempt = null;
		if (started != null) try started.cancel() catch (_:Dynamic) {}
		connectAt = at;
		// Input and resizes that did not leave before the break follow the new ATTACH; the size asked for last is sent
		// again in case its message was lost with the connection.
		// Acknowledgements belong to the connection that broke: the host counts afresh from the new ATTACH. An ATTACH
		// that never left (the pipe broke first) is not sent twice.
		taken = 0;
		for (message in outgoing.copy())
			if (message.length > 0 && (message.get(0) == TerminalHostProtocol.CREDIT || message.get(0) == TerminalHostProtocol.ATTACH)) {
				outgoing.remove(message);
				outgoingBytes -= message.length;
			}
		if (outgoingBytes < 0) outgoingBytes = 0;
		outgoing.unshift(TerminalHostProtocol.number(TerminalHostProtocol.CREDIT, 0));
		outgoing.unshift(TerminalHostProtocol.message(TerminalHostProtocol.ATTACH, Bytes.ofString(token)));
		if (wantedColumns > 0) outgoing.push(TerminalHostProtocol.pair(TerminalHostProtocol.RESIZE, wantedColumns, wantedRows));
		ServiceLog.note("terminal host " + idValue + ": " + reason + "; connecting again");
	}

	/** Why `link` closed, as " (reason)" for a log line, or nothing when that is not known. */
	static function why(link:Null<MessageTransport>):String {
		var reason = link != null && Std.isOfType(link, NativeRpcTransport) ? (cast link:NativeRpcTransport).failureReason() : null;
		return reason == null ? "" : " (" + reason + ")";
	}

	/** Ends the program; the host reports its exit code. */
	public function kill():Void {
		ensureOpen();
		if (ended) return;
		killed = true;
		queue(TerminalHostProtocol.message(TerminalHostProtocol.KILL));
	}

	/**
		Lets go of the host. A host whose program ended, or was told to end, is told to end too; any other keeps its program
		running for the next service.
	**/
	public function close():Void {
		if (closed) return;
		closed = true;
		var started = attempt;
		attempt = null;
		if (started != null) try started.cancel() catch (_:Dynamic) {}
		var link = transport;
		transport = null;
		var ending = killed || exitSeen;
		if (link != null) {
			if (ending && live) {
				outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.END));
				hosts.drain(link, outgoing.copy());
			} else link.close();
		}
		outgoing.resize(0);
		var process = child;
		child = null;
		if (process != null) try process.close() catch (_:Dynamic) {}
		// Told to end before the host was attached (or after its pipe was lost): this connection cannot carry the END, and
		// the host would keep the program running with nothing left that knows it.
		var directory = folder;
		if (killed && !live && directory != null) hosts.endFolder(directory, "the terminal was closed before its host was attached");
	}

	function ensureOpen():Void {
		if (closed) throw "PTY backend is closed";
	}
}
