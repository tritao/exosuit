package ui;

/** Read-only navigation from a conversation into the owning IDE workspace. */
typedef SessionWorkspaceActions = {
  var explore:Void->Void;
  var reviewChanges:Void->Void;
  var context:Void->String;
  @:optional var resolveImage:Null<String->Null<String>>;
  /** On-demand bytes from the owning workspace, never an implicit HTTP fetch. */
  @:optional var loadImage:Null<(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void>;
  /** Open already-authorized sent-image bytes in a bounded in-memory editor tab. */
  @:optional var openMessageImage:Null<(String,String,String,haxe.io.Bytes)->Void>;
  /** Read a bounded UTF-8 snapshot from the owning workspace, not the client machine. */
  @:optional var readContext:Null<(String, (Null<String>, Null<String>)->Void)->Void>;
  @:optional var newWorktree:Null<Void->Void>;
  @:optional var canCreateWorktree:Null<Void->Bool>;
  /** Clipboard image bytes are read locally and uploaded through the session. */
  @:optional var pasteImage:Null<Void->{bytes:Null<haxe.io.Bytes>, error:Null<String>}>;
  /** Local chooser returns a display name and bytes; the host path is never sent. */
  @:optional var chooseImage:Null<((Null<String>, Null<haxe.io.Bytes>, Null<String>)->Void)->Void>;
  @:optional var githubRepository:Null<Void->Void>;
  @:optional var githubPullRequest:Null<Void->Void>;
  @:optional var canOpenGithub:Null<Void->Bool>;
  @:optional var canOpenPullRequest:Null<Void->Bool>;
  @:optional var canCommitChanges:Null<Void->Bool>;
  @:optional var commitChanges:Null<Void->Void>;
  @:optional var previewArtifact:Null<(String, String)->Void>;
}
