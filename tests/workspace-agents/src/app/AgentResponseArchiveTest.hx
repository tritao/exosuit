package app;

import haxe.io.Bytes;
import workspace.provider.AgentContentCache;
import workspace.provider.AgentResponseArchive;
import workspace.provider.ClaudeConversation;
import workspace.provider.PiConversation;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentContentPersistence;
import workspace.service.WorkspaceAgentContentPersistence.AgentStoredContent;

class AgentResponseArchiveTest {
 static function require(ok:Bool,message:String):Void if(!ok) throw message;
 static function body(load:Int->Null<AgentContentChunk>,expected:String,partial:Bool=false):Void {
  var data=new haxe.io.BytesBuffer(),offset=0;
  while(true) {
   var result=load(offset);if(result==null) throw "Archived response chunk missing";
   require(result.offset==offset && result.partial==partial && result.bytes.length<=24576,"Archived response chunk contract changed");
   data.addBytes(result.bytes,0,result.bytes.length);offset+=result.bytes.length;
   if(offset==result.total) break;
   require(result.bytes.length>0,"Archived response did not progress");
  }
  require(data.getBytes().toString()==expected,"Recovered response changed exact source");
 }
 public static function run():Void {
  var path=Sys.args()[0]+"/response-recovery.sqlite";
  var seed:workspace.service.WorkspaceProtocol.WorkspaceSnapshot={epoch:"fixture",cursor:0,groups:[{id:"work",name:"Work",cwd:"/fixture",revision:1}]};
  var store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  var records:Array<AgentRecord>=[];
  for(kind in ["claude","pi"]) {
   var record:AgentRecord={id:kind,name:kind,group:"work",cwd:"/fixture",thread:"thread",state:"completed",turn:null,workspaceRoot:"/fixture",provider:kind};
   store.saveAgent(record);records.push(record);
  }
  var text="```hx\r\n"+StringTools.rpad("", "雪",6000)+"\r\n```\r\n";
  var claude=new ClaudeConversation(null,new AgentResponseArchive("claude","claude",store));
  claude.put("message","turn","agentMessage","Claude",text,"","completed");
  records[0].replay=claude.snapshot();store.saveAgent(records[0]);
  var pi=new PiConversation(null,new AgentResponseArchive("pi","pi",store));
  pi.delta("message","turn",text);pi.finish("turn","completed");
  records[1].replay=pi.snapshot();store.saveAgent(records[1]);
  store.close();
  for(i in 0...129) AgentContentCache.replace("evict-before-restart-"+i,"x");
  store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  records=store.loadAgents();
  var claudeReplay:Array<AgentActivityItem>=[],piReplay:Array<AgentActivityItem>=[];
  for(record in records) {if(record.provider=="claude") claudeReplay=cast record.replay;else piReplay=cast record.replay;}
  claude=new ClaudeConversation(claudeReplay,new AgentResponseArchive("claude","claude",store));
  pi=new PiConversation(piReplay,new AgentResponseArchive("pi","pi",store));
  var c=claude.page()[0],p=pi.page()[0];
  require(c.contentToken!=null && p.contentToken!=null && c.truncated && p.truncated,"Restart did not recover authoritative source tokens");
  body(function(offset) return claude.content("turn","message",c.contentToken,offset),text);
  body(function(offset) return pi.content("turn","message",p.contentToken,offset),text);
  for(i in 0...129) AgentContentCache.replace("evict-after-restart-"+i,"x");
  body(function(offset) return claude.content("turn","message",c.contentToken,offset),text);
  require(claude.content("turn","message","stale-token",0)==null,"Recovery accepted an unpublished content token");
  store.saveAgentContent("claude","claude","turn","message",Bytes.ofString(text+"changed tail"),false);
  var mismatch=new ClaudeConversation(claudeReplay,new AgentResponseArchive("claude","claude",store));
  require(mismatch.page()[0].contentToken==null,"Digest mismatch upgraded stale source to full content");
  var legacy:AgentActivityItem=cast Reflect.copy(claudeReplay[0]);legacy.contentDigest=null;
  var legacyConversation=new ClaudeConversation([legacy],new AgentResponseArchive("claude","claude",store));
  require(legacyConversation.page()[0].contentToken==null,"Legacy preview invented authoritative source");
  var oversized=StringTools.rpad("", "x",AgentContentCache.MAX_MESSAGE+10);
  pi.put("large","turn2","agentMessage","Pi",oversized,"","completed");
  var partialPi=new PiConversation(pi.snapshot(),new AgentResponseArchive("pi","pi",store));
  var page=partialPi.page(),last=page[page.length-1];
  body(function(offset) return partialPi.content("turn2","large",last.contentToken,offset),oversized.substring(0,AgentContentCache.MAX_MESSAGE),true);
  var failed=new ClaudeConversation(null,new AgentResponseArchive("claude","failure",new FailedResponseStore()));
  failed.put("message","turn","agentMessage","Claude",text,"","completed");
  require(failed.archiveError()!=null,"Archive failure was hidden");
  var retained=failed.page()[0];body(function(offset) return failed.content("turn","message",retained.contentToken,offset),text);
  store.close();
  Sys.println("PASS: Claude/Pi captured response restart, exact source, eviction recovery, digest binding, legacy fallback, partial and storage failure");
 }
}
private class FailedResponseStore implements WorkspaceAgentPersistence implements WorkspaceAgentContentPersistence {
 public function new() {}
 public function loadAgents():Array<AgentRecord> return [];
 public function saveAgent(record:AgentRecord):Void {}
 public function removeAgent(id:String):Void {}
 public function loadAgentContent(provider:String,session:String,turn:String,item:String):Null<AgentStoredContent> return null;
 public function saveAgentContent(provider:String,session:String,turn:String,item:String,bytes:Bytes,partial:Bool):Void throw "storage unavailable";
}
