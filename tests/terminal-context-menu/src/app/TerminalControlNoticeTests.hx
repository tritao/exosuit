package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.client.RpcTerminalBackend;

/** The "Read only" strip must appear and disappear in the built tree as another client takes and gives back control. */
@:access(ui.ExosuitApp)
class TerminalControlNoticeTests {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 public static function run(fonts:haxeon.ui.FontCollection):Void {
  var clock=function() return Sys.time()*1000;
  var pair=MemoryTransport.pair(),connection=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var endpoint=new NoticeEndpoint(connection);
  var controller=true;
  function info():TerminalInfo return {id:"shared",name:"Shared",cwd:"/tmp",state:"running",exitCode:0,columns:80,rows:24,
   start:Int64.ofInt(0),end:Int64.ofInt(0),restartable:true,historyAvailable:true,controller:controller,controlled:true,notifications:true};
  server.register(WorkspaceTerminalProtocol.OPEN,function(q,ctx) ctx.respond(info()));
  server.register(WorkspaceTerminalProtocol.REPLAY,function(q,ctx) ctx.respond({terminal:info(),events:[],next:Int64.ofInt(0),end:Int64.ofInt(0)}));
  server.register(WorkspaceTerminalProtocol.OUTPUT,function(q,ctx) ctx.respond({terminal:info(),offset:q.offset,data:Bytes.alloc(0)}));
  server.register(WorkspaceTerminalProtocol.SET_CONTROL,function(q,ctx) {controller=q.claim;ctx.respond(info());});
  server.register(WorkspaceTerminalProtocol.RESIZE,function(q,ctx) ctx.respond(info()));
  function changed():Void server.notify(WorkspaceTerminalProtocol.CHANGED,{workspace:"workspace",instance:"owner",id:"shared"},WorkspaceTerminalProtocol.encodeChange);
  server.register(WorkspaceTerminalProtocol.UNWATCH,function(q,ctx) ctx.respond(q));
  function pump():Void {server.poll();connection.poll();}
  var backend=new RpcTerminalBackend(function() return endpoint,"shared","/tmp",false);
  var session=new terminalsession.TerminalSession(backend,terminalkit.Emulator.open(80,24),false);
  var frames=0;
  var pane=new ui.TerminalPane(session,function() {frames++;},new ui.TerminalPalette(false),fonts,backend);
  var context=new haxeon.ui.core.UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(360,240);
  var root:haxeon.ui.core.RenderNode=null;
  // A frame is only built when the pane asked for one, as the application does.
  var seen=-1;
  function submit():Void {
   for(_ in 0...3) {
    pane.poll();pump();
    if(frames!=seen) {seen=frames;root=context.submit(pane,frame);}
   }
  }
  function settle(wantControl:Bool):Void {
   for(_ in 0...30) {submit();if(backend.canControl()==wantControl) break;}
   for(_ in 0...3) submit();
   require(backend.canControl()==wantControl,"backend did not reach the expected control state "+wantControl+": "+backend.controlStatus());
  }
  settle(true);
  require(!backend.needsControlNotice() && !hasNotice(root),"controlling pane drew a notice");
  controller=false;changed();
  settle(false);
  require(backend.needsControlNotice() && hasNotice(root),"pane lost control but its tree has no read-only strip");
  controller=true;changed();
  settle(true);
  require(!hasNotice(root),"pane regained control but the read-only strip stayed");
  context.dispose();pane.close();connection.close();server.close();
  trace("PASS: terminal control notice appears when another client takes control and goes when it is given back");
 }
 /** The same flip through the application, whose view cache decides whether the pane is built again; in the panel and in an editor tab, at desktop and phone width. */
 public static function runInApp(fonts:haxeon.ui.FontCollection):Void {
  for(inEditor in [false,true]) for(size in [[900.0,600.0],[390.0,800.0]]) {
   var clock=function() return Sys.time()*1000;
   var pair=MemoryTransport.pair(),connection=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
   var endpoint=new NoticeEndpoint(connection);
   var controller=true;
   function info():TerminalInfo return {id:"shared",name:"Shared",cwd:"/tmp",state:"running",exitCode:0,columns:80,rows:24,
    start:Int64.ofInt(0),end:Int64.ofInt(0),restartable:true,historyAvailable:true,controller:controller,controlled:true,notifications:true};
   server.register(WorkspaceTerminalProtocol.OPEN,function(q,ctx) ctx.respond(info()));
   server.register(WorkspaceTerminalProtocol.REPLAY,function(q,ctx) ctx.respond({terminal:info(),events:[],next:Int64.ofInt(0),end:Int64.ofInt(0)}));
   server.register(WorkspaceTerminalProtocol.OUTPUT,function(q,ctx) ctx.respond({terminal:info(),offset:q.offset,data:Bytes.alloc(0)}));
   server.register(WorkspaceTerminalProtocol.SET_CONTROL,function(q,ctx) {controller=q.claim;ctx.respond(info());});
   server.register(WorkspaceTerminalProtocol.RESIZE,function(q,ctx) ctx.respond(info()));
   function changed():Void server.notify(WorkspaceTerminalProtocol.CHANGED,{workspace:"workspace",instance:"owner",id:"shared"},WorkspaceTerminalProtocol.encodeChange);
   server.register(WorkspaceTerminalProtocol.UNWATCH,function(q,ctx) ctx.respond(q));
   var label=(inEditor?"editor":"panel")+" "+size[0]+"x"+size[1];
   var app=new ui.ExosuitApp(fonts,ui.ExosuitPalette.theme(false),null,null,null,null,false,function(_,_,_) return new StubTerminal());
   var backend=new RpcTerminalBackend(function() return endpoint,"shared","/tmp",false,null,null,true,true); // as the phone opens it: claims control, waits for its size
   var session=new terminalsession.TerminalSession(backend,terminalkit.Emulator.open(80,24),false);
   var pane=new ui.TerminalPane(session,app.requestFrame,new ui.TerminalPalette(false),fonts,backend);
   var tab=new ui.UiTerminalTab("shared","Shared","/tmp",pane,true,"shared","/tmp");
   if(inEditor) app.host.attachTerminal(tab); else {app.host.panelTerminals.push(tab);app.host.activePanelTerminalIndex=0;app.openTerminalPanel();app.host.activePanelTerminalIndex=app.host.panelTerminals.indexOf(tab);}
   var root:haxeon.ui.core.RenderNode=null;
   function step():Void {
    for(_ in 0...3) {server.poll();connection.poll();try pane.poll() catch(e:Dynamic) throw "pane.poll: "+Std.string(e)+haxe.CallStack.toString(haxe.CallStack.exceptionStack());app.pollTerminals();root=app.submit(new haxeon.ui.LayoutFrame(size[0],size[1]));}
   }
   function settle(want:Bool):Void {
    for(_ in 0...30) {step();if(backend.canControl()==want) break;}
    for(_ in 0...3) step();
    require(backend.canControl()==want,label+": backend did not reach control="+want+": "+backend.controlStatus());
   }
   settle(true);
   require(!hasNotice(root),label+": controlling pane drew a notice");
   controller=false;changed();settle(false);
   require(hasNotice(root),label+": pane lost control but the application tree has no read-only strip; status="+backend.controlStatus()+" notice="+backend.needsControlNotice()+" panes="+app.host.panelTerminals.length+" nodes="+labels(root));
   controller=true;changed();settle(true);
   require(!hasNotice(root),label+": pane regained control but the strip stayed");
   app.dispose();connection.close();server.close();
  }
  trace("PASS: terminal control notice follows control changes through the application view cache (panel and editor, desktop and phone width)");
 }
 static function labels(root:haxeon.ui.core.RenderNode):String {
  var out:Array<String>=[];
  root.walk(function(node) {if(node.semantics!=null && node.semantics.label!=null && node.semantics.label!="") out.push(node.semantics.label);});
  return out.join("|");
 }
 static function hasNotice(root:haxeon.ui.core.RenderNode):Bool {
  var found=false;
  root.walk(function(node) {if(node.semantics!=null && node.semantics.label=="Take control") found=true;});
  return found;
 }
}

private class NoticeEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/tmp";
 public function serviceGeneration():String return "owner";
 public function rpcConnection():Null<RpcConnection> return connection;
 var router:Null<workspace.client.WorkspaceTerminalEvents>;
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> {
  if(router==null) router=new workspace.client.WorkspaceTerminalEvents(connection);
  return router;
 }
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function workspaceEpoch():Null<String> return "epoch";
 public function hasCapability(capability:String):Bool return true;
}

private class StubTerminal implements ui.TerminalPanel {
 public function new() {}
 public function poll():Void {}
 public function terminate(force:Bool):Void {}
 public function close():Void {}
 public function status():String return "running";
 public function workspaceName():Null<String> return null;
 public function columns():Int return 80;
 public function rows():Int return 24;
 public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode
  return new haxeon.ui.widgets.text.Text("stub terminal").build(context);
}
