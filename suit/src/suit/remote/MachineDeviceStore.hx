package suit.remote;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import suit.SuitRecord.SuitRecords;
import workspace.service.WorkspaceDevicePersistence;
import workspace.service.WorkspaceDeviceRecord;

/**
	The machine's paired devices and what each may reach, in `machine-devices.json` in suit's (private) home. A device
	is pinned by its Noise key; `workspaces` maps a workspace id to the capabilities the owner granted the device in
	it. Pairing grants no workspace: the map starts empty. Only the daemon writes the file; it keeps the parsed copy.
	The pairing manager's persistence interface is implemented here, so the manager is the same one a workspace service
	uses.
**/
class MachineDeviceStore implements WorkspaceDevicePersistence {
	public static inline final VERSION = 1;
	static inline final FILE_LIMIT = 1048576;

	final path:String;
	var devices:Array<WorkspaceDeviceRecord> = [];
	/** One grant per device and workspace. Kept apart from the records: a grant may precede its record's approval. */
	var grants:Array<DeviceWorkspaceGrant> = [];
	var names:Map<String, String> = [];

	public function new(path:String) {
		this.path = path;
		if (!FileSystem.exists(path))
			return;
		var info = FileSystem.metadata(path);
		if (info == null || info.size > FILE_LIMIT)
			throw "machine-devices.json is too large";
		var value:Dynamic = Json.parse(File.getContent(path));
		if (SuitRecords.intField(value, "version") != VERSION)
			throw "machine-devices.json has an unknown version";
		for (item in (Reflect.field(value, "devices") : Array<Dynamic>)) {
			var id = SuitRecords.stringField(item, "deviceId"), key = SuitRecords.stringField(item, "key");
			if (id == null || key == null)
				continue;
			devices.push({deviceId: id, staticPublicKey: fromHex(key), grants: strings(Reflect.field(item, "grants")),
				revoked: Reflect.field(item, "revoked") == true});
			var given = SuitRecords.stringField(item, "name");
			if (given != null)
				names.set(id, given);
		}
		var granted:Dynamic = Reflect.field(value, "workspaces");
		if (granted != null)
			for (device in Reflect.fields(granted)) {
				var entries:Dynamic = Reflect.field(granted, device);
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
		var listed:Array<Dynamic> = [];
		for (record in devices)
			listed.push({deviceId: record.deviceId, key: toHex(record.staticPublicKey), grants: record.grants, revoked: record.revoked,
				name: names.get(record.deviceId)});
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
		save();
	}

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
