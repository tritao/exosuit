package app;

import haxe.Json;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;
import workspace.provider.CodexProvider;
import workspace.provider.WorkspaceAgentService;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceAgentProtocol;

/** Actual native adapter and proxy bridge, deterministic peer and isolated state. */
class CodexHistoryTest {
 static function require(ok:Bool,message:String):Void if (!ok) throw message;
 static function main():Void {
  var args=Sys.args(), root=args[0], python=args[1], bridge=args[2], script=args[3];
  var directories=new WorkspaceDirectories(root);root=directories.root;
  var source:Array<Dynamic>=[];
  var longMessage="Older source 界\n\n```haxe\n"+StringTools.rpad("", "x", 5000)+"\n```\n";
  for (i in 0...96) source.push({turnId:"history",completedAtMs:1,item:{id:"history-"+i,type:"agentMessage",text:i==8 ? longMessage : "Message "+i+" 界"}});
  sys.io.File.saveContent(root+"/history-fixture.json",Json.stringify(source));
  var threads:Dynamic={};
  Reflect.setField(threads,"history-thread",{id:"history-thread",cwd:root,status:{type:"idle"},turn:null});
  sys.io.File.saveContent(root+"/fake-codex.json",Json.stringify({threads:threads,starts:0,prompts:0}));
  var clock=function() return Sys.time()*1000, processes=new ProcessManager();
  var groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup>=[{id:"work",name:"Work",cwd:root,revision:1}];
  var adapter=new CodexProvider("owner",directories,function() return groups,processes,clock,null,python,bridge,script);
  var service=new WorkspaceAgentService("w","owner",directories.root,[adapter]);
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function pump():Void {server.poll();service.poll();client.poll();Sys.sleep(0.002);}
  function wait(done:Void->Bool):Void {
   var end=clock()+20000;
   while(!done()) {require(clock()<end,"Codex history fixture timed out: "+service.status);pump();}
  }
  var record:Null<AgentRecord>=null,code="";
  function create():Void {
   var done=false;code="";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"a",name:"History",group:"work",thread:"history-thread"},20000,
    function(r) {record=r;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);
  }
  create();require(code=="provider_starting","Codex did not report lazy startup");
  wait(function() return StringTools.startsWith(service.status,"Codex connected"));
  create();require(record!=null && code=="","Codex fixture did not create a session");
  var value:Null<AgentView>=null;
  function action(kind:String,?after:String):AgentView {
   var done=false;code="";value=null;
   client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"a",action:kind,text:"",request:null,after:after},20000,
    function(v) {value=v;done=true;},function(e) {code=e.code;done=true;});
   wait(function() return done);require(code=="" && value!=null,"Codex history action failed: "+kind+" "+code);
   return cast value;
  }
  function requests():Int {
   var count=0,path=root+"/history-requests.jsonl";
   if (sys.FileSystem.exists(path)) for (line in sys.io.File.getContent(path).split("\n")) if (line!="") {
    var request:Dynamic=Json.parse(line);if(Reflect.field(request,"method")=="thread/items/list") count++;
   }
   return count;
  }
  var first=action("read");
  require(first.items!=null && first.items.length==8 && first.itemsNext!=null,"Attached history page is incomplete");
  var initial=requests();require(initial==1,"Attach eagerly fetched native history: "+initial);
  var cursor:String=cast first.itemsNext, epoch=first.historyEpoch, second=action("read",cursor);
  require(second.items!=null && second.items.length==8 && second.itemsNext!=null && second.historyEpoch==epoch,
   "Older page lost its native continuation or epoch");
  require(requests()==initial+1,"Explicit older read did not fetch exactly one native page");
  var repeated=action("read",cursor);
  require(Json.stringify(second.items)==Json.stringify(repeated.items) && requests()==initial+1,"Repeated native cursor was not idempotent");
  var older:Array<AgentActivityItem>=cast second.items;
  var message:Null<AgentActivityItem>=null;
  for (item in older) if (item.id=="history-8") message=item;
  require(message!=null && message.truncated && message.contentToken!=null,"Older message lost its full-source handle");
  var retainedMessage:AgentActivityItem=cast message;
  var full:Null<AgentContentChunk>=null,contentDone=false;
  client.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"w",instance:"owner",session:"a",turn:"history",item:"history-8",token:retainedMessage.contentToken,offset:0},5000,
   function(chunk) {full=chunk;contentDone=true;},function(e) throw e.message);
  wait(function() return contentDone);
  var fullReply:AgentContentChunk=cast full;
  var fullBytes:haxe.io.Bytes=cast fullReply.bytes;
  require(fullBytes.toString()==longMessage,"Older native page full source was clipped or changed");
  var next=second.itemsNext,seen:Map<String,Bool>=[];
  while(next!=null) {
   var requested:String=cast next;require(!seen.exists(requested),"Native history cursor cycled");seen.set(requested,true);
   next=action("read",requested).itemsNext;
  }
  require(requests()==12,"Native history did not advance one page at a time");
  var refetched=action("read",cursor),refetchedItems:Array<AgentActivityItem>=cast refetched.items;
  require(requests()==13 && refetchedItems[0].id==older[0].id,"Evicted page could not be re-fetched from native history");
  require(action("read").itemsNext==first.itemsNext,"Older paging changed the newest history boundary");
  service.dispose();client.close();server.close();processes.shutdown();
  Sys.println("PASS: native Codex lazy attachment, demand paging, cursor idempotency and stable epoch");
 }
}
