package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcEnvelope;
import haxeon.rpc.RpcProtocol;
import workspace.client.RpcTerminalBackend;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;
import terminalsession.TerminalSession;
import terminalkit.Emulator;

/** The client's side of a connection, counting the requests it sends by method and the history limits it asks for. */
private class CountingTransport implements MessageTransport {
  final inner:MessageTransport;
  final counts:Map<Int, Int> = [];
  /** `historyLimit` of every SNAPSHOT that starts a snapshot (token 0); -1 for none. */
  public final historyLimits:Array<Int> = [];
  public function new(inner:MessageTransport) this.inner = inner;
  public function count(method:Int):Int { var n = counts.get(method); return n == null ? 0 : n; }
  public function isOpen():Bool return inner.isOpen();
  public function send(message:Bytes):Bool {
    var sent = inner.send(message);
    if (sent) switch (RpcProtocol.decode(message, 1 << 28)) {
      case Request(_, method, _, payload):
        counts.set(method, count(method) + 1);
        if (method == WorkspaceTerminalProtocol.SNAPSHOT.id) {
          var query = WorkspaceTerminalProtocol.SNAPSHOT.decodeRequest(payload);
          if (query.token == 0) historyLimits.push(query.historyLimit == null ? -1 : query.historyLimit);
        }
      default:
    }
    return sent;
  }
  public function receive():Null<Bytes> return inner.receive();
  public function close():Void inner.close();
}

/** One client connection to the service under test. */
private class Link {
  public final client:RpcConnection;
  public final server:RpcConnection;
  public final counter:CountingTransport;
  public function new(manager:WorkspaceTerminalManager) {
    var pair = MemoryTransport.pair(), clock = function() return Sys.time() * 1000;
    counter = new CountingTransport(pair.client);
    client = new RpcConnection(counter, clock);
    server = new RpcConnection(pair.server, clock);
    manager.bind(server, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL]);
  }
  public function close():Void { client.close(); server.close(); }
}

private class FlowEndpoint implements WorkspaceRpcEndpoint {
  public var connection:Null<RpcConnection>;
  final root:String;
  final generation:String;
  var router:Null<workspace.client.WorkspaceTerminalEvents>;
  public function new(root:String, generation:String) { this.root = root; this.generation = generation; }
  public function rootPath():Null<String> return root;
  public function serviceGeneration():String return generation;
  public function workspaceEpoch():Null<String> return generation;
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return true;
  public function hasCapability(value:String):Bool return true;
  public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> {
    var c = connection;
    if (c == null) return null;
    var current = router;
    if (current == null || current.connection != c) { current = new workspace.client.WorkspaceTerminalEvents(c); router = current; }
    return current;
  }
}

/** A real WorkspaceTerminalManager with real shells, its client connections and the views polled with it. */
private class Rig {
  public final manager:WorkspaceTerminalManager;
  public final instance:String;
  public final links:Array<Link> = [];
  public final sessions:Array<TerminalSession> = [];
  public function new(root:String, instance:String, journal:Int) {
    this.instance = instance;
    manager = new WorkspaceTerminalManager("workspace", instance, root, journal);
  }
  public function link():Link { var made = new Link(manager); links.push(made); return made; }
  public function drop(link:Link):Void { link.close(); links.remove(link); }
  public function step():Void {
    for (l in links) l.server.poll();
    manager.poll();
    for (l in links) { l.client.poll(); l.server.poll(); l.client.poll(); }
    for (s in sessions) s.pollEvents();
  }
  public function until(check:Void->Bool, message:String, seconds:Float = 15):Void {
    var deadline = Sys.time() + seconds;
    while (!check()) { if (Sys.time() > deadline) throw message; step(); Sys.sleep(0.002); }
  }
  public function pump(seconds:Float):Void {
    var end = Sys.time() + seconds;
    while (Sys.time() < end) { step(); Sys.sleep(0.002); }
  }
  public function open(link:Link, id:String, create:Bool, watch:Bool, paced:Bool, columns:Int = 80, rows:Int = 24):TerminalInfo {
    var info:Null<TerminalInfo> = null, failure = "";
    link.client.call(WorkspaceTerminalProtocol.OPEN, {workspace: "workspace", instance: instance, id: id, create: create,
      columns: columns, rows: rows, watch: watch ? true : null, paced: paced ? true : null}, 5000,
      function(value) info = value, function(e) failure = e.code);
    until(function() return info != null || failure != "", "OPEN of " + id + " was not answered");
    if (failure != "") throw "OPEN of " + id + " failed: " + failure;
    var opened:TerminalInfo = info;
    return opened;
  }
  public function input(link:Link, id:String, sequence:Int, data:Bytes):Void {
    var done = false, failure = "";
    link.client.call(WorkspaceTerminalProtocol.INPUT, {workspace: "workspace", instance: instance, id: id, sequence: sequence, data: data},
      5000, function(_) done = true, function(e) failure = e.code);
    until(function() return done || failure != "", "INPUT to " + id + " was not answered");
    if (failure != "") throw "INPUT to " + id + " failed: " + failure;
  }
  /** A whole paged snapshot, read the way a view reads it. */
  public function snapshot(link:Link, id:String, history:Bool, limit:Null<Int>):{data:Bytes, history:Int, columns:Int, rows:Int} {
    var token = 0, offset = 0, total = -1, historyBytes = 0, columns = 0, rows = 0, data = Bytes.alloc(0);
    while (total < 0 || offset < total) {
      var waiting = true, failure = "";
      link.client.call(WorkspaceTerminalProtocol.SNAPSHOT, {workspace: "workspace", instance: instance, id: id, token: token,
        offset: offset, history: offset == 0 && history ? true : null, historyLimit: offset == 0 ? limit : null}, 5000,
        function(page) {
          if (total < 0) {
            total = page.total == null ? page.data.length : page.total;
            token = page.token == null ? 0 : page.token;
            historyBytes = page.history == null ? 0 : page.history;
            columns = page.terminal.columns; rows = page.terminal.rows;
            data = Bytes.alloc(total);
          }
          data.blit(offset, page.data, 0, page.data.length);
          offset += page.data.length;
          waiting = false;
        }, function(e) { failure = e.code; waiting = false; });
      until(function() return !waiting, "SNAPSHOT of " + id + " was not answered");
      if (failure != "") throw "SNAPSHOT of " + id + " failed: " + failure;
    }
    return {data: data, history: historyBytes, columns: columns, rows: rows};
  }
  /** The service's screen of terminal `id` shows `text`. */
  public function screenShows(link:Link, id:String, text:String):Bool {
    var shot = snapshot(link, id, false, null);
    var screen = Emulator.open(shot.columns, shot.rows, 8, "xterm-256color", false);
    screen.restoreScreenSnapshot(shot.data);
    screen.snapshot();
    var found = false;
    for (row in 0...screen.rows()) if (screen.rowText(row).indexOf(text) >= 0) found = true;
    screen.close();
    return found;
  }
  public function waitForScreen(link:Link, id:String, text:String, seconds:Float = 30):Void {
    var deadline = Sys.time() + seconds;
    while (!screenShows(link, id, text)) {
      if (Sys.time() > deadline) throw "The service's screen of " + id + " never showed " + text;
      pump(0.1);
    }
  }
  public function dispose():Void {
    for (s in sessions) s.close();
    sessions.resize(0);
    manager.dispose();
    for (l in links) l.close();
    links.resize(0);
  }
}

/**
  Flow control and history on the way to a view, against a real WorkspaceTerminalManager with real shells:
  paced CHANGED notifications under a flood, recent history on open, and re-attaching by replay.
**/
class TerminalFlowTests {
  /** A throw ends this program without its message (0xC0000409 on Windows): say what failed first. */
  static function require(value:Bool, message:String):Void { if (!value) { Sys.println("FAIL: " + message); throw message; } }
  static inline function windows():Bool return Sys.systemName() == "Windows";
  static function int(value:Int64):Int return Int64.toInt(value);

  static function screenText(session:TerminalSession):String {
    var e = session.emulator;
    e.snapshot();
    return [for (row in 0...e.rows()) e.rowText(row)].join("\n");
  }

  public static function run(root:String):Void {
    paced(root);
  }

  /** 10 s of 190 coloured cells per line, numbered, then FLOOD_DONE. */
  static function flood():Bytes {
    return TestShell.line(windows()
      ? "$e=[char]27; $l=-join (0..189 | % { $e+'[38;5;'+($_ % 200 + 16)+'m'+[char](65+$_ % 26) }); $w=[Diagnostics.Stopwatch]::StartNew(); $n=0; while($w.Elapsed.TotalSeconds -lt 10){ $b=[Text.StringBuilder]::new(); for($k=0;$k -lt 50;$k++){ $n++; [void]$b.Append($n.ToString('000000')).Append($l).Append(\"$e[0m`r`n\") }; [Console]::Out.Write($b.ToString()) }; 'FLOOD_'+'DONE'"
      : "end=$(( $(date +%s) + 10 )); while [ $(date +%s) -lt $end ]; do awk 'BEGIN{for(n=0;n<200;n++){for(i=0;i<190;i++)printf \"\\033[38;5;%dm%c\",i%200+16,65+i%26;printf \"\\033[0m\\n\"}}'; done; printf 'FLOOD_%s\\n' DONE");
  }

  /**
    1a: a paced watcher gets one CHANGED for a flood until it pulls (and the 5 s re-send), an unpaced one every change.
    1b: a real RpcTerminalBackend view attached during the flood stays attached and ends on the flood's last line.
  **/
  static function paced(root:String):Void {
    var rig = new Rig(root, "flow-paced", WorkspaceTerminalManager.REPLAY_BYTES);
    var pacedLink = rig.link(), plainLink = rig.link();
    var pacedChanges:Array<Float> = [], plainChanges:Array<Float> = [];
    pacedLink.client.onNotification(WorkspaceTerminalProtocol.CHANGED, WorkspaceTerminalProtocol.decodeChange,
      function(_) pacedChanges.push(Sys.time()));
    plainLink.client.onNotification(WorkspaceTerminalProtocol.CHANGED, WorkspaceTerminalProtocol.decodeChange,
      function(_) plainChanges.push(Sys.time()));
    var opened = rig.open(pacedLink, "flood", true, true, true, 200, 50);
    require(opened.paced == true, "The service did not answer a paced OPEN with paced");
    var plainOpened = rig.open(plainLink, "flood", false, true, false, 200, 50);
    require(plainOpened.paced == null, "The service called an unpaced view paced");
    // Acknowledge whatever the shell printed while starting, so the count starts with the flood.
    var pull = function():Void {
      var answered = false;
      pacedLink.client.call(WorkspaceTerminalProtocol.REPLAY, {workspace: "workspace", instance: rig.instance, id: "flood",
        cursor: Int64.ofInt(0)}, 5000, function(_) answered = true, function(_) answered = true);
      rig.until(function() return answered, "REPLAY of the paced view was not answered");
    };
    rig.pump(1.0);
    pull();
    var pacedBefore = pacedChanges.length, plainBefore = plainChanges.length;
    rig.input(pacedLink, "flood", 1, flood());
    rig.until(function() return pacedChanges.length > pacedBefore, "The paced view got no CHANGED for the flood");
    var first = pacedChanges[pacedBefore];
    // 1b: the view attaches while the shell floods.
    var endpoint = new FlowEndpoint(root, "flow-paced");
    var viewLink = rig.link();
    endpoint.connection = viewLink.client;
    var backend = new RpcTerminalBackend(function() return endpoint, "flood", root, false);
    var view = new TerminalSession(backend, Emulator.open(80, 24, 10000, "xterm-256color", false), false);
    rig.sessions.push(view);
    rig.pump(first + 4.0 - Sys.time());
    require(pacedChanges.length == pacedBefore + 1,
      "A paced view that did not pull got " + (pacedChanges.length - pacedBefore) + " CHANGED in 4 s of flood, not 1");
    require(plainChanges.length - plainBefore >= 10,
      "An unpaced view got " + (plainChanges.length - plainBefore) + " CHANGED in 4 s of flood");
    rig.until(function() return pacedChanges.length == pacedBefore + 2, "The paced view was not told again after 5 s", 6);
    var resent = pacedChanges[pacedBefore + 1] - first;
    require(resent >= 4.9 && resent < 8, "The paced view was told again after " + resent + " s, not 5 s");
    pull();
    rig.until(function() return pacedChanges.length == pacedBefore + 3, "The paced view got no CHANGED after it pulled", 3);
    rig.pump(1.0);
    require(pacedChanges.length == pacedBefore + 3, "A paced view got " + (pacedChanges.length - pacedBefore - 3)
      + " more CHANGED after the one its pull answered");
    // The view catches up with the end of the flood and is still attached.
    rig.until(function() return screenText(view).indexOf("FLOOD_DONE") >= 0, "The view never showed the end of the flood", 40);
    var end = rig.open(plainLink, "flood", false, false, false, 200, 50).end;
    require(int(end) > 4 * 1024 * 1024, "The flood printed only " + int(end) + " bytes");
    require(backend.isAttached() && backend.isAvailable() && viewLink.client.isOpen() && view.status == "running",
      "The view of the flood lost its attachment: " + backend.controlStatus());
    Sys.println("PASS: under " + Std.int(int(end) / 1048576) + " MiB of coloured output a paced view got 1 CHANGED per pull (re-sent after "
      + Math.round(resent * 10) / 10 + " s), an unpaced view " + (plainChanges.length - plainBefore)
      + "; a view attached during the flood stayed attached and shows its end");
    rig.dispose();
  }
}
