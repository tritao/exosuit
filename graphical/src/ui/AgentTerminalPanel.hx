package ui;

/** A terminal factory can opt into typed, service-owned agent CLI launches. */
interface AgentTerminalPanel extends TerminalPanel {
  public function configureAgent(provider:String):Void;
}
