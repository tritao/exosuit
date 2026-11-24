package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.*;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.transport.RpcCalls;

class TerminalCloseServiceTests {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run(root:String):Void {
  var seed=new WorkspaceService("w","e",[{id:"work",name:"Work",cwd:root,revision:1}]);
  var store=new WorkspaceSqliteStore(root+"/close-contract.sqlite","w",seed.snapshot(),root);
  var clock=function() return Sys.time()*1000;
  var manager=TestTerminals.manager("w","owner",root,65536,store,function() return seed.snapshot().groups,"close");
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
  function step():Void {server.poll();manager.poll();client.poll();Sys.sleep(0.002);}
  function wait(done:Void->Bool):Void {var deadline=clock()+5000;while(!done()) {require(clock()<deadline,"terminal close contract timed out");step();}}
  function record(id:String):TerminalRecord {
   for(value in manager.snapshot().terminals) if(value.id==id) return value;
   throw "missing terminal "+id;
  }
  function open(id:String):TerminalRecord {
   var done=false;
   RpcCalls.call(client, WorkspaceTerminalProtocol.OPEN,{workspace:"w",instance:"owner",id:id,create:true,columns:80,rows:24},1000,
    function(_) done=true,function(error) throw error.message);wait(function() return done);return record(id);
  }
  var target=open("close-target"),other=open("close-other"),code="",done=false;
  function remove(value:TerminalRecord,terminate:Bool):Void {
   code="";done=false;
   RpcCalls.call(client, WorkspaceTerminalProtocol.FORGET,{workspace:"w",instance:"owner",id:value.id,resourceInstance:value.instance,expectedRevision:value.revision,terminate:terminate},1000,
    function(_) done=true,function(error) {code=error.code;done=true;});wait(function() return done);
  }
  require(manager.activeCount()==2,"terminal fixtures did not start");
  remove(target,false);require(code=="terminal_running" && manager.activeCount()==2,"ordinary forget terminated live terminal");
  var stale:TerminalRecord=cast Reflect.copy(target);stale.revision+=1;
  remove(stale,true);require(code=="stale_revision" && manager.activeCount()==2,"stale close killed a terminal");
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock);
  manager.bind(roServer,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CATALOG]);
  var denied=false;
  RpcCalls.call(ro, WorkspaceTerminalProtocol.FORGET,{workspace:"w",instance:"owner",id:target.id,resourceInstance:target.instance,expectedRevision:target.revision,terminate:true},1000,
   function(_) throw "read-only close succeeded",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied && manager.activeCount()==2,"read-only close stopped a terminal");
  remove(target,true);
  require(code=="" && manager.activeCount()==1 && manager.snapshot().terminals.length==1 && record(other.id).state=="running","close did not stop/remove exactly its target");
  require(store.loadTerminals().length==1,"close retained the terminal's record");
  remove(target,true);require(code=="" && manager.activeCount()==1,"repeated close affected another terminal");
  client.close();server.close();ro.close();roServer.close();manager.dispose();store.close();
  // A terminal the next daemon took back from its host: Close ends it and removes it.
  store=new WorkspaceSqliteStore(root+"/close-contract.sqlite","w",seed.snapshot(),root);
  manager=TestTerminals.manager("w","next-owner",root,65536,store,function() return seed.snapshot().groups,"close");
  pair=MemoryTransport.pair();client=new RpcConnection(pair.client,clock);server=new RpcConnection(pair.server,clock);
  manager.bind(server,[WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
  var archived=record(other.id);done=false;code="";
  RpcCalls.call(client, WorkspaceTerminalProtocol.FORGET,{workspace:"w",instance:"next-owner",id:archived.id,resourceInstance:archived.instance,expectedRevision:archived.revision,terminate:true},1000,
   function(_) done=true,function(error) {done=true;code=error.code;});wait(function() return done);
  require(code=="" && manager.snapshot().terminals.length==0 && store.loadTerminals().length==0,"archived terminal remained after close");
  client.close();server.close();manager.dispose();store.close();
  trace("PASS: Close Terminal stops one live process, removes its entry, closes a terminal taken back by the next service and checks revision, permissions and idempotency");
 }
}
