package workspace.provider;

import haxe.Json;
import haxe.io.Path;
import haxeon.wire.MessagePack;
import sys.FileSystem;
import sys.io.File;
import haxeon.rpc.RpcContext;
import process.OwnedProcess;
import process.ProcessManager;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;

private typedef PiDialog = {
 var nativeId:String;
 var method:String;
 var detail:String;
 var reviewable:Bool;
 var options:Array<String>;
 var expires:Float;
}
private typedef PiSession = {
 var record:AgentRecord;
 var process:Null<OwnedProcess>;
 var transport:Null<PiTransport>;
 var ready:Bool;
 var policyReady:Bool;
 var busy:Bool;
 var error:Null<String>;
 var conversation:PiConversation;
 var dialogs:Map<String,PiDialog>;
 var models:Array<AgentModel>;
 var commands:Null<Array<AgentCommand>>;
 var commandsError:Null<String>;
 var commandsLoading:Bool;
 var serial:Int;
 var message:Int;
 var interrupted:Bool;
 var pendingPrompts:Int;
 var revision:Int;
 var probe:Int;
 var inputs:PiInputQueue;
 var nativePending:Array<AgentNativeInput>;
 var nativeKnown:Bool;
 var settled:Bool;
 var settling:Bool;
 var currentModel:Null<String>;
 var currentEffort:Null<String>;
}

/** Pi owns credentials, extensions and native session files. The daemon owns process lifetime and delivery. */
class PiProvider implements AgentMessageSource {
 public var imageUploadAvailable:Bool=false;
 public var imagePrepare:Null<(String,Array<String>,Null<String>,Null<String>)->Null<Array<Dynamic>>>;
 public var imageHold:Null<(String,String,String,String,Array<String>)->Bool>;
 public function hasHeldImages(id:String):Bool {
  var session=sessions.get(id);if(session==null) return false;
  for(input in session.inputs.pending()) if(input.imageIds!=null && input.imageIds.length>0) return true;
  return false;
 }
 public function nativeNamingSupported():Bool return false;
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void {
  ctx.fail({code:"unsupported_operation",message:"Load models from an attached session",ambiguous:false});
 }
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void {
  ctx.fail({code:"unsupported_operation",message:"Session discovery is not supported by this provider",ambiguous:false});
 }
 public function driverKind():String return "pi";
 public function summary():String return "Pi: " + [for(s in sessions) true].length + " sessions";
 final directories:WorkspaceDirectories;
 final groups:Void->Array<WorkspaceGroup>;
 final processes:ProcessManager;
 final clock:Void->Float;
 final persistence:Null<WorkspaceAgentPersistence>;
 final executable:String;
 final prefix:Array<String>;
 final extensionDirectory:String;
 final sessions:Map<String,PiSession> = [];
 var storageFailed=false;
 public function new(directories:WorkspaceDirectories, groups:Void->Array<WorkspaceGroup>, processes:ProcessManager,
  clock:Void->Float, extensionDirectory:String, ?persistence:WorkspaceAgentPersistence, executable:String="pi", ?script:String) {
  this.directories=directories;this.groups=groups;this.processes=processes;this.clock=clock;
  this.extensionDirectory=extensionDirectory;this.persistence=persistence;this.executable=executable;
  prefix=script == null ? [] : [script];
  if(persistence != null) for(r in persistence.loadAgents()) if(r.provider == "pi") {
   if(!valid(r.id,128) || !valid(r.name,256) || !inside(r.cwd) || r.workspaceRoot != directories.root
    || (r.thread != "" && !sessionPath(r.thread)) || !mode(r.permissionMode) || sessions.exists(r.id)) throw "Invalid persisted Pi session";
   r.state=r.state == "working" || r.state == "needs-attention" || r.state == "uncertain" ? "uncertain" : "disconnected";
   r.turn=null;sessions.set(r.id,session(r));
  }
 }
 static function valid(v:String,n:Int):Bool return v != null && v.length > 0 && v.length <= n;
 static function mode(v:String):Bool return v == "supervised" || v == "acceptEdits" || v == "fullAccess";
 static function str(v:Dynamic,key:String):String {
  var x=v == null ? null : Reflect.field(v,key);return Std.isOfType(x,String) ? x : "";
 }
 static function sessionPath(v:String):Bool return valid(v,4096) && Path.isAbsolute(v) && v.indexOf("\n") < 0;
 function inside(v:String):Bool return directories.inside(v);
 function session(r:AgentRecord):PiSession return {record:r,process:null,transport:null,ready:false,policyReady:false,busy:false,error:null,
  conversation:new PiConversation(r.replay,new AgentResponseArchive("pi",r.id,persistence)),dialogs:[],models:[],commands:null,commandsError:null,commandsLoading:false,serial:0,message:0,interrupted:false,pendingPrompts:0,revision:0,probe:0,inputs:new PiInputQueue(r),nativePending:[],nativeKnown:false,settled:false,
  settling:false,currentModel:null,currentEffort:null};
 static function copy(r:AgentRecord):AgentRecord {var result:AgentRecord=cast Reflect.copy(r);result.replay=null;result.inputMessages=null;return result;}
 public function owns(id:String):Bool return sessions.exists(id);
 public function records():Array<AgentRecord> return [for(s in sessions) copy(s.record)];
 function save(s:PiSession):Void {
  if(storageFailed) throw "Agent storage requires recovery";
  s.record.replay=s.conversation.snapshot();
  // Outbox state has priority over the optional recent-history snapshot.
  while(MessagePack.encode(s.record).length>16384 && (cast s.record.replay:Array<AgentActivityItem>).length>0)
   (cast s.record.replay:Array<AgentActivityItem>).shift();
  if(MessagePack.encode(s.record).length>16384) throw "Pi input state exceeds storage bound";
  if(persistence != null) try persistence.saveAgent(s.record) catch(e:Dynamic) {storageFailed=true;throw e;}
 }
 function view(s:PiSession,?before:Int):AgentView {
  var pending:Array<AgentRequest>=[for(id=>d in s.dialogs) {id:id,method:d.method == "confirm" ? "item/commandExecution/requestApproval" : "item/tool/requestUserInput",
   detail:d.detail,reviewable:d.reviewable,inputKind:d.method,options:d.options}];
  var page=AgentRequestPage.project(pending);
  return {
  record:copy(s.record),activity:"",items:s.conversation.page(before),itemsNext:s.conversation.next(before),itemsOmitted:false,supportsMessageContent:true,supportsImageUpload:imageUploadAvailable,historyEpoch:s.conversation.epoch(),historyOmitted:s.conversation.hasOmitted(),
  requests:page.requests,requestsOmitted:page.omitted,
  models:s.models,modelsNext:null,commands:s.commands,commandsError:s.commandsError,commandsLoading:s.commandsLoading,currentModel:s.currentModel,currentEffort:s.currentEffort,
  connectionState:s.ready && s.record.state != "reconnecting" ? "connected" : s.transport == null ? "disconnected" : "reconnecting",
  recoveryReason:s.ready ? null : "explicit-resume",error:s.error == null ? s.conversation.archiveError() : s.error,
  inputToken:s.inputs.token(),pendingInputs:[for(m in s.inputs.pending()) cast Reflect.copy(m)],queuePaused:s.record.queuePaused==true,
  nativePending:s.nativePending,inputBusy:s.inputs.hasNativeOperation(),supportsSteering:true,supportsQueue:true
  };
 }
 public function messageContent(session:String,turn:String,item:String,token:String,offset:Int):Null<AgentContentChunk> {
  var s=sessions.get(session); return s == null ? null : s.conversation.content(turn,item,token,offset);
 }
 function fail(s:PiSession,reason:String,terminalState:String="failed"):Void {
  var t=s.transport;s.transport=null;s.ready=false;
  var uncertain=s.busy || s.record.state == "uncertain";
  s.inputs.pause();s.nativePending=[];s.nativeKnown=false;s.pendingPrompts=0;s.revision++;s.probe++;
  s.busy=false;s.settling=false;s.dialogs.clear();s.commands=null;s.commandsLoading=false;s.commandsError=null;s.error=reason.substring(0,2048);
  if(s.record.turn != null) s.conversation.finish(s.record.turn,terminalState);
  s.record.state=uncertain ? "uncertain" : "disconnected";s.record.turn=null;
  if(t != null) t.close(reason);
  if(s.process != null) {processes.release(s.process);s.process=null;}
  try save(s) catch(_:Dynamic) {}
 }
 function request(s:PiSession,method:String,params:Dynamic,done:Dynamic->Void):Void {
  var t=s.transport;if(t == null) return;
  t.request(method,params,clock(),function(r) {
   if(s.transport != t) return;
   if(r.error != null) {fail(s,r.error);return;}
   done(r.result);
  });
 }
 function refreshCommands(s:PiSession):Void {
  var t=s.transport;if(t == null || s.commandsLoading) return;
  s.commandsLoading=true;s.commandsError=null;
  t.request("get_commands",{},clock(),function(r) {
   if(s.transport != t) return;
   s.commandsLoading=false;
   if(r.error != null) {s.commandsError="Pi command discovery failed: "+r.error;return;}
   try s.commands=PiCommands.parse(r.result) catch(e:Dynamic) s.commandsError=Std.string(e);
  });
 }
 function launch(s:PiSession):Void {
  if(s.transport != null) return;
  if(s.record.thread != "" && !FileSystem.exists(s.record.thread) && s.record.nativeSessionRequired == true) {fail(s,"Pi session file is missing; refusing to create a replacement conversation");return;}
  try {
   if(!FileSystem.isDirectory(extensionDirectory)) throw "Pi extension directory is unavailable";
   var source=PiPermissionExtension.source(s.record.permissionMode);
   var extension=extensionDirectory + "/pi-permissions-" + haxe.crypto.Sha256.encode(source).substr(0,16) + ".mjs";
   if(!FileSystem.exists(extension) || File.getContent(extension) != source) File.saveContent(extension,source);
   var args=prefix.concat(["--mode","rpc","--extension",extension]);
   if(s.record.thread != "") args=args.concat(["--session",s.record.thread]);
   s.record.state="reconnecting";s.error=null;s.policyReady=false;
   s.process=processes.start(executable,args,s.record.cwd);
   var t=new PiTransport(s.process);s.transport=t;
   t.notification=function(type,v) event(s,type,v);
   request(s,"get_state",{},function(state) {
    var path=str(state,"sessionFile");
    if(!sessionPath(path) || (s.record.thread != "" && path != s.record.thread)) {fail(s,"Pi returned a different or invalid session file");return;}
    s.record.thread=path;
    var model=Reflect.field(state,"model");
    s.currentModel=valid(str(model,"provider"),256) && valid(str(model,"id"),256) ? str(model,"provider") + "/" + str(model,"id") : null;
    s.currentEffort=str(state,"thinkingLevel");
    // Persist identity before allowing the first prompt.
    try save(s) catch(_:Dynamic) {fail(s,"Pi session identity could not be saved");return;}
    request(s,"get_available_models",{},function(data) {
     var raw:Dynamic=Reflect.field(data,"models");
     if(!Std.isOfType(raw,Array) || (cast raw:Array<Dynamic>).length > 256) {fail(s,"Invalid Pi model catalog");return;}
     s.models=[];
     for(m in (cast raw:Array<Dynamic>)) {
      var provider=str(m,"provider"),id=str(m,"id"),name=str(m,"name");
      if(!valid(provider,128) || !valid(id,256)) {fail(s,"Invalid Pi model identity");return;}
      s.models.push({model:provider+"/"+id,name:valid(name,256) ? name : id,supportedEfforts:thinkingLevels(m)});
     }
     function ready():Void {
      if(!s.policyReady) {fail(s,"Pi permission extension did not initialize; no prompt was sent");return;}
      s.ready=true;s.record.state=s.dialogs.keys().hasNext() ? "needs-attention" : "idle";
      try save(s) catch(_:Dynamic) {fail(s,"Pi initialization could not be saved");return;}
      refreshCommands(s);
     }
     function thinking():Void {
      if(s.record.preferredEffort != null) setThinking(s,s.record.preferredEffort,ready);else ready();
     }
     if(s.record.preferredModel != null && s.record.preferredModel != s.currentModel)
      setModel(s,s.record.preferredModel,thinking);
     else thinking();
    });
   });
  } catch(e:Dynamic) fail(s,Std.string(e));
 }
 static function thinkingLevels(model:Dynamic):Array<String> {
  if(Reflect.field(model,"reasoning") != true) return [];
  var mapping=Reflect.field(model,"thinkingLevelMap"),levels:Array<String>=[];
  for(level in ["off","minimal","low","medium","high","xhigh","max"]) {
   if(mapping != null && Reflect.hasField(mapping,level) && Reflect.field(mapping,level) == null) continue;
   if((level == "xhigh" || level == "max") && (mapping == null || !Reflect.hasField(mapping,level))) continue;
   levels.push(level);
  }
  return levels;
 }
 function effortSupported(s:PiSession,model:Null<String>,effort:Null<String>):Bool {
  if(effort == null) return true;
  for(m in s.models) if(m.model == model && m.supportedEfforts != null) return m.supportedEfforts.contains(effort);
  return false;
 }
 function refreshState(s:PiSession,done:Void->Void):Void {
  request(s,"get_state",{},function(state) {
   if(str(state,"sessionFile") != s.record.thread) {fail(s,"Pi changed its native conversation unexpectedly");return;}
   var model=Reflect.field(state,"model");
   s.currentModel=str(model,"provider")+"/"+str(model,"id");s.currentEffort=str(state,"thinkingLevel");done();
  });
 }
 function setModel(s:PiSession,model:String,done:Void->Void):Void {
  var at=model.indexOf("/");
  request(s,"set_model",{provider:model.substring(0,at),modelId:model.substring(at+1)},function(_) {
   s.record.preferredModel=model;
   refreshState(s,function() {
    if(s.currentModel != model) {fail(s,"Pi did not apply the requested model");return;}
    done();
   });
  });
 }
 function setThinking(s:PiSession,level:String,done:Void->Void):Void {
  if(!effortSupported(s,s.currentModel,level)) {fail(s,"Pi thinking level is not supported by the selected model");return;}
  request(s,"set_thinking_level",{level:level},function(_) {
   refreshState(s,function() {
    if(s.currentEffort != level) {fail(s,"Pi did not apply the requested thinking level");return;}
    s.record.preferredEffort=level;done();
   });
  });
 }
 function dialog(s:PiSession,v:Dynamic):Void {
  var method=str(v,"method"),nativeId=str(v,"id");
  if(method == "notify") {
   if(str(v,"message") == "exosuit-permissions/v1:"+s.record.permissionMode) {s.policyReady=true;return;}
   s.conversation.put("notice-"+(++s.serial),s.record.turn == null ? "session" : s.record.turn,"system","Pi",str(v,"message"),"","completed");return;
  }
  if(method != "confirm" && method != "select" && method != "input" && method != "editor") return;
  if(!valid(nativeId,256) || [for(_ in s.dialogs) true].length >= 16) {fail(s,"Invalid or excessive Pi dialogs");return;}
  var detail=str(v,"title")+"\n"+str(v,"message"),options:Array<String>=[],raw:Dynamic=Reflect.field(v,"options");
  if(method == "input") detail += "\n"+str(v,"placeholder");
  if(method == "editor") detail += "\n"+str(v,"prefill");
  if(method == "select") {
   if(!Std.isOfType(raw,Array) || (cast raw:Array<Dynamic>).length > 64) {fail(s,"Invalid Pi selection options");return;}
   for(o in (cast raw:Array<Dynamic>)) {
    if(!Std.isOfType(o,String) || !valid(o,1024)) {fail(s,"Invalid Pi selection option");return;}
    options.push(o);
   }
   detail += "\n"+options.join("\n");
  }
  // Public request IDs are unique across process restarts, even if Pi reuses native IDs.
  var id="pi-"+(++s.serial)+"-"+Std.string(clock());
  var timeout:Dynamic=Reflect.field(v,"timeout");
  var expires=Std.isOfType(timeout,Float) && timeout != 0 ? clock()+Math.max(0,timeout) : Math.POSITIVE_INFINITY;
  s.dialogs.set(id,{nativeId:nativeId,method:method,detail:detail.substring(0,2048),reviewable:detail.length<=2048,options:options,expires:expires});
  s.record.state="needs-attention";
 }
 function settle(s:PiSession):Void {
  if(!s.busy || s.pendingPrompts!=0 || !s.settled || s.settling || s.dialogs.keys().hasNext() || s.inputs.hasNativeOperation()) return;
  s.settling=true;var revision=s.revision,probe=++s.probe,turn=s.record.turn;
  request(s,"get_state",{},function(state) {
   if(s.probe!=probe) return;
   s.settling=false;
   if(s.revision!=revision || s.record.turn!=turn) {settle(s);return;}
   if(Reflect.field(state,"isStreaming") != false || Reflect.field(state,"isCompacting") == true
    || (Reflect.field(state,"pendingMessageCount") != null && Reflect.field(state,"pendingMessageCount") != 0)) return;
   if(s.record.turn == null) return;
   s.nativePending=[];s.nativeKnown=true;s.inputs.nativeEmpty();
   var status=s.interrupted ? "interrupted" : s.error == null ? "completed" : "failed";
   s.conversation.finish(s.record.turn,status);s.record.state=status;s.record.turn=null;s.busy=false;s.dialogs.clear();
   if(status!="completed") s.record.queuePaused=true;
   try save(s) catch(_:Dynamic) {fail(s,"Pi result could not be saved");return;}
   drain(s);
  });
 }
 function imageBlocks(s:PiSession,ids:Null<Array<String>>,?turn:String,?item:String):Null<Array<Dynamic>> {
  if(ids==null || ids.length==0) return [];
  return imagePrepare==null ? null : imagePrepare(s.record.id,ids,turn,item);
 }
 function imageFrameFits(text:String,images:Array<Dynamic>):Bool {
  var payload:Dynamic={type:"prompt",id:"2147483647",message:text,streamingBehavior:"steer",images:images};
  return haxe.io.Bytes.ofString(haxe.Json.stringify(payload)).length+1 <= PiTransport.MAX_FRAME_BYTES;
 }
 function startRun(s:PiSession,text:String,?message:AgentInputMessage,?directIds:Array<String>,?directTurn:String):Bool {
  var turn=message == null ? directTurn == null ? "pi-turn-"+(++s.serial)+"-"+Std.string(clock()) : directTurn : "pi-turn-"+message.id;
  var ids=message==null ? directIds : message.imageIds, itemId=message==null ? turn : message.id;
  var blocks=imageBlocks(s,ids,turn,itemId);
  if(blocks==null || !imageFrameFits(text,blocks)) {
   s.record.queuePaused=true;s.error="Queued image is unavailable or exceeds the Pi frame limit; remove this input and retry";
   try save(s) catch(_:Dynamic) fail(s,"Pi queue state could not be saved");return false;
  }
  s.record.nativeSessionRequired=true;s.record.state="working";s.record.turn=turn;s.busy=true;s.error=null;
  s.message=0;s.interrupted=false;s.settled=false;s.settling=false;s.probe++;s.revision++;
  if(message != null) message.state="sending";
  s.conversation.put(itemId,turn,"userMessage","You",text,"","completed");
  if(ids!=null && ids.length>0) s.conversation.attachImages(turn,itemId,ids);
  try save(s) catch(_:Dynamic) {fail(s,"Pi prompt could not be saved before delivery");return false;}
  sendPrompt(s,text,message,false,blocks);return true;
 }
 function sendPrompt(s:PiSession,text:String,message:Null<AgentInputMessage>,activeSteer:Bool,?images:Array<Dynamic>):Void {
  var t=s.transport;if(t == null) return;
  s.pendingPrompts++;
  var params:Dynamic={message:text};
  if(images!=null && images.length>0) Reflect.setField(params,"images",images);
  if(message != null && message.kind=="steer") Reflect.setField(params,"streamingBehavior","steer");
  t.request("prompt",params,clock(),function(r) {
   if(s.transport!=t) return;
   if(r.error != null) {fail(s,r.error);return;}
   s.pendingPrompts--;
   var disposition=str(r.result,"disposition");
   if(disposition!="started" && disposition!="queued" && disposition!="handled") {fail(s,"Pi did not report prompt acceptance");return;}
   if(message != null) s.inputs.finish(message,disposition=="handled" ? "handled" : disposition=="queued" && (!s.nativeKnown || s.nativePending.length>0) ? "steering" : "sent");
   if(disposition=="handled") s.settled=true;
   try save(s) catch(_:Dynamic) {fail(s,"Pi input acceptance could not be saved");return;}
   settle(s);
  },function(reason) {
   if(s.transport!=t) return;
   s.pendingPrompts--;
   if(message == null) {fail(s,reason);return;}
   s.inputs.finish(message,"rejected",reason);
   if(!activeSteer) {
    if(s.record.turn != null) s.conversation.finish(s.record.turn,"failed");
    s.busy=false;s.record.turn=null;s.record.state="failed";s.record.queuePaused=true;
   }
   try save(s) catch(_:Dynamic) {fail(s,"Pi rejection could not be saved");return;}
   settle(s);
  });
 }
 function drain(s:PiSession):Void {
  if(!s.ready || s.busy || s.record.queuePaused==true || s.dialogs.keys().hasNext() || s.inputs.hasNativeOperation() || s.nativePending.length>0) return;
  var next=s.inputs.next();if(next != null) startRun(s,next.text,next);
 }
 function nativeQueue(s:PiSession,v:Dynamic):Void {
  var result:Array<AgentNativeInput>=[];
  for(kind in ["steering","followUp"]) {
   var raw:Dynamic=Reflect.field(v,kind);
   if(!Std.isOfType(raw,Array) || (cast raw:Array<Dynamic>).length>64) {fail(s,"Invalid Pi pending-message snapshot");return;}
   for(text in (cast raw:Array<Dynamic>)) {
    if(!Std.isOfType(text,String)) {fail(s,"Invalid Pi pending message");return;}
    result.push({kind:kind=="steering" ? "steer" : "queue",text:(cast text:String).substr(0,2048),truncated:(cast text:String).length>2048});
   }
  }
  s.nativePending=result;s.nativeKnown=true;
  if(result.length==0) {
   s.inputs.nativeEmpty();
   try save(s) catch(_:Dynamic) fail(s,"Pi queue state could not be saved");
  }
 }
 function canSteerText(s:PiSession,text:String):Bool {
  if(!StringTools.startsWith(text,"/")) return true;
  var token=~/\s+/g.split(text)[0];
  if(s.commands != null) for(command in (cast s.commands:Array<AgentCommand>))
   if(command.invocation==token) return command.kind=="skill" || command.kind=="prompt";
  return false;
 }
 function submitInput(s:PiSession,q:AgentAction,ctx:RpcContext<AgentView>):Void {
  var kind=q.action=="queue" ? "queue" : q.action=="steer" ? "steer" : "clear",text=kind=="clear" ? "" : q.text;
  var ids=q.imageIds;
  if(text == null || (kind!="clear" && (text.length>4096 || (StringTools.trim(text)=="" && (ids==null || ids.length==0))))
   || (kind=="clear" && ids!=null && ids.length>0) || q.request==null || !valid(q.request,128)) {
   ctx.fail({code:"invalid_request",message:"A current input token and a message of at most 4096 bytes are required",ambiguous:false});return;
  }
  var existing=s.inputs.find(q.request);
  if(existing != null) {
   if(existing.kind!=kind || existing.fingerprint!=PiInputQueue.fingerprint(kind,text,ids)) ctx.fail({code:"conflict",message:"Input token already belongs to another message",ambiguous:false});
   else ctx.respond(view(s));return;
  }
  if(q.request!=s.inputs.token()) {ctx.fail({code:"stale_input",message:"The input token has expired; refresh the session before submitting again",ambiguous:false});return;}
  if(!s.ready || s.transport==null) {ctx.fail({code:"disconnected",message:"Resume Pi before submitting messages",ambiguous:false});return;}
  if((kind!="queue" && s.inputs.hasNativeOperation()) || (s.busy && s.record.turn==null)) {ctx.fail({code:"busy",message:"Wait for the pending Pi operation",ambiguous:false});return;}
  if(kind=="steer" && !canSteerText(s,text)) {ctx.fail({code:"invalid_request",message:"Send extension commands when Pi is idle; steering supports text, skills and prompt templates",ambiguous:false});return;}
  if(!s.inputs.canAdd(text,kind,ids)) {ctx.fail({code:"limit",message:"Pending inputs are limited to eight messages and 4096 total bytes",ambiguous:false});return;}
  var blocks=imageBlocks(s,ids);
  if(blocks==null || !imageFrameFits(text,blocks)) {ctx.fail({code:"image_unavailable",message:"An image is unavailable or exceeds the Pi input limit",ambiguous:false});return;}
  if(ids!=null && ids.length>0) {
   var turn=kind=="steer" && s.busy ? s.record.turn : "pi-turn-"+q.request;
   if(turn==null || imageHold==null || !imageHold(s.record.id,s.record.thread,turn,q.request,ids)) {
    ctx.fail({code:"image_unavailable",message:"Could not retain this image for the Pi input",ambiguous:false});return;
   }
  }
  var input=s.inputs.add(q.request,kind,text,ids);
  try save(s) catch(_:Dynamic) {fail(s,"Pi input could not be saved before delivery");ctx.fail({code:"storage_unavailable",message:"Pi input could not be saved",ambiguous:false});return;}
  if(kind=="steer") {
   if(s.busy) {
    s.revision++;s.settled=false;
    s.conversation.put(input.id,s.record.turn,"userMessage","You · Steering",text,"","completed");
    if(ids!=null && ids.length>0) s.conversation.attachImages(s.record.turn,input.id,ids);
    try save(s) catch(_:Dynamic) {fail(s,"Steering could not be saved");ctx.respond(view(s));return;}
    sendPrompt(s,text,input,true,blocks);
   } else startRun(s,text,input);
  } else if(kind=="clear") {
   var t=s.transport;s.revision++;
   t.request("clear_queue",{},clock(),function(r) {
    if(s.transport!=t) return;
    if(r.error != null) {fail(s,r.error);return;}
    s.inputs.finish(input,"sent");
    if(s.nativeKnown && s.nativePending.length==0) s.inputs.nativeEmpty();
    try save(s) catch(_:Dynamic) {fail(s,"Pi clear-queue result could not be saved");return;}
    settle(s);
   },function(reason) {
    if(s.transport!=t) return;
    s.inputs.finish(input,"rejected",reason);
    try save(s) catch(_:Dynamic) {fail(s,"Pi clear-queue rejection could not be saved");return;}
    settle(s);
   });
  }
  ctx.respond(view(s));
 }
 function event(s:PiSession,type:String,v:Dynamic):Void {
  if(type == "queue_update") {nativeQueue(s,v);return;}
  if(type == "extension_ui_request") {dialog(s,v);return;}
  if(type == "extension_error") {s.error="Pi extension failed: "+str(v,"error");return;}
  var turn=s.record.turn;if(turn == null) return;
  switch(type) {
   case "agent_start": s.revision++;s.settled=false;
   case "message_start":
    s.revision++;s.settled=false;
    if(str(Reflect.field(v,"message"),"role") == "assistant") s.message++;
   case "message_update":
    var d=Reflect.field(v,"assistantMessageEvent"),kind=str(d,"type"),index:Dynamic=Reflect.field(d,"contentIndex");
    if(kind == "text_delta" || kind == "thinking_delta") {
     var reasoning=kind == "thinking_delta";
     s.conversation.delta(turn+":"+s.message+":"+(reasoning ? "thinking" : "text")+":"+Std.string(index),turn,str(d,"delta"),reasoning ? "reasoning" : "agentMessage");
    }
    if(kind == "text_end" || kind == "thinking_end") {
     var reasoning=kind == "thinking_end";
     s.conversation.put(turn+":"+s.message+":"+(reasoning ? "thinking" : "text")+":"+Std.string(index),turn,
      reasoning ? "reasoning" : "agentMessage",reasoning ? "Reasoning" : "Pi",str(d,reasoning ? "thinking" : "content"),"","completed");
    }
   case "message_end":
    var m=Reflect.field(v,"message");
    if(str(m,"role") == "assistant" && str(m,"stopReason") == "error") s.error=str(m,"errorMessage");
   case "tool_execution_start", "tool_execution_update", "tool_execution_end":
    var id=str(v,"toolCallId");if(!valid(id,256)) {fail(s,"Invalid Pi tool identity");return;}
    var output=Reflect.field(v,type == "tool_execution_update" ? "partialResult" : "result");
    var content:Dynamic=output == null ? null : Reflect.field(output,"content"),text="";
    if(Std.isOfType(content,Array)) for(part in (cast content:Array<Dynamic>)) if(str(part,"type") == "text" && text.length < 8192) text += str(part,"text");
    s.conversation.put(turn+":tool:"+id,turn,"tool",str(v,"toolName"),text,type == "tool_execution_start" ? Json.stringify(Reflect.field(v,"args")) : "",
     type == "tool_execution_end" ? Reflect.field(v,"isError") == true ? "failed" : "completed" : "inProgress");
    if (type == "tool_execution_end" && Reflect.field(v,"isError") != true)
     s.conversation.toolPatch(turn+":tool:"+id,turn,output);
   case "agent_settled": s.settled=true;settle(s);
   case "compaction_end": settle(s);
   default:
  }
 }
 public function poll():Void {
  for(s in sessions) {
   var t=s.transport;
   if(t != null) {
    t.poll(clock());if(t.failure != null && s.transport == t) fail(s,t.failure);
    for(id in [for(id=>d in s.dialogs) if(clock() >= d.expires) id]) s.dialogs.remove(id);
    if(s.ready && s.record.state == "needs-attention" && !s.dialogs.keys().hasNext()) s.record.state=s.busy ? "working" : "idle";
    drain(s);
   }
  }
 }
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void {
  if(storageFailed) {ctx.fail({code:"storage_unavailable",message:"Agent storage requires recovery",ambiguous:false});return;}
  var selected=q.permissionProfile == null ? "supervised" : q.permissionProfile;
  if(!valid(q.id,128) || !valid(q.name,256) || q.thread != null || !mode(selected) || (q.defaultEffort != null && !valid(q.defaultEffort,32))
   || (q.defaultModel != null && !modelId(q.defaultModel))) {
   ctx.fail({code:"invalid_request",message:"Invalid Pi configuration; native session import is not supported yet",ambiguous:false});return;
  }
  var previous=sessions.get(q.id);
  if(previous != null) {
   if(previous.record.name != q.name || previous.record.group != q.group) ctx.fail({code:"conflict",message:"Agent identity is reserved",ambiguous:false});
   else ctx.respond(copy(previous.record));return;
  }
  var cwd:Null<String>=null;for(g in groups()) if(g.id == q.group) cwd=directories.resolve(g.cwd);
  if(cwd == null || !inside(cwd)) {ctx.fail({code:"invalid_request",message:"Invalid Pi group directory",ambiguous:false});return;}
  var s=session({id:q.id,name:q.name,group:q.group,cwd:cwd,thread:"",state:"disconnected",turn:null,workspaceRoot:directories.root,
   provider:"pi",permissionMode:selected,preferredModel:q.defaultModel,preferredEffort:q.defaultEffort});
  try save(s) catch(_:Dynamic) {ctx.fail({code:"storage_unavailable",message:"Pi reservation failed",ambiguous:false});return;}
  sessions.set(q.id,s);launch(s);ctx.respond(copy(s.record));
 }
 static function modelId(v:String):Bool return valid(v,384) && v.indexOf("/") > 0 && v.indexOf("/") < v.length-1;
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void {
  var s=sessions.get(q.id);
  function error(code:String,message:String,ambiguous:Bool=false):Void ctx.fail({code:code,message:message,ambiguous:ambiguous});
  if(s == null) {error("unknown_agent","Unknown Pi agent");return;}
  if(q.action == "read") {
   var before=q.after == null ? null : s.conversation.offset(q.after);
   if(q.after != null && before == null) {error("invalid_cursor","Refresh activity history");return;}
   ctx.respond(view(s,before));return;
  }
  if(storageFailed) {error("storage_unavailable","Agent storage requires recovery");return;}
  if (q.action == "move" || q.action == "rename") {
   try {
    var error = q.action == "move"
     ? AgentMetadata.move(s.record, q.request, q.text, groups(), function() save(s))
     : AgentMetadata.rename(s.record, q.request, q.text, function() save(s));
    if (error != null) {ctx.fail({code:error,message:"Session metadata changed or the new name or destination is invalid",ambiguous:false});return;}
   } catch (_:Dynamic) {
    storageFailed = true;
    ctx.fail({code:"storage_unavailable",message:"Session metadata could not be saved",ambiguous:false});return;
   }
   ctx.respond(view(s));return;
  }
  if(q.action=="queue" || q.action=="steer" || q.action=="clear-native-queue") {submitInput(s,q,ctx);return;}
  if(q.action=="remove-input") {
   var input=s.inputs.find(q.request);
   if(input==null) {error("resolved","This input is no longer retained");return;}
   if(input.state=="cancelled") {ctx.respond(view(s));return;}
   if(input.state!="queued" && input.state!="uncertain" && input.state!="rejected") {error("resolved","Pi already accepted this message; use Clear Pi pending messages for its native queue");return;}
   s.inputs.finish(input,"cancelled");
   try save(s) catch(_:Dynamic) {error("storage_unavailable","Input removal could not be saved");return;}
   ctx.respond(view(s));return;
  }
  if(q.action=="resume-queue" || q.action=="pause-queue") {
   if(q.action=="resume-queue" && !s.ready) {error("disconnected","Resume Pi before resuming queued messages");return;}
   s.record.queuePaused=q.action=="pause-queue";
   try save(s) catch(_:Dynamic) {error("storage_unavailable","Queue policy could not be saved");return;}
   ctx.respond(view(s));return;
  }
  if(q.action == "connect") {if(s.transport == null) launch(s);ctx.respond(view(s));return;}
  if(q.action == "delete") {
   if(s.busy || s.dialogs.keys().hasNext() || s.inputs.pending().length>0) {error("busy","Stop Pi and remove its pending inputs before removing this session");return;}
   var result=view(s);
   try {if(persistence != null) persistence.removeAgent(q.id);} catch(_:Dynamic) {storageFailed=true;error("storage_unavailable","Pi removal failed");return;}
   if(s.process != null) processes.release(s.process);sessions.remove(q.id);ctx.respond(result);return;
  }
  var t=s.transport;
  if(t == null) {error("disconnected","Explicitly resume this Pi session before sending requests");return;}
  if(q.action == "approve" || q.action == "decline" || q.action == "answer") {
   var d=q.request == null ? null : s.dialogs.get(q.request);
   if(d == null || clock() >= d.expires) {error("resolved","Pi request has resolved or expired");return;}
   var response:Dynamic={type:"extension_ui_response",id:d.nativeId};
   if(q.action == "decline") {if(d.method == "confirm") Reflect.setField(response,"confirmed",false);else Reflect.setField(response,"cancelled",true);}
   else if(!d.reviewable) {error("unsupported_request","The full Pi request exceeds the view limit; decline it");return;}
   else if(q.action == "approve" && d.method == "confirm") Reflect.setField(response,"confirmed",true);
   else if(q.action == "answer" && d.method != "confirm" && q.text != null && q.text.length <= 8192) {
    if(d.method == "select" && !d.options.contains(q.text)) {error("invalid_request","Choose an exact Pi option");return;}
    Reflect.setField(response,"value",q.text);
   } else {error("invalid_request","Unsupported Pi dialog response");return;}
   if(!t.send(response)) {error("backpressure","Pi response was not queued");return;}
   s.dialogs.remove(q.request);s.record.state=s.dialogs.keys().hasNext() ? "needs-attention" : s.busy ? "working" : s.ready ? "idle" : "reconnecting";
   ctx.respond(view(s));return;
  }
  if(q.action == "stop") {
   if(!s.busy) {error("busy","No active Pi turn");return;}
   // Termination is reliable even when Stop races prompt dispatch or an extension dialog.
   s.interrupted=true;var turn=s.record.turn;
   fail(s,"Pi stopped; resume the native conversation to continue","interrupted");
   if(turn != null) s.conversation.finish(turn,"interrupted");s.record.state="interrupted";
   try save(s) catch(_:Dynamic) {error("storage_unavailable","Pi stop could not be saved",true);return;}
   ctx.respond(view(s));return;
  }
  if(!s.ready) {error("provider_starting","Pi is initializing");return;}
  if(q.action == "models") {ctx.respond(view(s));return;}
  if(q.action == "commands") {
   if(s.busy || s.dialogs.keys().hasNext()) {error("busy","Wait for Pi to finish before refreshing commands");return;}
   refreshCommands(s);ctx.respond(view(s));return;
  }
  if(q.action == "permissions") {
   if(s.busy || s.dialogs.keys().hasNext()) {error("busy","Wait for Pi to finish");return;}
   if(!mode(q.text)) {error("invalid_permissions","Choose supervised, acceptEdits or fullAccess");return;}
   s.record.permissionMode=q.text;
   try save(s) catch(_:Dynamic) {error("storage_unavailable","Pi policy could not be saved");return;}
   fail(s,"Applying Pi policy");launch(s);ctx.respond(view(s));return;
  }
  if(q.action == "model-settings") {
   if(s.busy || s.dialogs.keys().hasNext()) {error("busy","Wait for Pi to finish");return;}
   var model=q.model == null ? s.currentModel : q.model;
   if(model == null || !modelId(model) || !effortSupported(s,model,q.effort)) {error("invalid_request","Unsupported Pi model or thinking level");return;}
   s.busy=true;s.record.state="reconnecting";
   function done():Void {
    s.busy=false;s.record.state="idle";
    try save(s) catch(_:Dynamic) fail(s,"Pi settings could not be saved");
   }
   function thinking():Void {
    if(q.effort != null) setThinking(s,q.effort,done);
    else {s.record.preferredEffort=null;done();}
   }
   if(model != s.currentModel) setModel(s,model,thinking);else thinking();
   ctx.respond(view(s));return;
  }
  if(q.action != "prompt") {error("unsupported_request","Unsupported Pi action");return;}
  if(q.text==null || q.text.length>8192 || (StringTools.trim(q.text)=="" && (q.imageIds==null || q.imageIds.length==0)) || s.busy || s.dialogs.keys().hasNext()) {error("busy","Pi is busy or the prompt is empty/too large");return;}
  if((q.effort != null && q.effort != s.currentEffort) || (q.model != null && q.model != s.currentModel)) {error("invalid_request","Apply Pi model/thinking settings before sending");return;}
  if(s.inputs.next()!=null && s.record.queuePaused!=true) {error("busy","Queued messages will run first");return;}
  var directTurn:Null<String>=null;
  if(q.imageIds!=null && q.imageIds.length>0) {
   var blocks=imageBlocks(s,q.imageIds);
   if(blocks==null || !imageFrameFits(q.text,blocks)) {error("image_unavailable","An image is unavailable or exceeds the Pi input limit");return;}
   directTurn="pi-turn-"+(++s.serial)+"-"+Std.string(clock());
   if(imageHold==null || !imageHold(s.record.id,s.record.thread,directTurn,directTurn,q.imageIds)) {error("image_unavailable","Could not retain this image for the Pi input");return;}
  }
  if(!startRun(s,q.text,null,q.imageIds,directTurn)) {error("image_unavailable","Pi input could not be prepared");return;}
  ctx.respond(view(s));
 }
 public function activeCount():Int return [for(s in sessions) if(s.busy || s.dialogs.keys().hasNext() || (s.inputs.next()!=null && s.record.queuePaused!=true)) true].length;
 public function updateActivityCount():Int return [for(s in sessions) if(s.transport != null) true].length;
 public function dispose():Void {for(s in sessions) if(s.transport != null) fail(s,"Workspace daemon closed; explicitly resume Pi");}
}
