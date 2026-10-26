package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceAgentProtocol;

/** A second submission must use fresh admission metadata even while old history pages are still loading. */
class PiClientInputTest {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run():Void {
  var clock=function() return 1000.0,pair=MemoryTransport.pair(),connection=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var sequence=0,accepted=0,pending:Null<haxeon.rpc.RpcContext<AgentView>>=null;
  function view(token:String,more:Bool):AgentView return {
   record:{id:"a",name:"Pi",group:"work",cwd:"/fixture",thread:"thread",state:"working",turn:"turn",workspaceRoot:"/fixture",provider:"pi"},
   activity:"",requests:[],error:null,items:[],itemsNext:more ? "0:8" : null,inputToken:token
  };
  server.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   if(q.after!=null) {pending=ctx;return;}
   if(q.action=="read") {ctx.respond(view("token-0",false));return;}
   if(q.text=="reject") {ctx.fail({code:"busy",message:"Keep the draft",ambiguous:false});return;}
   require(q.request=="token-"+sequence,"Submission reused a token while history was loading");
   sequence++;ctx.respond(view("token-"+sequence,sequence==1));
  });
  var client=new workspace.client.RpcWorkspaceWorkbenchClient(new PiClientEndpoint(connection),clock);
  client.poll();client.agentAction("a","read","",null);server.poll();connection.poll();
  client.agentAction("a","queue","first",null,null,null,function() accepted++);server.poll();connection.poll();server.poll();
  require(pending!=null && accepted==1,"Fixture did not hold the first action's history page");
  client.agentAction("a","queue","second",null,null,null,function() accepted++);server.poll();connection.poll();
  require(sequence==2 && accepted==2,"A slow history page blocked or lost the second submission");
  pending.respond(view("stale-token",false));connection.poll();
  var current=client.agentView("a");
  require(current!=null && current.inputToken=="token-2","Stale history overwrote the current input token");
  client.agentAction("a","queue","reject",null,null,null,function() accepted++);server.poll();connection.poll();
  require(accepted==2 && client.agentError()=="Keep the draft","A rejected submission was reported as accepted");
  client.dispose();connection.close();server.close();
  Sys.println("PASS: fresh Pi admission tokens during slow history loading, stale-page fencing and rejected-draft retention");
 }
}

private class PiClientEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/fixture";
 public function serviceGeneration():String return "test";
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function rpcConnection():Null<RpcConnection> return connection;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return false;
 public function workspaceEpoch():Null<String> return null;
 public function hasCapability(value:String):Bool return value==WorkspaceAgentProtocol.READ || value==WorkspaceAgentProtocol.CONTROL;
}
