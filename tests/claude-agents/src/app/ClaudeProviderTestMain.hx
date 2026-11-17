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
@:access(workspace.provider.AgentImageStaging)
class ClaudeProviderTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function largePng():haxe.io.Bytes {
  var original=sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"),length=2*1024*1024-original.length-12;
  var chunk=haxe.io.Bytes.alloc(length+12);
  chunk.set(0,(length>>>24)&255);chunk.set(1,(length>>>16)&255);chunk.set(2,(length>>>8)&255);chunk.set(3,length&255);
  chunk.blit(4,haxe.io.Bytes.ofString("tEXt"),0,4);for(i in 0...length) chunk.set(8+i,120);
  var crc=workspace.provider.AgentImageStaging.crc32(chunk,4,length+4);
  for(i in 0...4) chunk.set(8+length+i,(crc>>>(24-8*i))&255);
  var result=haxe.io.Bytes.alloc(original.length+chunk.length);
  result.blit(0,original,0,original.length-12);result.blit(original.length-12,chunk,0,chunk.length);
  result.blit(original.length-12+chunk.length,original,original.length-12,12);return result;
 }
 static function main():Void {
  var args=Sys.args(),root=args[0],script=args[1],clock=function() return Sys.time()*1000;
  var python=Sys.getEnv("EXOSUIT_TEST_PYTHON"); if (python == null || python == "") python="python3";
  // The fake keeps Claude Code's own record of each conversation here, and the provider reads it there.
  Sys.putEnv("FAKE_CLAUDE_HOME",root+"/claude-home");Sys.putEnv("CLAUDE_CONFIG_DIR",root+"/claude-home");
  var sid="a";
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),root);
  var claude=new ClaudeProvider(dirs,function() return seed.snapshot().groups,processes,clock,store,python,script);
  var provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, workspace.provider.AgentProviderFactory.built([claude]), store,"claude-image-fixture");
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function pump():Void {server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  function wait(done:Void->Bool):Void {
   var end=clock()+60000;
   while(!done()) {require(clock()<end,"Timed out waiting for Claude protocol");pump();}
  }
  var record:Null<AgentRecord>=null,code="",value:Null<AgentView>=null;
  function currentRecord():AgentRecord return cast record;
  function currentView():AgentView return cast value;
  function items():Array<AgentActivityItem> return cast currentView().items;
  function create():Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:sid,name:"Claude",group:"work",thread:null,provider:"claude"},5000,
    function(r) {record=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);require(code=="","Create failed: "+code);
  }
  function action(action:String,text:String="",?request:String,?model:String,?imageIds:Array<String>):Void {
   var done=false;code="";value=null;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:sid,action:action,text:text,request:request,model:model,imageIds:imageIds},5000,
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
  function upload(bytes:haxe.io.Bytes):String {
   var uploadId:Null<String>=null,offset=0,done=false;
   function call(operation:String,chunk:Null<haxe.io.Bytes>):AgentImageUploadResult {
    var result:Null<AgentImageUploadResult>=null;done=false;
    client.call(WorkspaceAgentProtocol.IMAGE_UPLOAD,{workspace:"w",instance:"owner",session:"a",operation:operation,upload:uploadId,size:bytes.length,offset:offset,bytes:chunk},5000,
     function(v) {result=v;done=true;},function(e) throw e.message);
    wait(function() return done);return cast result;
   }
   uploadId=call("begin",null).upload;
   while(offset<bytes.length) {var count=Std.int(Math.min(32768,bytes.length-offset));offset=call("chunk",bytes.sub(offset,count)).offset;}
   call("finish",null);return cast uploadId;
  }
  var png=largePng();sys.io.File.saveBytes(root+"/expected-claude-image.png",png);
  var image1=upload(png),image2=upload(png);
  action("prompt","image maximum 界\n\"quoted\"",null,null,[image1,image2]);require(code=="","Claude image prompt rejected");until("completed");
  require([for(item in items()) if(item.kind=="userMessage" && item.images!=null && item.images.length==2 && item.images[0].id==image1 && item.images[1].id==image2) true].length==1,
   "Claude sent-image identity missing");
  var imageOnly=upload(sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"));
  action("prompt","",null,null,[imageOnly]);require(code=="","Claude image-only prompt rejected");until("completed");
  action("prompt","invalid image",null,null,[StringTools.lpad("missing","0",32)]);require(code=="image_unavailable","Invalid Claude image accepted");
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
  var uncertainImage=upload(sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"));
  action("prompt","image-crash",null,null,[uncertainImage]);
  var uncertainTurn="";
  for(item in items()) if(item.kind=="userMessage" && item.images!=null && item.images.length==1 && item.images[0].id==uncertainImage) uncertainTurn=item.turn;
  require(uncertainTurn!="","Uncertain image identity was not retained before delivery");until("uncertain");
  action("prompt","must-not-send");require(code=="disconnected","Prompt allowed after uncertain delivery");
  var persisted=store.loadAgents();require(persisted[0].thread==id && persisted[0].provider=="claude" && persisted[0].replay != null,"Persisted session/replay missing");
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  claude=new ClaudeProvider(dirs,function() return seed.snapshot().groups,processes,clock,store,python,script);
  provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, workspace.provider.AgentProviderFactory.built([claude]), store,"claude-image-fixture");
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  for(_ in 0...10) provider.poll();
  var restored=claude.sessions.get("a");
  require(restored!=null && restored.transport==null,"Persisted Claude session was resumed automatically");
  action("read");require(items().length>0 && currentView().record.state=="uncertain","Restart lost uncertain state or replay");
  require([for(item in items()) if(item.turn==uncertainTurn && item.images!=null && item.images.length==1 && item.images[0].id==uncertainImage) true].length==1,
   "Restart lost uncertain image association");
  var archived:Null<AgentContentChunk>=null,archivedDone=false;
  client.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"w",instance:"owner",session:"a",turn:uncertainTurn,item:uncertainTurn,token:uncertainImage,offset:0},5000,
   function(chunk) {archived=chunk;archivedDone=true;},function(e) throw e.message);
  wait(function() return archivedDone);
  require(archived!=null && archived.bytes.compare(sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"))==0,"Restart lost uncertain image bytes");
  action("connect");until("idle");require(currentView().record.thread==id,"Resume changed session id");
  action("prompt","after-resume");until("completed");
  action("prompt","long");until("completed");
  // Stop and restart with nothing in flight. Before it: a second session nothing was ever sent to, and a saved
  // record that fails validation.
  sid="b";create();var unsent=currentRecord().thread;until("idle");sid="a";
  store.saveAgent({id:"c",name:"Broken",group:"work",cwd:dirs.root,thread:"not-a-conversation",state:"idle",turn:null,
   workspaceRoot:"elsewhere",provider:"claude",nameMetadata:{source:"native",nativeName:null},permissionMode:"default",preferredModel:null});
  // A conversation with messages whose Claude record is gone, and a row whose working folder is gone.
  store.saveAgent({id:"d",name:"Lost",group:"work",cwd:dirs.root,thread:"22222222-2222-4222-a222-222222222222",state:"idle",turn:null,
   workspaceRoot:"elsewhere",provider:"claude",nameMetadata:{source:"native",nativeName:null},permissionMode:"default",preferredModel:null,
   replay:[{id:"t1",turn:"t1",kind:"userMessage",title:"You",text:"earlier question",detail:"",state:"completed",truncated:false}]});
  store.saveAgent({id:"e",name:"NoFolder",group:"work",cwd:"",thread:"33333333-3333-4333-a333-333333333333",state:"idle",turn:null,
   workspaceRoot:"elsewhere",provider:"claude",nameMetadata:{source:"native",nativeName:null},permissionMode:"default",preferredModel:null});
  function launches():Array<Dynamic> return [for(line in sys.io.File.getContent(root+"/wire.jsonl").split("\n")) if(line.indexOf('"type": "launch"')>=0) haxe.Json.parse(line)];
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  claude=new ClaudeProvider(dirs,function() return seed.snapshot().groups,processes,clock,store,python,script);
  provider=new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, workspace.provider.AgentProviderFactory.built([claude]), store,"claude-image-fixture");
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var rows:Array<String>=[],rowsDone=false;
  client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},5000,function(r) {rows=[for(row in r.records) row.id+":"+row.state];rowsDone=true;},function(e) throw e.message);
  wait(function() return rowsDone);rows.sort(Reflect.compare);
  require(rows.join(",")=="a:disconnected,b:disconnected,c:reconnect-failed,d:disconnected,e:reconnect-failed","A restart lost or mislabelled session rows: "+rows.join(","));
  action("read");
  require(currentView().record.state=="disconnected" && currentView().connectionState=="disconnected" && currentView().promptResumes==true
   && currentView().recoveryReason=="explicit-resume","A stopped session is not offered as resumable");
  // The whole conversation, not the six shortened items the service saves: read every page.
  var whole:Array<AgentActivityItem>=[],older:Null<String>=null;
  while(true) {
   var done=false,page:Null<AgentView>=null;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:"read",text:"",request:null,after:older},5000,
    function(r) {page=r;done=true;},function(e) throw e.message);
   wait(function() return done);
   var got:AgentView=cast page;whole=(cast got.items:Array<AgentActivityItem>).concat(whole);older=got.itemsNext;
   if(older==null) break;
  }
  var prompts=[for(item in whole) if(item.kind=="userMessage") item.text];
  require(whole.length>12 && prompts[0]=="hello" && prompts.contains("approval") && prompts.contains("after-resume") && prompts[prompts.length-1]=="long",
   "A restart did not bring the whole conversation back: "+prompts.join("|"));
  var longReply=[for(item in whole) if(item.kind=="agentMessage" && item.id=="message-long") item];
  require(longReply.length==1 && longReply[0].truncated && longReply[0].text.length==4096 && longReply[0].contentToken!=null,"A long reply was not restored with its content");
  var content:Null<AgentContentChunk>=null,contentDone=false;
  client.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"w",instance:"owner",session:"a",turn:longReply[0].turn,item:"message-long",token:cast longReply[0].contentToken,offset:0},5000,
   function(chunk) {content=chunk;contentDone=true;},function(e) throw e.message);
  wait(function() return contentDone);
  require(content!=null && (cast content:AgentContentChunk).total>6000,"A long reply's whole text is not served after a restart");
  var stopped=claude.sessions.get("a");
  require(stopped!=null && stopped.transport==null,"Reading a stopped session started its process");
  // One action continues it: a prompt resumes the same conversation and is delivered once.
  var before=launches().length;
  action("prompt","typed-after-restart");require(code=="","A prompt to a stopped session was refused: "+code);until("completed");
  var started=launches();
  require(started.length==before+1 && started[before].session==id && started[before].resume==true,"A prompt did not resume the same Claude conversation");
  require(currentView().record.thread==id && items()[items().length-1].text=="Hello 界" && items()[items().length-2].text=="typed-after-restart","The resumed prompt or its reply is missing");
  // A session nothing was sent to has no conversation to resume: it is begun under the same id.
  sid="b";action("read");require(currentView().record.state=="disconnected" && currentView().record.thread==unsent,"The unsent session changed");
  action("connect");until("idle");started=launches();
  require(started[started.length-1].session==unsent && started[started.length-1].resume==false,"A session without a conversation was resumed instead of begun");
  // The invalid record stays as a row that says why it cannot be resumed.
  sid="c";action("read");
  require(currentView().record.state=="reconnect-failed" && currentView().error!=null && currentView().error.indexOf("conversation id")>=0,"An invalid record is not explained");
  action("connect");require(code=="session_unavailable","An invalid record was resumed");
  action("prompt","nothing");require(code=="disconnected","An invalid record took a prompt");
  // A conversation that had messages but lost Claude's record is not replaced by an empty one.
  sid="d";var startedBefore=launches().length;
  action("prompt","hello again");require(code=="" || code=="disconnected","Unexpected refusal: "+code);
  wait(function() {action("read");return currentView().error!=null;});
  require(currentView().error.indexOf("no longer has this conversation's record")>=0 && currentView().error.indexOf("not sent")>=0,"A lost record was not reported: "+currentView().error);
  require(launches().length==startedBefore && (function() {var lost=claude.sessions.get("d");return lost!=null && lost.transport==null;})(),"A lost conversation was begun again under the same id");
  // A row without a working folder shows the workspace root, but renaming it keeps the saved record's own folder.
  sid="e";action("read");require(currentView().record.cwd==dirs.root,"A broken row does not show the workspace root");
  action("rename","Renamed",currentView().record.name);require(code=="","Rename of a broken row failed: "+code);
  var savedE=[for(a in store.loadAgents()) if(a.id=="e") a][0];
  require(savedE.name=="Renamed" && savedE.cwd=="","A rename saved the placeholder folder: "+savedE.cwd);
  sid="a";
  action("prompt","malformed");until("uncertain");
  action("connect");until("idle");action("prompt","oversized");until("uncertain");
  require(currentView().error!=null && currentView().error.indexOf("Claude frame exceeded bound")>=0,"Oversized unterminated Claude frame did not hit its bound");
  // A read-only attachment cannot mutate Claude through the Codex routing boundary.
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  provider.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:"connect",text:"",request:null},5000,function(_) throw "Read-only control succeeded",function(e) {require(e.code=="unauthorized","Wrong permission error");denied=true;});
  roServer.poll();ro.poll();require(denied,"Missing read-only rejection");
  // Replay evictions invalidate cursors, and persistence snapshots remain bounded.
  var c=new workspace.provider.AgentConversation("Claude");
  for(i in 0...20) c.put(Std.string(i),"t","agentMessage","Claude","text","","completed");
  var cursor=c.next();
  for(i in 20...(workspace.provider.AgentConversation.MAX_ENTRIES+40)) c.put(Std.string(i),"t","agentMessage","Claude","text","","completed");
  require(c.offset(cursor)==null && c.snapshot().length==6,"Replay bounds/cursors failed");
  provider.dispose();client.close();server.close();ro.close();roServer.close();
  var silent=processes.start(python,[script,"--session-id","11111111-1111-4111-a111-111111111111","--silent"],root);
  var t=new workspace.provider.ClaudeTransport(silent),callbacks=0;
  t.request("initialize",{},0,function(r) {require(r.error != null,"Missing control timeout");callbacks++;});
  t.poll(60001);require(callbacks==1,"Control request did not time out");
  for(i in 0...33) t.request("set_model",{model:"fixture"},60001,function(r) {require(r.error != null,"Unexpected control completion");callbacks++;});
  require(callbacks==2,"Pending request limit was not enforced");
  t.close("Fixture shutdown");require(callbacks==34,"Control callbacks were lost or completed twice");
  t.close("Duplicate shutdown");require(callbacks==34,"Close completed callbacks twice");
  processes.release(silent);
  var silentQueue=processes.start(python,[script,"--session-id","11111111-1111-4111-a111-111111111111","--silent"],root);
  var bounded=new workspace.provider.ClaudeTransport(silentQueue);
  require(!bounded.send({text:StringTools.lpad("","x",workspace.provider.ClaudeTransport.MAX_FRAME_BYTES)}),"Oversized outgoing frame accepted");
  var accepted=0;
  while(bounded.send({text:StringTools.lpad("","x",200000)})) {accepted++;require(accepted<=32,"Output queue was unbounded");}
  require(accepted>0,"Bounded output queue accepted nothing");bounded.close("Fixture shutdown");processes.release(silentQueue);processes.shutdown();
  Sys.println("PASS: native Claude routing, streaming, controls, approval/questions, interrupt, detach, explicit resume, uncertain delivery, malformed/bounded frames, replay, and a restart that keeps every row, restores the whole conversation and resumes on a prompt");
 }
}
