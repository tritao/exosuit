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
  var synchronized:Bool = false;
  var synchronizationPending:Bool = false;
  var geometryReady:Bool;
  var observedColumns:Int = 0;
  var observedRows:Int = 0;
  var controller:Bool = false;
  var controlled:Bool = false;
  var controlPending:Bool = false;
  final autoClaimControl:Bool;
  var controlReleased:Bool = false;
  var controlUnavailable:Bool = false;
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
  var replayCursor:Int64 = 0;
  var snapshotOnly:Bool = false;
  var snapshotPending:Bool = false;
  var replayAfterResize:Bool = false;

  public function new(provider:Void -> Null<WorkspaceRpcEndpoint>, terminalId:String, root:String, create:Bool, ?group:String, ?directory:String, autoClaimControl:Bool = false, requireGeometry:Bool = false) {
    this.provider = provider;
    geometryReady = !requireGeometry;
    this.autoClaimControl = autoClaimControl;
    this.terminalId = terminalId;
    this.root = root;
    this.create = create;
    this.group = group;
    this.directory = directory;
  }
  public function id():String return terminalId;
  public function isAttached():Bool return attached;
  public function isSynchronized():Bool return synchronized;
  public function canControl():Bool return controller;
  public function hasControlGrant():Bool {
    var client = provider();
    return client != null && client.hasCapability(WorkspaceTerminalProtocol.CONTROL);
  }
  public function controlStatus():String {
    if (failure != null) return "Terminal unavailable: " + failure;
    if (!attached) {
      var endpoint = provider();
      if (endpoint != null && endpoint.rootPath() != null && endpoint.rootPath() != root)
        return "Open this terminal's workspace to reconnect: " + root;
      return "Connecting to workspace terminal…";
    }
    if (!synchronized) return "Loading terminal history…";
    if (controlUnavailable) return "Read only · update the workspace daemon to control this terminal";
    if (!hasControlGrant()) return "Read only · control permission was not granted";
    if (controlPending) return "Updating terminal control…";
    if (controller) return "You are controlling this terminal";
    if (controlled) return "Read only · another client controls this terminal";
    return "Read only · no client is controlling this terminal";
  }
  public function controlAction():String return !attached || !synchronized || controlUnavailable || !hasControlGrant() || controlPending ? "" : controller ? "Release" : "Take control";
  public function activateControl():Void {
    controlReleased = controller;
    setControl(!controller, true);
  }
  function setControl(claim:Bool, takeover:Bool = false):Void {
    var c = connection;
    if (closed || !attached || controlUnavailable || c == null || !c.isOpen() || !hasControlGrant() || controlPending) return;
    controlPending = true;
    c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
      workspace: "workspace", instance: instance, id: terminalId,
      claim: claim, takeover: claim && takeover
    }, 2000, function(info) {
      if (closed || connection != c) {
        if (info.controller == true && c.isOpen()) c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
          workspace: "workspace", instance: instance, id: terminalId,
          claim: false, takeover: false
        }, 1000, function(_) {}, function(_) {});
        return;
      }
      controlPending = false;
      if (!observe(info)) return;
    }, function(error) {
      if (connection == c) controlPending = false;
      if (!closed && connection == c) {
        if (error.code == "unknown_method") controlUnavailable = true;
        else if (error.code != "disconnected" && error.code != "timeout") fail(error.code);
      }
    });
  }
  function observe(info:WorkspaceTerminalProtocol.TerminalInfo):Bool {
    if (info.columns < 1 || info.columns > 512 || info.rows < 1 || info.rows > 256) {
      fail("Invalid terminal geometry");
      return false;
    }
    observedColumns = info.columns;
    observedRows = info.rows;
    controller = info.controller == true;
    controlled = info.controlled == true;
    resizePending = controller && (columns != observedColumns || rows != observedRows);
    if (attached && !controller) {
      writes.resize(0);
      writeBytes = 0;
    }
    if (autoClaimControl && !controlReleased && attached && !controlled && info.state == "running")
      setControl(true);
    return true;
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
    if (writing || writeBytes == 0 || resizePending || !synchronized) return;
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
    geometryReady = true;
    this.columns = columns;
    this.rows = rows;
    resizePending = controller && (columns != observedColumns || rows != observedRows);
  }
  public function requestReplay(offset:Int64):Void {
    // Byte offsets cannot identify geometry-only records. Recover atomically.
    snapshotPending = true;
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
    if (closed || !geometryReady) return;
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
      synchronized = false;
      synchronizationPending = false;
      pending = false;
      sequence = 0;
      controller = false;
      controlled = false;
      controlPending = false;
      controlUnavailable = false;
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
          if (!observe(info)) return;
          // Lifecycle follows drained replay, including when attaching after exit.
        }, function(e) {
          if (!closed && connection == c) {
            pending = false;
            if (!retryable(e.code)) fail(e.code);
          }
        }
        );
      } else if (snapshotPending) {
        requestScreenSnapshot(c);
      } else if (resizePending && !replayAfterResize) {
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
            if (!observe(info)) return;
            replayAfterResize = true;
            nextRead = 0;
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
        if (snapshotOnly) requestScreenSnapshot(c);
        else requestReplayBatch(c);
      }
    }
    var events = output;
    output = [];
    for (event in events) emit(event);
    // Readiness follows application to the emulator, never just receipt of an RPC reply.
    if (synchronizationPending) {
      synchronizationPending = false;
      synchronized = true;
    }
  }
  function requestReplayBatch(c:RpcConnection):Void {
    pending = true;
    var requested = replayCursor;
    c.call(WorkspaceTerminalProtocol.REPLAY, {
      workspace:"workspace", instance:instance, id:terminalId, cursor:requested
    }, 2000, function(value) {
      if (closed || connection != c) return;
      pending = false;
      if (value.terminal == null || value.terminal.id != terminalId || value.events == null
          || value.events.length > 128 || value.next != requested + value.events.length || value.next > value.end) {
        fail("Invalid terminal replay"); return;
      }
      var nextOffset = position, nextCursor = requested, bytes = 0;
      // Validate the whole batch before exposing any of it to the emulator.
      for (event in value.events) {
        if (event.sequence != nextCursor || event.offset != nextOffset || event.data == null
            || event.data.length > 65536) { fail("Invalid terminal replay order"); return; }
        if (event.data.length == 0) {
          if (event.columns < 1 || event.columns > 512 || event.rows < 1 || event.rows > 256) {
            fail("Invalid terminal replay geometry"); return;
          }
        } else if (event.columns != 0 || event.rows != 0) {
          fail("Invalid terminal replay output"); return;
        }
        bytes += event.data.length;
        nextOffset += event.data.length;
        nextCursor += 1;
      }
      if (bytes > 65536 || nextOffset > value.terminal.end) { fail("Invalid terminal replay bounds"); return; }
      if (!observe(value.terminal)) return;
      for (event in value.events) output.push(event.data.length == 0
        ? TerminalEvent.geometry(event.columns, event.rows) : TerminalEvent.output(event.offset, event.data));
      position = nextOffset;
      replayCursor = value.next;
      if (value.next == value.end) {
        synchronizationPending = true;
        output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
      }
      replayAfterResize = false;
      nextRead = Sys.time() + (value.events.length == 0 ? 0.05 : 0);
    }, function(error) {
      if (closed || connection != c) return;
      pending = false;
      if (error.code == "unknown_method") {
        // Older daemons have no ordered geometry history. Their atomic snapshots
        // are safe; combining current dimensions with historical bytes is not.
        snapshotOnly = true;
        snapshotPending = true;
      } else if (error.code == "replay_gap") snapshotPending = true;
      else if (!retryable(error.code)) fail(error.code);
    });
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
      if (!snapshotOnly && (value.cursor == null || value.cursor < replayCursor)) {
        fail("Invalid terminal snapshot cursor"); return;
      }
      if (!observe(value.terminal)) return;
      if (value.cursor != null) replayCursor = value.cursor;
      snapshotPending = false;
      synchronizationPending = true;
      replayAfterResize = false;
      position = value.terminal.end;
      output.push(TerminalEvent.screenSnapshot(position, value.data));
      output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
      nextRead = Sys.time() + (snapshotOnly ? 0.05 : 0);
    }, function(error) {
      if (connection != c) return;
      pending = false;
      if (!closed && !retryable(error.code)) fail(error.code == "snapshot_unavailable"
        ? "Terminal screen snapshot is unavailable" : error.code);
    });
  }
}
