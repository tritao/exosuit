package app;

import workspace.provider.PiProvider;
import workspace.runtime.WorkspaceDirectories;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceService;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;

@:access(workspace.provider.AgentImageStaging)
class PiInputTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function largePng():haxe.io.Bytes {
  var original=sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"), length=2*1024*1024-original.length-12;
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
  PiClientInputTest.run();
  var args=Sys.args(),root=args[0],script=args[1],clock=function() return Sys.time()*1000;
  var processes=new ProcessManager(),dirs=new WorkspaceDirectories(root);
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/agents.sqlite","w",seed.snapshot(),32,root);
  var python=Sys.getEnv("EXOSUIT_TEST_PYTHON");if(python==null || python=="") python="python3";
  function build():workspace.provider.WorkspaceAgentService return new workspace.provider.WorkspaceAgentService("w", "owner", dirs.root, [new workspace.provider.CodexProvider("owner", dirs, function() return seed.snapshot().groups, processes, clock, store, "missing-codex", null, null), new PiProvider(dirs,function() return seed.snapshot().groups,processes,clock,root,store,python,script)], store,"pi-image-fixture");
  var provider=build(),pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  var value:Null<AgentView>=null,code="";
  function view():AgentView return cast value;
  function wait(done:Void->Bool):Void {
   var end=clock()+60000;
   while(!done()) {require(clock()<end,"Pi input timeout: "+(value == null ? "" : haxe.Json.stringify(value)));server.poll();provider.poll();client.poll();Sys.sleep(0.002);}
  }
  function action(kind:String,text:String="",?request:String,?imageIds:Array<String>):Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"pi",action:kind,text:text,request:request,imageIds:imageIds},5000,
    function(v) {value=v;done=true;},function(e) {code=e.code;done=true;});wait(function() return done);
  }
  function until(state:String):Void {wait(function() {action("read");return view().record.state==state;});}
  var created=false;
  client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"pi",name:"Pi",group:"work",thread:null,provider:"pi"},5000,
   function(_) created=true,function(e) throw e.message);wait(function() return created);until("idle");
  function upload(bytes:haxe.io.Bytes):String {
   var id:Null<String>=null,offset=0,done=false;
   function request(operation:String,chunk:Null<haxe.io.Bytes>):AgentImageUploadResult {
    var result:Null<AgentImageUploadResult>=null;done=false;
    client.call(WorkspaceAgentProtocol.IMAGE_UPLOAD,{workspace:"w",instance:"owner",session:"pi",operation:operation,upload:id,size:bytes.length,offset:offset,bytes:chunk},5000,
     function(value) {result=value;done=true;},function(e) throw e.message);
    wait(function() return done);return cast result;
   }
   var first=request("begin",null);id=first.upload;
   while(offset<bytes.length) {var n=Std.int(Math.min(32768,bytes.length-offset));var chunk=request("chunk",bytes.sub(offset,n));offset=chunk.offset;}
   request("finish",null);return cast id;
  }
  var png=largePng();require(png.length==2*1024*1024,"Maximum image fixture has wrong size");
  sys.io.File.saveBytes(root+"/expected-pi-image.png",png);
  var imageId=upload(png),secondImage=upload(png);
  require(view().supportsImageUpload==true,"Pi image capability missing");
  action("prompt","image echo 界\n\"quoted\"",null,[imageId,secondImage]);require(code=="","Pi image prompt failed: "+code);until("completed");
  var imageItems:Array<AgentActivityItem>=cast view().items;
  require([for(item in imageItems) if(item.kind=="userMessage" && item.images!=null && item.images.length==2 && item.images[0].id==imageId && item.images[1].id==secondImage) true].length==1,
   "Pi sent-image transcript identity missing");
  var imageOnly=upload(sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png"));
  action("prompt","",null,[imageOnly]);require(code=="","Image-only Pi prompt rejected");until("completed");
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
  var queuedImage=upload(png), steerImage=upload(png);
  var deferred=view().inputToken;action("queue","queue-after-restart",deferred,[queuedImage]);require(code=="","Image queue rejected");
  action("queue","queue-after-restart",deferred,[queuedImage]);require(code=="","Image queue retry not idempotent");
  action("queue","queue-after-restart",deferred,[steerImage]);require(code=="conflict","Image identity did not participate in idempotency");
  var lost=view().inputToken;action("steer","lost-steer",lost,[steerImage]);until("uncertain");
  require(view().queuePaused==true,"Transport loss did not pause queue");
  provider.dispose();client.close();server.close();
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  provider=build();provider.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  require(processes.activeCount()==0,"Restart relaunched Pi automatically");
  action("read");
  require([for(m in (cast view().pendingInputs:Array<AgentInputMessage>)) if(m.id==lost && m.state=="uncertain") true].length==1,"Uncertain delivery was lost");
  action("steer","lost-steer",lost,[steerImage]);require(code=="","Restart lost image idempotency receipt");
  action("connect");until("idle");require(view().queuePaused==true,"Restart/connect resumed pending queue");
  action("resume-queue");until("completed");
  require([for(item in (cast view().items:Array<AgentActivityItem>)) if(item.images!=null && item.images.length==1 && item.images[0].id==queuedImage) true].length>0,
   "Queued image did not survive restart and delivery");
  action("remove-input","",lost);require(code=="","Uncertain input could not be dismissed");
  action("prompt","wait");until("needs-attention");approval=view().requests[0].id;
  var missingImage=upload(sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png")), missingInput=view().inputToken;
  action("queue","missing image",missingInput,[missingImage]);require(code=="","Missing-image setup failed");
  var missingPath:Null<String>=null;
  for(name in sys.FileSystem.readDirectory(root)) if(StringTools.startsWith(name,"exosuit-agent-images-")) {
   var candidate=root+"/"+name+"/"+missingImage+".png";if(sys.FileSystem.exists(candidate)) missingPath=candidate;
  }
  require(missingPath!=null,"Could not find isolated staged image fixture");sys.FileSystem.deleteFile(cast missingPath);
  action("approve","",approval);
  wait(function() {action("read");return view().queuePaused==true && view().error!=null && view().error.indexOf("Queued image")>=0;});
  require([for(m in (cast view().pendingInputs:Array<AgentInputMessage>)) if(m.id==missingInput && m.state=="queued") true].length==1,
   "Unavailable queued image was silently discarded or delivered");
  action("remove-input","",missingInput);require(code=="","Unavailable queued image could not be removed");
  action("resume-queue");
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
