package workspace.provider;

import haxe.Json;
import haxeon.rpc.RpcContext;
import process.OwnedProcess;
import process.ProcessManager;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;

private typedef ClaudeApproval = {
 var input:Dynamic;
 var tool:String;
 var detail:String;
 var reviewable:Bool;
 var questions:Array<String>;
 var structured:Null<Array<AgentQuestion>>;
}
private typedef ClaudeSession = {
 var record:AgentRecord;
 var process:Null<OwnedProcess>;
 var transport:Null<ClaudeTransport>;
 var ready:Bool;
 var busy:Bool;
 var error:Null<String>;
 var conversation:ClaudeConversation;
 var approvals:Map<String,ClaudeApproval>;
 var models:Array<AgentModel>;
 var message:String;
 var currentModel:Null<String>;
 var serial:Int;
 var interrupting:Bool;
}

/** One native CLI process per session, owned by the workspace daemon, not an editor attachment. */
class ClaudeProvider implements AgentMessageSource {
 public function modelCatalog(q:AgentModelsQuery,ctx:RpcContext<AgentModelsPage>):Void {
  ctx.fail({code:"unsupported_operation",message:"Load models from an attached session",ambiguous:false});
 }
 public function discover(q:AgentDiscoveryQuery,ctx:RpcContext<AgentDiscovery>):Void {
  ctx.fail({code:"unsupported_operation",message:"Session discovery is not supported by this provider",ambiguous:false});
 }
 public function driverKind():String return "claude";
 final directories:WorkspaceDirectories;
 final groups:Void->Array<WorkspaceGroup>;
 final processes:ProcessManager;
 final clock:Void->Float;
 final persistence:Null<WorkspaceAgentPersistence>;
 final executable:String;
 final prefix:Array<String>;
 final sessions:Map<String,ClaudeSession> = [];
 final nameBridge:ClaudeNameBridge;
 final nameSync:Map<String,AgentNameSync> = [];
 public function nativeNamingSupported():Bool return nameBridge.available();
 function names(s:ClaudeSession):AgentNameSync {
  var existing=nameSync.get(s.record.id);if(existing!=null) return existing;
  var sync=new AgentNameSync(s.record,function() save(s),
   function(done) nameBridge.read(s.record.thread,s.record.cwd,done),
   function(name,expected,done) nameBridge.write(s.record.thread,s.record.cwd,name,expected,done),clock);
  nameSync.set(s.record.id,sync);return sync;
 }
 var storageFailed = false;
 public function new(directories:WorkspaceDirectories, groups:Void->Array<WorkspaceGroup>, processes:ProcessManager,
   clock:Void->Float, ?persistence:WorkspaceAgentPersistence, executable:String = "claude", ?script:String) {
  this.directories=directories;this.groups=groups;this.processes=processes;this.clock=clock;this.persistence=persistence;
  this.executable=executable;prefix=script == null ? [] : [script];
  nameBridge=new ClaudeNameBridge(processes,clock,directories.root,ClaudeNameBridge.findScript());
  if (persistence != null) for (r in persistence.loadAgents()) if (r.provider == "claude") {
   if (!valid(r.id,128) || !valid(r.name,256) || !uuid(r.thread) || r.workspaceRoot != directories.root
      || !valid(r.cwd,1024) || !inside(r.cwd) || !mode(r.permissionMode) || sessions.exists(r.id)) throw "Invalid persisted Claude session";
   r.state = r.state == "working" || r.state == "needs-attention" || r.state == "uncertain" ? "uncertain" : "disconnected";
   r.turn=null;
   sessions.set(r.id,session(r));
  }
 }
 static function valid(v:String,n:Int):Bool return v != null && v.length > 0 && v.length <= n;
 static function uuid(v:String):Bool return v != null && ~/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.match(v);
 static function mode(v:String):Bool return v == "default" || v == "acceptEdits" || v == "plan";
 static function str(v:Dynamic,key:String):String {
  var x = v == null ? null : Reflect.field(v,key);
  return Std.isOfType(x,String) ? x : "";
 }
 function inside(path:String):Bool return directories.inside(path);
 function session(r:AgentRecord):ClaudeSession return {
  record:r,process:null,transport:null,ready:false,busy:false,error:null,conversation:new ClaudeConversation(r.replay),
  approvals:[],models:[],message:"",currentModel:r.preferredModel,serial:0,interrupting:false
 };
 function save(s:ClaudeSession):Void {
  if (storageFailed) throw "Agent storage requires recovery";
  s.record.replay=s.conversation.snapshot();
  if (persistence != null) try persistence.saveAgent(s.record) catch(e:Dynamic) {storageFailed=true;throw e;}
 }
 public function owns(id:String):Bool return sessions.exists(id);
 public function summary():String return "Claude: " + [for(s in sessions) true].length + " sessions";
 public function records():Array<AgentRecord> return [for(s in sessions) copy(s.record)];
 static function copy(r:AgentRecord):AgentRecord {
  var result:AgentRecord = cast Reflect.copy(r);
  // Replay is returned through paged views, never in the catalog.
  result.replay=null;
  return result;
 }
 function view(s:ClaudeSession,?before:Int):AgentView {
  var pending = AgentRequestPage.project([for(id=>r in s.approvals) {id:id,method:r.tool == "AskUserQuestion" ? "item/tool/requestUserInput" : "item/commandExecution/requestApproval",detail:r.detail,reviewable:r.reviewable,questions:r.structured}]);
  return {
  record:copy(s.record),activity:"",items:s.conversation.page(before),itemsNext:s.conversation.next(before),itemsOmitted:false,supportsMessageContent:true,historyEpoch:s.conversation.epoch(),historyOmitted:s.conversation.hasOmitted(),
  requests:pending.requests,requestsOmitted:pending.omitted,
  models:s.models,modelsNext:null,currentModel:s.currentModel,currentEffort:null,
  connectionState:s.ready ? "connected" : s.transport == null ? "disconnected" : "reconnecting",
  recoveryReason:s.ready ? null : "explicit-resume",error:s.error
  };
 }
 public function messageContent(session:String,turn:String,item:String,token:String,offset:Int):Null<AgentContentChunk> {
  var s=sessions.get(session); return s == null ? null : s.conversation.content(turn,item,token,offset);
 }
 function fail(s:ClaudeSession,reason:String):Void {
  s.ready=false;s.busy=false;s.error=reason.substring(0,2048);s.approvals.clear();
  s.record.state = s.record.state == "working" || s.record.state == "needs-attention" ? "uncertain" : "disconnected";
  s.record.turn=null;
  if(s.transport != null) s.transport.close(reason);
  s.transport=null;
  if(s.process != null) {processes.release(s.process);s.process=null;}
  try save(s) catch(_:Dynamic) {}
 }
 function launch(s:ClaudeSession,resume:Bool):Void {
  if (s.transport != null) return;
  if (directories.resolve(s.record.cwd) != s.record.cwd) {fail(s,"Claude session directory no longer resolves inside this workspace");return;}
  var args=prefix.concat(["-p","--input-format","stream-json","--output-format","stream-json","--verbose",
   "--include-partial-messages","--permission-prompt-tool","stdio","--permission-mode",s.record.permissionMode]);
  args=args.concat(resume ? ["--resume",s.record.thread] : ["--session-id",s.record.thread]);
  if(s.record.preferredModel != null) args=args.concat(["--model",s.record.preferredModel]);
  s.record.state="reconnecting";s.error=null;
  try {
   s.process=processes.start(executable,args,s.record.cwd);
   var t=new ClaudeTransport(s.process);s.transport=t;
   t.notification=function(type,v) event(s,type,v);
   t.serverRequest=function(id,subtype,request) approval(s,Std.string(id),subtype,request);
   t.request("initialize",{},clock(),function(r) {
    if(s.transport != t) return;
    if(r.error != null) {fail(s,r.error);return;}
    var models:Dynamic = r.result == null ? null : Reflect.field(r.result,"models");
    if(Std.isOfType(models,Array)) for(m in (cast models:Array<Dynamic>)) {
     if(s.models.length >= 64) break;
     var id=str(m,"value"),name=str(m,"displayName");
     if(valid(id,256) && valid(name,256)) s.models.push({model:id,name:name,supportedEfforts:[]});
    }
    s.ready=true;s.record.state="idle";
    try save(s) catch(e:Dynamic) fail(s,"Claude initialization could not be saved");
   });
  } catch(e:Dynamic) fail(s,Std.string(e));
 }
 function approval(s:ClaudeSession,id:String,subtype:String,request:Dynamic):Void {
  var t=s.transport;
  if(t == null) return;
  if(subtype != "can_use_tool") {if (!t.reject(id,"Unsupported Exosuit control request")) fail(s,"Claude control response queue is full");return;}
  if(s.approvals.exists(id)) {fail(s,"Duplicate Claude approval id");return;}
  if([for(_ in s.approvals) true].length >= 16) {fail(s,"Too many Claude approval requests");return;}
  var tool=str(request,"tool_name"),input=Reflect.field(request,"input"),raw=Json.stringify(input);
  var questions:Array<String>=[];
  if(tool == "AskUserQuestion") {
   var qs:Dynamic=Reflect.field(input,"questions");
   if(Std.isOfType(qs,Array) && (cast qs:Array<Dynamic>).length <= 16)
    for(q in (cast qs:Array<Dynamic>)) questions.push(str(q,"question"));
  }
  var detail=tool + "\n" + raw;
  if(questions.length > 0) detail += "\n" + [for(i in 0...questions.length) i + "=" + questions[i]].join("\n");
  var reviewable = detail.length <= 2048 && (tool != "AskUserQuestion" || questions.length > 0);
  s.approvals.set(id,{input:input,tool:tool,detail:detail.substring(0,2048),reviewable:reviewable,questions:questions,
   structured:reviewable && tool == "AskUserQuestion" ? StructuredQuestions.project("claude",input) : null});
  s.record.state="needs-attention";
 }
 function event(s:ClaudeSession,type:String,v:Dynamic):Void {
  var turn=s.record.turn == null ? "session" : s.record.turn;
  switch(type) {
   case "system":
    if(str(v,"subtype") == "init") {
     if(str(v,"session_id") != s.record.thread) {fail(s,"Claude resumed a different session; refusing delivery");return;}
     var model=str(v,"model");if(valid(model,256)) s.currentModel=model;
    }
   case "control_cancel_request": s.approvals.remove(str(v,"request_id"));
   case "stream_event":
    if(Reflect.field(v,"parent_tool_use_id") != null) return;
    var e=Reflect.field(v,"event");
    if(str(e,"type") == "message_start") s.message=str(Reflect.field(e,"message"),"id");
    if(str(e,"type") == "content_block_delta") {
     var d=Reflect.field(e,"delta");
     if(str(d,"type") == "text_delta" && valid(s.message,128)) s.conversation.delta(s.message,turn,str(d,"text"));
    }
   case "assistant", "user":
    if(Reflect.field(v,"parent_tool_use_id") != null) return;
    var message=Reflect.field(v,"message"),content:Dynamic=Reflect.field(message,"content");
    if(!Std.isOfType(content,Array)) return;
    var id=str(message,"id");if(!valid(id,128)) id=str(v,"uuid");
    if(!valid(id,128)) return;
    var text="";
    for(part in (cast content:Array<Dynamic>)) {
     switch(str(part,"type")) {
      case "text": if (text.length <= AgentContentCache.MAX_MESSAGE) text += str(part,"text");
      case "tool_use":
       var tool=str(part,"name");
       s.conversation.put(str(part,"id"),turn,"tool",tool,"",Json.stringify(Reflect.field(part,"input")),"inProgress");
      case "tool_result":
       var result=Reflect.field(part,"content");
       s.conversation.put(str(part,"tool_use_id"),turn,"tool","Tool",Std.isOfType(result,String) ? result : Json.stringify(result),"",Reflect.field(part,"is_error") == true ? "failed" : "completed");
      default:
     }
    }
    if(text != "") s.conversation.put(id,turn,type == "assistant" ? "agentMessage" : "userMessage",type == "assistant" ? "Claude" : "You",text,"","completed");
   case "result":
    var failed=Reflect.field(v,"is_error") == true;
    s.record.state=s.interrupting ? "interrupted" : failed ? "failed" : "completed";
    s.interrupting=false;
    s.conversation.finish(turn,s.record.state);s.record.turn=null;s.busy=false;s.approvals.clear();
    if(failed) s.error=str(v,"result");
    try save(s) catch(_:Dynamic) fail(s,"Claude result could not be saved");
   default:
  }
 }
 public function poll():Void {
  nameBridge.poll();
  if(!storageFailed && nameBridge.available()) for(s in sessions) if(names(s).poll()) break;
  for(s in sessions) {
   var t=s.transport;
   if(t != null) {t.poll(clock());if(t.failure != null && s.transport == t) fail(s,t.failure);}
  }
 }
 public function create(q:AgentCreate,ctx:RpcContext<AgentRecord>):Void {
  if(storageFailed) {ctx.fail({code:"storage_unavailable",message:"Agent storage requires recovery",ambiguous:false});return;}
  if(!valid(q.id,128) || !valid(q.name,256) || (q.thread != null && !uuid(q.thread))
    || (q.defaultModel != null && !valid(q.defaultModel,256)) || q.defaultEffort != null) {
   ctx.fail({code:"invalid_request",message:"Invalid Claude session configuration; effort overrides are not supported",ambiguous:false});return;
  }
  var previous=sessions.get(q.id);
  if(previous != null) {
   if(previous.record.name != q.name || previous.record.group != q.group || (q.thread != null && previous.record.thread != q.thread))
    ctx.fail({code:"conflict",message:"Agent identity is already reserved",ambiguous:false});
   else ctx.respond(copy(previous.record));
   return;
  }
  var cwd:Null<String>=null;
  for(g in groups()) if(g.id == q.group) cwd=directories.resolve(g.cwd);
  if(cwd == null || !inside(cwd)) {ctx.fail({code:"invalid_request",message:"Invalid agent group directory",ambiguous:false});return;}
  var selected=q.permissionProfile == null ? "default" : q.permissionProfile;
  if(!mode(selected)) {ctx.fail({code:"invalid_permissions",message:"Choose default, acceptEdits or plan",ambiguous:false});return;}
  if(q.thread != null) for(s in sessions) if(s.record.thread == q.thread) {ctx.fail({code:"conflict",message:"Session is already attached",ambiguous:false});return;}
  var hex=haxe.crypto.Sha256.encode(Std.string(clock()) + ":" + Math.random() + ":" + q.id);
  var id=hex.substr(0,8)+"-"+hex.substr(8,4)+"-4"+hex.substr(13,3)+"-a"+hex.substr(17,3)+"-"+hex.substr(20,12);
  var s=session({id:q.id,name:q.name,group:q.group,cwd:cwd,thread:q.thread == null ? id : q.thread,state:"disconnected",turn:null,
   workspaceRoot:directories.root,provider:"claude",nameMetadata:{source:"native",nativeName:null},permissionMode:selected,preferredModel:q.defaultModel});
  try save(s) catch(_:Dynamic) {ctx.fail({code:"storage_unavailable",message:"Claude reservation failed",ambiguous:false});return;}
  sessions.set(q.id,s);launch(s,q.thread != null);ctx.respond(copy(s.record));
 }
 public function action(q:AgentAction,ctx:RpcContext<AgentView>):Void {
  var s=sessions.get(q.id);
  if(s == null) {ctx.fail({code:"unknown_agent",message:"Unknown Claude agent",ambiguous:false});return;}
  function error(code:String,message:String,ambiguous:Bool=false):Void {ctx.fail({code:code,message:message,ambiguous:ambiguous});}
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
  if(q.action == "inspect-name" || q.action == "rename-native") {
   if(!nativeNamingSupported()) {error("unsupported_operation","Native Claude naming is unavailable. Use Rename in Workbench or install the metadata adapter.");return;}
   var sync=names(s);
   if(q.action == "inspect-name") sync.inspect(function() ctx.respond(view(s)),function(problem) ctx.fail(problem));
   else if(q.request==null) error("invalid_request","Reopen Rename before saving");
   else sync.rename(q.request,q.expectedNativeName,q.text,function() ctx.respond(view(s)),function(problem) ctx.fail(problem));
   return;
  }
  if(q.action == "connect") {
   if(s.transport == null) launch(s,true);
   ctx.respond(view(s));return;
  }
  if(q.action == "delete") {
   if(s.busy || s.record.state == "needs-attention") {error("busy","Stop the turn before removing this session");return;}
   var result=view(s);
   try {if(persistence != null) persistence.removeAgent(q.id);} catch(_:Dynamic) {storageFailed=true;error("storage_unavailable","Session could not be removed");return;}
   if(s.process != null) processes.release(s.process);
   var sync=nameSync.get(q.id);if(sync!=null) sync.dispose();nameSync.remove(q.id);
   sessions.remove(q.id);ctx.respond(result);return;
  }
  if(!s.ready || s.transport == null) {error("disconnected","Explicitly resume this Claude session before sending requests");return;}
  var t=s.transport;
  if(q.action == "models") {ctx.respond(view(s));return;}
  if(q.action == "stop") {
   s.interrupting=true;
   t.request("interrupt",{},clock(),function(r) {
    if(r.error != null) {fail(s,r.error);error("provider_error",r.error,true);return;}
    ctx.respond(view(s));
   });return;
  }
  if(q.action == "permissions" || q.action == "model-settings") {
   if(s.busy || s.approvals.keys().hasNext()) {error("busy","Wait for this turn to finish");return;}
   var permissions=q.action == "permissions";
   if(permissions ? !mode(q.text) : q.effort != null || (q.model != null && !valid(q.model,256))) {error("invalid_request","Unsupported Claude setting");return;}
   s.busy=true;
   t.request(permissions ? "set_permission_mode" : "set_model",permissions ? {mode:q.text} : {model:q.model},clock(),function(r) {
    s.busy=false;
    if(r.error != null) {fail(s,r.error);error("provider_error",r.error,true);return;}
    if(permissions) s.record.permissionMode=q.text;else {s.record.preferredModel=q.model;s.currentModel=q.model;}
    try save(s) catch(_:Dynamic) {fail(s,"Claude settings could not be saved");error("storage_unavailable","Claude settings could not be saved",true);return;}
    ctx.respond(view(s));
   });return;
  }
  if(q.action == "prompt") {
   if(!valid(q.text,8192) || s.busy || s.record.state == "uncertain") {error("busy","Claude is busy or delivery requires reconciliation");return;}
   if(q.effort != null || (q.model != null && q.model != s.record.preferredModel)) {error("invalid_request","Set the Claude model before sending; effort overrides are unsupported");return;}
   var turn="turn-" + (++s.serial) + "-" + Std.string(clock());
   s.record.state="working";s.record.turn=turn;s.error=null;s.busy=true;
   s.conversation.put(turn,turn,"userMessage","You",q.text,"","completed");
   // Write-ahead state: a daemon crash must never cause an automatic prompt retry.
   try save(s) catch(_:Dynamic) {s.busy=false;s.record.state="uncertain";error("storage_unavailable","Prompt was not queued");return;}
   if(!t.send({type:"user",session_id:s.record.thread,message:{role:"user",content:q.text},parent_tool_use_id:null})) {
    fail(s,"Claude prompt queue failed; explicitly resume before another prompt");error("backpressure","Claude prompt was not queued");return;
   }
   ctx.respond(view(s));return;
  }
  var r=q.request == null ? null : s.approvals.get(q.request);
  if(r == null) {error("resolved","Request has resolved or disconnected");return;}
  if(q.text == null || haxe.io.Bytes.ofString(q.text).length > 8192) {error("invalid_request","Answer exceeds limit");return;}
  var response:Dynamic;
  if(q.action == "decline") response={behavior:"deny",message:"Declined by user"};
  else if(q.action == "approve" && r.tool != "AskUserQuestion" && r.reviewable) response={behavior:"allow",updatedInput:r.input};
  else if(q.action == "answer-questions" && r.tool == "AskUserQuestion" && r.reviewable) {
   var validated = StructuredQuestions.answers(r.structured,q.text,"claude");
   if (validated == null) {error("invalid_request","Review and answer every question");return;}
   var answers:Dynamic = {};
   for (id => values in validated) {
    var index = Std.parseInt(id);
    if (index == null || index < 0 || index >= r.questions.length) {error("invalid_request","Unknown question");return;}
    Reflect.setField(answers,r.questions[index],values.join(", "));
   }
   var updated = Reflect.copy(r.input); Reflect.setField(updated,"answers",answers);
   response = {behavior:"allow",updatedInput:updated};
  } else if(q.action == "answer" && r.tool == "AskUserQuestion" && r.reviewable) {
   var answers:Dynamic={},seen:Map<Int,Bool>=[];
   for(line in q.text.split("\n")) {
    var at=line.indexOf("="),index=Std.parseInt(line.substring(0,at));
    if(at <= 0 || index == null || Std.string(index) != line.substring(0,at) || index < 0 || index >= r.questions.length || seen.exists(index)) {error("invalid_request","Answer each question as index=value");return;}
    seen.set(index,true);Reflect.setField(answers,r.questions[index],line.substring(at+1));
   }
   if([for(_ in seen) true].length != r.questions.length) {error("invalid_request","Answer every question");return;}
   var updated=Reflect.copy(r.input);Reflect.setField(updated,"answers",answers);
   response={behavior:"allow",updatedInput:updated};
  } else {error("unsupported_request","Review the complete request before responding");return;}
  if(!t.respond(q.request,response)) {error("backpressure","Claude response was not queued");return;}
  s.approvals.remove(q.request);if(!s.approvals.keys().hasNext()) s.record.state="working";
  ctx.respond(view(s));
 }
 public function activeCount():Int return [for(s in sessions) if(s.busy || s.record.state == "needs-attention") true].length;
 public function updateActivityCount():Int return [for(s in sessions) if(s.transport != null) true].length
  + [for(sync in nameSync) if(sync.busy) true].length;
 public function dispose():Void {
  for(sync in nameSync) sync.dispose();nameBridge.dispose();
  for(s in sessions) if(s.transport != null) fail(s,"Workspace daemon closed; explicitly resume this session");
 }
}
