import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import terminalsession.TerminalSession;
import TerminalCursorSmoke.QuietBackend;

/** A TUI consuming mouse motion must not swallow the next workbench click. */
class TerminalPointerTests {
 static function require(value:Bool,message:String):Void { if (!value) throw message; }
 public static function run(fonts:haxeon.ui.FontCollection):Void {
  var context=new UiContext(null,fonts), backend=new QuietBackend();
  var emulator=terminalkit.Emulator.open(80,24);
  var pane=new ui.TerminalPane(new TerminalSession(backend,emulator),function() {},new ui.TerminalPalette(true),fonts);
  var clicks=0;
  var style=new LayoutStyle();style.width=LayoutAxis.stretch();style.height=LayoutAxis.stretch();
  var view=new Stack("terminal-pointer-test",[
   new StackChild("layout",new Button("Layout",null,function() clicks++),0,0,1,LayoutAxis.fixed(100),LayoutAxis.fixed(40)),
   new StackChild("sidebar",new Button("Files",null,function() clicks++),0,50,1,LayoutAxis.fixed(100),LayoutAxis.fixed(40)),
   new StackChild("terminal",pane,110,50,1,LayoutAxis.fixed(500),LayoutAxis.fixed(300))
  ],style);
  var root=context.submit(view,new LayoutFrame(640,400));
  var terminal:RenderNode=null, button:RenderNode=null;
  root.walk(function(node) {
   if (node.styleKey=="terminal-pane") terminal=node;
   if (node.semantics!=null && node.semantics.label=="Layout") button=node;
  });
  require(terminal!=null,"Missing terminal in pointer fixture");
  for (mode in [0,1002,1003]) {
   emulator.feedString("\x1b[?1002l\x1b[?1003l\x1b[?1006h"+(mode==0 ? "" : "\x1b[?"+mode+"h"));
   for (y in [20,70]) {
    context.pointerDown(200,120,0);context.pointerUp(200,120,0);
    require(context.focus.focusedId==terminal.id,"Terminal did not receive pointer focus");
    var before=clicks;
    // An unpressed movement inside an all-motion TUI calls preventDefault.
    context.pointerMove(210,125);
    context.pointerMove(50,y);
    context.pointerDown(50,y,0);context.pointerUp(50,y,0);
    require(clicks==before+1,"First workbench click was swallowed after terminal hover, mouse mode "+mode);
   }
  }
  require(button!=null,"Missing toolbar button in pointer fixture");
  button.on(UiEventKind.PointerMove,function(event) event.preventDefault());
  var before=clicks;
  context.pointerMove(50,20);
  context.pointerDown(50,20,0);context.pointerUp(50,20,0);
  require(clicks==before+1,"Consumed hover suppressed its own button's next click");
  before=clicks;
  context.pointerDown(50,20,0);context.pointerMove(55,20);context.pointerUp(55,20,0);
  require(clicks==before,"Consumed drag activated the button");
  context.pointerDown(50,20,0);context.pointerUp(50,20,0);
  require(clicks==before+1,"Suppression escaped the completed drag gesture");
  context.pointerDown(50,20,0);context.pointerMove(55,20);context.pointerCancel(0,55,20);
  context.pointerDown(50,20,0);context.pointerUp(50,20,0);
  require(clicks==before+2,"Cancelled drag suppressed the following click");
  pane.close();
  Sys.println("PASS: first toolbar/sidebar click after focused terminal mouse tracking");
 }
}
