package workspace.provider;

import haxe.Json;
import haxe.io.Path;
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
 var promptDone:Bool;
 var settled:Bool;
 var settling:Bool;
 var currentModel:Null<String>;
 var currentEffort:Null<String>;
}

/** Pi owns credentials, extensions and native session files. The daemon owns process lifetime and delivery. */
class PiProvider implements LocalAgentProvider {
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
 function inside(v:String):Bool return v != null && (v == directories.root || StringTools.startsWith(v,directories.root == "/" ? "/" : directories.root + "/"));
 function session(r:AgentRecord):PiSession return {record:r,process:null,transport:null,ready:false,policyReady:false,busy:false,error:null,
  conversation:new PiConversation(r.replay),dialogs:[],models:[],commands:null,commandsError:null,commandsLoading:false,serial:0,message:0,interrupted:false,promptDone:false,settled:false,
  settling:false,currentModel:null,currentEffort:null};
 static function copy(r:AgentRecord):AgentRecord {var result:AgentRecord=cast Reflect.copy(r);result.replay=null;return result;}
 public function owns(id:String):Bool return sessions.exists(id);
 public function records():Array<AgentRecord> return [for(s in sessions) copy(s.record)];
 function save(s:PiSession):Void {
  if(storageFailed) throw "Agent storage requires recovery";
  s.record.replay=s.conversation.snapshot();
  if(persistence != null) try persistence.saveAgent(s.record) catch(e:Dynamic) {storageFailed=true;throw e;}
 }
 function view(s:PiSession,?before:Int):AgentView return {
  record:copy(s.record),activity:"",items:s.conversation.page(before),itemsNext:s.conversation.next(before),itemsOmitted:false,
  requests:[for(id=>d in s.dialogs) {id:id,method:d.method == "confirm" ? "item/commandExecution/requestApproval" : "item/tool/requestUserInput",
   detail:d.detail,reviewable:d.reviewable,inputKind:d.method,options:d.options}],
  models:s.models,modelsNext:null,commands:s.commands,commandsError:s.commandsError,commandsLoading:s.commandsLoading,currentModel:s.currentModel,currentEffort:s.currentEffort,
  connectionState:s.ready && s.record.state != "reconnecting" ? "connected" : s.transport == null ? "disconnected" : "reconnecting",
  recoveryReason:s.ready ? null : "explicit-resume",error:s.error
 };
 function fail(s:PiSession,reason:String,terminalState:String="failed"):Void {
  var t=s.transport;s.transport=null;s.ready=false;
  var uncertain=s.busy || s.record.state == "uncertain";
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
  if(!s.busy || !s.promptDone || !s.settled || s.settling || s.dialogs.keys().hasNext()) return;
  s.settling=true;
  request(s,"get_state",{},function(state) {
   s.settling=false;
   if(Reflect.field(state,"isStreaming") != false || Reflect.field(state,"isCompacting") == true) return;
   if(s.record.turn == null) return;
   var status=s.interrupted ? "interrupted" : s.error == null ? "completed" : "failed";
   s.conversation.finish(s.record.turn,status);s.record.state=status;s.record.turn=null;s.busy=false;s.dialogs.clear();
   try save(s) catch(_:Dynamic) fail(s,"Pi result could not be saved");
  });
 }
 function event(s:PiSession,type:String,v:Dynamic):Void {
  if(type == "extension_ui_request") {dialog(s,v);return;}
  if(type == "extension_error") {s.error="Pi extension failed: "+str(v,"error");return;}
  var turn=s.record.turn;if(turn == null) return;
  switch(type) {
   case "message_start": if(str(Reflect.field(v,"message"),"role") == "assistant") s.message++;
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
   case "agent_settled": s.settled=true;settle(s);
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
  if(q.action == "connect") {if(s.transport == null) launch(s);ctx.respond(view(s));return;}
  if(q.action == "delete") {
   if(s.busy || s.dialogs.keys().hasNext()) {error("busy","Stop Pi before removing this session");return;}
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
  if(!valid(q.text,8192) || s.busy || s.dialogs.keys().hasNext()) {error("busy","Pi is busy or the prompt is empty/too large");return;}
  if((q.effort != null && q.effort != s.currentEffort) || (q.model != null && q.model != s.currentModel)) {error("invalid_request","Apply Pi model/thinking settings before sending");return;}
  var turn="pi-turn-"+(++s.serial)+"-"+Std.string(clock());
  s.record.nativeSessionRequired=true;
  s.record.state="working";s.record.turn=turn;s.busy=true;s.error=null;s.message=0;s.interrupted=false;s.promptDone=false;s.settled=false;
  s.conversation.put(turn,turn,"userMessage","You",q.text,"","completed");
  try save(s) catch(_:Dynamic) {s.busy=false;s.record.state="uncertain";error("storage_unavailable","Pi prompt was not queued");return;}
  request(s,"prompt",{message:q.text},function(data) {s.promptDone=true;if(str(data,"disposition") == "handled") s.settled=true;settle(s);});
  ctx.respond(view(s));
 }
 public function activeCount():Int return [for(s in sessions) if(s.busy || s.dialogs.keys().hasNext()) true].length;
 public function updateActivityCount():Int return [for(s in sessions) if(s.transport != null) true].length;
 public function dispose():Void {for(s in sessions) if(s.transport != null) fail(s,"Workspace daemon closed; explicitly resume Pi");}
}
