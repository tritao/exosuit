package workspace.provider;

import process.OwnedProcess;

/** JSON-RPC over lines: the Codex bridge (`run-codex-proxy.py`) and the Claude session-name helper. */
class AgentJsonTransport extends AgentLineTransport {
	public function new(process:OwnedProcess, label:String, maxFrame:Int = 262144, maxQueue:Int = 1048576)
		super(process, label, maxFrame, maxQueue, 15000);

	override function envelope(id:Int, method:String, params:Dynamic):Dynamic return {id: id, method: method, params: params};

	override function exitReason():String return label + " proxy disconnected";

	override function dispatch(v:Dynamic):Void {
		var method:Dynamic = Reflect.field(v, "method"),
			id:Dynamic = Reflect.field(v, "id");
		if (method != null) {
			if (!Std.isOfType(method, String))
				throw "Invalid " + label + " method";
			if (id == null)
				notification(method, Reflect.field(v, "params"));
			else
				serverRequest(id, method, Reflect.field(v, "params"));
		} else {
			if (!Std.isOfType(id, Int))
				throw "Invalid " + label + " response id";
			var error = Reflect.field(v, "error");
			settle(id, Reflect.field(v, "result"), error == null ? null : Std.string(Reflect.field(error, "message")));
		}
	}
}
