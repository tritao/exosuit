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
import terminalsession.LocalPtyBackend;
import terminalsession.TerminalBackend;
import terminalsession.TerminalProfile;
import workspace.runtime.AgentTerminalResume;
import workspace.runtime.AgentTerminalIdentity;
import terminalkit.Emulator;

private class RuntimeTerminal {
  public final id:String;
  public final cwd:String;
  public var backend:Null<TerminalBackend>;
  public final emulator:Emulator;
  public var columns:Int;
  public var rows:Int;
  public var state:String = "running";
  public var exitCode:Int = 0;
  public final replay:TerminalReplayLog;
  public var historyDirty:Bool = false;
  public var nextHistorySave:Float = 0;
  public var historyError:Bool = false;
  public var hasHistory:Bool = false;
  /** The connection to its host was given up while the host was resending its history: the emulator holds part of it. */
  public var partial:Bool = false;
  /** Taken over from a host an earlier service generation left running. */
  public var adopted:Bool = false;
  /** When a view last read it (see WorkspaceTerminalManager.unloadEnded). */
  public var used:Float = Sys.time();
  public var start(get, never):Int64;
  public var end(get, never):Int64;
  function get_start():Int64 return replay.startOffset;
  function get_end():Int64 return replay.endOffset;
  public function new(id:String, cwd:String, backend:Null<TerminalBackend>, columns:Int, rows:Int, historyLimit:Int) {
    this.id = id;
    this.cwd = cwd;
    this.backend = backend;
    replay = new TerminalReplayLog(columns, rows, historyLimit);
    try emulator = Emulator.open(columns, rows, TerminalHostProtocol.SCROLLBACK_ROWS, "xterm-256color", false) catch (failure:Dynamic) {
      if (backend != null) backend.close();
      throw failure;
    }
    this.columns = columns;
    this.rows = rows;
    historyDirty = backend != null;
  }
}

/** First bounded runtime slice. Closing RPC clients never closes PTYs. */
class WorkspaceTerminalManager implements WorkspaceTerminals {
  /**
    Raw output each terminal's replay journal keeps for views catching up between reads. A view further behind takes a
    snapshot (screen and history from the emulator) instead, so the journal only needs to cover a burst; at 16 MiB it was,
    for a busy terminal, a second full copy of the history beside the emulator's.
  **/
  public static inline final REPLAY_BYTES = 2 * 1024 * 1024;
  /**
    An ended terminal no view has read for this long gives up its emulator and journal (up to tens of MiB with a full
    scrollback): its saved history is on disk and is loaded again when a view opens it, asks for its snapshot or
    restarts it. A view still showing it keeps what it shows; it asks again only when something changes.
  **/
  public static inline final UNLOAD_SECONDS = 30.0;
  /** UNLOAD_SECONDS; tests shorten it. */
  public var unloadSeconds:Float = UNLOAD_SECONDS;
  /**
    How often a running terminal with new output saves its history. A save exports the whole rendered history (up to
    16 MiB) and encodes a copy of it for the store, all of it garbage a moment later: at one save every two seconds, four
    busy terminals with long histories made the service drop about 64 MiB a second (see `exported` for why it stayed).
    The pause after a save grows with the size saved, one second per HISTORY_SAVE_RATE bytes and never less than
    HISTORY_SAVE_SECONDS (16 seconds at 16 MiB), so what saves cost per second no longer grows with the history. An
    ended terminal, a restart and a service stop still save at once.
  **/
  public static inline final HISTORY_SAVE_SECONDS = 2.0;
  public static inline final HISTORY_SAVE_RATE = 1048576.0;
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
  final historyLimit:Int;
  var count:Int = 0;
  final catalog:Map<String, TerminalRecord> = [];
  final persistence:Null<WorkspaceTerminalPersistence>;
  final groups:Void -> Array<WorkspaceGroup>;
  /** Where terminals' PTYs live when they are to outlive this service; null keeps them in this process. */
  final hosts:Null<TerminalHosts>;
  /** The service's state folder, where terminal hosts have their folders; set with hosts on or off, null in tests without state. */
  final hostState:Null<String>;
  var storageFailed:Bool = false;
  /** Conversation ids the workspace's chat sessions keep: never a terminal's. Set by the service. */
  public var otherConversations:Void -> Array<String> = function() return [];
  var nextIdentityCheck:Float = 0;

  public function new(
    workspace:String,
    instance:String,
    root:String,
    historyLimit:Int = 16777216,
    ? persistence:WorkspaceTerminalPersistence,
    ? groups:Void -> Array<WorkspaceGroup>,
    ? hosts:TerminalHosts,
    ? hostState:String
  ) {
    this.hosts = hosts;
    this.hostState = hostState;
    this.workspace = workspace;
    this.instance = instance;
    this.root = root;
    if (workspace == null || workspace.length == 0
      || workspace.length > 128 || instance == null || instance.length == 0 || instance.length > 128
      || root == null || root.length == 0 || root.length > 1024) throw "Invalid terminal workspace identity";
    if (historyLimit < 65536 || historyLimit > 16777216) throw "Invalid terminal history limit";
    this.historyLimit = historyLimit;
    this.persistence = persistence;
    // Without a group source the workspace has no groups: terminals sit in the workspace root.
    this.groups = groups == null ? function() return [] : groups;
    var stored = persistence == null ?[] : persistence.loadTerminals();
    if (stored.length > 256) throw "Terminal catalog exceeds limit";
    if (persistence != null) for (record in stored) {
      if (record.workspaceRoot == null) record.workspaceRoot = root;
      if (!validRecord(record) || catalog.exists(record.id)) throw "Invalid persisted terminal record";
      var wasRunning = record.state == "running" || record.state == "starting";
      // A lost terminal whose host still runs is taken back too: an earlier service lost its connection to the host, or
      // ran without hosts, and the program went on.
      if (record.instance != instance && (wasRunning || record.state == "lost")) {
        // A terminal in a host kept running while no service did: this generation takes it over. The host sends its
        // screen and history when the connection opens (see HostedPtyBackend); if it no longer answers, the terminal
        // is reported lost then.
        var kept = hosts == null || count >= 16 ? null : hosts.adopt(record.id);
        if (kept != null) {
          ServiceLog.note('terminal kept by its host: "${record.name}" (${record.id}), from service generation ${record.instance}');
          var adopted = new RuntimeTerminal(record.id, record.cwd, kept, 80, 24, historyLimit);
          // Nothing to save until the host's screen arrives; saving now would replace the stored history with a blank one.
          adopted.historyDirty = false;
          adopted.adopted = true;
          terminals.set(record.id, adopted);
          count++;
          record.instance = instance;
          record.state = "running";
          record.revision += 1;
          persistence.saveTerminal(record);
        } else if (wasRunning) {
          ServiceLog.note('terminal lost: "${record.name}" (${record.id}) was running in service generation ${record.instance}, which ended');
          record.state = "lost";
          record.revision += 1;
          persistence.saveTerminal(record);
        }
      }
      record.available = false;
      catalog.set(record.id, record);
    }
    // No host may be left running unseen: one whose terminal has no record is logged (suit lists it; the user ends it), and
    // a service without hosts says which hosts go on running under it.
    if (persistence != null && hostState != null) {
      var running = 0;
      try running = TerminalHosts.sweep(hostState, [for (record in stored) record.id]) catch (_:Dynamic) {}
      if (hosts == null && running > 0)
        ServiceLog.note(running + " terminal host(s) of this workspace keep running although this service runs without hosts"
          + " (EXOSUIT_TERMINAL_HOST): their terminals show as lost; `suit terminals` lists them and `suit terminals end` ends them");
    }
  }
  function knownGroup(id:String):Bool return WorkspaceProtocol.knownGroup(id, groups());
  function validName(name:String):Bool return name != null && StringTools.trim(name).length > 0
    && name.length <= 128 && name.indexOf("\t") < 0 && name.indexOf("\n") < 0 && name.indexOf("\r") < 0;
  static function validTheme(theme:Null<TerminalTheme>):Bool return theme == null
    || theme.foreground >= 0 && theme.foreground <= 0xffffff && theme.background >= 0 && theme.background <= 0xffffff;
  static function applyTheme(t:RuntimeTerminal, theme:Null<TerminalTheme>):Void {
    if (theme == null) return;
    t.emulator.setDefaultColors(theme.foreground, theme.background);
    // A subscribed, idle TUI must receive the notification without writing output first.
    var replies = t.emulator.takeReplies();
    if (t.state == "running" && t.backend != null && replies.length > 0) t.backend.write(replies);
  }
  static function validAgentProvider(provider:Null<String>):Bool return provider == null || ["codex", "claude", "pi"].indexOf(provider) >= 0;
  static function profile(record:TerminalRecord, launch:Null<AgentTerminalLaunch>):TerminalProfile return record.agentProvider == null
    ? TerminalProfile.shell(record.cwd) : TerminalProfile.agent(record.agentProvider, record.cwd, launch == null ? null : launch.arguments);
  /** How a provider terminal starts (which conversation it resumes); null for a shell. Records the choice in `record`. */
  function agentLaunch(record:TerminalRecord, restart:Bool):Null<AgentTerminalLaunch> {
    if (record.agentProvider == null) return null;
    var launch = AgentTerminalResume.plan(record, restart, taken(record), AgentTerminalIdentity.folder(hostState, record.id));
    record.agentSession = launch.session;
    record.agentStarted = launch.started;
    return launch;
  }
  /** The conversations kept elsewhere than `record`: by the other terminals and by chat sessions. */
  function taken(record:TerminalRecord):Array<String> {
    var found = [for (other in catalog) if (other.id != record.id && other.agentSession != null) other.agentSession];
    try for (thread in otherConversations()) if (thread != null && thread != "") found.push(thread) catch (_:Dynamic) {}
    return found;
  }
  /**
    Keeps each running provider terminal's conversation in its record while it runs, so another terminal's restart
    sees it as taken and a restart of this one needs no guess: Claude's reported id (after `/clear` too), and the one
    Codex or Pi record that can only be this terminal's (`AgentTerminalResume.resolve`).
  **/
  function followConversations():Void {
    if (storageFailed || Sys.time() < nextIdentityCheck) return;
    nextIdentityCheck = Sys.time() + 2;
    for (t in terminals) {
      if (t.state != "running") continue;
      var record = catalog.get(t.id);
      if (record == null || record.agentProvider == null) continue;
      var found:Null<String> = null;
      if (record.agentProvider == "claude") {
        var told = AgentTerminalIdentity.reported(AgentTerminalIdentity.folder(hostState, record.id));
        if (told != null && told != record.agentSession && taken(record).indexOf(told) < 0) found = told;
      } else if (record.agentSession == null && record.agentStarted != null) {
        // Two terminals of one provider and folder both waiting: a record could be either's, so neither takes one.
        var waiting = false;
        for (other in terminals) {
          var o = other == t || other.state != "running" ? null : catalog.get(other.id);
          if (o != null && o.agentProvider == record.agentProvider && o.agentSession == null && o.cwd == record.cwd) waiting = true;
        }
        if (!waiting) found = AgentTerminalResume.resolve(record, taken(record));
      }
      if (found == null) continue;
      var updated = copy(record);
      updated.agentSession = found;
      updated.revision += 1;
      try save(updated) catch (_:Dynamic) {}
    }
  }
  /** Starts the terminal's program: in a host when hosts are on, else (or when the host cannot start) in this process. */
  function spawnBackend(record:TerminalRecord, columns:Int, rows:Int, agent:Null<AgentTerminalLaunch>):TerminalBackend {
    var launch = profile(record, agent);
    var available = hosts;
    if (available != null) {
      try return available.spawn(record.id, launch, columns, rows, record.name) catch (failure:Dynamic)
        ServiceLog.note('terminal host could not start for ${record.id} (${Std.string(failure)}); the terminal runs inside the service and ends with it');
      // An earlier host for this terminal (it was lost, and is being restarted) must not keep its program running unseen:
      // the same request through its folder that removing a terminal leaves.
      if (hostState != null) TerminalHosts.endHostOf(hostState, record.id, "the terminal was restarted inside the service");
    }
    return LocalPtyBackend.spawn(launch, columns, rows);
  }
  /** Running terminals whose programs a host keeps when this service stops. */
  public function hostedCount():Int {
    var hosted = 0;
    for (t in terminals) if (t.state == "running" && t.backend != null && Std.isOfType(t.backend, HostedPtyBackend)) hosted++;
    return hosted;
  }
  function validRecord(r:TerminalRecord):Bool return r != null && validAgentProvider(r.agentProvider) && r.id != null && r.id.length > 0
    && r.id.length <= 128 && validName(r.name) && knownGroup(r.group) && WorkspaceProtocol.validOrder(r.order) && r.workspaceRoot == root && r.cwd != null && r.cwd.length > 0 && r.cwd.length <= 1024 && r.instance != null
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
    // Every retained record can open a read-only recovery view, even if an
    // older daemon never saved output. Opening must never spawn a replacement.
    available: true,
    revision: r.revision,
    workspaceRoot: root,
    agentProvider: r.agentProvider,
    order: r.order,
    agentSession: r.agentSession,
    agentStarted: r.agentStarted
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
  function restoreHistory(id:String):Null<RuntimeTerminal> {
    var record = catalog.get(id);
    if (record == null) return null;
    if (count >= 16) throw "Terminal limit";
    var history = persistence == null ? null : persistence.loadTerminalHistory(id);
    var t = new RuntimeTerminal(id, record.cwd, null, history == null ? 80 : history.columns,
      history == null ? 24 : history.rows, historyLimit);
    try {
      if (history != null) {
        t.emulator.feed(history.data);
        t.emulator.takeReplies();
        t.replay.output(history.data, history.data.length);
        t.hasHistory = true;
      }
    } catch (failure:Dynamic) { t.emulator.close(); throw failure; }
    var reached = unloaded.get(id);
    if (reached != null) {
      t.replay.continueFrom(reached.cursor, reached.offset);
      unloaded.remove(id);
    }
    t.state = record.state;
    t.exitCode = record.exitCode;
    terminals.set(id, t);
    count++;
    return t;
  }
  /** The terminal's runtime, loaded again from its saved history when it was let go; null when there is none. */
  function loaded(id:String):Null<RuntimeTerminal> {
    var t = terminals.get(id);
    if (t == null && unloaded.exists(id) && catalog.exists(id)) try t = restoreHistory(id) catch (_:Dynamic) {}
    return t;
  }
  /**
    Lets go of the emulator and journal of every ended terminal whose history is saved and that no view read for
    UNLOAD_SECONDS. Without persistence nothing could load it again, so tests without state keep them.
  **/
  function unloadEnded(now:Float):Void {
    if (persistence == null) return;
    var released = false;
    for (id in [for (id in terminals.keys()) id]) {
      var t = terminals.get(id);
      if (t.state == "running" || t.state == "starting" || t.historyDirty || t.historyError || !catalog.exists(id)
          || now - t.used < unloadSeconds || snapshotPages.holds(id)) continue;
      unloaded.set(id, {cursor: t.replay.endCursor, offset: t.replay.endOffset});
      if (t.backend != null) { t.backend.close(); t.backend = null; }
      t.emulator.close();
      terminals.remove(id);
      count--;
      released = true;
    }
    // What the ended terminals' last saves and views left is garbage the collector does not count (see `exported`), and a
    // quiet service allocates too little to start a collection: without one, two ended terminals let go left it at
    // 880 MiB instead of 250.
    #if hl
    if (released) hl.Gc.major();
    #end
  }
  /** True while a hosted terminal's emulator holds a history its host has not finished sending (HostedPtyBackend.midReplay). */
  static function midReplay(t:RuntimeTerminal):Bool {
    return t.backend != null && Std.isOfType(t.backend, HostedPtyBackend) && (cast t.backend:HostedPtyBackend).midReplay();
  }
  function saveHistory(t:RuntimeTerminal):Void {
    if (persistence == null || !t.historyDirty) return;
    // Saved, the part would replace the whole history in the store; it is saved once the host's screen has arrived.
    if (midReplay(t)) return;
    var saved = 0;
    try {
      var data = t.emulator.historySnapshot();
      saved = data.length;
      persistence.saveTerminalHistory(t.id, {version:1, columns:t.columns, rows:t.rows, data:data});
    } catch (failure:Dynamic) {
      // Once per run of failures: a save is retried every two seconds.
      if (!t.historyError) ServiceLog.note('terminal ${t.id}: its history could not be saved (${Std.string(failure)})');
      t.historyError = true;
      throw failure;
    }
    t.historyError = false;
    t.historyDirty = false;
    t.nextHistorySave = Sys.time() + Math.max(HISTORY_SAVE_SECONDS, saved / HISTORY_SAVE_RATE);
    // The export and its encoded copy.
    exported(2 * saved);
  }
  /**
    Large buffers made for history (saves and views' snapshots) and dropped since this manager last asked for a
    collection. HashLink starts a major collection by the allocation it counts, and these buffers did not move that
    count (measured 2026-11-12: its counters stayed under 70 MiB while the service held 2.7 GiB): their garbage stayed
    until other allocation reached the collector's trigger, a minute or more later. Past GARBAGE_BYTES this manager
    starts one itself (1-17 ms measured with four full terminals).
  **/
  static inline final GARBAGE_BYTES = 64.0 * 1024 * 1024;
  var garbage:Float = 0;
  function exported(bytes:Int):Void {
    garbage += bytes;
    if (garbage < GARBAGE_BYTES) return;
    garbage = 0;
    #if hl
    hl.Gc.major();
    #end
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
    historyError: t.historyError,
    restartable: true,
    historyAvailable: t.hasHistory,
    agentProvider: record == null ? null : record.agentProvider,
    controlled: owner != null
    };
  }
  function error(code:String):RpcError return {code: code, message: code, ambiguous: false};
  function valid(workspace:String, instance:String, id:String):Bool return workspace == this.workspace
    && instance == this.instance && id != null && id.length > 0 && id.length <= 128;
  function size(columns:Int, rows:Int):Bool return columns >= 1 && columns <= 512 && rows >= 1 && rows <= 256;
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
        c.fail({code: "storage_failed", message: "Terminal metadata requires recovery", ambiguous: true}
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
        if (r.terminate == true && t != null && t.backend != null) {
          if (t.state == "running") {
            ServiceLog.note('terminal closed by a client while running: ${r.id}');
            t.backend.terminate(true);
          }
          t.backend.close();t.backend = null;t.state = "exited";
        }
        if (persistence != null) persistence.removeTerminal(r.id);
        catalog.remove(r.id);
        unloaded.remove(r.id);
        // The record is gone, so must its host be, also one this service is not attached to (lost, not answered yet, or
        // kept from a service with hosts while this one runs without).
        if (hostState != null) TerminalHosts.endHostOf(hostState, r.id, "the terminal was removed");
        AgentTerminalIdentity.remove(AgentTerminalIdentity.folder(hostState, r.id));
      } catch (_:Dynamic) {
        storageFailed = true;
        c.fail({code: "storage_failed", message: "Terminal metadata requires recovery", ambiguous: true}
        );
        return;
      }
      if (t != null) {
        if (t.backend != null) t.backend.close();
        t.emulator.close();
        terminals.remove(r.id);
        count--;
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
      var t = terminals.get(r.id);
      if (t == null && !r.create && catalog.exists(r.id)) {
        try t = restoreHistory(r.id) catch (_:Dynamic) { c.fail(error("history_unavailable")); return; }
      }
      if (t == null) {
        if (!r.create) {
          c.fail(error("unknown_terminal"));
          return;
        }
        if (catalog.exists(r.id)) {
          c.fail(error("terminal_unavailable"));
          return;
        }
        if (storageFailed) {
          c.fail(error("storage_unavailable"));
          return;
        }
        if ([for (_ in catalog) 1].length >= 256) {
          c.fail(error("catalog_limit"));
          return;
        }
        if (count >= 16) {
          c.fail(error("terminal_limit"));
          return;
        }
        var groupList = groups();
        // Without a group the terminal goes to the workspace root.
        var selectedGroup = r.group != null ? r.group : WorkspaceProtocol.ROOT_GROUP;
        if (!knownGroup(selectedGroup)) { c.fail(error("unknown_group")); return; }
        // The explicit directory, else the group's or nearest ancestor's folder, else the root (ADR 0006).
        var chosen = new WorkspaceDirectories(root).forSession(groupList, selectedGroup, r.directory);
        if (chosen.path == null) { c.fail({code: "invalid_directory", message: chosen.error, ambiguous: false}); return; }
        var resolved = chosen.path;
        var record:TerminalRecord = {
          id: r.id,
          name: r.agentProvider == null ? nextTerminalName() : (r.agentProvider == "claude" ? "Claude Code" : r.agentProvider == "codex" ? "Codex" : "Pi") + " · Terminal",
          group: selectedGroup,
          cwd : resolved,
          workspaceRoot: root,
          instance : instance,
          state : "starting",
          exitCode : 0,
          available : false,
          revision : 1,
          agentProvider: r.agentProvider,
          order: nextOrder(selectedGroup, groupList)
        };
        var agent:Null<AgentTerminalLaunch> = null;
        try agent = agentLaunch(record, false) catch (_:Dynamic) {}
        try {
          save(record);
        } catch (_:Dynamic) {
          c.fail({code: "storage_failed", message: "Terminal creation requires recovery", ambiguous: true}
          );
          return;
        }
        var created:RuntimeTerminal;
        try {
          created = new RuntimeTerminal(
            r.id,
            resolved,
            spawnBackend(record, r.columns, r.rows, agent),
            r.columns,
            r.rows,
            historyLimit
          );
        } catch (cause:Dynamic) {
          var failed = copy(record);
          failed.state = "failed";
          failed.revision += 1;
          try save(failed) catch (_:Dynamic) {
          }
          c.fail({
            code: storageFailed ? "storage_failed" : "terminal_spawn_failed",
            message : "Terminal creation failed: " + Std.string(cause),
            ambiguous : storageFailed
          }
          );
          return;
        }
        var running = copy(record);
        running.state = "running";
        running.revision += 1;
        try save(running) catch (_:Dynamic) {
          created.backend.close();
          created.emulator.close();
          c.fail({code: "storage_failed", message: "Terminal creation requires recovery", ambiguous: true}
          );
          return;
        }
        t = created;
        terminals.set(r.id, created);
        count++;
        ServiceLog.note('terminal started: "${running.name}" (${r.id})');
      }
      t.used = Sys.time();
      var openKey = clientKey(scope, r.clientKey);
      if (control && t.state == "running" && (controller(r.id) == null || sameClient(r.id, openKey))) setController(r.id, connection, openKey);
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
    connection.register(WorkspaceTerminalProtocol.OUTPUT, function(r, c) {
      if (!read) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = terminals.get(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (r.offset < t.start) {
        c.fail(error("replay_gap"));
        return;
      }
      if (r.offset > t.end || r.offset < 0) {
        c.fail(error("invalid_offset"));
        return;
      }
      var bytes = t.replay.readBytes(r.offset);
      c.respond({terminal: info(t, connection), offset: r.offset, data: bytes}
      );
    }
    );
    connection.register(WorkspaceTerminalProtocol.REPLAY, function(r, c) {
      if (!read) { c.fail(error("unauthorized")); return; }
      if (!valid(r.workspace, r.instance, r.id)) { c.fail(error("invalid_request")); return; }
      var t = terminals.get(r.id);
      // An ended terminal whose runtime was let go (unloadEnded): the view takes a snapshot, which loads it from disk.
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
      var t = terminals.get(r.id);
      if (t == null && unloaded.exists(r.id) && catalog.exists(r.id))
        try t = restoreHistory(r.id) catch (_:Dynamic) { c.fail(error("history_unavailable")); return; }
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
      var value:TerminalScreenSnapshot;
      try {
        var data = t.emulator.screenSnapshot(), current = info(t, connection);
        // A view that attaches asks for the lines above the screen too (up to SCROLLBACK_ROWS of them): the rendered
        // history, taken at the same moment as the screen and sent ahead of it.
        var historyBytes = 0;
        if (token == 0 && r.history == true) {
          try {
            var whole = t.emulator.historySnapshot();
            // A view on a slow link asks for the recent rows only (TerminalSnapshotQuery.historyLimit).
            var limit:Int = r.historyLimit == null ? 0 : r.historyLimit;
            var history = limit > 0 ? Emulator.recentHistory(whole, limit) : whole;
            if (history == null) history = Bytes.alloc(0);
            var joined = Bytes.alloc(history.length + data.length);
            joined.blit(0, history, 0, history.length);
            joined.blit(history.length, data, 0, data.length);
            historyBytes = history.length;
            data = joined;
            // The export now, and the joined copy once the view has read its pages.
            exported(whole.length + history.length);
          } catch (failure:Dynamic) {
            ServiceLog.note('terminal ${t.id}: the history could not be exported for a view (${Std.string(failure)}); it gets the screen alone');
          }
        }
        // Older clients ask for the whole snapshot in one reply, which a large grid's does not fit.
        value = token < 0 ? {terminal: current, data: data, cursor: t.replay.endCursor}
          : snapshotPages.start(connection, t.id, data, current, t.replay.endCursor, Sys.time(), historyBytes,
            scope == "local" ? TerminalSnapshotPages.LOCAL_PAGE_BYTES : TerminalSnapshotPages.PAGE_BYTES);
        c.respond(value);
      } catch (failure:Dynamic) {
        Sys.println("Terminal screen snapshot failed for " + t.id + ": " + Std.string(failure));
        c.fail(error("snapshot_unavailable"));
      }
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
        if (owner == null || owner == connection || r.takeover || sameClient(r.id, claimKey)) setController(r.id, connection, claimKey);
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
      if (t == null || t.state != "running") {
        c.fail(error("terminal_not_running"));
        return;
      }
      if (controller(r.id) != connection) {
        c.fail(error("terminal_controlled"));
        return;
      }
      var previous = inputSequence.get(r.id);
      if (r.sequence !=(previous == null ? 1 : previous + 1)) {
        c.fail(error("input_sequence"));
        return;
      }
      // Reserve before writing: an exception can have delivered a prefix. Never repeat input.
      inputSequence.set(r.id, r.sequence);
      try {
        t.backend.write(r.data);
        c.respond(info(t, connection));
      } catch (_:Dynamic) {
        c.fail({code: "input_failed", message: "Input delivery is uncertain", ambiguous: true}
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
          if (t.state == "running") t.backend.resize(r.columns, r.rows);
          t.emulator.resize(r.columns, r.rows);
          t.replay.geometry(r.columns, r.rows);
          t.columns = r.columns;
          t.rows = r.rows;
          t.historyDirty = true;
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
      if (t.state == "running") {
        ServiceLog.note('terminal asked to end by a client: ${r.id}');
        t.backend.terminate(true);
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
      try {
        if (t == null) t = restoreHistory(r.id);
        if (t == null) throw "Unknown terminal";
        var normalized = t.emulator.historySnapshot();
        t.emulator.feed(normalized);
        t.replay.output(normalized, normalized.length);
        // Move the entire old viewport into scrollback before a fresh shell's
        // startup code can clear its screen, then move the separator into scrollback
        // too: a Windows ConPTY starts by clearing the visible page, which would erase
        // a separator left on it. The fresh shell gets a blank page.
        var boundary = new StringBuf();
        boundary.add('\033[${t.rows};1H');
        for (_ in 0...t.rows) boundary.add("\r\n");
        var starting = copy(record);
        var agent = agentLaunch(starting, true);
        boundary.add("\033[H" + (agent == null ? "── Shell restarted ──" : agent.note));
        boundary.add('\033[${t.rows};1H\r\n\033[H');
        var separator = haxe.io.Bytes.ofString(boundary.toString());
        t.emulator.feed(separator);
        t.emulator.takeReplies();
        t.replay.output(separator, separator.length);
        t.hasHistory = true;
        t.historyDirty = true;
        saveHistory(t);
        starting.instance = instance; starting.state = "starting"; starting.exitCode = 0; starting.revision += 1;
        save(starting);
        if (t.backend != null) t.backend.close();
        var restartingTheme:Null<TerminalTheme> = r.theme;
        applyTheme(t, restartingTheme);
        t.backend = spawnBackend(starting, t.columns, t.rows, agent);
        t.state = "running"; t.exitCode = 0;
        var running = copy(starting); running.state = "running"; running.revision += 1;
        save(running);
        setController(r.id, connection, null);
        c.respond(info(t, connection));
      } catch (_:Dynamic) {
        if (t != null) {
          if (t.backend != null) t.backend.close();
          t.backend = null; t.state = "failed";
          var current = catalog.get(r.id);
          var failed = copy(current == null ? record : current); failed.state = "failed"; failed.revision += 1;
          try save(failed) catch (_:Dynamic) {}
        }
        c.fail({code:"terminal_restart_failed", message:"Could not restart shell; saved history was retained", ambiguous:true});
      }
    });
  }
  // Replay remains authoritative. Invalidation is coalesced once per terminal per daemon tick.
  function changeStamp(t:RuntimeTerminal, connection:RpcConnection):String {
    var record = catalog.get(t.id);
    return Std.string(t.replay.endCursor) + ":" + t.state + ":" + t.exitCode + ":"
      + (controller(t.id) == connection) + ":" + (controller(t.id) != null) + ":"
      + (record == null ? "" : Std.string(record.revision)) + ":" + t.historyError;
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
    snapshotPages.prune(Sys.time());
    for (t in terminals) {
      if (t.state != "running") {
        if (t.historyDirty && Sys.time() >= t.nextHistorySave)
          try saveHistory(t) catch (_:Dynamic) { t.nextHistorySave = Sys.time() + 2; }
        continue;
      }
      try t.backend.pollEvents(function(event) {
        if (event.kind == "output") {
          t.emulator.feedRange(event.data, 0, event.length);
          var replies = t.emulator.takeReplies();
          if (replies.length > 0) t.backend.write(replies);
          t.replay.output(event.data, event.length);
          if (event.length > 0) t.hasHistory = true;
          t.historyDirty = true;
        } else if (event.kind == "status") {
          t.state = event.state;
          t.exitCode = event.exitCode;
        } else if (event.kind == "geometry" && Std.isOfType(t.backend, HostedPtyBackend)) {
          // The size of the host's screen (see HostedPtyBackend.pollEvents): this emulator follows it.
          if (event.columns != t.columns || event.rows != t.rows) {
            t.emulator.resize(event.columns, event.rows);
            t.replay.geometry(event.columns, event.rows);
            t.columns = event.columns;
            t.rows = event.rows;
          }
        } else if (event.kind == "snapshot") {
          // A host's exact screen, cursor and modes, after its history was fed as output.
          try t.emulator.restoreScreenSnapshot(event.data) catch (failure:Dynamic)
            ServiceLog.note('terminal ${t.id}: the screen kept by its host could not be restored (${Std.string(failure)})');
          t.emulator.takeReplies();
          t.historyDirty = true;
          // The restored screen is not in the journal, so a view cannot reach it by replay. At a service start no view
          // is attached yet; after a reconnect to the host the attached ones find a gap and take the snapshot again.
          t.replay.cut();
        }
      }
      ) catch (failure:Dynamic) {
        if (Std.isOfType(t.backend, HostedPtyBackend)) {
          // The fault is this service's (its emulator refused what the host sent, as a newer or older build may): the
          // program is not ended for it. The host keeps it and the next service takes the terminal back.
          ServiceLog.note('terminal ${t.id}: reading from its host failed in this service (${Std.string(failure)}); the host keeps the program');
          t.state = "lost";
        } else {
          t.state = "failed";
          try t.backend.terminate(true) catch (_:Dynamic) {}
        }
        t.backend.close();
      }
      if (t.state != "running") {
        ServiceLog.note('terminal ended: ${t.id} is ${t.state}, exit code ${t.exitCode}');
        t.backend.close();
        if (midReplay(t)) {
          // What this emulator holds is the start of the host's history: the store keeps the whole one it had, and the
          // runtime is dropped below so that opening the terminal shows that.
          ServiceLog.note('terminal ${t.id}: the history its host was sending was cut off; the saved history is kept');
          t.partial = true;
          t.historyDirty = false;
        }
      }
      if (t.historyDirty && (t.state != "running" || Sys.time() >= t.nextHistorySave))
        try saveHistory(t) catch (_:Dynamic) { t.nextHistorySave = Sys.time() + 2; }
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
    // A terminal whose host did not answer has nothing on its screen, and one whose host's history was cut off only part of
    // it: drop the runtime so that opening it shows its saved history.
    for (id in [for (id in terminals.keys()) id]) {
      var gone = terminals.get(id);
      if (gone == null || gone.state != "lost" || !(gone.partial || gone.adopted && !gone.hasHistory)) continue;
      gone.emulator.close();
      terminals.remove(id);
      count--;
    }
    followConversations();
    unloadEnded(Sys.time());
    if (hosts != null) hosts.poll();
    notifyChanges();
  }
  /** Terminals whose emulator this service holds (running, or ended and read lately). */
  public function loadedCount():Int return count;
  public function activeCount():Int {
    var active = 0;
    for (t in terminals) if (t.state == "running") active++;
    return active;
  }
  public function dispose():Void {
    for (t in terminals) {
      try saveHistory(t) catch (_:Dynamic) { Sys.println("Terminal history could not be saved: " + t.id); }
      if (t.state == "running") ServiceLog.note(Std.isOfType(t.backend, HostedPtyBackend)
        ? 'terminal kept running by its host while the service stops: ${t.id}' : 'terminal ended by the service stopping: ${t.id}');
      if (t.backend != null) t.backend.close();
      t.emulator.close();
    }
    if (hosts != null) hosts.dispose();
    terminals.clear();
    controllers.clear();
    controllerKeys.clear();
    watchers.resize(0);
    snapshotPages.clear();
    count = 0;
  }
}
