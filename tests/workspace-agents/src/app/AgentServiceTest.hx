package app;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.rpc.MemoryTransport;
import workspace.provider.LocalAgentProvider;
import workspace.provider.AgentMessageSource;
import workspace.provider.WorkspaceAgentService;
import workspace.service.WorkspaceAgentProtocol;

/** Routing boundaries exercised without depending on any vendor CLI or provider order. */
class AgentServiceTest {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run():Void {
  var questions=workspace.provider.StructuredQuestions.project("codex",{questions:[{id:"mode",header:"Mode",question:"Choose a mode",isOther:false,isSecret:false,
   options:[{label:"Careful",description:"Run checks"},{label:"Fast",description:"Short run"}]}]});
  require(questions != null && questions.length==1 && !questions[0].multiple,"Native question projection failed");
  require(workspace.provider.StructuredQuestions.answers(questions,'[{"id":"mode","answers":["Careful"]}]',"codex") != null,
   "Exact native choice was rejected");
  require(workspace.provider.StructuredQuestions.answers(questions,'[{"id":"mode","answers":["invented"]}]',"codex") == null
   && workspace.provider.StructuredQuestions.answers(questions,'[{"id":"mode","answers":["Careful","Fast"]}]',"codex") == null
   && workspace.provider.StructuredQuestions.answers(questions,'[{"id":"other","answers":["Careful"]}]',"codex") == null,
   "Structured answers bypassed retained question constraints");
  var multi=workspace.provider.StructuredQuestions.project("claude",{questions:[{header:"Checks",question:"Which checks?",multiSelect:true,
   options:[{label:"Build",description:""},{label:"Tests",description:""}]}]});
  require(multi != null && multi[0].multiple && workspace.provider.StructuredQuestions.answers(multi,'[{"id":"0","answers":["Build","Tests"]}]',"claude") != null,
   "Claude multiple selections were not preserved");
  require(workspace.provider.StructuredQuestions.project("codex",{questions:[{id:"mode",header:"Mode",question:StringTools.rpad("", "界", 1000),options:null}]}) == null,
   "Oversized UTF-8 question was presented as complete");
  var pending:Array<AgentRequest> = [];
  for (i in 0...16) pending.push({id:"request-"+i,method:"item/tool/requestUserInput",detail:StringTools.rpad("", "界", 1800),reviewable:true});
  var page=workspace.provider.AgentRequestPage.project(pending);
  require(page.requests.length>0 && page.omitted==pending.length-page.requests.length
   && haxeon.wire.MessagePack.encode(page.requests).length <= workspace.provider.AgentRequestPage.MAX_BYTES,
   "Pending request page exceeded its relay budget");
  pending.shift();
  var next=workspace.provider.AgentRequestPage.project(pending);
  require(next.requests[0].id=="request-1","Resolved request blocked the next queued decision");
  var oversized:Array<AgentRequest>=[{id:"huge",method:"item/tool/requestUserInput",detail:"Question",reviewable:true,
   options:[StringTools.rpad("", "x", 12000)]}];
  var fallback=workspace.provider.AgentRequestPage.project(oversized);
  require(fallback.requests.length==1 && fallback.requests[0].id=="huge" && !fallback.requests[0].reviewable
   && fallback.requests[0].options==null && fallback.omitted==0,"Oversized request lost its safe decline path");
  var alpha=new MessageFixtureProvider("alpha",31),beta=new FixtureProvider("beta",1);
  var service=new WorkspaceAgentService("w","owner","/work",[alpha,beta]);
  var clock=function() return Sys.time()*1000;
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function create(kind:String,id:String):String {
   var code="pending";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:id,name:"Fixture",group:"work",thread:null,provider:kind},1000,
    function(_) code="ok",function(error) code=error.code);
   server.poll();client.poll();return code;
  }
  require(create("beta","new")=="limit" && beta.creates==0,"Global catalog limit was not enforced across providers");
  require(create("beta","alpha-0")=="conflict" && beta.creates==0,"Cross-provider resource identity was routed incorrectly");
  require(create("missing","new")=="invalid_provider","Unknown provider was silently substituted");
  require(create("alpha","alpha-0")=="ok" && alpha.creates==1,"Idempotent creation was blocked by global capacity");
  var catalog:Null<AgentCatalog>=null;
  client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},1000,function(r) catalog=r,function(error) throw error.message);
  server.poll();client.poll();
  require(catalog!=null && catalog.records.length==6 && catalog.next!=null,"Combined catalog pagination failed");
  var duplicate=false;
  try new WorkspaceAgentService("w","owner","/work",[alpha,alpha]) catch(_:Dynamic) duplicate=true;
  require(duplicate,"Duplicate provider registration was accepted");
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  service.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"alpha-0",name:"Fixture",group:"work",thread:null,provider:"alpha"},1000,
   function(_) throw "Read-only create was accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied && alpha.creates==1,"Authorization did not fence the adapter side effect");
  denied=false;
  ro.call(WorkspaceAgentProtocol.IMAGE_UPLOAD,{workspace:"w",instance:"owner",session:"alpha-0",operation:"begin",
   upload:null,size:64,offset:0,bytes:null},1000,function(_) throw "Read-only image upload was accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied,"Image upload ignored control permission");
  var unsupported=false;
  client.call(WorkspaceAgentProtocol.IMAGE_UPLOAD,{workspace:"w",instance:"owner",session:"beta-0",operation:"begin",
   upload:null,size:64,offset:0,bytes:null},1000,function(_) throw "Non-Codex image upload was accepted",function(error) unsupported=error.code=="unsupported_operation");
  server.poll();client.poll();require(unsupported,"Non-Codex provider advertised image upload");
  var noReadPair=MemoryTransport.pair(), noRead=new RpcConnection(noReadPair.client,clock), noReadServer=new RpcConnection(noReadPair.server,clock);
  service.bind(noReadServer,[]); denied=false;
  noRead.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"w",instance:"owner",session:"alpha-0",turn:"t",item:"i",token:"1",offset:0},1000,
   function(_) throw "Content read without authorization was accepted",function(error) denied=error.code=="unauthorized");
  noReadServer.poll();noRead.poll();require(denied,"Message content ignored read permission");
  unsupported=false;
  ro.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"w",instance:"owner",session:"beta-0",turn:"t",item:"i",token:"1",offset:0},1000,
   function(_) throw "Non-Codex content was accepted",function(error) unsupported=error.code=="content_unavailable");
  roServer.poll();ro.poll();require(unsupported,"Message content ignored provider ownership");
  var loaded:Null<AgentContentChunk>=null;
  ro.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"w",instance:"owner",session:"alpha-0",turn:"t",item:"i",token:"1",offset:0},1000,
   function(chunk) loaded=chunk,function(error) throw error.message);
  roServer.poll();ro.poll();require(loaded != null && loaded.bytes.toString()=="Complete response" && alpha.reads==1,"Optional message source was not routed with read permission");
  denied=false;
  ro.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"other",instance:"owner",session:"alpha-0",turn:"t",item:"i",token:"1",offset:0},1000,
   function(_) throw "Cross-workspace message read accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied && alpha.reads==1,"Workspace check did not fence message source");
  denied=false;
  noRead.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"w",instance:"owner",session:"alpha-0",turn:"t",item:"i",token:"image",offset:0},1000,
   function(_) throw "Sent image read without permission was accepted",function(error) denied=error.code=="unauthorized");
  noReadServer.poll();noRead.poll();require(denied,"Sent image ignored read permission");
  denied=false;
  ro.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"other",instance:"owner",session:"alpha-0",turn:"t",item:"i",token:"image",offset:0},1000,
   function(_) throw "Cross-workspace sent image read accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied,"Sent image ignored workspace ownership");
  denied=false;
  ro.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"w",instance:"other",session:"alpha-0",turn:"t",item:"i",token:"image",offset:0},1000,
   function(_) throw "Cross-instance sent image read accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied,"Sent image ignored service instance");
  unsupported=false;
  ro.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"w",instance:"owner",session:"beta-0",turn:"t",item:"i",token:"image",offset:0},1000,
   function(_) throw "Unknown sent image accepted",function(error) unsupported=error.code=="image_unavailable");
  roServer.poll();ro.poll();require(unsupported,"Missing sent image did not report unavailable");
  noRead.close();noReadServer.close();
  service.dispose();require(alpha.disposed && beta.disposed,"Service lifecycle did not reach every adapter");
  client.close();server.close();ro.close();roServer.close();
  Sys.println("PASS: provider-neutral routing, combined limits/pagination, cross-provider identity and authorization");
 }
}

private class MessageFixtureProvider extends FixtureProvider implements AgentMessageSource {
 public var reads=0;
 public function messageContent(session:String,turn:String,item:String,token:String,offset:Int):Null<AgentContentChunk> {
  reads++;
  if (session!="alpha-0" || turn!="t" || item!="i" || token!="1" || offset!=0) return null;
  var bytes=haxe.io.Bytes.ofString("Complete response");
  return {token:token,offset:0,total:bytes.length,bytes:bytes,partial:false};
 }
}

private class FixtureProvider implements LocalAgentProvider {
 final kind:String;
 final entries:Array<AgentRecord>=[];
 public var creates=0;
 public var disposed=false;
 public function new(kind:String,count:Int) {
  this.kind=kind;
  for(i in 0...count) entries.push({id:kind+"-"+i,name:"Fixture",group:"work",cwd:"/work",thread:kind+"-"+i,state:"idle",turn:null,workspaceRoot:"/work",provider:kind});
 }
 public function driverKind():String return kind;
 public function nativeNamingSupported():Bool return false;
 public function summary():String return kind;
 public function owns(id:String):Bool {for(r in entries) if(r.id==id) return true;return false;}
 public function records():Array<AgentRecord> return entries.copy();
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void {
  creates++;for(r in entries) if(r.id==q.id) {ctx.respond(r);return;}
  throw "Unexpected fixture create side effect";
 }
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void throw "Unexpected fixture action";
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void throw "Unexpected fixture models";
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void throw "Unexpected fixture discovery";
 public function poll():Void {}
 public function activeCount():Int return 0;
 public function updateActivityCount():Int return 0;
 public function dispose():Void {disposed=true;}
}
