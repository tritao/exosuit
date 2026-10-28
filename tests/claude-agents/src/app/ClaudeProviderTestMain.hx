package app;

import workspace.provider.ClaudeProvider;
import workspace.runtime.WorkspaceDirectories;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceService;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;

@:access(workspace.provider.ClaudeProvider)
class ClaudeProviderTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function main():Void {
  var args=Sys.args(),root=args[0],script=args[1],clock=function() return Sys.time()*1000;
  var python=Sys.getEnv("EXOSUIT_TEST_PYTHON"); if (python == null || python == "") python="python3";
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  var claude=new ClaudeProvider(dirs,function() return seed.snapshot().groups,processes,clock,store,python,script);
  var provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, [claude], store);
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function pump():Void {server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  function wait(done:Void->Bool):Void {
   var end=clock()+15000;
   while(!done()) {require(clock()<end,"Timed out waiting for Claude protocol");pump();}
  }
  var record:Null<AgentRecord>=null,code="",value:Null<AgentView>=null;
  function currentRecord():AgentRecord return cast record;
  function currentView():AgentView return cast value;
  function items():Array<AgentActivityItem> return cast currentView().items;
  function create():Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"a",name:"Claude",group:"work",thread:null,provider:"claude"},5000,
    function(r) {record=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);require(code=="","Create failed: "+code);
  }
  function action(action:String,text:String="",?request:String,?model:String):Void {
   var done=false;code="";value=null;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:action,text:text,request:request,model:model},5000,
    function(r) {value=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);
  }
  function until(state:String):Void {
   wait(function() {action("read");return value != null && currentView().record.state==state;});
  }
  create();var id=currentRecord().thread;create();require(currentRecord().thread==id,"Duplicate create changed session id");
  until("idle");
  var listed=false;
  client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},5000,function(r) {require(r.records.length==1 && r.records[0].provider=="claude","Mixed catalog lost Claude identity");
   var supported=r.providers;require(supported != null && supported.contains("claude"),"Catalog omitted Claude support");listed=true;},function(e) throw e.message);
  wait(function() return listed);
  action("prompt","hello");require(code=="","Prompt rejected");until("completed");
  require(items().length==2 && items()[1].text=="Hello 界","Streaming/final message was duplicated or corrupted");
  action("model-settings","",null,"test-model");require(code=="","set_model failed");
  action("permissions","plan");require(currentView().record.permissionMode=="plan","Permission choice was not saved");
  action("permissions","bypassPermissions");require(code=="invalid_request","Unsafe unsupported mode accepted");
  action("prompt","approval");until("needs-attention");var request=currentView().requests[0].id;
  action("approve","",request);require(code=="","Approval reply failed");until("completed");
  action("approve","",request);require(code=="resolved","Duplicate approval accepted");
  action("prompt","large-approval");until("needs-attention");request=currentView().requests[0].id;
  require(!currentView().requests[0].reviewable,"Truncated request was reviewable");
  action("approve","",request);require(code=="unsupported_request","Truncated approval accepted");
  action("decline","",request);until("completed");
  action("prompt","question");until("needs-attention");request=currentView().requests[0].id;
  action("answer","0=Blue\n0=Red",request);require(code=="invalid_request","Duplicate question answer accepted");
  action("answer","0=Blue",request);require(code=="","Question response failed");until("completed");
  action("prompt","question-structured");until("needs-attention");request=currentView().requests[0].id;
  var questions=currentView().requests[0].questions;
  require(questions != null && questions.length==2 && questions[1].multiple,"Structured Claude questions missing");
  action("answer-questions",'[{"id":"0","answers":["Blue"]},{"id":"1","answers":["Red, Green"]}]',request);
  require(code=="invalid_request","Ambiguous multiselect accepted");
  action("answer-questions",'[{"id":"0","answers":["Blue"]},{"id":"1","answers":["Red","Green"]}]',request);
  require(code=="","Structured Claude response failed");until("completed");
  action("prompt","wait");until("needs-attention");action("stop");require(code=="","Interrupt failed");until("interrupted");
  // Closing the editor connection must leave the daemon-owned process alive.
  client.close();server.close();
  for(_ in 0...10) {provider.poll();Sys.sleep(0.002);}
  var detached=claude.sessions.get("a");
  require(detached!=null && detached.transport!=null,"Editor detachment killed Claude");
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  action("prompt","crash");until("uncertain");
  action("prompt","must-not-send");require(code=="disconnected","Prompt allowed after uncertain delivery");
  var persisted=store.loadAgents();require(persisted[0].thread==id && persisted[0].provider=="claude" && persisted[0].replay != null,"Persisted session/replay missing");
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  claude=new ClaudeProvider(dirs,function() return seed.snapshot().groups,processes,clock,store,python,script);
  provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, [claude], store);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  for(_ in 0...10) provider.poll();
  var restored=claude.sessions.get("a");
  require(restored!=null && restored.transport==null,"Persisted Claude session was resumed automatically");
  action("read");require(items().length>0 && currentView().record.state=="uncertain","Restart lost uncertain state or replay");
  action("connect");until("idle");require(currentView().record.thread==id,"Resume changed session id");
  action("prompt","after-resume");until("completed");
  action("prompt","malformed");until("uncertain");
  action("connect");until("idle");action("prompt","oversized");until("uncertain");
  // A read-only attachment cannot mutate Claude through the Codex routing boundary.
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  provider.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:"connect",text:"",request:null},5000,function(_) throw "Read-only control succeeded",function(e) {require(e.code=="unauthorized","Wrong permission error");denied=true;});
  roServer.poll();ro.poll();require(denied,"Missing read-only rejection");
  // Replay evictions invalidate cursors, and persistence snapshots remain bounded.
  var c=new workspace.provider.ClaudeConversation();
  for(i in 0...20) c.put(Std.string(i),"t","agentMessage","Claude","text","","completed");
  var cursor=c.next();
  for(i in 20...160) c.put(Std.string(i),"t","agentMessage","Claude","text","","completed");
  require(c.offset(cursor)==null && c.snapshot().length==6,"Replay bounds/cursors failed");
  provider.dispose();client.close();server.close();ro.close();roServer.close();
  var silent=processes.start(python,[script,"--session-id","11111111-1111-4111-a111-111111111111","--silent"],root);
  var t=new workspace.provider.ClaudeTransport(silent),callbacks=0;
  t.request("initialize",{},0,function(r) {require(r.error != null,"Missing control timeout");callbacks++;});
  t.poll(60001);require(callbacks==1,"Control request did not time out");
  for(i in 0...33) t.request("set_model",{model:"fixture"},60001,function(r) {require(r.error != null,"Unexpected control completion");callbacks++;});
  require(callbacks==2,"Pending request limit was not enforced");
  require(!t.send({text:StringTools.lpad("","x",270000)}),"Oversized outgoing frame accepted");
  var accepted=0;
  while(t.send({text:StringTools.lpad("","x",200000)})) {accepted++;require(accepted<8,"Output queue was unbounded");}
  require(accepted>0,"Bounded output queue accepted nothing");
  t.close("Fixture shutdown");require(callbacks==34,"Control callbacks were lost or completed twice");
  t.close("Duplicate shutdown");require(callbacks==34,"Close completed callbacks twice");
  processes.release(silent);processes.shutdown();
  Sys.println("PASS: native Claude routing, streaming, controls, approval/questions, interrupt, detach, explicit resume, uncertain delivery, malformed/bounded frames and replay");
 }
}
