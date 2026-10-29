package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol;
import workspace.client.AgentSnapshotAssembler;

@:access(workspace.client.RpcWorkspaceWorkbenchClient)
class AgentSnapshotClientTest {
 static function require(ok:Bool,message:String):Void if (!ok) throw message;
 static function view(token:String,activity:String):AgentView return {
  record:{id:"a",name:"Pi",group:"work",cwd:"/fixture",thread:"thread",state:"idle",turn:null,workspaceRoot:"/fixture",provider:"pi"},
  activity:activity,requests:[],error:null,items:[],inputToken:token
 };
 static function main():Void {
  var clock=function() return 1000.0, pair=MemoryTransport.pair(), conn=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  var endpoint=new SnapshotEndpoint(conn), client=new workspace.client.RpcWorkspaceWorkbenchClient(endpoint,clock);
  client.poll();
  client.agentCatalog={instance:"test",root:"/fixture",records:[],status:"ready",supportsSnapshots:true};
  client.agentViews.set("a",view("token-0","old"));
  var accepted=0, actions=0, held:Null<RpcContext<AgentSnapshotReply>>=null, bytesByToken:Map<String,Bytes>=[];
  var longText="x"; for (_ in 0...17) longText+=longText;
  server.register(WorkspaceAgentProtocol.ACTION_SNAPSHOT,function(q,ctx) {
   actions++;
   if (q.text == "scope") {ctx.respond({session:"other",root:"/fixture",token:null,total:0,offset:0,bytes:null,inputToken:null,snapshotError:"unavailable"});return;}
   if (q.text == "reject") {ctx.fail({code:"busy",message:"Rejected",ambiguous:false});return;}
   if (q.text == "unavailable") {ctx.respond({session:"a",root:"/fixture",token:null,total:0,offset:0,bytes:null,inputToken:"token-2",snapshotError:"unavailable"});return;}
   var token=q.text == "first" ? "one" : "two", admission=q.text == "first" ? "token-1" : "token-2";
   var result=view(admission,q.text == "first" ? longText : "newer");
   if (q.text == "page") {result.itemsNext="0:8"; result.items=[{id:"new",turn:"t",kind:"agentMessage",title:"",text:"new",detail:"",state:"completed",truncated:false}];}
   if (q.after != null) result.items=[{id:"old",turn:"t",kind:"agentMessage",title:"",text:"old",detail:"",state:"completed",truncated:false}];
   var data=MessagePack.encode(result); bytesByToken.set(token,data);
   var count=Std.int(Math.min(AgentSnapshotAssembler.MAX_CHUNK,data.length));
   ctx.respond({session:"a",root:"/fixture",token:token,total:data.length,offset:0,bytes:data.sub(0,count),inputToken:admission,snapshotError:null});
  });
  server.register(WorkspaceAgentProtocol.SNAPSHOT_READ,function(q,ctx) {
   if (q.token == "one") {held=ctx;return;}
   var data:Bytes=cast bytesByToken.get(q.token), n=Std.int(Math.min(AgentSnapshotAssembler.MAX_CHUNK,data.length-q.offset));
   ctx.respond({session:"a",root:"/fixture",token:q.token,total:data.length,offset:q.offset,bytes:data.sub(q.offset,n),inputToken:null,snapshotError:null});
  });
  client.agentAction("a","queue","first",null,null,null,function() accepted++);
  server.poll();conn.poll();
  var current:AgentView=cast client.agentView("a");
  require(accepted==1 && !client.agentBusy() && current.inputToken=="token-1", "Action was not acknowledged before snapshot assembly");
  server.poll();require(held!=null,"Snapshot did not request a subsequent chunk");
  client.agentAction("a","queue","second",null,null,null,function() accepted++);
  server.poll();conn.poll();
  current=cast client.agentView("a");
  require(accepted==2 && current.activity=="newer", "New action did not preempt a slow snapshot");
  var original:Bytes=cast bytesByToken.get("one"), n=Std.int(Math.min(AgentSnapshotAssembler.MAX_CHUNK,original.length-AgentSnapshotAssembler.MAX_CHUNK));
  held.respond({session:"a",root:"/fixture",token:"one",total:original.length,offset:AgentSnapshotAssembler.MAX_CHUNK,
   bytes:original.sub(AgentSnapshotAssembler.MAX_CHUNK,n),inputToken:null,snapshotError:null}); conn.poll();
  current=cast client.agentView("a"); require(current.activity=="newer", "Stale snapshot replaced the new view");
  client.agentAction("a","prompt","unavailable",null,null,null,function() accepted++);server.poll();conn.poll();
  current=cast client.agentView("a"); var error:String=cast client.agentError();
  require(accepted==3 && error.indexOf("Action completed")>=0 && current.inputToken=="token-2", "Post-ack snapshot failure lost acceptance or admission token");
  client.agentAction("a","prompt","reject",null,null,null,function() accepted++);server.poll();conn.poll();
  require(accepted==3 && client.agentError()=="Rejected" && actions==4, "Rejected action was acknowledged or replayed");
  client.agentAction("a","prompt","scope",null,null,null,function() accepted++);server.poll();conn.poll();
  require(accepted==3 && actions==5, "Invalid snapshot scope acknowledged an action");
  client.agentAction("a","prompt","page",null,null,null,function() accepted++);server.poll();conn.poll();
  current=cast client.agentView("a");
  require(accepted==4 && current.items != null && current.items.length==1 && client.agentHistory("a").hasOlder, "Initial snapshot did not publish only its first page");
  var pageError:Null<String>="pending";
  client.loadOlderAgentItems("a",function(error) pageError=error); server.poll();conn.poll();
  current=cast client.agentView("a");
  require(pageError==null && current.items != null && current.items.length==2 && current.items[0].id=="old", "Explicit snapshot history page did not aggregate in order");
  var imageBytes=Bytes.alloc(70000);for (i in 0...imageBytes.length) imageBytes.set(i,i%251);
  var imageReads=0, loaded:Null<Bytes>=null, imageError:Null<String>="pending";
  server.register(WorkspaceAgentProtocol.MESSAGE_IMAGE,function(q,ctx) {
   require(q.session=="a" && q.turn=="t" && q.item=="old" && q.token=="opaque", "Image read lost its item scope");
   imageReads++;var count=Std.int(Math.min(24*1024,imageBytes.length-q.offset));
   ctx.respond({token:q.token,offset:q.offset,total:imageBytes.length,bytes:imageBytes.sub(q.offset,count),partial:false});
  });
  client.loadAgentImage("a","t","old","opaque",function(bytes,error) {loaded=bytes;imageError=error;});
  for (_ in 0...5) {server.poll();conn.poll();}
  require(imageError==null && loaded!=null && (cast loaded:Bytes).compare(imageBytes)==0 && imageReads==3,"Sent image chunks did not assemble exactly");
  client.agentAction("a","prompt","generation",null,null,null,function() accepted++);server.poll();
  endpoint.generation="changed";conn.poll();client.poll();
  require(accepted==4 && !client.agentBusy(), "Changed service generation acknowledged stale action or left it busy");
  var data=MessagePack.encode(view("z",longText)), first:AgentSnapshotReply={session:"a",root:"/fixture",token:"snap",total:data.length,offset:0,
   bytes:data.sub(0,AgentSnapshotAssembler.MAX_CHUNK),inputToken:null,snapshotError:null};
  var assembler=new AgentSnapshotAssembler(first,"a","/fixture"), wrong=false;
  try assembler.add({session:"a",root:"/fixture",token:"different",total:data.length,offset:assembler.offset,bytes:Bytes.alloc(1),inputToken:null,snapshotError:null}) catch (_:Dynamic) wrong=true;
  require(wrong,"Changed snapshot token was accepted");
  wrong=false; try assembler.add({session:"a",root:"/fixture",token:"snap",total:data.length,offset:0,bytes:Bytes.alloc(1),inputToken:null,snapshotError:null}) catch (_:Dynamic) wrong=true;
  require(wrong,"Repeated snapshot offset was accepted");
  while (!assembler.complete()) {
   var offset=assembler.offset, count=Std.int(Math.min(AgentSnapshotAssembler.MAX_CHUNK,data.length-offset));
   assembler.add({session:"a",root:"/fixture",token:"snap",total:data.length,offset:offset,bytes:data.sub(offset,count),inputToken:null,snapshotError:null});
  }
  require(assembler.view().activity==longText,"Large view was not assembled losslessly");
  client.dispose();conn.close();server.close();
  for (mode in ["token","offset","total","oversize","generation","connection","session"]) malformedImage(mode);
  AgentHistoryClientTest.run();
  disposalDuringSnapshot();
  realServiceRoundTrip();
  Sys.println("PASS: negotiated snapshot acknowledgement, stale fencing, errors and bounded assembly");
 }
 static function malformedImage(mode:String):Void {
  var clock=function() return 1000.0,pair=MemoryTransport.pair(),conn=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var endpoint=new SnapshotEndpoint(conn),client=new workspace.client.RpcWorkspaceWorkbenchClient(endpoint,clock);
  client.poll();client.agentCatalog={instance:"test",root:"/fixture",records:[],status:"ready"};client.agentViews.set("a",view("token",""));
  var held:Null<RpcContext<AgentContentChunk>>=null,callbacks=0,error:Null<String>=null,result:Null<Bytes>=null;
  server.register(WorkspaceAgentProtocol.MESSAGE_IMAGE,function(q,ctx) {
   if(q.offset==0 && (mode=="generation" || mode=="connection" || mode=="session")) {held=ctx;return;}
   if(q.offset==0) {ctx.respond({token:"image",offset:0,total:30000,bytes:Bytes.alloc(24576),partial:false});return;}
   ctx.respond({token:mode=="token" ? "other" : "image",offset:mode=="offset" ? q.offset+1 : q.offset,
    total:mode=="total" ? 30001 : mode=="oversize" ? 2*1024*1024+1 : 30000,bytes:Bytes.alloc(5424),partial:false});
  });
  client.loadAgentImage("a","turn","item","image",function(bytes,message) {callbacks++;result=bytes;error=message;});
  server.poll();conn.poll();
  if(held!=null) {
   if(mode=="generation") endpoint.generation="replacement";
   if(mode=="connection") endpoint.conn=null;
   if(mode=="session") client.agentViews.remove("a");
   var pending:RpcContext<AgentContentChunk>=cast held;
   var payload:AgentContentChunk={token:"image",offset:0,total:1,bytes:Bytes.alloc(1),partial:false};
   require(pending.respond(payload) && !pending.respond(payload),"Provider delivered duplicate completion");
   conn.poll();
  } else {server.poll();conn.poll();}
  require(callbacks==1 && result==null && error!=null,"Invalid or stale sent image accepted: "+mode);
  client.dispose();conn.close();server.close();
 }
 static function disposalDuringSnapshot():Void {
  var clock=function() return 1000.0, pair=MemoryTransport.pair();
  var conn=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  var client=new workspace.client.RpcWorkspaceWorkbenchClient(new SnapshotEndpoint(conn),clock), accepted=0;
  client.poll(); client.agentCatalog={instance:"test",root:"/fixture",records:[],status:"ready",supportsSnapshots:true};
  var longText="x"; for (_ in 0...16) longText+=longText;
  var data=MessagePack.encode(view("queue",longText));
  var held:Null<RpcContext<AgentSnapshotReply>>=null;
  server.register(WorkspaceAgentProtocol.ACTION_SNAPSHOT,function(_,ctx) ctx.respond({session:"a",root:"/fixture",token:"pending",total:data.length,offset:0,
    bytes:data.sub(0,AgentSnapshotAssembler.MAX_CHUNK),inputToken:"queue",snapshotError:null}));
  server.register(WorkspaceAgentProtocol.SNAPSHOT_READ,function(_,ctx) held=ctx);
  client.agentAction("a","prompt","hello",null,null,null,function() accepted++);
  server.poll();conn.poll();server.poll();
  require(accepted==1 && held != null && conn.pendingCalls()==1,"Disposal fixture did not hold a snapshot chunk");
  client.dispose();
  var count=Std.int(Math.min(AgentSnapshotAssembler.MAX_CHUNK,data.length-AgentSnapshotAssembler.MAX_CHUNK));
  held.respond({session:"a",root:"/fixture",token:"pending",total:data.length,offset:AgentSnapshotAssembler.MAX_CHUNK,
    bytes:data.sub(AgentSnapshotAssembler.MAX_CHUNK,count),inputToken:null,snapshotError:null});
  conn.poll();
  require(accepted==1 && client.agentView("a")==null && conn.pendingCalls()==0 && server.activeRequests()==0,
   "Disposed client accepted a late snapshot, replayed acknowledgement, or retained the completed RPC");
  conn.close();server.close();
 }
 static function realServiceRoundTrip():Void {
  var clock=function() return 1000.0, pair=MemoryTransport.pair(), limit=65492;
  var conn=new RpcConnection(pair.client,clock,limit), server=new RpcConnection(pair.server,clock,limit);
  var provider=new SnapshotProvider(), service=new workspace.provider.WorkspaceAgentService("workspace","test","/fixture",[provider]);
  service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var endpoint=new SnapshotEndpoint(conn), client=new workspace.client.RpcWorkspaceWorkbenchClient(endpoint,clock), accepted=0;
  client.poll(); client.refreshAgents(); server.poll(); conn.poll();
  require(client.agentCatalog != null && client.agentCatalog.supportsSnapshots == true,"Real service did not negotiate snapshots");
  client.agentAction("a","prompt","test",null,null,null,function() accepted++);
  server.poll(); conn.poll();
  require(accepted==1 && provider.mutations==1 && client.agentView("a") == null,"Real service did not acknowledge before the full snapshot");
  for (_ in 0...40) {server.poll();conn.poll();}
  require(provider.historyReads==0 && client.agentHistory("a").hasOlder,"Real service loaded old history without a request");
  var olderError:Null<String>="pending";
  client.loadOlderAgentItems("a",function(error) olderError=error);
  for (_ in 0...40) {server.poll();conn.poll();}
  require(olderError==null,"Real service older history did not finish");
  var actual:AgentView=cast client.agentView("a"), expected=provider.expected();
  var older:Array<AgentActivityItem>=[provider.oldItem()], newer:Array<AgentActivityItem>=cast expected.items;
  expected.items=older.concat(newer); expected.itemsNext=null;
  require(actual != null && MessagePack.encode(actual).compare(MessagePack.encode(expected))==0, "Real RPC lost snapshot fields, Unicode or paged history");
  require(accepted==1 && provider.mutations==1 && provider.historyReads==1,"Real RPC replayed a mutation or missed the activity cursor");
  require(MessagePack.encode(expected).length > limit,"Real snapshot fixture did not exceed the relay limit");
  client.dispose();service.dispose();conn.close();server.close();
 }
}
private class SnapshotProvider implements workspace.provider.LocalAgentProvider {
 public var mutations=0; public var historyReads=0;
 final record:AgentRecord={id:"a",name:"Pi",group:"work",cwd:"/fixture",thread:"thread",state:"idle",turn:null,workspaceRoot:"/fixture",provider:"pi"};
 public function new() {}
 public function driverKind():String return "pi";
 public function nativeNamingSupported():Bool return false;
 public function summary():String return "fixture";
 public function owns(id:String):Bool return id == "a";
 public function records():Array<AgentRecord> return [record];
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void ctx.respond(record);
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void ctx.fail({code:"unsupported",message:"unused",ambiguous:false});
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void ctx.fail({code:"unsupported",message:"unused",ambiguous:false});
 public function oldItem():AgentActivityItem return {id:"older",turn:"t",kind:"agentMessage",title:"Pi",text:"earlier 雪",detail:"",state:"completed",truncated:false};
 public function expected():AgentView {
  var text="雪é"; for (_ in 0...9) text+=text;
  var models:Array<AgentModel>=[]; for (i in 0...64) models.push({model:"provider/model-"+i,name:"Model 雪 "+i,supportedEfforts:["low","high"]});
  var commands:Array<AgentCommand>=[]; for (i in 0...96) commands.push({name:"command"+i,description:text.substr(0,256),kind:"command",invocation:"/command"+i,scope:"project"});
  var native:Array<AgentNativeInput>=[]; for (i in 0...32) native.push({kind:"queue",text:text.substr(0,1024),truncated:false});
  return {record:record,activity:"legacy diagnostics 雪",requests:[{id:"approval",method:"item/tool/requestUserInput",detail:"Please choose 雪",reviewable:true}],error:null,
   items:[{id:"newer",turn:"t",kind:"agentMessage",title:"Pi",text:text.substr(0,2048),detail:"",state:"completed",truncated:false}],itemsNext:"0:8",
   models:models,modelsNext:null,currentModel:"provider/model-1",currentEffort:"high",commands:commands,commandsLoading:false,
   inputToken:"queue-token",pendingInputs:[{id:"q",kind:"queue",text:"queued 雪",fingerprint:"fixture",state:"queued"}],queuePaused:false,
   nativePending:native,inputBusy:false,supportsSteering:true,supportsQueue:true};
 }
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void {
  if(q.after != null) {historyReads++;var page=expected();page.items=[oldItem()];page.itemsNext=null;ctx.respond(page);return;}
  if(q.action != "read") mutations++; ctx.respond(expected());
 }
 public function poll():Void {}
 public function activeCount():Int return 0;
 public function updateActivityCount():Int return 0;
 public function dispose():Void {}
}
private class SnapshotEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 public var conn:Null<RpcConnection>;
 public var generation:String="test";
 public function new(conn:RpcConnection) this.conn=conn;
 public function rootPath():Null<String> return "/fixture";
 public function serviceGeneration():String return generation;
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function rpcConnection():Null<RpcConnection> return conn;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return false;
 public function workspaceEpoch():Null<String> return null;
 public function hasCapability(value:String):Bool return value==WorkspaceAgentProtocol.READ || value==WorkspaceAgentProtocol.CONTROL;
}
