package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/**
	Re-ordering in the real Workbench panel against a service that keeps positions: a row dropped on the upper or lower
	part of another places itself there with an insertion line shown, the middle of a group still moves it in, and the
	order is the service's, so it holds after the catalogs reload.
**/
class ReorderTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var now=1000.0;
  var clock=function() { return now; };
  var pair=MemoryTransport.pair();
  var connection=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
  var groups:Array<WorkspaceGroup>=[{id:"work",name:"Work",parent:null,cwd:null,revision:1,order:0},
   {id:"other",name:"Other",parent:null,cwd:null,revision:1,order:1},{id:"sub",name:"Sub",parent:"work",cwd:null,revision:1,order:0}];
  function terminal(id:String,group:String):TerminalRecord return {id:id,name:id,group:group,cwd:"/workspace",instance:"owner",state:"running",
   exitCode:0,available:true,revision:Int64.ofInt(1),workspaceRoot:"/workspace"};
  function agent(id:String,group:String):AgentRecord return {id:id,name:id,group:group,cwd:"/workspace",thread:"thread-"+id,state:"disconnected",
   turn:null,workspaceRoot:"/workspace",provider:"codex"};
  var terminals=[terminal("r1",WorkspaceProtocol.ROOT_GROUP),terminal("t1","work"),terminal("t2","work")];
  var agents=[agent("a1","work"),agent("a2","work")];
  var writes:Array<String>=[];
  server.register(WorkspaceAgentProtocol.LIST,function(q,ctx) {
   ctx.respond({instance:"owner",root:"/workspace",records:agents,status:"",canMove:true,canRename:true});
  });
  server.register(WorkspaceTerminalProtocol.LIST,function(q,ctx) {
   ctx.respond({instance:"owner",workspaceRoot:"/workspace",next:null,terminals:terminals,groups:groups});
  });
  server.register(WorkspaceTerminalProtocol.RENAME,function(q,ctx) {
   for (record in terminals) if (record.id==q.id) {
    require(q.expectedRevision==record.revision,"terminal write lost the revision");
    record.group=q.group;if(q.order!=null) record.order=q.order;record.revision=Int64.add(record.revision,Int64.ofInt(1));
    writes.push("t:"+q.id+"@"+q.group+"#"+q.order);ctx.respond(record);return;
   }
   ctx.fail({code:"unknown_terminal",message:"unknown",ambiguous:false});
  });
  server.register(WorkspaceAgentProtocol.ACTION,function(q,ctx) {
   for (record in agents) if (record.id==q.id && q.action=="move") {
    require(q.request==record.group,"session write sent the wrong source group");
    record.group=q.text;if(q.order!=null) record.order=q.order;
    writes.push("a:"+q.id+"@"+q.text+"#"+q.order);ctx.respond({record:record,activity:"",requests:[],error:null});return;
   }
   ctx.respond({record:agents[0],activity:"",requests:[],error:null});
  });
  server.register(WorkspaceProtocol.GROUP,function(q,ctx) {
   for (group in groups) if (group.id==q.group) {
    require(q.action=="update" && q.expectedRevision==group.revision,"group write lost the revision");
    group.parent=q.parent;group.order=q.order;group.revision++;
    writes.push("g:"+q.group+"@"+q.parent+"#"+q.order);
    ctx.respond({epoch:"epoch",operation:q.operation,sequence:group.revision,group:group});return;
   }
   ctx.fail({code:"unknown_group",message:"unknown",ambiguous:false});
  });
  var endpoint=new ReorderEndpoint(connection);
  var client=new RpcWorkspaceWorkbenchClient(endpoint,clock);
  function pump():Void {for(_ in 0...2) {client.poll();server.poll();connection.poll();}}
  pump();client.refreshTerminals(true);client.refreshAgents();pump();
  var errors:Array<String>=[];
  var panel=new ui.WorkbenchPanel(client,function(_) { return true; },function(_) {},function(_,_) {},function(_) {},
   function(_) { return []; },function() {},function(_) {},function(_,_,_) {},function(_) {},function(_,_) {},
   function(_,_) {},function() { return true; });
  panel.onError=function(message) errors.push(message);
  var view:ui.WorkbenchMachineView={machine:{id:"m",name:"cube",workspaces:[{id:"resume",name:"resume-2026",folders:["/workspace"],scratch:null,revision:1}]},
   error:null,openWorkspace:"resume",openRoots:["/workspace"],revision:1};
  panel.machine={view:function() { return view; },busy:function() { return false; },open:function(_) {},start:function(_) {},create:function() {},
   rename:function(_) {},attachFolder:function(_) {},detachFolder:function(_) {},remove:function(_) {}};
  var fonts=haxeon.ui.FontCollection.create();fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
  var context=new UiContext(null,fonts),frame=new haxeon.ui.LayoutFrame(320,600);
  var root:RenderNode=null;
  function submit():Void {for(_ in 0...3) root=context.submit(panel,frame);}
  function row(key:String):haxeon.ui.Rect {
   var result:RenderNode=null;
   root.walk(function(node) {if(node.semantics!=null && node.semantics.label==key) result=node;});
   require(result!=null,"missing workbench row "+key);return result.globalBounds();
  }
  /** Reloads both catalogs and lets any queued writes run to the end. */
  function settle():Void {
   pump();
   for(_ in 0...16) {now+=2000;client.refreshTerminals(true);client.refreshAgents();pump();submit();pump();}
  }
  /** Presses `from`'s row and moves to `part` (0 top … 1 bottom) of `to`'s row; the button stays down. */
  function hold(from:String,to:String,part:Float):Float {
   var source=row(from),target=row(to),y=target.y+target.height*part;
   context.pointerDown(120,source.y+source.height/2,0);context.pointerMove(120,y);submit();return y;
  }
  function drop(y:Float):Void {context.pointerUp(120,y,0);submit();settle();}
  function dragTo(from:String,to:String,part:Float):Void drop(hold(from,to,part));
  function lines():Int {
   var count=0;
   root.walk(function(node) {if(node.styleKey=="workbench-insertion-line") count++;});
   return count;
  }
  function order(group:String):String return panel.model.siblings(group).join(",");
  submit();settle();
  panel.tree.setExpanded("g:work",true);submit();
  require(panel.model.groupParent=="w:resume","groups did not sit under the open workspace");
  // Rows nobody ordered keep the order they always had: groups, terminals, then sessions.
  require(order("work")=="g:sub,t:t1,t:t2,a:a1,a:a2","unordered rows changed their order: "+order("work"));
  require(order(WorkspaceProtocol.ROOT_GROUP)=="g:work,g:other,t:r1","root rows are not groups then items: "+order(WorkspaceProtocol.ROOT_GROUP));
  // The row probe finds each row where the tree lays it out.
  for (key in ["g:work","g:sub","t:t1","a:a1"]) {
   var bounds=row(key),centre=panel.model.centreOf(key);
   require(centre!=null && Math.abs(centre-(bounds.y+bounds.height/2))<=2,"the probed centre of "+key+" is not its row's: "+centre+" vs "+(bounds.y+bounds.height/2));
  }

  // The insertion line follows the pointer and goes with it; nothing is written until release.
  var y=hold("a:a2","t:t1",0.15);
  require(panel.model.insertion=="t:t1" && !panel.model.insertionAfter && lines()==1,"no insertion line above the row");
  var target=row("t:t2");context.pointerMove(120,target.y+target.height*0.85);submit();
  require(panel.model.insertion=="t:t2" && panel.model.insertionAfter && lines()==1,"the insertion line did not follow to the lower edge");
  context.pointerMove(120,row("g:other").y+row("g:other").height*0.5);submit();
  require(panel.model.insertion==null && lines()==0,"a drop into a group still shows an insertion line");
  context.key(UiEventKind.KeyDown,UiKey.Escape);context.pointerUp(120,target.y,0);submit();settle();
  require(writes.length==0 && panel.model.insertion==null && lines()==0,"cancelling a drag wrote or left a line");
  // Escape also ends the tree's own drag: a release over the middle of a group afterwards moves nothing.
  var into=hold("a:a2","g:other",0.5);
  context.key(UiEventKind.KeyDown,UiKey.Escape);context.pointerUp(120,into,0);submit();settle();
  require(writes.length==0 && panel.model.insertion==null && terminals.length==3 && agents[1].group=="work","a release after Escape still moved the row into the group: "+writes.join(" "));
  // A release outside the panel leaves no insertion line behind.
  hold("a:a2","t:t1",0.15);
  require(panel.model.insertion=="t:t1","no insertion line before leaving the panel");
  context.pointerMove(5000,row("t:t1").y);submit();context.pointerUp(5000,row("t:t1").y,0);submit();settle();
  require(panel.model.insertion==null && lines()==0 && writes.length==0,"a release outside the panel left the insertion line or wrote: "+writes.join(" "));
  // Asking whether a row can be dragged, as every hover does, starts nothing.
  var canDrag:String->Bool=cast panel.tree.canDragItem;
  require(canDrag("a:a2"),"a session cannot be dragged");
  context.pointerMove(120,row("t:t1").y+row("t:t1").height*0.15);context.pointerMove(120,row("t:t1").y+row("t:t1").height*0.15+9);submit();
  require(panel.model.insertion==null && lines()==0,"a hover query made the next pointer move a drag");

  // A client that may not write groups cannot renumber them: the drop above the first row is refused with the reason and nothing is written,
  // while a drop that needs only the moved row goes through.
  endpoint.denied=WorkspaceProtocol.WRITE;submit();
  errors=[];
  var refusedAt=hold("a:a2","g:sub",0.1);
  require(panel.model.insertion==null && lines()==0,"an insertion line was offered where the client cannot write the renumbered groups");
  drop(refusedAt);
  require(writes.length==0 && errors.length==1,"a placement needing unwritable rows was not refused: "+writes.join(" ")+" / "+errors.join("|"));
  errors=[];

  // Dropping on the upper half of a terminal puts a session there; the rows after it renumber, and the service holds the order.
  dragTo("a:a2","t:t1",0.15);
  endpoint.denied=null;
  require(order("work")=="g:sub,a:a2,t:t1,t:t2,a:a1","session did not land above the terminal: "+order("work"));
  require(writes.join(" ")=="a:a2@work#1024","only the moved row is written: "+writes.join(" "));
  require(panel.model.insertion==null && lines()==0 && errors.length==0,"the insertion line outlived the drop");
  // Placed rows stay where they were put after a fresh load of both catalogs.
  settle();require(order("work")=="g:sub,a:a2,t:t1,t:t2,a:a1" && writes.length==1,"the order did not hold after a reload");
  // A drop that changes nothing places nothing and shows no line.
  hold("a:a2","t:t1",0.15);
  require(panel.model.insertion==null && lines()==0,"a drop that changes nothing showed a line");
  drop(row("t:t1").y+3);require(writes.length==1,"a drop that changes nothing wrote");

  // The lower half of a row places after it; a terminal can go below a session.
  writes=[];
  dragTo("t:t1","a:a1",0.85);
  require(order("work")=="g:sub,a:a2,t:t2,a:a1,t:t1","terminal did not land below the session: "+order("work"));
  require(writes.join(" ")=="t:t2@work#2048 a:a1@work#3072 t:t1@work#4096","only the rows that moved were written: "+writes.join(" "));

  // Sub-groups re-order among their siblings, and a root terminal sits among the top-level groups.
  writes=[];
  dragTo("g:other","g:work",0.1);
  require(order(WorkspaceProtocol.ROOT_GROUP)=="g:other,g:work,t:r1","group did not land above its sibling: "+order(WorkspaceProtocol.ROOT_GROUP));
  require(writes.join(" ")=="g:other@null#0 g:work@null#1024 t:r1@#2048","group writes: "+writes.join(" "));
  writes=[];
  dragTo("t:r1","g:other",0.1);
  require(order(WorkspaceProtocol.ROOT_GROUP)=="t:r1,g:other,g:work","a root terminal did not go first: "+order(WorkspaceProtocol.ROOT_GROUP));

  // Between rows of another group moves a row there, at that place.
  writes=[];
  dragTo("t:r1","t:t2",0.1);
  require(order("work")=="g:sub,a:a2,t:r1,t:t2,a:a1,t:t1" && terminals[0].group=="work","row did not move into the other group at the drop: "+order("work"));
  require(order(WorkspaceProtocol.ROOT_GROUP)=="g:other,g:work","the root kept the moved row: "+order(WorkspaceProtocol.ROOT_GROUP));

  // The lower edge of an open group is the upper edge of its first row.
  writes=[];
  hold("t:t1","g:work",0.9);
  require(panel.model.insertion=="g:sub" && !panel.model.insertionAfter,"the lower edge of an open group is not above its first row");
  drop(row("g:work").y+row("g:work").height*0.9);
  require(order("work")=="t:t1,g:sub,a:a2,t:r1,t:t2,a:a1","row did not become the group's first: "+order("work"));

  // A group cannot go between rows of its own contents; a selection that includes one still places the rest.
  writes=[];errors=[];
  hold("g:work","t:t2",0.15);
  require(panel.model.insertion==null,"a group offered a place inside itself");
  context.key(UiEventKind.KeyDown,UiKey.Escape);context.pointerUp(120,row("t:t2").y,0);submit();settle();
  require(writes.length==0,"a group was written into itself");
  panel.tree.select("g:work");panel.tree.toggleSelection("g:other");submit();
  dragTo("g:other","g:sub",0.15);
  var other=panel.model.groups.get("other"),work=panel.model.groups.get("work");
  require(writes.length>0 && other!=null && other.parent=="work" && work!=null && work.parent==null,"the movable row of a selection was not placed");
  require(errors.length==1 && errors[0].indexOf("1 selected row could not be moved")==0,"a skipped row went unreported: "+errors.join("|"));

  // Alt+Up and Alt+Down move the selected row one place among its siblings.
  writes=[];
  var before=order("work");
  panel.tree.select("t:t2");submit();
  var siblings=panel.model.siblings("work"),at=siblings.indexOf("t:t2");
  context.key(UiEventKind.KeyDown,UiKey.Down,UiModifier.Alt);submit();settle();
  var expected=siblings.copy();expected[at]=siblings[at+1];expected[at+1]="t:t2";
  require(order("work")==expected.join(",") && writes.length>=1 && writes.length<=2,"Alt+Down did not move the row down: "+before+" -> "+order("work"));
  context.key(UiEventKind.KeyDown,UiKey.Up,UiModifier.Alt);submit();settle();
  require(order("work")==before,"Alt+Up did not move the row back: "+order("work"));
  panel.tree.select(panel.model.siblings("work")[0]);submit();writes=[];
  context.key(UiEventKind.KeyDown,UiKey.Up,UiModifier.Alt);submit();settle();
  require(writes.length==0,"Alt+Up moved the first row out of its group");

  // A row dropped into a group goes to the end of it, not at the position it had in the group it left.
  writes=[];
  dragTo("t:t2","g:other",0.5);
  require(writes.join(" ")=="t:t2@other#0","a terminal moved into a group kept its old position: "+writes.join(" "));
  writes=[];
  dragTo("a:a1","g:other",0.5);
  require(writes.join(" ")=="a:a1@other#"+ui.WorkbenchOrder.STEP,"a session moved into a group kept its old position: "+writes.join(" "));
  // With no button down, hovering after that drop shows no insertion line.
  var after=row("g:work");
  context.pointerMove(120,after.y+after.height*0.5);context.pointerMove(120,after.y+after.height*0.5+20);submit();
  require(panel.model.insertion==null && lines()==0,"hovering after a move-into drop drew an insertion line");

  // A service that does not advertise the position would ignore it and the order would revert: no line, no re-order, moves still work.
  endpoint.ordering=false;submit();
  writes=[];
  var refused=hold("t:t1","a:a2",0.15);
  require(panel.model.insertion==null && lines()==0,"an insertion line was offered by a service that cannot keep the order");
  drop(refused);
  require(writes.length==0,"a service that cannot keep the order was asked to re-order");
  panel.tree.select("t:t1");submit();
  context.key(UiEventKind.KeyDown,UiKey.Down,UiModifier.Alt);submit();settle();
  require(writes.length==0,"Alt+Down re-ordered against a service that cannot keep the order");
  dragTo("t:t1","g:other",0.5);
  require(writes.length==1,"moving into a group stopped working against a service that cannot keep the order: "+writes.join(" "));
  endpoint.ordering=true;

  // A multi-row drop into a group decides its target once at release: the rows that leave shift the layout under the held pointer, and
  // every one still goes in.
  writes=[];errors=[];
  var first="t:t1",second="a:a1";
  require(row(first).y<row("g:sub").y && row(second).y<row("g:sub").y,"the shifting-layout drop needs both rows above the target: "+order("other"));
  panel.tree.select(first);panel.tree.toggleSelection(second);submit();
  dragTo(first,"g:sub",0.5);
  var inSub=panel.model.siblings("sub");
  require(inSub.indexOf(first)>=0 && inSub.indexOf(second)>=0 && errors.length==0,"a multi-row drop lost a row when the layout shifted: "+order("sub")+" "+errors.join("|"));

  context.dispose();fonts.dispose();client.dispose();connection.close();server.close();
  trace("PASS: re-ordering in the Workbench: insertion line, upper and lower drop zones, sessions, terminals and groups, moves between groups, the open group's first row, skipped rows reported, Alt+Up/Down, and the service's order after a reload");
 }
}

private class ReorderEndpoint implements workspace.client.WorkspaceRpcEndpoint {
 final connection:RpcConnection;
 public function new(connection:RpcConnection) this.connection=connection;
 public function rootPath():Null<String> return "/workspace";
 public function serviceGeneration():String return "owner";
 public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return null;
 public function rpcConnection():Null<RpcConnection> return connection;
 public function failureReason():Null<String> return null;
 public function supportsWorkspaceGroups():Bool return true;
 public function workspaceEpoch():Null<String> return "epoch";
 public var ordering=true;
 public var denied:Null<String>=null;
 public function hasCapability(capability:String):Bool return (ordering || capability!=WorkspaceProtocol.ORDER) && capability!=denied;
}
