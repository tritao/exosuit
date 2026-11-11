package workspace.runtime;

import workspace.transport.RelayMachineEndpoint;

/** Small relay surface needed by the local pairing state machine. */
interface WorkspacePairingRelay {
	function pairingEndpoint():RelayMachineEndpoint;
	function isConnected():Bool;
	function createPairing(channelId:String, secret:String, ttlSeconds:Int, complete:Null<String>->Void):Void;
	function registerDevice(channelId:String, token:String, complete:Null<String>->Void):Void;
	function revokeDevice(channelId:String, complete:Null<String>->Void):Void;
	/**
		The machine gave up a pairing on this channel (rejected, expired, rolled back): the relay closes the client's socket
		too, so the phone shows that the pairing ended instead of waiting on a channel nobody reads.
	**/
	function endPairingChannel(channelId:String):Void;
}
