package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import workspace.service.WorkspaceAgentProtocol;
import workspace.client.AgentHistoryWindow;

@:access(workspace.client.RpcWorkspaceWorkbenchClient)
class AgentHistoryClientTest {
 static function require(ok:Bool,message:String):Void if (!ok) throw message;
 static function items(view:AgentView):Array<AgentActivityItem> return cast view.items;
 static function item(i:Int):AgentActivityItem return {id:Std.string(i),turn:"turn",kind:"agentMessage",title:"Pi",text:"message "+i,detail:"",state:"completed",truncated:false};
 static function page(start:Int,end:Int,next:Null<String>,epoch:String="epoch-1"):AgentView return {
  record:{id:"a",name:"Pi",group:"work",cwd:"/fixture",thread:"thread",state:"idle",turn:null,workspaceRoot:"/fixture",provider:"pi"},
  activity:"",requests:[],error:null,items:[for(i in start...end) item(i)],itemsNext:next,historyEpoch:epoch
 };
 public static function run():Void {
  var clock=function() return 1000.0,pair=MemoryTransport.pair(),conn=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var endpoint=new HistoryEndpoint(conn),client=new workspace.client.RpcWorkspaceWorkbenchClient(endpoint,clock);
  var latest=page(8,16,"older-one"), pages:Map<String,AgentView>=[], held:Null<RpcContext<AgentView>>=null, hold=false, pageReads=0;
  var older=page(0,8,null); items(older)[0].state="inProgress"; pages.set("older-one",older);
  server.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   if(q.after == null) ctx.respond(latest);
   else {pageReads++; if(hold) held=ctx; else {var p=pages.get(q.after); if(p == null) ctx.fail({code:"invalid_cursor",message:"invalid",ambiguous:false}); else ctx.respond(p);} }
  });
  client.poll();
  function pump():Void {server.poll();conn.poll();}
  client.agentAction("a","read","",null);pump();
  var current:AgentView=cast client.agentView("a");
  require(items(current).length==8 && pageReads==0 && client.agentHistory("a").hasOlder,"First page was not published independently");
  var result:Null<String>="pending"; client.loadOlderAgentItems("a",function(error) result=error);pump();
  current=cast client.agentView("a");
  require(result==null && items(current).length==16 && items(current)[0].id=="0" && pageReads==1,"Explicit page was not prepended exactly once");
  pages.set("older-one",page(0,8,null));
  client.agentAction("a","read","",null);pump();pump();
  current=cast client.agentView("a");
  require(items(current)[0].state=="completed" && pageReads==2,"Older in-progress activity did not receive its terminal update");
  client.agentAction("a","read","",null);pump();
  require(pageReads==2,"Completed retained activity caused unnecessary history reads");
  latest=page(14,22,"bridge-14");client.agentAction("a","read","",null);pump();
  current=cast client.agentView("a");
  require(items(current).length==22 && items(current)[0].id=="0" && items(current)[21].id=="21","Live refresh dropped retained history or new activity");
  latest=page(30,38,"bridge-30"); pages.set("bridge-30",page(22,30,"bridge-22"));pages.set("bridge-22",page(14,22,"bridge-14"));
  client.agentAction("a","read","",null);pump();pump();pump();
  current=cast client.agentView("a");
  require(items(current).length==38 && items(current)[0].id=="0" && items(current)[37].id=="37" && !client.agentHistory("a").resetRequired,
   "Burst bridge did not preserve contiguous history");
  latest=page(90,94,null,"epoch-2");client.agentAction("a","read","",null);pump();
  current=cast client.agentView("a");
  require(items(current)[0].id=="0" && client.agentHistory("a").resetRequired,"Epoch change silently discarded the reading window");
  client.resetAgentHistory("a");current=cast client.agentView("a");
  require(items(current)[0].id=="90" && !client.agentHistory("a").resetRequired,"Reset did not synchronously restore latest");
  latest=page(300,308,"opaque-cycle","epoch-3");client.agentAction("a","read","",null);pump();client.resetAgentHistory("a");
  pages.set("opaque-cycle",page(292,300,"opaque-cycle","epoch-3"));result="pending";
  client.loadOlderAgentItems("a",function(error) result=error);pump();
  require(result!=null && client.agentHistory("a").resetRequired,"Repeated opaque cursor was accepted");
  client.resetAgentHistory("a"); hold=true;result="pending";
  client.loadOlderAgentItems("a",function(error) result=error);server.poll();
  require(held!=null && client.agentHistory("a").loading,"Older page did not remain pending");
  client.agentAction("a","prompt","hi",null);pump();
  require(result!=null && !client.agentHistory("a").loading,"Mutation failed to preempt pending history");
  (cast held:RpcContext<AgentView>).respond(page(292,300,null,"epoch-3"));conn.poll();
  current=cast client.agentView("a");require(items(current)[0].id=="300","Late preempted page overwrote the view");
  hold=false; latest=page(256,264,"range-248","epoch-4");client.agentAction("a","read","",null);pump();client.resetAgentHistory("a");
  for (n in 0...32) {
   var start=248-n*8, next=start==0 ? null : "range-"+(start-8);
   pages.set("range-"+start,page(start,start+8,next,"epoch-4"));
   result="pending";client.loadOlderAgentItems("a",function(error) result=error);pump();
   require(result==null,"Bounded history page failed");
  }
  current=cast client.agentView("a");
  require(client.agentHistory("a").detached && items(current).length==256 && items(current)[0].id=="0" && items(current)[255].id=="255",
   "History window did not slide predictably on explicit older paging");
  latest=page(260,268,"range-252","epoch-4");client.agentAction("a","read","",null);pump();
  current=cast client.agentView("a");require(items(current)[0].id=="0" && items(current)[255].id=="255","Live refresh displaced a detached reader");
  client.resetAgentHistory("a");current=cast client.agentView("a");
  require(items(current)[0].id=="260" && items(current)[7].id=="267" && !client.agentHistory("a").detached,"Reset lost live messages while detached");
  var many:Array<AgentActivityItem>=[];for(i in 0...256) many.push(item(i));
  require(AgentHistoryWindow.within(many),"A normal 256-item history should fit");many.push(item(256));
  require(!AgentHistoryWindow.within(many),"History item bound was not enforced");
  client.dispose();conn.close();server.close();
  Sys.println("PASS: incremental history, live bridge, opaque cursor, reset and preemption");
 }
}
private class HistoryEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final conn:RpcConnection;
 public function new(conn:RpcConnection) this.conn=conn;
 public function rootPath():Null<String> return "/fixture";
 public function serviceGeneration():String return "test";
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function rpcConnection():Null<RpcConnection> return conn;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return false;
 public function workspaceEpoch():Null<String> return null;
 public function hasCapability(value:String):Bool return value==WorkspaceAgentProtocol.READ || value==WorkspaceAgentProtocol.CONTROL;
}
