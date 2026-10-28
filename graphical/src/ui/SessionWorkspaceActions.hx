package ui;

/** Read-only navigation from a conversation into the owning IDE workspace. */
typedef SessionWorkspaceActions = {
  var explore:Void->Void;
  var reviewChanges:Void->Void;
  var context:Void->String;
  @:optional var resolveImage:Null<String->Null<String>>;
}
