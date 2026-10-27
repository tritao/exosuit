package ui;

/** Process loss ends a shell; its retained record can still open for recovery. */
class TerminalStateLabels {
  public static function display(state:String):String return state == "lost" ? "session ended" : state;
}
