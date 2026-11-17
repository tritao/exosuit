package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import process.OwnedProcess;
import language.JsonRpcResponse;
import language.JsonRpcPending;

/**
 * One JSON value per line over a provider process's stdin and stdout, the transport every provider shares: bounded
 * frames and queue, 4 KiB writes, LF framing, UTF-8 checks, request deadlines, exit detection and close. A provider's
 * envelope (how a request is written, how a line is read) is its subclass: `ClaudeTransport` (Claude's control
 * protocol), `PiTransport` (Pi's RPC mode), `AgentJsonTransport` (JSON-RPC: the Codex bridge, the Claude name helper).
 */
class AgentLineTransport {
	public var notification:(String, Dynamic) -> Void = function(_, _) {};
	public var serverRequest:(Dynamic, String, Dynamic) -> Void = function(_, _, _) {};
	public var failure(default, null):Null<String>;

	final label:String;
	final process:OwnedProcess;
	final maxFrame:Int;
	final maxQueue:Int;
	final timeout:Float;
	final pending:Map<Int, JsonRpcPending> = [];
	final rejections:Map<Int, String->Void> = [];
	final queue:Array<Bytes> = [];
	final sizes:Array<Int> = [];
	var offset = 0;
	var queued = 0;
	var input = new BytesBuffer();
	var inputLength = 0;
	var pendingInput:Null<Bytes>;
	var pendingOffset = 0;
	var next = 1;
	var exited = 0;

	/** `label` names the provider in errors; `timeout` is a request's deadline in milliseconds. */
	public function new(process:OwnedProcess, label:String, maxFrame:Int, maxQueue:Int, timeout:Float) {
		this.process = process;
		this.label = label;
		this.maxFrame = maxFrame;
		this.maxQueue = maxQueue;
		this.timeout = timeout;
	}

	/** Sends a request; `done` gets its answer. With `onReject`, a refusal goes there instead of to `done`. */
	public function request(method:String, params:Dynamic, now:Float, done:JsonRpcResponse->Void, ?onReject:String->Void):Void {
		if (failure != null) {
			done(new JsonRpcResponse(null, failure));
			return;
		}
		if (count() >= 32) {
			done(new JsonRpcResponse(null, label + " requests are busy"));
			return;
		}
		var id = next++;
		pending.set(id, new JsonRpcPending(id, now + deadline(method), done));
		if (onReject != null) rejections.set(id, onReject);
		if (!send(envelope(id, method, params))) {
			pending.remove(id);
			rejections.remove(id);
			done(new JsonRpcResponse(null, label + " output queue is full"));
		}
	}

	/** Milliseconds a request may wait for its answer. */
	function deadline(method:String):Float return timeout;

	/** The line a request is written as. */
	function envelope(id:Int, method:String, params:Dynamic):Dynamic throw "No request envelope";

	/** Reads one line from the process: answers go to `settle`, the rest to `notification` or `serverRequest`. */
	function dispatch(value:Dynamic):Void throw "No line reader";

	/** What the transport fails with when the process has exited. */
	function exitReason():String return label + " exited with status " + process.exitStatus();

	/** Completes request `id` with its result, or with `error` when it was refused. */
	function settle(id:Int, result:Dynamic, error:Null<String>):Void {
		var p = pending.get(id);
		if (p == null) return;
		pending.remove(id);
		var rejected = rejections.get(id);
		rejections.remove(id);
		if (error != null) error = error.substring(0, 2048);
		if (error != null && rejected != null) rejected(error);
		else p.complete(new JsonRpcResponse(result, error));
	}

	/** A request id written as decimal text, as Claude and Pi echo it; null for anything else. */
	static function textId(wire:Dynamic):Null<Int> {
		if (!Std.isOfType(wire, String)) return null;
		var id = Std.parseInt(wire);
		return id != null && Std.string(id) == wire ? id : null;
	}

	public function send(value:Dynamic):Bool {
		if (failure != null)
			return false;
		var line = Bytes.ofString(Json.stringify(value) + "\n");
		if (line.length > maxFrame || queued + line.length > maxQueue || queue.length >= 32)
			return false;
		queue.push(line);
		sizes.push(line.length);
		queued += line.length;
		return true;
	}

	public function poll(now:Float):Void {
		if (failure != null)
			return;
		try {
			for (_ in 0...16) {
				if (queue.length == 0)
					break;
				var line = queue[0], length = Std.int(Math.min(4096, line.length - offset));
				var written = process.writeBytes(line, offset, length);
				if (written < 0 || written > length) throw "Invalid " + label + " write count";
				if (written == 0)
					break;
				offset += written;
				if (offset == line.length) {
					queue.shift();
					queued -= sizes.shift();
					offset = 0;
				}
			}
			var received = false, messages = 0;
			for (_ in 0...8) {
				if (messages >= 32)
					break;
				var chunk = pendingInput;
				if (chunk == null) {
					chunk = process.readStdoutBytes();
					pendingOffset = 0;
					if (chunk.length > 0) pendingInput = chunk;
				}
				var bytes:Bytes = cast chunk;
				if (bytes.length == 0) break;
				received = true;
				while (pendingOffset < bytes.length && messages < 32) {
					var value = bytes.get(pendingOffset++);
					if (value == 10) {
						if (inputLength > 0) {
							var line = input.getBytes();
							input = new BytesBuffer();
							inputLength = 0;
							if (!workspace.TextFileContent.validUtf8(line)) throw "Invalid " + label + " UTF-8 frame";
							messages++;
							var parsed:Dynamic = Json.parse(line.toString());
							if (parsed == null) throw "Invalid " + label + " envelope";
							dispatch(parsed);
						}
					} else {
						if (++inputLength > maxFrame) throw label + " frame exceeded bound";
						input.addByte(value);
					}
				}
				if (pendingOffset == bytes.length) {
					pendingInput = null;
					pendingOffset = 0;
				}
			}
			// Drain bounded stderr without forwarding credentials/config to UI.
			for (_ in 0...8)
				if (process.readStderr().length == 0)
					break;
			for (id in [for (id in pending.keys()) id]) {
				var p = pending.get(id);
				if (p != null && now >= p.deadline) {
					pending.remove(id);
					rejections.remove(id);
					p.complete(new JsonRpcResponse(null, label + " response timed out; reconcile before retrying"));
				}
			}
			if (process.exited()) {
				exited = received ? 0 : exited + 1;
				if (exited >= 2)
					close(exitReason());
			}
		} catch (error:Dynamic)
			close(label + " protocol connection failed: " + Std.string(error));
	}

	function count():Int {
		var n = 0;
		for (_ in pending)
			n++;
		return n;
	}

	public function close(reason:String):Void {
		if (failure != null)
			return;
		failure = reason;
		queue.resize(0);
		input = new BytesBuffer();
		inputLength = 0;
		pendingInput = null;
		pendingOffset = 0;
		sizes.resize(0);
		offset = 0;
		queued = 0;
		rejections.clear();
		var callbacks = [for (p in pending) p];
		pending.clear();
		for (p in callbacks)
			p.complete(new JsonRpcResponse(null, reason));
	}
}
