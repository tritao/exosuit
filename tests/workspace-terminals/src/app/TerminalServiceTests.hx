package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;
import terminalkit.Emulator;

class TerminalServiceTests {
  static function require(value:Bool, message:String):Void {
    if (!value) throw message;
  }
  public static function run(root:String):Void {
    var clock = function() return Sys.time() * 1000;
    var manager = TestTerminals.manager("w", "instance", root, 65536);
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
    var changes = 0;
    client.onNotification(WorkspaceTerminalProtocol.CHANGED, WorkspaceTerminalProtocol.decodeChange, function(event) {
      require(event.workspace == "w" && event.instance == "instance" && event.id == "bounded", "Notification scope mismatch");
      changes++;
    });
    var open:TerminalOpen = {watch:true, workspace: "w", instance: "instance", id: "bounded", create: true, columns: 80, rows: 24};
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
    client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(info) {
      require(info.notifications == true, "Daemon omitted notification support");
      require(info.name == "Terminal 1", "Open response omitted the service-owned terminal name");
      done = true;
    }, function(e) {
      throw e.code;
    }
    );
    while (!done) {
      require(clock() < deadline, "Open retry timed out");
      step();
    }
    require(manager.activeCount() == 1, "Open retry duplicated PTY");
    // Service records accepted geometry even when no PTY output intervenes.
    // Drain RPC only here so both resizes have the same byte offset.
    for (width in [20, 80]) {
      done = false;
      client.call(WorkspaceTerminalProtocol.RESIZE, {workspace:"w", instance:"instance", id:"bounded",
        columns:width, rows:24}, 1000, function(_) done = true, function(e) throw e.code);
      client.poll(); server.poll(); client.poll();
      require(done, "Ordered resize was not acknowledged");
    }
    var beforeChanges = changes;
    manager.poll(); client.poll();
    require(changes == beforeChanges + 1, "Geometry changes were not coalesced into one notification");
    client.call(WorkspaceTerminalProtocol.UNWATCH, {workspace:"w", instance:"instance", id:"bounded"},
      1000, function(_) {}, function(e) throw e.code);
    client.poll(); server.poll(); client.poll();
    beforeChanges = changes;
    for (width in [79, 80]) {
      client.call(WorkspaceTerminalProtocol.RESIZE, {workspace:"w", instance:"instance", id:"bounded", columns:width, rows:24},
        1000, function(_) {}, function(e) throw e.code);
      client.poll(); server.poll(); manager.poll(); client.poll();
    }
    require(changes == beforeChanges, "Unwatched connection still receives notifications");
    // Reattaching opts back in; old clients omit watch and keep polling.
    client.call(WorkspaceTerminalProtocol.OPEN, open, 1000, function(_) {}, function(e) throw e.code);
    client.poll(); server.poll(); client.poll();
    var replay:Null<TerminalReplay> = null;
    client.call(WorkspaceTerminalProtocol.REPLAY, {workspace:"w", instance:"instance", id:"bounded", cursor:0},
      1000, function(value) replay = value, function(e) throw e.code);
    client.poll(); server.poll(); client.poll();
    require(replay != null && replay.next == replay.end, "Service replay cursor did not cover the current journal");
    var batch:TerminalReplay = cast replay;
    var geometry = [for (event in batch.events) if (event.data.length == 0) event];
    require(geometry.length == 5 && geometry[0].columns == 80 && geometry[1].columns == 20
      && geometry[2].columns == 80 && geometry[1].offset == geometry[2].offset
      && geometry[1].sequence + 1 == geometry[2].sequence,
      "Service lost geometry-only replay order");

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
      data: TestShell.flood()
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
    // A new view (another pane, a restarted terminal) numbers its input from 1 once control is given again.
    deadline = clock() + 2000;
    var given = false;
    client.call(WorkspaceTerminalProtocol.SET_CONTROL, {workspace: "w", instance: "instance", id: "bounded",
      claim: true, takeover: false}, 1000, function(_) given = true, function(e) throw e.code);
    while (!given) {
      require(clock() < deadline, "Control was not given again");
      step();
    }
    var restarted = false;
    var again:TerminalInput = {workspace: "w", instance: "instance", id: "bounded", sequence: 1, data: haxe.io.Bytes.ofString(" ")};
    client.call(WorkspaceTerminalProtocol.INPUT, again, 1000, function(_) restarted = true,
      function(e) throw "Input numbered from 1 after control was given again was refused: " + e.code);
    while (!restarted) {
      require(clock() < deadline, "Input after control was given again timed out");
      step();
    }
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
    client.call(WorkspaceTerminalProtocol.REPLAY,
      {workspace: "w", instance: "instance", id: "bounded", cursor: 0}, 1000, function(_) {
      throw "Trimmed replay was silently accepted";
    }, function(e) error = e.code);
    step();
    step();
    require(error == "replay_gap", "Trimmed output did not report a gap");
    var screen:Null<TerminalScreenSnapshot> = null;
    client.call(WorkspaceTerminalProtocol.SNAPSHOT,
      {workspace: "w", instance: "instance", id: "bounded"}, 3000,
      function(value) screen = value, function(e) throw e.code);
    deadline = clock() + 3000;
    while (screen == null) {
      require(clock() < deadline, "Terminal screen snapshot timed out");
      step();
    }
    var shot = screen;
    if (shot == null) throw "Terminal screen snapshot timed out";
    require(shot.cursor != null && shot.cursor > batch.next && shot.terminal.end >= 100000 && shot.data.length >= 64
      && shot.data.length <= 3 * 1024 * 1024,
      "Terminal screen snapshot was not bounded at the current output offset");
    var restored = Emulator.open(10, 3, 8, "xterm-256color", false);
    restored.restoreScreenSnapshot(shot.data);
    restored.snapshot();
    var outputVisible = false;
    for (row in 0...restored.rows()) if (restored.rowText(row).indexOf("x") >= 0
      || restored.rowText(row).indexOf("DONE") >= 0) outputVisible = true;
    restored.close();
    require(outputVisible, "Terminal screen snapshot did not restore the live viewport");
    // A phone reaches the service through a relay: no answer may be bigger than one stream frame, whatever the screen holds.
    var frame = workspace.service.MachineDirectoryProtocol.MachineStreamFrame.MAX_PAYLOAD;
    // A screen where every cell has its own colours: the snapshot is bigger than one frame and arrives in pages.
    var drawn = false, resized = false;
    // A desktop-sized terminal (a phone observing it gets that grid): 160 x 50 cells of mosaic is far more than 48 KiB.
    client.call(WorkspaceTerminalProtocol.RESIZE, {workspace:"w", instance:"instance", id:"bounded", columns:160, rows:50}, 1000,
      function(_) resized = true, function(e) throw e.code);
    deadline = clock() + 5000;
    while (!resized) { require(clock() < deadline, "Resize timed out"); step(); }
    client.call(WorkspaceTerminalProtocol.INPUT, {workspace:"w", instance:"instance", id:"bounded", sequence:2, data:TestShell.mosaic(50, 160)},
      1000, function(_) drawn = true, function(e) throw e.code);
    // Reads a whole snapshot page by page as a client does; every page must fit a frame.
    var readSnapshot = function():{pages:Int, data:Bytes} {
      var offset = 0, total = 0, pages = 0, token = 0, joined:Null<Bytes> = null;
      while (true) {
        var page:Null<TerminalScreenSnapshot> = null;
        client.call(WorkspaceTerminalProtocol.SNAPSHOT, {workspace:"w", instance:"instance", id:"bounded", token:token, offset:offset},
          1000, function(value) page = value, function(e) throw e.code);
        var until = clock() + 2000;
        while (page == null) { require(clock() < until, "Snapshot page timed out"); step(); }
        var got:TerminalScreenSnapshot = cast page;
        require(WorkspaceTerminalProtocol.SNAPSHOT.encodeResponse(got).length <= frame, "A snapshot page is bigger than one relay frame");
        pages++;
        if (got.total == null) { require(offset == 0, "A snapshot ended in the middle"); return {pages:pages, data:got.data}; }
        if (offset == 0) { total = got.total; token = got.token == null ? -1 : got.token; joined = Bytes.alloc(total); }
        var target:Bytes = cast joined;
        require(offset + got.data.length <= total && got.data.length > 0, "A snapshot page overran the snapshot");
        target.blit(offset, got.data, 0, got.data.length);
        offset += got.data.length;
        if (offset == total) return {pages:pages, data:target};
      }
    };
    deadline = clock() + 15000;
    var shotPages = 0, lastSize = 0, lastPages = 0;
    var mosaicData:Null<Bytes> = null;
    while (mosaicData == null) {
      require(clock() < deadline, "The colour mosaic never reached the screen (drawn " + drawn + ", last snapshot " + lastSize + " bytes in " + lastPages + " pages)");
      step();
      Sys.sleep(0.1);
      if (!drawn) continue;
      var read = readSnapshot();
      lastSize = read.data.length; lastPages = read.pages;
      // The shell paints for a while: wait until the snapshot shows the mosaic (capital X cells, the flood before it was lower case) in a middle row.
      var probe = Emulator.open(160, 50, 8, "xterm-256color", false);
      probe.restoreScreenSnapshot(read.data);
      probe.snapshot();
      var painted = probe.rowText(10).indexOf("XXXXXXX") >= 0;
      probe.close();
      if (read.pages > 1 && painted) { shotPages = read.pages; mosaicData = read.data; }
    }
    require(shotPages > 1, "The paged colour mosaic snapshot did not restore (" + shotPages + " pages)");
    var peer = MemoryTransport.pair();
    var viewer = new RpcConnection(peer.client, clock), viewerServer = new RpcConnection(peer.server, clock);
    manager.bind(viewerServer, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL]);
    var viewerStep = function() {
      client.poll();
      viewer.poll();
      server.poll();
      viewerServer.poll();
      manager.poll();
      client.poll();
      viewer.poll();
    };
    var viewerInfo:Null<TerminalInfo> = null;
    viewer.call(WorkspaceTerminalProtocol.OPEN, {workspace: "w", instance: "instance", id: "bounded",
      create: false, columns: 80, rows: 24}, 1000, function(info) viewerInfo = info, function(e) throw e.code);
    deadline = clock() + 2000;
    while (viewerInfo == null) {
      require(clock() < deadline, "Read-only viewer did not attach");
      viewerStep();
    }
    require(viewerInfo.controlled == true && viewerInfo.controller == false,
      "Second viewer did not observe exclusive terminal ownership");
    error = "";
    viewer.call(WorkspaceTerminalProtocol.INPUT, {workspace: "w", instance: "instance", id: "bounded",
      sequence: 1, data: Bytes.ofString("should-not-run\n")}, 1000, function(_) throw "Viewer input bypassed controller lease",
      function(e) error = e.code);
    viewerStep(); viewerStep();
    require(error == "terminal_controlled", "Input from the non-controller was not refused");
    error = "";
    viewer.call(WorkspaceTerminalProtocol.RESIZE, {workspace: "w", instance: "instance", id: "bounded",
      columns: 100, rows: 30}, 1000, function(_) throw "Viewer resized a shared PTY",
      function(e) error = e.code);
    viewerStep(); viewerStep();
    require(error == "terminal_controlled", "Resize from the non-controller was not refused");
    viewerInfo = null;
    viewer.call(WorkspaceTerminalProtocol.SET_CONTROL, {workspace: "w", instance: "instance", id: "bounded",
      claim: true, takeover: true}, 1000, function(info) viewerInfo = info, function(e) throw e.code);
    deadline = clock() + 2000;
    while (viewerInfo == null) {
      require(clock() < deadline, "Explicit controller transfer timed out");
      viewerStep();
    }
    require(viewerInfo.controller == true, "Explicit controller transfer was not granted");
    error = "";
    client.call(WorkspaceTerminalProtocol.INPUT, {workspace: "w", instance: "instance", id: "bounded",
      sequence: 2, data: Bytes.ofString("old-owner-must-not-run\n")}, 1000, function(_) throw "Former controller retained input access",
      function(e) error = e.code);
    viewerStep(); viewerStep();
    require(error == "terminal_controlled", "Transferred controller retained input access");
    viewer.close();
    manager.poll();
    viewerServer.poll();
    var recovered:Null<TerminalInfo> = null;
    client.call(WorkspaceTerminalProtocol.SET_CONTROL, {workspace: "w", instance: "instance", id: "bounded",
      claim: true, takeover: false}, 1000, function(info) recovered = info, function(e) throw e.code);
    deadline = clock() + 2000;
    while (recovered == null) {
      require(clock() < deadline, "Controller lease did not recover after disconnect");
      viewerStep();
    }
    require(recovered.controller == true, "Disconnected controller did not release its lease");
    viewerServer.close();
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
