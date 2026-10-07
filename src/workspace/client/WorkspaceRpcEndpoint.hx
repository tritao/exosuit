package workspace.client;

import haxeon.rpc.RpcConnection;

/** Minimal authenticated workspace connection used by RPC-backed terminal sessions.
 * The root is service-owned and must not be canonicalized against the client's filesystem.
 */
interface WorkspaceRpcEndpoint {
	public function rootPath():Null<String>;
	public function serviceGeneration():String;
	public function rpcConnection():Null<RpcConnection>;
	public function failureReason():Null<String>;
	public function supportsWorkspaceGroups():Bool;
	public function workspaceEpoch():Null<String>;
	public function hasCapability(capability:String):Bool;
}
