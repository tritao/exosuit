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

class PiInputTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function main():Void {
  PiClientInputTest.run();
  var args=Sys.args(),root=args[0],script=args[1],clock=function() return Sys.time()*1000;
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  function build():CodexProvider return new CodexProvider("w","owner",dirs,function() return seed.snapshot().groups,processes,clock,store,
   "missing-codex",null,null,null,[new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,"python3",script)]);
  var provider=build(),pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var value:Null<AgentView>=null,code="";
  function view():AgentView return cast value;
  function wait(done:Void->Bool):Void {
   var end=clock()+15000;
   while(!done()) {require(clock()<end,"Pi input timeout: "+(value == null ? "" : haxe.Json.stringify(value)));server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  }
  function action(kind:String,text:String="",?request:String):Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"pi",action:kind,text:text,request:request},5000,
    function(v) {value=v;done=true;},function(e) {code=e.code;done=true;});wait(function() return done);
  }
  function until(state:String):Void {wait(function() {action("read");return view().record.state==state;});}
  var created=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"pi",name:"Pi",group:"work",thread:null,provider:"pi"},5000,
   function(_) created=true,function(e) throw e.message);wait(function() return created);until("idle");
  // A follow-up remains cancellable in the daemon while Pi is waiting for approval.
  action("prompt","wait");until("needs-attention");var approval=view().requests[0].id;
  var boundedIds:Array<String>=[];
  for(i in 0...8) {var token=view().inputToken;boundedIds.push(token);action("queue","bound-"+i,token);require(code=="","Bounded queue admission failed");}
  var full=view().inputToken;action("queue","bound-overflow",full);require(code=="limit" && view().inputToken==full,"Queue count limit consumed a token");
  action("clear-native-queue","",full);require(code=="","Full follow-up queue blocked native cancellation");
  wait(function() {action("read");return view().inputBusy != true;});
  for(token in boundedIds) action("remove-input","",token);
  var bounded=view().inputToken;action("queue",StringTools.lpad("","界",2000),bounded);
  require(code=="limit" && view().inputToken==bounded,"UTF-8 queue bound consumed a token or accepted oversized input");
  var rejected=view().inputToken;action("steer","reject-steer",rejected);
  wait(function() {action("read");return view().inputBusy != true;});
  require(view().record.state=="needs-attention" && view().connectionState=="connected","Rejected steer disconnected the active run");
  require([for(m in (cast view().pendingInputs:Array<AgentInputMessage>)) if(m.id==rejected && m.state=="rejected") true].length==1,"Rejected steer was lost");
  action("remove-input","",rejected);
  var first=view().inputToken;action("queue","queue-cancelled",first);require(code=="","Queue rejected: "+code);
  action("queue","queue-cancelled",first);require(code=="","Duplicate queue was not idempotent");
  action("queue","different",first);require(code=="conflict","Reused token accepted different content");
  var second=view().inputToken;action("queue","queue-delivered",second);require(code=="","Second queue failed");
  action("remove-input","",first);require(code=="","Queued cancellation failed");
  var steer=view().inputToken;action("steer","steer-cleared",steer);require(code=="","Steer rejected: "+code);
  wait(function() {action("read");return view().inputBusy != true;});
  action("steer","steer-cleared",steer);require(code=="","Duplicate steer was not idempotent");
  var clear=view().inputToken;action("clear-native-queue","",clear);require(code=="","Clear Pi queue failed");
  wait(function() {action("read");return view().inputBusy != true;});
  require((cast view().nativePending:Array<AgentNativeInput>).length==0,"Native pending inputs were not cleared");
  var kept=view().inputToken;action("steer","steer-delivered",kept);require(code=="","Second steer failed");
  wait(function() {action("read");return view().inputBusy != true;});
  action("approve","",approval);until("completed");
  wait(function() {action("read");return (cast view().pendingInputs:Array<AgentInputMessage>).length==0;});
  // Stop retains unsent work but does not resume it implicitly.
  action("prompt","wait");until("needs-attention");
  var stopped=view().inputToken;action("queue","queue-after-stop",stopped);
  action("stop");require(code=="" && view().queuePaused==true,"Stop did not pause queued work");
  action("connect");until("idle");require(view().queuePaused==true,"Connect automatically resumed queue");
  action("resume-queue");require(code=="","Queue resume failed");until("completed");
  // Lost steering acknowledgement must survive restart without an automatic retry.
  action("prompt","wait");until("needs-attention");
  var deferred=view().inputToken;action("queue","queue-after-restart",deferred);
  var lost=view().inputToken;action("steer","lost-steer",lost);until("uncertain");
  require(view().queuePaused==true,"Transport loss did not pause queue");
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider=build();provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  require(processes.activeCount()==0,"Restart relaunched Pi automatically");
  action("read");
  require([for(m in (cast view().pendingInputs:Array<AgentInputMessage>)) if(m.id==lost && m.state=="uncertain") true].length==1,"Uncertain delivery was lost");
  action("steer","lost-steer",lost);require(code=="","Restart lost idempotency receipt");
  action("connect");until("idle");require(view().queuePaused==true,"Restart/connect resumed pending queue");
  action("resume-queue");until("completed");action("remove-input","",lost);require(code=="","Uncertain input could not be dismissed");
  // A late idle probe must not settle a new steer which started after the previous native run ended.
  action("prompt","settle-race");
  wait(function() {action("read");return [for(i in (cast view().items:Array<AgentActivityItem>)) if(i.text=="RACE_PROBE_HELD") true].length>0;});
  var racing=view().inputToken;action("steer","race-steer",racing);require(code=="","Late steer rejected");
  until("needs-attention");approval=view().requests[0].id;
  var after=view().inputToken;action("queue","queue-after-race",after);
  action("approve","",approval);until("completed");
  wait(function() {action("read");return (cast view().pendingInputs:Array<AgentInputMessage>).length==0;});
  // Bounded receipts reject an old token after eviction, rather than admitting it as new work.
  var old=view().inputToken;
  for(i in 0...20) {
   var token=view().inputToken;action("queue","receipt-"+i,token);require(code=="","Receipt queue failed");
   wait(function() {action("read");return view().record.state=="completed" && view().inputBusy != true && (cast view().pendingInputs:Array<AgentInputMessage>).length==0;});
  }
  action("queue","receipt-0",old);require(code=="stale_input","Evicted delivery token was accepted again");
  // Read-only attachments cannot enqueue or steer.
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  provider.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"pi",action:"queue",text:"unauthorized",request:view().inputToken},5000,
   function(_) throw "Read-only queue succeeded",function(e) {require(e.code=="unauthorized","Wrong authorization failure");denied=true;});roServer.poll();ro.poll();require(denied,"Missing read-only rejection");
  provider.dispose();client.close();server.close();ro.close();roServer.close();processes.shutdown();
  Sys.println("PASS: Pi steering, FIFO follow-ups, cancellation, idempotency, stop/restart pause, lost ACK recovery, settlement races and authorization");
 }
}
