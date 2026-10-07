package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

typedef ServiceStatusQuery = workspace.service.WorkspacePairingProtocol.PairingListRequest;
@:wire
typedef WorkspaceServiceStatus = {
 @:id(1) var protocol:Int;
 @:id(2) var build:String;
 @:id(3) var terminals:Int;
 @:id(4) var agents:Int;
 @:id(5) var updatePending:Bool;
}
@:wire
typedef ServiceUpdateRequest = {
 @:id(1) var mode:String;
}
typedef ServiceUpdateResult = workspace.service.WorkspacePairingProtocol.PairingActionResult;

/** Same-user service management; never offered to remote or loopback WebSocket peers. */
class WorkspaceLifecycleProtocol {
 public static inline final CAPABILITY = "workspace.service.manage";
 public static inline final VERSION = 1;
 public static final STATUS = new RpcMethod<ServiceStatusQuery, WorkspaceServiceStatus>(136,
  function(value) return MessagePack.encode(value), function(bytes:Bytes):ServiceStatusQuery return MessagePack.decode(bytes),
  function(value) return MessagePack.encode(value), function(bytes:Bytes):WorkspaceServiceStatus return MessagePack.decode(bytes));
 public static final UPDATE = new RpcMethod<ServiceUpdateRequest, ServiceUpdateResult>(137,
  function(value) return MessagePack.encode(value), function(bytes:Bytes):ServiceUpdateRequest return MessagePack.decode(bytes),
  function(value) return MessagePack.encode(value), function(bytes:Bytes):ServiceUpdateResult return MessagePack.decode(bytes));
}
