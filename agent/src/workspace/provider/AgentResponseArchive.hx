package workspace.provider;

import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentContentPersistence;
import workspace.service.WorkspaceAgentContentPersistence.AgentStoredContent;
import workspace.service.WorkspaceAgentProtocol.AgentActivityItem;

/** Captured source only: never upgrades a persisted preview into authoritative content. */
class AgentResponseArchive {
 final store:Null<WorkspaceAgentContentPersistence>;
 final provider:String; final session:String;
 public var problem(default,null):Null<String>;
 public function new(provider:String,session:String,persistence:Null<WorkspaceAgentPersistence>) {
  this.provider=provider;this.session=session;
  store=Std.isOfType(persistence,WorkspaceAgentContentPersistence) ? cast persistence : null;
 }
 static function digest(source:AgentStoredContent):String
  return haxe.crypto.Sha256.encode((source.partial ? "partial:" : "complete:")+source.bytes.toString());
 public function capture(key:String,entry:AgentActivityItem):Void {
  if(entry.kind!="agentMessage" || entry.state=="inProgress" || entry.contentToken==null) return;
  var source=AgentContentCache.snapshot(key,entry.contentToken);
  if(source==null) return;
  entry.contentDigest=digest(source);
  if(store==null) return;
  try {store.saveAgentContent(provider,session,entry.turn,entry.id,source.bytes,source.partial);problem=null;}
  catch (_:Dynamic) problem="Full response history could not be saved; current session content remains available.";
 }
 public function restore(key:String,entry:AgentActivityItem,?token:String):Null<String> {
  if(store==null || entry.kind!="agentMessage" || entry.state=="inProgress" || entry.contentDigest==null) return null;
  try {
   var source=store.loadAgentContent(provider,session,entry.turn,entry.id);
   if(source==null || source.bytes==null || source.bytes.length>AgentContentCache.MAX_MESSAGE
      || !workspace.TextFileContent.validUtf8(source.bytes) || digest(source)!=entry.contentDigest) return null;
   var recovered=AgentContentCache.recover(key,source.bytes,source.partial,token);problem=null;return recovered;
  } catch (_:Dynamic) {problem="Full response history is unavailable; the retained preview is shown.";return null;}
 }
}
