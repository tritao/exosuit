package workspace.service;

import haxeon.rpc.RpcConnection;

interface WorkspaceAgents {
	public function bind(connection:RpcConnection, capabilities:Array<String>):Void;
	public function poll():Void;
	public function activeCount():Int;
	public function dispose():Void;
}
