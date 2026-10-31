package app;

import haxe.Int64;
import ui.WorkbenchOrder;
import ui.WorkbenchTreeModel;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;

/**
	The re-ordering policy on its own: a move in a large group writes only the moved row, at the middle between its
	neighbours; siblings are renumbered with room only when no gap is left or a neighbour has no position; and only rows
	the client may write are ever planned, the placement being refused otherwise.
**/
private class Item implements View {
 final model:WorkbenchTreeModel;
 final key:String;
 public var duringBuild:Null<Void->Void>;
 public function new(model:WorkbenchTreeModel,key:String) {this.model=model;this.key=key;}
 public function build(context:BuildContext):RenderNode {
  var rows:Array<haxeon.ui.widgets.KeyedView>=[new haxeon.ui.widgets.KeyedView(key,model.buildItem(key))];
  var node=new haxeon.ui.widgets.layout.Column("wrap",rows,new haxeon.ui.LayoutStyle()).build(context);
  // A pointer event between the build and the first layout.
  if(duringBuild!=null) duringBuild();
  return node;
 }
}

class OrderPlanTest {
 /** The row index forgets rows whose nodes left the tree, and keeps rows that are built but not yet laid out. */
 static function rowIndex():Void {
  var catalog:TerminalCatalog={instance:"owner",workspaceRoot:"/workspace",next:null,groups:[],
   terminals:[{id:"a",name:"a",group:"",cwd:"/workspace",instance:"owner",state:"running",exitCode:0,available:true,revision:Int64.ofInt(1),workspaceRoot:"/workspace"}]};
  var model=new WorkbenchTreeModel();model.update(catalog,null);
  var fonts=haxeon.ui.FontCollection.create();fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var context=new UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(320,200);
  var item=new Item(model,"t:a");
  item.duringBuild=function() model.rowAt(0);
  var root:RenderNode=null;
  for(_ in 0...3) root=context.submit(item,frame);
  item.duringBuild=null;
  require(model.probeCount()==1,"a row looked up before its first layout was forgotten");
  model.layoutChanged(root);
  var measured=model.centreOf("t:a");
  require(measured!=null,"the laid out row has no centre");
  var centre:Float=measured==null ? 0.0 : measured;
  var found=model.rowAt(centre);
  require(found!=null && found.key=="t:a","the laid out row was not found");
  require(root.children.length>0,"no row node");
  root.children[0].detach();
  model.layoutChanged(root);
  require(model.rowAt(centre)==null && model.probeCount()==0,"a row whose node left the tree was kept");
  context.dispose();fonts.dispose();
 }
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var terminals:Array<TerminalRecord>=[];
  function add(id:String,group:String,order:Null<Int>):Void terminals.push({id:id,name:id,group:group,cwd:"/workspace",instance:"owner",state:"running",
   exitCode:0,available:true,revision:Int64.ofInt(1),workspaceRoot:"/workspace",order:order});
  function catalog():TerminalCatalog return {instance:"owner",workspaceRoot:"/workspace",next:null,terminals:terminals,
   groups:[{id:"big",name:"Big",parent:null,cwd:null,revision:1,order:0}]};
  function model():WorkbenchTreeModel {var result=new WorkbenchTreeModel();result.update(catalog(),null);return result;}
  function plan(m:WorkbenchTreeModel,keys:Array<String>,anchor:String,after:Bool,writable:String->Bool):Null<Placement>
   return WorkbenchOrder.plan(m,catalog(),null,keys,anchor,after,writable);
  function all(_:String):Bool return true;
  function written(placement:Null<Placement>):String {
   if(placement==null) return "none";
   return [for(step in placement.steps) step.key+"@"+step.group+"#"+step.order].join(" ");
  }

  // A large group, spaced out: a move writes one row, at the middle between its neighbours.
  for (index in 0...200) add("t"+index,"big",index*WorkbenchOrder.STEP);
  var big=model();
  var moved=plan(big,["t:t150"],"t:t10",false,all);
  require(moved!=null && moved.refusal==null && moved.steps.length==1,"a move in a large group wrote "+written(moved));
  require(written(moved)=="t:t150@big#"+(9*WorkbenchOrder.STEP+WorkbenchOrder.STEP/2),"the moved row was not put midway: "+written(moved));
  var last=plan(big,["t:t5"],"t:t199",true,all);
  require(written(last)=="t:t5@big#"+(200*WorkbenchOrder.STEP),"a move to the end did not take the next step: "+written(last));
  var first=plan(big,["t:t5"],"t:t0",false,all);
  require(first!=null && first.steps.length>0 && written(first).indexOf("t:t5@big#")==0,"a move to the front was not planned");
  // Two rows go into one gap, spread within it.
  var pair=plan(big,["t:t150","t:t151"],"t:t10",false,all);
  require(pair!=null && pair.steps.length==2 && pair.steps[0].order>9*WorkbenchOrder.STEP && pair.steps[1].order<10*WorkbenchOrder.STEP
   && pair.steps[0].order<pair.steps[1].order,"two rows did not share the gap: "+written(pair));
  // A drop that leaves the order alone writes nothing.
  require(plan(big,["t:t5"],"t:t6",false,all)==null && plan(big,["t:t5"],"t:t4",true,all)==null,"a drop in place planned writes");

  // No gap left: the siblings are numbered again with room, and only the rows that change are written.
  terminals=[];
  add("a","big",0);add("b","big",1);add("c","big",2);add("d","big",3);
  var tight=model();
  var squeezed=plan(tight,["t:d"],"t:b",false,all);
  require(squeezed!=null && written(squeezed)=="t:d@big#1024 t:b@big#2048 t:c@big#3072","no-gap renumbering wrote "+written(squeezed));
  // Neighbours without a position: the moved row cannot sort after them, so everything gets one.
  terminals=[];
  add("a","big",null);add("b","big",null);add("c","big",null);
  var unplaced=plan(model(),["t:a"],"t:c",true,all);
  require(written(unplaced)=="t:b@big#0 t:c@big#1024 t:a@big#2048","unplaced neighbours: "+written(unplaced));
  // Placed rows before unplaced ones leave the unplaced alone: only the moved row is written.
  terminals=[];
  add("a","big",0);add("b","big",null);add("c","big",null);
  var tail=plan(model(),["t:c"],"t:b",false,all);
  require(written(tail)=="t:c@big#1024","a row put before unplaced rows needed more than itself: "+written(tail));

  // Permissions: a placement whose writes include a row the client may not change is refused, with the reason.
  terminals=[];
  add("a","big",0);add("b","big",1);add("c","big",2);add("foreign","big",3);
  var partly=function(key:String) return key!="t:foreign";
  var refused=plan(model(),["t:c"],"t:a",false,partly);
  require(refused!=null && refused.steps.length==0 && refused.refusal!=null,"a placement renumbering a foreign row was not refused");
  // The same move, needing no other row, still goes through.
  terminals=[];
  add("a","big",0);add("b","big",4096);add("foreign","big",8192);
  var fine=plan(model(),["t:foreign"],"t:b",false,function(key) return key=="t:foreign");
  require(fine!=null && fine.refusal==null && written(fine)=="t:foreign@big#2048","a single permitted write was not planned: "+written(fine));
  // A row the client cannot write is never the one that moves.
  require(plan(model(),["t:foreign"],"t:a",false,function(key) return key!="t:foreign")==null,"an unwritable row was planned to move");
  // A reader-only client plans nothing.
  require(plan(model(),["t:b"],"t:a",false,function(_) return false)==null,"a reader-only client planned writes");

  // The next position is one step past the last placed row, and 0 in a group with none.
  terminals=[];
  add("a","big",0);add("b","big",2048);add("c","big",null);
  var next=model();
  require(next.nextOrder("big")==2048+WorkbenchOrder.STEP && next.nextOrder("none")==0,"next position: "+next.nextOrder("big")+" "+next.nextOrder("none"));
  // Near the limit: rows share a gap of hundreds of millions without the arithmetic wrapping.
  terminals=[];
  add("a","big",0);add("z","big",900000000);add("m1","big",null);add("m2","big",null);add("m3","big",null);
  var wide=plan(model(),["t:m1","t:m2","t:m3"],"t:z",false,all);
  require(wide!=null && wide.steps.length==3 && wide.steps[0].order>0 && wide.steps[0].order<wide.steps[1].order
   && wide.steps[1].order<wide.steps[2].order && wide.steps[2].order<900000000,"a wide gap was not shared in order: "+written(wide));
  // Past the limit: an append that would exceed it renumbers instead, within what the services accept.
  terminals=[];
  add("a","big",WorkspaceProtocol.MAX_ORDER-10);add("b","big",null);
  var capped=plan(model(),["t:b"],"t:a",true,all);
  require(capped!=null && capped.steps.length>0 && capped.steps.filter(function(step) return !WorkspaceProtocol.validOrder(step.order)).length==0,
   "a move past the limit planned an order the services refuse: "+written(capped));
  rowIndex();
  trace("PASS: re-order plan: one write for a move in a large group, spaced renumbering only when no gap is left or a neighbour is unplaced, refusal of unwritable rows");
 }
}
