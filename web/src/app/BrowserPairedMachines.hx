package app;

import haxe.Json;
import workspace.client.DevicePairing.PairedMachine;
import workspace.client.DevicePairing.PairedMachines;

/**
	The browser's paired machines (`PairedMachines`): the records live in IndexedDB, encrypted with a non-extractable
	AES-GCM key (remote-device-store.js). The guest asks the page with one console line per request (`exosuit-remote-list:`,
	`exosuit-remote-load:`, `exosuit-remote-store:`, `exosuit-remote-forget:`), and the page answers through WebMain's
	exposed callbacks: bounded ASCII payload chunks, or a stored/failed flag.

	`load` reads every record at start (the list, then each record's credentials) and calls `done` once, with whether
	something could not be read.
**/
class BrowserPairedMachines implements PairedMachines {
	static inline final LIST = 1;
	static inline final LOAD = 2;

	var devices:Array<PairedMachine> = [];
	var nextRequest = 1;
	final storing:Map<Int, Bool->Void> = [];
	var payloadRequest = 0;
	var payloadKind = 0;
	var payloadIndex = 0;
	var payloadInvalid = false;
	var payload = new StringBuf();
	var listing = 0;
	var loading:Array<{machineId:String, deviceId:String}> = [];
	var loadingRequest = 0;
	var loaded:Array<PairedMachine> = [];
	var unreadable = false;
	var ready:Null<Bool->Void>;

	public function new() {}

	public function paired():Array<PairedMachine>
		return devices;

	/** Reads every saved pairing; `done(unreadable)` once all are in `paired()`. */
	public function load(done:Bool->Void):Void {
		ready = done;
		listing = nextRequest++;
		begin(listing, LIST);
		Sys.println("exosuit-remote-list:" + listing);
	}

	public function put(device:PairedMachine, done:Bool->Void):Void {
		var request = nextRequest++;
		storing.set(request, function(ok) {
			if (ok) {
				devices = [for (existing in devices) if (existing.machineId != device.machineId || existing.deviceId != device.deviceId) existing];
				devices.push(device);
			}
			done(ok);
		});
		Sys.println("exosuit-remote-store:" + Json.stringify({request: request, machineId: device.machineId, deviceId: device.deviceId,
			staticPrivateKey: device.staticPrivateKey, deviceToken: device.deviceToken, machineStaticPublicKey: device.machineStaticPublicKey,
			relayOrigin: device.relayOrigin}));
	}

	public function remove(machineId:String, deviceId:String, done:Bool->Void):Void {
		devices = [for (existing in devices) if (existing.machineId != machineId || existing.deviceId != deviceId) existing];
		Sys.println("exosuit-remote-forget:" + Json.stringify({machineId: machineId, deviceId: deviceId}));
		done(true);
	}

	public function learn(machineId:String, deviceId:String, name:String):Void {
		for (device in devices)
			if (device.machineId == machineId && device.deviceId == deviceId)
				device.name = name;
	}

	/** The page stored (or failed to store) the record of request `request`. */
	public function stored(request:Int, ok:Bool):Void {
		var done = storing.get(request);
		storing.remove(request);
		if (done != null) done(ok);
	}

	function begin(request:Int, kind:Int):Void {
		payloadRequest = request;
		payloadKind = kind;
		payloadIndex = 0;
		payloadInvalid = false;
		payload = new StringBuf();
	}

	public function chunk(request:Int, kind:Int, index:Int, value:Int):Void {
		if (request != payloadRequest || kind != payloadKind) return;
		if (index != payloadIndex || value < 0 || value > 127 || payloadIndex >= 32768) {
			payloadInvalid = true;
			return;
		}
		payload.addChar(value);
		payloadIndex++;
	}

	public function complete(request:Int, kind:Int, length:Int, success:Bool):Void {
		if (request != payloadRequest || kind != payloadKind) return;
		var text = success && !payloadInvalid && length == payloadIndex ? payload.toString() : null;
		payloadRequest = 0;
		if (kind == LIST && request == listing) {
			listing = 0;
			loading = [];
			if (text == null) unreadable = true;
			else
				try {
					var values:Array<Dynamic> = Json.parse(text);
					for (value in values) {
						var machineId:String = Reflect.field(value, "machineId"), deviceId:String = Reflect.field(value, "deviceId");
						if (hex(machineId, 32) && hex(deviceId, 32)) loading.push({machineId: machineId, deviceId: deviceId});
						else unreadable = true;
					}
				} catch (_:Dynamic) unreadable = true;
			loadNext();
		} else if (kind == LOAD && request == loadingRequest) {
			loadingRequest = 0;
			try {
				if (text == null) throw "unreadable";
				var value:Dynamic = Json.parse(text);
				var credentials:Dynamic = Reflect.field(value, "credentials");
				var device:PairedMachine = {machineId: Reflect.field(value, "machineId"), deviceId: Reflect.field(value, "deviceId"),
					relayOrigin: Reflect.field(credentials, "relayOrigin"), staticPrivateKey: Reflect.field(credentials, "staticPrivateKey"),
					deviceToken: Reflect.field(credentials, "deviceToken"), machineStaticPublicKey: Reflect.field(credentials, "machineStaticPublicKey"),
					name: null};
				if (!hex(device.machineId, 32) || !hex(device.deviceId, 32) || !hex(device.staticPrivateKey, 64) || !hex(device.deviceToken, 64)
					|| !hex(device.machineStaticPublicKey, 64) || device.relayOrigin == null)
					throw "invalid";
				loaded.push(device);
			} catch (_:Dynamic) unreadable = true;
			loadNext();
		}
	}

	function loadNext():Void {
		if (loading.length == 0) {
			devices = loaded;
			loaded = [];
			var done = ready;
			ready = null;
			if (done != null) done(unreadable);
			return;
		}
		var next = loading.shift();
		if (next == null) return;
		loadingRequest = nextRequest++;
		begin(loadingRequest, LOAD);
		Sys.println("exosuit-remote-load:" + Json.stringify({request: loadingRequest, machineId: next.machineId, deviceId: next.deviceId}));
	}

	static function hex(value:Null<String>, length:Int):Bool
		return value != null && value.length == length && ~/^[0-9a-f]+$/.match(value);
}
