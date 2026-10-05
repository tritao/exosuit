package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import process.OwnedProcess;
import language.JsonRpcResponse;
import language.JsonRpcPending;

/** Codex JSONL, not LSP framing. Owns only a proxy process, never the shared server. */
class CodexTransport {
	public var notification:(String, Dynamic) -> Void = function(_, _) {};
	public var serverRequest:(Dynamic, String, Dynamic) -> Void = function(_, _, _) {};
	public var failure(default, null):Null<String>;

	final process:OwnedProcess;
	final pending:Map<Int, JsonRpcPending> = [];
	final queue:Array<String> = [];
	final sizes:Array<Int> = [];
	var offset = 0;
	var queued = 0;
	var input = "";
	var next = 1;
	var exited = 0;

	public function new(process:OwnedProcess)
		this.process = process;

	public function request(method:String, params:Dynamic, now:Float, done:JsonRpcResponse->Void):Void {
		if (failure != null) {
			done(new JsonRpcResponse(null, failure));
			return;
		}
		if (count() >= 32) {
			done(new JsonRpcResponse(null, "Codex requests are busy"));
			return;
		}
		var id = next++;
		pending.set(id, new JsonRpcPending(id, now + 15000, done));
		if (!send({id: id, method: method, params: params})) {
			pending.remove(id);
			done(new JsonRpcResponse(null, "Codex output queue is full"));
		}
	}

	public function send(value:Dynamic):Bool {
		if (failure != null)
			return false;
		var line = Json.stringify(value) + "\n",
			bytes = Bytes.ofString(line).length;
		if (bytes > 262144 || queued + bytes > 1048576)
			return false;
		queue.push(line);
		sizes.push(bytes);
		queued += bytes;
		return true;
	}

	public function poll(now:Float):Void {
		if (failure != null)
			return;
		try {
			for (_ in 0...16) {
				if (queue.length == 0)
					break;
				var line = queue[0],
					end = Std.int(Math.min(line.length, offset + 512));
				var previous = line.charCodeAt(end - 1);
				if (end < line.length && previous != null && previous >= 0xd800 && previous <= 0xdbff)
					end--;
				var chunk = line.substring(offset, end),
					bytes = Bytes.ofString(chunk).length;
				var written = process.writeStdin(chunk);
				if (written == 0)
					break;
				if (written != bytes)
					throw "Partial Codex write";
				offset = end;
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
				if (input.indexOf("\n") < 0) {
					var chunk = process.readStdout();
					if (chunk.length == 0)
						break;
					received = true;
					input += chunk;
					if (Bytes.ofString(input).length > 1048576)
						throw "Codex input queue exceeded bound";
				}
				while (messages < 32) {
					var at = input.indexOf("\n");
					if (at < 0)
						break;
					var line = input.substring(0, at);
					input = input.substring(at + 1);
					if (Bytes.ofString(line).length > 262144)
						throw "Codex message exceeded bound";
					if (line.length == 0)
						continue;
					messages++;
					dispatch(Json.parse(line));
				}
				if (Bytes.ofString(input).length > 262144 && input.indexOf("\n") < 0)
					throw "Codex frame exceeded bound";
			}
			// Drain bounded stderr without forwarding credentials/config to UI.
			for (_ in 0...8)
				if (process.readStderr().length == 0)
					break;
			for (id in [for (id in pending.keys()) id]) {
				var p = pending.get(id);
				if (p != null && now >= p.deadline) {
					pending.remove(id);
					p.complete(new JsonRpcResponse(null, "Codex response timed out; reconcile before retrying"));
				}
			}
			if (process.exited()) {
				exited = received ? 0 : exited + 1;
				if (exited >= 2)
					close("Codex proxy disconnected");
			}
		} catch (error:Dynamic)
			close("Codex protocol connection failed: " + Std.string(error));
	}

	function dispatch(v:Dynamic):Void {
		if (v == null)
			throw "Invalid Codex envelope";
		var method:Dynamic = Reflect.field(v, "method"),
			id:Dynamic = Reflect.field(v, "id");
		if (method != null) {
			if (!Std.isOfType(method, String))
				throw "Invalid Codex method";
			if (id == null)
				notification(method, Reflect.field(v, "params"));
			else
				serverRequest(id, method, Reflect.field(v, "params"));
		} else {
			if (!Std.isOfType(id, Int))
				throw "Invalid Codex response id";
			var p = pending.get(id);
			if (p == null)
				return;
			pending.remove(id);
			var error = Reflect.field(v, "error");
			p.complete(new JsonRpcResponse(Reflect.field(v, "result"), error == null ? null : Std.string(Reflect.field(error, "message")).substring(0, 2048)));
		}
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
		sizes.resize(0);
		offset = 0;
		queued = 0;
		var callbacks = [for (p in pending) p];
		pending.clear();
		for (p in callbacks)
			p.complete(new JsonRpcResponse(null, reason));
	}
}
