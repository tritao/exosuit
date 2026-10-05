package app;

import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import platform.Platform;
import process.ProcessManager;
import workspace.client.LocalWorkspaceClient;

class AttachmentTestMain {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }

  static function main():Void {
    var args = Sys.args(), mode = args[0], root = args[1], launcher = args[2];

    var runtime = NativeKitRuntime.start(), processes = new ProcessManager();
    var clock = function() return NativeKit.nk_time_seconds() * 1000;
    var a = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
    var b = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
    var step = function() {
      runtime.events.wait(0.005);
      for (_ in 0...128) if (!runtime.events.poll()) break;
      a.poll();
      b.poll();
    };
    a.select(root);
    b.select(root);
    var deadline = clock() + 115000;
    if (mode == "reject") {
      while (a.error == null && clock() < deadline) {
        require(!a.ready, "Unverified workspace accepted");
        step();
      }
      require(a.error != null && !a.ready, "Mismatched discovery/daemon identity accepted");
      Sys.println("PASS: invalid workspace discovery/identity fails closed");
    } else {
      while ((!a.ready || !b.ready) && clock() < deadline) {
        require(a.error == null && b.error == null, "Attachment failed: " + a.error + " / " + b.error);
        step();
      }
      require(
        a.ready && b.ready && a.instance == b.instance && a.view()[0].cwd == sys.FileSystem.fullPath(root),
        "Concurrent clients did not attach to one validated daemon"
      );
      if (mode == "hold") {
        var holdUntil = clock() + 6000;
        while (clock() < holdUntil) {
          if (clock() >= holdUntil - 3000) a.dispose();
          step();
          require(b.ready && b.error == null, "Connected sibling lost during idle grace");
        }
        Sys.println("PASS: authenticated clients keep daemon alive beyond its idle timeout");
        a.dispose();
        b.dispose();
        processes.shutdown();
        runtime.dispose();

        return;
      }
      var previousInstance = a.instance, previousEpoch = a.epoch();
      a.dispose();
      for (_ in 0...8) step();
      require(b.ready, "Closing a client stopped its sibling's daemon");
      // Switching cancels the old attachment and resumes the same persistent workspace on return.
      b.select(root + "/other");
      deadline = clock() + 115000;
      while (!b.ready && clock() < deadline) {
        require(b.error == null, "Folder switch failed: " + b.error);
        step();
      }
      require(
        b.ready && b.instance != previousInstance && b.view()[0].cwd == sys.FileSystem.fullPath(root + "/other"),
        "Folder switch kept the old catalog"
      );
      b.select(root);
      deadline = clock() + 15000;
      while (!b.ready && clock() < deadline) {
        require(b.error == null, "Reuse failed: " + b.error);
        step();
      }
      require(
        b.ready && b.instance == previousInstance && b.epoch() == previousEpoch,
        "Returning to a folder spawned a replacement daemon"
      );
      Sys
        .println("PASS: concurrent discovery/spawn, typed identity, shared reuse, folder switching and client-independent daemon lifetime");
    }
    a.dispose();
    b.dispose();
    processes.shutdown();
    require(processes.activeCount() == 0, "Attachment helper leaked");
    runtime.dispose();

  }
}
