package workspace.client;

import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;

import haxe.io.Bytes;
import haxe.Int64;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;

/** Client attachment only: close/detach never kills a service-owned shell. */
class RpcTerminalBackend implements TerminalBackend {
  final terminalId:String;
  final root:String;
  final group:Null<String>;
  final directory:Null<String>;
  final provider:Void -> Null<WorkspaceRpcEndpoint>;
  var create:Bool;
  var connection:Null<RpcConnection>;
  var instance:String = "";
  var attached:Bool = false;
  var controller:Bool = false;
  var controlled:Bool = false;
  var controlPending:Bool = false;
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
  var serverColumns:Int = 0;
  var serverRows:Int = 0;

  public function new(provider:Void -> Null<WorkspaceRpcEndpoint>, terminalId:String, root:String, create:Bool, ?group:String, ?directory:String) {
    this.provider = provider;
    this.terminalId = terminalId;
    this.root = root;
    this.create = create;
    this.group = group;
    this.directory = directory;
  }
  public function id():String return terminalId;
  public function isAttached():Bool return attached;
  public function canControl():Bool return controller;
  public function hasControlGrant():Bool {
    var client = provider();
    return client != null && client.hasCapability(WorkspaceTerminalProtocol.CONTROL);
  }
  public function controlStatus():String {
    if (!attached) return "Connecting to workspace terminal…";
    if (!hasControlGrant()) return "Read only · control permission was not granted";
    if (controlPending) return "Updating terminal control…";
    if (controller) return "You are controlling this terminal";
    if (controlled) return "Read only · another client controls this terminal";
    return "Read only · no client is controlling this terminal";
  }
  public function controlAction():String return !attached || !hasControlGrant() || controlPending ? "" : controller ? "Release" : "Take control";
  public function activateControl():Void setControl(!controller);
  function setControl(claim:Bool):Void {
    var c = connection;
    if (closed || !attached || c == null || !c.isOpen() || !hasControlGrant() || controlPending) return;
    controlPending = true;
    c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
      workspace: "workspace", instance: instance, id: terminalId,
      claim: claim, takeover: claim
    }, 2000, function(info) {
      if (closed || connection != c) {
        if (info.controller == true && c.isOpen()) c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
          workspace: "workspace", instance: instance, id: terminalId,
          claim: false, takeover: false
        }, 1000, function(_) {}, function(_) {});
        return;
      }
      controlPending = false;
      observe(info);
      if (controller) resizePending = true;
    }, function(error) {
      if (connection == c) controlPending = false;
      if (!closed && connection == c && error.code != "disconnected" && error.code != "timeout")
        fail(error.code);
    });
  }
  function observe(info:WorkspaceTerminalProtocol.TerminalInfo):Void {
    if (info.columns < 1 || info.columns > 512 || info.rows < 1 || info.rows > 256) {
      fail("Invalid terminal geometry");
      return;
    }
    var wasController = controller;
    controller = info.controller == true;
    controlled = info.controlled == true;
    if (controller && !wasController) resizePending = true;
    if (attached && !controller) {
      writes.resize(0);
      writeBytes = 0;
    }
    if (info.columns != serverColumns || info.rows != serverRows) {
      serverColumns = info.columns;
      serverRows = info.rows;
      output.push(TerminalEvent.geometry(serverColumns, serverRows));
    }
  }
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
    writes.resize(0);
    writeBytes = 0;
  }
  public function write(bytes:Bytes):Void {
    if (closed || failure != null) throw "Terminal is unavailable";
    if (attached && !controller) return;
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
        if (e.code == "terminal_controlled") loseControl();
        else fail((e.ambiguous ? "Terminal input delivery uncertain: " : "Terminal input refused: ") + e.code);
      }
    }
    );
  }
  public function resize(columns:Int, rows:Int):Void {
    if (columns < 1 || columns > 512 || rows < 1 || rows > 256) throw "Terminal size exceeds service limits";
    this.columns = columns;
    this.rows = rows;
    if (controller) resizePending = true;
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
      if (!closed && connection == c) {
        if (e.code == "terminal_controlled") loseControl();
        else fail(e.code);
      }
    }
    );
  }
  public function detach():Void close();
  function loseControl():Void {
    controller = false;
    controlled = true;
    writes.resize(0);
    writeBytes = 0;
    resizePending = false;
  }
  public function close():Void {
    closed = true;
    var c = connection;
    if (controller && c != null && c.isOpen()) c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
      workspace: "workspace", instance: instance, id: terminalId,
      claim: false, takeover: false
    }, 1000, function(_) {}, function(_) {});
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
    var clientFailure = client.failureReason();
    if (clientFailure != null) {
      fail(clientFailure);
      return;
    }
    var c = client.rootPath() == root ? client.rpcConnection() : null;
    if (c != connection) {
      if (writing) {
        fail("Terminal input delivery uncertain after disconnect");
        return;
      }
      connection = c;
      attached = false;
      pending = false;
      sequence = 0;
      controller = false;
      controlled = false;
      controlPending = false;
    }
    if (c != null && attached) flushInput(c);
    if (c != null && !pending) {
      if (instance.length > 0 && instance != client.serviceGeneration()) {
        fail("Terminal service restarted; session was lost");
        return;
      }
      instance = client.serviceGeneration();
      if (!attached) {
        if (create && (group != null || directory != null) && !client.supportsWorkspaceGroups()) { fail("Workspace service does not support grouped terminals"); return; }
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
          observe(info);
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
        }, 2000, function(info) {
          if (connection == c) {
            pending = false;
            observe(info);
          }
        }, function(e) {
          if (connection == c) {
            pending = false;
            if (e.code == "terminal_controlled") loseControl();
            else if (retryable(e.code)) resizePending = true;
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
          observe(value.terminal);
          output.push(TerminalEvent.output(position, value.data));
          position += value.data.length;
          output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
          nextRead = Sys.time() +(value.data.length == 0 ? 0.05 : 0);
        }, function(e) {
          if (!closed && connection == c) {
            pending = false;
            if (e.code == "replay_gap") requestScreenSnapshot(c);
            else if (!retryable(e.code)) fail(e.code);
          }
        }
        );
      }
    }
    var events = output;
    output = [];
    for (event in events) emit(event);
  }
  function requestScreenSnapshot(c:RpcConnection):Void {
    if (closed || connection != c || pending) return;
    pending = true;
    c.call(WorkspaceTerminalProtocol.SNAPSHOT, {
      workspace: "workspace", instance: instance, id: terminalId
    }, 3000, function(value) {
      if (closed || connection != c) return;
      pending = false;
      if (value.terminal == null || value.terminal.id != terminalId
          || value.terminal.end < position || value.terminal.end < value.terminal.start
          || value.data == null || value.data.length < 64 || value.data.length > 3 * 1024 * 1024
          || value.terminal.columns < 1 || value.terminal.columns > 512
          || value.terminal.rows < 1 || value.terminal.rows > 256) {
        fail("Invalid terminal screen snapshot");
        return;
      }
      observe(value.terminal);
      position = value.terminal.end;
      output.push(TerminalEvent.screenSnapshot(position, value.data));
      output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
      nextRead = 0;
    }, function(error) {
      if (connection != c) return;
      pending = false;
      if (!closed && !retryable(error.code)) fail(error.code == "snapshot_unavailable"
        ? "Terminal screen snapshot is unavailable" : error.code);
    });
  }
}
