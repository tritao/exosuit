package app;

import haxeon.platform.Runtime;
import nativekit.ffi.NativeKit;
import sys.FileSystem;
import workspace.client.WorkspaceLink;
import workspace.client.WorkspaceServiceTarget;

/**
	Which terminal roots a client's service owns: the folder it started in, and any of its workspace's folders or its
	scratch folder. A client with no root owns none.
**/
@:access(workspace.client.WorkspaceLink)
class ServesRootTests {
  static function require(ok:Bool, message:String):Void {
    if (!ok) throw message;
  }

  /** `base` is a scratch directory the test may create folders in. */
  public static function run(base:String, runtime:Runtime):Void {
    var clock = function() return NativeKit.nk_time_seconds() * 1000;
    var client = new WorkspaceLink(runtime.events, clock, function(_, done) done(null, "no service in this test"), null);
    require(!client.servesRoot("/anything"), "a client with no root served a root");

    var first = base + "/serves-first", second = base + "/serves-second", scratch = base + "/serves-scratch";
    for (folder in [first, second, scratch]) if (!FileSystem.exists(folder)) FileSystem.createDirectory(folder);
    var firstFull = FileSystem.fullPath(first), secondFull = FileSystem.fullPath(second), scratchFull = FileSystem.fullPath(scratch);

    // A workspace's service, started in its first folder, owns every folder and the scratch folder.
    client.root = firstFull;
    client.serviceTarget = WorkspaceServiceTarget.forWorkspace("workspace-1", [firstFull, secondFull], scratchFull);
    require(client.servesRoot(firstFull) && client.servesRoot(secondFull), "a workspace service did not serve its folders");
    require(client.servesRoot(scratchFull), "a workspace service did not serve its scratch folder");
    require(!client.servesRoot(base + "/serves-elsewhere"), "a workspace service served a folder outside the workspace");

    // The service keeps the folder it started in even after that folder left the workspace.
    client.root = firstFull;
    client.serviceTarget = WorkspaceServiceTarget.forWorkspace("workspace-1", [secondFull], null);
    require(client.servesRoot(firstFull) && client.servesRoot(secondFull), "the folder the service started in stopped counting");
    require(!client.servesRoot(scratchFull), "a workspace without scratch served a scratch folder");

    client.root = null;
    require(!client.servesRoot(secondFull), "a client with no root served a workspace folder");
    for (folder in [first, second, scratch]) FileSystem.deleteDirectory(folder);
  }
}
