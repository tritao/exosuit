package workspace.provider;

import haxeon.rpc.RpcContext;
import workspace.service.WorkspaceAgentProtocol;

/** Small daemon-owned provider surface. Native protocol details stay in each implementation. */
interface LocalAgentProvider {
 public function driverKind():String;
 public function nativeNamingSupported():Bool;
 public function summary():String;
 public function owns(id:String):Bool;
 public function records():Array<AgentRecord>;
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void;
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void;
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void;
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void;
 public function poll():Void;
 public function activeCount():Int;
 public function updateActivityCount():Int;
 public function dispose():Void;
}
