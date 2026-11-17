package app;

import haxe.Json;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import sys.FileSystem;
import sys.io.File;
import workspace.runtime.TerminalHosts;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** A terminal manager as the service runs it, polled by a test: each poll also delivers the events of its hosts' pipes. */
class TestManager extends WorkspaceTerminalManager {
  override public function poll():Void {
    TestTerminals.pump();
    super.poll();
  }
}

/**
  Terminal managers whose terminals run in real terminal hosts (the terminal host program built beside the agent), with
  their state under the test's folder. Every host the tests started is ended by `endAll`, so
  nothing outlives the run.
**/
class TestTerminals {
  public static var events:Null<EventPump> = null;
  /** The agent program (its bytecode) whose terminal host program the hosts run. */
  public static var agentProgram:Null<String> = null;
  static final states:Array<String> = [];

  /**
    A manager of workspace `workspace` whose hosts keep their folders in `<root>/terminal-state/<state>`: a later
    manager given the same `state` is the next service generation and adopts the hosts the earlier one left. Without
    `state` each manager has folders of its own.
  **/
  public static function manager(workspace:String, instance:String, root:String, journal:Int = WorkspaceTerminalManager.REPLAY_BYTES,
      ?store:WorkspaceTerminalPersistence, ?groups:Void -> Array<WorkspaceGroup>, ?state:String):TestManager
    return new TestManager(workspace, instance, root, hosts(root, state == null ? instance + "-" + (made++) : state), journal, store, groups);
  static var made = 0;

  public static function hosts(root:String, state:String):TerminalHosts {
    var pump = events;
    if (pump == null) throw "TestTerminals.events is not set";
    var directory = Path.join([FileSystem.fullPath(root), "terminal-state", state]);
    if (!FileSystem.exists(directory)) FileSystem.createDirectory(directory);
    if (states.indexOf(directory) < 0) states.push(directory);
    var agent = agentProgram;
    if (agent == null) throw "TestTerminals.agentProgram is not set";
    return new TerminalHosts(pump, directory, Path.join([FileSystem.fullPath(root), "terminal-state", "runtime"]), agent, root, "test-workspace");
  }

  public static function pump():Void {
    var pump = events;
    if (pump == null) return;
    for (_ in 0...128) if (!pump.poll()) break;
  }

  static function folders(state:String):Array<String> {
    var base = Path.join([state, "terminal-hosts"]);
    return FileSystem.exists(base) ? [for (name in FileSystem.readDirectory(base)) Path.join([base, name])] : [];
  }

  /** Every host started in `<root>/terminal-state/<state>` has started (written its host.json). */
  public static function started(root:String, state:String):Bool {
    var base = Path.join([FileSystem.fullPath(root), "terminal-state", state, "terminal-hosts"]);
    if (!FileSystem.exists(base)) return false;
    for (name in FileSystem.readDirectory(base))
      if (!FileSystem.exists(Path.join([base, name, "host.json"]))) return false;
    return true;
  }

  /**
    Kills every host started under the tests' state folders that still runs. A host that is starting writes its
    host.json only after it spawned its program, so the folders are swept until a second of sweeps finds none running.
  **/
  public static function endAll():Void {
    var until = Sys.time() + 10, quietSince = Sys.time();
    while (Sys.time() < until && Sys.time() - quietSince < 1) {
      if (killRunning() > 0) quietSince = Sys.time();
      Sys.sleep(0.1);
    }
  }

  /** Kills the hosts whose host.json names a running process; returns how many there were. */
  static function killRunning():Int {
    var killed = 0;
    for (state in states) for (folder in folders(state)) {
      var path = Path.join([folder, "host.json"]);
      if (FileSystem.exists(Path.join([folder, "spec.bin"]))) killed++;
      if (!FileSystem.exists(path)) continue;
      try {
        var host:Dynamic = Json.parse(File.getContent(path));
        var pid:Int = host.pid, executable:String = host.executable;
        if (!app.AgentNative.processAlive(pid, executable)) continue;
        killed++;
        var handle = app.AgentNative.openProcessIdentity(pid, executable);
        if (handle != null) {
          app.AgentNative.terminateProcess(handle);
          app.AgentNative.closeProcessIdentity(handle);
        }
      } catch (_:Dynamic) {}
    }
    return killed;
  }
}
