package workspace.service;

import haxeon.rpc.RpcConnection;

/** Native runtime ownership stays behind this transport-independent service boundary. */
interface WorkspaceTerminals {
  public function bind(connection:RpcConnection, capabilities:Array<String>):Void;
  public function poll():Void;
  public function activeCount():Int;
  public function dispose():Void;
}
