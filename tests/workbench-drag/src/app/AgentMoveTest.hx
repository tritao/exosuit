package app;

import workspace.provider.*;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceAgentPersistence;
import workspace.runtime.WorkspaceDirectories;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;

/** Exercises the real authorized RPC route and durable metadata for every provider, without launching CLIs. */
class AgentMoveTest {
 static function require(ok:Bool, why:String):Void {if (!ok) throw why;}
 public static function run():Void {
  var directories = new WorkspaceDirectories(Sys.getCwd());
  var groups:Array<WorkspaceGroup> = [{id:"one",name:"One",parent:null,cwd:null,revision:1},
   {id:"two",name:"Two",parent:null,cwd:null,revision:1}];
  for (kind in ["codex","claude","pi"]) {
   var initial:AgentRecord = {id:"agent",name:"Agent",group:"one",cwd:directories.root,workspaceRoot:directories.root,
    thread:kind == "pi" ? "" : "12345678-1234-1234-1234-123456789abc",state:"disconnected",turn:null,
    provider:kind,permissionMode:kind == "claude" ? "default" : "supervised"};
   var store = new AgentMoveStore(initial);
   var processes = new ProcessManager();
   var clock = function() return Sys.time() * 1000;
   function make():LocalAgentProvider return switch(kind) {
    case "codex": new CodexProvider("owner",directories,function() return groups,processes,clock,store);
    case "claude": new ClaudeProvider(directories,function() return groups,processes,clock,store);
    default: new PiProvider(directories,function() return groups,processes,clock,directories.root,store);
   };
   var service = new WorkspaceAgentService("w","owner",directories.root,[make()],store);
   var pair = MemoryTransport.pair();
   var client = new RpcConnection(pair.client,clock), server = new RpcConnection(pair.server,clock);
   function bind(control:Bool):Void {
    client.close();server.close();
    var next=MemoryTransport.pair();client=new RpcConnection(next.client,clock);server=new RpcConnection(next.server,clock);
    service.bind(server,control ? [WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL] : [WorkspaceAgentProtocol.READ]);
   }
   bind(true);
   var advertised:Null<AgentCatalog> = null;
   client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},1000,
    function(catalog) advertised=catalog,function(error) throw error.message);
   server.poll();client.poll();
   require(advertised != null && advertised.canMove == true && advertised.canRename == true,kind+" omitted move support negotiation");
   var value:Null<AgentView> = null, code = "";
   function action(kind:String,expected:String,target:String,?order:Int):Void {
    value=null;code="";
    client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:"agent",action:kind,text:target,request:expected,order:order},1000,
     function(result) value=result,function(error) code=error.code);
    server.poll();client.poll();
   }
   function move(expected:String,target:String):Void action("move",expected,target);
   function rename(expected:String,name:String):Void action("rename",expected,name);
   move("one","two");
   require(value != null && value.record.group=="two" && store.record.group=="two",kind+" did not persist move");
   require(store.record.cwd==initial.cwd && store.record.thread==initial.thread,kind+" altered native identity");
   rename("Agent","  Plan α  ");
   require(value != null && value.record.name=="Plan α" && store.record.name=="Plan α",kind+" did not persist normalized rename");
   require(store.record.cwd==initial.cwd && store.record.thread==initial.thread && store.record.group=="two",kind+" rename changed session identity");
   rename("Agent","Stale");require(code=="conflict",kind+" accepted stale name");
   for (invalid in ["  ","bad\nname","bad\tname",StringTools.rpad("x","x",257)]) {
    rename("Plan α",invalid);require(code=="invalid_name" && store.record.name=="Plan α",kind+" accepted invalid name");
   }
   move("one","one");require(code=="conflict",kind+" accepted a stale source");
   move("two","missing");require(code=="unknown_group",kind+" accepted missing destination");
   service.dispose();
   service = new WorkspaceAgentService("w","owner",directories.root,[make()],store);
   bind(false);
   move("two","one");require(code=="unauthorized" && store.record.group=="two",kind+" allowed read-only move");
   rename("Plan α","Denied");require(code=="unauthorized",kind+" allowed read-only rename");
   bind(true);
   move("two","one");require(value != null && value.record.group=="one",kind+" lost grouping across restart");
   require(value != null && value.record.name=="Plan α",kind+" lost renamed session across restart");
   // A move names the position too, and may stay in the same group to re-order; no order leaves the position alone.
   require(store.record.order==null,kind+" placed a session nobody ordered");
   action("move","one","one",3);
   require(value != null && value.record.order==3 && store.record.order==3 && store.record.group=="one",kind+" did not persist an order within its group");
   action("move","one","one",-1);require(code=="invalid_order" && store.record.order==3,kind+" accepted a negative order");
   action("move","one","one",WorkspaceProtocol.MAX_ORDER+1);require(code=="invalid_order" && store.record.order==3,kind+" accepted an order past the limit");
   action("move","one","two",1);
   require(store.record.group=="two" && store.record.order==1,kind+" did not place a session in the group it moved to");
   action("move","two","one");
   require(store.record.group=="one" && store.record.order==1,kind+" lost its position when moved without one");
   action("move","one","one",3);
   store.fail=true;action("move","one","one",9);
   require(code=="storage_unavailable" && store.record.order==3,kind+" kept an order it could not save");
   store.fail=false;service.dispose();
   service=new WorkspaceAgentService("w","owner",directories.root,[make()],store);bind(true);
   var listed:Null<AgentCatalog>=null;
   client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},1000,function(catalog) listed=catalog,function(error) throw error.message);
   server.poll();client.poll();
   require(listed != null && listed.records.length==1 && listed.records[0].order==3,kind+" lost its position across restart");
   store.fail=true;move("one","two");require(code=="storage_unavailable" && store.record.group=="one",kind+" accepted failed storage");
   store.fail=false;service.dispose();
   service=new WorkspaceAgentService("w","owner",directories.root,[make()],store);bind(true);
   store.fail=true;rename("Plan α","Unsaved");
   require(code=="storage_unavailable" && store.record.name=="Plan α",kind+" accepted failed rename persistence");
   client.close();server.close();service.dispose();processes.shutdown();
  }
  trace("PASS: Codex, Claude and Pi move and rename RPC authorization, validation, conflicts, persistence, restart and storage failure");
 }
}

private class AgentMoveStore implements WorkspaceAgentPersistence {
 public var record:AgentRecord;
 public var fail=false;
 public function new(record:AgentRecord) this.record=copy(record);
 function copy(value:AgentRecord):AgentRecord return cast Reflect.copy(value);
 public function loadAgents():Array<AgentRecord> return [copy(record)];
 public function saveAgent(value:AgentRecord):Void {if(fail) throw "storage failure";record=copy(value);}
 public function removeAgent(id:String):Void throw "unexpected removal";
}
