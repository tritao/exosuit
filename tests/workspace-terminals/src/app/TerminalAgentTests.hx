package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.RpcTerminalBackend;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import terminalsession.TerminalSession;
import terminalkit.Emulator;
import workspace.runtime.AgentTerminalResume as Resume;

private class AgentTerminalEndpoint implements WorkspaceRpcEndpoint {
 public var connection:RpcConnection;
 public var generation:String;
 final root:String;
 var router:workspace.client.WorkspaceTerminalEvents;
 public function new(root:String) this.root=root;
 public function rootPath():Null<String> return root;
 public function serviceGeneration():String return generation;
 public function workspaceEpoch():Null<String> return "agent-terminal-test";
 public function rpcConnection():Null<RpcConnection> return connection;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function hasCapability(capability:String):Bool return true;
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> {
  if (router==null || router.connection!=connection) router=new workspace.client.WorkspaceTerminalEvents(connection);
  return router;
 }
}

class TerminalAgentTests {
 /** Terminals saved before conversation ids were kept: the provider's own list of the folder's conversations opens. */
 static function legacyContract(root:String):Void {
  var directory=sys.FileSystem.fullPath(root+"/cli-claude");
  var record:TerminalRecord={id:"legacy",name:"Claude Code",group:"work",cwd:directory,instance:"i",state:"lost",exitCode:0,available:true,
   revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"claude"};
  var plan=workspace.runtime.AgentTerminalResume.plan(record,true,[]);
  require(plan.arguments.join(" ")=="--resume" && plan.session==null,"A Claude terminal with no saved id did not offer its folder's conversations");
  record.cwd=root;
  plan=workspace.runtime.AgentTerminalResume.plan(record,true,[]);
  require(plan.arguments[0]=="--session-id" && plan.session!=null,"A Claude terminal in a folder with no conversation was not given an id");
  record.agentProvider="codex";record.cwd=directory;
  plan=workspace.runtime.AgentTerminalResume.plan(record,true,[]);
  require(plan.arguments.join(" ")=="resume","A Codex terminal with no saved start did not offer its conversations");
  record.agentStarted=Std.int(Date.now().getTime()/1000)+3600;
  plan=workspace.runtime.AgentTerminalResume.plan(record,true,[]);
  require(plan.arguments.length==0,"A Codex terminal took a conversation begun before it");
 }
 /**
  * A restart resumes only a conversation that is provably the terminal's. Its Claude reports each conversation it goes
  * on with (a SessionStart hook in the terminal's own settings file): after `/clear` the reported one is resumed, and a
  * conversation someone else began in the same folder later is not. Without a report, a later conversation of the
  * folder makes the restart open Claude's list instead of guessing.
  */
 static function identityContract(root:String):Void {
  var directory=sys.FileSystem.fullPath(root)+"/cli-cleared";
  sys.FileSystem.createDirectory(directory);
  var folder=root+"/claude-config/projects/"+~/[^A-Za-z0-9]/g.replace(directory,"-");
  sys.FileSystem.createDirectory(folder);
  var now=Std.int(Date.now().getTime()/1000);
  function stamp(t:Int):String { var c=Resume.calendar(t);return c.year+"-"+Resume.pad(c.month)+"-"+Resume.pad(c.day)+"T"+Resume.pad(c.hour)+":"+Resume.pad(c.minute)+":"+Resume.pad(c.second)+".000Z"; }
  function transcript(id:String,begun:Int,cwd:String):Void
   sys.io.File.saveContent(folder+"/"+id+".jsonl",haxe.Json.stringify({type:"user",sessionId:id,cwd:cwd,timestamp:stamp(begun)})+"\n{\"type\":\"assistant\"}\n");
  var first="11111111-1111-4111-a111-111111111111", cleared="22222222-2222-4222-a222-222222222222",
   foreign="33333333-3333-4333-a333-333333333333", chat="44444444-4444-4444-a444-444444444444";
  transcript(first,now-120,directory);
  var record:TerminalRecord={id:"cleared",name:"Claude Code",group:"work",cwd:directory,instance:"i",state:"lost",exitCode:0,available:true,
   revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"claude",agentSession:first,agentStarted:now-120};
  // Without a report: the recorded conversation while nothing else of the folder was written since.
  var plan=Resume.plan(record,true,[]);
  require(plan.arguments.join(" ")=="--resume "+first,"A Claude terminal did not resume its own conversation: "+plan.arguments.join(" "));
  // Someone else's conversation in the same folder, begun after the terminal's was last written (Claude in a plain
  // shell, outside Exosuit): never resumed by its folder and time.
  Sys.sleep(1.1);
  transcript(foreign,now+1,directory);
  plan=Resume.plan(record,true,[]);
  require(plan.arguments.join(" ")=="--resume" && plan.session==null,"A Claude terminal took a foreign conversation of its folder: "+plan.arguments.join(" "));
  // A chat session's conversation is not a terminal's either: kept elsewhere, it does not make the restart ask.
  require(Resume.plan(record,true,[foreign]).arguments.join(" ")=="--resume "+first,"A conversation kept elsewhere made the restart ask");

  // With the hook: the terminal's own settings file is passed and its log decides.
  var identity=sys.FileSystem.fullPath(root)+"/identity/cleared";
  plan=Resume.plan(record,false,[],identity);
  require(plan.arguments.length==4 && plan.arguments[0]=="--settings" && plan.session==first,
   "A Claude terminal was not started with its own settings: "+plan.arguments.join(" "));
  var settings=sys.io.File.getContent(plan.arguments[1]);
  require(settings.indexOf("SessionStart")>=0 && settings.indexOf("sessions.log")>=0,"The terminal's settings file has no SessionStart hook");
  var log=identity+"/sessions.log";
  function report(id:String,source:String):Void {
   sys.io.File.appendContent(log,haxe.Json.stringify({session_id:id,transcript_path:folder+"/"+id+".jsonl",cwd:directory,hook_event_name:"SessionStart",source:source})+"\n");
  }
  report(first,"startup");
  plan=Resume.plan(record,true,[],identity);
  require(plan.arguments.join(" ")=="--settings "+plan.arguments[1]+" --resume "+first,"A reported conversation was not resumed past a foreign one: "+plan.arguments.join(" "));
  // `/clear`: the terminal's Claude reports the new conversation; that one is followed, not the foreign one.
  transcript(cleared,now+2,directory);
  report(cleared,"clear");
  plan=Resume.plan(record,true,[],identity);
  require(plan.arguments[2]+" "+plan.arguments[3]=="--resume "+cleared && plan.session==cleared,"A Claude terminal did not follow its conversation past /clear: "+plan.arguments.join(" "));
  // A restart keeps the log: the report stays the terminal's.
  require(Resume.plan(record,true,[],identity).session==cleared,"A second restart lost the reported conversation");
  // A reported id another terminal or a chat session keeps is not taken.
  report(chat,"resume");
  require(Resume.plan(record,true,[chat],identity).session!=chat,"A reported conversation kept elsewhere was resumed");
  // A first start empties the log: its conversation is the one it is given.
  Resume.plan(record,false,[],identity);
  require(!sys.FileSystem.exists(log),"A first start kept an earlier terminal's reports");

  // Codex and Pi: only the one record that can be the terminal's is taken while it runs; at a restart the list opens.
  var codexFolder=sys.FileSystem.fullPath(root)+"/cli-codex-two";
  sys.FileSystem.createDirectory(codexFolder);
  var t=Resume.calendar(now);
  var day=root+"/codex-home/sessions/"+t.year+"/"+Resume.pad(t.month)+"/"+Resume.pad(t.day);
  mkdirs(day);
  function rollout(id:String):Void {
   var name=t.year+"-"+Resume.pad(t.month)+"-"+Resume.pad(t.day)+"T"+Resume.pad(t.hour)+"-"+Resume.pad(t.minute)+"-"+Resume.pad(t.second);
   sys.io.File.saveContent(day+"/rollout-"+name+"-"+id+".jsonl",haxe.Json.stringify({timestamp:"x",type:"session_meta",
    payload:{id:id,cwd:codexFolder,originator:"codex-tui",timestamp:stamp(now)}})+"\n{}\n");
  }
  var codex:TerminalRecord={id:"codex-two",name:"Codex",group:"work",cwd:codexFolder,instance:"i",state:"lost",exitCode:0,available:true,
   revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"codex",agentStarted:now-60};
  require(Resume.resolve(codex,[])==null,"A Codex terminal took a conversation when there was none");
  var one="0199a5e1-7f42-7c3d-9b1a-aaaaaaaaaaaa", two="0199a5e1-7f42-7c3d-9b1a-bbbbbbbbbbbb";
  rollout(one);
  require(Resume.resolve(codex,[])==one,"A Codex terminal did not take the one conversation of its folder");
  rollout(two);
  require(Resume.resolve(codex,[])==null,"A Codex terminal guessed between two conversations of its folder");
  require(Resume.resolve(codex,[one])==two,"A Codex terminal did not take the one conversation left");
  plan=Resume.plan(codex,true,[]);
  require(plan.arguments.join(" ")=="resume" && plan.session==null,"An unresolved Codex terminal guessed at restart: "+plan.arguments.join(" "));
 }
 /** A record line as Codex writes it first: `session_meta` with the conversation id, folder and UTC start. */
 static function codexMetaLine(id:String,cwd:String,time:String):String
  return haxe.Json.stringify({timestamp:time,type:"session_meta",payload:{id:id,cwd:cwd,originator:"codex-tui",timestamp:time}});
 /**
  * Codex and Pi records begun at 2026-09-08 08:09:09 (month, day, hour, minute and second 08 or 09), found through the
  * real files by `resolve` for a terminal started 4 s before. The files are written now, so their mtimes pass the
  * `modified >= started - 2` test; the times in the names and records decide.
  */
 static function timeFieldsContract(root:String):Void {
  var started=Resume.seconds(2026,9,8,8,9,5), time="2026-09-08T08:09:09.000Z";
  var codexFolder=sys.FileSystem.fullPath(root)+"/cli-codex-0809";
  sys.FileSystem.createDirectory(codexFolder);
  var day=root+"/codex-home/sessions/2026/09/08";
  mkdirs(day);
  var id="0199a5e1-7f42-7c3d-9b1a-080908090809";
  sys.io.File.saveContent(day+"/rollout-2026-09-08T08-09-09-"+id+".jsonl",codexMetaLine(id,codexFolder,time)+"\n{}\n");
  var codex:TerminalRecord={id:"codex-0809",name:"Codex",group:"work",cwd:codexFolder,instance:"i",state:"running",exitCode:0,available:true,
   revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"codex",agentStarted:started};
  require(Resume.resolve(codex,[])==id,"A Codex terminal did not take its conversation begun at 08:09:09 on 09-08");
  var piFolder=sys.FileSystem.fullPath(root)+"/cli-pi-0809";
  sys.FileSystem.createDirectory(piFolder);
  var sessions=Resume.piSessionFolder(piFolder);
  mkdirs(sessions);
  var piId="88888888-8888-4888-a888-888888888888";
  var file=haxe.io.Path.join([sessions,"2026-09-08T08-09-09-000Z_"+piId+".jsonl"]);
  sys.io.File.saveContent(file,haxe.Json.stringify({type:"session",version:3,id:piId,timestamp:time,cwd:piFolder})+"\n");
  var pi:TerminalRecord={id:"pi-0809",name:"Pi",group:"work",cwd:piFolder,instance:"i",state:"running",exitCode:0,available:true,
   revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"pi",agentStarted:started};
  require(Resume.resolve(pi,[])==file,"A Pi terminal did not take its session begun at 08:09:09 on 09-08: "+Resume.resolve(pi,[]));
 }
 /**
  * The scan reads a session file's first line once and keeps it per path; a line that does not parse yet is read again.
  * A record's first line never changes once written, so the only way to observe the cache is to change it in place:
  * a scan that still answers with the old id did not read the file again.
  */
 static function headCacheContract(root:String):Void {
  var started=Resume.seconds(2026,9,8,8,9,5), time="2026-09-08T08:09:09.000Z";
  var day=root+"/codex-home/sessions/2026/09/08";
  mkdirs(day);
  function terminal(id:String,cwd:String):TerminalRecord
   return {id:id,name:"Codex",group:"work",cwd:cwd,instance:"i",state:"running",exitCode:0,available:true,
    revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:"codex",agentStarted:started};
  // Read once: the same path with a different first line still gives the id first read.
  var kept=sys.FileSystem.fullPath(root)+"/cli-codex-kept";
  sys.FileSystem.createDirectory(kept);
  var first="0199a5e1-7f42-7c3d-9b1a-cccccccccccc", second="0199a5e1-7f42-7c3d-9b1a-dddddddddddd";
  var path=day+"/rollout-2026-09-08T08-09-09-"+first+".jsonl";
  sys.io.File.saveContent(path,codexMetaLine(first,kept,time)+"\n{}\n");
  require(Resume.resolve(terminal("codex-kept",kept),[])==first,"A Codex terminal did not take the conversation of its file");
  sys.io.File.saveContent(path,codexMetaLine(second,kept,time)+"\n{}\n");
  require(Resume.resolve(terminal("codex-kept",kept),[])==first,"A session file's first line was read again");
  // A first line still being written does not parse and is not kept: once complete, the file is found.
  var partial=sys.FileSystem.fullPath(root)+"/cli-codex-partial";
  sys.FileSystem.createDirectory(partial);
  var third="0199a5e1-7f42-7c3d-9b1a-eeeeeeeeeeee", line=codexMetaLine(third,partial,time);
  path=day+"/rollout-2026-09-08T08-09-09-"+third+".jsonl";
  sys.io.File.saveContent(path,line.substr(0,line.length-20));
  require(Resume.resolve(terminal("codex-partial",partial),[])==null,"A half-written first line was taken");
  sys.io.File.saveContent(path,line+"\n");
  require(Resume.resolve(terminal("codex-partial",partial),[])==third,"A first line read half-written was kept and the complete one not read");
 }
 static function require(value:Bool,message:String):Void { if (!value) throw message; }
 /** Every missing folder of `path`, outermost first. */
 static function mkdirs(path:String):Void {
  var parent=haxe.io.Path.directory(path);
  if (parent!="" && parent!=path && !sys.FileSystem.exists(parent)) mkdirs(parent);
  if (!sys.FileSystem.exists(path)) sys.FileSystem.createDirectory(path);
 }
 static function screen(e:Emulator):String { e.snapshot();return [for (row in 0...e.rows()) e.rowText(row)].join("\n"); }
 public static function run(root:String):Void {
  var settingsPath=root+"/agent-mode-settings.json";
  var preferences=new config.Preferences(settingsPath);
  require(preferences.current.agentSessionMode=="terminal","New sessions did not default to terminal mode");
  require(preferences.store.set("workbench/agents/session_mode",haxeon.ui.properties.PropertyValue.Enum("integrated"))==null,"Integrated mode was rejected");
  require(new config.Preferences(settingsPath).current.agentSessionMode=="integrated","Explicit integrated mode did not persist");
  require(preferences.store.set("workbench/agents/session_mode",haxeon.ui.properties.PropertyValue.Enum("terminal"))==null,"Global agent mode was rejected");
  require(preferences.current.agentSessionMode=="terminal" && preferences.current.copy().agentSessionMode=="terminal","Agent mode was not applied/copied");
  var restored=new config.Preferences(settingsPath);
  require(restored.current.agentSessionMode=="terminal","Agent mode did not persist");
  require(restored.store.set("workbench/agents/session_mode",haxeon.ui.properties.PropertyValue.Enum("invalid"))!=null && restored.current.agentSessionMode=="terminal","Invalid agent mode changed saved preference");
  restored.store.set("workbench/agents/session_mode",haxeon.ui.properties.PropertyValue.Enum("integrated"));
  var project=restored.forProject(root+"/project-agent-mode.json");
  require(project.current.agentSessionMode=="integrated" && !project.registry.exists("workbench/agents/session_mode"),"Agent mode was not a single global default");
  // Std.parseInt reads "09" as octal (0): a provider record begun in such a minute was not taken.
  require(Resume.utc("2026-09-08T08:09:09.000Z")==Resume.seconds(2026,9,8,8,9,9),"A provider record's time was misread");
  var oldClaude=Sys.getEnv("CLAUDE_CONFIG_DIR"), oldCodex=Sys.getEnv("CODEX_HOME"), oldPi=Sys.getEnv("PI_CODING_AGENT_DIR");
  Sys.putEnv("CLAUDE_CONFIG_DIR",root+"/claude-config");Sys.putEnv("CODEX_HOME",root+"/codex-home");Sys.putEnv("PI_CODING_AGENT_DIR",root+"/pi-agent");
  try {
   timeFieldsContract(root);
   headCacheContract(root);
   for (provider in ["codex","claude","pi"]) providerContract(root,provider);
   legacyContract(root);
   identityContract(root);
  } catch (failure:Dynamic) { Sys.putEnv("CLAUDE_CONFIG_DIR",oldClaude);Sys.putEnv("CODEX_HOME",oldCodex);Sys.putEnv("PI_CODING_AGENT_DIR",oldPi);throw failure; }
  Sys.putEnv("CLAUDE_CONFIG_DIR",oldClaude);Sys.putEnv("CODEX_HOME",oldCodex);Sys.putEnv("PI_CODING_AGENT_DIR",oldPi);
  Sys.println("PASS: global integrated/terminal preference; provider CLI PTYs, detach, durable identity and provider-preserving restart; Claude and Codex terminals resume their conversation after a stop, a Claude terminal follows its conversation past /clear by its own report and never takes a foreign one of its folder; a Pi terminal resumes its session file");
 }
 static function providerContract(root:String,provider:String):Void {
  var script=root+"/fake-interactive-"+provider+".py", count=root+"/launch-count-"+provider;
  sys.io.File.saveContent(script,"import os,sys,pathlib\np=pathlib.Path("+haxe.Json.stringify(count)+")\np.write_text(str(int(p.read_text())+1) if p.exists() else '1')\nprint('TUI_"+provider+":'+str(len(sys.argv))+':'+os.getcwd(),flush=True)\nprint('ARGS:['+' '.join(sys.argv[1:])+']',flush=True)\nfor line in sys.stdin:\n if line.strip()=='exit': break\n print('RECEIVED:'+line.strip(),flush=True)\n");
  var binaryKey="EXOSUIT_"+provider.toUpperCase()+"_BIN", scriptKey="EXOSUIT_"+provider.toUpperCase()+"_SCRIPT";
  var oldBinary=Sys.getEnv(binaryKey), oldScript=Sys.getEnv(scriptKey);
  Sys.putEnv(binaryKey,Sys.systemName()=="Windows"?"python":"/usr/bin/python3");Sys.putEnv(scriptKey,script);
  try runProvider(root,provider,count) catch (failure:Dynamic) {
   Sys.putEnv(binaryKey,oldBinary);Sys.putEnv(scriptKey,oldScript);throw failure;
  }
  Sys.putEnv(binaryKey,oldBinary);Sys.putEnv(scriptKey,oldScript);
 }
 static function runProvider(root:String,provider:String,countPath:String):Void {
  var directory=root+"/cli-"+provider;sys.FileSystem.createDirectory(directory);directory=sys.FileSystem.fullPath(directory);
  var seed:WorkspaceSnapshot={epoch:"agent-terminal",cursor:0,groups:[{id:"work",name:"Work",cwd:directory,revision:1}]};
  var path=root+"/agent-terminal-"+provider+".sqlite";
  var store=new WorkspaceSqliteStore(path,"workspace",seed);
  var manager=new WorkspaceTerminalManager("workspace","first",root,16777216,store,function() return seed.groups);
  require(manager.snapshot().agentProviders.indexOf(provider)>=0,"Daemon omitted interactive agent support");
  var endpoint=new AgentTerminalEndpoint(root), server:RpcConnection=null;
  var connect=function(generation:String) {
   if (endpoint.connection!=null) endpoint.connection.close();if (server!=null) server.close();
   var pair=MemoryTransport.pair(),clock=function() return Sys.time()*1000;
   endpoint.connection=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);endpoint.generation=generation;
   manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG,WorkspaceProtocol.TREE]);
  };
  connect("first");
  var invalidDone=false, invalidCode="";
  endpoint.connection.call(WorkspaceTerminalProtocol.OPEN,{workspace:"workspace",instance:"first",id:"invalid-agent",create:true,
   columns:80,rows:24,agentProvider:"codex; echo injected"},1000,function(_) invalidDone=true,function(error) { invalidCode=error.code;invalidDone=true; });
  for (_ in 0...10) { endpoint.connection.poll();server.poll(); }
  require(invalidDone && invalidCode=="invalid_request" && manager.snapshot().terminals.length==0 && manager.activeCount()==0,
   "Unsupported CLI command reached terminal creation");
  var backend=new RpcTerminalBackend(function() return endpoint,"interactive-agent",root,true,"work");backend.configureAgent(provider);
  var session=new TerminalSession(backend,Emulator.open(120,24),false);
  var step=function() { endpoint.connection.poll();server.poll();manager.poll();endpoint.connection.poll();session.pollEvents(); };
  var until=function(check:Void->Bool,message:String) {
   var deadline=Sys.time()+8;while (!check()) { require(Sys.time()<deadline,message+"\n"+screen(session.emulator));step();Sys.sleep(0.005); }
  };
  var argc=provider=="claude" ? 3 : 1;
  until(function() return backend.isSynchronized() && screen(session.emulator).indexOf("TUI_"+provider+":"+argc+":"+directory)>=0,"Provider did not start directly in the group's directory");
  require(manager.snapshot().terminals[0].agentProvider==provider && manager.activeCount()==1,"Interactive agent identity was not recorded");
  var conversation=manager.snapshot().terminals[0].agentSession;
  // The fake prints its arguments on the line after the one waited for above.
  if (provider=="claude") {
   require(conversation!=null,"Claude terminal was not given a conversation id");
   until(function() return screen(session.emulator).indexOf("ARGS:[--session-id "+conversation+"]")>=0,"Claude terminal was not begun under its recorded conversation id");
  } else {
   require(conversation==null,"A "+provider+" terminal was given a conversation id at its first start");
   until(function() return screen(session.emulator).indexOf("ARGS:[]")>=0,"A "+provider+" terminal got arguments at its first start");
  }
  require(manager.snapshot().terminals[0].agentStarted!=null,"The start of the provider conversation was not recorded");
  // Codex and Pi write their record once the conversation begins (written here as they would): the service keeps it
  // while the terminal runs.
  if (provider=="codex") {
   // A local time zone is not known here; the record's UTC time decides, the name only has to be within a day.
   var t=Resume.calendar(Std.int(Date.now().getTime()/1000)), id="0199a5e1-7f42-7c3d-9b1a-"+StringTools.hex(Std.random(0xffffff),6)+"000000";
   var folder=root+"/codex-home/sessions/"+t.year+"/"+Resume.pad(t.month)+"/"+Resume.pad(t.day);
   mkdirs(folder);
   var stamp=t.year+"-"+Resume.pad(t.month)+"-"+Resume.pad(t.day)+"T"+Resume.pad(t.hour)+"-"+Resume.pad(t.minute)+"-"+Resume.pad(t.second);
   sys.io.File.saveContent(folder+"/rollout-"+stamp+"-"+id+".jsonl",haxe.Json.stringify({timestamp:"x",type:"session_meta",
    payload:{id:id,cwd:directory,originator:"codex-tui",timestamp:stamp.substr(0,11)+StringTools.replace(stamp.substr(11),"-",":")+".000Z"}})+"\n{}\n");
   conversation=id;
  } else if (provider=="pi") {
   var folder=Resume.piSessionFolder(directory);
   var parts=haxe.io.Path.normalize(folder).split("/"), made="";
   for (part in parts) { made=made==""?part:made+"/"+part; if (made.length>2 && !sys.FileSystem.exists(made)) sys.FileSystem.createDirectory(made); }
   var t=Resume.calendar(Std.int(Date.now().getTime()/1000)+1);
   var stamp=t.year+"-"+Resume.pad(t.month)+"-"+Resume.pad(t.day)+"T"+Resume.pad(t.hour)+":"+Resume.pad(t.minute)+":"+Resume.pad(t.second)+".000Z";
   var file=haxe.io.Path.join([folder,StringTools.replace(StringTools.replace(stamp,":","-"),".","-")+"_77777777-7777-4777-a777-777777777777.jsonl"]);
   sys.io.File.saveContent(file,haxe.Json.stringify({type:"session",version:3,id:"77777777-7777-4777-a777-777777777777",timestamp:stamp,cwd:directory})+"\n");
   conversation=file;
  }
  if (provider!="claude") until(function() return manager.snapshot().terminals[0].agentSession==conversation,"A running "+provider+" terminal did not keep its conversation");
  var rejected=false;try backend.configureAgent("claude") catch (_:Dynamic) rejected=true;
  require(rejected,"Existing terminal mode changed after attachment");
  session.write(TestShell.line("hello"));until(function() return screen(session.emulator).indexOf("RECEIVED:hello")>=0,"Interactive agent did not receive terminal input");
  session.close();connect("first");
  backend=new RpcTerminalBackend(function() return endpoint,"interactive-agent",root,false);
  session=new TerminalSession(backend,Emulator.open(120,24),false);
  until(function() return backend.isSynchronized(),"Interactive agent did not reconnect");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==1,"View reconnection restarted the CLI");
  session.write(TestShell.line("exit"));until(function() return session.status=="exited","Interactive CLI did not exit");
  require(backend.controlAction()=="Restart Terminal","CLI session offered a shell replacement");
  manager.dispose();store.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed);
  manager=new WorkspaceTerminalManager("workspace","second",root,16777216,store,function() return seed.groups);
  require(manager.snapshot().terminals[0].agentProvider==provider,"Daemon restart lost provider identity");
  connect("second");
  step(); // Observe the new endpoint before checking the previous session's state.
  until(function() return backend.isSynchronized() && session.status=="exited","Archived CLI did not recover");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==0,"Opening saved CLI history spawned a new process");
  require(manager.snapshot().terminals[0].agentSession==conversation,"The provider conversation id did not survive a service restart");
  // The provider keeps its record of the conversation (written here as the provider would): a restart resumes it.
  var expected="ARGS:[]";
  if (provider=="claude") {
   var folder=root+"/claude-config/projects/"+~/[^A-Za-z0-9]/g.replace(directory,"-");
   mkdirs(folder);sys.io.File.saveContent(folder+"/"+conversation+".jsonl","{\"type\":\"user\"}\n");
   expected="ARGS:[--resume "+conversation+"]";
  } else if (provider=="codex") {
   expected="ARGS:[resume "+conversation+"]";
  } else if (provider=="pi") {
   // The path wraps on the 80-column screen: the screen shows the flag, the record the path.
   expected="ARGS:[--session ";
  }
  backend.activateControl();until(function() return backend.canControl() && session.status=="running","Explicit CLI restart failed");
  until(function() return sys.io.File.getContent(countPath)=="2","Restart did not launch the original provider");
  require(manager.snapshot().terminals[0].agentProvider==provider,"Restart changed the provider");
  until(function() return screen(session.emulator).indexOf(expected)>=0,"Restart did not continue the provider conversation ("+expected+")");
  require(manager.snapshot().terminals[0].agentSession==conversation,"Restart did not keep the conversation id");
  session.close();endpoint.connection.close();server.close();manager.dispose();store.close();
 }
}
