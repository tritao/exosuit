package app;

import workspace.provider.PiProvider;
import workspace.provider.CodexProvider;
import workspace.runtime.WorkspaceDirectories;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceService;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;

/** Real Pi CLI against a loopback-only deterministic model server. No user accounts or paid API calls. */
class RealPiSmokeMain {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 static function main():Void {
  var args=Sys.args(),root=args[0],binary=args[1],clock=function() return Sys.time()*1000;
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  function pi():PiProvider return new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,binary);
  var provider=new CodexProvider("w","owner",dirs,function() return seed.snapshot().groups,processes,clock,store,"missing-codex",null,null,null,[pi()]);
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var value:Null<AgentView>=null,code="";
  function view():AgentView return cast value;
  function wait(done:Void->Bool):Void {
   var end=clock()+20000;
   while(!done()) {require(clock()<end,"Real Pi timed out: "+(value == null ? "" : haxe.Json.stringify(value)));server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  }
  function action(kind:String,text:String="",?request:String):Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"pi",action:kind,text:text,request:request},5000,
    function(v) {value=v;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);require(code=="","Real Pi action failed: "+kind+" "+code);
  }
  function until(state:String):Void {wait(function() {action("read");return view().record.state==state;});}
  var created=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"pi",name:"Pi",group:"work",thread:null,provider:"pi",defaultModel:"fixture/test-model"},5000,
   function(_) created=true,function(e) throw e.message);
  wait(function() return created);until("idle");
  require((cast view().models:Array<AgentModel>).length==1,"Real Pi model discovery failed");
  wait(function() {action("read");return view().commands != null && view().commandsLoading != true;});
  var commands:Array<AgentCommand>=cast view().commands;
  require([for(c in commands) if(c.invocation=="/skill:fixture-skill" && c.kind=="skill") true].length==1,"Real Pi skill discovery failed");
  require([for(c in commands) if(c.invocation=="/fixture-prompt" && c.kind=="prompt") true].length==1,"Real Pi prompt discovery failed");
  require([for(c in commands) if(c.invocation=="/fixture-command" && c.kind=="command") true].length==1,"Real Pi command discovery failed: "+haxe.Json.stringify(commands));
  action("prompt","hello");until("completed");
  require([for(i in (cast view().items:Array<AgentActivityItem>)) if(i.kind=="agentMessage" && i.text=="Hello from real Pi") true].length==1,"Real Pi streaming failed");
  var session=view().record.thread;require(sys.FileSystem.exists(session),"Native Pi session was not persisted");
  action("prompt","approval");until("needs-attention");
  action("approve","",view().requests[0].id);until("completed");
  require(sys.io.File.getContent(root+"/approved.txt")=="approved","Approved real Pi tool did not execute");
  action("prompt","decline");until("needs-attention");action("decline","",view().requests[0].id);until("completed");
  require(!sys.FileSystem.exists(root+"/declined.txt"),"Declined real Pi tool executed");
  action("permissions","acceptEdits");until("idle");require(view().record.thread==session,"Policy restart changed Pi conversation");
  action("prompt","auto-edit");until("completed");
  require(sys.io.File.getContent(root+"/auto.txt")=="approved","Auto-accept edit required approval or failed");
  action("permissions","supervised");until("idle");
  action("prompt","hold");until("needs-attention");action("stop");
  require(view().record.state=="interrupted" && !sys.FileSystem.exists(root+"/stopped.txt"),"Stopped Pi executed a pending tool");
  action("connect");until("idle");require(view().record.thread==session,"Stop/resume changed conversation");
  // Rebuild the provider as a daemon restart, retaining only the SQLite state.
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider=new CodexProvider("w","owner",dirs,function() return seed.snapshot().groups,processes,clock,store,"missing-codex",null,null,null,[pi()]);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  require(processes.activeCount()==0,"Pi resumed without explicit connection");
  action("connect");until("idle");require(view().record.thread==session,"Real Pi resume changed native identity");
  action("prompt","after-resume");until("completed");
  action("prompt","/fixture-command");until("completed");
  require([for(i in (cast view().items:Array<AgentActivityItem>)) if(i.text=="PI_COMMAND_EXECUTED") true].length==1,"Real Pi extension command was not dispatched natively");
  action("prompt","/skill:fixture-skill investigate");until("completed");
  action("prompt","/fixture-prompt check native expansion");until("completed");
  provider.dispose();processes.shutdown();client.close();server.close();
  Sys.println("PASS: real Pi CLI discovery, permission-hook handshake, streaming, native tools, approve/decline, auto-edit, policy restart and persisted resume");
 }
}
