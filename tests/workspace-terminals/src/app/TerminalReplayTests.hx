package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.RpcTerminalBackend;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.service.TerminalReplayLog;
import workspace.service.WorkspaceTerminalProtocol;
import terminalkit.Emulator;
import terminalsession.TerminalSession;

private class ReplayEndpoint implements WorkspaceRpcEndpoint {
  public var connection:RpcConnection;
  public function new(connection:RpcConnection) this.connection = connection;
  public function rootPath():Null<String> return "/fixture";
  public function serviceGeneration():String return "replay-fixture";
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return true;
  public function workspaceEpoch():Null<String> return null;
  public function hasCapability(capability:String):Bool return true;
}

/** Deterministic RPC replay using the same journal and emulator as the daemon. */
private class ReplayFixture {
  public final log:TerminalReplayLog;
  public final emulator:Emulator;
  public final endpoint:ReplayEndpoint;
  public final backend:RpcTerminalBackend;
  public final session:TerminalSession;
  var server:RpcConnection;
  public var snapshots = 0;
  public var openedColumns = 0;
  public var openedRows = 0;
  public var replayRequests = 0;
  public var controller = true;
  public var state = "running";
  public var corrupt = false;
  final legacy:Bool;
  public function new(legacy:Bool = false, limit:Int = 65536, requireGeometry:Bool = false) {
    this.legacy = legacy;
    emulator = Emulator.open(80, 24, 1000, "xterm-256color", false);
    log = new TerminalReplayLog(80, 24, limit);
    endpoint = new ReplayEndpoint(null);
    connect();
    backend = new RpcTerminalBackend(function() return endpoint, "fixture", "/fixture", false, null, null, false, requireGeometry);
    session = new TerminalSession(backend, Emulator.open(80, 24, 1000, "xterm-256color", false), false);
  }
  function info():TerminalInfo return {id:"fixture", cwd:"/fixture", state:state, exitCode:0,
    columns:emulator.columns(), rows:emulator.rows(), start:log.startOffset, end:log.endOffset,
    controller:controller, controlled:controller};
  public function connect():Void {
    if (endpoint.connection != null) { endpoint.connection.close(); server.close(); }
    var pair = MemoryTransport.pair(), clock = function() return Sys.time() * 1000;
    endpoint.connection = new RpcConnection(pair.client, clock);
    server = new RpcConnection(pair.server, clock);
    server.register(WorkspaceTerminalProtocol.OPEN, function(r, c) { openedColumns = r.columns; openedRows = r.rows; c.respond(info()); });
    server.register(WorkspaceTerminalProtocol.RESIZE, function(r, c) { resize(r.columns, r.rows); c.respond(info()); });
    server.register(WorkspaceTerminalProtocol.SET_CONTROL, function(_, c) c.respond(info()));
    if (!legacy) server.register(WorkspaceTerminalProtocol.REPLAY, function(r, c) {
      replayRequests++;
      if (r.cursor < log.startCursor) { c.fail({code:"replay_gap", message:"trimmed", ambiguous:false}); return; }
      var batch = log.read(r.cursor);
      var events = batch.events;
      if (corrupt) events = [for (event in events) {sequence:event.sequence + 1, offset:event.offset,
        data:event.data, columns:event.columns, rows:event.rows}];
      c.respond({terminal:info(), events:events, next:batch.next, end:log.endCursor});
    });
    server.register(WorkspaceTerminalProtocol.SNAPSHOT, function(_, c) {
      snapshots++;
      var value:TerminalScreenSnapshot = {terminal:info(), data:emulator.screenSnapshot()};
      if (!legacy) value.cursor = log.endCursor;
      c.respond(value);
    });
  }
  public function output(text:String):Void {
    var bytes = Bytes.ofString(text);
    emulator.feed(bytes);
    log.output(bytes, bytes.length);
  }
  public function resize(columns:Int, rows:Int):Void {
    if (columns == emulator.columns() && rows == emulator.rows()) return;
    emulator.resize(columns, rows);
    log.geometry(columns, rows);
  }
  public function step(apply:Bool = true):Void {
    session.pollEvents(); endpoint.connection.poll(); server.poll(); endpoint.connection.poll();
    if (apply) session.pollEvents();
  }
  public function pump():Void {
    for (_ in 0...24) { step(); Sys.sleep(0.005); }
  }
  public function close():Void {
    session.close(); endpoint.connection.close(); server.close(); emulator.close();
  }
}

class TerminalReplayTests {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  static function equal(a:Emulator, b:Emulator):Bool {
    if (a.columns() != b.columns() || a.rows() != b.rows()) { Sys.println("grid " + a.columns() + "x" + a.rows() + " / " + b.columns() + "x" + b.rows()); return false; }
    a.snapshot(); b.snapshot();
    for (row in 0...a.rows()) {
      var ac = a.rowCells(row), bc = b.rowCells(row);
      for (column in 0...ac.length)
        if (ac[column].text != bc[column].text || ac[column].width != bc[column].width || ac[column].style != bc[column].style) { Sys.println("cell " + row + ":" + column + " " + ac[column].text + "/" + bc[column].text + " style " + ac[column].style + "/" + bc[column].style); return false; }
    }
    var ac = a.cursor(), bc = b.cursor();
    return ac.column == bc.column && ac.row == bc.row && ac.mode == bc.mode;
  }
  public static function run():Void {
    var atomic = new ReplayFixture();
    atomic.output("prompt$ ");
    for (_ in 0...8) {
      atomic.step(false);
      if (atomic.replayRequests > 0) break;
    }
    require(atomic.replayRequests > 0 && atomic.session.offset == 0 && !atomic.backend.isSynchronized(),
      "RPC receipt exposed readiness before emulator application");
    atomic.session.pollEvents();
    require(atomic.backend.isSynchronized() && equal(atomic.emulator, atomic.session.emulator),
      "Applied replay did not publish readiness");
    atomic.close();

    var measured = new ReplayFixture(false, 65536, true);
    measured.pump();
    require(measured.openedColumns == 0 && !measured.backend.isSynchronized(), "Terminal opened before measured geometry");
    measured.session.resize(89, 14);
    measured.output("prompt$ ");
    measured.pump();
    require(measured.openedColumns == 89 && measured.openedRows == 14,
      "OPEN did not use measured terminal dimensions");
    require(measured.backend.isSynchronized() && equal(measured.emulator, measured.session.emulator),
      "Measured terminal did not become ready after replay");
    measured.close();

    var fixture = new ReplayFixture();
    var prompt = "joao@tritao-desktop:~/dev/materia/exosuit/src$ ";
    // Historical output was produced at 80 columns, but metadata now says 20.
    // Replaying it at current dimensions used to create stray wrapped fragments.
    fixture.output(prompt);
    fixture.resize(20, 4);
    fixture.output("\r\x1b[2Kshort$ ");
    fixture.resize(80, 24);
    fixture.output("\r\x1b[2K" + prompt);
    fixture.pump();
    require(equal(fixture.emulator, fixture.session.emulator), "Historical output used current geometry");
    var before = fixture.session.emulator.columns();
    fixture.session.resize(18, 3);
    require(fixture.session.emulator.columns() == before, "Remote resize changed emulator before acknowledgement");
    // A newer request supersedes the first before the RPC is sent.
    fixture.session.resize(64, 12);
    fixture.pump();
    require(fixture.emulator.columns() == 64 && equal(fixture.emulator, fixture.session.emulator), "Coalesced resize diverged");
    // Two accepted resizes at the same byte offset must remain distinguishable.
    fixture.resize(22, 4); fixture.resize(80, 24);
    fixture.pump();
    require(equal(fixture.emulator, fixture.session.emulator), "Geometry-only records were lost");
    // Output between accepted resizes, including alternate screen and Unicode.
    fixture.output("\x1b[?1049h\x1b[31mwide 界 é\x1b[0m");
    fixture.resize(25, 5); fixture.output("\r\nnext"); fixture.resize(80, 24);
    fixture.output("\x1b[?1049l"); fixture.pump();
    require(equal(fixture.emulator, fixture.session.emulator), "Alternate-screen replay diverged");
    fixture.connect(); fixture.resize(30, 6); fixture.output("\r\nreconnected"); fixture.pump();
    require(equal(fixture.emulator, fixture.session.emulator), "Reconnect lost replay cursor or geometry");
    // Output history and geometry metadata are both bounded. Recover from a gap
    // using a coherent screen/cursor snapshot, then resume ordered replay.
    fixture.output([for (_ in 0...70000) "x"].join("")); fixture.pump();
    require(fixture.snapshots > 0 && equal(fixture.emulator, fixture.session.emulator), "Trimmed history did not recover atomically");
    fixture.resize(40, 8); fixture.output("\r\npost-snapshot"); fixture.pump();
    require(equal(fixture.emulator, fixture.session.emulator), "Replay did not resume after snapshot");
    fixture.close();

    var viewer = new ReplayFixture();
    viewer.controller = false;
    viewer.output(prompt); viewer.resize(20, 4); viewer.pump();
    require(!viewer.backend.canControl() && equal(viewer.emulator, viewer.session.emulator), "Viewer lost authoritative geometry");
    viewer.session.resize(120, 30); viewer.pump();
    require(viewer.emulator.columns() == 20 && equal(viewer.emulator, viewer.session.emulator), "Viewer changed shared geometry");
    viewer.close();

    var exited = new ReplayFixture(false, 262144);
    exited.output([for (_ in 0...100000) "z"].join("")); exited.state = "exited";
    for (_ in 0...8) { if (exited.replayRequests > 0) break; exited.step(); }
    require(!exited.backend.isSynchronized() && exited.session.status == "running" && exited.session.offset < exited.log.endOffset,
      "Exit was delivered before the last replay batch");
    exited.pump();
    require(exited.backend.isSynchronized() && exited.session.status == "exited" && equal(exited.emulator, exited.session.emulator), "Exit lost trailing replay output");
    exited.close();

    // A long history can contain many intermediate screens. None is ready to paint.
    var loading = new ReplayFixture(false, 262144);
    loading.output([for (_ in 0...30000) "p\r\n"].join("") + "\x1b[2J\x1b[Hprompt$ ");
    for (_ in 0...12) {
      loading.step();
      if (loading.session.offset > 0) break;
    }
    require(loading.session.offset > 0 && loading.session.offset < loading.log.endOffset
      && !loading.backend.isSynchronized(), "Partial history was exposed as a ready terminal");
    loading.pump();
    require(loading.backend.isSynchronized() && equal(loading.emulator, loading.session.emulator),
      "Final terminal screen did not replace intermediate history");
    loading.close();

    var invalid = new ReplayFixture(); invalid.output("must not be applied"); invalid.corrupt = true;
    var refused = false;
    try invalid.pump() catch (_:Dynamic) refused = true;
    require(refused && invalid.session.offset == 0, "Out-of-order replay was partially applied");
    invalid.close();

    var log = new TerminalReplayLog(80, 24, 65536);
    for (i in 0...5000) log.geometry(20 + i % 2, 4);
    require(log.startCursor > 0 && log.read(log.startCursor).events.length <= 128, "Geometry-only history is unbounded");
    // Older daemons have no ordered stream. Atomic snapshots remain safe.
    var legacy = new ReplayFixture(true);
    legacy.output(prompt); legacy.resize(20, 4); legacy.output("\r\nlegacy"); legacy.pump();
    require(legacy.snapshots > 0 && equal(legacy.emulator, legacy.session.emulator), "Legacy daemon fallback replayed bytes at wrong geometry");
    legacy.resize(80, 24); legacy.output("\r\nresized"); legacy.pump();
    require(equal(legacy.emulator, legacy.session.emulator), "Legacy snapshot refresh diverged");
    legacy.close();
    Sys.println("PASS: ordered terminal output/resize replay, coalescing, geometry-only events, reconnect, viewers, alternate screen, Unicode, exit ordering, invalid batches, bounded history, snapshot recovery and legacy daemon");
  }
}
