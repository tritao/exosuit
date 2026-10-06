package workspace.service;

interface WorkspaceDevicePersistence {
	function loadDevices():Array<WorkspaceDeviceRecord>;
	function saveDevice(record:WorkspaceDeviceRecord):Void;
	function revokeDevice(deviceId:String):Void;
	function deleteDevice(deviceId:String):Void;
}
