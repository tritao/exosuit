package app;

import workspace.provider.PiProvider;
import workspace.runtime.WorkspaceDirectories;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceService;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;

class PiProviderTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function main():Void {
  var args=Sys.args(),root=args[0],script=args[1],clock=function() return Sys.time()*1000;
  var python=Sys.getEnv("EXOSUIT_TEST_PYTHON");if(python==null || python=="") python="python3";
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  var pi=new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,python,script);
  var provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, [new workspace.provider.CodexProvider("owner", dirs, function() return seed.snapshot().groups, processes, clock, store, "missing-codex", null, null), pi], store);
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function pump():Void {server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  function wait(done:Void->Bool):Void {
   var end=clock()+15000;
   while(!done()) {require(clock()<end,"Timed out waiting for Pi protocol");pump();}
  }
  var record:Null<AgentRecord>=null,code="",value:Null<AgentView>=null;
  function currentRecord():AgentRecord return cast record;
  function currentView():AgentView return cast value;
  function items():Array<AgentActivityItem> return cast currentView().items;
  function create():Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"a",name:"Pi",group:"work",thread:null,provider:"pi"},5000,
    function(r) {record=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);require(code=="","Create failed: "+code);
  }
  function action(action:String,text:String="",?request:String,?model:String,?effort:String):Void {
   var done=false;code="";value=null;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:action,text:text,request:request,model:model,effort:effort},5000,
    function(r) {value=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);
  }
  function until(state:String):Void {
   wait(function() {action("read");return value != null && currentView().record.state==state;});
  }
  create();var id=currentRecord().thread;create();require(currentRecord().thread==id,"Duplicate create changed session id");
  until("idle");id=currentView().record.thread;create();require(currentRecord().thread==id,"Duplicate create changed native session");
  wait(function() {action("read");return currentView().commands != null && currentView().commandsLoading != true;});
  var commands:Array<AgentCommand>=cast currentView().commands;
  require(commands.length==3 && commands[2].kind=="skill" && commands[2].name=="fixture-skill" && commands[2].scope=="project","Native command/skill discovery lost metadata");
  var matches=workspace.client.AgentCommandCompletion.matches(commands,"$fixture");
  require(matches.length==1 && workspace.client.AgentCommandCompletion.insert(matches[0])=="/skill:fixture-skill ","Skill completion lost native invocation");
  require(workspace.client.AgentCommandCompletion.matches(commands,"/fixture-").length==2,"Slash completion lost command/template");
  require(workspace.client.AgentCommandCompletion.matches(commands,"/fixture-command argument").length==0 && workspace.client.AgentCommandCompletion.matches(commands,"text $fixture").length==0,"Completion consumed prompt arguments or prose");
  var many:Array<AgentCommand>=[for(i in 0...20) {name:"skill-"+i,description:"A skill",kind:"skill",invocation:"/skill:skill-"+i}];
  require(workspace.client.AgentCommandCompletion.matches(many,"$").length==8 && workspace.client.AgentCommandCompletion.matches(commands,"$FIXTURE").length==1,"Completion bounds/case filtering failed");
  var parsed=workspace.provider.PiCommands.parse({commands:[
   {name:"same",source:"extension",sourceInfo:{scope:""}},{name:"same",source:"prompt",sourceInfo:{scope:""}},{name:"bad command",source:"extension",sourceInfo:{scope:""}},
   {name:"unknown",source:"other",sourceInfo:{scope:""}},{name:"skill:",source:"skill",sourceInfo:{scope:""}},{name:"valid",source:"skill",sourceInfo:{scope:"global"}}
  ]});
  require(parsed.length==2 && parsed[0].kind=="command" && parsed[1].invocation=="/skill:valid" && parsed[1].scope=="user","Catalog validation or native precedence failed");
  sys.io.File.saveContent(root+"/commands-broken","");action("commands");
  wait(function() {action("read");return currentView().commandsLoading != true;});
  require(currentView().commandsError != null && currentView().connectionState=="connected" && (cast currentView().commands:Array<AgentCommand>).length==3,"Optional discovery failure disconnected Pi or erased the catalog");
  sys.FileSystem.deleteFile(root+"/commands-broken");sys.io.File.saveContent(root+"/commands-new","");action("commands");
  wait(function() {action("read");return currentView().commandsLoading != true;});
  require(currentView().commandsError==null && (cast currentView().commands:Array<AgentCommand>).length==4,"Explicit refresh did not update commands");
  var listed=false;
  client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},5000,function(r) {require(r.records.length==1 && r.records[0].provider=="pi","Mixed catalog lost Pi identity");listed=true;},function(e) throw e.message);
  wait(function() return listed);
  action("prompt","hello");require(code=="","Prompt rejected");until("completed");
  require(items().length==3 && items()[2].text=="Hello 界\u2028Pi" && items()[1].kind=="reasoning","Streaming/reasoning was duplicated or corrupted");
  action("prompt","/fixture-command");until("completed");
  action("prompt","/skill:fixture-skill investigate");until("completed");
  action("model-settings","",null,"fixture/other-model");require(code=="","set_model failed");
  wait(function() {action("read");return currentView().currentModel=="fixture/other-model";});
  until("idle");
  action("model-settings","",null,null,"high");until("idle");require(currentView().currentEffort=="high","Thinking setting was not applied");
  action("model-settings","",null,null,"max");require(code=="invalid_request","Unsupported thinking level accepted");
  action("permissions","acceptEdits");until("idle");require(currentView().record.permissionMode=="acceptEdits","Permission choice was not saved");
  action("permissions","auto");require(code=="invalid_permissions","Unsupported mode accepted");
  action("prompt","approval");until("needs-attention");var request=currentView().requests[0].id;
  action("approve","",request);require(code=="","Approval reply failed");until("completed");
  action("approve","",request);require(code=="resolved","Duplicate approval accepted");
  action("prompt","large-approval");until("needs-attention");request=currentView().requests[0].id;
  require(!currentView().requests[0].reviewable,"Truncated request was reviewable");
  action("approve","",request);require(code=="unsupported_request","Truncated approval accepted");
  action("decline","",request);until("completed");
  action("prompt","select");until("needs-attention");request=currentView().requests[0].id;
  require(currentView().requests[0].inputKind=="select" && currentView().requests[0].options[0]=="Blue","Typed selection dialog missing");
  action("answer","Green",request);require(code=="invalid_request","Unknown selection accepted");
  action("answer","Blue",request);require(code=="","Selection response failed");until("completed");
  for(kind in ["input","editor"]) {
   action("prompt",kind);until("needs-attention");request=currentView().requests[0].id;
   action("answer","An answer",request);require(code=="","Text response failed");until("completed");
  }
  action("prompt","tool");until("completed");
  require([for(i in currentView().items) if(i.kind=="tool" && i.text=="complete" && i.state=="completed") true].length==1,"Tool stream was not normalized");
  action("prompt","wait");until("needs-attention");var stale=currentView().requests[0].id;
  action("stop");require(code=="" && currentView().record.state=="interrupted","Stop failed");
  action("connect");until("idle");
  action("prompt","approval");until("needs-attention");request=currentView().requests[0].id;
  action("approve","",stale);require(code=="resolved","Approval from previous process was accepted");
  action("decline","",request);until("completed");
  // Closing the editor connection must leave the daemon-owned process alive.
  client.close();server.close();
  for(_ in 0...10) {provider.poll();Sys.sleep(0.002);}
  require(processes.activeCount()==1,"Editor detachment killed Pi");
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  action("prompt","crash");until("uncertain");
  action("prompt","must-not-send");require(code=="disconnected","Prompt allowed after uncertain delivery");
  var persisted=store.loadAgents();require(persisted[0].thread==id && persisted[0].provider=="pi" && persisted[0].replay != null,"Persisted session/replay missing");
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  pi=new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,python,script);
  provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, [new workspace.provider.CodexProvider("owner", dirs, function() return seed.snapshot().groups, processes, clock, store, "missing-codex", null, null), pi], store);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  for(_ in 0...10) provider.poll();
  require(processes.activeCount()==0,"Persisted Pi session was resumed automatically");
  action("read");require(items().length>0 && currentView().record.state=="uncertain","Restart lost uncertain state or replay");
  action("connect");until("idle");require(currentView().record.thread==id,"Resume changed session id");
  action("prompt","after-resume");until("completed");
  action("prompt","malformed");until("uncertain");
  action("connect");until("idle");action("prompt","oversized");until("uncertain");
  require(currentView().error!=null && currentView().error.indexOf("Pi frame exceeded bound")>=0,"Oversized unterminated Pi frame did not hit its bound");
  sys.FileSystem.deleteFile(id);
  action("connect");require(currentView().connectionState=="disconnected" && currentView().error.indexOf("missing")>=0,"Missing native session silently created a replacement");
  // A read-only attachment cannot mutate Pi through the Codex routing boundary.
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  provider.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:"connect",text:"",request:null},5000,function(_) throw "Read-only control succeeded",function(e) {require(e.code=="unauthorized","Wrong permission error");denied=true;});
  roServer.poll();ro.poll();require(denied,"Missing read-only rejection");
  var conflict=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"a",name:"Pi",group:"work",thread:null,provider:"codex"},5000,
   function(_) throw "Cross-provider identity collision accepted",function(e) {require(e.code=="conflict","Wrong provider collision error");conflict=true;});
  wait(function() return conflict);
  // A CLI that starts without confirming the injected hook must never receive a prompt.
  sys.io.File.saveContent(root+"/no-hook","");
  var unverified=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"unverified",name:"Pi",group:"work",thread:null,provider:"pi"},5000,
   function(_) unverified=true,function(e) throw e.message);
  wait(function() return unverified);
  wait(function() {
   var done=false;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"unverified",action:"read",text:"",request:null},5000,
    function(v) {value=v;done=true;},function(e) throw e.message);
   wait(function() return done);
   return currentView().connectionState=="disconnected" && currentView().error != null;
  });
  require(currentView().error.indexOf("permission extension")>=0,"Missing hook did not fail closed");
  var refused=false;
  client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"unverified",action:"prompt",text:"must-not-send",request:null},5000,
   function(_) throw "Prompt delivered without permission hook",function(e) {require(e.code=="disconnected","Wrong missing-hook error");refused=true;});
  wait(function() return refused);
  // Replay evictions invalidate cursors, and persistence snapshots remain bounded.
  var c=new workspace.provider.PiConversation();
  for(i in 0...20) c.put(Std.string(i),"t","agentMessage","Pi","text","","completed");
  var cursor=c.next();
  for(i in 20...160) c.put(Std.string(i),"t","agentMessage","Pi","text","","completed");
  require(c.offset(cursor)==null && c.snapshot().length==6,"Replay bounds/cursors failed");
  c.put("long-title","t","tool",StringTools.lpad("","x",3000),"text","","completed");
  require(c.snapshot()[5].title.length==256 && c.snapshot()[5].truncated,"Tool title retention was unbounded");
  provider.dispose();client.close();server.close();ro.close();roServer.close();
  var silent=processes.start(python,[script,"--session-id","11111111-1111-4111-a111-111111111111","--silent"],root);
  var t=new workspace.provider.PiTransport(silent),callbacks=0;
  t.request("initialize",{},0,function(r) {require(r.error != null,"Missing control timeout");callbacks++;});
  t.poll(60001);require(callbacks==1,"Control request did not time out");
  for(i in 0...33) t.request("set_model",{model:"fixture"},60001,function(r) {require(r.error != null,"Unexpected control completion");callbacks++;});
  require(callbacks==2,"Pending request limit was not enforced");
  t.close("Fixture shutdown");require(callbacks==34,"Control callbacks were lost or completed twice");
  t.close("Duplicate shutdown");require(callbacks==34,"Close completed callbacks twice");
  processes.release(silent);
  var silentQueue=processes.start(python,[script,"--session-id","11111111-1111-4111-a111-111111111111","--silent"],root);
  var bounded=new workspace.provider.PiTransport(silentQueue);
  require(!bounded.send({text:StringTools.lpad("","x",workspace.provider.PiTransport.MAX_FRAME_BYTES)}),"Oversized outgoing frame accepted");
  var accepted=0;
  while(bounded.send({text:StringTools.lpad("","x",200000)})) {accepted++;require(accepted<=32,"Output queue was unbounded");}
  require(accepted>0,"Bounded output queue accepted nothing");
  bounded.close("Fixture shutdown");processes.release(silentQueue);processes.shutdown();
  Sys.println("PASS: native Pi routing, streaming, controls, approval/questions, interrupt, detach, explicit resume, uncertain delivery, malformed/bounded frames and replay");
 }
}
