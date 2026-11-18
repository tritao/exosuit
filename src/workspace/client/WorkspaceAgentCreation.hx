package workspace.client;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceAgentProtocol;

/** UI snapshot; transport and completion ownership remain in the client. */
typedef AgentCreationStatus = {
 var id:String;
 var name:String;
 var provider:String;
 var phase:String;
}

/** One reserved resource ID across startup retries; never retries an ambiguous delivery. */
class WorkspaceAgentCreation {
 public final query:AgentCreate;
 public final connection:RpcConnection;
 public final root:String;
 public final deadline:Float;
 public final completed:Null<AgentRecord->Void>;
 /** Called once with the reason when the session did not start (the UI keeps a tab for it). */
 public final failed:Null<String->Void>;
 public var next:Float = 0;
 public var inFlight:Bool = false;
 public var phase:String = "waiting-catalog";
 public function new(query:AgentCreate,connection:RpcConnection,root:String,deadline:Float,?completed:AgentRecord->Void,?failed:String->Void) {
  this.query=query;this.connection=connection;this.root=root;this.deadline=deadline;this.completed=completed;this.failed=failed;
 }
 public function status():AgentCreationStatus return {
  id:query.id,name:query.name,provider:query.provider == null ? "codex" : query.provider,phase:phase
 };
}
