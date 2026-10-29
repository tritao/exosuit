package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import process.OwnedProcess;
import language.JsonRpcResponse;
import language.JsonRpcPending;

/** Bounded JSONL RPC transport for daemon-owned vendor adapters and metadata helpers. */
class AgentJsonTransport {
	final label:String;
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
	var inputLength = 0;
	var pendingInput:Null<Bytes>;
	var pendingOffset = 0;
	final maxFrame:Int;
	final maxQueue:Int;
	var next = 1;
	var exited = 0;

	public function new(process:OwnedProcess, label:String, maxFrame:Int=262144, maxQueue:Int=1048576) {
		this.process = process;this.label = label;this.maxFrame=maxFrame;this.maxQueue=maxQueue;
	}

	public function request(method:String, params:Dynamic, now:Float, done:JsonRpcResponse->Void):Void {
		if (failure != null) {
			done(new JsonRpcResponse(null, failure));
			return;
		}
		if (count() >= 32) {
			done(new JsonRpcResponse(null, (label + " requests are busy")));
			return;
		}
		var id = next++;
		pending.set(id, new JsonRpcPending(id, now + 15000, done));
		if (!send({id: id, method: method, params: params})) {
			pending.remove(id);
			done(new JsonRpcResponse(null, (label + " output queue is full")));
		}
	}

	public function send(value:Dynamic):Bool {
		if (failure != null)
			return false;
		var line = Bytes.ofString(Json.stringify(value) + "\n"), bytes=line.length;
		if (bytes > maxFrame || queued + bytes > maxQueue || queue.length >= 32)
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
				var line = queue[0], length = Std.int(Math.min(4096,line.length-offset));
				var written = process.writeBytes(line,offset,length);
				if (written < 0 || written > length) throw "Invalid process write count";
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
				var chunk=pendingInput;
				if (chunk==null) {chunk=process.readStdoutBytes();pendingOffset=0;if(chunk.length>0) pendingInput=chunk;}
				var bytes:Bytes=cast chunk;
				if (bytes.length==0) break;
				received=true;
				while (pendingOffset<bytes.length && messages<32) {
					var value=bytes.get(pendingOffset++);
					if (value==10) {
						if (inputLength>0) {
							var line=input.getBytes();input=new BytesBuffer();inputLength=0;
							if (!workspace.TextFileContent.validUtf8(line)) throw (label + " invalid UTF-8 frame");
							messages++;dispatch(Json.parse(line.toString()));
						}
					} else {
						if (++inputLength>maxFrame) throw (label + " frame exceeded bound");
						input.addByte(value);
					}
				}
				if (pendingOffset==bytes.length) {pendingInput=null;pendingOffset=0;}
			}
			// Drain bounded stderr without forwarding credentials/config to UI.
			for (_ in 0...8)
				if (process.readStderr().length == 0)
					break;
			for (id in [for (id in pending.keys()) id]) {
				var p = pending.get(id);
				if (p != null && now >= p.deadline) {
					pending.remove(id);
					p.complete(new JsonRpcResponse(null, (label + " response timed out; reconcile before retrying")));
				}
			}
			if (process.exited()) {
				exited = received ? 0 : exited + 1;
				if (exited >= 2)
					close((label + " proxy disconnected"));
			}
		} catch (error:Dynamic)
			close((label + " protocol connection failed: ") + Std.string(error));
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
