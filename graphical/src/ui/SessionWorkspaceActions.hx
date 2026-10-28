package ui;

/** Read-only navigation from a conversation into the owning IDE workspace. */
typedef SessionWorkspaceActions = {
  var explore:Void->Void;
  var reviewChanges:Void->Void;
  var context:Void->String;
  @:optional var resolveImage:Null<String->Null<String>>;
  /** Read a bounded UTF-8 snapshot from the owning workspace, not the client machine. */
  @:optional var readContext:Null<(String, (Null<String>, Null<String>)->Void)->Void>;
  @:optional var newWorktree:Null<Void->Void>;
  @:optional var canCreateWorktree:Null<Void->Bool>;
  /** Local chooser returns a display name and bytes; the host path is never sent. */
  @:optional var chooseImage:Null<((Null<String>, Null<haxe.io.Bytes>, Null<String>)->Void)->Void>;
  @:optional var githubRepository:Null<Void->Void>;
  @:optional var githubPullRequest:Null<Void->Void>;
  @:optional var canOpenGithub:Null<Void->Bool>;
  @:optional var canOpenPullRequest:Null<Void->Bool>;
}
