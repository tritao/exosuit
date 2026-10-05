package workspace.client;
import workspace.service.WorkspaceTerminalProtocol;
/** UI-facing catalog operations, independent of native transports. */
interface WorkspaceTerminalCatalogClient {
  public function canEditGroups():Bool;
  public function terminalCatalog():Null<TerminalCatalog>;
  public function terminalCatalogError():Null<String>;
  public function terminalCatalogRevision():Int;
  public function terminalCatalogBusy():Bool;
  public function refreshTerminals(force:Bool):Void;
  public function renameTerminal(record:TerminalRecord, name:String, group:String):Void;
  public function changeGroup(owner:String, group:workspace.service.WorkspaceProtocol.WorkspaceGroup, name:String, parent:Null<String>, cwd:Null<String>, order:Int, create:Bool):Void;
  public function stopTerminal(record:TerminalRecord):Void;
  public function forgetTerminal(record:TerminalRecord):Void;
}
