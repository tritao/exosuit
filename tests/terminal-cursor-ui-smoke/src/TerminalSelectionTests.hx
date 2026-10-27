import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiModifier;
import TerminalCursorSmoke.QuietBackend;

/** Real terminal pointer gestures, native copy and shared edge scrolling. */
@:access(ui.TerminalPane)
class TerminalSelectionTests {
 static function require(ok:Bool,message:String):Void { if(!ok) throw message; }
 public static function run(fonts:haxeon.ui.FontCollection):Void {
  var context=new UiContext(null,fonts), backend=new QuietBackend();
  var emulator=terminalkit.Emulator.open(80,24);
  var pane=new ui.TerminalPane(new terminalsession.TerminalSession(backend,emulator),function() {},new ui.TerminalPalette(true),fonts);
  var frame=new LayoutFrame(420,160);
  function submit():Void { for(_ in 0...2) context.submit(pane,frame); }
  submit();
  emulator.feedString("\x1b[?25lalpha beta_gamma!\r\nsecond line\r\n日本語 test");pane.poll();submit();
  function x(column:Int):Float return 8+(column+0.5)*pane.cellWidth;
  function y(row:Int):Float return 4+(row+0.5)*pane.rowHeight;
  function click(column:Int,row:Int,modifiers:Int=0):Void {
   context.pointerDown(x(column),y(row),0,modifiers);context.pointerUp(x(column),y(row),0,modifiers);
  }
  function selected(expected:String):Void require(emulator.selectionText()==expected,"Terminal selection differs: expected "+expected+", got "+emulator.selectionText());
  click(2,0);require(!pane.hasSelection,"Single click retained an unwanted cell selection");
  click(2,0);selected("alpha");
  click(2,0);selected("alpha beta_gamma!");
  click(2,0);require(!pane.hasSelection,"Fourth click did not start a new sequence");
  pane.selectionGesture.cancel();
  var edge=8+3*pane.cellWidth;
  context.pointerDown(edge-0.5,y(0),0);context.pointerUp(edge-0.5,y(0),0);
  context.pointerDown(edge+0.5,y(0),0);context.pointerUp(edge+0.5,y(0),0);selected("alpha");
  pane.selectionGesture.cancel();click(10,0);context.pointerDown(x(10),y(0),0);
  context.pointerMove(x(2),y(0));selected("alpha beta_gamma");context.pointerUp(x(2),y(0),0);
  pane.selectionGesture.cancel();click(2,0);click(2,0);click(8,0,UiModifier.Shift);selected("alpha bet");
  pane.selectionGesture.cancel();click(2,0);click(2,0);context.pointerDown(x(2),y(0),0);
  context.pointerMove(x(4),y(1));context.pointerUp(x(4),y(1),0);selected("alpha beta_gamma!\nsecond line");
  pane.selectionGesture.cancel();click(5,2);click(5,2);selected("日本語");
  pane.clearSelection();pane.selectionGesture.cancel();emulator.feedString("\x1b[?1003h\x1b[?1006h");backend.replies="";
  click(2,0);require(backend.replies.length>0 && !pane.hasSelection,"TUI mouse reporting was intercepted");
  pane.selectionGesture.cancel();click(2,0,UiModifier.Shift);click(2,0,UiModifier.Shift);selected("alpha");
  backend.replies="";click(20,4);
  require(!pane.hasSelection && emulator.selectionText()==null,"TUI click on empty space retained local selection");
  require(backend.replies.length>0,"Clearing local selection swallowed the TUI click");
  pane.clearSelection();emulator.feedString("\x1b[?1003l");
  for(i in 0...40) emulator.feedString("\r\nHISTORY_"+i);
  pane.poll();submit();pane.selectionGesture.cancel();
  context.pointerDown(x(2),y(2),0);context.pointerMove(x(2),-30);
  for(_ in 0...8) { context.animations.advance(0.1);submit(); }
  require(emulator.scrollback(-1).current>0,"Stationary captured pointer did not scroll terminal history");
  context.pointerUp(x(2),-30,0);
  var historySelection=emulator.selectionText();
  require(historySelection!=null && historySelection.length>0,"History autoscroll lost its anchored selection");
  pane.close();context.dispose();
  Sys.println("PASS: terminal word/line clicks, reverse semantic drag, Shift extension, Unicode, TUI override and stationary history autoscroll");
 }
}
