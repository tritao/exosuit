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
 static function require(value:Bool,message:String):Void { if (!value) throw message; }
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
  if (Sys.systemName()=="Windows") return; // Native process integration below uses the fixture's POSIX Python.
  for (provider in ["codex","claude","pi"]) providerContract(root,provider);
  Sys.println("PASS: global integrated/terminal preference; provider CLI PTYs, detach, durable identity and provider-preserving restart");
 }
 static function providerContract(root:String,provider:String):Void {
  var script=root+"/fake-interactive-"+provider+".py", count=root+"/launch-count-"+provider;
  sys.io.File.saveContent(script,"import os,sys,pathlib\np=pathlib.Path("+haxe.Json.stringify(count)+")\np.write_text(str(int(p.read_text())+1) if p.exists() else '1')\nprint('TUI_"+provider+":'+str(len(sys.argv))+':'+os.getcwd(),flush=True)\nfor line in sys.stdin:\n if line.strip()=='exit': break\n print('RECEIVED:'+line.strip(),flush=True)\n");
  var binaryKey="EXOSUIT_"+provider.toUpperCase()+"_BIN", scriptKey="EXOSUIT_"+provider.toUpperCase()+"_SCRIPT";
  var oldBinary=Sys.getEnv(binaryKey), oldScript=Sys.getEnv(scriptKey);
  Sys.putEnv(binaryKey,"/usr/bin/python3");Sys.putEnv(scriptKey,script);
  try runProvider(root,provider,count) catch (failure:Dynamic) {
   Sys.putEnv(binaryKey,oldBinary);Sys.putEnv(scriptKey,oldScript);throw failure;
  }
  Sys.putEnv(binaryKey,oldBinary);Sys.putEnv(scriptKey,oldScript);
 }
 static function runProvider(root:String,provider:String,countPath:String):Void {
  var directory=root+"/cli-"+provider;sys.FileSystem.createDirectory(directory);
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
  until(function() return backend.isSynchronized() && screen(session.emulator).indexOf("TUI_"+provider+":1:"+directory)>=0,"Provider did not start directly in the group's directory");
  require(manager.snapshot().terminals[0].agentProvider==provider && manager.activeCount()==1,"Interactive agent identity was not recorded");
  var rejected=false;try backend.configureAgent("claude") catch (_:Dynamic) rejected=true;
  require(rejected,"Existing terminal mode changed after attachment");
  session.write(Bytes.ofString("hello\n"));until(function() return screen(session.emulator).indexOf("RECEIVED:hello")>=0,"Interactive agent did not receive terminal input");
  session.close();connect("first");
  backend=new RpcTerminalBackend(function() return endpoint,"interactive-agent",root,false);
  session=new TerminalSession(backend,Emulator.open(120,24),false);
  until(function() return backend.isSynchronized(),"Interactive agent did not reconnect");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==1,"View reconnection restarted the CLI");
  session.write(Bytes.ofString("exit\n"));until(function() return session.status=="exited","Interactive CLI did not exit");
  require(backend.controlAction()=="Restart agent","CLI session offered a shell replacement");
  manager.dispose();store.close();
  store=new WorkspaceSqliteStore(path,"workspace",seed);
  manager=new WorkspaceTerminalManager("workspace","second",root,16777216,store,function() return seed.groups);
  require(manager.snapshot().terminals[0].agentProvider==provider,"Daemon restart lost provider identity");
  connect("second");
  step(); // Observe the new endpoint before checking the previous session's state.
  until(function() return backend.isSynchronized() && session.status=="exited","Archived CLI did not recover");
  require(sys.io.File.getContent(countPath)=="1" && manager.activeCount()==0,"Opening saved CLI history spawned a new process");
  backend.activateControl();until(function() return backend.canControl() && session.status=="running","Explicit CLI restart failed");
  until(function() return sys.io.File.getContent(countPath)=="2","Restart did not launch the original provider");
  require(manager.snapshot().terminals[0].agentProvider==provider,"Restart changed the provider");
  session.close();endpoint.connection.close();server.close();manager.dispose();store.close();
 }
}
