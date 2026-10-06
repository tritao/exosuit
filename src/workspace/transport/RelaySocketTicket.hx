package workspace.transport;

import haxe.Json;
import haxe.io.Bytes;

/** Short-lived single-use capability returned by the relay ticket endpoint. */
class RelaySocketTicket {
	public final value:String;
	public final expiresInSeconds:Int;

	public function new(value:String, expiresInSeconds:Int) {
		if (!isToken(value) || expiresInSeconds < 1 || expiresInSeconds > 60)
			throw "Invalid relay socket ticket";
		this.value = value;
		this.expiresInSeconds = expiresInSeconds;
	}

	public static function parse(body:Bytes):RelaySocketTicket {
		if (body == null || body.length == 0 || body.length > 4096)
			throw "Invalid relay ticket response";
		var value:Dynamic = Json.parse(body.toString());
		if (value == null || !Reflect.isObject(value))
			throw "Invalid relay ticket response";
		var ticket:Dynamic = Reflect.field(value, "ticket");
		var lifetime:Dynamic = Reflect.field(value, "expiresInSeconds");
		if (!Std.isOfType(ticket, String) || !Std.isOfType(lifetime, Int))
			throw "Invalid relay ticket response";
		return new RelaySocketTicket(cast ticket, cast lifetime);
	}

	public static function isToken(value:String):Bool {
		if (value == null || value.length != 64)
			return false;
		for (index in 0...value.length) {
			var character = value.charCodeAt(index);
			if (!(character >= 48 && character <= 57 || character >= 97 && character <= 102))
				return false;
		}
		return true;
	}
}
