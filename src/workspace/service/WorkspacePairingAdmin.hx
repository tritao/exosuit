package workspace.service;

import workspace.service.WorkspacePairingProtocol.PairingInvitation;
import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspacePairingProtocol.PendingPairing;

/** Local-only control surface for creating invitations and approving devices. */
interface WorkspacePairingAdmin {
	function createInvitation(ttlSeconds:Int, complete:PairingInvitation->Null<String>->Void):Void;
	function listPending():Array<PendingPairing>;
	function listDevices():Array<PairingDevice>;
	function approve(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void;
	function reject(deviceId:String):Bool;
	function revoke(deviceId:String, complete:Null<String>->Void):Void;
}
