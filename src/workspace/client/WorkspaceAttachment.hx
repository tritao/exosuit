package workspace.client;

/** Host composition boundary: UI observes an attachment, not transport or process details. */
interface WorkspaceAttachment {
  public function select(root:Null<String>):Void;
  public function poll():Void;
  public function statusLabel():String;
  public function failure():Null<String>;
  /** Stable per-connection API wrapper for root-scoped reads, or null without the negotiated grant. */
  public function fileClient():Null<WorkspaceFileClient>;
  public function fileWorkspace():String;
  public function fileScope():Null<String>;
  /** True when fileScope is on this machine and can use the regular editable file documents. */
  public function hasLocalFileAccess():Bool;
  public function dispose():Void;
}
