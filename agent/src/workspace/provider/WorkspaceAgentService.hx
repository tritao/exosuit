package workspace.provider;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceAgents;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentProtocol;

/** Workspace authorization, provider routing and resource limits; adapters own only their protocols. */
class WorkspaceAgentService implements WorkspaceAgents {
 final workspace:String;
 final instance:String;
 final root:String;
 final providers:Array<LocalAgentProvider>;
 final registry:Map<String,LocalAgentProvider> = [];
 public var status(get,never):String;
 function get_status():String return [for(provider in providers) provider.summary()].join("; ");

 public function new(workspace:String,instance:String,root:String,providers:Array<LocalAgentProvider>,?persistence:WorkspaceAgentPersistence) {
  this.workspace=workspace;this.instance=instance;this.root=root;this.providers=providers.copy();
  var identities:Map<String,Bool>=[];
  for(provider in providers) {
   var kind=provider.driverKind();
   if(kind == null || kind == "" || registry.exists(kind)) throw "Duplicate or invalid agent provider";
   registry.set(kind,provider);
   for(record in provider.records()) {
    if(identities.exists(record.id)) throw "Agent identity belongs to multiple providers";
    identities.set(record.id,true);
   }
  }
  if(persistence != null) for(record in persistence.loadAgents()) {
   var kind=record.provider == null ? "codex" : record.provider;
   if(!registry.exists(kind)) throw "Unknown persisted agent provider: " + kind;
  }
 }
 function owner(id:String):Null<LocalAgentProvider> {
  for(provider in providers) if(provider.owns(id)) return provider;
  return null;
 }
 function records():Array<AgentRecord> {
  var found:Array<AgentRecord>=[];
  for(provider in providers) found=found.concat(provider.records());
  return found;
 }
 public function bind(connection:RpcConnection,capabilities:Array<String>):Void {
  function allowed(w:String,i:String,control:Bool):Bool return w == workspace && i == instance
   && capabilities.contains(WorkspaceAgentProtocol.READ) && (!control || capabilities.contains(WorkspaceAgentProtocol.CONTROL));
  connection.register(WorkspaceAgentProtocol.LIST,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail({code:"unauthorized",message:"Agent catalog denied",ambiguous:false});return;}
   var found=records();
   found.sort(function(a,b) return Reflect.compare(a.id,b.id));
   found=[for(r in found) if(q.after == null || Reflect.compare(r.id,q.after)>0) r];
   var more=found.length>6;
   if(more) found.resize(6);
   ctx.respond({instance:instance,root:root,records:found,status:status,
    providers:[for(p in providers) p.driverKind()],next:more ? found[found.length-1].id : null});
  });
  connection.register(WorkspaceAgentProtocol.CREATE,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,true)) {ctx.fail({code:"unauthorized",message:"Agent creation denied",ambiguous:false});return;}
   if(q.id == null || q.id.length == 0 || q.id.length>128 || q.name == null || q.name.length == 0 || q.name.length>256) {
    ctx.fail({code:"invalid_request",message:"Invalid agent identity",ambiguous:false});return;
   }
   var kind=q.provider == null ? "codex" : q.provider;
   var provider=registry.get(kind);
   if(provider == null) {ctx.fail({code:"invalid_provider",message:"Unsupported agent provider",ambiguous:false});return;}
   var existing=owner(q.id);
   if(existing != null && existing != provider) {ctx.fail({code:"conflict",message:"Agent id belongs to another provider",ambiguous:false});return;}
   if(existing == null && records().length>=32) {ctx.fail({code:"limit",message:"Agent catalog is full",ambiguous:false});return;}
   provider.create(q,ctx);
  });
  connection.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,q.action != "read")) {ctx.fail({code:"unauthorized",message:"Agent operation denied",ambiguous:false});return;}
   var provider=owner(q.id);
   if(provider == null) {ctx.fail({code:"unknown_agent",message:"Unknown agent",ambiguous:false});return;}
   provider.action(q,ctx);
  });
  connection.register(WorkspaceAgentProtocol.MODELS,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail({code:"unauthorized",message:"Model catalog denied",ambiguous:false});return;}
   var provider=registry.get(q.provider == null ? "codex" : q.provider);
   if(provider == null) {ctx.fail({code:"invalid_provider",message:"Unsupported agent provider",ambiguous:false});return;}
   provider.modelCatalog(q,ctx);
  });
  connection.register(WorkspaceAgentProtocol.DISCOVER,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail({code:"unauthorized",message:"Session discovery denied",ambiguous:false});return;}
   var provider=registry.get(q.provider == null ? "codex" : q.provider);
   if(provider == null) {ctx.fail({code:"invalid_provider",message:"Unsupported agent provider",ambiguous:false});return;}
   provider.discover(q,ctx);
  });
 }
 public function poll():Void {for(p in providers) p.poll();}
 public function groupIsEmpty(group:String):Bool {
  for(r in records()) if(r.group == group) return false;
  return true;
 }
 public function activeCount():Int {
  var count=0;for(p in providers) count+=p.activeCount();return count;
 }
 public function updateActivityCount():Int {
  var count=0;for(p in providers) count+=p.updateActivityCount();return count;
 }
 public function dispose():Void {for(p in providers) p.dispose();}
}
