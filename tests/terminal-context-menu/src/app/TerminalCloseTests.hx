package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.client.RpcWorkspaceWorkbenchClient;
import haxeon.ui.widgets.overlays.MenuItem;

@:access(ui.ExosuitApp)
@:access(ui.CommandMenu)
class TerminalCloseTests {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run(app:ui.ExosuitApp):Void {
  var pair=MemoryTransport.pair(),clock=function() return Sys.time()*1000;
  var connection=new RpcConnection(pair.client,clock),server=new RpcConnection(pair.server,clock);
  var endpoint=new CloseEndpoint(connection),client=new RpcWorkspaceWorkbenchClient(endpoint,clock);
  var record:TerminalRecord={id:"close-target",name:"Target",group:"work",cwd:"/tmp",workspaceRoot:"/tmp",instance:"owner",
   state:"running",exitCode:0,available:true,revision:Int64.ofInt(1)};
  var records=[record],calls=0,pending:Null<haxeon.rpc.RpcContext<TerminalTarget>>=null;
  server.register(WorkspaceTerminalProtocol.LIST,function(q,ctx) ctx.respond({instance:"owner",workspaceRoot:"/tmp",terminals:records,next:null,
   groups:[{id:"work",name:"Work",cwd:"/tmp",revision:1}]}));
  server.register(WorkspaceTerminalProtocol.FORGET,function(q,ctx) {
   require(q.terminate==true && q.id==record.id && q.resourceInstance==record.instance && Int64.compare(q.expectedRevision,record.revision)==0,
    "close omitted force-stop or exact resource identity");calls++;pending=ctx;
  });
  function pump():Void {for(_ in 0...3) {server.poll();connection.poll();}}
  client.poll();client.refreshTerminals(true);pump();
  app.attachWorkbench(client);
  var targetPanel=new CloseView(),editorPanel=new CloseView(),hiddenPanel=new CloseView();
  var target=new ui.UiTerminalTab("close-panel","Target","/tmp",targetPanel,true,record.id,"/tmp");
  var editor=new ui.UiTerminalTab("close-editor","Target editor","/tmp",editorPanel,true,record.id,"/tmp");
  var hidden=new ui.UiTerminalTab("close-hidden","Target hidden","/tmp",hiddenPanel,true,record.id,"/tmp");
  target.retainOnClose=true;editor.retainOnClose=true;hidden.retainOnClose=true;
  var activeBefore=app.host.activePanelTerminal();
  app.host.panelTerminals.insert(0,target);app.host.activePanelTerminalIndex++;
  app.host.activePane.items.push(ui.UiEditorTab.Terminal(editor));
  app.host.hiddenTerminals.push(hidden);
  var root=app.submit(new haxeon.ui.LayoutFrame(900,600));
  var event=new haxeon.ui.core.UiEvent(haxeon.ui.core.UiEventKind.PointerDown,root.id,100,100,0,0,1);
  function closeAction():MenuItem {
   app.showTerminalContextMenu(target,event);
   var menu:ui.CommandMenu=cast app.contextMenu,items:Array<MenuItem>=cast menu.customItems;
   var result:MenuItem=null;
   for(item in items) {
    require(item.label!="Close Terminal View" && item.label!="Remove from Workbench","redundant terminal close actions remain");
    if(item.key=="terminal-close") result=item;
   }
   require(result!=null && result.label=="Close Terminal","resource close missing from terminal context menu");return result;
  }
  var selected=closeAction();selected.onSelect();pump();
  require(calls==1 && client.terminalCatalogBusy() && !target.disposed && !editor.disposed && !hidden.disposed,"close disposed views before service confirmation");
  var failed=pending;if(failed==null) throw "close request missing";
  failed.fail({code:"storage_failed",message:"Unable to remove saved terminal",ambiguous:true});pump();
  require(!target.disposed && !editor.disposed && !hidden.disposed && records.length==1,"failed close discarded terminal views");
  var error=client.terminalCatalogError();require(error!=null && error.indexOf("kept open")>=0,"failed close lost recovery feedback");
  closeAction().onSelect();pump();require(calls==2,"close retry did not reach service");
  client.closeTerminal(record);pump();require(calls==2,"duplicate close was issued while busy");
  records=[];var confirmed=pending;if(confirmed==null) throw "close retry missing";
  confirmed.respond({workspace:"workspace",instance:"owner",id:record.id});pump();
  require(target.disposed && editor.disposed && hidden.disposed && targetPanel.closes==1 && editorPanel.closes==1 && hiddenPanel.closes==1,"confirmed close missed or double-closed a view");
  require(app.host.allTerminalTabs().indexOf(target)<0 && app.host.allTerminalTabs().indexOf(editor)<0 && app.host.hiddenTerminals.indexOf(hidden)<0,"closed terminal remained retained in Workbench layout");
  require(app.host.activePanelTerminal()==activeBefore,"closing target changed another terminal's active selection");
  var catalog=client.terminalCatalog();require(catalog!=null && catalog.terminals.length==0,"closed entry remained in client catalog");
  selected.onSelect();pump();require(calls==2,"stale menu acted on removed terminal");
  app.detachWorkbench(client);client.dispose();connection.close();server.close();
  trace("PASS: Close Terminal confirms removal before disposing all views, keeps failed closes, preserves other terminals and rejects duplicate/stale actions");
 }
}
private class CloseView implements ui.TerminalPanel {
 public var closes=0;
 public function new() {}
 public function poll():Void {}
 public function terminate(force:Bool):Void throw "View must not terminate the service resource itself";
 public function close():Void closes++;
 public function status():String return "running";
 public function workspaceName():Null<String> return null;
 public function columns():Int return 80;
 public function rows():Int return 24;
 public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode return new haxeon.ui.widgets.text.Text("remote fixture").build(context);
}
private class CloseEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/tmp";
 public function serviceGeneration():String return "owner";
 public function rpcConnection():Null<RpcConnection> return connection;
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function workspaceEpoch():Null<String> return "epoch";
 public function hasCapability(value:String):Bool return [WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG].indexOf(value)>=0;
}
