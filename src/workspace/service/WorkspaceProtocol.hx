package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire typedef WorkspaceGroup = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var cwd:Null<String>;
	@:id(4) var revision:Int;
}

@:wire typedef WorkspaceQuery = {@:id(1) var workspace:String;}

@:wire typedef WorkspaceSnapshot = {
	@:id(1) var epoch:String;
	@:id(2) var cursor:Int;
	@:id(3) var groups:Array<WorkspaceGroup>;
}

@:wire typedef WorkspaceEvent = {
	@:id(1) var epoch:String;
	@:id(2) var sequence:Int;
	@:id(3) var group:WorkspaceGroup;
}

@:wire typedef WorkspaceWatch = {
	@:id(1) var workspace:String;
	@:id(2) var epoch:String;
	@:id(3) var cursor:Int;
}

@:wire typedef WorkspaceReplay = {
	@:id(1) var epoch:String;
	@:id(2) var cursor:Int;
	@:id(3) var reset:Bool;
	@:id(4) var events:Array<WorkspaceEvent>;
}

@:wire typedef RenameGroup = {
	@:id(1) var workspace:String;
	@:id(2) var epoch:String;
	@:id(3) var operation:String;
	@:id(4) var group:String;
	@:id(5) var expectedRevision:Int;
	@:id(6) var name:String;
}

@:wire typedef RenameResult = {
	@:id(1) var epoch:String;
	@:id(2) var operation:String;
	@:id(3) var sequence:Int;
	@:id(4) var group:WorkspaceGroup;
}

@:wire typedef OperationQuery = {
	@:id(1) var workspace:String;
	@:id(2) var epoch:String;
	@:id(3) var operation:String;
}

@:wire typedef OperationResult = {
	@:id(1) var known:Bool;
	@:id(2) var outcome:Null<RenameResult>;
}

/** Permanent ids for the first workspace service methods; never reuse ids. */
class WorkspaceProtocol {
	public static inline final READ = "workspace.read";
	public static inline final EVENTS = "workspace.events";
	public static inline final WRITE = "workspace.groups.write";
	public static inline final CHANGED = 200;
	public static final QUERY = new RpcMethod<WorkspaceQuery, WorkspaceSnapshot>(100, function(value:WorkspaceQuery) return MessagePack.encode(value),
		function(bytes:Bytes):WorkspaceQuery return MessagePack.decode(bytes), function(value:WorkspaceSnapshot) return MessagePack.encode(value),
		function(bytes:Bytes):WorkspaceSnapshot return MessagePack.decode(bytes));
	public static final WATCH = new RpcMethod<WorkspaceWatch, WorkspaceReplay>(101, function(value:WorkspaceWatch) return MessagePack.encode(value),
		function(bytes:Bytes):WorkspaceWatch return MessagePack.decode(bytes), function(value:WorkspaceReplay) return MessagePack.encode(value),
		function(bytes:Bytes):WorkspaceReplay return MessagePack.decode(bytes));
	public static final RENAME = new RpcMethod<RenameGroup, RenameResult>(102, function(value:RenameGroup) return MessagePack.encode(value),
		function(bytes:Bytes):RenameGroup return MessagePack.decode(bytes), function(value:RenameResult) return MessagePack.encode(value),
		function(bytes:Bytes):RenameResult return MessagePack.decode(bytes));
	public static final OPERATION = new RpcMethod<OperationQuery, OperationResult>(103, function(value:OperationQuery) return MessagePack.encode(value),
		function(bytes:Bytes):OperationQuery return MessagePack.decode(bytes), function(value:OperationResult) return MessagePack.encode(value),
		function(bytes:Bytes):OperationResult return MessagePack.decode(bytes));

	public static function encodeEvent(value:WorkspaceEvent):Bytes
		return MessagePack.encode(value);

	public static function decodeEvent(bytes:Bytes):WorkspaceEvent
		return MessagePack.decode(bytes);

	public static function copyGroup(value:WorkspaceGroup):WorkspaceGroup
		return {
			id: value.id,
			name: value.name,
			cwd: value.cwd,
			revision: value.revision
		};

	public static function copyOutcome(value:RenameResult):RenameResult
		return {
			epoch: value.epoch,
			operation: value.operation,
			sequence: value.sequence,
			group: copyGroup(value.group)
		};
}
