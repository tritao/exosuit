package app;

import haxe.io.Bytes;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.rpc.MemoryTransport;
import haxeon.wire.MessagePack;
import workspace.provider.AgentSnapshotCache;
import workspace.provider.LocalAgentProvider;
import workspace.provider.WorkspaceAgentService;
import workspace.service.WorkspaceAgentProtocol;

class AgentSnapshotTest {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run():Void {
  var now=0.0, serial=0;
  var cache=new AgentSnapshotCache("/work",function() return now,function() return "token-"+(++serial));
  var big=Bytes.alloc(70000);
  var first=cache.create("s",big,"input");
  var firstBytes:Bytes=cast first.bytes;
  require(first.snapshotError == null && firstBytes.length == AgentSnapshotCache.CHUNK,"Snapshot first chunk");
  require(cache.read("other",first.token,AgentSnapshotCache.CHUNK)==null,"Cross-session snapshot accepted");
  require(cache.read("s",first.token,1)==null,"Invalid snapshot offset accepted");
  now=31;require(cache.read("s",first.token,AgentSnapshotCache.CHUNK)==null,"Idle snapshot did not expire");
  var handles=[];for(_ in 0...4) handles.push(cache.create("s",big,null));
  require(cache.create("s",big,null).snapshotError != null,"Snapshot handle quota bypassed");
  now=62;cache.clean();require(cache.create("s",big,null).snapshotError == null,"Expired quota not released");
  cache.clear();require(cache.create("s",Bytes.alloc(AgentSnapshotCache.MAX_BYTES+1),null).snapshotError != null,"Oversized snapshot accepted");

  var provider=new SnapshotFixtureProvider(),service=new WorkspaceAgentService("w","owner","/work",[provider]);
  var pair=MemoryTransport.pair(),clock=function() return Sys.time()*1000;
  var machine=noisekit.NoiseSession.generateKeypair(),device=noisekit.NoiseSession.generateKeypair();
  var prologue=workspace.transport.NoisePrologue.encode("0123456789abcdef0123456789abcdef","fedcba9876543210fedcba9876543210");
  var securedClient:Null<workspace.transport.NoiseMessageTransport>=null,securedServer:Null<workspace.transport.NoiseMessageTransport>=null;
  var machineHandshake=new workspace.transport.NoiseServerHandshake(pair.server,machine.privateKey,device.publicKey,prologue,clock,
   function(transport) securedServer=transport);
  var deviceHandshake=new workspace.transport.NoiseClientHandshake(pair.client,device.privateKey,machine.publicKey,prologue,clock,
   function(transport) securedClient=transport);
  for (_ in 0...12) {machineHandshake.poll();deviceHandshake.poll();}
  require(securedClient != null && securedServer != null,"Snapshot test Noise authentication failed");
  var limit=workspace.transport.NoiseMessageTransport.MAX_PLAINTEXT_BYTES;
  var client=new RpcConnection(cast securedClient,clock,limit,32,1048576),server=new RpcConnection(cast securedServer,clock,limit,32,1048576);
  service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var response:Null<AgentSnapshotReply>=null, failure:Null<String>=null;
  client.call(WorkspaceAgentProtocol.ACTION_SNAPSHOT,{workspace:"w",instance:"owner",id:"s",action:"prompt",text:"hello",request:null},5000,
   function(r) response=r,function(e) failure=e.code);
  server.poll();client.poll();require(response != null && failure == null && provider.calls==1 && response.inputToken=="admitted","Mutation acknowledgement lost");
  var initial:AgentSnapshotReply=cast response;
  var encodedReply=MessagePack.encode(initial);
  var envelope=haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Response(1,encodedReply),65492);
  require(envelope.length <= workspace.transport.NoiseMessageTransport.MAX_PLAINTEXT_BYTES,"Snapshot reply exceeds encrypted relay frame");
  require(!provider.duplicateAccepted,"Provider completed snapshot action twice");
  var total=initial.total, token:String=cast initial.token, data=Bytes.alloc(total), chunk:Bytes=cast initial.bytes, offset=chunk.length;
  data.blit(0,chunk,0,chunk.length);
  while(offset<total) {
   var reply:Null<AgentSnapshotReply>=null;
   client.call(WorkspaceAgentProtocol.SNAPSHOT_READ,{workspace:"w",instance:"owner",session:"s",token:token,offset:offset},5000,
    function(r) reply=r,function(e) throw e.message);
   server.poll();client.poll();require(reply != null,"Snapshot chunk missing");
   var part:AgentSnapshotReply=cast reply;
   require(part.offset==offset && part.total==total && part.token==token,"Snapshot chunk mismatch");
   var partBytes:Bytes=cast part.bytes;
   data.blit(offset,partBytes,0,partBytes.length);offset+=partBytes.length;
  }
  var view:AgentView=MessagePack.decode(data);
  require(view.activity==provider.activity && provider.calls==1,"Reassembled view changed or mutation repeated");
  failure=null;
  client.call(WorkspaceAgentProtocol.SNAPSHOT_READ,{workspace:"w",instance:"owner",session:"s",token:token,offset:AgentSnapshotCache.CHUNK},5000,
   function(_) throw "Completed handle retained",function(e) failure=e.code);
  server.poll();client.poll();require(failure=="snapshot_unavailable","Stale snapshot accepted");
  failure=null;
  client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"s",action:"read",text:"",request:null},5000,
   function(_) throw "Oversized legacy reply accepted",function(e) failure=e.code);
  server.poll();client.poll();require(failure=="snapshot_too_large","Legacy oversize did not fail explicitly");
  failure=null;
  client.call(WorkspaceAgentProtocol.ACTION_SNAPSHOT,{workspace:"other",instance:"owner",id:"s",action:"prompt",text:"",request:null},5000,
   function(_) throw "Unauthorized mutation accepted",function(e) failure=e.code);
  server.poll();client.poll();require(failure=="unauthorized" && provider.calls==2,"Unauthorized mutation reached provider");
  service.dispose();client.close();server.close();
  for (index in 0...machine.privateKey.length) machine.privateKey.set(index,0);
  for (index in 0...device.privateKey.length) device.privateKey.set(index,0);
  Sys.println("PASS: encrypted bounded snapshot action, reassembly, authorization, expiry and legacy oversize");
 }
}
private class SnapshotFixtureProvider implements LocalAgentProvider {
 public var calls=0;
 public var duplicateAccepted=false;
 public var activity=StringTools.rpad("", "x", 70000);
 final record:AgentRecord={id:"s",name:"Fixture",group:"work",cwd:"/work",thread:"t",state:"idle",turn:null,workspaceRoot:"/work",provider:"fixture"};
 public function new() {}
 public function driverKind():String return "fixture";
 public function nativeNamingSupported():Bool return false;
 public function summary():String return "fixture";
 public function owns(id:String):Bool return id=="s";
 public function records():Array<AgentRecord> return [record];
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void {
  calls++;var view:AgentView={record:record,activity:activity,requests:[],error:null,inputToken:"admitted"};
  ctx.respond(view);duplicateAccepted=ctx.respond(view);
 }
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void throw "unused";
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void throw "unused";
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void throw "unused";
 public function poll():Void {}
 public function activeCount():Int return 0;
 public function updateActivityCount():Int return 0;
 public function dispose():Void {}
}
