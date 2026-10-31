package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.TerminalHistory;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceTerminalProtocol;

/** The terminal service keeps a terminal's position among its siblings: it is set with a rename or move, bounded, and survives a restart. */
class TerminalOrderTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var root=Sys.getCwd();
  var store=new OrderTerminalStore({id:"term",name:"Shell",group:"work",cwd:root,instance:"before",state:"exited",
   exitCode:0,available:false,revision:Int64.ofInt(1),workspaceRoot:root});
  var groups:Array<WorkspaceProtocol.WorkspaceGroup>=[{id:"work",name:"Work",cwd:null,revision:1},{id:"other",name:"Other",cwd:null,revision:1}];
  var manager=new WorkspaceTerminalManager("w","owner",root,65536,store,function() { return groups; });
  var clock=function() { return Sys.time()*1000; };
  var pair=MemoryTransport.pair();
  var client=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CATALOG,WorkspaceTerminalProtocol.CONTROL]);
  var code="", answered:Null<TerminalRecord>=null;
  function rename(group:String,?order:Int):Void {
   var current=store.record;code="";answered=null;
   client.call(WorkspaceTerminalProtocol.RENAME,{workspace:"w",instance:"owner",id:"term",name:current.name,group:group,
    expectedRevision:current.revision,order:order},1000,function(record) {answered=record;},function(error) {code=error.code;});
   server.poll();client.poll();
  }
  require(store.record.order==null && manager.snapshot().terminals[0].order==null,"a terminal nobody ordered has a position");
  rename("work",4);
  require(answered!=null && answered.order==4 && store.record.order==4 && store.record.group=="work","terminal order was not saved with a rename");
  rename("work");
  require(answered!=null && answered.order==4 && store.record.order==4,"a rename without an order lost the position");
  rename("other",1);
  require(answered!=null && answered.group=="other" && answered.order==1 && store.record.order==1,"terminal move did not carry its position");
  rename("work",-1);require(code=="invalid_request" && store.record.order==1 && store.record.group=="other","negative terminal order accepted");
  rename("work",WorkspaceProtocol.MAX_ORDER+1);require(code=="invalid_request" && store.record.order==1,"terminal order past the limit accepted");
  rename("work",WorkspaceProtocol.MAX_ORDER);require(answered!=null && store.record.order==WorkspaceProtocol.MAX_ORDER,"terminal order at the limit refused");
  rename("work",2);
  client.close();server.close();manager.dispose();
  manager=new WorkspaceTerminalManager("w","restarted",root,65536,store,function() { return groups; });
  require(manager.snapshot().terminals[0].order==2 && manager.snapshot().terminals[0].group=="work","terminal position lost across a restart");
  manager.dispose();
  trace("PASS: terminal service saves, bounds and keeps a terminal's position among its siblings");
 }
}

private class OrderTerminalStore implements WorkspaceTerminalPersistence {
 public var record:TerminalRecord;
 public function new(record:TerminalRecord) this.record=record;
 public function loadTerminals():Array<TerminalRecord> return [record];
 public function saveTerminal(value:TerminalRecord):Void record=value;
 public function removeTerminal(id:String):Void throw "unexpected removal";
 public function hasTerminalHistory(id:String):Bool return false;
 public function loadTerminalHistory(id:String):Null<TerminalHistory> return null;
 public function saveTerminalHistory(id:String,history:TerminalHistory):Void {}
}
