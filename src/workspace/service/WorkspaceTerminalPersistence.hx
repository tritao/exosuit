package workspace.service;
import workspace.service.WorkspaceTerminalProtocol;
/** Durable terminal records. A terminal's screen is its host's (TerminalHosts); runtime availability is recomputed. */
interface WorkspaceTerminalPersistence {
  public function loadTerminals():Array<TerminalRecord>;
  public function saveTerminal(record:TerminalRecord):Void;
  public function removeTerminal(id:String):Void;
}
