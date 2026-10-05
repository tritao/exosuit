package workspace.client;

import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;

import haxe.io.Bytes;
import haxe.Int64;
import haxeon.rpc.RpcConnection;
import workspace.client.LocalWorkspaceClient;
import workspace.service.WorkspaceTerminalProtocol;

/** Client attachment only: close/detach never kills a service-owned shell. */
class RpcTerminalBackend implements TerminalBackend {
  final terminalId:String;
  final root:String;
  final group:Null<String>;
  final directory:Null<String>;
  final provider:Void -> Null<LocalWorkspaceClient>;
  var create:Bool;
  var connection:Null<RpcConnection>;
  var instance:String = "";
  var attached:Bool = false;
  var pending:Bool = false;
  var closed:Bool = false;
  var columns:Int = 80;
  var rows:Int = 24;
  var resizePending:Bool = false;
  var position:Int64 = 0;
  var sequence:Int = 0;
  final writes:Array<Bytes> = [];
  var writeBytes:Int = 0;
  var writing:Bool = false;
  var failure:Null<String>;
  var failureReported:Bool = false;
  var output:Array<TerminalEvent> = [];
  var nextRead:Float = 0;

  public function new(provider:Void -> Null<LocalWorkspaceClient>, terminalId:String, root:String, create:Bool, ?group:String, ?directory:String) {
    this.provider = provider;
    this.terminalId = terminalId;
    this.root = sys.FileSystem.fullPath(root);
    this.create = create;
    this.group = group;
    this.directory = directory;
  }
  public function id():String return terminalId;
  public function isAttached():Bool return attached;
  static function retryable(code:String):Bool return code == "timeout" || code == "disconnected";
  function fail(message:String):Void {
    message = switch (message) {
      case "unknown_terminal":
        "The terminal session is no longer available";
      case "replay_gap":
        "Terminal replay history has been trimmed; this view cannot be restored";
      case "unauthorized":
        "Terminal access denied";
      default:
        message;
    };
    failure = message;
    attached = false;
  }
  public function write(bytes:Bytes):Void {
    if (closed || failure != null) throw "Terminal is unavailable";
    if (bytes == null || bytes.length == 0) return;
    if (writeBytes + bytes.length > 65536) throw "Terminal input queue exceeds limit";
    writes.push(bytes.sub(0, bytes.length));
    writeBytes += bytes.length;
  }
  function flushInput(c:RpcConnection):Void {
    if (writing || writeBytes == 0 || resizePending) return;
    var bytes = writes.length == 1 ? writes[0] : Bytes.alloc(writeBytes);
    if (writes.length > 1) {
      var offset = 0;
      for (part in writes) {
        bytes.blit(offset, part, 0, part.length);
        offset += part.length;
      }
    }
    writes.resize(0);
    writeBytes = 0;
    writing = true;
    sequence++;
    c.call(WorkspaceTerminalProtocol.INPUT, {
      workspace: "workspace",
      instance: instance,
      id: terminalId,
      sequence: sequence,
      data: bytes
    }, 2000, function(_) {
      if (connection == c) writing = false;
    }, function(e) {
      if (connection == c) {
        writing = false;
        fail((e.ambiguous ? "Terminal input delivery uncertain: " : "Terminal input refused: ") + e.code);
      }
    }
    );
  }
  public function resize(columns:Int, rows:Int):Void {
    if (columns < 1 || columns > 512 || rows < 1 || rows > 256) throw "Terminal size exceeds service limits";
    this.columns = columns;
    this.rows = rows;
    resizePending = true;
  }
  public function requestReplay(offset:Int64):Void {
    position = offset;
    nextRead = 0;
  }
  public function terminate(force:Bool):Void {
    if (!force) {
      write(Bytes.ofString("\x03"));
      return;
    }
    var c = connection;
    if (c == null || !c.isOpen() || instance.length == 0) throw "Terminal is not connected";
    c.call(WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "workspace", instance: instance, id: terminalId}, 2000, function(_) {
    }, function(e) {
      if (!closed && connection == c) fail(e.code);
    }
    );
  }
  public function detach():Void close();
  public function close():Void {
    closed = true;
    connection = null;
    output.resize(0);
    writes.resize(0);
    writeBytes = 0;
  }
  public function pollEvents(emit:TerminalEvent -> Void):Void {
    if (closed) return;
    if (failure != null) {
      if (!failureReported) {
        failureReported = true;
        throw failure;
      }
      emit(TerminalEvent.status("failed"));
      return;
    }
    var client = provider();
    if (client == null) return;
    if (client.error != null) {
      fail(client.error);
      return;
    }
    var c = client.root == root ? client.rpc() : null;
    if (c != connection) {
      if (writing) {
        fail("Terminal input delivery uncertain after disconnect");
        return;
      }
      connection = c;
      attached = false;
      pending = false;
      sequence = 0;
    }
    if (c != null && attached) flushInput(c);
    if (c != null && !pending) {
      if (instance.length > 0 && instance != client.instance) {
        fail("Terminal service restarted; session was lost");
        return;
      }
      instance = client.instance;
      if (!attached) {
        if (create && (group != null || directory != null) && !client.hasGroupTree()) { fail("Workspace service does not support grouped terminals"); return; }
        pending = true;
        c.call(WorkspaceTerminalProtocol.OPEN, {
          workspace: "workspace",
          instance: instance,
          id: terminalId,
          create: create,
          columns: columns,
          rows: rows,
          group: group, directory: directory
        }, 2000, function(info) {
          if (closed || connection != c) return;
          pending = false;
          attached = true;
          create = false;
          output.push(TerminalEvent.status(info.state, info.exitCode));
        }, function(e) {
          if (!closed && connection == c) {
            pending = false;
            if (!retryable(e.code)) fail(e.code);
          }
        }
        );
      } else if (resizePending) {
        resizePending = false;
        pending = true;
        c.call(WorkspaceTerminalProtocol.RESIZE, {
          workspace: "workspace",
          instance: instance,
          id: terminalId,
          columns: columns,
          rows: rows
        }, 2000, function(_) {
          if (connection == c) pending = false;
        }, function(e) {
          if (connection == c) {
            pending = false;
            if (retryable(e.code)) resizePending = true;
            else fail(e.code);
          }
        }
        );
      } else if (Sys.time() >= nextRead) {
        pending = true;
        c.call(WorkspaceTerminalProtocol.OUTPUT, {
          workspace: "workspace",
          instance: instance,
          id: terminalId,
          offset: position
        }, 2000, function(value) {
          if (closed || connection != c) return;
          pending = false;
          if (value.offset != position || value.terminal.id != terminalId) {
            fail("Invalid terminal replay");
            return;
          }
          output.push(TerminalEvent.output(position, value.data));
          position += value.data.length;
          output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
          nextRead = Sys.time() +(value.data.length == 0 ? 0.05 : 0);
        }, function(e) {
          if (!closed && connection == c) {
            pending = false;
            if (!retryable(e.code)) fail(e.code);
          }
        }
        );
      }
    }
    var events = output;
    output = [];
    for (event in events) emit(event);
  }
}
