package app;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.rpc.MemoryTransport;
import workspace.provider.LocalAgentProvider;
import workspace.provider.WorkspaceAgentService;
import workspace.service.WorkspaceAgentProtocol;

/** Routing boundaries exercised without depending on any vendor CLI or provider order. */
class AgentServiceTest {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run():Void {
  var alpha=new FixtureProvider("alpha",31),beta=new FixtureProvider("beta",1);
  var service=new WorkspaceAgentService("w","owner","/work",[alpha,beta]);
  var clock=function() return Sys.time()*1000;
  var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
  function create(kind:String,id:String):String {
   var code="pending";
   client.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:id,name:"Fixture",group:"work",thread:null,provider:kind},1000,
    function(_) code="ok",function(error) code=error.code);
   server.poll();client.poll();return code;
  }
  require(create("beta","new")=="limit" && beta.creates==0,"Global catalog limit was not enforced across providers");
  require(create("beta","alpha-0")=="conflict" && beta.creates==0,"Cross-provider resource identity was routed incorrectly");
  require(create("missing","new")=="invalid_provider","Unknown provider was silently substituted");
  require(create("alpha","alpha-0")=="ok" && alpha.creates==1,"Idempotent creation was blocked by global capacity");
  var catalog:Null<AgentCatalog>=null;
  client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},1000,function(r) catalog=r,function(error) throw error.message);
  server.poll();client.poll();
  require(catalog!=null && catalog.records.length==6 && catalog.next!=null,"Combined catalog pagination failed");
  var duplicate=false;
  try new WorkspaceAgentService("w","owner","/work",[alpha,alpha]) catch(_:Dynamic) duplicate=true;
  require(duplicate,"Duplicate provider registration was accepted");
  var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock),denied=false;
  service.bind(roServer,[WorkspaceAgentProtocol.READ]);
  ro.call(WorkspaceAgentProtocol.CREATE,{workspace:"w",instance:"owner",id:"alpha-0",name:"Fixture",group:"work",thread:null,provider:"alpha"},1000,
   function(_) throw "Read-only create was accepted",function(error) denied=error.code=="unauthorized");
  roServer.poll();ro.poll();require(denied && alpha.creates==1,"Authorization did not fence the adapter side effect");
  service.dispose();require(alpha.disposed && beta.disposed,"Service lifecycle did not reach every adapter");
  client.close();server.close();ro.close();roServer.close();
  Sys.println("PASS: provider-neutral routing, combined limits/pagination, cross-provider identity and authorization");
 }
}

private class FixtureProvider implements LocalAgentProvider {
 final kind:String;
 final entries:Array<AgentRecord>=[];
 public var creates=0;
 public var disposed=false;
 public function new(kind:String,count:Int) {
  this.kind=kind;
  for(i in 0...count) entries.push({id:kind+"-"+i,name:"Fixture",group:"work",cwd:"/work",thread:kind+"-"+i,state:"idle",turn:null,workspaceRoot:"/work",provider:kind});
 }
 public function driverKind():String return kind;
 public function summary():String return kind;
 public function owns(id:String):Bool {for(r in entries) if(r.id==id) return true;return false;}
 public function records():Array<AgentRecord> return entries.copy();
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void {
  creates++;for(r in entries) if(r.id==q.id) {ctx.respond(r);return;}
  throw "Unexpected fixture create side effect";
 }
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void throw "Unexpected fixture action";
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void throw "Unexpected fixture models";
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void throw "Unexpected fixture discovery";
 public function poll():Void {}
 public function activeCount():Int return 0;
 public function updateActivityCount():Int return 0;
 public function dispose():Void {disposed=true;}
}
