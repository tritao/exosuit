package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** A suit-on Workbench: dragging a terminal and a session out of a sub-group into a top-level group sends the menu's move calls. */
class SubgroupDropTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var now=1000.0;
  var clock=function() { return now; };
  var pair=MemoryTransport.pair();
  var connection=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  var terminal:TerminalRecord={id:"term",name:"Claude Code",group:"sub",cwd:"/workspace",instance:"owner",state:"running",exitCode:0,
   available:true,revision:Int64.ofInt(1),workspaceRoot:"/workspace"};
  var agent:AgentRecord={id:"agent",name:"Codex",group:"sub",cwd:"/workspace",thread:"thread",
   state:"disconnected",turn:null,workspaceRoot:"/workspace",provider:"codex"};
  var renames:Array<String>=[], moves:Array<String>=[];
  var heldRename:Null<haxeon.rpc.RpcContext<TerminalRecord>>=null, holdRename=false;
  server.register(WorkspaceAgentProtocol.LIST,function(q,ctx) {
   ctx.respond({instance:"owner",root:"/workspace",records:[agent],status:"",canMove:true,canRename:true});
  });
  server.register(WorkspaceTerminalProtocol.LIST,function(q,ctx) {
   ctx.respond({instance:"owner",workspaceRoot:"/workspace",next:null,terminals:[terminal],groups:[
    {id:"work",name:"Work",parent:null,cwd:null,revision:1,order:0},{id:"sub",name:"Sub",parent:"work",cwd:null,revision:1,order:0},
    {id:"other",name:"Other",parent:null,cwd:null,revision:1,order:1}]});
  });
  server.register(WorkspaceTerminalProtocol.RENAME,function(q,ctx) {
   require(q.expectedRevision==terminal.revision && q.name==terminal.name,"terminal move changed the name or lost the revision");
   renames.push(q.group);terminal.group=q.group;terminal.revision=Int64.add(terminal.revision,Int64.ofInt(1));
   if(holdRename) heldRename=ctx; else ctx.respond(terminal);
  });
  server.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   if(q.action=="move") {
    require(q.request==agent.group,"session move sent the wrong source group");
    moves.push(q.text);agent.group=q.text;
   }
   ctx.respond({record:agent,activity:"",requests:[],error:null});
  });
  var client=new RpcWorkspaceWorkbenchClient(new SubgroupEndpoint(connection),clock);
  function pump():Void {for(_ in 0...2) {client.poll();server.poll();connection.poll();}}
  pump();client.refreshTerminals(true);client.refreshAgents();pump();
  var menuItems:Array<haxeon.ui.widgets.overlays.MenuItem>=[];
  var created:Array<String>=[];
  var panel=new ui.WorkbenchPanel(client,function(_) { return true; },function(group) { created.push(group); },function(_,_) {},function(_) {},
   function(_) { return []; },function() {},function(_) {},function(items,_,_) {menuItems=items;},function(_) {},function(_,_) {},
   function(_,group) { created.push(group); },function() { return true; });
  var view:ui.WorkbenchMachineView={machine:{id:"m",name:"cube",workspaces:[{id:"resume",name:"resume-2026",folders:["/workspace"],scratch:null,revision:1},
   {id:"elsewhere",name:"elsewhere",folders:["/elsewhere"],scratch:null,revision:1}]},error:null,openWorkspace:"resume",openRoots:["/workspace"],revision:1};
  panel.machine={view:function() { return view; },busy:function() { return false; },open:function(_) {},create:function() {},
   rename:function(_) {},attachFolder:function(_) {},remove:function(_) {}};
  var fonts=haxeon.ui.FontCollection.create();fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var context=new UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(320,600);
  var root:RenderNode=null;
  function submit():Void {for(_ in 0...3) root=context.submit(panel,frame);}
  function row(label:String):haxeon.ui.Rect {
   var result:RenderNode=null;
   root.walk(function(node) {if(node.semantics!=null && node.semantics.label==label) result=node;});
   require(result!=null,"missing workbench row "+label);return result.globalBounds();
  }
  function drag(from:String,to:String):Void {
   var source=row(from),target=row(to);
   context.pointerDown(120,source.y+source.height/2,0);context.pointerMove(120,target.y+target.height/2);submit();
   context.pointerUp(120,target.y+target.height/2,0);pump();submit();
  }
  submit();panel.tree.setExpanded("g:sub",true);submit();
  var machinePicker=false;
  root.walk(function(node) {var sem=node.semantics;if(sem!=null && sem.label=="Machine") machinePicker=true;});
  require(machinePicker && panel.model.rootKeyAt(0)=="w:resume","the machine is not chosen above a tree of workspaces");
  require(panel.model.openRow=="w:resume" && panel.model.groupParent=="w:resume","groups did not sit under the open workspace");
  for(target in ["g:sub","w:elsewhere","n:new-workspace"]) {
   drag("t:term",target);drag("a:agent",target);
   require(renames.length==0 && moves.length==0,"drop onto "+target+" was accepted");
  }
  holdRename=true;drag("t:term","g:work");
  require(renames.join(",")=="work" && heldRename!=null && client.terminalCatalogBusy(),"terminal did not move to the top-level group");
  drag("a:agent","g:work");
  require(moves.length==0,"session moved while the terminal catalog was busy");
  holdRename=false;var held=heldRename;if(held!=null) held.respond(terminal);
  now+=2000;client.refreshTerminals(true);pump();submit();
  var moved=panel.model.terminals.get("term");
  require(moved!=null && moved.group=="work" && !client.terminalCatalogBusy(),"moved terminal did not reach its new group");
  panel.tree.select("a:agent");submit();
  context.key(UiEventKind.KeyDown,haxeon.ui.core.UiKey.F2);submit();
  var renaming=false;
  root.walk(function(node) {var sem=node.semantics;if(sem!=null && sem.label=="Workbench label") renaming=true;});
  require(renaming,"F2 did not start the session rename");
  context.text(UiEventKind.TextInput,"Unsaved");submit();
  // Pressing another row ends the rename unsaved, as a click does, so the drag that follows goes ahead.
  drag("t:term","g:other");
  var editor=false;
  root.walk(function(node) {var sem=node.semantics;if(sem!=null && sem.label=="Workbench label") editor=true;});
  require(!editor && agent.name=="Codex" && renames.join(",")=="work,other","drag past an open rename saved it or did not move");
  drag("a:agent","g:work");
  require(moves.join(",")=="work" && agent.group=="work","session did not move to the top-level group");
  now+=2000;client.refreshAgents();pump();submit();
  drag("a:agent","g:work");
  require(moves.length==1,"drop onto the session's own group was accepted");
  // The open workspace's row is the workspace root: no group.
  drag("t:term","w:resume");drag("a:agent","w:resume");
  require(renames.join(",")=="work,other," && moves.join(",")=="work,","drop onto the workspace row did not move to the root");
  now+=2000;client.refreshTerminals(true);client.refreshAgents();pump();submit();
  require(panel.model.childKeyAt("w:resume",panel.model.childCount("w:resume")-1)=="a:agent","root items did not follow the groups");
  drag("t:term","w:resume");drag("a:agent","w:resume");
  require(renames.length==3 && moves.length==2,"drop onto the workspace row accepted an item already at the root");
  drag("t:term","g:sub");
  require(renames.join(",")=="work,other,,sub","item did not move from the root into a sub-group");
  now+=2000;client.refreshTerminals(true);client.refreshAgents();pump();submit();
  // New terminal and New Codex create in the selected row's group, else at the workspace root.
  function press(styleKey:String):Void {
   var actions=context.submit(panel.headerActions(300),frame),found:RenderNode=null;
   actions.walk(function(node) { if(node.styleKey==styleKey) found=node; });
   require(found!=null,"missing header action "+styleKey);
   var box=found.globalBounds();
   context.pointerDown(box.x+box.width/2,box.y+box.height/2,0);context.pointerUp(box.x+box.width/2,box.y+box.height/2,0);submit();
  }
  for(key in ["a:agent","t:term","g:work","w:resume"]) {panel.tree.select(key);press("workbench-new-terminal");press("workbench-new-codex");}
  require(created.join(",")==",,sub,sub,work,work,,","new items did not follow the selection to its group or the root: "+created.join(","));
  context.dispose();fonts.dispose();client.dispose();connection.close();server.close();
  trace("PASS: sub-group terminal and session drops onto a top-level group; the workspace row as root; own group, other rows and a busy catalog refused; a press ends an open rename unsaved; new items go to the selected group or the root");
 }
}

private class SubgroupEndpoint implements workspace.client.WorkspaceRpcEndpoint {
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
