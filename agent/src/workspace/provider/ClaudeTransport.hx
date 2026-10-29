package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import process.OwnedProcess;
import language.JsonRpcResponse;
import language.JsonRpcPending;

/** Native Claude CLI bidirectional JSONL control protocol. No intermediary process. */
class ClaudeTransport {
	public static inline final MAX_FRAME_BYTES:Int = 6 * 1024 * 1024;
	static inline final MAX_QUEUE_BYTES:Int = 8 * 1024 * 1024;
	public var notification:(String, Dynamic) -> Void = function(_, _) {};
	public var serverRequest:(Dynamic, String, Dynamic) -> Void = function(_, _, _) {};
	public var failure(default, null):Null<String>;

	final process:OwnedProcess;
	final pending:Map<Int, JsonRpcPending> = [];
	final queue:Array<Bytes> = [];
	final sizes:Array<Int> = [];
	var offset = 0;
	var queued = 0;
	var input = new BytesBuffer();
	var inputLength=0;
	var pendingInput:Null<Bytes>;
	var pendingOffset=0;
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
			done(new JsonRpcResponse(null, "Claude requests are busy"));
			return;
		}
		var id = next++;
		pending.set(id, new JsonRpcPending(id, now + 60000, done));
		Reflect.setField(params, "subtype", method);
		if (!send({type: "control_request", request_id: Std.string(id), request: params})) {
			pending.remove(id);
			done(new JsonRpcResponse(null, "Claude output queue is full"));
		}
	}

	public function send(value:Dynamic):Bool {
		if (failure != null)
			return false;
		var bytes=Bytes.ofString(Json.stringify(value)+"\n");
		if (bytes.length > MAX_FRAME_BYTES || queued + bytes.length > MAX_QUEUE_BYTES || queue.length>=32)
			return false;
		queue.push(bytes);
		sizes.push(bytes.length);
		queued += bytes.length;
		return true;
	}

	public function poll(now:Float):Void {
		if (failure != null)
			return;
		try {
			for (_ in 0...16) {
				if (queue.length == 0)
					break;
				var line = queue[0];
				var length = Std.int(Math.min(4096, line.length - offset));
				var written = process.writeBytes(line, offset, length);
				if (written < 0 || written > length) throw "Invalid Claude write count";
				if (written == 0) break;
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
				var chunk=pendingInput;
				if(chunk==null) {chunk=process.readStdoutBytes();pendingOffset=0;if(chunk.length>0) pendingInput=chunk;}
				var bytes:Bytes=cast chunk;if(bytes.length==0) break;
				received=true;
				while(pendingOffset<bytes.length && messages<32) {
					var value=bytes.get(pendingOffset++);
					if(value==10) {
						if(inputLength>0) {
							var line=input.getBytes();input=new BytesBuffer();inputLength=0;
							if(!workspace.TextFileContent.validUtf8(line)) throw "Invalid Claude UTF-8 frame";
							messages++;dispatch(Json.parse(line.toString()));
						}
					} else {
						if(++inputLength>MAX_FRAME_BYTES) throw "Claude frame exceeded bound";
						input.addByte(value);
					}
				}
				if(pendingOffset==bytes.length) {pendingInput=null;pendingOffset=0;}
			}
			// Drain bounded stderr without forwarding credentials/config to UI.
			for (_ in 0...8)
				if (process.readStderr().length == 0)
					break;
			for (id in [for (id in pending.keys()) id]) {
				var p = pending.get(id);
				if (p != null && now >= p.deadline) {
					pending.remove(id);
					p.complete(new JsonRpcResponse(null, "Claude response timed out; reconcile before retrying"));
				}
			}
			if (process.exited()) {
				exited = received ? 0 : exited + 1;
				if (exited >= 2)
					close("Claude CLI exited with status " + process.exitStatus());
			}
		} catch (error:Dynamic)
			close("Claude protocol connection failed: " + Std.string(error));
	}

	public function respond(id:String, response:Dynamic):Bool
		return send({type: "control_response", response: {subtype: "success", request_id: id, response: response}});

	public function reject(id:String, reason:String):Bool
		return send({type: "control_response", response: {subtype: "error", request_id: id, error: reason}});

	function dispatch(v:Dynamic):Void {
		if (v == null || !Std.isOfType(Reflect.field(v, "type"), String)) throw "Invalid Claude envelope";
		var type:String = Reflect.field(v, "type");
		switch (type) {
			case "control_response":
				var response = Reflect.field(v, "response");
				var wireId:Dynamic = Reflect.field(response, "request_id");
				if (!Std.isOfType(wireId, String)) throw "Invalid Claude response id";
				var id = Std.parseInt(wireId);
				if (id == null || Std.string(id) != wireId) throw "Invalid Claude response id";
				var p = pending.get(id);
				if (p == null) return;
				pending.remove(id);
				p.complete(new JsonRpcResponse(Reflect.field(response, "response"),
					Reflect.field(response, "subtype") == "success" ? null : Std.string(Reflect.field(response, "error")).substring(0, 2048)));
			case "control_request":
				var id:Dynamic = Reflect.field(v, "request_id"), request = Reflect.field(v, "request");
				if (!Std.isOfType(id, String) || id.length == 0 || id.length > 256 || request == null) throw "Invalid Claude control request";
				serverRequest(id, Reflect.field(request, "subtype"), request);
			default: notification(type, v);
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
		input=new BytesBuffer();inputLength=0;pendingInput=null;pendingOffset=0;
		sizes.resize(0);
		offset = 0;
		queued = 0;
		var callbacks = [for (p in pending) p];
		pending.clear();
		for (p in callbacks)
			p.complete(new JsonRpcResponse(null, reason));
	}
}
