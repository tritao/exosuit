import haxe.Json;
import haxe.io.Bytes;

/** One paired machine as the phone keeps it (ADR 0005 section 4: a device pairs once with the machine and is granted workspaces there). The key and token are secrets: the host stores them under the Android Keystore. */
typedef SavedDevice = {
	var machineId:String;
	var deviceId:String;
	var relayOrigin:String;
	var staticPrivateKey:String;
	var deviceToken:String;
	var machineStaticPublicKey:String;
	/** The machine's name, learned from its directory. Null until then. */
	var name:Null<String>;
}

/**
	The phone's paired machines. The document lives in the host's Keystore-encrypted file: it arrives with the `start`
	command (`load`) and goes back through HostBridge on every change (`save`). Nothing is written by the Haxe side.
**/
class PhoneCredentials {
	/** Version 1 held one pairing per workspace service; those are not machine pairings, so they are not read. */
	public static inline final VERSION = 2;
	public static inline final MAX_DEVICES = 16;

	public var devices(default, null):Array<SavedDevice> = [];

	public function new() {}

	public function load(document:Null<Bytes>):Void {
		devices = [];
		if (document == null || document.length == 0) return;
		try {
			var value:Dynamic = Json.parse(document.toString());
			if (value == null || value.version != VERSION || !Std.isOfType(value.devices, Array)) return;
			for (entry in (cast value.devices:Array<Dynamic>)) {
				if (devices.length >= MAX_DEVICES) break;
				var device = validate(entry);
				if (device != null) devices.push(device);
			}
		} catch (_:Dynamic) devices = [];
	}

	static function validate(entry:Dynamic):Null<SavedDevice> {
		var machineId:Dynamic = Reflect.field(entry, "machineId"), deviceId:Dynamic = Reflect.field(entry, "deviceId");
		var origin:Dynamic = Reflect.field(entry, "relayOrigin"), key:Dynamic = Reflect.field(entry, "staticPrivateKey");
		var token:Dynamic = Reflect.field(entry, "deviceToken"), machineKey:Dynamic = Reflect.field(entry, "machineStaticPublicKey");
		if (!hex(machineId, 32) || !hex(deviceId, 32) || !Std.isOfType(origin, String) || !hex(key, 64) || !hex(token, 64) || !hex(machineKey, 64))
			return null;
		var name:Dynamic = Reflect.field(entry, "name");
		return {machineId: machineId, deviceId: deviceId, relayOrigin: origin, staticPrivateKey: key, deviceToken: token,
			machineStaticPublicKey: machineKey, name: Std.isOfType(name, String) ? name : null};
	}

	static function hex(value:Dynamic, length:Int):Bool
		return Std.isOfType(value, String) && (value:String).length == length && ~/^[0-9a-f]+$/.match(value);

	public function find(machineId:String, deviceId:String):Null<SavedDevice> {
		for (device in devices) if (device.machineId == machineId && device.deviceId == deviceId) return device;
		return null;
	}

	/** Adds or replaces the entry for the same machine and device, then stores the document. */
	public function put(device:SavedDevice, done:Bool->Void):Void {
		devices = [for (existing in devices) if (existing.machineId != device.machineId || existing.deviceId != device.deviceId) existing];
		devices.push(device);
		save(done);
	}

	public function remove(machineId:String, deviceId:String, done:Bool->Void):Void {
		devices = [for (existing in devices) if (existing.machineId != machineId || existing.deviceId != deviceId) existing];
		save(done);
	}

	/** Records the machine's name once its directory has been read, when that is new. */
	public function learn(machineId:String, deviceId:String, name:String):Void {
		var device = find(machineId, deviceId);
		if (device == null || device.name == name) return;
		device.name = name;
		save(function(_) {});
	}

	function save(done:Bool->Void):Void {
		var document = Bytes.ofString(Json.stringify({version: VERSION, devices: devices}));
		HostBridge.request(HostBridge.KIND_SAVE_CREDENTIALS, document, done);
		// The request holds its own copy until the host takes it; this one carried the secrets only that far.
		for (index in 0...document.length) document.set(index, 0);
	}
}
