package ui;

/** Process loss ends a shell; its retained record can still open for recovery. */
class TerminalStateLabels {
  /** A Claude Code, Codex or Pi terminal whose program ended continues the same conversation when opened or restarted. */
  public static function display(state:String, ?agentProvider:String):String
    return (state == "lost" || state == "exited") && resumes(agentProvider) ? "resumable" : state == "lost" ? "session ended" : state;
  public static function resumes(agentProvider:Null<String>):Bool return agentProvider == "claude" || agentProvider == "codex" || agentProvider == "pi";
}
