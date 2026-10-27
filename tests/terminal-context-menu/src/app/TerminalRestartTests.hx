package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.client.RpcTerminalBackend;

class TerminalRestartTests {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run(fonts:haxeon.ui.FontCollection):Void {
  var clock=function() return Sys.time()*1000;
  var pair=MemoryTransport.pair(),connection=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var endpoint=new RestartEndpoint(connection);
  var state="exited", supported=false, requests=0, opens=0, mode="", pendingOpen:Null<haxeon.rpc.RpcContext<TerminalInfo>>=null;
  var record:TerminalRecord={id:"ended",name:"Saved terminal",cwd:"/tmp",workspaceRoot:"/tmp",group:"work",instance:"owner",
   revision:Int64.ofInt(1),state:state,exitCode:0,available:true};
  function info():TerminalInfo return {id:"ended",name:record.name,cwd:record.cwd,state:state,exitCode:0,columns:80,rows:24,
   start:Int64.ofInt(0),end:Int64.ofInt(0),restartable:supported,historyAvailable:true,controller:state=="running",controlled:state=="running"};
  server.register(WorkspaceTerminalProtocol.LIST,function(q,ctx) ctx.respond({instance:"owner",workspaceRoot:"/tmp",groups:[],terminals:[record],next:null}));
  server.register(WorkspaceTerminalProtocol.OPEN,function(q,ctx) {
   require(!q.create,"restart created a new terminal resource");opens++;
   if(mode=="defer") pendingOpen=ctx;else ctx.respond(info());
  });
  server.register(WorkspaceTerminalProtocol.RESTART,function(q,ctx) {
   requests++;
   if(mode=="error") {ctx.fail({code:"terminal_restart_failed",message:"Shell startup failed; saved history retained",ambiguous:true});return;}
   state="running";record.state=state;record.revision+=1;ctx.respond(info());
  });
  server.register(WorkspaceTerminalProtocol.REPLAY,function(q,ctx) ctx.respond({terminal:info(),events:[],next:Int64.ofInt(0),end:Int64.ofInt(0)}));
  server.register(WorkspaceTerminalProtocol.OUTPUT,function(q,ctx) ctx.respond({terminal:info(),offset:q.offset,data:Bytes.alloc(0)}));
  server.register(WorkspaceTerminalProtocol.SET_CONTROL,function(q,ctx) ctx.respond(info()));
  server.register(WorkspaceTerminalProtocol.RESIZE,function(q,ctx) ctx.respond(info()));
  server.register(WorkspaceTerminalProtocol.UNWATCH,function(q,ctx) ctx.respond(q));
  var client=new RpcWorkspaceWorkbenchClient(endpoint,clock);
  function pump():Void {server.poll();connection.poll();}
  client.poll();client.refreshTerminals(true);for(_ in 0...3) pump();
  function current():TerminalRecord {var catalog=client.terminalCatalog();if(catalog==null) throw "catalog missing";return catalog.terminals[0];}
  client.restartTerminal(current());for(_ in 0...5) pump();
  var error=client.terminalCatalogError();
  require(requests==0 && error!=null && error.indexOf("Update the workspace service")>=0,"unsupported restart was sent or error lost to refresh");
  supported=true;
  var stale:TerminalRecord=cast Reflect.copy(current());stale.revision+=1;
  client.restartTerminal(stale);for(_ in 0...3) pump();require(requests==0,"stale context menu restarted terminal");
  mode="defer";client.restartTerminal(current());pump();
  require(pendingOpen!=null,"restart probe not issued");endpoint.control=false;
  var pending=pendingOpen;if(pending==null) throw "pending probe missing";pending.respond(info());for(_ in 0...4) pump();
  require(requests==0,"lost control permission did not fence restart");endpoint.control=true;mode="";
  client.restartTerminal(current());client.restartTerminal(current());for(_ in 0...6) pump();
  require(requests==1 && current().state=="running" && current().id=="ended","restart duplicated process or failed catalog refresh");
  client.restartTerminal(current());for(_ in 0...3) pump();require(requests==1,"running terminal restarted again");
  state="exited";record.state=state;record.revision+=1;client.refreshTerminals(true);for(_ in 0...3) pump();
  var backend=new RpcTerminalBackend(function() return endpoint,"ended","/tmp",false);
  var session=new terminalsession.TerminalSession(backend,terminalkit.Emulator.open(80,24),false);
  var pane=new ui.TerminalPane(session,function() {},new ui.TerminalPalette(false),fonts,backend);
  var context=new haxeon.ui.core.UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(360,240);
  var root:haxeon.ui.core.RenderNode=null;
  function submit():Void {for(_ in 0...3) {pane.poll();pump();root=context.submit(pane,frame);}}
  for(_ in 0...12) submit();
  require(backend.isSynchronized() && backend.controlAction()=="Restart Terminal","ended pane missing restart affordance");
  function button():haxeon.ui.core.RenderNode {
   var found:haxeon.ui.core.RenderNode=null;
   root.walk(function(node) {if(node.semantics!=null && node.semantics.label=="Restart Terminal") found=node;});
   require(found!=null && found.focusable,"restart is not an accessible button");return found;
  }
  for(dark in [false,true]) for(width in [140.0,220.0,360.0]) {
   context.setTheme(ui.ExosuitPalette.theme(dark));frame=new haxeon.ui.LayoutFrame(width,240);submit();
   var target=button().globalBounds();
   require(target.width>0 && target.x>=0 && target.x+target.width<=width+0.1,"restart button escaped narrow viewport");
  }
  context.setTheme(ui.ExosuitPalette.theme(false));frame=new haxeon.ui.LayoutFrame(360,240);submit();
  var bounds=button().globalBounds();
  context.pointerDown(12,12,0);context.pointerUp(12,12,0);for(_ in 0...4) pump();submit();
  require(requests==1,"clicking status text restarted terminal");
  mode="error";require(context.focusWidget(button().id),"restart button cannot receive keyboard focus");
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.Enter);for(_ in 0...8) {pump();submit();}
  require(requests==2 && backend.isAvailable() && backend.isSynchronized(),"failed restart destroyed retained history attachment");
  require(backend.controlStatus().indexOf("could not be confirmed")>=0,"failed restart lacked clear feedback");
  mode="";bounds=button().globalBounds();
  context.pointerDown(bounds.x+bounds.width/2,bounds.y+bounds.height/2,0);
  context.pointerUp(bounds.x+bounds.width/2,bounds.y+bounds.height/2,0);
  for(_ in 0...8) {pump();submit();}
  require(requests==3 && backend.canControl(),"pointer retry did not restart retained terminal");
  context.dispose();pane.close();client.dispose();connection.close();server.close();
  trace("PASS: terminal restart discovery, compatibility, stale targets, permission changes, duplicate suppression, accessible button, keyboard/pointer activation and recoverable failures");
 }
}

private class RestartEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public var control=true;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/tmp";
 public function serviceGeneration():String return "owner";
 public function rpcConnection():Null<RpcConnection> return connection;
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function workspaceEpoch():Null<String> return "epoch";
 public function hasCapability(capability:String):Bool return capability!=WorkspaceTerminalProtocol.CONTROL || control;
}
