package app;

import haxe.io.Bytes;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceAgentProtocol;

/** Real SQLite migration, identity, durability and archive quota checks. */
class AgentContentStorageTest {
 static function require(ok:Bool,message:String):Void if(!ok) throw message;
 static function main():Void run();
 public static function run():Void {
  var base=Sys.args()[0],path=base+"/agent-content.sqlite";
  var seed:WorkspaceSnapshot={epoch:"fixture",cursor:0,groups:[{id:"work",name:"Work",cwd:"/fixture",revision:1}]};
  var record:AgentRecord={id:"session",name:"Test",group:"work",cwd:"/fixture",thread:"thread",state:"idle",turn:null,workspaceRoot:"/fixture",provider:"claude"};
  var store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  store.saveAgent(record);
  var content=Bytes.ofString("Full response 雪");
  store.saveAgentContent("claude","session","turn","item",content,true);
  require(store.loadAgentContent("codex","session","turn","item")==null && store.loadAgentContent("claude","other","turn","item")==null,"Content escaped provider/session scope");
  store.close();store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  var restored=store.loadAgentContent("claude","session","turn","item");
  require(restored!=null && restored.bytes.compare(content)==0 && restored.partial,"Captured bytes/partial lost after reopen");
  var rejected=false;try store.saveAgentContent("claude","session","turn","large",Bytes.alloc(262145),false) catch(_:Dynamic) rejected=true;
  require(rejected,"Oversized content was stored");
  rejected=false;var invalid=Bytes.alloc(1);invalid.set(0,255);
  try store.saveAgentContent("claude","session","turn","invalid",invalid,false) catch(_:Dynamic) rejected=true;
  require(rejected,"Invalid UTF-8 content was stored");
  for(i in 0...129) store.saveAgentContent("claude","session","turn","entry-"+i,Bytes.ofString("x"),false);
  require(store.loadAgentContent("claude","session","turn","entry-0")==null && store.loadAgentContent("claude","session","turn","entry-128")!=null,"Oldest count quota was not enforced");
  var large=Bytes.alloc(262144);for(i in 0...large.length) large.set(i,120);
  for(i in 0...17) store.saveAgentContent("claude","session","large","entry-"+i,large,false);
  require(store.loadAgentContent("claude","session","large","entry-0")==null && store.loadAgentContent("claude","session","large","entry-16")!=null,"Oldest byte quota was not enforced");
  store.removeAgent("session");store.saveAgent(record);
  require(store.loadAgentContent("claude","session","large","entry-16")==null,"Removing an agent retained its content");
  store.close();
  var old=sqlitekit.Database.open(path,1000);old.exec("DROP TABLE workspace_agent_content");old.exec("DROP TABLE workspace_agent_content_meta");old.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  require(store.loadAgents().length==1,"Version 8 migration lost agents");
  store.saveAgentContent("claude","session","turn","migrated",content,false);store.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  require(store.loadAgentContent("claude","session","turn","migrated")!=null,"Version 8 extension failed to persist content");store.close();
  old=sqlitekit.Database.open(path,1000);
  var pragma=old.prepare("PRAGMA user_version");require(pragma.step() && haxe.Int64.toInt(pragma.columnInt64(0))==8,"Archive changed the core schema version");pragma.close();
  old.exec("DELETE FROM workspace_agents WHERE id='session'");old.close();
  rejected=false;try new WorkspaceSqliteStore(path,"other",seed) catch(_:Dynamic) rejected=true;
  require(rejected,"Foreign workspace opened before archive cleanup");
  old=sqlitekit.Database.open(path,1000);
  var countRows=old.prepare("SELECT count(*) FROM workspace_agent_content");
  require(countRows.step() && haxe.Int64.toInt(countRows.columnInt64(0))==1,"Foreign workspace changed archive state");
  countRows.close();old.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture");
  store.saveAgent(record);
  require(store.loadAgentContent("claude","session","turn","migrated")==null,"Legacy deletion left an orphaned response");store.close();
  old=sqlitekit.Database.open(path,1000);old.exec("UPDATE workspace_agent_content_meta SET version=2 WHERE id=1");old.close();
  rejected=false;try new WorkspaceSqliteStore(path,"workspace",seed,32,"/fixture") catch(_:Dynamic) rejected=true;
  require(rejected,"Future content extension was accepted");
  old=sqlitekit.Database.open(path,1000);old.exec("UPDATE workspace_agent_content_meta SET version=1 WHERE id=1");old.close();
  rejected=false;try new WorkspaceSqliteStore(path,"other",seed,32,"/fixture") catch(_:Dynamic) rejected=true;
  require(rejected,"Content database accepted another workspace identity");
  Sys.println("PASS: SQLite response archive reopen, scope, UTF-8, quotas, legacy deletion and versioned v8 extension");
 }
}
