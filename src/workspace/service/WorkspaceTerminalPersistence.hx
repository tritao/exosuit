package workspace.service;
import workspace.service.WorkspaceTerminalProtocol;
/** Durable metadata and bounded rendered history. Runtime availability is recomputed. */
interface WorkspaceTerminalPersistence {
  public function loadTerminals():Array<TerminalRecord>;
  public function saveTerminal(record:TerminalRecord):Void;
  public function removeTerminal(id:String):Void;
  public function hasTerminalHistory(id:String):Bool;
  public function loadTerminalHistory(id:String):Null<TerminalHistory>;
  public function saveTerminalHistory(id:String, history:TerminalHistory):Void;
}
