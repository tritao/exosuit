package workspace.runtime;

import haxe.io.Bytes;
import haxe.Int64;
import haxeon.rpc.*;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceTerminals;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import terminalsession.LocalPtyBackend;
import terminalsession.TerminalProfile;
import terminalkit.Emulator;

private typedef OutputChunk = {var offset: Int64;
var data:Bytes;
var length:Int;
}
private class RuntimeTerminal {
  public final id:String;
  public final backend:LocalPtyBackend;
  public final emulator:Emulator;
  public var columns:Int;
  public var rows:Int;
  public var state:String = "running";
  public var exitCode:Int = 0;
  public var start:Int64 = 0;
  public var end:Int64 = 0;
  public var retained:Int = 0;
  public final output:Array<OutputChunk> = [];
  public function new(id:String, backend:LocalPtyBackend, columns:Int, rows:Int) {
    this.id = id;
    this.backend = backend;
    try emulator = Emulator.open(columns, rows, 1000, "xterm-256color", false) catch (failure:Dynamic) {
      backend.close();
      throw failure;
    }
    this.columns = columns;
    this.rows = rows;
  }
}

/** First bounded runtime slice. Closing RPC clients never closes PTYs. */
class WorkspaceTerminalManager implements WorkspaceTerminals {
  final workspace:String;
  final instance:String;
  final root:String;
  final terminals:Map<String, RuntimeTerminal> = [];
  final historyLimit:Int;
  var count:Int = 0;
  final catalog:Map<String, TerminalRecord> = [];
  final persistence:Null<WorkspaceTerminalPersistence>;
  final groups:Void -> Array<WorkspaceGroup>;
  var storageFailed:Bool = false;

  public function new(
    workspace:String,
    instance:String,
    root:String,
    historyLimit:Int = 16777216,
    ? persistence:WorkspaceTerminalPersistence,
    ? groups:Void -> Array<WorkspaceGroup>
  ) {
    this.workspace = workspace;
    this.instance = instance;
    this.root = root;
    if (workspace == null || workspace.length == 0
      || workspace.length > 128 || instance == null || instance.length == 0 || instance.length > 128
      || root == null || root.length == 0 || root.length > 1024) throw "Invalid terminal workspace identity";
    if (historyLimit < 65536 || historyLimit > 16777216) throw "Invalid terminal history limit";
    this.historyLimit = historyLimit;
    this.persistence = persistence;
    this.groups = groups == null ? function() return [{id : "work", name : "Work", cwd : root, revision : 1}
    ]:groups;
    var stored = persistence == null ?[] : persistence.loadTerminals();
    if (stored.length > 256) throw "Terminal catalog exceeds limit";
    if (persistence != null) for (record in stored) {
      if (!validRecord(record) || catalog.exists(record.id)) throw "Invalid persisted terminal record";
      if (record.instance != instance &&(record.state == "running" || record.state == "starting")) {
        record.state = "lost";
        record.revision += 1;
        persistence.saveTerminal(record);
      }
      record.available = false;
      catalog.set(record.id, record);
    }
  }
  function knownGroup(id:String):Bool {
    for (group in groups()) if (group.id == id) return true;
    return false;
  }
  function validName(name:String):Bool return name != null && StringTools.trim(name).length > 0
    && name.length <= 128 && name.indexOf("\t") < 0 && name.indexOf("\n") < 0 && name.indexOf("\r") < 0;
  function validRecord(r:TerminalRecord):Bool return r != null && r.id != null && r.id.length > 0
    && r.id.length <= 128 && validName(r.name) && knownGroup(r.group) && r.cwd == root && r.instance != null
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
  function copy(r:TerminalRecord):TerminalRecord return {
    id: r.id,
    name: r.name,
    group: r.group,
    cwd: r.cwd,
    instance: r.instance,
    state: r.state,
    exitCode: r.exitCode,
    available: terminals.exists(r.id) && r.instance == instance,
    revision: r.revision
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
  public function snapshot():TerminalCatalog {
    var records = [for (r in catalog) copy(r)];
    records.sort(function(a, b) return Reflect.compare(a.id, b.id));
    return {instance: instance, groups: groups(), terminals: records, next: null};
  }
  function info(t:RuntimeTerminal):TerminalInfo return {
    id: t.id,
    cwd: root,
    state: t.state,
    exitCode: t.exitCode,
    columns: t.columns,
    rows: t.rows,
    start: t.start,
    end: t.end
  };
  function error(code:String):RpcError return {code: code, message: code, ambiguous: false};
  function valid(workspace:String, instance:String, id:String):Bool return workspace == this.workspace
    && instance == this.instance && id != null && id.length > 0 && id.length <= 128;
  function size(columns:Int, rows:Int):Bool return columns >= 1 && columns <= 512 && rows >= 1 && rows <= 256;
  public function bind(connection:RpcConnection, capabilities:Array<String>):Void {
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
        if (records.length == 8) {
          more = true;
          break;
        }
        records.push(copy(catalog.get(id)));
      }
      c.respond({
        instance: instance,
        groups: groups(),
        terminals: records,
        next: more ? records[records.length - 1].id : null
      }
      );
    }
    );
    connection.register(WorkspaceTerminalProtocol.RENAME, function(r, c) {
      if (!control || !catalogGrant) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id) || !validName(r.name) || !knownGroup(r.group)) {
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
      if (t != null && t.state == "running") {
        c.fail(error("terminal_running"));
        return;
      }
      try {
        if (storageFailed) throw "Terminal metadata storage unavailable";
        if (persistence != null) persistence.removeTerminal(r.id);
        catalog.remove(r.id);
      } catch (_:Dynamic) {
        storageFailed = true;
        c.fail({code: "storage_failed", message: "Terminal metadata requires recovery", ambiguous: true}
        );
        return;
      }
      if (t != null) {
        t.backend.close();
        t.emulator.close();
        terminals.remove(r.id);
        count--;
      }
      c.respond({workspace: r.workspace, instance: r.instance, id: r.id}
      );
    }
    );
    // Input sequence is per authenticated connection, never a persisted global client counter.
    var inputSequence:Map<String, Int> = [];
    connection.register(WorkspaceTerminalProtocol.OPEN, function(r, c) {
      if (!read ||(r.create && !control)) {
        c.fail(error("unauthorized"));
        return;
      }
      if (!valid(r.workspace, r.instance, r.id) || !size(r.columns, r.rows)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = terminals.get(r.id);
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
        if (groupList.length == 0) {
          c.fail(error("unknown_group"));
          return;
        }
        var record:TerminalRecord = {
          id: r.id,
          name: "Terminal " +(count + 1),
          group: knownGroup("work") ? "work" : groupList[0].id,
          cwd : root,
          instance : instance,
          state : "starting",
          exitCode : 0,
          available : false,
          revision : 1
        };
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
            LocalPtyBackend.spawn(TerminalProfile.shell(root), r.columns, r.rows),
            r.columns,
            r.rows
          );
        } catch (_:Dynamic) {
          var failed = copy(record);
          failed.state = "failed";
          failed.revision += 1;
          try save(failed) catch (_:Dynamic) {
          }
          c.fail({
            code: storageFailed ? "storage_failed" : "terminal_spawn_failed",
            message : "Terminal creation failed",
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
      }
      c.respond(info(t));
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
      var length = Int64.toInt(t.end - r.offset > 65536 ? Int64.ofInt(65536) : t.end - r.offset);
      var bytes = Bytes.alloc(length), copied = 0;
      for (chunk in t.output) {
        if (copied == length) break;
        if (chunk.offset + chunk.length <= r.offset) continue;
        var skip = r.offset > chunk.offset ? Int64.toInt(r.offset - chunk.offset) : 0;
        var take = chunk.length - skip;
        if (take > length - copied) take = length - copied;
        bytes.blit(copied, chunk.data, skip, take);
        copied += take;
      }
      c.respond({terminal: info(t), offset: r.offset, data: bytes}
      );
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
      var previous = inputSequence.get(r.id);
      if (r.sequence !=(previous == null ? 1 : previous + 1)) {
        c.fail(error("input_sequence"));
        return;
      }
      // Reserve before writing: an exception can have delivered a prefix. Never repeat input.
      inputSequence.set(r.id, r.sequence);
      try {
        t.backend.write(r.data);
        c.respond(info(t));
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
      if (!valid(r.workspace, r.instance, r.id) || !size(r.columns, r.rows)) {
        c.fail(error("invalid_request"));
        return;
      }
      var t = terminals.get(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      try {
        if (t.state == "running") t.backend.resize(r.columns, r.rows);
        t.emulator.resize(r.columns, r.rows);
        t.columns = r.columns;
        t.rows = r.rows;
        c.respond(info(t));
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
      var t = terminals.get(r.id);
      if (t == null) {
        c.fail(error("unknown_terminal"));
        return;
      }
      if (t.state == "running") t.backend.terminate(true);
      c.respond(info(t));
    }
    );
  }
  public function poll():Void {
    for (t in terminals) {
      if (t.state != "running") continue;
      try t.backend.pollEvents(function(event) {
        if (event.kind == "output") {
          t.emulator.feedRange(event.data, 0, event.length);
          var replies = t.emulator.takeReplies();
          if (replies.length > 0) t.backend.write(replies);
          // Native PTY memory is borrowed; retained replay must own exactly these bytes.
          var consumed = 0;
          while (consumed < event.length) {
            var chunk = t.output.length == 0 ? null : t.output[t.output.length - 1];
            if (chunk == null || chunk.length == 65536) {
              chunk = {offset: t.end + consumed, data: Bytes.alloc(65536), length: 0};
              t.output.push(chunk);
            }
            var take = event.length - consumed;
            if (take > 65536 - chunk.length) take = 65536 - chunk.length;
            chunk.data.blit(chunk.length, event.data, consumed, take);
            chunk.length += take;
            consumed += take;
          }
          t.end += event.length;
          t.retained += event.length;
          while (t.retained > historyLimit) {
            var old = t.output.shift();
            t.retained -= old.length;
            t.start = old.offset + old.length;
          }
        } else if (event.kind == "status") {
          t.state = event.state;
          t.exitCode = event.exitCode;
        }
      }
      ) catch (_:Dynamic) {
        t.state = "failed";
        t.backend.close();
      }
      if (t.state != "running") t.backend.close();
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
  }
  public function activeCount():Int {
    var active = 0;
    for (t in terminals) if (t.state == "running") active++;
    return active;
  }
  public function dispose():Void {
    for (t in terminals) {
      t.backend.close();
      t.emulator.close();
    }
    terminals.clear();
    count = 0;
  }
}
