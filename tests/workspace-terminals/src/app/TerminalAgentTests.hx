package app;

import testing.TestEndpoint;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.RpcTerminalBackend;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import terminalsession.TerminalSession;
import terminalkit.Emulator;
import workspace.runtime.AgentTerminalResume as Resume;

class TerminalAgentTests {
 static function agentEndpoint(root:String):TestEndpoint {
  var endpoint=new TestEndpoint();endpoint.root=root;endpoint.epoch="agent-terminal-test";
  return endpoint;
 }
 /**
  * A restart resumes the conversation the terminal's provider last reported into its log, else the one its record
  * keeps; with neither, a new one. Nothing is looked up in the providers' own files except whether Claude keeps a
  * record of the conversation (`--resume` needs one).
  */
 static function reportContract(root:String):Void {
  var directory=sys.FileSystem.fullPath(root)+"/cli-report";
  sys.FileSystem.createDirectory(directory);
  function record(provider:String,?session:String):TerminalRecord
   return {id:"report-"+provider,name:"Agent",group:"work",cwd:directory,instance:"i",state:"lost",exitCode:0,available:true,
    revision:haxe.Int64.ofInt(1),workspaceRoot:root,agentProvider:provider,agentSession:session};
  var identity=sys.FileSystem.fullPath(root)+"/identity/report";
  function log(line:Dynamic):Void sys.io.File.appendContent(identity+"/sessions.log",haxe.Json.stringify(line)+"\n");
  // Codex: no id before its first turn; a restart then begins a new conversation, with nothing guessed.
  var plan=Resume.plan(record("codex"),false,identity);
  require(plan.session==null && plan.arguments.length==2 && plan.arguments[0]=="-c" && StringTools.startsWith(plan.arguments[1],"notify=['"),
   "A Codex terminal was not started with its notify reporter: "+plan.arguments.join(" "));
  require(Resume.plan(record("codex"),true,identity).arguments.indexOf("resume")<0,"A Codex terminal with no reported turn resumed something");
  var thread="0199a5e1-7f42-7c3d-9b1a-aaaaaaaaaaaa";
  log({type:"agent-turn-complete","thread-id":thread,cwd:directory});
  plan=Resume.plan(record("codex"),true,identity);
  require(plan.session==thread && plan.arguments.slice(2).join(" ")=="resume "+thread,"A Codex terminal did not resume its reported thread: "+plan.arguments.join(" "));
  // Claude and Pi are given an id at the first start; a first start empties the log.
  plan=Resume.plan(record("claude"),false,identity);
  require(!sys.FileSystem.exists(identity+"/sessions.log"),"A first start kept an earlier terminal's reports");
  require(plan.arguments[0]=="--settings" && plan.arguments[2]=="--session-id" && plan.session==plan.arguments[3],
   "A Claude terminal was not started with its settings and an id: "+plan.arguments.join(" "));
  var settings=sys.io.File.getContent(plan.arguments[1]);
  require(settings.indexOf("SessionStart")>=0 && settings.indexOf("sessions.log")>=0,"The terminal's settings file has no SessionStart hook");
  var given=plan.session, cleared="22222222-2222-4222-a222-222222222222";
  // Claude keeps no record of a conversation with nothing said yet: it is begun again under its id.
  require(Resume.plan(record("claude",given),true,identity).arguments.slice(2).join(" ")=="--session-id "+given,
   "An empty Claude conversation was not begun again under its id");
  log({session_id:cleared,hook_event_name:"SessionStart",source:"clear"});
  var folder=root+"/claude-config/projects/"+~/[^A-Za-z0-9]/g.replace(directory,"-");
  mkdirs(folder);sys.io.File.saveContent(folder+"/"+cleared+".jsonl","{\"type\":\"user\"}\n");
  plan=Resume.plan(record("claude",given),true,identity);
  require(plan.session==cleared && plan.arguments.slice(2).join(" ")=="--resume "+cleared,
   "A Claude terminal did not follow its conversation past /clear: "+plan.arguments.join(" "));
  require(Resume.plan(record("claude",given),true,identity).session==cleared,"A second restart lost the reported conversation");
  plan=Resume.plan(record("pi"),false,identity);
  require(plan.arguments[0]=="--extension" && StringTools.endsWith(plan.arguments[1],"pi-identity.mjs") && plan.arguments[2]=="--session-id"
   && plan.session==plan.arguments[3],"A Pi terminal was not started with its extension and an id: "+plan.arguments.join(" "));
  var old="88888888-8888-4888-a888-888888888888";
  // An id a command line would change is never passed.
  log({session_id:"x\" & calc"});
  require(Resume.plan(record("pi",old),true,identity).session==old,"An unusable reported id was taken");
 }
 static function require(value:Bool,message:String):Void { if (!value) throw message; }
 /** Every missing folder of `path`, outermost first. */
 static function mkdirs(path:String):Void {
  var parent=haxe.io.Path.directory(path);
  if (parent!="" && parent!=path && !sys.FileSystem.exists(parent)) mkdirs(parent);
  if (!sys.FileSystem.exists(path)) sys.FileSystem.createDirectory(path);
 }
 static function screen(e:Emulator):String { e.snapshot();return [for (row in 0...e.rows()) e.rowText(row)].join("\n"); }
 /** The screen's rows joined without breaks: a line the terminal wrapped reads whole. */
 static function flat(e:Emulator):String { e.snapshot();return [for (row in 0...e.rows()) e.rowText(row)].join(""); }
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
  var oldClaude=Sys.getEnv("CLAUDE_CONFIG_DIR");
  Sys.putEnv("CLAUDE_CONFIG_DIR",root+"/claude-config");
  try {
   reportContract(root);
   for (provider in ["codex","claude","pi"]) providerContract(root,provider);
   failedStartRetry(root);
  } catch (failure:Dynamic) { Sys.putEnv("CLAUDE_CONFIG_DIR",oldClaude);throw failure; }
  Sys.putEnv("CLAUDE_CONFIG_DIR",oldClaude);
  Sys.println("PASS: global integrated/terminal preference; Claude, Codex and Pi terminals report their conversation through their own hook, notify program or extension, follow it past /clear or /new, resume it after a service restart, and continue it by themselves when an ended one is opened; a failed start's Retry shows the real cause and starts the CLI once it is there");
 }
 static function providerContract(root:String,provider:String):Void {
  var count=root+"/launch-count-"+provider, input=root+"/input-"+provider;
  var script=Sys.getEnv("FAKE_AGENT_CLI");
  require(script!=null && sys.FileSystem.exists(script),"FAKE_AGENT_CLI does not name tests/workspace-terminals/fake-agent-cli.py");
  var keys=["EXOSUIT_"+provider.toUpperCase()+"_BIN","EXOSUIT_"+provider.toUpperCase()+"_SCRIPT","FAKE_AGENT_PROVIDER","FAKE_AGENT_COUNT","FAKE_AGENT_INPUT"];
  var values=[Sys.systemName()=="Windows"?"python":"/usr/bin/python3",script,provider,count,input];
  var old=[for (key in keys) Sys.getEnv(key)];
  for (index in 0...keys.length) Sys.putEnv(keys[index],values[index]);
  function reset() for (index in 0...keys.length) Sys.putEnv(keys[index],old[index]);
  try runProvider(root,provider,count,input) catch (failure:Dynamic) { reset();throw failure; }
  reset();
 }
 /**
  * Workbench Q11: a terminal whose CLI is missing fails with the cause and Retry. Retry starts it again from its record:
  * while the CLI is still missing it fails with the same cause, and once the CLI is there it runs, in the same terminal.
  */
 static function failedStartRetry(root:String):Void {
  var script=Sys.getEnv("FAKE_AGENT_CLI");
  var keys=["EXOSUIT_PI_BIN","EXOSUIT_PI_SCRIPT","FAKE_AGENT_PROVIDER","FAKE_AGENT_COUNT","FAKE_AGENT_INPUT"];
  var old=[for (key in keys) Sys.getEnv(key)];
  function set(values:Array<Null<String>>) for (index in 0...keys.length) Sys.putEnv(keys[index],values[index]);
  set([sys.FileSystem.fullPath(root)+"/missing/pi.exe","","pi",root+"/launch-count-retry",root+"/input-retry"]);
  try {
   var directory=root+"/cli-retry";sys.FileSystem.createDirectory(directory);directory=sys.FileSystem.fullPath(directory);
   var seed:WorkspaceSnapshot={epoch:"agent-retry",cursor:0,groups:[{id:"work",name:"Work",cwd:directory,revision:1}]};
   var store=new WorkspaceSqliteStore(root+"/agent-retry.sqlite","workspace",seed);
   var manager=TestTerminals.manager("workspace","first",root,65536,store,function() return seed.groups,"agents-retry");
   var endpoint=agentEndpoint(root);
   var pair=MemoryTransport.pair(),clock=function() return Sys.time()*1000;
   endpoint.connection=new RpcConnection(pair.client,clock);endpoint.generation="first";
   var server=new RpcConnection(pair.server,clock);
   manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG,WorkspaceProtocol.TREE]);
   var backend=new RpcTerminalBackend(function() return endpoint,"retry-agent",root,true,"work");backend.configureAgent("pi");
   var session=new TerminalSession(backend,Emulator.open(80,24),false);
   // A failure is thrown from the poll that reports it, once; the view keeps it on its strip.
   var step=function() { endpoint.connection.poll();server.poll();manager.poll();endpoint.connection.poll();try session.pollEvents() catch (_:Dynamic) {} };
   var until=function(check:Void->Bool,message:String) {
    var deadline=Sys.time()+15;while (!check()) { require(Sys.time()<deadline,message+": "+backend.controlStatus());step();Sys.sleep(0.005); }
   };
   var cause="Terminal unavailable: Terminal creation failed: The pi CLI was not found on the workspace host PATH";
   until(function() return backend.controlAction()=="Retry","A start whose CLI is missing offered no Retry");
   require(backend.controlStatus()==cause,"A failed start did not show its cause: "+backend.controlStatus());
   backend.activateControl();
   until(function() return backend.controlAction()=="Retry","A Retry whose CLI is still missing did not fail again");
   require(backend.controlStatus()==cause,"A failed Retry did not show the real cause: "+backend.controlStatus());
   set([Sys.systemName()=="Windows"?"python":"/usr/bin/python3",script,"pi",root+"/launch-count-retry",root+"/input-retry"]);
   backend.activateControl();
   until(function() return backend.isSynchronized() && session.status=="running" && screen(session.emulator).indexOf("TUI_pi:")>=0,
    "Retry did not start the CLI once it was there");
   require(manager.snapshot().terminals.length==1,"Retry made a second terminal");
   session.write(TestShell.line("exit"));until(function() return session.status=="exited","The retried CLI did not exit");
   session.close();endpoint.connection.close();server.close();manager.dispose();store.close();
  } catch (failure:Dynamic) { set(old);throw failure; }
  set(old);
 }
 static function runProvider(root:String,provider:String,countPath:String,inputPath:String):Void {
  var directory=root+"/cli-"+provider;sys.FileSystem.createDirectory(directory);directory=sys.FileSystem.fullPath(directory);
  var seed:WorkspaceSnapshot={epoch:"agent-terminal",cursor:0,groups:[{id:"work",name:"Work",cwd:directory,revision:1}]};
  var path=root+"/agent-terminal-"+provider+".sqlite";
  var store=new WorkspaceSqliteStore(path,"workspace",seed);
  var manager=TestTerminals.manager("workspace","first",root,16777216,store,function() return seed.groups,"agents-"+provider);
  require(manager.snapshot().agentProviders.indexOf(provider)>=0,"Daemon omitted interactive agent support");
  var endpoint=agentEndpoint(root), server:RpcConnection=null;
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
  var session=new TerminalSession(backend,Emulator.open(200,30),false);
  var step=function() { endpoint.connection.poll();server.poll();manager.poll();endpoint.connection.poll();session.pollEvents(); };
  var until=function(check:Void->Bool,message:String) {
   var deadline=Sys.time()+15;while (!check()) { require(Sys.time()<deadline,message+"\n"+screen(session.emulator));step();Sys.sleep(0.005); }
  };
  // The reporting arguments come first: Claude `--settings <file>`, Codex `-c notify=[...]`, Pi `--extension <file>`;
  // Claude and Pi then get the conversation id they begin.
  var argc=provider=="codex" ? 3 : 5;
  until(function() return backend.isSynchronized() && screen(session.emulator).indexOf("TUI_"+provider+":"+argc+":"+directory)>=0,"Provider did not start directly in the group's directory");
  require(manager.snapshot().terminals[0].agentProvider==provider && manager.activeCount()==1,"Interactive agent identity was not recorded");
  var conversation=manager.snapshot().terminals[0].agentSession;
  if (provider=="codex") require(conversation==null,"A Codex terminal was given a conversation id at its first start");
  else {
   require(conversation!=null,"A "+provider+" terminal was not given a conversation id");
   until(function() return flat(session.emulator).indexOf("--session-id "+conversation+"]")>=0,"A "+provider+" terminal was not begun under its recorded id");
   until(function() return flat(session.emulator).indexOf("REPORTED:"+conversation)>=0,"A "+provider+" terminal did not report its conversation at startup");
  }
  var rejected=false;try backend.configureAgent("claude") catch (_:Dynamic) rejected=true;
  require(rejected,"Existing terminal mode changed after attachment");
  session.write(TestShell.line("hello"));until(function() return screen(session.emulator).indexOf("RECEIVED:hello")>=0,"Interactive agent did not receive terminal input");
  // A turn (Codex reports its thread after one), then a new conversation in the same program (`/clear`, `/new`).
  session.write(TestShell.line("turn"));
  if (provider=="codex") until(function() return flat(session.emulator).indexOf("REPORTED:")>=0,"Codex did not report its thread after a turn");
  session.write(TestShell.line("switch"));
  until(function() {
   var reported=~/REPORTED:([0-9a-f-]{36})/;
   var text=flat(session.emulator), last:Null<String>=null, seen=0;
   while (reported.match(text)) { last=reported.matched(1);seen++;text=reported.matchedRight(); }
   if (seen<2) return false;
   conversation=last;return true;
  },"The "+provider+" terminal did not report its new conversation");
  session.close();connect("first");
  backend=new RpcTerminalBackend(function() return endpoint,"interactive-agent",root,false);
  session=new TerminalSession(backend,Emulator.open(200,30),false);
  until(function() return backend.isSynchronized(),"Interactive agent did not reconnect");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==1,"View reconnection restarted the CLI");
  session.write(TestShell.line("exit"));until(function() return session.status=="exited","Interactive CLI did not exit");
  require(backend.controlAction()=="Restart Terminal","CLI session offered a shell replacement");
  manager.dispose();store.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed);
  manager=TestTerminals.manager("workspace","second",root,16777216,store,function() return seed.groups,"agents-"+provider);
  require(manager.snapshot().terminals[0].agentProvider==provider,"Daemon restart lost provider identity");
  connect("second");
  step(); // Observe the new endpoint before checking the previous session's state.
  // A view that was open when the program ended does not start it again by itself.
  until(function() return backend.isSynchronized() && session.status=="exited","Archived CLI did not recover");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==0,"A view open when the CLI ended started it again");
  session.close();
  // Opening the ended terminal continues its conversation in the same terminal, and sends nothing.
  var expected=switch (provider) {
   case "claude":
    var folder=root+"/claude-config/projects/"+~/[^A-Za-z0-9]/g.replace(directory,"-");
    mkdirs(folder);sys.io.File.saveContent(folder+"/"+conversation+".jsonl","{\"type\":\"user\"}\n");
    "--resume "+conversation+"]";
   case "codex": "resume "+conversation+"]";
   default: "--session-id "+conversation+"]";
  }
  var sent=sys.io.File.getContent(inputPath);
  backend=new RpcTerminalBackend(function() return endpoint,"interactive-agent",root,false);
  session=new TerminalSession(backend,Emulator.open(200,30),false);
  until(function() return sys.io.File.getContent(countPath)=="2" && session.status=="running","Opening the ended CLI did not continue it");
  require(manager.snapshot().terminals[0].agentProvider==provider,"Restart changed the provider");
  until(function() return flat(session.emulator).indexOf(expected)>=0,"Opening did not continue the provider conversation ("+expected+")");
  require(manager.snapshot().terminals[0].agentSession==conversation,"Restart did not keep the conversation id");
  require(sys.io.File.getContent(inputPath)==sent,"Continuing the conversation sent text");
  session.write(TestShell.line("exit"));until(function() return session.status=="exited","Continued CLI did not exit");
  session.close();endpoint.connection.close();server.close();manager.dispose();store.close();
 }
}
