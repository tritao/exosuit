package exohost.remote;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import exohost.ExohostRecord.ExohostRecords;
import workspace.service.WorkspaceDevicePersistence;
import workspace.service.WorkspaceDeviceRecord;

/**
	The machine's paired devices and what each may reach, in `machine-devices.json` in exohost's (private) home. A device
	is pinned by its Noise key; `workspaces` maps a workspace id to the capabilities the owner granted the device in
	it. Pairing grants no workspace: the map starts empty. Only the daemon writes the file; it keeps the parsed copy.
	It is the persistence of exohost's pairing manager (WorkspacePairingManager).
**/
class MachineDeviceStore implements WorkspaceDevicePersistence {
	public static inline final VERSION = 1;
	static inline final FILE_LIMIT = 1048576;

	final path:String;
	var devices:Array<WorkspaceDeviceRecord> = [];
	/** One grant per device and workspace. Kept apart from the records: a grant may precede its record's approval. */
	var grants:Array<DeviceWorkspaceGrant> = [];
	var names:Map<String, String> = [];
	/** When each device was paired (ms since the epoch), for exohost's device list; absent for devices paired before it was kept. */
	var pairedAt:Map<String, Float> = [];

	/** True when the file could not be read: the store is then empty and never writes, so the file stays as it is. */
	public final unreadable:Bool;

	/**
		Reads the file, skipping device and grant entries that are not valid. Throws when the file as a whole cannot be
		used (too large, not JSON, another version), unless `readFile` is false: then the store is empty and `unreadable`.
	**/
	public function new(path:String, readFile:Bool = true) {
		this.path = path;
		unreadable = !readFile;
		if (!readFile || !FileSystem.exists(path))
			return;
		var info = FileSystem.metadata(path);
		if (info == null || info.size > FILE_LIMIT)
			throw "machine-devices.json is too large";
		var value:Dynamic = Json.parse(File.getContent(path));
		if (ExohostRecords.intField(value, "version") != VERSION)
			throw "machine-devices.json has an unknown version";
		var listed:Dynamic = Reflect.field(value, "devices");
		if (Std.isOfType(listed, Array))
			for (item in (listed : Array<Dynamic>)) {
				var id = ExohostRecords.stringField(item, "deviceId"), key = ExohostRecords.stringField(item, "key");
				// A Noise static key is 32 bytes.
				if (id == null || key == null || key.length != 64 || !~/^[0-9a-f]+$/.match(key))
					continue;
				devices.push({deviceId: id, staticPublicKey: fromHex(key), grants: strings(Reflect.field(item, "grants")),
					revoked: Reflect.field(item, "revoked") == true});
				var given = ExohostRecords.stringField(item, "name");
				if (given != null)
					names.set(id, given);
				var paired = ExohostRecords.floatField(item, "pairedAt");
				if (paired != null)
					pairedAt.set(id, paired);
			}
		var granted:Dynamic = Reflect.field(value, "workspaces");
		if (granted != null && Reflect.isObject(granted))
			for (device in Reflect.fields(granted)) {
				var entries:Dynamic = Reflect.field(granted, device);
				if (entries == null || !Reflect.isObject(entries) || Std.isOfType(entries, Array))
					continue;
				for (workspace in Reflect.fields(entries))
					grants.push({device: device, workspace: workspace, grants: strings(Reflect.field(entries, workspace))});
			}
	}

	static function toHex(bytes:Bytes):String {
		var output = new StringBuf();
		for (index in 0...bytes.length)
			output.add(StringTools.hex(bytes.get(index), 2).toLowerCase());
		return output.toString();
	}

	static function fromHex(value:String):Bytes {
		if (value.length % 2 != 0 || !~/^[0-9a-f]*$/.match(value))
			throw "invalid device key";
		var result = Bytes.alloc(Std.int(value.length / 2));
		for (index in 0...result.length)
			result.set(index, Std.parseInt("0x" + value.substr(index * 2, 2)));
		return result;
	}

	static function strings(value:Dynamic):Array<String> {
		var result:Array<String> = [];
		if (Std.isOfType(value, Array))
			for (item in (value : Array<Dynamic>))
				if (Std.isOfType(item, String))
					result.push(item);
		return result;
	}

	function save():Void {
		if (unreadable)
			throw "machine-devices.json could not be read; it is left as it is";
		var listed:Array<Dynamic> = [];
		for (record in devices)
			listed.push({deviceId: record.deviceId, key: toHex(record.staticPublicKey), grants: record.grants, revoked: record.revoked,
				name: names.get(record.deviceId), pairedAt: pairedAt.get(record.deviceId)});
		var granted:Dynamic = {};
		for (entry in grants) {
			var entries:Dynamic = Reflect.field(granted, entry.device);
			if (entries == null) {
				entries = {};
				Reflect.setField(granted, entry.device, entries);
			}
			Reflect.setField(entries, entry.workspace, entry.grants);
		}
		AtomicFile.write(path, Json.stringify({version: VERSION, devices: listed, workspaces: granted}) + "\n");
	}

	public function loadDevices():Array<WorkspaceDeviceRecord> {
		return [for (record in devices) {deviceId: record.deviceId, staticPublicKey: record.staticPublicKey, grants: record.grants.copy(), revoked: record.revoked}];
	}

	public function saveDevice(record:WorkspaceDeviceRecord):Void {
		var copy:WorkspaceDeviceRecord = {deviceId: record.deviceId, staticPublicKey: record.staticPublicKey, grants: record.grants.copy(),
			revoked: record.revoked};
		for (index in 0...devices.length)
			if (devices[index].deviceId == record.deviceId) {
				devices[index] = copy;
				save();
				return;
			}
		devices.push(copy);
		pairedAt.set(record.deviceId, Date.now().getTime());
		save();
	}

	/** A device's name, when it gave one. */
	public function nameOf(deviceId:String):Null<String>
		return names.get(deviceId);

	/** When a device was paired (ms since the epoch), or null when not known. */
	public function pairedAtOf(deviceId:String):Null<Float>
		return pairedAt.get(deviceId);

	public function revokeDevice(deviceId:String):Void {
		for (record in devices)
			if (record.deviceId == deviceId) {
				record.revoked = true;
				// A revoked device keeps its pin but reaches nothing.
				dropGrants(deviceId);
				save();
				return;
			}
		throw "unknown device";
	}

	public function deleteDevice(deviceId:String):Void {
		devices = [for (record in devices) if (record.deviceId != deviceId) record];
		dropGrants(deviceId);
		names.remove(deviceId);
		pairedAt.remove(deviceId);
		save();
	}

	function dropGrants(deviceId:String):Bool {
		var before = grants.length;
		grants = [for (entry in grants) if (entry.device != deviceId) entry];
		return grants.length != before;
	}

	/** The capabilities `deviceId` holds in `workspace`, or null when it is not granted that workspace. */
	public function grantsFor(deviceId:String, workspace:String):Null<Array<String>> {
		for (entry in grants)
			if (entry.device == deviceId && entry.workspace == workspace)
				return entry.grants.copy();
		return null;
	}

	/** Every workspace `deviceId` is granted, with its capabilities. */
	public function grantsOf(deviceId:String):Map<String, Array<String>> {
		var result = new Map<String, Array<String>>();
		for (entry in grants)
			if (entry.device == deviceId)
				result.set(entry.workspace, entry.grants.copy());
		return result;
	}

	/** Replaces the device's workspaces: those not in `wanted` are no longer reachable. */
	public function setGrants(deviceId:String, wanted:Map<String, Array<String>>):Void {
		dropGrants(deviceId);
		for (workspace => capabilities in wanted)
			grants.push({device: deviceId, workspace: workspace, grants: capabilities.copy()});
		save();
	}

	public function clearGrants(deviceId:String):Void {
		if (dropGrants(deviceId))
			save();
	}

	/** A workspace was deleted: no device is granted it any more. Returns whether any grant went. */
	public function forgetWorkspace(workspace:String):Bool {
		var before = grants.length;
		grants = [for (entry in grants) if (entry.workspace != workspace) entry];
		if (grants.length == before)
			return false;
		save();
		return true;
	}
}

private typedef DeviceWorkspaceGrant = {
	var device:String;
	var workspace:String;
	var grants:Array<String>;
}
