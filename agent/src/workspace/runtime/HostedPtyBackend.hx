package workspace.runtime;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import sys.io.ChildProcess;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	A terminal whose PTY lives in a terminal host (app.TerminalHostMain), seen by the service as a backend like the
	in-process one. Closing it while its program runs only detaches: the host keeps the program, and the next service
	generation adopts it (TerminalHosts.adopt).

	On attach the host sends the terminal's size, its rendered history and its exact screen before any new output, so the
	service's own emulator and replay log start from what the program has drawn so far. They arrive here as ordinary
	events: geometry, output, then one screen snapshot.
**/
class HostedPtyBackend implements TerminalBackend {
	static var nextId:Int = 1;

	final idValue:String;
	final hub:NativeRpcHub;
	final pipe:String;
	final token:String;
	final hosts:TerminalHosts;
	/** True for a host found running at service start; false for one this service started. */
	public final adopted:Bool;
	/** An adopted host's `host.json`: removed when its pipe never opened, so later services do not try the host again. */
	final record:Null<String>;
	/** The host's folder: where an end request goes when the host cannot be told over its pipe. */
	final folder:Null<String>;
	/** An adopted host's process, as its `host.json` names it (0: unknown). */
	final hostPid:Int;
	/** The final file this backend reads instead of a host; removed once its exit code was delivered. */
	final finalPath:Null<String>;
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
	var screen:Null<BytesOutput>;
	var offset:haxe.Int64 = 0;
	var live:Bool = false;
	var ended:Bool = false;
	var exitSeen:Bool = false;
	/**
		True from the first HISTORY chunk of a connection until its LIVE. The history starts by clearing the screen and the
		scrollback, so in between the service's emulator holds only part of the terminal's history: it must not be saved
		over the whole one the store has (a connection that broke there and was given up left it truncated).
	**/
	var replaying:Bool = false;
	var killed:Bool = false;
	var closed:Bool = false;

	public function new(hosts:TerminalHosts, hub:NativeRpcHub, pipe:String, token:String, child:Null<ChildProcess>, adopted:Bool,
			?record:String, ?folder:String, hostPid:Int = 0, ?hostExecutable:String, ?recorded:MessageTransport, ?finalPath:String) {
		this.finalPath = finalPath;
		if (recorded != null) {
			// A host's final file instead of a host: there is nothing to connect to.
			transport = recorded;
			openedAt = Sys.time();
		}
		this.record = record;
		this.folder = folder;
		this.hostPid = hostPid;
		this.hostExecutable = hostExecutable;
		this.hosts = hosts;
		this.hub = hub;
		this.pipe = pipe;
		this.token = token;
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

	public function id():String return idValue;

	/** True while the host owns a program this service can no longer reach or has not reached yet. */
	public function isLive():Bool return live;

	/** True while the emulator fed by this backend holds a history the host has not finished sending (see `replaying`). */
	public function midReplay():Bool return replaying;

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
		// The host ignores a size outside these bounds; refusing it here keeps this service's emulator at the host's size.
		if (columns < 1 || columns > TerminalHostProtocol.MAX_COLUMNS || rows < 1 || rows > TerminalHostProtocol.MAX_ROWS)
			throw "Terminal size is outside the terminal host's limits";
		queue(TerminalHostProtocol.pair(TerminalHostProtocol.RESIZE, columns, rows));
		wantedColumns = columns;
		wantedRows = rows;
	}

	/**
		Geometry events here are only the host's: the size its screen had when this service attached, and, once the screen
		has arrived, the size this service asked for meanwhile (the host applies that request after sending its screen).
		The service resizes its own emulator to follow them; its own later resizes need no event.
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
					// The record goes only with the process: a host that runs but did not answer in time (a busy machine, a
					// suspended process) keeps it, so a later service can take the terminal back.
					var stale = record;
					var gone = hostPid > 0 && !app.AgentManagerNative.processAlive(hostPid, hostExecutable);
					if (stale != null && gone) try sys.FileSystem.deleteFile(stale) catch (_:Dynamic) {}
					fail(emit, adopted ? "lost" : "failed", !adopted ? "the host did not become ready"
						: gone ? "the host left by an earlier service is gone"
						: "the host left by an earlier service runs but did not answer; a later service will try it again");
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
			} else if (kind == TerminalHostProtocol.HISTORY || kind == TerminalHostProtocol.OUTPUT) {
				if (kind == TerminalHostProtocol.HISTORY && !live) replaying = true;
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
				live = true;
				replaying = false;
				if (reconnectUntil > 0) {
					reconnectUntil = 0;
					ServiceLog.note("terminal host " + idValue + ": connected again; the screen was taken from the host anew");
				}
				var buffer = screen;
				screen = null;
				if (buffer != null) {
					var snapshot = buffer.getBytes();
					if (snapshot.length > 0) emit(TerminalEvent.screenSnapshot(offset, snapshot));
				}
				if (wantedColumns > 0 && (wantedColumns != hostColumns || wantedRows != hostRows))
					emit(TerminalEvent.geometry(wantedColumns, wantedRows));
			} else if (kind == TerminalHostProtocol.EXITED) {
				ended = true;
				exitSeen = true;
				emit(TerminalEvent.status("exited", TerminalHostProtocol.numberOf(message)));
				return;
			}
		}
		if (taken > 0 && finalPath == null && link.isOpen()) {
			queue(TerminalHostProtocol.number(TerminalHostProtocol.CREDIT, taken));
			taken = 0;
		}
		if (!link.isOpen() && !ended) {
			// Whatever broke the connection, a host that still runs keeps the program: this service takes it back, also
			// when the break came before the host's screen did (on the first attach or during a reconnect).
			if (finalPath == null && hostRuns()) {
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
		return hostPid <= 0 || app.AgentManagerNative.processAlive(hostPid, hostExecutable);
	}

	/**
		The connection to a host that runs closed while this service runs (the host dropped a service that took no output
		for a minute, another connection took the host for a moment, or the pipe failed): open it again in place. The host
		then sends its size, history and screen as on any attach, and the terminal stays running for its views. A
		connection that keeps breaking is opened again more slowly, ten seconds apart after five breaks in a minute, but
		not given up on: given up, the terminal would be shown ended while its host kept the program running with nothing
		attached. It is given up only when the host ends, or does not take a connection for RECONNECT_SECONDS (lost: the
		host keeps its record and the next service tries it again).
	**/
	function reconnect(now:Float):Void {
		while (reconnects.length > 0 && now - reconnects[0] > 60) reconnects.shift();
		reconnects.push(now);
		var link = transport;
		transport = null;
		if (link != null) link.close();
		live = false;
		screen = null;
		connecting = false;
		attempt = null;
		connectAt = now + (reconnects.length > 5 ? 10.0 : 0.2 * reconnects.length);
		reconnectUntil = connectAt + RECONNECT_SECONDS;
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
		ServiceLog.note("terminal host " + idValue + ": the connection closed while the program runs" + why(link) + "; connecting again");
	}

	/** Why `link` closed, as " (reason)" for a log line, or nothing when that is not known. */
	static function why(link:Null<MessageTransport>):String {
		var reason = link != null && Std.isOfType(link, NativeRpcTransport) ? (cast link:NativeRpcTransport).failureReason() : null;
		return reason == null ? "" : " (" + reason + ")";
	}

	public function requestReplay(offset:haxe.Int64):Void {
		throw "Hosted PTY output cannot replay";
	}

	public function terminate(force:Bool):Void {
		ensureOpen();
		if (ended) return;
		if (force) {
			killed = true;
			queue(TerminalHostProtocol.message(TerminalHostProtocol.KILL));
		} else write(Bytes.ofString("\x03"));
	}

	public function detach():Void { ensureOpen(); }

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
		var consumed = finalPath;
		if (consumed != null && exitSeen) try sys.FileSystem.deleteFile(consumed) catch (_:Dynamic) {}
		var link = transport;
		transport = null;
		if (link != null) {
			if (consumed != null) link.close();
			else if (killed || exitSeen) {
				outgoing.push(TerminalHostProtocol.message(TerminalHostProtocol.END));
				hosts.drain(link, outgoing.copy());
			} else link.close();
		}
		// Closed for good before the host answered (or after its pipe was lost): the pipe cannot carry the END, and the
		// host would keep the program running with nothing left that knows it. Its folder can.
		if (killed && (link == null || !live) && folder != null)
			try suit.TerminalHostFolder.requestEnd(folder, "the terminal was closed before its host was attached", hostPid > 0 ? hostPid : null,
				TerminalHostProtocol.instanceOf(token)) catch (_:Dynamic) {}
		outgoing.resize(0);
		var process = child;
		child = null;
		if (process != null) try process.close() catch (_:Dynamic) {}
	}

	function ensureOpen():Void {
		if (closed) throw "PTY backend is closed";
	}
}
