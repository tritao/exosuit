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
  var agentProvider:Null<String>;
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
  var controlOffered:Bool = false;
  var terminalState:String = "running";
  var historyError:Bool = false;
  var historyAvailable:Bool = true;
  var restartable:Bool = false;
  var restartError:Null<String>;
  var pending:Bool = false;
  var closed:Bool = false;
  var columns:Int = 80;
  var rows:Int = 24;
  var resizePending:Bool = false;
  var theme:Null<TerminalTheme>;
  var themePending:Bool = false;
  var position:Int64 = 0;
  var sequence:Int = 0;
  final writes:Array<Bytes> = [];
  var writeBytes:Int = 0;
  var writing:Bool = false;
  var failure:Null<String>;
  public var name(default, null):Null<String>;
  var failureReported:Bool = false;
  var output:Array<TerminalEvent> = [];
  var nextRead:Float = 0;
  var interactiveUntil:Float = 0; // Legacy daemons only.
  var eventDriven:Bool = false;
  var replayDirty:Bool = true;
  var releaseEvents:Null<Void->Bool>;
  var replayCursor:Int64 = 0;
  var snapshotOnly:Bool = false;
  var snapshotPending:Bool = false;
  // Counts attachments. Retry attaches again on the same RpcConnection object, so the connection alone does not tell a
  // reply to a call of the failed attachment from one of the new: every callback also compares the count it started under.
  var attachEpoch:Int = 0;
  inline function current(c:RpcConnection, epoch:Int):Bool return connection == c && attachEpoch == epoch;
  // The next snapshot also brings the lines above the screen: set whenever this view's own scrollback cannot be
  // trusted (it just attached, or output was lost to a replay gap).
  var historyWanted:Bool = false;
  // A new service generation owns the terminal: what this view shows is replaced when that service's history and screen
  // arrive, in one step, and stays on screen until then.
  var resetPending:Bool = false;
  static inline final HISTORY_LIMIT = 16 * 1024 * 1024; // terminalkit_history_copy's bound
  static inline final SCREEN_LIMIT = 3 * 1024 * 1024;
  // Expired paged snapshots in a row, and when the next attempt may start.
  var snapshotExpiries:Int = 0;
  var snapshotRetryAt:Float = 0;
  var replayAfterResize:Bool = false;
  // Geometry of the service's recorded stream, as last applied to the emulator.
  var streamColumns:Int = 0;
  var streamRows:Int = 0;
  // Local view geometry of an ended terminal (0 = follows the stream). No PTY or
  // future output depends on it, so the saved history is drawn at the pane's size
  // without rewriting the service's record for other viewers.
  var viewColumns:Int = 0;
  var viewRows:Int = 0;

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
  static final CLIENT_KEY = "EXOSUIT_TERMINAL_CLIENT_KEY";
  /** Names this client process, so the service can tell a pane that replaced an old attachment from another client.
      Random and kept in the process environment: statics do not survive a live module reload, the environment does.
      The value is `<pid>:<key>` and counts only in the process that made it: every child (suit, services, their
      shells, an editor run from one of those) inherits the variable, and must not take terminal control as this
      editor without the takeover prompt. */
  static function clientKey():String {
    var owner = Sys.getPid() + ":";
    var value = Sys.getEnv(CLIENT_KEY);
    if (value != null && StringTools.startsWith(value, owner) && value.length > owner.length)
      return value.substr(owner.length);
    var key = haxe.crypto.Sha256.encode(Sys.time() + ":" + Math.random() + ":" + Sys.getPid()).substr(0, 32);
    Sys.putEnv(CLIENT_KEY, owner + key);
    return key;
  }
  /** For a host whose app process is killed and started again (the phone): the key persists across processes, so the
      service sees a restarted client as the same one and lets it replace its own old control lease. It still counts only
      in this process (see clientKey), like a generated one. Call before the first terminal opens. */
  public static function adoptClientKey(key:String):Void {
    if (key == null || key.length < 16 || key.length > 128) return;
    Sys.putEnv(CLIENT_KEY, Sys.getPid() + ":" + key);
  }
  public function id():String return terminalId;
  /** A Claude Code or Codex terminal: restarting it continues the same conversation. */
  public function resumesConversation():Bool return agentProvider == "claude" || agentProvider == "codex";
  public function configureAgent(provider:String):Void {
    if (!create || attached || pending || ["codex","claude","pi"].indexOf(provider) < 0)
      throw "Agent launch mode must be selected before creating the terminal";
    agentProvider = provider;
  }
  public function isAttached():Bool return attached;
  public function usesNotifications():Bool return eventDriven;
  /** False once the terminal failed or closed: write throws, so input must not reach it. */
  public function isAvailable():Bool return !closed && failure == null;
  public function isSynchronized():Bool return synchronized;
  public function canControl():Bool return controller && terminalState == "running";
  public function hasControlGrant():Bool {
    var client = provider();
    return client != null && client.hasCapability(WorkspaceTerminalProtocol.CONTROL);
  }
  /** Normal writable sessions need no persistent control notice. */
  public function needsControlNotice():Bool
    return failure != null || !attached || !synchronized || historyError || terminalState != "running" || controlUnavailable || !hasControlGrant() || controlPending || !controller;
  public function controlStatus():String {
    if (failure != null) return "Terminal unavailable: " + failure;
    if (!attached) {
      var endpoint = provider();
      if (endpoint != null && endpoint.rootPath() != null && !serves(endpoint))
        return "Open this terminal's workspace to reconnect: " + root;
      return "Connecting to workspace terminal…";
    }
    if (!synchronized) return "Loading terminal history…";
    if (historyError) return "Terminal history could not be saved";
    if (terminalState == "starting") return "Starting terminal…";
    if (terminalState != "running") {
      if (controlPending) return "Restarting terminal…";
      if (restartError != null) return restartError;
      if (!hasControlGrant()) return "Session ended · restarting requires terminal control permission";
      if (!restartable || controlUnavailable) return "Session ended · update the workspace service in Remote Access to restart";
      return historyAvailable ? "Session ended · saved history" : "Session ended · no saved history";
    }
    if (controlUnavailable) return "Read only · update the workspace daemon to control this terminal";
    if (!hasControlGrant()) return "Read only · control permission was not granted";
    if (controlPending) return "Updating terminal control…";
    if (controller) return "You are controlling this terminal";
    if (asking()) return "Take control back?";
    if (controlled) return "Read only · another client controls this terminal";
    return "Read only · no client is controlling this terminal";
  }
  public function controlAction():String return failure != null ? (closed ? "" : "Retry") : !attached || !synchronized || controlUnavailable || !hasControlGrant() || controlPending || terminalState == "starting" ? "" : terminalState != "running" ? (restartable ? "Restart Terminal" : "") : controller ? "Release" : "Take control";
  /** This view holds the terminal's control lease. */
  public function isController():Bool return attached && controller;
  /** For a host that held control before its process was killed and reopens the terminal by itself (the phone): another
      client (the editor) may have claimed the freed lease meanwhile, and this view must ask its person before taking it
      back. Call right after opening. While the question is open the notice reads "Take control back?" with Take control
      (activateControl, the usual takeover) and Not now (declineControl), and the view does not claim a lease that falls
      free by itself. A view the service puts in control when it opens (nobody else held the lease) has nothing to ask. */
  public function offerControlBack():Void controlOffered = true;
  /** The offer was made and is not answered yet (it may not be on screen yet: the view is still attaching). */
  public function controlOfferOpen():Bool return controlOffered;
  /** Label of the action that answers the offer with no; "" while no question is on screen. */
  public function controlDeclineAction():String return asking() ? "Not now" : "";
  /** The person keeps observing: the view is an ordinary observer with Take control from here on, and does not claim a free lease. */
  public function declineControl():Void {
    if (!controlOffered) return;
    controlOffered = false;
    controlReleased = true;
  }
  function asking():Bool
    return controlOffered && failure == null && attached && synchronized && !historyError && terminalState == "running" && !controlUnavailable && hasControlGrant() && !controlPending && !controller;
  /** Attaches again after a failure, from the service's current screen, as a view that was just opened does. */
  function retry():Void {
    if (closed || failure == null) return;
    failure = null;
    failureReported = false;
    if (releaseEvents != null) { releaseEvents(); releaseEvents = null; }
    // The next poll sees a new connection and an unknown service generation: it resets the view and opens the terminal again.
    connection = null;
    attachEpoch++;
    resumePages = null;
    instance = "retry";
    writing = false;
    pending = false;
    snapshotRetryAt = 0;
    snapshotExpiries = 0;
  }
  public function activateControl():Void {
    if (failure != null) { retry(); return; }
    if (terminalState != "running") { restartShell(); return; }
    controlReleased = controller;
    setControl(!controller, true);
  }
  function restartShell():Void {
    var c = connection;
    var epoch = attachEpoch;
    if (closed || !attached || !synchronized || !restartable || controlPending || c == null || !c.isOpen() || !hasControlGrant()) return;
    controlPending = true; restartError = null;
    var owner = instance;
    WorkspaceTerminalRestart.request(c,owner,terminalId,theme,
      function() return !closed && current(c, epoch) && instance == owner && hasControlGrant(), function(info) {
      if (closed || !current(c, epoch)) return;
      controlPending = false;
      if (!observe(info)) return;
      replayDirty = true; nextRead = 0;
    }, function(error) {
      if (closed || !current(c, epoch)) return;
      controlPending = false;
      // Another viewer may have restarted it first. Refresh rather than retry input.
      replayDirty = true; nextRead = 0;
      if (error.code != "terminal_running") restartError = WorkspaceTerminalRestart.message(error);
      if (error.code == "unknown_method" || error.code == "unsupported") restartable = false;
    });
  }
  function setControl(claim:Bool, takeover:Bool = false):Void {
    var c = connection;
    var epoch = attachEpoch;
    if (closed || !attached || controlUnavailable || c == null || !c.isOpen() || !hasControlGrant() || controlPending) return;
    controlPending = true;
    c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
      workspace: "workspace", instance: instance, id: terminalId,
      claim: claim, takeover: claim && takeover, clientKey: clientKey()
    }, 2000, function(info) {
      if (closed || !current(c, epoch)) {
        if (info.controller == true && c.isOpen()) c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
          workspace: "workspace", instance: instance, id: terminalId,
          claim: false, takeover: false
        }, 1000, function(_) {}, function(_) {});
        return;
      }
      controlPending = false;
      if (!observe(info)) return;
    }, function(error) {
      if (current(c, epoch)) controlPending = false;
      if (!closed && current(c, epoch)) {
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
    if (info.name != null && StringTools.trim(info.name) != "") name = info.name;
    observedRows = info.rows;
    terminalState = info.state;
    if (terminalState == "running") restartError = null;
    if (info.agentProvider != null) agentProvider = info.agentProvider;
    historyError = info.historyError == true;
    historyAvailable = info.historyAvailable != false;
    restartable = info.restartable == true;
    if (!controller && info.controller == true && theme != null) themePending = true;
    controller = info.controller == true;
    controlled = info.controlled == true;
    // In control (the service gave it at open, or the person took it), or nothing left to control: the offer is answered.
    if (controller || ended()) controlOffered = false;
    resizePending = terminalState == "running" && controller && (columns != observedColumns || rows != observedRows);
    if (terminalState == "running" || terminalState == "starting") restoreStreamGeometry();
    if (attached && !controller) {
      writes.resize(0);
      writeBytes = 0;
    }
    if (autoClaimControl && !controlReleased && !controlOffered && attached && !controlled && info.state == "running")
      setControl(true);
    return true;
  }
  /** Whether `endpoint`'s service holds this terminal: same root, or a workspace service serving this root among its folders. */
  function serves(endpoint:WorkspaceRpcEndpoint):Bool {
    if (endpoint.rootPath() == root) return true;
    if (!Std.isOfType(endpoint, ServedRoots)) return false;
    var served:ServedRoots = cast endpoint;
    return served.servesRoot(root);
  }
  static inline final SNAPSHOT_RETRIES = 6;
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
    terminalsession.TerminalLatencyTrace.mark("terminal.input.queued");
    writeBytes += bytes.length;
    interactiveUntil = Sys.time() + 0.25;
    nextRead = 0;
    var c = connection;
    if (c != null && c.isOpen()) flushInput(c);
  }
  function flushInput(c:RpcConnection):Void {
    var epoch = attachEpoch;
    if (writing || writeBytes == 0 || resizePending || themePending || !synchronized || !attached || !controller) return;
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
    terminalsession.TerminalLatencyTrace.mark("terminal.input.sent");
    c.call(WorkspaceTerminalProtocol.INPUT, {
      workspace: "workspace",
      instance: instance,
      id: terminalId,
      sequence: sequence,
      data: bytes
    }, 2000, function(_) {
      if (current(c, epoch)) {
        writing = false;
        terminalsession.TerminalLatencyTrace.mark("terminal.input.acknowledged");
        nextRead = 0;
        flushInput(c);
      }
    }, function(e) {
      if (current(c, epoch)) {
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
    resizePending = controller && terminalState == "running" && (columns != observedColumns || rows != observedRows);
  }
  function ended():Bool return terminalState != "running" && terminalState != "starting";
  /** Put the emulator back on the recorded grid before more recorded events reach it. */
  function restoreStreamGeometry():Void {
    if (viewColumns == 0) return;
    viewColumns = 0; viewRows = 0;
    // Before any recorded geometry arrives, the service's current grid is the stream's.
    output.push(streamColumns > 0 ? TerminalEvent.geometry(streamColumns, streamRows)
      : TerminalEvent.geometry(observedColumns, observedRows));
  }
  /** An ended terminal has no PTY to resize; fit its view to the pane locally. */
  function fitEndedView():Void {
    // Wait for the whole catch-up, so a multi-page replay is not refitted between pages.
    if (!synchronized || !ended() || pending || replayDirty || output.length > 0 || snapshotPending) return;
    var currentColumns = viewColumns > 0 ? viewColumns : streamColumns;
    var currentRows = viewColumns > 0 ? viewRows : streamRows;
    if (columns == currentColumns && rows == currentRows) return;
    if (columns == streamColumns && rows == streamRows) { restoreStreamGeometry(); return; }
    viewColumns = columns; viewRows = rows;
    output.push(TerminalEvent.geometry(columns, rows));
  }
  public function requestReplay(offset:Int64):Void {
    // Byte offsets cannot identify geometry-only records. Recover atomically.
    snapshotPending = true;
    replayDirty = true;
    nextRead = 0;
  }
  /** Only the controlling attachment configures the service's VT query replies. */
  public function setDefaultColors(foreground:Int, background:Int):Void {
    if (theme != null && theme.foreground == foreground && theme.background == background) return;
    theme = {foreground:foreground, background:background};
    themePending = true;
  }
  public function terminate(force:Bool):Void {
    if (!force) {
      write(Bytes.ofString("\x03"));
      return;
    }
    var c = connection;
    if (c == null || !c.isOpen() || instance.length == 0) throw "Terminal is not connected";
    var epoch = attachEpoch;
    c.call(WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "workspace", instance: instance, id: terminalId}, 2000, function(_) {
    }, function(e) {
      if (!closed && current(c, epoch)) {
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
    if (closed) return;
    closed = true;
    var lastListener = releaseEvents == null || releaseEvents();
    releaseEvents = null;
    var c = connection;
    if (lastListener && eventDriven && c != null && c.isOpen()) c.call(WorkspaceTerminalProtocol.UNWATCH,
      {workspace:"workspace", instance:instance, id:terminalId}, 1000, function(_) {}, function(_) {});
    if (lastListener && controller && c != null && c.isOpen()) c.call(WorkspaceTerminalProtocol.SET_CONTROL, {
      workspace: "workspace", instance: instance, id: terminalId,
      claim: false, takeover: false
    }, 1000, function(_) {}, function(_) {});
    resumePages = null;
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
    var c = serves(client) ? client.rpcConnection() : null;
    var epoch = attachEpoch;
    if (c != connection) {
      if (writing) {
        fail("Terminal input delivery uncertain after disconnect");
        return;
      }
      if (releaseEvents != null) { releaseEvents(); releaseEvents = null; }
      connection = c;
      eventDriven = false;
      replayDirty = true;
      var events = c == null ? null : client.terminalEvents();
      if (events != null) releaseEvents = events.listen(terminalId, function(event) {
        if (closed || !current(c, epoch) || event.workspace != "workspace" || event.instance != instance) return;
        replayDirty = true;
        nextRead = 0;
      });
      attached = false;
      synchronized = false;
      synchronizationPending = false;
      pending = false;
      sequence = 0;
      controller = false;
      controlled = false;
      controlPending = false;
      controlUnavailable = false;
      restartError = null;
    }
    if (c != null && attached) flushInput(c);
    if (resumePages != null) { var resume = resumePages; resumePages = null; resume(); }
    if (c != null && !pending) {
      if (instance.length > 0 && instance != client.serviceGeneration()) {
        // A new owner can provide persisted history, but must never receive
        // input queued for the old shell. Its replay has an independent cursor.
        writes.resize(0); writeBytes = 0;
        position = 0; replayCursor = 0;
        viewColumns = 0; viewRows = 0; streamColumns = 0; streamRows = 0;
        output = [];
        resetPending = true;
        snapshotOnly = false; snapshotPending = true; replayAfterResize = false;
        replayDirty = true; nextRead = 0;
      }
      instance = client.serviceGeneration();
      if (!attached) {
        if (create && (group != null || directory != null) && !client.supportsWorkspaceGroups()) { fail("Workspace service does not support grouped terminals"); return; }
        pending = true;
        var router = client.terminalEvents();
        var creating = create;
        ConnectTimeline.mark("terminal-open", root, terminalId);
        c.call(WorkspaceTerminalProtocol.OPEN, {
          workspace: "workspace",
          instance: instance,
          id: terminalId,
          create: create,
          columns: columns,
          rows: rows,
          group: group, directory: directory, watch: true, paced: true, theme: theme, agentProvider: agentProvider,
          clientKey: autoClaimControl ? clientKey() : null
        }, 2000, function(info) {
          // The daemon owns the resource even if its view closed before the reply.
          // Keep this on the captured connection's router across reconnects.
          if (creating && router != null && info.id == terminalId) router.invalidateCatalog();
          if (closed || !current(c, epoch)) {
            if (info.notifications == true && c.isOpen() && router != null && !router.hasListeners(terminalId)) {
              c.call(WorkspaceTerminalProtocol.UNWATCH, {workspace:"workspace", instance:instance, id:terminalId},
                1000, function(_) {}, function(_) {});
              if (info.controller == true) c.call(WorkspaceTerminalProtocol.SET_CONTROL,
                {workspace:"workspace", instance:instance, id:terminalId, claim:false, takeover:false},
                1000, function(_) {}, function(_) {});
            }
            return;
          }
          pending = false;
          attached = true;
          eventDriven = info.notifications == true && releaseEvents != null;
          create = false;
          // Every attach starts from the service's history and current screen; replay continues from its cursor.
          snapshotPending = true;
          historyWanted = true;
          if (!observe(info)) return;
          // Lifecycle follows the applied snapshot, including when attaching after exit.
        }, function(e) {
          if (!closed && current(c, epoch)) {
            pending = false;
            if (!retryable(e.code)) fail(e.message == null || StringTools.trim(e.message) == "" ? e.code : e.message);
          }
        }
        );
      } else if (snapshotPending) {
        if (Sys.time() >= snapshotRetryAt) requestScreenSnapshot(c);
      } else if ((resizePending || themePending && controller && terminalState == "running") && !replayAfterResize) {
        resizePending = false;
        themePending = false;
        pending = true;
        c.call(WorkspaceTerminalProtocol.RESIZE, {
          workspace: "workspace",
          instance: instance,
          id: terminalId,
          columns: columns,
          rows: rows,
          theme: theme
        }, 2000, function(info) {
          if (current(c, epoch)) {
            pending = false;
            if (!observe(info)) return;
            replayAfterResize = true;
            replayDirty = true;
            nextRead = 0;
          }
        }, function(e) {
          if (current(c, epoch)) {
            pending = false;
            if (e.code == "terminal_controlled") loseControl();
            else if (retryable(e.code)) { resizePending = true; themePending = theme != null; }
            else fail(e.code);
          }
        }
        );
      } else if ((!eventDriven || replayDirty) && Sys.time() >= nextRead) {
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
    fitEndedView();
    if (output.length > 0) {
      var local = output;
      output = [];
      for (event in local) emit(event);
    }
  }
  // Keep polling for asynchronous shell echo after input, then resume idle backoff.
  function idleReadDelay():Float return eventDriven || Sys.time() < interactiveUntil ? 0 : 0.05;

  /** What a REPLAY reply can take on the wire: 64 KiB of data and its framing. */
  static inline final REPLAY_RESERVE = 65536 + 1024;
  /** What a first snapshot page can take (a local page is 128 KiB) and its framing. */
  static inline final SNAPSHOT_RESERVE = 128 * 1024 + 1024;

  function requestReplayBatch(c:RpcConnection):Void {
    var epoch = attachEpoch;
    // Other views on this connection have replies in flight up to the budget: stay dirty and ask again shortly.
    if (!TerminalReplyBudget.reserve(c, REPLAY_RESERVE)) { replayDirty = true; nextRead = Sys.time() + 0.05; return; }
    pending = true;
    replayDirty = false;
    var requested = replayCursor;
    terminalsession.TerminalLatencyTrace.mark("terminal.replay.requested");
    c.call(WorkspaceTerminalProtocol.REPLAY, {
      workspace:"workspace", instance:instance, id:terminalId, cursor:requested
    }, 2000, function(value) {
      TerminalReplyBudget.release(c, REPLAY_RESERVE);
      if (closed || !current(c, epoch)) return;
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
      terminalsession.TerminalLatencyTrace.mark("terminal.replay.received");
      if (value.events.length > 0) restoreStreamGeometry();
      for (event in value.events) {
        if (event.data.length == 0) { streamColumns = event.columns; streamRows = event.rows; }
        output.push(event.data.length == 0
          ? TerminalEvent.geometry(event.columns, event.rows) : TerminalEvent.output(event.offset, event.data));
      }
      position = nextOffset;
      replayCursor = value.next;
      if (value.next < value.end) replayDirty = true;
      if (value.next == value.end) {
        synchronizationPending = true;
        output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
      }
      replayAfterResize = false;
      nextRead = Sys.time() + (value.events.length == 0 ? idleReadDelay() : 0);
    }, function(error) {
      TerminalReplyBudget.release(c, REPLAY_RESERVE);
      if (closed || !current(c, epoch)) return;
      pending = false;
      replayDirty = true;
      if (error.code == "unknown_method") {
        // Older daemons have no ordered geometry history. Their atomic snapshots
        // are safe; combining current dimensions with historical bytes is not.
        snapshotOnly = true;
        snapshotPending = true;
      } else if (error.code == "replay_gap") { snapshotPending = true; historyWanted = true; }
      else if (!retryable(error.code)) fail(error.code);
    });
  }
  function requestScreenSnapshot(c:RpcConnection):Void {
    var epoch = attachEpoch;
    if (closed || !current(c, epoch) || pending) return;
    resumePages = null;
    if (!TerminalReplyBudget.reserve(c, SNAPSHOT_RESERVE)) { nextRead = Sys.time() + 0.05; return; }
    pending = true;
    replayDirty = false;
    requestSnapshotPage(c, null, null, 0);
  }
  /** Reads the snapshot page by page: `head` is its first page, `data` holds the `offset` bytes read so far. */
  function requestSnapshotPage(c:RpcConnection, head:Null<WorkspaceTerminalProtocol.TerminalScreenSnapshot>, data:Null<Bytes>, offset:Int):Void {
    var epoch = attachEpoch;
    var token = head == null ? 0 : head.token;
    c.call(WorkspaceTerminalProtocol.SNAPSHOT, {
      workspace: "workspace", instance: instance, id: terminalId, token: token, offset: offset,
      history: head == null && historyWanted ? true : null
    }, 3000, function(value) {
      if (head == null) TerminalReplyBudget.release(c, SNAPSHOT_RESERVE);
      if (closed || !current(c, epoch)) return;
      if (value.total == null) {
        // Older daemons send the whole snapshot in one reply.
        pending = false;
        if (head != null) fail("Invalid terminal screen snapshot");
        else applyScreenSnapshot(value, value.data);
        return;
      }
      var first = head == null ? value : head;
      var total:Int = first.total == null ? -1 : first.total;
      var pageToken:Int = value.token == null ? -1 : value.token;
      var historyBytes:Int = first.history == null ? 0 : first.history;
      if (value.data == null || pageToken < 0 || value.token != first.token || value.offset != offset
          || historyBytes < 0 || historyBytes > HISTORY_LIMIT || historyBytes > total - 64
          || value.total != total || total < 64 || total - historyBytes > SCREEN_LIMIT
          || value.data.length == 0 || value.data.length > total - offset
          || (offset + value.data.length < total && pageToken == 0)) {
        pending = false;
        fail("Invalid terminal screen snapshot");
        return;
      }
      var bytes = data == null ? Bytes.alloc(total) : data;
      bytes.blit(offset, value.data, 0, value.data.length);
      var filled = offset + value.data.length;
      if (filled < total) {
        // The service cuts every page but the last at the first page's size: the rest is read through a window of requests.
        requestRemainingPages(c, first, bytes, filled, value.data.length);
        return;
      }
      pending = false;
      ConnectTimeline.mark("terminal-shown", root, terminalId + " " + total + " bytes");
      applyScreenSnapshot(first, bytes);
    }, function(error) {
      if (head == null) TerminalReplyBudget.release(c, SNAPSHOT_RESERVE);
      snapshotFailed(c, epoch, error);
    });
  }

  /**
    Snapshot pages kept in flight at once. A 10000-line history is up to 16 MiB: 128 pages on a local connection, 512 over
    a remote one; read one round trip after another that was hundreds of sequential calls per tab open.
  **/
  static inline final PARALLEL_PAGES = 16;
  /**
    The most page bytes in flight at once. The service answers as fast as it can, and a NativeKit connection closes
    when more than its 1 MiB receive buffer waits unread (NativeRpcHub.local): 16 local pages of 128 KiB did that to a
    view of a long coloured history, which then never attached. Half the buffer: 4 local pages, 16 remote ones.
  **/
  static inline final PARALLEL_BYTES = 512 * 1024;

  /**
    Reads the pages of a snapshot after the first through a window of PARALLEL_PAGES requests, asked for in order (the
    service drops the snapshot once its last page is read, and one connection answers in order): each page that arrives
    lets the next one be asked for. The snapshot is applied when all have come; the first failure ends it.
  **/
  function requestRemainingPages(c:RpcConnection, first:WorkspaceTerminalProtocol.TerminalScreenSnapshot, bytes:Bytes, from:Int, size:Int):Void {
    var epoch = attachEpoch;
    var total:Int = first.total == null ? 0 : first.total;
    var left = Math.ceil((total - from) / size), failed = false;
    var offset = from;
    var reserved = size + 1024;
    var ask:Void->Bool = null;
    // Each page takes `reserved` bytes of the connection's budget until it arrives. When the budget is used up the
    // request waits for the next poll (`resumePages`) instead of being sent.
    ask = function() {
      if (offset >= total || failed || closed || !current(c, epoch)) return true;
      if (!TerminalReplyBudget.reserve(c, reserved)) { resumePages = ask; return false; }
      var at = offset, length = total - at < size ? total - at : size;
      offset += length;
      c.call(WorkspaceTerminalProtocol.SNAPSHOT, {
        workspace: "workspace", instance: instance, id: terminalId, token: first.token, offset: at, history: null
      }, 3000, function(value) {
        TerminalReplyBudget.release(c, reserved);
        if (failed || closed || !current(c, epoch)) return;
        if (value.data == null || value.token != first.token || value.offset != at || value.total != total
            || value.data.length != length) {
          failed = true;
          pending = false;
          fail("Invalid terminal screen snapshot");
          return;
        }
        bytes.blit(at, value.data, 0, length);
        left--;
        if (left > 0) { ask(); return; }
        pending = false;
        ConnectTimeline.mark("terminal-shown", root, terminalId + " " + total + " bytes");
        applyScreenSnapshot(first, bytes);
      }, function(error) {
        TerminalReplyBudget.release(c, reserved);
        if (failed) return;
        failed = true;
        snapshotFailed(c, epoch, error);
      });
      return true;
    };
    var parallel = size >= PARALLEL_BYTES ? 1 : Std.int(PARALLEL_BYTES / size);
    for (_ in 0...(parallel > PARALLEL_PAGES ? PARALLEL_PAGES : parallel)) if (!ask()) break;
  }
  /** Set while a page request waits for the connection's reply budget: tried again on every poll. */
  var resumePages:Null<Void->Bool>;

  function snapshotFailed(c:RpcConnection, epoch:Int, error:Dynamic):Void {
      if (!current(c, epoch)) return;
      pending = false;
      replayDirty = true;
      if (closed) return;
      if (error.code == "snapshot_expired") {
        // The service dropped the rest before it was read: take a new one, waiting longer each time
        // so many views do not keep pushing out each other's snapshots.
        snapshotExpiries += 1;
        if (snapshotExpiries > SNAPSHOT_RETRIES) {
          fail("Terminal screen snapshot kept expiring before it was read");
          return;
        }
        snapshotRetryAt = Sys.time() + 0.1 * Math.pow(2, snapshotExpiries - 1) * (1 + Math.random());
        nextRead = snapshotRetryAt;
      } else if (!retryable(error.code)) fail(error.code == "snapshot_unavailable"
        ? "Terminal screen snapshot is unavailable" : error.code);
  }
  /** The viewer shows the service's screen as of the snapshot, then replays from the cursor it was taken at. */
  function applyScreenSnapshot(value:WorkspaceTerminalProtocol.TerminalScreenSnapshot, data:Bytes):Void {
    // A service that was asked for the history sends it ahead of the screen (see TerminalScreenSnapshot.history).
    var historyBytes:Int = value.history == null || value.total == null ? 0 : value.history;
    var history:Null<Bytes> = null;
    if (data != null && historyBytes > 0 && historyBytes <= HISTORY_LIMIT && historyBytes <= data.length - 64) {
      history = data.sub(0, historyBytes);
      data = data.sub(historyBytes, data.length - historyBytes);
    } else if (historyBytes != 0) data = null;
    if (value.terminal == null || value.terminal.id != terminalId
        || value.terminal.end < position || value.terminal.end < value.terminal.start
        || data == null || data.length < 64 || data.length > SCREEN_LIMIT
        || value.terminal.columns < 1 || value.terminal.columns > 512
        || value.terminal.rows < 1 || value.terminal.rows > 256) {
      fail("Invalid terminal screen snapshot");
      return;
    }
    // Daemons without a snapshot cursor have no ordered replay either: they are read by snapshots alone.
    if (value.cursor == null) snapshotOnly = true;
    else if (value.cursor < replayCursor) { fail("Invalid terminal snapshot cursor"); return; }
    if (!observe(value.terminal)) return;
    if (value.cursor != null) replayCursor = value.cursor;
    snapshotPending = false;
    snapshotExpiries = 0;
    snapshotRetryAt = 0;
    synchronizationPending = true;
    replayAfterResize = false;
    position = value.terminal.end;
    // The snapshot carries its own grid and replaces any local view geometry.
    viewColumns = 0; viewRows = 0;
    streamColumns = value.terminal.columns; streamRows = value.terminal.rows;
    historyWanted = false;
    // The history replaces the view's content by itself; without one (an older service) the view is cleared first.
    if (resetPending && history == null) output.push(TerminalEvent.resetReplay());
    resetPending = false;
    if (history != null) {
      // The history is rendered at the service's width, and replaces this view's content and scrollback.
      output.push(TerminalEvent.geometry(streamColumns, streamRows));
      output.push(TerminalEvent.history(history));
    }
    output.push(TerminalEvent.screenSnapshot(position, data));
    output.push(TerminalEvent.status(value.terminal.state, value.terminal.exitCode));
    // Output recorded after the snapshot follows by replay.
    if (!snapshotOnly) replayDirty = true;
    nextRead = Sys.time() + (snapshotOnly ? idleReadDelay() : 0);
  }
}
