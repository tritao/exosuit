package app;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;

/** Creates the private, one-shot bootstrap passed from the manager to the daemon. */
class AgentRelayBootstrap {
	public static function create(directory:String, origin:Null<String>):Null<String> {
		if (origin == null || origin.length == 0) return null;
		var identityPath = Path.join([directory, "relay-machine.json"]);
		var machineId:String;
		if (FileSystem.exists(identityPath)) {
			if (!AgentManagerNative.privateFile(identityPath)) throw "Relay identity file is not private";
			var metadata = FileSystem.metadata(identityPath);
			if (metadata == null || metadata.size > 16384) throw "Invalid workspace relay identity";
			var identity:Dynamic;
			try identity = Json.parse(File.getContent(identityPath)) catch (_:Dynamic) throw "Invalid workspace relay identity";
			if (identity == null || !Reflect.isObject(identity) || Std.isOfType(identity, Array))
				throw "Invalid workspace relay identity";
			machineId = fieldString(identity, "machineId");
			if (fieldInt(identity, "version") != 1 || !isHex(machineId, 32)) throw "Invalid workspace relay identity";
		} else {
			machineId = AgentManagerNative.randomToken().substr(0, 32);
			AtomicFile.create(identityPath, Json.stringify({version: 1, machineId: machineId}) + "\n");
		}
		var path = Path.join([directory, "relay-bootstrap.json"]);
		if (FileSystem.exists(path)) {
			if (!AgentManagerNative.privateFile(path)) throw "Relay bootstrap file is not private";
			FileSystem.deleteFile(path);
		}
		AtomicFile.create(path, Json.stringify({version: 1, origin: origin, machineId: machineId,
			bootstrapToken: AgentManagerNative.randomToken()}) + "\n");
		return path;
	}

	static function fieldInt(value:Dynamic, field:String):Int {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Int) ? cast result : -1;
	}

	static function fieldString(value:Dynamic, field:String):String {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) ? cast result : "";
	}

	static function isHex(value:String, length:Int):Bool {
		if (value == null || value.length != length) return false;
		for (index in 0...value.length) {
			var c = value.charCodeAt(index);
			if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
		}
		return true;
	}
}
