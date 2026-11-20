package workspace.provider;

import process.OwnedProcess;

/** Claude CLI's bidirectional JSONL control protocol (`claude -p --input-format stream-json`). No intermediary process. */
class ClaudeTransport extends AgentLineTransport {
	public static inline final MAX_FRAME_BYTES:Int = 6 * 1024 * 1024;

	public function new(process:OwnedProcess)
		super(process, "Claude", MAX_FRAME_BYTES, 8 * 1024 * 1024, 60000);

	override function envelope(id:Int, method:String, params:Dynamic):Dynamic {
		Reflect.setField(params, "subtype", method);
		return {type: "control_request", request_id: Std.string(id), request: params};
	}

	override function exitReason():String return "Claude CLI exited with status " + process.exitStatus();

	public function respond(id:String, response:Dynamic):Bool
		return send({type: "control_response", response: {subtype: "success", request_id: id, response: response}});

	public function reject(id:String, reason:String):Bool
		return send({type: "control_response", response: {subtype: "error", request_id: id, error: reason}});

	override function dispatch(v:Dynamic):Void {
		if (!Std.isOfType(Reflect.field(v, "type"), String)) throw "Invalid Claude envelope";
		var type:String = Reflect.field(v, "type");
		switch (type) {
			case "control_response":
				var response = Reflect.field(v, "response");
				var id = AgentLineTransport.textId(Reflect.field(response, "request_id"));
				if (id == null) throw "Invalid Claude response id";
				settle(id, Reflect.field(response, "response"),
					Reflect.field(response, "subtype") == "success" ? null : Std.string(Reflect.field(response, "error")));
			case "control_request":
				var id:Dynamic = Reflect.field(v, "request_id"), request = Reflect.field(v, "request");
				if (!Std.isOfType(id, String) || id.length == 0 || id.length > 256 || request == null) throw "Invalid Claude control request";
				serverRequest(id, Reflect.field(request, "subtype"), request);
			default: notification(type, v);
		}
	}
}
