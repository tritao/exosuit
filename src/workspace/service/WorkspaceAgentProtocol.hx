package workspace.service;

import haxe.io.Bytes;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire typedef AgentRecord = {
	@:id(1) var id:String;
	@:id(2) var name:String;
	@:id(3) var group:String;
	@:id(4) var cwd:String;
	@:id(5) var thread:String;
	@:id(6) var state:String;
	@:id(7) var turn:Null<String>;
	@:id(8) var workspaceRoot:String;
}

@:wire typedef AgentQuery = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:optional @:id(3) var after:Null<String>;
}

@:wire typedef AgentCatalog = {
	@:id(1) var instance:String;
	@:id(2) var root:String;
	@:id(3) var records:Array<AgentRecord>;
	@:id(4) var status:String;
	@:optional @:id(5) var next:Null<String>;
}

@:wire typedef AgentCreate = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var id:String;
	@:id(4) var group:String;
	@:id(5) var name:String;
	// Null creates a new thread; non-null explicitly attaches an existing thread.
	@:id(6) var thread:Null<String>;
}

@:wire typedef AgentAction = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var id:String;
	@:id(4) var action:String;
	@:id(5) var text:String;
	@:id(6) var request:Null<String>;
}

@:wire typedef AgentRequest = {
	@:id(1) var id:String;
	@:id(2) var method:String;
	@:id(3) var detail:String;
	@:id(4) var reviewable:Bool;
}

@:wire typedef AgentView = {
	@:id(1) var record:AgentRecord;
	@:id(2) var activity:String;
	@:id(3) var requests:Array<AgentRequest>;
	@:id(4) var error:Null<String>;
	@:optional @:id(5) var items:Null<Array<AgentActivityItem>>;
	@:optional @:id(6) var itemsOmitted:Null<Bool>;
}

/** Bounded presentation data; provider protocol and policy stay on the host. */
@:wire typedef AgentActivityItem = {
	@:id(1) var id:String;
	@:id(2) var turn:String;
	@:id(3) var kind:String;
	@:id(4) var title:String;
	@:id(5) var text:String;
	@:id(6) var detail:String;
	@:id(7) var state:String;
	@:id(8) var truncated:Bool;
}

@:wire typedef AgentDiscoveryQuery = {
	@:id(1) var workspace:String;
	@:id(2) var instance:String;
	@:id(3) var group:String;
	@:id(4) var cursor:Null<String>;
}

@:wire typedef AgentThread = {
	@:id(1) var id:String;
	@:id(2) var title:String;
	@:id(3) var cwd:String;
}

@:wire typedef AgentDiscovery = {
	@:id(1) var threads:Array<AgentThread>;
	@:id(2) var next:Null<String>;
}

class WorkspaceAgentProtocol {
	public static inline final READ = "workspace.agents.read";
	public static inline final CONTROL = "workspace.agents.control";
	public static final DISCOVER = new RpcMethod<AgentDiscoveryQuery, AgentDiscovery>(123, function(v:AgentDiscoveryQuery) return MessagePack.encode(v),
		function(b:Bytes):AgentDiscoveryQuery return MessagePack.decode(b), function(v:AgentDiscovery) return MessagePack.encode(v),
		function(b:Bytes):AgentDiscovery return MessagePack.decode(b));
	public static final LIST = new RpcMethod<AgentQuery, AgentCatalog>(120, function(v:AgentQuery) return MessagePack.encode(v),
		function(b:Bytes):AgentQuery return MessagePack.decode(b), function(v:AgentCatalog) return MessagePack.encode(v),
		function(b:Bytes):AgentCatalog return MessagePack.decode(b));
	public static final CREATE = new RpcMethod<AgentCreate, AgentRecord>(121, function(v:AgentCreate) return MessagePack.encode(v),
		function(b:Bytes):AgentCreate return MessagePack.decode(b), function(v:AgentRecord) return MessagePack.encode(v),
		function(b:Bytes):AgentRecord return MessagePack.decode(b));
	public static final ACTION = new RpcMethod<AgentAction, AgentView>(122, function(v:AgentAction) return MessagePack.encode(v),
		function(b:Bytes):AgentAction return MessagePack.decode(b), function(v:AgentView) return MessagePack.encode(v),
		function(b:Bytes):AgentView return MessagePack.decode(b));
}
