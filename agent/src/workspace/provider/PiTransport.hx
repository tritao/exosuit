package workspace.provider;

import process.OwnedProcess;

/** Pi's RPC mode (`pi --mode rpc`): requests and responses carry `type` and a text `id`; everything else is an event. */
class PiTransport extends AgentLineTransport {
	public static inline final MAX_FRAME_BYTES:Int = 6 * 1024 * 1024;

	public function new(process:OwnedProcess)
		super(process, "Pi", MAX_FRAME_BYTES, 8 * 1024 * 1024, 60000);

	/** A prompt is answered when its turn ends, however long that takes. */
	override function deadline(method:String):Float return method == "prompt" ? Math.POSITIVE_INFINITY : timeout;

	override function envelope(id:Int, method:String, params:Dynamic):Dynamic {
		Reflect.setField(params, "type", method);
		Reflect.setField(params, "id", Std.string(id));
		return params;
	}

	override function exitReason():String return "Pi proxy disconnected";

	override function dispatch(v:Dynamic):Void {
		if (!Std.isOfType(Reflect.field(v, "type"), String)) throw "Invalid Pi envelope";
		var type:String = Reflect.field(v, "type");
		if (type != "response") {
			notification(type, v);
			return;
		}
		var id = textId(Reflect.field(v, "id"));
		if (id == null) throw "Invalid Pi response id";
		settle(id, Reflect.field(v, "data"), Reflect.field(v, "success") == true ? null : Std.string(Reflect.field(v, "error")));
	}
}
