package workspace.client;

import haxeon.ui.Path;

import haxeon.rpc.*;
import haxeon.wire.JsonWire;
import process.ProcessManager;
import process.OwnedProcess;
import sys.FileSystem;
import haxeon.platform.NativeKitEvents;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcConnector;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceReplica;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspacePairingProtocol;
import workspace.service.WorkspacePairingProtocol.PairingInvitation;
import workspace.service.WorkspacePairingProtocol.PairingList;

@:wire typedef LocalWorkspaceEndpoint = {@: id(1) var version: Int;
@:id(2) var protocol:Int;
@:id(3) var codec:Int;
@:id(4) var workspace:String;
@:id(5) var root:String;
@:id(6) var managerPid:Int;
@:id(7) var generation:String;
@:id(8) var socket:String;
@:id(9) var websocket:String;
@:id(10) var credentialFile:String;
@:optional @:id(11) var expectedBuild:Null<String>;
}

/** Nonblocking native attachment. Closing a client never owns/stops the shared daemon. */
class LocalWorkspaceClient implements WorkspaceAttachment implements WorkspaceRpcEndpoint implements workspace.client.WorkspaceWorkbenchClient implements workspace.client.WorkspaceAgentClient implements workspace.client.WorkspacePairingClient {
  public var root(default, null):Null<String>;
  public var error(default, null):Null<String>;
  public var instance(default, null):String = "";
  public var ready(get, never):Bool;

  final hub:NativeRpcHub;
  final processes:ProcessManager;
  final launcher:String;
  final clock:Void -> Float;
  final environment:Null<Map < String, String>>;
  final workbench:RpcWorkspaceWorkbenchClient;
  var client:Null<RpcClient>;
  var fileApiConnection:Null<RpcConnection>;
  var fileApiClient:Null<WorkspaceFileClient>;
  var replica:Null<WorkspaceReplica>;
  var helper:Null<OwnedProcess>;
  var helperMode:String = "";
  var output:String = "";
  var errors:String = "";
  var helperDeadline:Float = 0;
  var deadline:Float = 0;
  var startupDeadline:Float = 0;
  var retryAt:Float = 0;
  var selection:Int = 0;
  var selectedPath:Null<String>;
  var verified:Bool = false;
  var wasReady:Bool = false;
  var spawned:Bool = false;
  var disposed:Bool = false;
  var pairings:Null<PairingList>;
  var pairingsError:Null<String>;
  var pairingsRevision:Int = 0;
  var pairingsPending:Bool = false;
  var pairingsMutation:Bool = false;
  var pairingsNext:Float = 0;
  var relayStatus:Null<workspace.service.WorkspacePairingProtocol.RemoteAccessStatus>;
  var relayStatusNext:Float = 0;
  var relayStatusPending:Bool = false;
  var relayOrigin:String = "";
  var expectedBuild:String = "";
  var lifecycle:Null<workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus>;
  var lifecyclePending = false;
  var lifecycleNext:Float = 0;
  var updateHelper:Null<OwnedProcess>;
  var updateOutput = "";
  var updateErrors = "";
  var updateMode = "";
  var updateSelection = 0;
  var updateInstance = "";
  var updateDeadline:Float = 0;
  var updateFailure:Null<String>;
  var updateRequestPending = false;
  var autoUpdateAttempted = false;
  var recoveringUntil:Float = 0;

  public function new(
    events:NativeKitEvents,
    processes:ProcessManager,
    launcher:String,
    clock:Void -> Float,
    ? environment:Map<
      String,
      String
  >
  ) {
    this.hub = new NativeRpcHub(events);
    this.processes = processes;
    this.launcher = launcher;
    this.clock = clock;
    this.environment = environment;
    this.workbench = new RpcWorkspaceWorkbenchClient(this, clock);
  }

  function get_ready():Bool return verified
    && client != null && client.current() != null && replica != null && replica.ready;

  public function view():Array < WorkspaceGroup > return ready && replica != null ? replica.view() :[];

  public function rpc():Null < RpcConnection > return ready && client != null ? client.current() : null;

  public function rootPath():Null<String> return root;
  public function serviceGeneration():String return instance;
  public function rpcConnection():Null<RpcConnection> return rpc();
  public function failureReason():Null<String> return error;
  public function supportsWorkspaceGroups():Bool return hasGroupTree();
  public function workspaceEpoch():Null<String> return replica == null ? null : replica.epoch;
  public function hasCapability(capability:String):Bool
    return client != null && client.capabilities().indexOf(capability) >= 0;

  /** A typed file API tied to the currently authenticated local workspace connection. */
  public function fileClient():Null<WorkspaceFileClient> {
    var connection = rpc();
    if (connection == null || client == null || client.capabilities().indexOf(WorkspaceFileProtocol.READ) < 0) {
      fileApiConnection = null;
      fileApiClient = null;
      return null;
    }
    if (connection != fileApiConnection) {
      fileApiConnection = connection;
      fileApiClient = new WorkspaceFileClient(connection);
    }
    return fileApiClient;
  }

  public function fileWorkspace():String return "workspace";
  public function fileScope():Null<String> return root;
  public function hasLocalFileAccess():Bool return true;

  public function hasGroupTree():Bool return client != null && client.capabilities().indexOf(WorkspaceProtocol.TREE) >= 0;
  public function canEditGroups():Bool return workbench.canEditGroups();

  public function workspaceConnected():Bool return ready;
  public function serviceStatus():Null<workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus> return lifecycle;
  public function serviceUpdateAvailable():Bool return ready && (!hasCapability(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY)
    || lifecycle != null && (lifecycle.protocol != workspace.service.WorkspaceLifecycleProtocol.VERSION
      || expectedBuild.length > 0 && lifecycle.build != expectedBuild));
  public function serviceUpdateBusy():Bool return updateHelper != null || updateRequestPending;
  public function serviceUpdateError():Null<String> return updateFailure;

  public function requestServiceUpdate(mode:String):Void {
    if (!ready || serviceUpdateBusy() || root == null || mode != "idle" && mode != "now" && mode != "cancel") return;
    autoUpdateAttempted = true;
    updateFailure = null;
    if (mode == "cancel") { sendServiceUpdate(mode); return; }
    var managed = hasCapability(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY);
    if (!managed && mode != "now") {
      updateFailure = "This older service requires an explicit restart; its session activity cannot be checked safely.";
      pairingsRevision++;
      return;
    }
    updateMode = mode; updateSelection = selection; updateInstance = instance;
    updateOutput = ""; updateErrors = "";
    try {
      var executable:String;
      var arguments:Array<String>;
      executable = Sys.executablePath();
      arguments = [launcher, "--manager", root];
      if (managed) {
        arguments.push("--prepare-update");
      } else {
        arguments.push("--restart");
        arguments.push("--expected-generation");
        arguments.push(instance);
      }
      arguments.push("--wire");
      updateHelper = processes.start(executable, arguments, root, helperEnvironment());
      updateDeadline = clock() + 110000;
    } catch (failure:Dynamic) updateFailure = Std.string(failure);
    pairingsRevision++;
  }

  function sendServiceUpdate(mode:String):Void {
    var connection = rpc();
    if (connection == null || !hasCapability(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY)) return;
    updateRequestPending = true;
    connection.call(workspace.service.WorkspaceLifecycleProtocol.UPDATE, {mode: mode}, 3000, function(value) {
      updateRequestPending = false;
      if (rpc() != connection) return;
      if (!value.accepted) updateFailure = "The workspace service refused this update request.";
      lifecycleNext = 0; pairingsRevision++;
    }, function(failure) {
      updateRequestPending = false;
      if (rpc() == connection) { updateFailure = failure.message; pairingsRevision++; }
    });
  }

  function pollUpdateHelper():Void {
    var process = updateHelper;
    if (process == null) return;
    updateOutput += process.readStdout(); updateErrors += process.readStderr();
    if (clock() >= updateDeadline || updateOutput.length > 16384 || updateErrors.length > 16384) {
      processes.release(process); updateHelper = null;
      updateFailure = "Workspace update preparation exceeded its limit."; pairingsRevision++; return;
    }
    if (process.running()) return;
    updateOutput += process.readStdout(); updateErrors += process.readStderr();
    var code = process.exitStatus();
    processes.release(process); updateHelper = null;
    if (updateSelection != selection) return;
    if (code != 0) {
      updateFailure = updateErrors.length == 0 ? "Could not prepare the workspace update." : StringTools.trim(updateErrors);
    } else {
      try {
        var endpoint:LocalWorkspaceEndpoint = JsonWire.decode(updateOutput);
        if (endpoint.root != root) throw "Update helper returned another workspace";
        expectedBuild = endpoint.expectedBuild == null ? "" : endpoint.expectedBuild;
        if (endpoint.generation != updateInstance) {
          stopConnection(); retryAt = clock() + 100; recoveringUntil = clock() + 120000;
        } else if (instance == updateInstance) sendServiceUpdate(updateMode);
        else updateFailure = "Workspace service changed while preparing the update; refresh and try again.";
      } catch (failure:Dynamic) updateFailure = Std.string(failure);
    }
    pairingsRevision++;
  }

  function refreshServiceStatus():Void {
    var connection = rpc();
    if (connection == null || lifecyclePending || clock() < lifecycleNext
      || !hasCapability(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY)) return;
    lifecyclePending = true; lifecycleNext = clock() + 1000;
    connection.call(workspace.service.WorkspaceLifecycleProtocol.STATUS, {}, 3000, function(value) {
      if (rpc() != connection) return;
      lifecyclePending = false;
      if (value.protocol < 1 || value.build == null || value.build.length > 128 || value.terminals < 0 || value.agents < 0) {
        updateFailure = "Workspace service returned an invalid update status.";
        pairingsRevision++;
        return;
      }
      var changed = lifecycle == null || lifecycle.build != value.build || lifecycle.protocol != value.protocol
        || lifecycle.terminals != value.terminals || lifecycle.agents != value.agents || lifecycle.updatePending != value.updatePending;
      lifecycle = value;
      if (changed) pairingsRevision++;
      if (serviceUpdateAvailable() && value.protocol == workspace.service.WorkspaceLifecycleProtocol.VERSION
        && value.terminals == 0 && value.agents == 0 && !value.updatePending
        && !serviceUpdateBusy() && !autoUpdateAttempted) {
        autoUpdateAttempted = true;
        requestServiceUpdate("idle");
      }
    }, function(failure) {
      if (rpc() == connection) { lifecyclePending = false; updateFailure = failure.message; pairingsRevision++; }
    });
  }
  public function remoteAccessStatus():Null<workspace.service.WorkspacePairingProtocol.RemoteAccessStatus> return relayStatus;
  public function canConfigureRelay():Bool return ready && hasCapability(WorkspacePairingProtocol.STATUS_CAPABILITY);
  public function configureRelay(origin:String):Void {
    if (!canConfigureRelay() || helper != null || relayStatus != null && relayStatus.configured) return;
    // Match the transport's origin validation before passing a structured process argument.
    try {
      var endpoint = new workspace.transport.RelayMachineEndpoint(StringTools.trim(origin), "00000000000000000000000000000000");
      if (endpoint.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1") throw "Enter an HTTPS relay address";
      relayOrigin = endpoint.origin;
      startHelper("configure-relay");
    } catch (failure:Dynamic) {
      pairingsError = Std.string(failure);
      pairingsRevision++;
    }
  }
  public function canManagePairings():Bool return ready && client != null
    && client.capabilities().indexOf(WorkspacePairingProtocol.ADMIN) >= 0
    && (relayStatus == null || relayStatus.connected);
  public function pairingList():Null<PairingList> return pairings;
  public function pairingRevision():Int return pairingsRevision;
  public function pairingBusy():Bool return pairingsMutation;
  public function pairingError():Null<String> return pairingsError;

  public function refreshPairings(force:Bool):Void {
    refreshRemoteAccessStatus(force);
    var connection = rpc();
    if (connection == null || pairingsPending || (!force && clock() < pairingsNext)
      || client == null || client.capabilities().indexOf(WorkspacePairingProtocol.ADMIN) < 0) return;
    if (force) pairingsError = null;
    pairingsPending = true;
    pairingsNext = clock() + 1000;
    connection.call(WorkspacePairingProtocol.LIST, {}, 3000, function(value) {
      if (rpc() != connection) return;
      pairingsPending = false;
      if (value.pending == null || value.devices == null || value.pending.length > 8 || value.devices.length > 1024) {
        pairingsError = "Invalid remote device list";
      } else {
        pairings = value;
        pairingsError = null;
      }
      pairingsRevision++;
    }, function(failure) {
      if (rpc() == connection) {
        pairingsPending = false;
        pairingsError = failure.message;
        pairingsRevision++;
      }
    });
  }

  function refreshRemoteAccessStatus(force:Bool):Void {
    var connection = rpc();
    if (connection == null || relayStatusPending || !hasCapability(WorkspacePairingProtocol.STATUS_CAPABILITY)
      || !force && clock() < relayStatusNext) return;
    relayStatusPending = true;
    relayStatusNext = clock() + 1000;
    connection.call(WorkspacePairingProtocol.STATUS, {}, 3000, function(value) {
      if (rpc() != connection) return;
      relayStatusPending = false;
      var changed = relayStatus == null || relayStatus.configured != value.configured
        || relayStatus.connected != value.connected || relayStatus.origin != value.origin || relayStatus.error != value.error;
      relayStatus = value;
      if (changed) pairingsRevision++;
      if (value.configured && !hasCapability(WorkspacePairingProtocol.ADMIN)) {
        stopConnection();
        retryAt = clock() + 100;
      }
    }, function(failure) {
      if (rpc() != connection) return;
      relayStatusPending = false;
      pairingsError = failure.message;
      pairingsRevision++;
    });
  }

  public function createPairing(ttlSeconds:Int, complete:PairingInvitation->Null<String>->Void):Void {
    if (complete == null) throw "Pairing completion cannot be null";
    pairingMutation(WorkspacePairingProtocol.CREATE, {ttlSeconds: ttlSeconds}, function(result) {
      var invitation:PairingInvitation = cast result;
      complete(invitation, null);
    }, function(error) complete(null, error));
  }

  public function approvePairing(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void
    pairingAction(WorkspacePairingProtocol.APPROVE, {deviceId: deviceId, grants: grants}, complete);

  public function rejectPairing(deviceId:String, complete:Null<String>->Void):Void
    pairingAction(WorkspacePairingProtocol.REJECT, {deviceId: deviceId}, complete);

  public function revokePairing(deviceId:String, complete:Null<String>->Void):Void
    pairingAction(WorkspacePairingProtocol.REVOKE, {deviceId: deviceId}, complete);

  function pairingAction<Request>(method:haxeon.rpc.RpcMethod<Request, workspace.service.WorkspacePairingProtocol.PairingActionResult>,
      request:Request, complete:Null<String>->Void):Void {
    if (complete == null) throw "Pairing action completion cannot be null";
    pairingMutation(method, request, function(result:workspace.service.WorkspacePairingProtocol.PairingActionResult) {
      if (!result.accepted) complete(result.error == null ? "pairing_action_failed" : result.error);
      else {
        pairingsNext = 0;
        complete(null);
      }
    }, complete);
  }

  function pairingMutation<Request, Response>(method:haxeon.rpc.RpcMethod<Request, Response>, request:Request,
      success:Response->Void, failure:Null<String>->Void):Void {
    var connection = rpc();
    if (connection == null || !canManagePairings() || pairingsMutation) {
      failure("remote_access_unavailable");
      return;
    }
    pairingsMutation = true;
    pairingsError = null;
    var selected = selection;
    connection.call(method, request, 10000, function(value) {
      if (rpc() != connection || selected != selection) return;
      pairingsMutation = false;
      pairingsRevision++;
      success(value);
    }, function(error) {
      if (rpc() != connection || selected != selection) return;
      pairingsMutation = false;
      pairingsError = error.message;
      pairingsRevision++;
      failure(error.message);
    });
  }

  public function agentService():WorkspaceAgentClient return workbench.agentService();
  public function canReadAgents():Bool return workbench.canReadAgents();
  public function canControlAgents():Bool return workbench.canControlAgents();
  public function agentBusy():Bool return workbench.agentBusy();
  public function agentRevision():Int return workbench.agentRevision();
  public function agents():Null<AgentCatalog> return workbench.agents();
  public function agentError():Null<String> return workbench.agentError();
  public function refreshAgents():Void workbench.refreshAgents();
  public function createAgent(group:String, thread:Null<String>, ?created:String->Void):Void workbench.createAgent(group, thread, created);
  public function deleteAgent(id:String, ?deleted:Void->Void):Void workbench.deleteAgent(id, deleted);
  public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String):Void
    workbench.agentAction(id, action, text, request, model, effort);
  public function discoverAgents(group:String, cursor:Null<String>):Void workbench.discoverAgents(group, cursor);
  public function discoveredAgents():Null<AgentDiscovery> return workbench.discoveredAgents();
  public function agentView(id:String):Null<AgentView> return workbench.agentView(id);

  public function canReadTerminals():Bool return workbench.canReadTerminals();
  public function canControlTerminals():Bool return workbench.canControlTerminals();
  public function canCreateTerminals():Bool return workbench.canCreateTerminals();
  public function terminalCatalog():Null<TerminalCatalog> return workbench.terminalCatalog();
  public function terminalCatalogError():Null<String> return workbench.terminalCatalogError();
  public function terminalCatalogRevision():Int return workbench.terminalCatalogRevision();
  public function terminalCatalogBusy():Bool return workbench.terminalCatalogBusy();
  public function refreshTerminals(force:Bool):Void workbench.refreshTerminals(force);
  public function renameTerminal(record:TerminalRecord, name:String, group:String):Void
    workbench.renameTerminal(record, name, group);
  public function changeGroup(owner:String, group:WorkspaceGroup, name:String, parent:Null<String>,
      cwd:Null<String>, order:Int, create:Bool):Void
    workbench.changeGroup(owner, group, name, parent, cwd, order, create);
  public function stopTerminal(record:TerminalRecord):Void workbench.stopTerminal(record);
  public function forgetTerminal(record:TerminalRecord):Void workbench.forgetTerminal(record);

  public function failure():Null < String > return error;

  public function cursor():Int return replica == null ? 0 : replica.cursor;

  public function epoch():String return replica == null ? "" : replica.epoch;

  public function statusLabel():String {
    if (root == null) return "";
    if (error != null) return "Workspace unavailable";
    if (ready) return serviceUpdateAvailable() ? "Workspace update available" : "Workspace connected";
    return wasReady ? "Workspace reconnecting" : "Connecting workspace…";
  }

  public static function findLauncher():String {
    var configured = Sys.getEnv("EXOSUIT_AGENT_LAUNCHER");
    if (configured != null && configured.length > 0)
      return FileSystem.fullPath(configured);
    var directory = FileSystem.fullPath(Sys.getCwd());
    for (_ in 0...8) {
      for (candidate in [directory + "/agent/build/host/main.hl", directory + "/tools/exosuit-agent.hl"])
        if (FileSystem.exists(candidate)) return FileSystem.fullPath(candidate);
      var parent = haxe.io.Path.directory(directory);
      if (parent == directory || parent.length == 0) break;
      directory = parent;
    }
    throw "Workspace agent launcher is not installed";
  }

  public function select(path:Null<String>):Void {
    if (disposed || path == selectedPath) return;
    selectedPath = path;
    var canonical:Null<String> = null;
    try canonical = path == null ? null : FileSystem.fullPath(path) catch (failure : Dynamic) {
      selection++;
      stopConnection();
      stopHelper();
      root = path;
      fail(Std.string(failure));
      return;
    }
    if (canonical == root) return;
    selection++;
    if (updateHelper != null) processes.release(updateHelper);
    updateHelper = null; updateFailure = null; autoUpdateAttempted = false; recoveringUntil = 0;
    stopConnection();
    stopHelper();
    root = canonical;
    error = null;
    instance = "";
    replica = null;
    verified = false;
    wasReady = false;
    spawned = false;
    retryAt = 0;
    if (canonical == null) return;
    startupDeadline = clock() + 120000;
    startHelper("discover");
  }

  function stopConnection():Void {
    lifecycle = null; lifecyclePending = false; lifecycleNext = 0; updateRequestPending = false;
    relayStatus = null; relayStatusPending = false; relayStatusNext = 0;
    pairings = null; pairingsError = null; pairingsPending = false; pairingsMutation = false; pairingsNext = 0; pairingsRevision++;
    if (client != null) client.close();
    client = null;
    verified = false;
    workbench.poll();
  }

  function stopHelper():Void {
    var process = helper;
    helper = null;
    if (process != null) processes.release(process);
  }

  function fail(message:String):Void {
    error = message;
    if (updateHelper != null) processes.release(updateHelper);
    updateHelper = null;
    stopConnection();
    stopHelper();
  }

  function startHelper(mode:String):Void {
    var path = root;
    if (path == null || disposed) return;
    stopConnection();
    stopHelper();
    output = "";
    errors = "";
    helperMode = mode;
    try {
      var arguments = [launcher, "--manager", path];
      if (mode == "configure-relay") {
        arguments.push("--configure-relay");
        arguments.push(relayOrigin);
      } else {
        arguments.push(mode == "discover" ? "--discover" : "--detach");
      }
      arguments.push("--wire");
      helper = processes.start(
        Sys.executablePath(),
        arguments,
        path,
        helperEnvironment()
      );
      helperDeadline = clock() + 95000;
    } catch (failure:Dynamic) {
      fail(Std.string(failure));
    }
  }

  function helperEnvironment():Map<String, String> {
    var result = new Map<String, String>();
    if (environment != null)
      for (key => value in environment)
        result.set(key, value);
    result.set("EXOSUIT_AGENT_LAUNCHER", launcher);

    var launcherDirectory = haxe.io.Path.directory(FileSystem.fullPath(launcher));
    var nativeRoot = haxe.io.Path.join([launcherDirectory, "native"]);
    var directories:Array<String> = [];
    addExistingDirectory(directories, nativeRoot);
    if (FileSystem.exists(nativeRoot) && FileSystem.isDirectory(nativeRoot))
      for (entry in FileSystem.readDirectory(nativeRoot))
        addExistingDirectory(directories, haxe.io.Path.join([nativeRoot, entry]));

    // Installed bundles place all agent libraries in ../lib; source builds
    // keep them under agent/build/host/native/<package>.
    var installRoot = haxe.io.Path.directory(launcherDirectory);
    addExistingDirectory(directories, haxe.io.Path.join([installRoot, "lib"]));
    addExistingDirectory(directories, haxe.io.Path.directory(Sys.executablePath()));
    var haxeonHome = Sys.getEnv("HAXEON_HOME");
    if (haxeonHome != null && haxeonHome.length > 0) {
      addExistingDirectory(directories, haxe.io.Path.join([haxeonHome, "out"]));
      addExistingDirectory(directories, haxe.io.Path.join([haxeonHome, ".tools", "hashlink"]));
    }

    var windows = Sys.systemName() == "Windows";
    var variable = windows ? "PATH" : Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH";
    var inherited = environment == null ? null : environment.get(variable);
    if (inherited == null || inherited.length == 0) inherited = Sys.getEnv(variable);
    if (inherited != null && inherited.length > 0) directories.push(inherited);
    if (directories.length > 0) result.set(variable, directories.join(windows ? ";" : ":"));
    return result;
  }

  static function addExistingDirectory(directories:Array<String>, path:String):Void {
    if (path.length > 0 && FileSystem.exists(path) && FileSystem.isDirectory(path) && directories.indexOf(path) < 0)
      directories.push(path);
  }

  function install(endpoint:LocalWorkspaceEndpoint):Void {
    var path = root;
    if (path == null || endpoint.version != 1 || endpoint.protocol != 1 || endpoint.codec != 1
      || endpoint.workspace != "workspace" || endpoint.root != path || endpoint.generation.length != 32
      || endpoint.socket.length == 0) throw "Invalid workspace discovery descriptor";
    var expectedInstance = endpoint.generation, expectedRoot = path, selected = selection;
    instance = expectedInstance;
    expectedBuild = endpoint.expectedBuild == null ? "" : endpoint.expectedBuild;
    verified = false;
    if (replica == null) replica = new WorkspaceReplica("workspace", 2000);
    var required = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY];
    var caps = required.copy();
    caps.push(WorkspaceProtocol.WRITE);
    caps.push(WorkspaceProtocol.TREE);
    caps.push(WorkspaceTerminalProtocol.CATALOG);
    caps.push(WorkspaceAgentProtocol.READ);
    caps.push(WorkspaceAgentProtocol.CONTROL);
    caps.push(WorkspaceTerminalProtocol.READ);
    caps.push(WorkspaceTerminalProtocol.CONTROL);
    caps.push(WorkspaceFileProtocol.READ);
    caps.push(WorkspacePairingProtocol.ADMIN);
    caps.push(WorkspacePairingProtocol.STATUS_CAPABILITY);
    caps.push(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY);
    deadline = clock() + 12000;
    client = new RpcClient(new NativeRpcConnector(hub,
      NativeRpcHub.local(endpoint.socket)), clock, function() return Math.random(), new RpcPeerOptions(
        "exosuit-editor/1",
        caps,
        required,
        2000,
        262144,
        32,
        1048576
      ), function(
        connection,
        token,
        _
      ) {
      var current = client;
      if (current == null || selected != selection) return;
      verified = false;
      if (current.remoteApplication != "exosuit-agent/1") {
        fail("Unexpected workspace service");
        return;
      }
      connection.call(WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, 2000, function(identity) {
        if (selected != selection || !current.isCurrent(token)) return;
        if (identity.workspace != "workspace" || identity.root != expectedRoot) {
          fail("Workspace service identity mismatch");
          return;
        }
        if (identity.instance != expectedInstance) {
          stopConnection();
          retryAt = clock() + 100;
          return;
        }
        verified = true;
        deadline = clock() + 6000;
        spawned = false;
        var view = replica;
        if (view != null) view.restore(
          connection,
          function() return selected == selection && verified && current.isCurrent(token)
        );
      }, function(failure) {
        if (selected == selection
          && current.isCurrent(token)) fail("Workspace identity validation failed: " + failure.code);
      }
      );
    }, 100, 1000, 2000);
  }

  public function poll():Void {
    pollUpdateHelper();
    workbench.poll();
    if (disposed || root == null || error != null) return;
    var now = clock(), process = helper;
    if (recoveringUntil > 0 && now >= recoveringUntil && !ready) { fail("Workspace service did not reconnect after updating"); return; }
    if (!wasReady && now >= startupDeadline) {
      fail("Workspace startup timed out");
      return;
    }
    if (process != null) {
      output += process.readStdout();
      errors += process.readStderr();
      if (output.length > 16384 || errors.length > 16384 || now >= helperDeadline) {
        fail("Workspace startup helper exceeded its limit");
        return;
      }
      if (process.running()) return;
      // Drain after exit so the final descriptor cannot be lost to a process-state race.
      output += process.readStdout();
      errors += process.readStderr();
      var code = process.exitStatus(), mode = helperMode;
      stopHelper();
      if (output.length > 16384 || errors.length > 16384) {
        fail("Workspace discovery exceeds its limit");
        return;
      }
      if (code == 0) {
        try {
          var endpoint:LocalWorkspaceEndpoint = JsonWire.decode(output);
          install(endpoint);
        } catch (failure:Dynamic) {
          fail(Std.string(failure));
        }
      } else if (mode == "configure-relay") {
        var message = errors.length > 0 ? StringTools.trim(errors) : "Could not configure remote access";
        startHelper("discover");
        pairingsError = message;
        pairingsRevision++;
      } else if (mode == "discover" && code == 4) {
        spawned = true;
        startHelper("launch");
      } else if (mode == "launch" && code == 3) {
        retryAt = now + 250;
      } else {
        fail(errors.length > 0 ? StringTools.trim(errors) : "Workspace startup failed");
      }
      return;
    }
    var current = client;
    if (current == null) {
      if (now >= retryAt) startHelper("discover");
      return;
    }
    current.poll();
    workbench.poll();
    if (client != current || error != null) return;
    if (current.state == Closed) {
      if (wasReady) {
        stopConnection(); retryAt = now + 250;
        if (recoveringUntil == 0) recoveringUntil = now + 120000;
        pairingsRevision++;
        return;
      }
      fail(current.lastError == null ? "Workspace connection closed" : current.lastError.code);
      return;
    }
    var view = replica;
    if (view != null && view.error != null) {
      if (view.error == "replay_gap") view.recover();
      else {
        fail("Workspace catalog unavailable: " + view.error);
        return;
      }
    }
    if (ready) {
      recoveringUntil = 0;
      refreshServiceStatus();
      wasReady = true;
      deadline = now + 3000;
      return;
    }
    if (now >= deadline) {
      if (!spawned) {
        spawned = true;
        startHelper("launch");
      } else {
        stopConnection();
        retryAt = now + 1000;
      }
    }
  }

  public function dispose():Void {
    if (disposed) return;
    disposed = true;
    if (updateHelper != null) processes.release(updateHelper);
    updateHelper = null;
    selection++;
    stopConnection();
    workbench.dispose();
    stopHelper();
    hub.dispose();
    root = null;
  }
}
