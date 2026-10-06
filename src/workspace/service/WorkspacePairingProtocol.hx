package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire typedef CreatePairingRequest = {
	@:id(1) var ttlSeconds:Int;
}

@:wire typedef PairingInvitation = {
	@:id(1) var relayOrigin:String;
	@:id(2) var machineId:String;
	@:id(3) var deviceId:String;
	@:id(4) var secret:String;
	@:id(5) var pairingSocketUrl:String;
	@:id(6) var expiresInSeconds:Int;
}

@:wire typedef PairingListRequest = {}

@:wire typedef PendingPairing = {
	@:id(1) var deviceId:String;
	@:id(2) var authenticationCode:String;
	@:id(3) var expiresInSeconds:Int;
}

@:wire typedef PairingList = {
	@:id(1) var pending:Array<PendingPairing>;
	@:id(2) var devices:Array<PairingDevice>;
}

@:wire typedef PairingDevice = {
	@:id(1) var deviceId:String;
	@:id(2) var grants:Array<String>;
	@:id(3) var revoked:Bool;
	@:id(4) var connected:Bool;
}

@:wire typedef ApprovePairingRequest = {
	@:id(1) var deviceId:String;
	@:id(2) var grants:Array<String>;
}

@:wire typedef PairingActionRequest = {
	@:id(1) var deviceId:String;
}

@:wire typedef PairingActionResult = {
	@:id(1) var accepted:Bool;
	@:optional @:id(2) var error:Null<String>;
}

/** Pairing administration is available only over the same-user local socket. */
class WorkspacePairingProtocol {
	public static inline final ADMIN = "workspace.pairing.admin";
	public static final CREATE = new RpcMethod<CreatePairingRequest, PairingInvitation>(120,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):CreatePairingRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingInvitation return MessagePack.decode(bytes));
	public static final LIST = new RpcMethod<PairingListRequest, PairingList>(121,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingListRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingList return MessagePack.decode(bytes));
	public static final APPROVE = new RpcMethod<ApprovePairingRequest, PairingActionResult>(122,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):ApprovePairingRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingActionResult return MessagePack.decode(bytes));
	public static final REJECT = new RpcMethod<PairingActionRequest, PairingActionResult>(123,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingActionRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingActionResult return MessagePack.decode(bytes));
	public static final REVOKE = new RpcMethod<PairingActionRequest, PairingActionResult>(124,
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingActionRequest return MessagePack.decode(bytes),
		function(value) return MessagePack.encode(value), function(bytes:Bytes):PairingActionResult return MessagePack.decode(bytes));
}
