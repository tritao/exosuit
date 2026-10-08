package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

private class CapabilityEndpoint implements WorkspaceRpcEndpoint {
  public var connection:Null<RpcConnection>;
  public var grants:Array<String> = [];
  public function new(connection:RpcConnection) this.connection = connection;
  public function rootPath():Null<String> return "/fixture";
  public function serviceGeneration():String return "fixture";
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return hasCapability(WorkspaceProtocol.TREE);
  public function workspaceEpoch():Null<String> return null;
  public function hasCapability(capability:String):Bool return grants.indexOf(capability) >= 0;
}

/** Terminal UI decisions depend on negotiated workspace grants, without a local process host. */
class TerminalCapabilitiesTests {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  public static function run():Void {
    var pair = MemoryTransport.pair(), connection = new RpcConnection(pair.client, () -> 0.0);
    var endpoint = new CapabilityEndpoint(connection), client = new RpcWorkspaceWorkbenchClient(endpoint, () -> 0.0);
    endpoint.grants = [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG];
    require(client.canReadTerminals() && !client.canCreateTerminals(), "Read-only device can create terminals");
    endpoint.grants.push(WorkspaceTerminalProtocol.CONTROL);
    require(client.canCreateTerminals() && !client.canCreateGroupedTerminals(), "Ungrouped terminal requires unrelated tree permissions");
    endpoint.grants.push(WorkspaceProtocol.TREE);
    require(client.canCreateGroupedTerminals() && !client.canEditGroups(), "Terminal creation requires group editing permission");
    endpoint.grants.remove(WorkspaceTerminalProtocol.READ);
    require(!client.canCreateTerminals() && !client.canCreateGroupedTerminals(), "Creation allowed without terminal read permission");
    endpoint.connection = null;
    require(!client.canReadTerminals() && !client.canControlTerminals() && !client.canCreateTerminals(), "Disconnected device retained terminal actions");
    connection.close();
    Sys.println("PASS: remote terminal availability, read-only grants, group permissions and disconnect");
  }
}
