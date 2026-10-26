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

class RealPiInputMain {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 static function main():Void {
  var args=Sys.args(),root=args[0],binary=args[1],clock=function() return Sys.time()*1000;
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root),seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  function build():CodexProvider return new CodexProvider("w","owner",dirs,function() return seed.snapshot().groups,processes,clock,store,"missing-codex",null,null,null,
   [new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,binary)]);
  var provider=build(),pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var value:Null<AgentView>=null,code="";
  function view():AgentView return cast value;
  function wait(done:Void->Bool):Void {
   var end=clock()+20000;
   while(!done()) {require(clock()<end,"Real Pi input timeout: "+(value==null ? "" : haxe.Json.stringify(value)));server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  }
  function action(kind:String,text:String="",?id:String):Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"pi",action:kind,text:text,request:id},5000,
    function(v) {value=v;done=true;},function(e) {code=e.code;done=true;});wait(function() return done);
  }
  function until(state:String):Void {wait(function() {action("read");return view().record.state==state;});}
  function idleInputs():Void {wait(function() {action("read");return view().inputBusy != true;});}
  function drained():Void {wait(function() {action("read");return view().record.state=="completed" && (cast view().pendingInputs:Array<AgentInputMessage>).length==0;});}
  var created=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"pi",name:"Pi",group:"work",thread:null,provider:"pi",defaultModel:"fixture/test-model"},5000,
   function(_) created=true,function(e) throw e.message);wait(function() return created);until("idle");
  action("prompt","approval");until("needs-attention");var approval=view().requests[0].id;
  var token=view().inputToken;action("queue","real-follow-up",token);require(code=="","Follow-up admission failed");
  action("queue","real-follow-up",token);require(code=="","Duplicate follow-up failed");
  var removed=view().inputToken;action("queue","real-removed",removed);action("remove-input","",removed);require(code=="","Remove follow-up failed");
  var cleared=view().inputToken;action("steer","real-steer-cleared",cleared);idleInputs();require(code=="","Native steering failed");
  wait(function() {action("read");return (cast view().nativePending:Array<AgentNativeInput>).length>0;});
  action("clear-native-queue","",view().inputToken);idleInputs();
  require((cast view().nativePending:Array<AgentNativeInput>).length==0,"Pi did not clear its queue");
  token=view().inputToken;action("steer","/fixture-command",token);require(code=="invalid_request" && view().inputToken==token,"Active extension command was executed or consumed its token");
  action("steer","/skill:unadvertised",token);require(code=="invalid_request" && view().inputToken==token,"Unadvertised slash steer consumed a token");
  action("steer","/skill:fixture-skill adjust the task",token);idleInputs();
  require([for(m in (cast view().nativePending:Array<AgentNativeInput>)) if(m.text.indexOf("PI_SKILL_EXPANSION_MARKER")>=0) true].length==1,"Native Pi steering did not expand skill");
  action("steer","/skill:fixture-skill adjust the task",token);require(code=="","Duplicate native steer failed");
  action("approve","",approval);drained();
  require(sys.io.File.getContent(root+"/approved.txt")=="approved","Original turn was lost during steering");
  action("prompt","hold");until("needs-attention");
  token=view().inputToken;action("queue","real-after-stop",token);
  var uncertain=view().inputToken;action("steer","real-uncertain-steer",uncertain);idleInputs();action("stop");
  require(view().queuePaused==true,"Stop did not pause follow-ups");
  action("connect");until("idle");
  require([for(m in (cast view().pendingInputs:Array<AgentInputMessage>)) if(m.id==uncertain && m.state=="uncertain") true].length==1,"Stopped native steer lost uncertainty");
  action("remove-input","",uncertain);action("resume-queue");drained();
  action("prompt","hold");until("needs-attention");action("queue","real-after-restart",view().inputToken);
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider=build();provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  require(processes.activeCount()==0,"Restart relaunched Pi");action("connect");until("idle");
  require(view().queuePaused==true,"Restart resumed follow-up implicitly");action("resume-queue");drained();
  provider.dispose();client.close();server.close();processes.shutdown();
  Sys.println("PASS: actual Pi streaming steering, native queue clear, skill expansion, removable follow-ups, stop and restart recovery");
 }
}
