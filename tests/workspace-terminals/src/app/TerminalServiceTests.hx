package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;

class TerminalServiceTests {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }
  public static function run(root:String):Void {
    var clock = function() return Sys.time() * 1000;
    var manager = new WorkspaceTerminalManager("w", "instance", root, 65536);
    var pair = MemoryTransport.pair(), client = new RpcConnection(pair.client, clock), server = new RpcConnection(
      pair.server,
      clock
    );
    manager.bind(server, [WorkspaceTerminalProtocol.READ]);
    var error = "";
    client.call(WorkspaceTerminalProtocol.OPEN, {
      workspace: "w",
      instance: "instance",
      id: "bounded",
      create: true,
      columns: 80,
      rows: 24
    }, 1000, function(_) {
      throw "Read-only peer created a runtime";
    }, function(e) error = e.code);
    client.poll();
    server.poll();
    client.poll();
    require(error == "unauthorized", "Terminal creation capability not enforced");
    var denied = 0;
    client.call(WorkspaceTerminalProtocol.INPUT, {
      workspace: "w",
      instance: "instance",
      id: "bounded",
      sequence: 1,
      data: Bytes.ofString("x")
    }, 1000, function(_) {
      throw "Read-only peer wrote input";
    }, function(e) {
      require(e.code == "unauthorized", "Input grant ignored");
      denied++;
    }
    );
    client.call(WorkspaceTerminalProtocol.RESIZE, {
      workspace: "w",
      instance: "instance",
      id: "bounded",
      columns: 80,
      rows: 24
    }, 1000, function(_) {
      throw "Read-only peer resized terminal";
    }, function(e) {
      require(e.code == "unauthorized", "Resize grant ignored");
      denied++;
    }
    );
    client.call(WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "w", instance: "instance", id: "bounded"}, 1000, function(_) {
      throw "Read-only peer killed terminal";
    }, function(e) {
      require(e.code == "unauthorized", "Terminate grant ignored");
      denied++;
    }
    );
    client.poll();
    server.poll();
    client.poll();
    require(denied == 3, "Read-only controls were not all refused");
    client.close();
    server.close();
    pair = MemoryTransport.pair();
    client = new RpcConnection(pair.client, clock);
    server = new RpcConnection(pair.server, clock);
    manager.bind(server, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL]);
    var step = function() {
      client.poll();
      server.poll();
      manager.poll();
      client.poll();
    };
    var open:TerminalOpen = {workspace: "w", instance: "instance", id: "bounded", create: true, columns: 80, rows: 24};
    var done = false;
    // A committed open with a lost reply must not create a second shell when retried.
    pair.server.loseNext();
    client.call(WorkspaceTerminalProtocol.OPEN, open, 10, function(_) {
      throw "Injected lost reply survived";
    }, function(_) done = true);
    var deadline = clock() + 2000;
    while (!done) {
      require(clock() < deadline, "Lost open reply did not expire");
      step();
      Sys.sleep(0.005);
    }
    require(manager.activeCount() == 1, "Runtime was not created before reply loss");
    done = false;
    client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    while (!done) {
      require(clock() < deadline, "Open retry timed out");
      step();
    }
    require(manager.activeCount() == 1, "Open retry duplicated PTY");
    error = "";
    client.call(WorkspaceTerminalProtocol.OPEN, {
      workspace: "w",
      instance: "old",
      id: "bounded",
      create: true,
      columns: 80,
      rows: 24
    }, 1000, function(_) {
      throw "Stale instance created a runtime";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "invalid_request", "Stale instance accepted");
    done = false;
    var input:TerminalInput = {
      workspace: "w",
      instance: "instance",
      id: "bounded",
      sequence: 1,
      data: Bytes.ofString("head -c 150000 /dev/zero | tr '\\000' x; printf DONE\\n\n")
    };
    client.call(WorkspaceTerminalProtocol.INPUT, input, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    while (!done) {
      require(clock() < deadline, "Input timed out");
      step();
    }
    error = "";
    client.call(WorkspaceTerminalProtocol.INPUT, input, 1000, function(_) {
      throw "Duplicate input executed";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "input_sequence", "Duplicate input accepted");
    var advanced = false;
    deadline = clock() + 10000;
    while (!advanced) {
      done = false;
      client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(info) {
        advanced = info.end > 100000;
        done = true;
      }, function(e) {
        throw e.code;
      }
      );
      while (!done) {
        require(clock() < deadline, "Bounded output did not arrive");
        step();
        Sys.sleep(0.005);
      }
    }
    error = "";
    client.call(WorkspaceTerminalProtocol.OUTPUT,
      {workspace: "w", instance: "instance", id: "bounded", offset: 0}, 1000, function(_) {
      throw "Trimmed replay was silently accepted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "replay_gap", "Trimmed output did not report a gap");
    done = false;
    client.call(WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "w", instance: "instance", id: "bounded"}, 1000, function(_) done = true, function(e) {
      throw e.code;
    }
    );
    deadline = clock() + 5000;
    while (!done || manager.activeCount() != 0) {
      require(clock() < deadline, "Explicit termination did not retire PTY");
      step();
      Sys.sleep(0.005);
    }
    manager.dispose();
    client.close();
    server.close();
    require(manager.activeCount() == 0, "Runtime disposal leaked a shell");
    Sys
      .println("PASS: terminal capability, stale instance, lost-open reconciliation, duplicate input and bounded replay gap");
  }
}
