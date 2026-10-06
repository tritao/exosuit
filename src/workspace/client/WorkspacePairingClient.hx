package workspace.client;

import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspacePairingProtocol.PairingInvitation;
import workspace.service.WorkspacePairingProtocol.PairingList;

/** Local-only controls for pairing and revoking remote devices. */
interface WorkspacePairingClient {
	public function canManagePairings():Bool;
	public function pairingList():Null<PairingList>;
	public function pairingRevision():Int;
	public function pairingBusy():Bool;
	public function pairingError():Null<String>;
	public function refreshPairings(force:Bool):Void;
	public function createPairing(ttlSeconds:Int, complete:PairingInvitation->Null<String>->Void):Void;
	public function approvePairing(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void;
	public function rejectPairing(deviceId:String, complete:Null<String>->Void):Void;
	public function revokePairing(deviceId:String, complete:Null<String>->Void):Void;
}
