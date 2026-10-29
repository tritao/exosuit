package workspace.service;

import haxe.io.Bytes;

typedef AgentStoredContent = {var bytes:Bytes; var partial:Bool;}

/** Optional durable archive for captured, authoritative assistant responses. */
interface WorkspaceAgentContentPersistence {
 public function loadAgentContent(provider:String,session:String,turn:String,item:String):Null<AgentStoredContent>;
 public function saveAgentContent(provider:String,session:String,turn:String,item:String,bytes:Bytes,partial:Bool):Void;
}
