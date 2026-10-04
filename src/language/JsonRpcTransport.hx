package language;

import haxe.Json;
import haxe.io.Bytes;
import process.OwnedProcess;

/** Bounded Language Server Protocol transport over an owned stdio process. */
class JsonRpcTransport {
	public static inline final MAX_FRAME_BYTES = 1024 * 1024;
	public static inline final MAX_QUEUED_BYTES = 1024 * 1024;
	public static inline final MAX_STDERR_BYTES = 64 * 1024;
	static inline final WRITE_CHARS = 512;
	static inline final IO_STEPS = 16;

	public final process:OwnedProcess;
	public final frameLimit:Int;
	public final queueLimit:Int;
	public var notification:(String, Dynamic)->Void = function(method, params) {};
	public var serverRequest:(String, Dynamic)->JsonRpcResponse = function(method, params) {
		return new JsonRpcResponse(null, "Method not found");
	};
	public var failed:String->Void = function(message) {};
	public var trace:Null<(String, String)->Void>;
	public var failure(default, null):Null<String>;
	public var stderr(default, null):String = "";

	final outbound:Array<String> = [];
	final pending:Map<Int, JsonRpcPending> = [];
	var inbound:String = "";
	var outboundOffset:Int = 0;
	var outboundBytes:Int = 0;
	var nextId:Int = 1;
	var drainedAfterExit:Int = 0;

	public function new(process:OwnedProcess, frameLimit:Int = MAX_FRAME_BYTES, queueLimit:Int = MAX_QUEUED_BYTES) {
		if (frameLimit < 1 || frameLimit > MAX_FRAME_BYTES) throw "invalid JSON-RPC frame limit";
		if (queueLimit < frameLimit || queueLimit > MAX_QUEUED_BYTES) throw "invalid JSON-RPC queue limit";
		this.process = process;
		this.frameLimit = frameLimit;
		this.queueLimit = queueLimit;
	}

	public function request(method:String, params:Dynamic, now:Float, timeout:Float, complete:JsonRpcResponse->Void):Int {
		if (timeout <= 0) throw "JSON-RPC timeout must be positive";
		var id = nextId++;
		pending.set(id, new JsonRpcPending(id, now + timeout, complete));
		if (!enqueue({jsonrpc: "2.0", id: id, method: method, params: params})) {
			pending.remove(id);
			complete(new JsonRpcResponse(null, failure == null ? "JSON-RPC output queue is full" : failure));
		}
		return id;
	}

	public function notify(method:String, params:Dynamic):Bool
		return enqueue({jsonrpc: "2.0", method: method, params: params});

	public function cancel(id:Int):Bool {
		var request = pending.get(id);
		if (request == null) return false;
		pending.remove(id);
		enqueue({jsonrpc: "2.0", method: "$/cancelRequest", params: {id: id}});
		request.complete(new JsonRpcResponse(null, "request cancelled"));
		return true;
	}

	public function update(now:Float):Void {
		if (failure != null) return;
		flush();
		var received = false;
		for (_ in 0...IO_STEPS) {
			var chunk = process.readStdout();
			if (chunk.length == 0) break;
			received = true;
			inbound += chunk;
			if (Bytes.ofString(inbound).length > frameLimit + 8192) {
				terminate("language server input exceeded the transport bound");
				return;
			}
			parseFrames();
			if (failure != null) return;
		}
		for (_ in 0...IO_STEPS) {
			var chunk = process.readStderr();
			if (chunk.length == 0) break;
			stderr += chunk;
			trimStderr();
		}
		expire(now);
		if (process.exited()) {
			if (received) drainedAfterExit = 0; else drainedAfterExit++;
			if (drainedAfterExit >= 2) terminate('language server exited with status ${process.exitStatus()}');
		}
	}

	public function close():Void {
		if (failure == null) terminate("language service transport closed");
	}

	public function pendingCount():Int return countPending();
	public function queuedBytes():Int return outboundBytes;

	function enqueue(message:Dynamic):Bool {
		if (failure != null) return false;
		var payload = Json.stringify(message), length = Bytes.ofString(payload).length;
		if (length > frameLimit) return false;
		var frame = 'Content-Length: $length\r\n\r\n$payload', size = Bytes.ofString(frame).length;
		if (size > queueLimit - outboundBytes) return false;
		if (trace != null) trace("send", payload);
		outbound.push(frame);
		outboundBytes += size;
		return true;
	}

	function flush():Void {
		for (_ in 0...IO_STEPS) {
			if (outbound.length == 0) return;
			var frame = outbound[0], end = outboundOffset + WRITE_CHARS;
			if (end > frame.length) end = frame.length;
			if (end < frame.length && isHighSurrogate(frame.charCodeAt(end - 1))) end--;
			var chunk = frame.substring(outboundOffset, end), expected = Bytes.ofString(chunk).length;
			var written:Int;
			try {
				written = process.writeStdin(chunk);
			} catch (error:Dynamic) {
				terminate("could not write to language server: " + Std.string(error));
				return;
			}
			if (written == 0) return;
			if (written != expected) {
				terminate("language server accepted a partial atomic write");
				return;
			}
			outboundOffset = end;
			if (outboundOffset == frame.length) {
				outbound.shift();
				outboundBytes -= Bytes.ofString(frame).length;
				outboundOffset = 0;
			}
		}
	}

	function parseFrames():Void {
		while (true) {
			var headerEnd = inbound.indexOf("\r\n\r\n");
			if (headerEnd < 0) {
				if (Bytes.ofString(inbound).length > 8192) terminate("language server header exceeded 8 KiB");
				return;
			}
			var length = contentLength(inbound.substring(0, headerEnd));
			if (length < 0 || length > frameLimit) {
				terminate("language server sent an invalid Content-Length");
				return;
			}
			var bodyStart = headerEnd + 4, bodyEnd = characterEnd(inbound, bodyStart, length);
			if (bodyEnd < 0) return;
			var payload = inbound.substring(bodyStart, bodyEnd);
			inbound = inbound.substring(bodyEnd);
			dispatch(payload);
			if (failure != null) return;
		}
	}

	function dispatch(payload:String):Void {
		if (trace != null) trace("receive", payload);
		var message:Dynamic;
		try {
			message = Json.parse(payload);
		} catch (error:Dynamic) {
			terminate("language server sent invalid JSON");
			return;
		}
		var methodValue:Dynamic = Reflect.field(message, "method"), rawId:Dynamic = Reflect.field(message, "id");
		var method:Null<String> = methodValue == null ? null : cast(methodValue, String);
		if (method != null) {
			if (rawId == null) notification(method, Reflect.field(message, "params"));
			else {
				var response = serverRequest(method, Reflect.field(message, "params"));
				if (response.error == null) enqueue({jsonrpc: "2.0", id: rawId, result: response.result});
				else enqueue({jsonrpc: "2.0", id: rawId, error: {code: -32602, message: response.error}});
			}
			return;
		}
		if (rawId == null) return;
		var id = Std.parseInt(Std.string(rawId)), request = pending.get(id);
		if (request == null) return;
		pending.remove(id);
		var rpcError:Dynamic = Reflect.field(message, "error");
		request.complete(new JsonRpcResponse(Reflect.field(message, "result"), rpcError == null ? null : rpcErrorMessage(rpcError)));
	}

	function expire(now:Float):Void {
		var expired:Array<Int> = [];
		for (id => request in pending)
			if (now >= request.deadline) expired.push(id);
		for (id in expired) {
			var request = pending.get(id);
			pending.remove(id);
			enqueue({jsonrpc: "2.0", method: "$/cancelRequest", params: {id: id}});
			request.complete(new JsonRpcResponse(null, "request timed out"));
		}
	}

	function terminate(message:String):Void {
		if (failure != null) return;
		failure = message;
		outbound.resize(0);
		outboundBytes = 0;
		var requests:Array<JsonRpcPending> = [];
		for (request in pending) requests.push(request);
		pending.clear();
		for (request in requests) request.complete(new JsonRpcResponse(null, message));
		failed(message);
	}

	function trimStderr():Void {
		var bytes = Bytes.ofString(stderr).length;
		if (bytes <= MAX_STDERR_BYTES) return;
		var remove = characterEnd(stderr, 0, bytes - MAX_STDERR_BYTES);
		if (remove > 0) stderr = stderr.substring(remove);
	}

	function countPending():Int {
		var count = 0;
		for (_ in pending) count++;
		return count;
	}

	static function contentLength(headers:String):Int {
		var result = -1;
		for (header in headers.split("\r\n")) {
			var separator = header.indexOf(":");
			if (separator < 0) continue;
			if (header.substring(0, separator).toLowerCase() == "content-length")
				result = Std.parseInt(StringTools.trim(header.substring(separator + 1)));
		}
		return result;
	}

	/** Returns a UTF-16 index ending at exactly byteCount UTF-8 bytes, or -1 if incomplete. */
	static function characterEnd(value:String, start:Int, byteCount:Int):Int {
		var index = start, bytes = 0;
		while (index < value.length && bytes < byteCount) {
			var code = value.charCodeAt(index), width = 1, units = 1;
			if (code <= 0x7f) width = 1;
			else if (code <= 0x7ff) width = 2;
			else if (isHighSurrogate(code) && index + 1 < value.length && isLowSurrogate(value.charCodeAt(index + 1))) {
				width = 4;
				units = 2;
			} else width = 3;
			if (bytes + width > byteCount) return -2;
			bytes += width;
			index += units;
		}
		return bytes == byteCount ? index : -1;
	}

	static function rpcErrorMessage(error:Dynamic):String {
		var message:Dynamic = Reflect.field(error, "message");
		return message == null ? "JSON-RPC request failed" : Std.string(message);
	}

	static function isHighSurrogate(code:Int):Bool return code >= 0xd800 && code <= 0xdbff;
	static function isLowSurrogate(code:Int):Bool return code >= 0xdc00 && code <= 0xdfff;
}
