package workspace.service;
import workspace.service.WorkspaceTerminalProtocol;
/** Durable metadata only. Runtime availability is always recomputed by the owner. */
interface WorkspaceTerminalPersistence {
  public function loadTerminals():Array<TerminalRecord>;
  public function saveTerminal(record:TerminalRecord):Void;
  public function removeTerminal(id:String):Void;
}
