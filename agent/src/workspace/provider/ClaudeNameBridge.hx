package workspace.provider;

import haxeon.rpc.RpcError;
import process.OwnedProcess;
import process.ProcessManager;
import workspace.provider.AgentNameSync.NativeNameReadDone;

/** Persistent, bounded bridge to the pinned SDK's metadata-only functions. */
class ClaudeNameBridge {
 final processes:ProcessManager;
 final clock:Void->Float;
 final root:String;
 final script:Null<String>;
 final node:Null<String>;
 var process:Null<OwnedProcess>;
 var transport:Null<AgentJsonTransport>;
 var retryAt=0.0;
 public function new(processes:ProcessManager,clock:Void->Float,root:String,script:Null<String>) {
  this.processes=processes;this.clock=clock;this.root=root;this.script=script;this.node=findNode();
 }
 public static function findScript(?launcher:String):Null<String> {
  var configured=Sys.getEnv("EXOSUIT_CLAUDE_NAMING_HELPER");
  if(configured!=null && configured!="") return configured;
  var directory=haxe.io.Path.directory(launcher==null ? Sys.programPath() : launcher);
  for(_ in 0...8) {
   for(relative in ["claude-naming/claude-session-names.mjs","agent/naming/claude-session-names.mjs"]) {
    var candidate=haxe.io.Path.join([directory,relative]);
    if(sys.FileSystem.exists(candidate)) return candidate;
   }
   var parent=haxe.io.Path.directory(directory);if(parent==directory || parent=="") break;directory=parent;
  }
  return null;
 }
 static function findNode():Null<String> {
  var configured=Sys.getEnv("EXOSUIT_NODE_BIN"),path=Sys.getEnv("PATH");
  var name=configured==null ? (Sys.systemName()=="Windows" ? "node.exe" : "node") : configured;
  if(name.indexOf("/")>=0 || name.indexOf("\\")>=0) return sys.FileSystem.exists(name) && !sys.FileSystem.isDirectory(name) ? name : null;
  if(path!=null) for(directory in path.split(Sys.systemName()=="Windows" ? ";" : ":")) {
   if(directory=="") continue;
   var candidate=haxe.io.Path.join([directory,name]);
   if(sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate)) return candidate;
  }
  return null;
 }
 public function available():Bool return node!=null && script!=null && sys.FileSystem.exists(script)
  && sys.FileSystem.exists(haxe.io.Path.directory(script)+"/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs");
 function call(method:String,params:Dynamic,done:language.JsonRpcResponse->Void):Void {
  if(!available()) {done(new language.JsonRpcResponse(null,"unsupported: Native Claude naming requires Node.js 18.14+ and the packaged metadata adapter"));return;}
  if(transport==null && clock()>=retryAt) {
   try {
    var executable=node,helper=script;
    if(helper==null || executable==null) throw "Metadata helper or Node.js is missing";
    var child=processes.start(executable,[helper,root],root);
    process=child;transport=new AgentJsonTransport(child,"Claude session metadata");
   } catch(_:Dynamic) {retryAt=clock()+10000;}
  }
  var current=transport;
  if(current==null) {done(new language.JsonRpcResponse(null,"provider_starting: Claude session metadata helper is reconnecting; retry shortly"));return;}
  current.request(method,params,clock(),done);
 }
 static function failure(message:String):RpcError return {
  code:StringTools.startsWith(message,"conflict:") ? "conflict" : StringTools.startsWith(message,"unsupported:") ? "unsupported_operation" : StringTools.startsWith(message,"provider_starting:") ? "provider_starting" : "provider_error",
  message:message,ambiguous:message.toLowerCase().indexOf("timeout")>=0
 };
 public function read(session:String,cwd:String,done:NativeNameReadDone):Void {
  call("session/name/read",{sessionId:session,cwd:cwd},function(result) {
   if(result.error!=null) {done(null,failure(result.error));return;}
   var name:Dynamic=result.result==null ? null : Reflect.field(result.result,"name");
   if(name!=null && !Std.isOfType(name,String)) {done(null,failure("Invalid native name response"));return;}
   done(name,null);
  });
 }
 public function write(session:String,cwd:String,name:String,expected:Null<String>,done:Null<RpcError>->Void):Void {
  call("session/name/set",{sessionId:session,cwd:cwd,name:name,expected:expected},function(result) done(result.error==null ? null : failure(result.error)));
 }
 public function poll():Void {
  var current=transport;if(current==null) return;
  current.poll(clock());
  if(current.failure!=null) {dispose();retryAt=clock()+10000;}
 }
 public function dispose():Void {
  if(transport!=null) transport.close("Metadata bridge closed");transport=null;
  if(process!=null) processes.release(process);process=null;
 }
}
