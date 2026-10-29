package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.provider.*;
import workspace.service.WorkspaceAgentProtocol;
import workspace.runtime.WorkspaceDirectories;
import process.ProcessManager;

@:access(workspace.provider.CodexProvider)
@:access(workspace.provider.AgentNameSync)
class NativeSessionNamesTestMain {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 static function main():Void {
  var args=Sys.args(),root=args[0],repo=args[1];
  var offset=0.0;
  var clock=function() return Sys.time()*1000+offset;
  var directories=new WorkspaceDirectories(root),processes=new ProcessManager();
  for(kind in ["codex","claude"]) {
   var record:AgentRecord={id:kind,name:"Existing local label",group:"work",cwd:directories.root,thread:kind=="codex" ? "native-codex" : "12345678-1234-1234-1234-123456789abc",
    state:"disconnected",turn:null,workspaceRoot:directories.root,provider:kind,permissionMode:"default"};
   var store=new NameStore(record);
   var codex:Null<CodexProvider>=null;
   var provider:LocalAgentProvider;
   if(kind=="codex") {
    var selected=new CodexProvider("owner",directories,function() return [],processes,clock,store);
    var python=Sys.getEnv("EXOSUIT_TEST_PYTHON");
    if (python==null || python=="") python="python3";
    var child=processes.start(python,[repo+"/tests/native-session-names/fake-codex-names.py",root],root);
    selected.transport=new CodexTransport(child);selected.proxy=child;selected.phase="ready";
    var session=selected.sessions.get(kind);if(session==null) throw "missing seeded Codex session";
    session.reconnectBlocked=true;selected.names(session).nextRead=clock()+100000;
    codex=selected;provider=selected;
   } else provider=new ClaudeProvider(directories,function() return [],processes,clock,store,"exosuit-must-not-launch-claude");
   var service=new WorkspaceAgentService("w","owner",directories.root,[provider],store);
   var pair=MemoryTransport.pair(),client=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
   service.bind(server,[WorkspaceAgentProtocol.READ,WorkspaceAgentProtocol.CONTROL]);
   function pump():Void {server.poll();service.poll();client.poll();Sys.sleep(0.002);}
   function wait(done:Void->Bool):Void {var until=clock()+10000;while(!done()) {require(clock()<until,"metadata operation timed out for "+kind);pump();}}
   var catalog:Null<AgentCatalog>=null;
   client.call(WorkspaceAgentProtocol.LIST,{workspace:"w",instance:"owner"},1000,function(value) catalog=value,function(error) throw error.message);
   wait(function() return catalog!=null);
   require(catalog!=null && catalog.nativeRenameProviders!=null && catalog.nativeRenameProviders.indexOf(kind)>=0,"provider omitted native naming capability");
   var value:Null<AgentView>=null,code="";
   function view():AgentView return cast value;
   function metadata():AgentNameMetadata return cast view().record.nameMetadata;
   function action(action:String,text:String="",?expected:String,?nativeName:String):Void {
    var done=false;value=null;code="";
    client.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:kind,action:action,text:text,request:expected,expectedNativeName:nativeName},5000,
     function(result) {value=result;done=true;},function(error) {code=error.code;done=true;});
    wait(function() return done);
   }
   wait(function() {action("inspect-name");return code!="busy";});
   require(code=="" && view().record.name=="Existing local label" && view().record.nameMetadata!=null,"inspection did not preserve legacy local label");
   var initial=view().record.nameMetadata;if(initial==null) throw "missing inspected metadata";
   action("rename-native","Synced α","Existing local label",initial.nativeName);
   require(code=="" && view().record.name=="Synced α" && store.record.name=="Synced α" && view().record.state=="disconnected","native rename resumed or failed to persist "+kind+": "+code);
   require(view().record.cwd==record.cwd && view().record.thread==record.thread && view().record.nameMetadata!=null && metadata().pending==null,"native rename changed identity or left intent");
   function external(name:String):Void {
    if(kind=="codex") sys.io.File.saveContent(root+"/title.json",haxe.Json.stringify(name));
    else {
     var child=processes.start("node",[repo+"/tests/native-session-names/external-claude-name.mjs",repo+"/agent/naming/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs",record.thread,root,name],root);
     wait(function() return child.exited());require(child.exitStatus()==0,child.readStderr());processes.release(child);
    }
   }
   external("Changed outside Exosuit");offset+=6000;
   wait(function() return store.record.name=="Changed outside Exosuit");
   action("rename-native","Must not overwrite","Synced α","Synced α");
   require(code=="conflict" && store.record.name=="Changed outside Exosuit","external native rename was overwritten");
   action("inspect-name");require(code=="" && view().record.name=="Changed outside Exosuit","external native name was not synchronized");
   action("rename","Pinned local label","Changed outside Exosuit");require(code=="","local-only override failed");
   external("Another native name");offset+=6000;
   wait(function() {var metadata=store.record.nameMetadata;return metadata!=null && metadata.nativeName=="Another native name";});
   action("inspect-name");
   require(code=="" && view().record.name=="Pinned local label" && view().record.nameMetadata!=null && metadata().nativeName=="Another native name","native refresh overwrote explicit local label");
   if(kind=="codex") {
    sys.io.File.saveContent(root+"/unsupported-name-set","");
    action("rename-native","Unsupported native","Pinned local label","Another native name");
    require(code=="unsupported_operation" && store.record.name=="Pinned local label" && !provider.nativeNamingSupported(),
     "older Codex naming support silently fell back or changed local state");
    sys.FileSystem.deleteFile(root+"/unsupported-name-set");
   }
   var roPair=MemoryTransport.pair(),ro=new RpcConnection(roPair.client,clock),roServer=new RpcConnection(roPair.server,clock);
   service.bind(roServer,[WorkspaceAgentProtocol.READ]);var denied=false;
   ro.call(WorkspaceAgentProtocol.ACTION,{workspace:"w",instance:"owner",id:kind,action:"rename-native",text:"Denied",request:"Pinned local label",expectedNativeName:"Another native name"},1000,
    function(_) throw "read-only native rename was accepted",function(error) denied=error.code=="unauthorized");
   roServer.poll();ro.poll();require(denied,"native rename permission was not enforced");
   ro.close();roServer.close();client.close();server.close();service.dispose();
  }
  processes.shutdown();
  trace("PASS: Codex and Claude native naming RPCs, disconnected sessions, scope/identity, external edits, conflicts, local overrides, durable intent and permissions without agent/model execution");
 }
}
private class NameStore implements workspace.service.WorkspaceAgentPersistence {
 public var record:AgentRecord;
 public function new(record:AgentRecord) this.record=cast Reflect.copy(record);
 public function loadAgents():Array<AgentRecord> return [cast Reflect.copy(record)];
 public function saveAgent(value:AgentRecord):Void record=cast Reflect.copy(value);
 public function removeAgent(id:String):Void throw "unexpected removal";
}
