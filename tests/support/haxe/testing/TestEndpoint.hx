package testing;

import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.WorkspaceTerminalEvents;

/**
	A workspace connection for client tests: an RPC connection the test made (usually over `MemoryTransport`) and what a
	service would have said about itself. Every field may change while the test runs.
**/
class TestEndpoint implements WorkspaceRpcEndpoint {
	public var connection:RpcConnection;
	public var root:Null<String> = "/fixture";
	public var generation:String = "fixture";
	public var epoch:Null<String> = "epoch";
	public var groups:Bool = true;
	/** The capabilities granted; null grants every one. **/
	public var grants:Null<Array<String>> = null;
	/** Capabilities withheld even when `grants` has them. **/
	public var denied:Array<String> = [];
	/** Whether terminal events are routed over the connection; false: `terminalEvents()` is null. **/
	public var events:Bool = true;

	var router:Null<WorkspaceTerminalEvents>;

	public function new(?connection:RpcConnection) this.connection = connection;

	public function rootPath():Null<String> return root;
	public function serviceGeneration():String return generation;
	public function workspaceEpoch():Null<String> return epoch;
	public function rpcConnection():Null<RpcConnection> return connection;
	public function failureReason():Null<String> return null;
	public function supportsWorkspaceGroups():Bool return groups;

	public function hasCapability(capability:String):Bool
		return (grants == null || grants.indexOf(capability) >= 0) && denied.indexOf(capability) < 0;

	/** One router per connection: a new connection gets a new one. **/
	public function terminalEvents():Null<WorkspaceTerminalEvents> {
		var current = connection;
		if (!events || current == null) return null;
		if (router == null || router.connection != current) router = new WorkspaceTerminalEvents(current);
		return router;
	}
}
