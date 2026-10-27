import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiContext;
import terminalsession.TerminalSession;
import TerminalPollTests.DelayedEchoBackend;

/** A resize redraw can arrive in separate PTY/RPC reads across real UI submissions. */
@:access(ui.TerminalPane)
class TerminalSyncOutputTests {
 static function require(ok:Bool,message:String):Void { if(!ok) throw message; }
 public static function run(fonts:haxeon.ui.FontCollection):Void {
  var context=new UiContext(null,fonts),backend=new DelayedEchoBackend();
  var pane=new ui.TerminalPane(new TerminalSession(backend,terminalkit.Emulator.open(80,24)),function(){},new ui.TerminalPalette(true),fonts);
  function submit(width:Float):Void { for(_ in 0...2) context.submit(pane,new LayoutFrame(width,160)); }
  backend.output("\x1b[?25lCOMPLETE BEFORE RESIZE\r\nretained content");pane.poll();submit(500);
  var before=pane.renderedRows[0].text;
  backend.output("\x1b[?2026h\x1b[2J\x1b[HPARTIAL");pane.poll();submit(380);
  require(pane.renderedRows[0].text==before,"Synchronized resize exposed a partial redraw");
  backend.output("\x1b[HCOMPLETE AFTER RESIZE\r\nupdated content\x1b[?2026l");pane.poll();submit(380);
  require(StringTools.startsWith(pane.renderedRows[0].text,"COMPLETE AFTER RESIZE"),"Completed resize redraw did not appear");
  // Unsynchronized shell output must remain immediate during dragging.
  backend.output("\x1b[HNORMAL OUTPUT");pane.poll();submit(420);
  require(StringTools.startsWith(pane.renderedRows[0].text,"NORMAL OUTPUT"),"Resize froze ordinary shell output");
  backend.output("\x1b[?2026h\x1b[HUNFINISHED UPDATE");pane.poll();
  pane.synchronizedOutputSince=Sys.time()-2;
  pane.poll();submit(420);
  require(StringTools.startsWith(pane.renderedRows[0].text,"UNFINISHED UPDATE"),"Unterminated synchronization froze the terminal indefinitely");
  backend.output("\x1b[?2026l\x1b[?2026h\x1b[HSECOND PARTIAL");pane.poll();submit(420);
  // A new redraw in the same read must receive its own timeout budget.
  require(!StringTools.startsWith(pane.renderedRows[0].text,"SECOND PARTIAL"),"A new redraw inherited an expired synchronization timeout");
  backend.output("\x1b[?2026l");pane.poll();
  backend.output("\x1b[?2026h\x1b[HNEW PARTIAL");pane.poll();submit(420);
  require(!StringTools.startsWith(pane.renderedRows[0].text,"NEW PARTIAL"),"A later synchronized redraw reused the expired timeout");
  pane.close();context.dispose();
  Sys.println("PASS: synchronized resize retains complete content, presents on release and leaves ordinary output live");
 }
}
