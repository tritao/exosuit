package workspace.provider;

import workspace.service.WorkspaceAgentProtocol.AgentContentChunk;

/** Optional bounded message snapshots, routed through the owning provider. */
interface AgentMessageSource extends LocalAgentProvider {
 public function messageContent(session:String, turn:String, item:String, token:String, offset:Int):Null<AgentContentChunk>;
}
