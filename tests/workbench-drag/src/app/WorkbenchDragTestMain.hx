package app;

import haxe.Int64;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.widgets.collections.TreeView;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceAgentProtocol;
import workspace.provider.AgentMetadata;
import ui.WorkbenchDropRules;
import ui.WorkbenchTreeModel;

class WorkbenchDragTestMain {
 static function require(ok:Bool, message:String):Void {if (!ok) throw message;}
 static function main():Void {
  AgentNameSyncTest.run();
  AgentMoveTest.run();
  WorkbenchFeedbackTest.run();
  var catalog:TerminalCatalog = {instance:"owner",workspaceRoot:"/workspace",next:null,
   groups:[{id:"one",name:"One",parent:null,cwd:null,revision:1},
    {id:"two",name:"Two",parent:null,cwd:null,revision:1},
    {id:"child",name:"Child",parent:"one",cwd:null,revision:1}],
   terminals:[{id:"term",name:"Terminal",group:"one",cwd:"/original",instance:"owner",state:"running",exitCode:0,
    available:true,revision:Int64.ofInt(1)}]};
  var record:AgentRecord = {id:"agent",name:"Agent",group:"one",cwd:"/original",thread:"thread",state:"disconnected",
   turn:null,workspaceRoot:"/workspace"};
  var agents:AgentCatalog = {instance:"owner",root:"/workspace",records:[record],status:""};
  function canDrop(a:String,b:String):Bool return WorkbenchDropRules.canDrop(a,b,catalog,agents);
  require(canDrop("t:term","g:two") && canDrop("a:agent","g:two") && canDrop("g:one","g:two"),"valid moves rejected");
  require(!canDrop("g:one","g:child") && !canDrop("g:one","g:one"),"group cycle accepted");
  require(!canDrop("t:term","g:one") && !canDrop("a:agent","g:missing") && !canDrop("g:one","t:term"),"invalid destination accepted");
  agents.instance="other"; require(!canDrop("a:agent","g:two"),"foreign catalog accepted"); agents.instance="owner";
  var saves=0;
  require(AgentMetadata.move(record,"one","two",catalog.groups,function() saves++) == null && saves==1,"agent move not persisted");
  require(record.cwd=="/original" && record.thread=="thread", "move changed native session identity");
  require(AgentMetadata.move(record,"one","one",catalog.groups,function() saves++)=="conflict","stale move accepted");
  require(AgentMetadata.move(record,"two","missing",catalog.groups,function() saves++)=="unknown_group","missing group accepted");
  var failed=false;
  try AgentMetadata.move(record,"two","one",catalog.groups,function() {throw "storage failure";}) catch (_:Dynamic) failed=true;
  require(failed && record.group=="two", "failed persistence changed live grouping");
  record.group="one";
  var model=new WorkbenchTreeModel(); model.update(catalog,agents);
  var fonts=haxeon.ui.FontCollection.create();
  fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var context=new UiContext(null,fonts);
  var style=new LayoutStyle();style.width=LayoutAxis.grow();style.height=LayoutAxis.grow();
  var tree=new TreeView("drag-tree",model,style);
  tree.canDragItem=function(_) return true; tree.canDropItem=canDrop;
  var drops=0,clicks=0;
  tree.onItemDrop=function(a,b) {require(a=="t:term" && b=="g:two","wrong drop");drops++;};
  tree.onItemClicked=function(_,_) clicks++;
  var frame=new haxeon.ui.LayoutFrame(300,300);
  var root:RenderNode=null;
  function submit():Void {for (_ in 0...2) root=context.submit(tree,frame);}
  function row(key:String):haxeon.ui.Rect {
   var found:RenderNode=null;
   root.walk(function(node) {if(node.semantics!=null && node.semantics.label==key) found=node;});
   require(found!=null,"missing row "+key);return found.globalBounds();
  }
  submit();
  var from=row("t:term"),to=row("g:two");
  context.pointerDown(100,from.y+15,0); context.pointerUp(100,from.y+15,0);submit();
  require(clicks==1 && drops==0,"drag support broke normal clicks");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  context.pointerUp(100,to.y+15,0);submit();
  require(drops==1 && clicks==1 && tree.selectedKey=="t:term","drag failed, lost selection or activated source");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  context.key(UiEventKind.KeyDown,UiKey.Escape);context.pointerUp(100,to.y+15,0);submit();
  require(drops==1,"Escape failed to cancel drag");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  context.pointerCancel(0,100,to.y+15);context.pointerUp(100,to.y+15,0);submit();
  require(drops==1,"pointer cancel committed a drop");
  context.pointerDown(100,from.y+15,0);context.pointerMove(400,280);context.pointerUp(400,280,0);submit();
  require(drops==1,"drop outside tree committed");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  tree.canDropItem=function(_,_) return false;
  context.pointerUp(100,to.y+15,0);submit();require(drops==1,"release did not revalidate policy");
  tree.canDropItem=canDrop;
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  var replacement=new TreeView("drag-tree",model,style);
  replacement.canDragItem=tree.canDragItem;replacement.canDropItem=tree.canDropItem;
  replacement.onItemDrop=tree.onItemDrop;replacement.onItemClicked=tree.onItemClicked;
  tree=replacement;submit();context.pointerUp(100,to.y+15,0);submit();
  require(drops==2,"declarative rebuild lost the drag gesture");
  catalog.groups.push({id:"nested",name:"Nested",parent:"two",cwd:null,revision:1});
  model.update(catalog,agents);tree.setExpanded("g:two",false);submit();
  from=row("t:term");to=row("g:two");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,to.y+15);submit();
  context.animations.advance(0.65);submit();
  require(tree.isExpanded("g:two"),"hover did not expand destination");
  context.pointerCancel(0,100,to.y+15);submit();
  for (i in 0...40) catalog.terminals.push({id:"extra-"+i,name:"Extra",group:"one",cwd:"/original",instance:"owner",
   state:"running",exitCode:0,available:true,revision:Int64.ofInt(1)});
  model.update(catalog,agents);submit();from=row("t:term");
  context.pointerDown(100,from.y+15,0);context.pointerMove(100,295);submit();
  context.animations.advance(0.25);submit();
  require(tree.controller.targetY>0,"edge drag did not scroll tree");
  context.pointerCancel(0,100,295);submit();
  context.dispose();fonts.dispose();
  trace("PASS: workbench drop rules, durable agent grouping, real tree pointer gestures, click preservation, cancellation, release validation, hover expansion and edge scrolling");
 }
}
