package app;

import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import platform.Platform;
import process.ProcessManager;
import workspace.client.LocalWorkspaceClient;
import workspace.client.RpcTerminalBackend;
import terminalsession.TerminalSession;
import terminalkit.Emulator;
import haxe.io.Bytes;

class TerminalRpcTestMain {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }
  static function text(emulator:Emulator):String {
    emulator.snapshot();
    var lines:Array<String> = [];
    for (row in 0...emulator.rows()) lines.push(emulator.rowText(row));
    return lines.join("\n");
  }
  static function marker(emulator:Emulator, prefix:String):String {
    emulator.snapshot();
    for (row in 0...emulator.rows()) {
      var line = emulator.rowText(row), at = line.indexOf(prefix);
      if (at >= 0) return StringTools.trim(line.substring(at + prefix.length));
    }
    return "";
  }
  static function main():Void {
    var args = Sys.args(), mode = args[0], root = args[1], launcher = args[2];

    var runtime = NativeKitRuntime.start(), processes = new ProcessManager();
    if (mode == "contracts") {
      TerminalServiceTests.run(root);
      TerminalCatalogTests.run(root);
      WorkspaceGroupTests.run(root);
      processes.shutdown();
      runtime.dispose();

      return;
    }
    var clock = function() return NativeKit.nk_time_seconds() * 1000;
    var client = new LocalWorkspaceClient(runtime.events, processes, launcher, clock);
    client.select(root);
    if(mode=="catalog") {
      TerminalCatalogClientTests.run(client,runtime);
      client.dispose();processes.shutdown();runtime.dispose();return;
    }
    var backend = new RpcTerminalBackend(function() return client, "test-terminal", root, mode == "create");
    var session = new TerminalSession(backend, Emulator.open(80, 24), false);
    var step = function() {
      runtime.events.wait(0.005);
      for (_ in 0...128) if (!runtime.events.poll()) break;
      client.poll();
      require(client.error == null, "Workspace failed: " + client.error);
      session.pollEvents();
    };
    var deadline = clock() + 15000;
    while (!backend.isAttached()) {
      require(clock() < deadline, "Terminal attach timed out");
      step();
    }
    if (mode == "create") {
      session.write(Bytes.ofString("KEEP=alive; printf 'DAEMON_%s:%s\\n' PID $$\n"));
      while (marker(session.emulator, "DAEMON_PID:") == "") {
        require(clock() < deadline, "Shell output missing");
        step();
      }
      var pid = marker(session.emulator, "DAEMON_PID:");
      sys.io.File.saveContent(root + "/shell-pid", pid);
      session.write(Bytes.ofString("sleep 3; printf 'DETACHED_%s\\n' OUTPUT\n"));
      // Pump until queued input has been acknowledged before closing the client process.
      var flushUntil = clock() + 500;
      while (clock() < flushUntil) step();
      Sys.println("PASS: shell created through typed RPC, input delivered, editor process detaches");
    } else {
      while (marker(session.emulator,
        "DETACHED_OUTPUT") == "" && text(session.emulator).indexOf("DETACHED_OUTPUT") < 0) {
        require(clock() < deadline, "Disconnected output was not replayed");
        step();
      }
      var previous = sys.io.File.getContent(root + "/shell-pid");
      require(marker(session.emulator, "DAEMON_PID:") == previous, "Reattach replaced the shell");
      session.resize(96, 32);
      var resizeUntil = clock() + 300;
      while (clock() < resizeUntil) step();
      session.write(Bytes.ofString("printf 'REATTACHED_%s:%s\\n' \"$KEEP\" $$; stty size\n"));
      while (marker(session.emulator, "REATTACHED_alive:") == "") {
        require(clock() < deadline, "Reattached shell did not respond");
        step();
      }
      require(
        marker(session.emulator, "REATTACHED_alive:") == previous,
        "Shell state/PID changed across editor processes"
      );
      while (text(session.emulator).indexOf("32 96") < 0) {
        require(clock() < deadline, "PTY resize not applied");
        step();
      }
      session.write(Bytes.ofString("exit 7\n"));
      while (session.status != "exited") {
        require(clock() < deadline, "Terminal exit was not delivered");
        step();
      }
      require(session.exitCode == 7, "Terminal exit code lost");
      Sys.println("PASS: same shell PID/state, detached output replay, resize and exit across editor processes");
    }
    session.close();
    client.dispose();
    processes.shutdown();
    runtime.dispose();

  }
}
