package workspace.runtime;

import haxe.io.Bytes;
import haxe.Int64;
import haxeon.rpc.*;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceTerminals;
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

  public function new(workspace:String, instance:String, root:String, historyLimit:Int = 16777216) {
    this.workspace = workspace;
    this.instance = instance;
    this.root = root;
    if (historyLimit < 65536 || historyLimit > 16777216) throw "Invalid terminal history limit";
    this.historyLimit = historyLimit;
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
        if (count >= 16) {
          c.fail(error("terminal_limit"));
          return;
        }
        try {
          t = new RuntimeTerminal(
            r.id,
            LocalPtyBackend.spawn(TerminalProfile.shell(root), r.columns, r.rows),
            r.columns,
            r.rows
          );
          terminals.set(r.id, t);
          count++;
        } catch (_:Dynamic) {
          c.fail(error("terminal_spawn_failed"));
          return;
        }
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
