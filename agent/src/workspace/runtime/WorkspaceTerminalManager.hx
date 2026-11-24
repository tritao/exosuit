package workspace.runtime;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.*;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.TerminalReplayLog;
import workspace.service.TerminalSnapshotPages;
import workspace.service.WorkspaceTerminals;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceProtocol;
import terminalsession.TerminalProfile;
import workspace.runtime.AgentTerminalResume;
import workspace.runtime.AgentTerminalIdentity;
import terminalkit.Emulator;

/** A view's SNAPSHOT that waits for the host's screen. */
private typedef WaitingSnapshot = {
  var connection:RpcConnection;
  var context:RpcContext<TerminalScreenSnapshot>;
  var token:Int;
  var history:Bool;
  var historyLimit:Int;
  var scope:String;
}

private class RuntimeTerminal {
  public final id:String;
  public final cwd:String;
  public var backend:Null<HostedPtyBackend>;
  public var columns:Int;
  public var rows:Int;
  public var state:String = "running";
  public var exitCode:Int = 0;
  /** The output and sizes since the host's last screen, for views reading on (REPLAY); one further behind takes a snapshot. */
  public final replay:TerminalReplayLog;
  /** Views waiting for the host's screen, and the history part of the screen being received. */
  public final waiting:Array<WaitingSnapshot> = [];
  public var history:Null<Bytes> = null;
  /** When a view last read it (see WorkspaceTerminalManager.unloadEnded). */
  public var used:Float = Sys.time();
  public var start(get, never):Int64;
  public var end(get, never):Int64;
  function get_start():Int64 return replay.startOffset;
  function get_end():Int64 return replay.endOffset;
  public function new(id:String, cwd:String, backend:Null<HostedPtyBackend>, columns:Int, rows:Int, journalBytes:Int) {
    this.id = id;
    this.cwd = cwd;
    this.backend = backend;
    this.columns = columns;
    this.rows = rows;
    replay = new TerminalReplayLog(columns, rows, journalBytes);
  }
}

/**
  The service's terminals: their catalog records, and a relay between views and the terminal hosts that own the
  programs (TerminalHosts). The host's emulator is a terminal's only screen: a view's SNAPSHOT is answered with the
  screen the host sends when asked, and the output in between is kept in a short journal views read on from (REPLAY).
  An ended terminal, or one whose host is gone, shows the last screen its host kept. Closing RPC clients never ends a
  terminal, and neither does this service stopping: the next service adopts the hosts.
**/
class WorkspaceTerminalManager implements WorkspaceTerminals {
  /**
    Raw output each terminal's replay journal keeps for views catching up between reads. A view further behind takes a
    snapshot from the host instead, so the journal only needs to cover a burst.
  **/
  public static inline final REPLAY_BYTES = 2 * 1024 * 1024;
  /** An ended terminal no view has read for this long gives up its journal; its last screen stays in its host's folder. */
  public static inline final UNLOAD_SECONDS = 30.0;
  /** UNLOAD_SECONDS; tests shorten it. */
  public var unloadSeconds:Float = UNLOAD_SECONDS;
  /**
    How often, and how many times, lost terminals are looked at again after the service starts or one is lost while it
    runs: a host that was slow to answer, or ran while no service did, is taken back. Later a view opening one does it.
  **/
  static inline final ADOPT_RETRY_SECONDS = 10.0;
  static inline final ADOPT_RETRIES = 6;
  /** Ended terminals whose runtime was let go, with the journal position a view of them may have reached. */
  final unloaded:Map<String, {cursor:Int64, offset:Int64}> = [];
  final workspace:String;
  final instance:String;
  final root:String;
  final terminals:Map<String, RuntimeTerminal> = [];
  final controllers:Map<String, RpcConnection> = [];
  /** Who holds each lease: the client process behind the connection, when it said so. */
  final controllerKeys:Map<String, String> = [];
  final watchers:Array<{connection:RpcConnection, id:String, stamp:String, paced:Bool, notified:Bool, notifiedAt:Float}> = [];
  /** A paced view that has not pulled this long after a CHANGED is told again (the notification may have been lost). */
  static inline final PACED_RENOTIFY_SECONDS = 5.0;
  final snapshotPages = new TerminalSnapshotPages();
  final journalBytes:Int;
  final catalog:Map<String, TerminalRecord> = [];
  final persistence:Null<WorkspaceTerminalPersistence>;
  final groups:Void -> Array<WorkspaceGroup>;
  final hosts:TerminalHosts;
  var storageFailed:Bool = false;
  /** The first look at lost terminals waits a while: the constructor just adopted what runs. */
  var nextAdoptCheck:Float = Sys.time() + ADOPT_RETRY_SECONDS;
  var adoptChecksLeft:Int = ADOPT_RETRIES;

  public function new(
    workspace:String,
    instance:String,
    root:String,
    hosts:TerminalHosts,
    journalBytes:Int = REPLAY_BYTES,
    ? persistence:WorkspaceTerminalPersistence,
    ? groups:Void -> Array<WorkspaceGroup>
  ) {
    this.hosts = hosts;
    this.workspace = workspace;
    this.instance = instance;
    this.root = root;
    if (hosts == null || workspace == null || workspace.length == 0
      || workspace.length > 128 || instance == null || instance.length == 0 || instance.length > 128
      || root == null || root.length == 0 || root.length > 1024) throw "Invalid terminal workspace identity";
    if (journalBytes < 65536 || journalBytes > 16777216) throw "Invalid terminal journal size";
    this.journalBytes = journalBytes;
    this.persistence = persistence;
    // Without a group source the workspace has no groups: terminals sit in the workspace root.
    this.groups = groups == null ? function() return [] : groups;
    var stored = persistence == null ?[] : persistence.loadTerminals();
    for (record in stored) {
      // The service's start folder is the workspace's root for its terminals; a record keeps the one it was made under.
      record.workspaceRoot = root;
      if (!validRecord(record) || catalog.exists(record.id)) {
        ServiceLog.note('terminal record skipped, it is not valid: ${record == null ? "null" : record.id}');
        continue;
      }
      record.available = false;
      catalog.set(record.id, record);
      // A terminal whose host kept running while no service did: this generation takes it over.
      if (record.state == "running" || record.state == "starting" || record.state == "lost") adoptRecord(record);
    }
    // No host may be left running unseen: one whose terminal has no record is logged (exohost lists it; the user ends it).
    if (persistence != null) try hosts.sweep([for (id in catalog.keys()) id]) catch (_:Dynamic) {}
  }

  /**
    Takes over the running host of `record`'s terminal: the host sends its screen when the connection opens. With no
    host running the record says what is left: the program's exit from its last screen, or lost.
  **/
  function adoptRecord(record:TerminalRecord):Null<RuntimeTerminal> {
    var kept = hosts.adopt(record.id);
    if (kept != null) {
      ServiceLog.note('terminal kept by its host: "${record.name}" (${record.id}), from service generation ${record.instance}');
      var t = terminals.get(record.id);
      if (t == null) {
        t = new RuntimeTerminal(record.id, record.cwd, kept, 80, 24, journalBytes);
        var reached = unloaded.get(record.id);
        if (reached != null) t.replay.continueFrom(reached.cursor, reached.offset);
        unloaded.remove(record.id);
        terminals.set(record.id, t);
      } else t.backend = kept;
      t.state = "running";
      t.exitCode = 0;
      updateRecord(record, "running", 0, true);
      return t;
    }
    var last = hosts.lastScreen(record.id);
    if (last != null && last.exited) {
      if (record.state != "exited") ServiceLog.note('terminal "${record.name}" (${record.id}) ended while no service ran, exit code ${last.exitCode}');
      updateRecord(record, "exited", last.exitCode, false);
    } else if (record.state != "lost") {
      ServiceLog.note('terminal lost: "${record.name}" (${record.id}) was running in service generation ${record.instance}, and its host is gone');
      updateRecord(record, "lost", record.exitCode, false);
    }
    return null;
  }

  function updateRecord(record:TerminalRecord, state:String, exitCode:Int, adopted:Bool):Void {
    if (record.state == state && record.exitCode == exitCode && (!adopted || record.instance == instance)) return;
    var updated = copy(record);
    updated.state = state;
    updated.exitCode = exitCode;
    if (adopted) updated.instance = instance;
    updated.revision += 1;
    try save(updated) catch (_:Dynamic) {}
  }

  function knownGroup(id:String):Bool return WorkspaceProtocol.knownGroup(id, groups());
  function validName(name:String):Bool return name != null && StringTools.trim(name).length > 0
    && name.length <= 128 && name.indexOf("\t") < 0 && name.indexOf("\n") < 0 && name.indexOf("\r") < 0;
  static function validTheme(theme:Null<TerminalTheme>):Bool return theme == null
    || theme.foreground >= 0 && theme.foreground <= 0xffffff && theme.background >= 0 && theme.background <= 0xffffff;
  static function applyTheme(t:RuntimeTerminal, theme:Null<TerminalTheme>):Void {
    if (theme != null && t.state == "running" && t.backend != null) t.backend.theme(theme.foreground, theme.background);
  }
  static function validAgentProvider(provider:Null<String>):Bool return provider == null || ["codex", "claude", "pi"].indexOf(provider) >= 0;
  static function profile(record:TerminalRecord, launch:Null<AgentTerminalLaunch>):TerminalProfile return record.agentProvider == null
    ? TerminalProfile.shell(record.cwd) : TerminalProfile.agent(record.agentProvider, record.cwd, launch == null ? null : launch.arguments);
  /** How a provider terminal starts (which conversation it resumes); null for a shell. Records the choice in `record`. */
  function agentLaunch(record:TerminalRecord, restart:Bool):Null<AgentTerminalLaunch> {
    if (record.agentProvider == null) return null;
    var launch = AgentTerminalResume.plan(record, restart, AgentTerminalIdentity.folder(hosts.stateDirectory, record.id));
    record.agentSession = launch.session;
    return launch;
  }
  /** Starts the terminal's program in a host of its own; `prelude` is what its screen shows before the program starts. */
  function spawnBackend(record:TerminalRecord, columns:Int, rows:Int, agent:Null<AgentTerminalLaunch>, ?prelude:Bytes):HostedPtyBackend
    return hosts.spawn(record.id, profile(record, agent), columns, rows, record.name, prelude);
  function validRecord(r:TerminalRecord):Bool return r != null && validAgentProvider(r.agentProvider) && r.id != null && r.id.length > 0
    && r.id.length <= 128 && validName(r.name) && knownGroup(r.group) && WorkspaceProtocol.validOrder(r.order) && r.cwd != null && r.cwd.length > 0 && r.cwd.length <= 1024 && r.instance != null
    && r.instance.length > 0 && r.instance.length <= 128 && r.revision > 0 && r.revision < Int64.make(
      0x7fffffff,
      0xffffffff
    ) &&[
      "starting",
      "running",
      "exited",
      "failed",
      "lost"
    ].indexOf(r.state) >= 0;
  /**
    A new terminal's place: after the terminals and groups already placed in `group`, so the tree lists it where it
    was made (a terminal with no place sorts by its id, a hash, among the others).
  **/
  function nextOrder(group:String, groupList:Array<WorkspaceGroup>):Int {
    var last = -1;
    for (record in catalog) if (record.group == group && record.order != null && record.order > last) last = record.order;
    for (g in groupList) if ((WorkspaceProtocol.isRoot(group) ? WorkspaceProtocol.isRoot(g.parent) : g.parent == group)
      && g.order != null && g.order > last) last = g.order;
    return last < 0 ? 0 : Std.int(Math.min(WorkspaceProtocol.MAX_ORDER, last + 1024));
  }
  function nextTerminalName():String {
    var used:Map<String, Bool> = [];
    for (record in catalog) used.set(record.name, true);
    var number = 1;
    while (used.exists("Terminal " + number)) number++;
    return "Terminal " + number;
  }

  function copy(r:TerminalRecord):TerminalRecord return {
    id: r.id,
    name: r.name,
    group: r.group,
    cwd: r.cwd,
    instance: r.instance,
    state: r.state,
    exitCode: r.exitCode,
    // Every retained record can open a read-only view of its last screen. Opening must never spawn a replacement.
    available: true,
    revision: r.revision,
    workspaceRoot: root,
    agentProvider: r.agentProvider,
    order: r.order,
    agentSession: r.agentSession
  };
  function save(r:TerminalRecord):Void {
    if (storageFailed) throw "Terminal metadata storage unavailable";
    r.available = false;
    try {
      if (persistence != null) persistence.saveTerminal(r);
    } catch (e:Dynamic) {
      storageFailed = true;
      throw e;
    }
    catalog.set(r.id, r);
  }
  /**
    The terminal's runtime: the one this service holds, else one made for a recorded terminal (an ended one let go, or
    one lost). A lost terminal whose host runs is taken back here, when a view opens it.
  **/
  function loaded(id:String):Null<RuntimeTerminal> {
    var t = terminals.get(id);
    if (t != null) return t;
    var found = catalog.get(id);
    if (found == null) return null;
    if (found.state == "lost" || found.state == "running" || found.state == "starting") {
      t = adoptRecord(found);
      if (t != null) return t;
    }
    // adoptRecord may have replaced the record (an exit read from the last screen).
    var record:TerminalRecord = catalog.get(id);
    var last = hosts.lastScreen(id);
    t = new RuntimeTerminal(id, record.cwd, null, last == null ? 80 : last.columns, last == null ? 24 : last.rows, journalBytes);
    var reached = unloaded.get(id);
    if (reached != null) t.replay.continueFrom(reached.cursor, reached.offset);
    unloaded.remove(id);
    t.state = record.state;
    t.exitCode = record.exitCode;
    terminals.set(id, t);
    return t;
  }
  /** Lets go of the journal of every ended terminal that no view read for UNLOAD_SECONDS. */
  function unloadEnded(now:Float):Void {
    for (id in [for (id in terminals.keys()) id]) {
      var t = terminals.get(id);
      if (t.state == "running" || t.state == "starting" || !catalog.exists(id) || t.waiting.length > 0
          || now - t.used < unloadSeconds || snapshotPages.holds(id)) continue;
      unloaded.set(id, {cursor: t.replay.endCursor, offset: t.replay.endOffset});
      if (t.backend != null) { t.backend.close(); t.backend = null; }
      terminals.remove(id);
    }
  }
  /**
    Looks again at the lost terminals every ADOPT_RETRY_SECONDS, ADOPT_RETRIES times: one whose host runs (it was slow
    to answer, or this service lost its connection) is taken back, as a view opening it would.
  **/
  function readopt(now:Float):Void {
    if (adoptChecksLeft <= 0 || now < nextAdoptCheck) return;
    adoptChecksLeft--;
    nextAdoptCheck = now + ADOPT_RETRY_SECONDS;
    for (record in [for (r in catalog) if (r.state == "lost") r]) if (hosts.hostRuns(record.id)) adoptRecord(record);
  }

  public function snapshot():TerminalCatalog {
    var records = [for (r in catalog) copy(r)];
    records.sort(function(a, b) return Reflect.compare(a.id, b.id));
    return {instance: instance, groups: groups(), terminals: records, next: null, workspaceRoot: root, agentProviders:["codex","claude","pi"]};
  }
  function controller(id:String):Null<RpcConnection> {
    var owner = controllers.get(id);
    if (owner != null && !owner.isOpen()) {
      clearController(id);
      return null;
    }
    return owner;
  }
  function setController(id:String, connection:RpcConnection, key:Null<String>):Void {
    controllers.set(id, connection);
    if (key == null) controllerKeys.remove(id); else controllerKeys.set(id, key);
  }
  function clearController(id:String):Void {
    controllers.remove(id);
    controllerKeys.remove(id);
  }
  /** A client process is named by its scope (local or remote peer) and the key it sends; no key means unknown. */
  static function clientKey(scope:String, key:Null<String>):Null<String>
    return key == null || key == "" || key.length > 128 ? null : scope + "/" + key;
  /** The lease is held by another connection of the same client process: a replaced or leaked attachment. */
  function sameClient(id:String, key:Null<String>):Bool
    return key != null && controllerKeys.get(id) == key;
  function info(t:RuntimeTerminal, viewer:RpcConnection):TerminalInfo {
    var owner = controller(t.id);
    var record = catalog.get(t.id);
    return {
    id: t.id,
    name: record == null ? null : record.name,
    cwd: t.cwd,
    state: t.state,
    exitCode: t.exitCode,
    columns: t.columns,
    rows: t.rows,
    start: t.start,
    end: t.end,
    controller: owner == viewer,
    notifications: true,
    restartable: true,
    historyAvailable: t.state == "running" || hosts.hasLastScreen(t.id),
    agentProvider: record == null ? null : record.agentProvider,
    controlled: owner != null
    };
  }
  function error(code:String):RpcError return new RpcError(code, code, false);
  function valid(workspace:String, instance:String, id:String):Bool return workspace == this.workspace
    && instance == this.instance && id != null && id.length > 0 && id.length <= 128;
  function size(columns:Int, rows:Int):Bool return columns >= 1 && columns <= 512 && rows >= 1 && rows <= 256;

  /** Answers `request` with `history` and `screen`, the terminal as it is at the end of its journal. */
  function answerSnapshot(t:RuntimeTerminal, request:WaitingSnapshot, history:Bytes, screen:Bytes):Void {
    if (!request.connection.isOpen()) return;
    var data = screen, historyBytes = 0;
    if (request.token == 0 && request.history && history.length > 0) {
      // A view on a slow link asks for the recent rows only (TerminalSnapshotQuery.historyLimit).
      var part = request.historyLimit > 0 ? Emulator.recentHistory(history, request.historyLimit) : history;
      if (part == null) part = Bytes.alloc(0);
      data = Bytes.alloc(part.length + screen.length);
      data.blit(0, part, 0, part.length);
      data.blit(part.length, screen, 0, screen.length);
      historyBytes = part.length;
    }
    var current = info(t, request.connection);
    // Older clients ask for the whole snapshot in one reply, which a large grid's does not fit.
    try request.context.respond(request.token < 0 ? {terminal: current, data: data, cursor: t.replay.endCursor}
      : snapshotPages.start(request.connection, t.id, data, current, t.replay.endCursor, Sys.time(), historyBytes,
        request.scope == "local" ? TerminalSnapshotPages.LOCAL_PAGE_BYTES : TerminalSnapshotPages.PAGE_BYTES))
    catch (failure:Dynamic) {
      ServiceLog.note('terminal ${t.id}: a screen could not be sent to a view (${Std.string(failure)})');
      request.context.fail(error("snapshot_unavailable"));
    }
  }

  /**
    What a restarted terminal's new host shows before its program starts: the earlier program's history and last
    screen, both in scrollback, then `note` in scrollback too. The old screen moves into scrollback before a fresh
    shell's startup code can clear it, and so does the note: a Windows ConPTY starts by clearing the visible page, which
    would erase a note left on it. The new program gets a blank page.
  **/
  static function restartPrelude(last:Null<TerminalHostProtocol.TerminalScreen>, columns:Int, rows:Int, note:String):Bytes {
    var boundary = new StringBuf();
    boundary.add('\033[${rows};1H');
    for (_ in 0...rows) boundary.add("\r\n");
    boundary.add("\033[H" + note);
    boundary.add('\033[${rows};1H\r\n\033[H');
    var separator = Bytes.ofString(boundary.toString());
    if (last == null || last.screen.length == 0) return separator;
    var emulator = Emulator.open(last.columns, last.rows, TerminalHostProtocol.SCROLLBACK_ROWS, "xterm-256color", false);
    try {
      // As a view applies a snapshot: the history, then the exact screen.
      emulator.feed(last.history);
      emulator.takeReplies();
      emulator.restoreScreenSnapshot(last.screen);
      if (emulator.columns() != columns || emulator.rows() != rows) emulator.resize(columns, rows);
      emulator.feed(separator);
      emulator.takeReplies();
      var prelude = emulator.historySnapshot();
      emulator.close();
      return prelude;
    } catch (failure:Dynamic) {
      emulator.close();
      ServiceLog.note('the last screen could not be carried into the restarted terminal: ${Std.string(failure)}');
      return separator;
    }
  }

  /**
    Answers a view's snapshot of a terminal no host shows: from the last screen its host kept, or a blank screen of its
    size when none was kept.
  **/
  function answerFromLastScreen(t:RuntimeTerminal, request:WaitingSnapshot):Void {
    var last = hosts.lastScreen(t.id);
    if (last != null && last.screen.length > 0) {
      answerSnapshot(t, request, last.history, last.screen);
      return;
    }
    try {
      var blank = Emulator.open(t.columns, t.rows, 0, "xterm-256color", false);
      var screen = blank.screenSnapshot();
      blank.close();
      answerSnapshot(t, request, Bytes.alloc(0), screen);
    } catch (failure:Dynamic) {
      ServiceLog.note('terminal ${t.id}: no screen could be made for a view (${Std.string(failure)})');
      request.context.fail(error("snapshot_unavailable"));
    }
  }

  /** Answers the views waiting for a terminal whose host will not send its screen any more. */
  function answerWaiting(t:RuntimeTerminal):Void {
    var waiting = t.waiting.copy();
    t.waiting.resize(0);
    t.history = null;
    for (request in waiting) answerFromLastScreen(t, request);
  }

  public function bind(connection:RpcConnection, capabilities:Array<String>, ?scope:String):Void {
    if (scope == null) scope = "";
    var read = capabilities.indexOf(WorkspaceTerminalProtocol.READ) >= 0;
    var control = capabilities.indexOf(WorkspaceTerminalProtocol.CONTROL) >= 0;
    var catalogGrant = capabilities.indexOf(WorkspaceTerminalProtocol.CATALOG) >= 0;
    connection.register(WorkspaceTerminalProtocol.LIST, function(r, c) {
      if (!read || !catalogGrant) {
        c.fail(error("unauthorized"));
        return;
      }
      if (r.workspace != workspace || r.instance != instance) {
        c.fail(error("invalid_request"));
        return;
      }
      if (storageFailed) {
        c.fail(error("storage_unavailable"));
        return;
      }
      if (r.after != null && r.after.length > 128) {
        c.fail(error("invalid_request"));
        return;
      }
      var ids = [for (id in catalog.keys()) id];
      ids.sort(Reflect.compare);
      var records:Array<TerminalRecord> = [];
      var more = false;
      for (id in ids) if (r.after == null || Reflect.compare(id, r.after) > 0) {
        if (records.length == WorkspaceTerminalProtocol.CATALOG_PAGE_LIMIT) {
          more = true;
          break;
        }
        records.push(copy(catalog.get(id)));
      }
      c.respond({
        instance: instance,
        groups: groups(),
        terminals: records,
        next: more ? records[records.length - 1].id : null,
        workspaceRoot: root,
        agentProviders: ["codex","claude","pi"]
      }
      );
    }
    );
    connection.register(WorkspaceTerminalProtocol.RENAME, function(r, c) {
      if (!control || !catalogGrant) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id) || !validName(r.name) || !knownGroup(r.group) || !WorkspaceProtocol.validOrder(r.order)) {
        c.fail(error("invalid_request"));
        return;
      }
      var old = catalog.get(r.id);
      if (old == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (old.revision != r.expectedRevision || old.revision >= Int64.make(0x7fffffff, 0xfffffffe)) {
        c.fail(error("stale_revision"));
        return;
      }
      var updated = copy(old);
      updated.name = StringTools.trim(r.name);
      updated.group = r.group;
      if (r.order != null) updated.order = r.order;
      updated.revision += 1;
      try {
        save(updated);
        c.respond(copy(updated));
      } catch (_:Dynamic) {
        c.fail(new RpcError("storage_failed", "Terminal metadata requires recovery", true)
        );
      }
    }
    );
    connection.register(WorkspaceTerminalProtocol.FORGET, function(r, c) {
      if (!control || !catalogGrant) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id)) {
        c.fail(error("invalid_request"));
        return;
      }
      var existing = catalog.get(r.id);
      if (existing != null &&(existing.instance != r.resourceInstance || existing.revision != r.expectedRevision)) {
        c.fail(error("stale_revision"));
        return;
      }
      var t = terminals.get(r.id);
      if (t != null && t.state == "running" && r.terminate != true) {
        c.fail(error("terminal_running"));
        return;
      }
      try {
        if (storageFailed) throw "Terminal metadata storage unavailable";
        var attached = false;
        var runtime = t;
        if (runtime != null) {
          var backend = runtime.backend;
          if (backend != null) {
            attached = runtime.state == "running";
            if (attached) {
              ServiceLog.note('terminal closed by a client while running: ${r.id}');
              backend.kill();
            }
            backend.close();
            runtime.backend = null;
            runtime.state = "exited";
          }
        }
        if (persistence != null) persistence.removeTerminal(r.id);
        catalog.remove(r.id);
        unloaded.remove(r.id);
        // The record is gone, so must its host be, also one this service is not attached to (lost, or not answered yet).
        if (!attached) hosts.end(r.id, "the terminal was removed");
        hosts.forget(r.id);
        AgentTerminalIdentity.remove(AgentTerminalIdentity.folder(hosts.stateDirectory, r.id));
      } catch (_:Dynamic) {
        storageFailed = true;
        c.fail(new RpcError("storage_failed", "Terminal metadata requires recovery", true)
        );
        return;
      }
      if (t != null) {
        for (request in t.waiting) request.context.fail(error("unknown_terminal"));
        terminals.remove(r.id);
      }
      clearController(r.id);
      notifyChanges();
      c.respond({workspace: r.workspace, instance: r.instance, id: r.id}
      );
    }
    );
    // Input sequence is per authenticated connection, never a persisted global client counter.
    var inputSequence:Map<String, Int> = [];
    connection.register(WorkspaceTerminalProtocol.UNWATCH, function(r, c) {
      if (!read) { c.fail(error("unauthorized")); return; }
      if (!valid(r.workspace, r.instance, r.id)) { c.fail(error("invalid_request")); return; }
      for (watch in watchers.copy())
        if (watch.connection == connection && watch.id == r.id) watchers.remove(watch);
      c.respond(r);
    });
    connection.register(WorkspaceTerminalProtocol.OPEN, function(r, c) {
      if (!read ||(r.create && !control)) {
        c.fail(error("unauthorized"));
        return;
      }
      if ((r.group != null || r.directory != null) && capabilities.indexOf(WorkspaceProtocol.TREE) < 0) { c.fail(error("unsupported")); return; }
      if (!valid(r.workspace, r.instance, r.id) || !size(r.columns, r.rows) || !validTheme(r.theme) || !validAgentProvider(r.agentProvider)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = r.create ? terminals.get(r.id) : loaded(r.id);
      // The last screen of a failed start that a view loaded does not answer its Retry.
      if (r.create && t != null && t.state == "failed" && t.backend == null) {
        terminals.remove(r.id);
        t = null;
      }
      if (t == null) {
        if (!r.create) {
          c.fail(error("unknown_terminal"));
          return;
        }
        // A terminal whose start failed is started again from its record (the view's Retry); any other is not made twice.
        var failedStart = catalog.get(r.id);
        if (failedStart != null && failedStart.state != "failed") {
          c.fail(error("terminal_unavailable"));
          return;
        }
        if (storageFailed) {
          c.fail(error("storage_unavailable"));
          return;
        }
        var record:TerminalRecord;
        if (failedStart != null) {
          record = copy(failedStart);
          record.instance = instance;
          record.state = "starting";
          record.revision += 1;
        } else {
          if ([for (_ in catalog) 1].length >= 256) {
            c.fail(error("catalog_limit"));
            return;
          }
          var groupList = groups();
          // Without a group the terminal goes to the workspace root.
          var selectedGroup = r.group != null ? r.group : WorkspaceProtocol.ROOT_GROUP;
          if (!knownGroup(selectedGroup)) { c.fail(error("unknown_group")); return; }
          // The explicit directory, else the group's or nearest ancestor's folder, else the root (ADR 0006).
          var chosen = new WorkspaceDirectories(root).forSession(groupList, selectedGroup, r.directory);
          if (chosen.path == null) { c.fail(new RpcError("invalid_directory", chosen.error, false)); return; }
          record = {
            id: r.id,
            name: r.agentProvider == null ? nextTerminalName() : (r.agentProvider == "claude" ? "Claude Code" : r.agentProvider == "codex" ? "Codex" : "Pi") + " · Terminal",
            group: selectedGroup,
            cwd : chosen.path,
            workspaceRoot: root,
            instance : instance,
            state : "starting",
            exitCode : 0,
            available : false,
            revision : 1,
            agentProvider: r.agentProvider,
            order: nextOrder(selectedGroup, groupList)
          };
        }
        var agent:Null<AgentTerminalLaunch> = null;
        try agent = agentLaunch(record, false) catch (_:Dynamic) {}
        try {
          save(record);
        } catch (_:Dynamic) {
          c.fail(new RpcError("storage_failed", "Terminal creation requires recovery", true)
          );
          return;
        }
        var created:RuntimeTerminal;
        try {
          created = new RuntimeTerminal(r.id, record.cwd, spawnBackend(record, r.columns, r.rows, agent), r.columns, r.rows, journalBytes);
        } catch (cause:Dynamic) {
          ServiceLog.note('terminal host could not start for ${r.id}: ${Std.string(cause)}');
          var failed = copy(record);
          failed.state = "failed";
          failed.revision += 1;
          try save(failed) catch (_:Dynamic) {
          }
          c.fail(new RpcError(storageFailed ? "storage_failed" : "terminal_spawn_failed", "Terminal creation failed: " + Std.string(cause), storageFailed)
          );
          return;
        }
        var running = copy(record);
        running.state = "running";
        running.revision += 1;
        try save(running) catch (_:Dynamic) {
          created.backend.kill();
          created.backend.close();
          c.fail(new RpcError("storage_failed", "Terminal creation requires recovery", true)
          );
          return;
        }
        t = created;
        terminals.set(r.id, created);
        ServiceLog.note('terminal started: "${running.name}" (${r.id})');
      }
      t.used = Sys.time();
      var openKey = clientKey(scope, r.clientKey);
      if (control && t.state == "running" && (controller(r.id) == null || controller(r.id) == connection || sameClient(r.id, openKey))) { setController(r.id, connection, openKey); inputSequence.remove(r.id); }
      var openingTheme:Null<TerminalTheme> = r.theme;
      if (openingTheme != null && controller(r.id) == connection)
        applyTheme(t, openingTheme);
      var paced = r.watch == true && r.paced == true;
      if (r.watch == true) {
        var watch = Lambda.find(watchers, function(w) return w.connection == connection && w.id == r.id);
        if (watch == null) watchers.push({connection:connection, id:r.id, stamp:changeStamp(t, connection), paced:paced, notified:false, notifiedAt:0.0});
        else { watch.stamp = changeStamp(t, connection); watch.paced = paced; watch.notified = false; }
      }
      var opened = info(t, connection);
      // Only a watching view that asked is paced; the answer tells it the service keeps its side.
      if (paced) opened.paced = true;
      c.respond(opened);
    }
    );
    connection.register(WorkspaceTerminalProtocol.REPLAY, function(r, c) {
      if (!read) { c.fail(error("unauthorized")); return; }
      if (!valid(r.workspace, r.instance, r.id)) { c.fail(error("invalid_request")); return; }
      var t = terminals.get(r.id);
      // An ended terminal whose runtime was let go (unloadEnded): the view takes a snapshot, which loads it again.
      if (t == null && unloaded.exists(r.id) && catalog.exists(r.id)) { c.fail(error("replay_gap")); return; }
      if (t == null) { c.fail(error("unknown_terminal")); return; }
      t.used = Sys.time();
      acknowledge(connection, r.id);
      if (r.cursor < t.replay.startCursor) { c.fail(error("replay_gap")); return; }
      if (r.cursor < 0 || r.cursor > t.replay.endCursor) { c.fail(error("invalid_offset")); return; }
      var batch = t.replay.read(r.cursor);
      c.respond({terminal:info(t, connection), events:batch.events, next:batch.next, end:t.replay.endCursor});
    });
    connection.register(WorkspaceTerminalProtocol.SNAPSHOT, function(r, c) {
      if (!read) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = loaded(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      t.used = Sys.time();
      acknowledge(connection, r.id);
      var token:Int = r.token == null ? -1 : r.token;
      if (token > 0) {
        var page = snapshotPages.next(connection, t.id, token, r.offset == null ? 0 : r.offset, Sys.time());
        if (page == null) c.fail(error("snapshot_expired"));
        else c.respond(page);
        return;
      }
      var request:WaitingSnapshot = {connection: connection, context: c, token: token, history: r.history == true,
        historyLimit: r.historyLimit == null ? 0 : r.historyLimit, scope: scope};
      var backend = t.backend;
      if (t.state != "running" || backend == null) {
        answerFromLastScreen(t, request);
        return;
      }
      // The host's screen, in order with its output: answered when it arrives (poll).
      t.waiting.push(request);
      backend.requestSnapshot();
    });
    connection.register(WorkspaceTerminalProtocol.SET_CONTROL, function(r, c) {
      if (!read || !control) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = loaded(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (t.state != "running") { c.respond(info(t, connection)); return; }
      var owner = controller(r.id);
      if (r.claim) {
        var claimKey = clientKey(scope, r.clientKey);
        if (owner == null || owner == connection || r.takeover || sameClient(r.id, claimKey)) { setController(r.id, connection, claimKey); inputSequence.remove(r.id); }
      } else if (owner == connection) {
        clearController(r.id);
      }
      c.respond(info(t, connection));
    }
    );
    connection.register(WorkspaceTerminalProtocol.INPUT, function(r, c) {
      if (!control) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id) || r.data == null || r.data.length > 65536 || r.sequence < 1) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = terminals.get(r.id);
      if (t == null || t.state != "running" || t.backend == null) {
        c.fail(error("terminal_not_running"));
        return;
      }
      if (controller(r.id) != connection) {
        c.fail(error("terminal_controlled"));
        return;
      }
      var previous = inputSequence.get(r.id);
      // Numbering starts again whenever control is given (setController): a client numbers its input per view, and a
      // new view, a reconnect or a restarted terminal starts its own count. After the first input, each must follow on.
      if (previous != null && r.sequence != previous + 1) {
        c.fail(error("input_sequence"));
        return;
      }
      // Reserve before writing: an exception can have delivered a prefix. Never repeat input.
      inputSequence.set(r.id, r.sequence);
      try {
        t.backend.write(r.data);
        c.respond(info(t, connection));
      } catch (_:Dynamic) {
        c.fail(new RpcError("input_failed", "Input delivery is uncertain", true)
        );
      }
    }
    );
    connection.register(WorkspaceTerminalProtocol.RESIZE, function(r, c) {
      if (!control) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id) || !size(r.columns, r.rows) || !validTheme(r.theme)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = terminals.get(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (controller(r.id) != connection) {
        c.fail(error("terminal_controlled"));
        return;
      }
      try {
        var resizedTheme:Null<TerminalTheme> = r.theme;
        applyTheme(t, resizedTheme);
        if (t.columns != r.columns || t.rows != r.rows) {
          if (t.state == "running" && t.backend != null) t.backend.resize(r.columns, r.rows);
          t.replay.geometry(r.columns, r.rows);
          t.columns = r.columns;
          t.rows = r.rows;
        }
        c.respond(info(t, connection));
      } catch (_:Dynamic) {
        c.fail(error("resize_failed"));
      }
    }
    );
    connection.register(WorkspaceTerminalProtocol.TERMINATE, function(r, c) {
      if (!control) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = loaded(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (t.state == "running" && t.backend != null) {
        ServiceLog.note('terminal asked to end by a client: ${r.id}');
        t.backend.kill();
      }
      c.respond(info(t, connection));
    }
    );
    connection.register(WorkspaceTerminalProtocol.RESTART, function(r, c) {
      if (!read || !control) { c.fail(error("unauthorized")); return; }
      if (!valid(r.workspace, r.instance, r.id) || !validTheme(r.theme)) { c.fail(error("invalid_request")); return; }
      var record = catalog.get(r.id);
      if (record == null) { c.fail(error("unknown_terminal")); return; }
      var t = terminals.get(r.id);
      if (record.state == "running" || record.state == "starting" || t != null && t.state == "running") {
        c.fail(error("terminal_running")); return;
      }
      if (storageFailed) { c.fail(error("storage_unavailable")); return; }
      // The host of a program that ended may not have gone yet; it keeps nothing but the last screen it wrote.
      if (record.state == "exited" || t != null && t.state == "exited") hosts.endExited(r.id);
      // A host that still runs keeps its program: the terminal is taken back, never restarted over it.
      if (hosts.hostRuns(r.id)) {
        var kept = adoptRecord(record);
        if (kept == null) { c.fail(error("terminal_running")); return; }
        ServiceLog.note('terminal ${r.id}: Restart found its host running; the terminal was taken back instead');
        { setController(r.id, connection, null); inputSequence.remove(r.id); }
        c.respond(info(kept, connection));
        return;
      }
      try {
        if (t == null) t = loaded(r.id);
        if (t == null) throw "Unknown terminal";
        var starting = copy(record);
        var agent = agentLaunch(starting, true);
        var prelude = restartPrelude(hosts.lastScreen(r.id), t.columns, t.rows,
          agent == null ? "── Shell restarted ──" : agent.note);
        starting.instance = instance; starting.state = "starting"; starting.exitCode = 0; starting.revision += 1;
        save(starting);
        if (t.backend != null) t.backend.close();
        t.backend = spawnBackend(starting, t.columns, t.rows, agent, prelude);
        // Views take the new host's screen: it starts from the prelude (which begins with a reset), and holds what the new
        // program writes before this service is attached to the host, which no output event carries. The journal skips one
        // so every view, also one that had read all of the ended program's output, finds a gap and asks for that screen.
        t.replay.continueFrom(t.replay.endCursor + 1, t.replay.endOffset);
        var restartingTheme:Null<TerminalTheme> = r.theme;
        t.state = "running"; t.exitCode = 0;
        applyTheme(t, restartingTheme);
        var running = copy(starting); running.state = "running"; running.revision += 1;
        save(running);
        { setController(r.id, connection, null); inputSequence.remove(r.id); }
        c.respond(info(t, connection));
      } catch (failure:Dynamic) {
        ServiceLog.note('terminal ${r.id} could not be restarted: ${Std.string(failure)}');
        if (t != null) {
          if (t.backend != null) t.backend.close();
          t.backend = null; t.state = "failed";
          var current = catalog.get(r.id);
          var failed = copy(current == null ? record : current); failed.state = "failed"; failed.revision += 1;
          try save(failed) catch (_:Dynamic) {}
        }
        c.fail(new RpcError("terminal_restart_failed", "Could not restart shell; its last screen was kept", true));
      }
    });
  }
  // Replay remains authoritative. Invalidation is coalesced once per terminal per daemon tick.
  function changeStamp(t:RuntimeTerminal, connection:RpcConnection):String {
    var record = catalog.get(t.id);
    return Std.string(t.replay.endCursor) + ":" + Std.string(t.replay.startCursor) + ":" + t.state + ":" + t.exitCode + ":"
      + (controller(t.id) == connection) + ":" + (controller(t.id) != null) + ":"
      + (record == null ? "" : Std.string(record.revision));
  }
  /** A REPLAY or SNAPSHOT from a paced view answers its last CHANGED. */
  function acknowledge(connection:RpcConnection, id:String):Void {
    for (watch in watchers)
      if (watch.connection == connection && watch.id == id) watch.notified = false;
  }
  function notifyChanges():Void {
    for (watch in watchers.copy()) {
      var connection = watch.connection;
      if (!connection.isOpen()) { watchers.remove(watch); continue; }
      var t = terminals.get(watch.id);
      // Letting go of an ended terminal changes nothing a view shows: its watch stays, quiet.
      if (t == null && unloaded.exists(watch.id)) continue;
      var stamp = t == null ? "missing" : changeStamp(t, connection);
      if (stamp == watch.stamp) continue;
      // One unanswered CHANGED per view. The change stays pending (the stamp is not taken) and goes out once the
      // view pulls, or after the safety net if it never does.
      if (watch.paced && watch.notified && Sys.time() - watch.notifiedAt < PACED_RENOTIFY_SECONDS) continue;
      watch.stamp = stamp;
      watch.notified = true;
      watch.notifiedAt = Sys.time();
      connection.notify(WorkspaceTerminalProtocol.CHANGED,
        {workspace:workspace, instance:instance, id:watch.id}, WorkspaceTerminalProtocol.encodeChange);
      if (t == null) watchers.remove(watch);
    }
  }
  public function poll():Void {
    for (id in [for (id in controllers.keys()) id]) controller(id);
    var now = Sys.time();
    snapshotPages.prune(now);
    for (t in [for (t in terminals) t]) {
      // A view that stopped waiting (its call expired or its connection closed) is not answered.
      for (request in t.waiting.copy())
        if (!request.connection.isOpen() || request.context.isCancelled()) t.waiting.remove(request);
      var backend = t.backend;
      if (t.state != "running" || backend == null) continue;
      try backend.pollEvents(function(event) {
        if (event.kind == "output") {
          t.replay.output(event.data, event.length);
        } else if (event.kind == "status") {
          t.state = event.state;
          t.exitCode = event.exitCode;
        } else if (event.kind == "geometry") {
          // The size of the host's screen (see HostedPtyBackend.pollEvents).
          if (event.columns != t.columns || event.rows != t.rows) {
            t.replay.geometry(event.columns, event.rows);
            t.columns = event.columns;
            t.rows = event.rows;
          }
        } else if (event.kind == "reset") {
          // A new connection to the host: what came before is not continued by what follows. Views behind this point
          // find a gap and take the host's screen.
          t.replay.cut();
        } else if (event.kind == "history") {
          t.history = event.data;
        } else if (event.kind == "snapshot") {
          var history = t.history == null ? Bytes.alloc(0) : t.history;
          t.history = null;
          var waiting = t.waiting.copy();
          t.waiting.resize(0);
          for (request in waiting) answerSnapshot(t, request, history, event.data);
        }
      }) catch (failure:Dynamic) {
        // The fault is this service's: the program is not ended for it. The host keeps it and it is taken back later.
        ServiceLog.note('terminal ${t.id}: reading from its host failed in this service (${Std.string(failure)}); the host keeps the program');
        t.state = "lost";
        adoptChecksLeft = ADOPT_RETRIES;
        nextAdoptCheck = Sys.time() + ADOPT_RETRY_SECONDS;
      }
      if (t.state != "running") {
        ServiceLog.note('terminal ended: ${t.id} is ${t.state}, exit code ${t.exitCode}');
        backend.close();
        t.backend = null;
        answerWaiting(t);
      }
      var record = catalog.get(t.id);
      if (record != null &&(record.state != t.state || record.exitCode != t.exitCode) && !storageFailed) {
        var updated = copy(record);
        updated.state = t.state;
        updated.exitCode = t.exitCode;
        updated.revision += 1;
        try save(updated) catch (_:Dynamic) {
        }
      }
    }
    readopt(now);
    unloadEnded(now);
    hosts.poll();
    notifyChanges();
  }
  /** Running terminals. Their hosts keep them when this service stops, so they do not keep it running. */
  public function activeCount():Int {
    var active = 0;
    for (t in terminals) if (t.state == "running") active++;
    return active;
  }
  public function dispose():Void {
    for (t in terminals) {
      if (t.state == "running") ServiceLog.note('terminal kept running by its host while the service stops: ${t.id}');
      for (request in t.waiting) request.context.fail(error("snapshot_unavailable"));
      if (t.backend != null) t.backend.close();
    }
    hosts.dispose();
    terminals.clear();
    controllers.clear();
    controllerKeys.clear();
    watchers.resize(0);
    snapshotPages.clear();
  }
}
