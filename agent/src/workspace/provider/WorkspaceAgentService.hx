package workspace.provider;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceAgents;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentProtocol;

/**
 * Workspace authorization, provider routing and resource limits; adapters own only their protocols.
 *
 * Providers are built when first needed: a session of theirs is created, listed or acted on, or their models or
 * sessions are asked for. A workspace whose agents are all terminals builds none, and the image staging folder is made
 * only for the first image.
 */
@:access(haxeon.rpc.RpcConnection)
class WorkspaceAgentService implements WorkspaceAgents {
 final workspace:String;
 final instance:String;
 final root:String;
 final factories:Array<AgentProviderFactory>;
 /** Built providers, in the order of `factories`. */
 final providers:Array<LocalAgentProvider> = [];
 final registry:Map<String,LocalAgentProvider> = [];
 /** The provider of each saved session, read once at start. */
 final saved:Map<String,String> = [];
 final imageStorageIdentity:Null<String>;
 var staging:Null<AgentImageStaging>;
 public var status(get,never):String;
 function get_status():String return [for(provider in providers) provider.summary()].join("; ");

 public function new(workspace:String,instance:String,root:String,factories:Array<AgentProviderFactory>,?persistence:WorkspaceAgentPersistence, ?imageStorageIdentity:String) {
  this.workspace=workspace;this.instance=instance;this.root=root;this.factories=factories.copy();this.imageStorageIdentity=imageStorageIdentity;
  var kinds:Map<String,Bool>=[];
  for(factory in factories) {
   if(factory.kind == null || factory.kind == "" || kinds.exists(factory.kind)) throw "Duplicate or invalid agent provider";
   kinds.set(factory.kind,true);
  }
  // A record of a provider this build does not have (the built-in agent, removed 2026-11-15) is left in the store
  // unread: the service starts without it.
  if(persistence != null) for(record in persistence.loadAgents()) {
   var kind=record.provider == null ? "codex" : record.provider;
   if(!kinds.exists(kind)) Sys.stderr().writeString("Agent " + record.id + " skipped: no provider \"" + kind + "\" in this build\n");
   else saved.set(record.id,kind);
  }
  for(factory in factories) if(factory.existing != null) provider(factory.kind);
 }
 /** The provider of `kind`, built now if it was not; null for a kind this service does not have. */
 function provider(kind:String):Null<LocalAgentProvider> {
  var built=registry.get(kind);
  if(built != null) return built;
  for(factory in factories) if(factory.kind == kind) {
   built=factory.build();
   registry.set(kind,built);
   providers.resize(0);
   for(f in factories) { var p=registry.get(f.kind); if(p != null) providers.push(p); }
   attachImages(built);
   return built;
  }
  return null;
 }
 /** The image staging folder, made (and locked) when an image is first uploaded, sent or shown. */
 function images():AgentImageStaging {
  var existing=staging;
  if(existing != null) return existing;
  var stageLock:Null<app.AgentNative.AgentLockHandle> = null;
  var made = new AgentImageStaging(imageBase(), root + "\n" + imageStorageIdentity, app.AgentNative.randomToken, Sys.time,
   app.AgentNative.prepareDirectory, app.AgentNative.privateFile,
   function(path) { stageLock = app.AgentNative.acquireLock(path); return stageLock != null; },
   function() { if (stageLock != null) { app.AgentNative.releaseLock(stageLock); stageLock = null; } });
  staging=made;
  return made;
 }
 /** Where images are staged; null when this service stages none (no storage identity, no temporary folder). */
 function imageBase():Null<String> {
  if (imageStorageIdentity == null || imageStorageIdentity == "") return null;
  var tempBase = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : Sys.getEnv("TMPDIR");
  return tempBase == null && Sys.systemName() != "Windows" ? "/tmp" : tempBase;
 }
 function attachImages(provider:LocalAgentProvider):Void {
  var available=imageBase() != null;
  if (Std.isOfType(provider, CodexProvider)) {
   var codex:CodexProvider = cast provider;
   codex.imageUploadAvailable = available;
   codex.imageIdentity = function(session,turn,item,path) return images().archive(session,turn,item,path);
  }
  if(Std.isOfType(provider,PiProvider)) {
   var pi:PiProvider=cast provider;
   pi.imageUploadAvailable=available;
   pi.imagePrepare=function(session,ids,turn,item) return images().piImages(session,ids,turn,item);
   pi.imageHold=function(session,thread,turn,item,ids) return images().holdInput(session,thread,turn,item,ids);
  }
  if(Std.isOfType(provider,ClaudeProvider)) {
   var claude:ClaudeProvider=cast provider;
   claude.imageUploadAvailable=available;
   claude.imagePrepare=function(session,ids,turn,item) return images().piImages(session,ids,turn,item);
   claude.imageHold=function(session,thread,turn,item,ids) return images().holdInput(session,thread,turn,item,ids);
  }
 }
 function owner(id:Null<String>):Null<LocalAgentProvider> {
  // A request without an id names no session (Map.get(null) would crash natively).
  if(id == null) return null;
  for(provider in providers) if(provider.owns(id)) return provider;
  var kind=saved.get(id);
  if(kind == null || registry.exists(kind)) return null;
  var built=provider(kind);
  return built != null && built.owns(id) ? built : null;
 }
 public function requestCounts():Map<String,Int> {
  var counts = new Map<String,Int>();
  for(provider in providers) {
   var source:Null<AgentRequestCounts> = Std.isOfType(provider, AgentRequestCounts) ? cast provider : null;
   if(source != null) for(id=>waiting in source.requestCounts()) counts.set(id,waiting);
  }
  return counts;
 }
 /** Every session; a provider with saved sessions is built to list them. */
 public function records():Array<AgentRecord> {
  for(kind in saved) if(!registry.exists(kind)) provider(kind);
  var found:Array<AgentRecord>=[];
  for(provider in providers) found=found.concat(provider.records());
  return found;
 }
 public function bind(connection:RpcConnection,capabilities:Array<String>):Void {
  function allowed(w:String,i:String,control:Bool):Bool return w == workspace && i == instance
   && capabilities.contains(WorkspaceAgentProtocol.READ) && (!control || capabilities.contains(WorkspaceAgentProtocol.CONTROL));
  connection.register(WorkspaceAgentProtocol.LIST,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail(new RpcError("unauthorized", "Agent catalog denied", false));return;}
   var found=records();
   found.sort(function(a,b) return Reflect.compare(a.id,b.id));
   found=[for(r in found) if(q.after == null || Reflect.compare(r.id,q.after)>0) r];
   var more=found.length>6;
   if(more) found.resize(6);
   ctx.respond({instance:instance,root:root,records:found,status:status,
    canMove:true,canRename:true,nativeRenameProviders:[for(p in providers) if(p.nativeNamingSupported()) p.driverKind()],providers:[for(f in factories) f.kind],next:more ? found[found.length-1].id : null});
  });
  connection.register(WorkspaceAgentProtocol.CREATE,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,true)) {ctx.fail(new RpcError("unauthorized", "Agent creation denied", false));return;}
   if(q.id == null || q.id.length == 0 || q.id.length>128 || q.name == null || q.name.length == 0 || q.name.length>256) {
    ctx.fail(new RpcError("invalid_request", "Invalid agent identity", false));return;
   }
   var kind=q.provider == null ? "codex" : q.provider;
   var provider=provider(kind);
   if(provider == null) {ctx.fail(new RpcError("invalid_provider", "Unsupported agent provider", false));return;}
   var existing=owner(q.id);
   if(existing != null && existing != provider) {ctx.fail(new RpcError("conflict", "Agent id belongs to another provider", false));return;}
   if(existing == null && records().length>=32) {ctx.fail(new RpcError("limit", "Agent catalog is full", false));return;}
   provider.create(q,ctx);
  });
  function action(q:AgentAction,ctx:haxeon.rpc.RpcContext<AgentView>):Void {
   if(!allowed(q.workspace,q.instance,q.action != "read")) {ctx.fail(new RpcError("unauthorized", "Agent operation denied", false));return;}
   var provider=owner(q.id);
   if(provider == null) {ctx.fail(new RpcError("unknown_agent", "Unknown agent", false));return;}
   if (q.imageIds != null && q.imageIds.length > 0) {
    if(Std.isOfType(provider,ClaudeProvider)) {
     if(q.action!="prompt") {ctx.fail(new RpcError("unsupported_operation", "This Claude action cannot attach images", false));return;}
     provider.action(q,ctx);return;
    }
    if(Std.isOfType(provider,PiProvider)) {
     if(q.action!="prompt" && q.action!="queue" && q.action!="steer") {ctx.fail(new RpcError("unsupported_operation", "This Pi action cannot attach images", false));return;}
     provider.action(q,ctx);return;
    }
    if (q.action != "prompt" || !Std.isOfType(provider, CodexProvider)) {ctx.fail(new RpcError("unsupported_operation", "This provider does not support image attachments", false));return;}
    var paths = images().resolve(q.id, q.imageIds);
    if (paths == null) {ctx.fail(new RpcError("image_unavailable", "An image expired or is unavailable. Remove it and upload it again.", false));return;}
    (cast provider:CodexProvider).actionWithImages(q,ctx,paths,function(thread) return images().pin(q.id,thread,q.imageIds)); return;
   }
   provider.action(q,ctx);
  }
  // A view is one page of a session (8 items, each cut to a few KiB). Over a forwarded stream (about 64 KiB) a page of
  // long or non-ASCII texts can still be too large: `fitted` cuts its texts further, so one reply always carries it.
  connection.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) action(q,new FittedViewContext(ctx,function(view) return fitted(view,connection.maxMessageBytes - 1024))));
  connection.register(WorkspaceAgentProtocol.MESSAGE_CONTENT,function(q,ctx) {
   if (!allowed(q.workspace,q.instance,false)) {ctx.fail(new RpcError("unauthorized", "Message content denied", false));return;}
   if (q.session == null || q.session.length == 0 || q.session.length > 128 || q.turn == null || q.item == null || q.token == null
       || q.turn.length > 128 || q.item.length > 512 || q.token.length > 32 || q.offset < 0) {
    ctx.fail(new RpcError("content_unavailable", "Message content is unavailable", false));return;
   }
   var provider=owner(q.session);
   if (provider == null || !Std.isOfType(provider,AgentMessageSource)) {
    ctx.fail(new RpcError("content_unavailable", "Message content is unavailable", false));return;
   }
   var source:AgentMessageSource = cast provider;
   var chunk=source.messageContent(q.session,q.turn,q.item,q.token,q.offset);
   if (chunk == null) ctx.fail(new RpcError("content_unavailable", "Message content changed or is no longer available", false));
   else ctx.respond(chunk);
  });
  connection.register(WorkspaceAgentProtocol.IMAGE_UPLOAD,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,true)) {ctx.fail(new RpcError("unauthorized", "Image upload denied", false));return;}
   var provider = owner(q.session);
   if (provider == null || (!Std.isOfType(provider,CodexProvider) && !Std.isOfType(provider,PiProvider) && !Std.isOfType(provider,ClaudeProvider))) {ctx.fail(new RpcError("unsupported_operation", "Image upload is unavailable for this session", false));return;}
   try ctx.respond(images().process(q)) catch (error:Dynamic) {
    var message = Std.string(error);
    var safe = ["Image staging requires recovery; check the workspace service", "Invalid session", "Image must be at most 2 MiB",
     "Image staging quota reached; wait for abandoned uploads to expire or reconcile the session", "Could not create image identity",
     "Image upload expired or is unavailable", "Invalid image upload chunk", "Image upload is incomplete",
     "Choose a valid PNG, JPEG, or GIF image up to 4096 pixels per side", "Could not stage image"];
    ctx.fail(new RpcError("invalid_image_upload", safe.indexOf(message) >= 0 ? message : "Image staging failed; retry or check the workspace service", false));
   }
  });
  connection.register(WorkspaceAgentProtocol.MESSAGE_IMAGE,function(q,ctx) {
   if (!allowed(q.workspace,q.instance,false)) {ctx.fail(new RpcError("unauthorized", "Image access denied", false));return;}
   if (q.session == null || q.turn == null || q.item == null || q.token == null || q.session.length > 128
       || q.turn.length > 128 || q.item.length > 128 || q.token.length > 256 || q.offset < 0 || owner(q.session) == null) {
    ctx.fail(new RpcError("image_unavailable", "Sent image is unavailable", false));return;
   }
   var chunk=images().readArchive(q.session,q.turn,q.item,q.token,q.offset);
   if (chunk == null) ctx.fail(new RpcError("image_unavailable", "Sent image is no longer available", false));
   else ctx.respond(chunk);
  });
  connection.register(WorkspaceAgentProtocol.MODELS,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail(new RpcError("unauthorized", "Model catalog denied", false));return;}
   var provider=provider(q.provider == null ? "codex" : q.provider);
   if(provider == null) {ctx.fail(new RpcError("invalid_provider", "Unsupported agent provider", false));return;}
   provider.modelCatalog(q,ctx);
  });
  connection.register(WorkspaceAgentProtocol.DISCOVER,function(q,ctx) {
   if(!allowed(q.workspace,q.instance,false)) {ctx.fail(new RpcError("unauthorized", "Session discovery denied", false));return;}
   var provider=provider(q.provider == null ? "codex" : q.provider);
   if(provider == null) {ctx.fail(new RpcError("invalid_provider", "Unsupported agent provider", false));return;}
   provider.discover(q,ctx);
  });
 }
 /**
  `view` with its items' texts cut (halving their length each round) until its reply fits in `bytes`; a cut item is
  marked truncated, and MESSAGE_CONTENT reads it whole. The provider's own items are not changed.
 */
 static function fitted(view:AgentView,bytes:Int):AgentView {
  var items=view.items;
  if(items == null || WorkspaceAgentProtocol.ACTION.encodeResponse(view).length <= bytes) return view;
  var limit=2048;
  while(limit >= 32) {
   view.items=[for(item in items) item.text.length <= limit && item.detail.length <= limit ? item : {
    id:item.id,turn:item.turn,kind:item.kind,title:item.title,text:item.text.substr(0,limit),detail:item.detail.substr(0,limit),
    state:item.state,truncated:true,files:item.files,contentToken:item.contentToken,images:item.images,imagePath:item.imagePath,
    contentDigest:item.contentDigest
   }];
   if(WorkspaceAgentProtocol.ACTION.encodeResponse(view).length <= bytes) return view;
   limit=Std.int(limit/2);
  }
  return view;
 }
 public function poll():Void {
  for(p in providers) p.poll();
  var made=staging;
  if(made != null) made.clean(function(id) return owner(id) != null, function(id, thread) {
   var provider=owner(id);
   if (provider == null) return true; // An orphaned pinned lease has no proof that the native turn finished.
   if(Std.isOfType(provider,PiProvider) && (cast provider:PiProvider).hasHeldImages(id)) return true;
   for (record in provider.records()) if (record.id == id)
    return record.thread != thread || record.state == "working" || record.state == "needs-attention" || record.state == "uncertain"
     || record.state == "disconnected" || record.state == "reconnecting" || record.state == "reconnect-failed";
   return true;
  });
 }
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
 public function dispose():Void {for(p in providers) p.dispose(); var made=staging; if(made != null) made.dispose();}
}

/** Hands the view a provider answers ACTION with through `fit` before it is sent; cancellation and failure pass through. */
private class FittedViewContext extends haxeon.rpc.RpcContext<AgentView> {
 final source:haxeon.rpc.RpcContext<AgentView>;
 final fit:AgentView->AgentView;
 public function new(source:haxeon.rpc.RpcContext<AgentView>,fit:AgentView->AgentView) {
  super(null,null,null);
  this.source=source;
  this.fit=fit;
 }
 override public function deadline():Float return source.deadline();
 override public function isCancelled():Bool return source.isCancelled();
 override public function respond(value:AgentView):Bool return source.respond(fit(value));
 override public function fail(error:haxeon.rpc.RpcError):Bool return source.fail(error);
}
