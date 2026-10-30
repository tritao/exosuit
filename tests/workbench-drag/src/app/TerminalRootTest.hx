package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.TerminalHistory;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceTerminalProtocol;

/** The terminal service keeps a terminal in the workspace root (no group) across a restart and moves it in and out. */
class TerminalRootTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var root=Sys.getCwd();
  var store=new RootTerminalStore({id:"term",name:"Shell",group:WorkspaceProtocol.ROOT_GROUP,cwd:root,instance:"before",state:"exited",
   exitCode:0,available:false,revision:Int64.ofInt(1),workspaceRoot:root});
  var groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup>=[{id:"work",name:"Work",cwd:null,revision:1}];
  var manager=new WorkspaceTerminalManager("w","owner",root,65536,store,function() { return groups; });
  var clock=function() { return Sys.time()*1000; };
  var pair=MemoryTransport.pair();
  var client=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CATALOG,WorkspaceTerminalProtocol.CONTROL]);
  var moved:Array<String>=[], code="";
  function move(group:String):Void {
   var current=store.record;
   client.call(WorkspaceTerminalProtocol.RENAME,{workspace:"w",instance:"owner",id:"term",name:current.name,group:group,
    expectedRevision:current.revision},1000,function(record) {moved.push(record.group);},function(error) {code=error.code;});
   server.poll();client.poll();
  }
  require(manager.snapshot().terminals.length==1,"a stored terminal in the workspace root was dropped on load");
  move("work");move(WorkspaceProtocol.ROOT_GROUP);move("missing");
  require(moved.join(",")=="work," && store.record.group==WorkspaceProtocol.ROOT_GROUP,"terminal did not move in and out of the workspace root");
  require(code=="invalid_request","terminal moved to an unknown group");
  client.close();server.close();manager.dispose();
  trace("PASS: terminal service loads, keeps and moves terminals in the workspace root");
 }
}

private class RootTerminalStore implements WorkspaceTerminalPersistence {
 public var record:TerminalRecord;
 public function new(record:TerminalRecord) this.record=record;
 public function loadTerminals():Array<TerminalRecord> return [record];
 public function saveTerminal(value:TerminalRecord):Void record=value;
 public function removeTerminal(id:String):Void throw "unexpected removal";
 public function hasTerminalHistory(id:String):Bool return false;
 public function loadTerminalHistory(id:String):Null<TerminalHistory> return null;
 public function saveTerminalHistory(id:String,history:TerminalHistory):Void {}
}
