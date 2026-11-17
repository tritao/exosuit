import haxe.Json;
import haxe.io.Bytes;

/** One paired machine as the phone keeps it (ADR 0005 section 4). The key and token are secrets: the host stores them under the Android Keystore. */
typedef PairedMachine = workspace.client.DevicePairing.PairedMachine;

/**
	The phone's paired machines. The document lives in the host's Keystore-encrypted file: it arrives with the `start`
	command (`load`) and goes back through HostBridge on every change (`save`). Nothing is written by the Haxe side.
**/
class PhoneCredentials implements workspace.client.DevicePairing.PairedMachines {
	/** Version 1 held one pairing per workspace service; those are not machine pairings, so they are not read. */
	public static inline final VERSION = 2;
	public static inline final MAX_DEVICES = 16;

	public var devices(default, null):Array<PairedMachine> = [];
	/** The host has saved pairings that could not be opened (Keystore or file failure) or read (not a document this version understands); `devices` is empty but nothing was lost yet. */
	public var unreadable(default, null):Bool = false;

	public function new() {}

	public function load(document:Null<Bytes>, unreadable:Bool = false):Void {
		devices = [];
		this.unreadable = unreadable;
		if (document == null || document.length == 0) return;
		if (read(document)) return;
		// The document opened but is not one this version reads (damaged text, an unknown version). That is not "no
		// pairings": the host is told, so the next save moves the file aside instead of replacing it.
		devices = [];
		this.unreadable = true;
		HostBridge.request(HostBridge.KIND_CREDENTIALS_UNREADABLE, Bytes.alloc(0), function(_) {});
	}

	/** Fills `devices` from the document. False when it is not a credentials document this version can read. */
	function read(document:Bytes):Bool {
		try {
			var value:Dynamic = Json.parse(document.toString());
			if (value == null) return false;
			var version:Dynamic = Reflect.field(value, "version");
			// Version 1 is known and deliberately not read (see VERSION): an empty list that the next save may replace.
			if (version == 1) return true;
			var entries:Dynamic = Reflect.field(value, "devices");
			if (version != VERSION || !Std.isOfType(entries, Array)) return false;
			for (entry in (cast entries:Array<Dynamic>)) {
				if (devices.length >= MAX_DEVICES) break;
				var device = validate(entry);
				if (device != null) devices.push(device);
			}
			return true;
		} catch (_:Dynamic) return false;
	}

	static function validate(entry:Dynamic):Null<PairedMachine> {
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

	public function paired():Array<PairedMachine> return devices;

	public function find(machineId:String, deviceId:String):Null<PairedMachine> {
		for (device in devices) if (device.machineId == machineId && device.deviceId == deviceId) return device;
		return null;
	}

	/**
		Adds or replaces the entry for the same machine and device, then stores the document. When the host refuses to store
		it, the entry is taken back out (and the one it replaced, if any, put back), so a later save (learn, remove) cannot
		store a device whose pairing never completed.
	**/
	public function put(device:PairedMachine, done:Bool->Void):Void {
		var previous = find(device.machineId, device.deviceId);
		devices = [for (existing in devices) if (existing.machineId != device.machineId || existing.deviceId != device.deviceId) existing];
		devices.push(device);
		save(function(ok) {
			if (!ok && devices.indexOf(device) >= 0) {
				devices = [for (existing in devices) if (existing != device) existing];
				if (previous != null) devices.push(previous);
			}
			done(ok);
		});
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
