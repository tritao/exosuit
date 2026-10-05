package workspace.client;

/** Host composition boundary: UI observes an attachment, not transport or process details. */
interface WorkspaceAttachment {
  public function select(root:Null<String>):Void;
  public function poll():Void;
  public function statusLabel():String;
  public function failure():Null<String>;
  public function dispose():Void;
}
