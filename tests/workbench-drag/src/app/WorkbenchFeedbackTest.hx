package app;

import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceTerminalProtocol;

class WorkbenchFeedbackTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var now=1000.0, supported:Null<Bool>=null, requests=0;
  var deferCatalog=false;
  var pendingCatalog:Null<haxeon.rpc.RpcContext<AgentCatalog>>=null;
  var clock=function() return now;
  var pair=MemoryTransport.pair();
  var connection=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  var agent:AgentRecord={id:"agent",name:"Claude",group:"work",cwd:"/workspace",thread:"native-thread",
   state:"disconnected",turn:null,workspaceRoot:"/workspace",provider:"claude"};
  server.register(WorkspaceAgentProtocol.LIST,function(q,ctx) {
   if(deferCatalog) pendingCatalog=ctx;
   else ctx.respond({instance:"owner",root:"/workspace",records:[agent],status:"",canMove:supported,canRename:supported});
  });
  server.register(WorkspaceTerminalProtocol.LIST,function(q,ctx)
   ctx.respond({instance:"owner",workspaceRoot:"/workspace",next:null,terminals:[],groups:[
    {id:"work",name:"Work",parent:null,cwd:null,revision:1},{id:"other",name:"Other",parent:null,cwd:null,revision:1}]}));
  server.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   requests++;require(q.action=="move" || q.action=="rename","metadata edit sent a native-session command");
   if(q.action=="move") agent.group=q.text;else agent.name=q.text;
   ctx.respond({record:agent,activity:"",requests:[],error:null});
  });
  var client=new RpcWorkspaceWorkbenchClient(new FeedbackEndpoint(connection),clock);
  function pump():Void {client.poll();server.poll();connection.poll();}
  pump();client.refreshTerminals(true);client.refreshAgents();pump();
  var menuItems:Array<haxeon.ui.widgets.overlays.MenuItem>=[];
  var panel=new ui.WorkbenchPanel(client,function(_) return true,function(_) {},function(_,_) {},function(_) {},function(_) return [],
   function() {},function(_) {},function(items,_,_) menuItems=items,function(_) {},function(_,_) {},function(_,_) {},function() return true);
  var center=new feedback.NotificationCenter();
  panel.onError=function(message) center.publish(message,feedback.NotificationKind.Error,"workbench");
  var fonts=haxeon.ui.FontCollection.create();fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var context=new UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(300,240);
  var root:RenderNode=null;
  function submit():Void {for(_ in 0...3) root=context.submit(panel,frame);}
  function row(label:String):haxeon.ui.Rect {
   var result:RenderNode=null;
   root.walk(function(node) {if(node.semantics!=null && node.semantics.label==label) result=node;});
   require(result!=null,"missing workbench row "+label);return result.globalBounds();
  }
  function drop():Void {
   var from=row("a:agent"),target=row("g:other");
   context.pointerDown(120,from.y+15,0);context.pointerMove(120,target.y+15);submit();
   context.pointerUp(120,target.y+15,0);pump();submit();
  }
  submit();
  client.agentAction("agent","rename","Renamed","Claude");pump();submit();
  require(requests==0 && center.entries.length==1 && center.entries[0].message.indexOf("rename agent sessions")>=0,
   "legacy service received rename or did not explain upgrade");
  center.clear();
  var initialY=row("g:work").y;drop();
  require(requests==0 && center.entries.length==1,"legacy daemon received unsupported move or missing notification");
  require(center.entries[0].message.indexOf("Update the workspace service")>=0,"legacy move showed native resume error");
  require(row("g:work").y==initialY,"error displaced workbench tree: "+initialY+" -> "+row("g:work").y);
  center.dismissToast();submit();require(center.entries.length==1 && center.current()==null,"sticky error republished after dismissal");
  supported=true;now+=2000;client.refreshAgents();pump();submit();drop();
  require(requests==1 && agent.group=="other","updated service could not move disconnected Claude session");
  var agentBounds=row("a:agent");
  context.pointerDown(120,agentBounds.y+15,1);context.pointerUp(120,agentBounds.y+15,1);submit();
  var rename:haxeon.ui.widgets.overlays.MenuItem=null;
  for(item in menuItems) if(item.key=="rename-agent") rename=item;
  require(rename!=null && rename.enabled,"rename context action missing");
  rename.onSelect();submit();
  context.text(haxeon.ui.core.UiEventKind.TextInput,"Design session");submit();
  var staleAgent:AgentRecord=cast Reflect.copy(agent);
  deferCatalog=true;now+=2000;client.refreshAgents();server.poll();
  require(pendingCatalog!=null,"missing in-flight catalog coverage");
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.Enter);pump();submit();
  require(requests==2 && agent.name=="Design session","inline rename did not commit");
  var stale=pendingCatalog;
  stale.respond({instance:"owner",root:"/workspace",records:[staleAgent],status:"",canMove:true,canRename:true});
  deferCatalog=false;connection.poll();submit();
  var current=client.agents();
  require(current!=null && current.records[0].name=="Design session","accepted rename was missing or overwritten by stale catalog");
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.F2);submit();
  var hasEditor=false;
  root.walk(function(node) {if(node.semantics!=null && node.semantics.label=="Agent session name") hasEditor=true;});
  require(hasEditor,"F2 did not start agent rename");
  context.text(haxeon.ui.core.UiEventKind.TextInput,"   ");submit();
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.Enter);pump();submit();
  require(requests==2 && agent.name=="Design session","blank inline rename reached service");
  context.text(haxeon.ui.core.UiEventKind.TextInput,"Cancelled edit");submit();
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.Escape);pump();submit();
  require(requests==2 && agent.name=="Design session","Escape saved cancelled rename");
  context.key(haxeon.ui.core.UiEventKind.KeyDown,haxeon.ui.core.UiKey.F2);submit();
  context.text(haxeon.ui.core.UiEventKind.TextInput,"Unsaved blur");submit();
  var group=row("g:work");context.pointerDown(120,group.y+15,0);context.pointerUp(120,group.y+15,0);submit();
  var editorAfterBlur=false;
  root.walk(function(node) {if(node.semantics!=null && node.semantics.label=="Agent session name") editorAfterBlur=true;});
  require(!editorAfterBlur && requests==2 && agent.name=="Design session","leaving rename editor saved or stranded the draft: editor="+editorAfterBlur+", requests="+requests+", name="+agent.name+", selected="+panel.tree.selectedKey);
  var unusedPanel:ui.CodexSessionPanel=null;
  var pane=new ui.UiEditorPane("first"),second=new ui.UiEditorPane("second");
  var firstTab=new ui.UiAgentTab("view1","agent","/workspace","Old",unusedPanel);
  var secondTab=new ui.UiAgentTab("view2","agent","/workspace","Old",unusedPanel);
  var foreignTab=new ui.UiAgentTab("foreign","agent","/another-workspace","Foreign",unusedPanel);
  pane.items.push(ui.UiEditorTab.Agent(firstTab));second.items.push(ui.UiEditorTab.Agent(secondTab));
  second.items.push(ui.UiEditorTab.Agent(foreignTab));
  require(current!=null && ui.UiEditorTabs.syncAgentNames([pane,second],current),"tab titles did not synchronize");
  require(firstTab.title=="Design session" && secondTab.title=="Design session" && foreignTab.title=="Foreign",
   "rename missed a view or changed another workspace's tab");
  context.dispose();fonts.dispose();client.dispose();connection.close();server.close();
  trace("PASS: old-service feature negotiation, notification routing without tree displacement, dismissal updated-service moves, rename menu, F2, Enter and Escape");
 }
}

private class FeedbackEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/workspace";
 public function serviceGeneration():String return "owner";
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function rpcConnection():Null<RpcConnection> return connection;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function workspaceEpoch():Null<String> return "epoch";
 public function hasCapability(capability:String):Bool return true;
}
