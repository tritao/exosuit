package workspace.runtime;

import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Path;

/** A terminal's size, rendered history, exact screen and exit, as a host sends them (TerminalHostProtocol.screenOf). */
typedef TerminalScreen = {
	var columns:Int;
	var rows:Int;
	var history:Bytes;
	var screen:Bytes;
	var exited:Bool;
	var exitCode:Int;
}

/** What a terminal host is asked to run: written by the service as `spec.bin`, read once by the host. */
typedef TerminalHostSpec = {
	var token:String;
	var pipe:String;
	var columns:Int;
	var rows:Int;
	var program:String;
	var cwd:String;
	var arguments:Array<String>;
	/** `NAME=value` entries: the whole environment of the terminal's program. */
	var environment:Array<String>;
	/**
		Output fed to the host's emulator before the program starts: for Restart Terminal, the earlier program's rendered
		history and a separator, so the terminal keeps its past. Empty for a new terminal.
	**/
	var prelude:Bytes;
}

/**
	The few messages a workspace service and a terminal host exchange (see docs/design/terminal-host-status.md). A host
	runs the code it was started with for as long as its terminal lives, while services come and go, so this stays small
	and only grows: a message is one kind byte and a payload, framed by the transport.

	The host's emulator is the terminal's only screen: the service keeps none. It asks the host for the screen when a view
	needs one (SNAPSHOT), and relays the output in between.

	Service to host: ATTACH (the token), INPUT (bytes), RESIZE (columns, rows), THEME (default colours), SNAPSHOT, KILL
	(end the program), END (end the host), CREDIT (bytes taken).
	Host to service, after ATTACH and after each SNAPSHOT: GEOMETRY, HISTORY chunks (rendered scrollback and screen),
	SCREEN chunks (the exact screen, cursor and modes), LIVE. Then OUTPUT as the program writes and EXITED when it ends.

	Flow: a NativeKit stream reads its peer as fast as the peer writes and closes when more than its receive buffer
	(1 MiB, NativeRpcHub.local) waits unread, so a host must not send faster than its service takes messages in. The
	service sends CREDIT right after ATTACH, and a CREDIT with the cost of what it took since each time it takes messages;
	the host sends at most WINDOW bytes of messages it has not taken, and reads no more of its program's output meanwhile,
	so the program waits.
**/
class TerminalHostProtocol {
	/**
		Written to `host.json` as `protocol`. A service adopts hosts of its own number and older ones, never newer ones.
		Version 1 hosts know no SNAPSHOT or THEME and answer the program's queries only while no service is attached
		(HostedPtyBackend asks them for the screen by attaching again). The SCREEN payload carries its own format number
		(Emulator.screenSnapshot, "PTSMVTS" and a version the restore checks); HISTORY is plain terminal output.
	**/
	public static inline final VERSION = 2;
	/** The largest terminal either side accepts; the same as the service's own limit for its clients. */
	public static inline final MAX_COLUMNS = 512;
	public static inline final MAX_ROWS = 256;
	/**
		Lines kept above the screen by a host's emulator, by the service's and by a view's: what a terminal shows of its
		past after a service restart. The rendered history that carries them is also bounded to 16 MiB
		(terminalkit_history_copy), which drops the oldest lines of very long ones. Scrollback lines keep only their
		written cells (libtsm line_trim), so a terminal's memory follows what it printed rather than rows times columns.
	**/
	public static inline final SCROLLBACK_ROWS = 10000;
	/** Payload bytes per HISTORY, SCREEN or OUTPUT message; a framed message stays under the transport's 256 KiB. */
	public static inline final CHUNK = 196608;

	public static inline final ATTACH = 0x41;
	public static inline final INPUT = 0x49;
	public static inline final RESIZE = 0x52;
	public static inline final KILL = 0x4B;
	public static inline final END = 0x45;
	public static inline final CREDIT = 0x43;
	public static inline final SNAPSHOT = 0x50;
	public static inline final THEME = 0x54;

	/**
		The most a host sends that its service has not acknowledged with CREDIT, counted in `cost`: half the service's
		1 MiB receive buffer. (With nothing unacknowledged a host sends its next message whatever its size, at most CHUNK.)
	**/
	public static inline final WINDOW = 524288;

	/** What a message counts against the window: its bytes on the pipe, with the transport's 10-byte frame header. */
	public static inline function cost(message:Bytes):Int
		return message.length + 10;

	public static inline final GEOMETRY = 0x47;
	public static inline final HISTORY = 0x48;
	public static inline final SCREEN = 0x53;
	public static inline final LIVE = 0x4C;
	public static inline final OUTPUT = 0x4F;
	public static inline final EXITED = 0x58;

	/**
		The terminal's last screen, kept in the host's folder: written by the host when its program ends, and every
		SCREEN_SAVE_SECONDS or more while output comes, so a terminal whose host is gone (a reboot) still shows what it
		showed. The messages a service gets on attaching (GEOMETRY, HISTORY, SCREEN, LIVE, and EXITED once the program
		ended), each behind its length.
	**/
	public static inline final SCREEN_FILE = "screen.bin";
	public static inline final SCREEN_SAVE_SECONDS = 30.0;
	static inline final SCREEN_MAGIC = 0x4E494658; // "XFIN"

	public static function encodeScreen(messages:Array<Bytes>):Bytes {
		var output = new BytesOutput();
		writeU32(output, SCREEN_MAGIC);
		writeU32(output, VERSION);
		writeU32(output, messages.length);
		for (entry in messages) {
			writeU32(output, entry.length);
			output.write(entry);
		}
		return output.getBytes();
	}

	/** The messages of a screen file; throws when it is not one this build reads. */
	public static function decodeScreen(bytes:Bytes):Array<Bytes> {
		var position = [0];
		if (number32(bytes, position) != SCREEN_MAGIC) throw "Not a terminal screen file";
		var version = number32(bytes, position);
		if (version < 1 || version > VERSION) throw "Unsupported terminal screen file";
		var count = number32(bytes, position);
		if (count < 1 || count > 4096) throw "Invalid terminal screen file";
		var messages:Array<Bytes> = [];
		for (_ in 0...count) {
			var length = number32(bytes, position), offset = position[0];
			if (length < 1 || length > CHUNK + 1 || offset + length > bytes.length) throw "Truncated terminal screen file";
			messages.push(bytes.sub(offset, length));
			position[0] = offset + length;
		}
		return messages;
	}

	/** What a screen file or an attach holds, put together: the size, the rendered history, the exact screen and the exit. */
	public static function screenOf(messages:Array<Bytes>):TerminalScreen {
		var history = new BytesOutput(), screen = new BytesOutput();
		var result:TerminalScreen = {columns: 80, rows: 24, history: null, screen: null, exited: false, exitCode: 0};
		for (message in messages) {
			if (message.length == 0) continue;
			var kind = message.get(0);
			if (kind == GEOMETRY) {
				result.columns = pairFirst(message);
				result.rows = pairSecond(message);
			} else if (kind == HISTORY) history.writeBytes(message, 1, message.length - 1);
			else if (kind == SCREEN) screen.writeBytes(message, 1, message.length - 1);
			else if (kind == EXITED) {
				result.exited = true;
				result.exitCode = numberOf(message);
			}
		}
		result.history = history.getBytes();
		result.screen = screen.getBytes();
		return result;
	}

	/** The folder of one terminal's host inside its workspace's state folder. */
	public static function directory(stateDirectory:String, terminal:String):String
		return Path.join([stateDirectory, "terminal-hosts", Sha256.encode(terminal).substr(0, 24)]);

	/**
		The id of the host started with `token`: in its `host.json` and in end requests meant for it. Derived from the
		token, so the service that started the host knows it, without the token itself leaving the private files.
	**/
	public static function instanceOf(token:String):String
		return Sha256.encode("terminal-host-instance:" + token).substr(0, 16);

	public static function message(kind:Int, ?payload:Bytes, offset:Int = 0, length:Int = -1):Bytes {
		var output = new BytesOutput();
		output.writeByte(kind);
		if (payload != null) {
			var count = length < 0 ? payload.length - offset : length;
			if (count > 0) output.writeBytes(payload, offset, count);
		}
		return output.getBytes();
	}

	/** A message carrying two numbers below 65536 (a terminal size). */
	public static function pair(kind:Int, first:Int, second:Int):Bytes {
		var output = new BytesOutput();
		output.writeByte(kind);
		output.writeByte(first & 255);
		output.writeByte((first >> 8) & 255);
		output.writeByte(second & 255);
		output.writeByte((second >> 8) & 255);
		return output.getBytes();
	}

	public static function pairFirst(message:Bytes):Int
		return message.length < 5 ? 0 : message.get(1) | (message.get(2) << 8);

	public static function pairSecond(message:Bytes):Int
		return message.length < 5 ? 0 : message.get(3) | (message.get(4) << 8);

	/** A message carrying two 32-bit numbers (default colours). */
	public static function numbers(kind:Int, first:Int, second:Int):Bytes {
		var output = new BytesOutput();
		output.writeByte(kind);
		writeU32(output, first);
		writeU32(output, second);
		return output.getBytes();
	}

	public static function secondNumberOf(message:Bytes):Int
		return message.length < 9 ? 0 : readU32(message, 5);

	/** A message carrying one 32-bit number (an exit code). */
	public static function number(kind:Int, value:Int):Bytes {
		var output = new BytesOutput();
		output.writeByte(kind);
		writeU32(output, value);
		return output.getBytes();
	}

	public static function numberOf(message:Bytes):Int
		return message.length < 5 ? 0 : readU32(message, 1);

	/** Queues `data` as messages of `kind`, each within CHUNK. */
	public static function chunks(kind:Int, data:Bytes, into:Array<Bytes>):Void {
		var offset = 0;
		while (offset < data.length) {
			var count = data.length - offset > CHUNK ? CHUNK : data.length - offset;
			into.push(message(kind, data, offset, count));
			offset += count;
		}
	}

	public static function encodeSpec(spec:TerminalHostSpec):Bytes {
		var output = new BytesOutput();
		writeU32(output, VERSION);
		writeText(output, spec.token);
		writeText(output, spec.pipe);
		writeU32(output, spec.columns);
		writeU32(output, spec.rows);
		writeText(output, spec.program);
		writeText(output, spec.cwd);
		writeU32(output, spec.arguments.length);
		for (value in spec.arguments) writeText(output, value);
		writeU32(output, spec.environment.length);
		for (value in spec.environment) writeText(output, value);
		var prelude = spec.prelude == null ? Bytes.alloc(0) : spec.prelude;
		writeU32(output, prelude.length);
		output.write(prelude);
		return output.getBytes();
	}

	public static function decodeSpec(bytes:Bytes):TerminalHostSpec {
		var position = [0];
		if (number32(bytes, position) != VERSION) throw "Unsupported terminal host spec";
		var token = text(bytes, position), pipe = text(bytes, position);
		var columns = number32(bytes, position), rows = number32(bytes, position);
		var program = text(bytes, position), cwd = text(bytes, position);
		var arguments:Array<String> = [];
		var count = number32(bytes, position);
		if (count < 0 || count > 4096) throw "Invalid terminal host spec";
		for (_ in 0...count) arguments.push(text(bytes, position));
		var environment:Array<String> = [];
		count = number32(bytes, position);
		if (count < 0 || count > 65536) throw "Invalid terminal host spec";
		for (_ in 0...count) environment.push(text(bytes, position));
		var length = number32(bytes, position), offset = position[0];
		if (length < 0 || offset + length > bytes.length) throw "Truncated terminal host spec";
		return {token: token, pipe: pipe, columns: columns, rows: rows, program: program, cwd: cwd, arguments: arguments,
			environment: environment, prelude: bytes.sub(offset, length)};
	}

	static function writeU32(output:BytesOutput, value:Int):Void {
		output.writeByte(value & 255);
		output.writeByte((value >>> 8) & 255);
		output.writeByte((value >>> 16) & 255);
		output.writeByte((value >>> 24) & 255);
	}

	static function readU32(bytes:Bytes, offset:Int):Int
		return bytes.get(offset) | (bytes.get(offset + 1) << 8) | (bytes.get(offset + 2) << 16) | (bytes.get(offset + 3) << 24);

	static function writeText(output:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value == null ? "" : value);
		writeU32(output, bytes.length);
		output.write(bytes);
	}

	static function number32(bytes:Bytes, position:Array<Int>):Int {
		var offset = position[0];
		if (offset + 4 > bytes.length) throw "Truncated terminal host spec";
		position[0] = offset + 4;
		return readU32(bytes, offset);
	}

	static function text(bytes:Bytes, position:Array<Int>):String {
		var length = number32(bytes, position), offset = position[0];
		if (length < 0 || offset + length > bytes.length) throw "Truncated terminal host spec";
		position[0] = offset + length;
		return length == 0 ? "" : bytes.sub(offset, length).toString();
	}
}
