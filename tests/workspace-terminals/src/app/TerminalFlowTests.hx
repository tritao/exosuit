package app;

import testing.TestEndpoint;
import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcEnvelope;
import haxeon.rpc.RpcProtocol;
import workspace.client.RpcTerminalBackend;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;
import terminalsession.TerminalSession;
import terminalkit.Emulator;
import workspace.transport.RpcCalls;
import haxeon.rpc.RpcMethodKey;

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
      case Request(_, Id(method), _, payload):
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

/** A real WorkspaceTerminalManager with real shells, its client connections and the views polled with it. */
private class Rig {
  public final manager:WorkspaceTerminalManager;
  public final instance:String;
  public final links:Array<Link> = [];
  public final sessions:Array<TerminalSession> = [];
  public function new(root:String, instance:String, journal:Int) {
    this.instance = instance;
    manager = TestTerminals.manager("workspace", instance, root, journal);
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
    RpcCalls.call(link.client, WorkspaceTerminalProtocol.OPEN, {workspace: "workspace", instance: instance, id: id, create: create,
      columns: columns, rows: rows, watch: watch ? true : null, paced: paced ? true : null}, 5000,
      function(value) info = value, function(e) failure = e.code);
    until(function() return info != null || failure != "", "OPEN of " + id + " was not answered");
    if (failure != "") throw "OPEN of " + id + " failed: " + failure;
    var opened:TerminalInfo = info;
    return opened;
  }
  public function input(link:Link, id:String, sequence:Int, data:Bytes):Void {
    var done = false, failure = "";
    RpcCalls.call(link.client, WorkspaceTerminalProtocol.INPUT, {workspace: "workspace", instance: instance, id: id, sequence: sequence, data: data},
      5000, function(_) done = true, function(e) failure = e.code);
    until(function() return done || failure != "", "INPUT to " + id + " was not answered");
    if (failure != "") throw "INPUT to " + id + " failed: " + failure;
  }
  /** A whole paged snapshot, read the way a view reads it. */
  public function snapshot(link:Link, id:String, history:Bool, limit:Null<Int>):{data:Bytes, history:Int, columns:Int, rows:Int} {
    var token = 0, offset = 0, total = -1, historyBytes = 0, columns = 0, rows = 0, data = Bytes.alloc(0);
    while (total < 0 || offset < total) {
      var waiting = true, failure = "";
      RpcCalls.call(link.client, WorkspaceTerminalProtocol.SNAPSHOT, {workspace: "workspace", instance: instance, id: id, token: token,
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
  static function flowEndpoint(root:String, generation:String):TestEndpoint {
    var endpoint = new TestEndpoint();
    endpoint.root = root; endpoint.generation = generation; endpoint.epoch = generation;
    return endpoint;
  }
  /** A throw ends this program without its message (0xC0000409 on Windows): say what failed first. */
  static function require(value:Bool, message:String):Void { if (!value) { Sys.println("FAIL: " + message); throw message; } }
  static inline function windows():Bool return Sys.systemName() == "Windows";
  static function int(value:Int64):Int return Int64.toInt(value);

  /** Every line of an emulator, scrollback first, each with the text and style of its cells. */
  static function lines(e:Emulator):Array<String> {
    var out:Array<String> = [];
    var position = e.scrollback(-1).total;
    while (position > 0) {
      e.scrollback(position); e.snapshot();
      for (row in 0...(position < e.rows() ? position : e.rows())) out.push(describe(e, row));
      position -= e.rows();
    }
    e.scrollback(0); e.snapshot();
    for (row in 0...e.rows()) out.push(describe(e, row));
    return out;
  }
  static function describe(e:Emulator, row:Int):String {
    var text = new StringBuf();
    for (cell in e.rowCells(row)) { text.add(cell.text); text.add("\x01"); text.add(Std.string(cell.style)); text.add("\x02"); }
    return text.toString();
  }
  static function plain(line:String):String {
    var text = new StringBuf();
    for (cell in line.split("\x02")) { var at = cell.indexOf("\x01"); if (at >= 0) text.add(at == 0 ? " " : cell.substr(0, at)); }
    return text.toString();
  }
  /** The text of a view's scrollback and screen. */
  static function viewText(session:TerminalSession):String {
    var e = session.emulator, out:Array<String> = [];
    var position = e.scrollback(-1).total;
    while (position > 0) {
      e.scrollback(position); e.snapshot();
      for (row in 0...(position < e.rows() ? position : e.rows())) out.push(e.rowText(row));
      position -= e.rows();
    }
    e.scrollback(0);
    return out.join("\n") + "\n" + screenText(session);
  }
  static function screenText(session:TerminalSession):String {
    var e = session.emulator;
    e.snapshot();
    return [for (row in 0...e.rows()) e.rowText(row)].join("\n");
  }

  public static function run(root:String):Void {
    paced(root);
    recentHistory(root);
    reattach(root);
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
      RpcCalls.call(pacedLink.client, WorkspaceTerminalProtocol.REPLAY, {workspace: "workspace", instance: rig.instance, id: "flood",
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
    var endpoint = flowEndpoint(root, "flow-paced");
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

  /** 20000 numbered lines of red and green text, then HIST_DONE. */
  static function numbered():Bytes {
    return TestShell.line(windows()
      ? "$e=[char]27; $p=\" $e[31m\"+('r'*20)+\"$e[32m\"+('g'*20)+\"$e[0m end\"; $s=[Text.StringBuilder]::new(); for($i=1;$i -le 20000;$i++){[void]$s.Append('HIST_').Append($i.ToString('00000')).Append($p).Append(\"`r`n\")}; [Console]::Out.Write($s.ToString()); 'HIST_'+'DONE'"
      : "awk 'BEGIN{for(i=1;i<=20000;i++)printf \"HIST_%05d \\033[31mrrrrrrrrrrrrrrrrrrrr\\033[32mgggggggggggggggggggg\\033[0m end\\n\",i}'; printf 'HIST_%s\\n' DONE");
  }
  static function applied(shot:{data:Bytes, history:Int, columns:Int, rows:Int}):Emulator {
    // As TerminalSession applies a snapshot with history: the service's grid, the history, then the screen.
    var e = Emulator.open(shot.columns, shot.rows, 10000, "xterm-256color", false);
    e.feedRange(shot.data, 0, shot.history);
    e.takeReplies();
    e.restoreScreenSnapshot(shot.data.sub(shot.history, shot.data.length - shot.history));
    return e;
  }

  /** 2: SNAPSHOT with historyLimit sends the most recent rows only, cut at a row start; Emulator.recentHistory's cut. */
  static function recentHistory(root:String):Void {
    var rig = new Rig(root, "flow-history", WorkspaceTerminalManager.REPLAY_BYTES);
    var link = rig.link();
    rig.open(link, "history", true, false, false);
    rig.input(link, "history", 1, numbered());
    rig.waitForScreen(link, "history", "HIST_DONE");
    rig.pump(0.3);
    var whole = rig.snapshot(link, "history", true, null);
    var recent = rig.snapshot(link, "history", true, 65536);
    var prefix = Bytes.ofString("\x1b[3J\x1bc\x1b[?7l");
    require(whole.history > 256 * 1024, "The rendered history is only " + whole.history + " bytes");
    require(recent.history > 0 && recent.history <= 65536 && recent.data.length < whole.data.length / 4,
      "A 64 KiB history limit sent " + recent.history + " bytes of history (" + recent.data.length + " in all, " + whole.data.length + " without it)");
    require(recent.data.sub(0, prefix.length).compare(prefix) == 0 && recent.data.get(prefix.length) == 0x1b,
      "The recent history does not start with the export's reset and a row");
    var all = applied(whole), last = applied(recent);
    var allLines = lines(all), lastLines = lines(last);
    // The recent rows are the end of the whole history, cell for cell (text and colour), and the screens are the same.
    require(lastLines.length < allLines.length / 4, "The recent history holds " + lastLines.length + " of " + allLines.length + " lines");
    var suffix = allLines.slice(allLines.length - lastLines.length);
    for (i in 0...lastLines.length) require(lastLines[i] == suffix[i],
      "Line " + i + " of the recent history differs: [" + plain(lastLines[i]) + "] / [" + plain(suffix[i]) + "]");
    var ac = all.cursor(), lc = last.cursor();
    require(ac.row == lc.row && ac.column == lc.column, "The cursor differs after a limited history");
    var expected = "HIST_00000 " + [for (_ in 0...20) "r"].join("") + [for (_ in 0...20) "g"].join("") + " end";
    var top = StringTools.trim(plain(lastLines[0]));
    require(StringTools.startsWith(top, "HIST_") && top.length == expected.length && top.substr(10) == expected.substr(10),
      "The oldest recent row is torn: [" + top + "]");
    var text = [for (line in lastLines) plain(line)].join("\n");
    require(text.indexOf("HIST_20000 rrrr") >= 0 && text.indexOf("HIST_19900 rrrr") >= 0, "The last numbered lines are missing");
    all.close(); last.close();

    // Emulator.recentHistory on a real export: the cut follows CR LF and starts a row with ESC; the rest is the export's tail.
    var source = Emulator.open(80, 24, 1000, "xterm-256color", false);
    for (i in 0...300) source.feedString("\x1b[3" + (i % 7 + 1) + "mrow " + i + " coloured\x1b[0m plain\r\n");
    var exported = source.historySnapshot();
    var cut = Emulator.recentHistory(exported, 4096);
    require(cut != null && cut.length <= 4096 && cut.length > 2048 && cut.sub(0, prefix.length).compare(prefix) == 0,
      "recentHistory did not keep the recent rows of a real export");
    var kept:Bytes = cut;
    var at = exported.length - (kept.length - prefix.length);
    require(kept.get(prefix.length) == 0x1b && exported.get(at - 2) == 13 && exported.get(at - 1) == 10
      && kept.sub(prefix.length, kept.length - prefix.length).compare(exported.sub(at, exported.length - at)) == 0,
      "recentHistory did not cut at a row start");
    source.close();
    Sys.println("PASS: a 64 KiB history limit sent " + recent.history + " of " + whole.history
      + " history bytes, cut at a row start; the view gets the last " + lastLines.length + " lines intact and the same screen");
    rig.dispose();
  }

  /** 3: a phone view re-attaches by replay (no SNAPSHOT), keeps its content, and sends no transient size; a gap brings a bounded snapshot. */
  static function reattach(root:String):Void {
    var rig = new Rig(root, "flow-reattach", 65536);
    var phoneEndpoint = flowEndpoint(root, "flow-reattach"), deskEndpoint = flowEndpoint(root, "flow-reattach");
    var phoneLink = rig.link(), deskLink = rig.link();
    phoneEndpoint.connection = phoneLink.client;
    deskEndpoint.connection = deskLink.client;
    var phoneBackend = new RpcTerminalBackend(function() return phoneEndpoint, "reattach", root, true);
    phoneBackend.recentHistoryBytes = 256 * 1024;
    var phone = new TerminalSession(phoneBackend, Emulator.open(80, 24, 10000, "xterm-256color", false), false);
    rig.sessions.push(phone);
    rig.until(function() return phoneBackend.isSynchronized() && phoneBackend.canControl(), "The phone view did not open its terminal");
    var deskBackend = new RpcTerminalBackend(function() return deskEndpoint, "reattach", root, false);
    var desk = new TerminalSession(deskBackend, Emulator.open(80, 24, 10000, "xterm-256color", false), false);
    rig.sessions.push(desk);
    phone.write(TestShell.counted("OLD_", 30));
    rig.until(function() return viewText(phone).indexOf("OLD_029") >= 0 && viewText(desk).indexOf("OLD_029") >= 0,
      "The views did not show the first lines");
    require(phoneLink.counter.historyLimits.length == 1 && phoneLink.counter.historyLimits[0] == 256 * 1024,
      "The phone view's first snapshot did not ask for 256 KiB of history: " + phoneLink.counter.historyLimits);

    // Both views lose their connections; meanwhile another client makes the shell print more.
    var away = function(command:Bytes, marker:String):Void {
      phoneEndpoint.connection = null; deskEndpoint.connection = null;
      rig.drop(phoneLink); rig.drop(deskLink);
      rig.pump(0.1);
      var other = rig.link();
      rig.open(other, "reattach", false, false, false);
      rig.input(other, "reattach", 1, command);
      rig.waitForScreen(other, "reattach", marker);
      rig.drop(other);
    };
    away(TestShell.counted("NEW_", 20), "NEW_019");
    phoneLink = rig.link(); deskLink = rig.link();
    // The pane shows "Connecting…" while it re-attaches, a row less: the view asks for that grid before it caught up.
    phone.resize(80, 23);
    phoneEndpoint.connection = phoneLink.client;
    deskEndpoint.connection = deskLink.client;
    var resizedEarly = -1;
    rig.until(function() {
      if (!phoneBackend.isSynchronized()) return false;
      resizedEarly = phoneLink.counter.count(WorkspaceTerminalProtocol.RESIZE.id);
      // Caught up: the notice strip goes and the pane has its rows back.
      phone.resize(80, 24);
      return true;
    }, "The phone view did not re-attach");
    require(resizedEarly == 0, "The phone view resized the terminal before it caught up (" + resizedEarly + " RESIZE)");
    rig.until(function() return deskBackend.isSynchronized(), "The desktop view did not re-attach");
    rig.until(function() return viewText(phone).indexOf("NEW_019") >= 0 && viewText(desk).indexOf("NEW_019") >= 0,
      "The views did not show what was printed while they were away");
    rig.pump(0.5);
    require(phoneLink.counter.count(WorkspaceTerminalProtocol.SNAPSHOT.id) == 0,
      "The phone view took a snapshot to re-attach instead of replaying");
    require(phoneLink.counter.count(WorkspaceTerminalProtocol.REPLAY.id) > 0, "The phone view did not replay");
    require(viewText(phone).indexOf("OLD_000") >= 0, "The phone view lost its old content");
    require(deskLink.counter.count(WorkspaceTerminalProtocol.SNAPSHOT.id) > 0, "The desktop view re-attached without a snapshot");
    require(viewText(desk).indexOf("OLD_000") >= 0, "The desktop view lost the old lines");
    require(phoneLink.counter.count(WorkspaceTerminalProtocol.RESIZE.id) == 0, "The phone view sent a transient size after re-attaching");
    var probe = rig.link();
    var info = rig.open(probe, "reattach", false, false, false);
    require(info.rows == 24 && phone.emulator.rows() == 24, "The terminal has " + info.rows + " rows after the re-attach, not 24");
    rig.drop(probe);

    // 3b: more output than the journal holds while away: the phone view takes a snapshot bounded to its limit.
    away(TestShell.line(windows() ? "[Console]::Out.Write('x' * 150000); 'GAP_'+'DONE'"
      : "head -c 150000 /dev/zero | tr '\\000' x; printf 'GAP_%s\\n' DONE"), "GAP_DONE");
    phoneLink = rig.link(); deskLink = rig.link();
    phoneEndpoint.connection = phoneLink.client;
    deskEndpoint.connection = deskLink.client;
    rig.until(function() return phoneBackend.isSynchronized() && screenText(phone).indexOf("GAP_DONE") >= 0,
      "The phone view did not recover from a trimmed journal");
    require(phoneLink.counter.historyLimits.length == 1 && phoneLink.counter.historyLimits[0] == 256 * 1024,
      "The phone view's snapshot after a gap was not bounded: " + phoneLink.counter.historyLimits);
    probe = rig.link();
    var service = rig.snapshot(probe, "reattach", false, null);
    var screen = Emulator.open(service.columns, service.rows, 8, "xterm-256color", false);
    screen.restoreScreenSnapshot(service.data);
    screen.snapshot(); phone.emulator.snapshot();
    for (row in 0...screen.rows()) require(screen.rowText(row) == phone.emulator.rowText(row),
      "Row " + row + " of the phone view differs from the service's after a gap");
    screen.close();
    Sys.println("PASS: a phone view re-attaches by replay without a snapshot, keeps its content and never sends the "
      + "transient size; the desktop takes a snapshot; a trimmed journal brings a 256 KiB-bounded snapshot");
    rig.dispose();
  }
}
