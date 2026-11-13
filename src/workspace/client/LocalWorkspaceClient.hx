package workspace.client;

import haxeon.ui.Path;

import haxeon.rpc.*;
import haxeon.wire.JsonWire;
import process.ProcessManager;
import process.OwnedProcess;
import sys.FileSystem;
import haxeon.platform.event.EventPump;
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
@:optional @:id(12) var launcher:Null<String>;
/** The id of the workspace a service is keyed by; absent for a folder's service. */
@:optional @:id(13) var workspaceId:Null<String>;
}

/** Nonblocking native attachment. Closing a client never owns/stops the shared daemon. */
class LocalWorkspaceClient implements WorkspaceAttachment implements WorkspaceRpcEndpoint implements ServedRoots implements workspace.client.WorkspaceWorkbenchClient implements workspace.client.WorkspaceAgentClient implements workspace.client.WorkspacePairingClient {
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
  final choices:WorkspaceManagerChoices;
  /** The chosen manager's state folder; null for the folder's default state. */
  var stateDir:Null<String>;
  var choiceRevision:Int = -1;
  /** The attached manager's launcher, from discovery; empty for a manager from before it was reported. */
  var managerLauncher:String = "";
  /** What a connection made from the descriptor displaced (root, launcher, expected build) until its identity is verified. */
  var directPrior:Null<{root:Null<String>, launcher:String, build:String}> = null;
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
  /** The workspace whose service this attaches to by id, or null for the folder's. */
  var serviceTarget:Null<WorkspaceServiceTarget>;
  var selectedTarget:Null<String>;
  var verified:Bool = false;
  var wasReady:Bool = false;
  var spawned:Bool = false;
  /** True while `client` was connected from the service's own descriptor and the launcher has not confirmed it yet. */
  var direct:Bool = false;
  /** When the descriptor may be read again. */
  var directAt:Float = 0;
  /** Generations a connection from the descriptor, or the launcher, turned down: not tried again in this attachment. */
  final directRefused:Map<String, Bool> = [];
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
  final events:EventPump;
  /** Which client the current connection's callbacks act on: the one that made it, or the one it was handed to. */
  var owner:Null<ConnectionOwner>;
  /**
    Told just before this client leaves the service it is ready on (for another folder, workspace or state), while its
    connection still works: the terminal pool takes that connection over with `handOver`, so terminals of the service
    the window leaves stay connected.
  **/
  public var leaving:Null<LocalWorkspaceClient->Void>;

  public function new(
    events:EventPump,
    processes:ProcessManager,
    launcher:String,
    clock:Void -> Float,
    ? environment:Map<
      String,
      String
  >,
    ? choices:WorkspaceManagerChoices
  ) {
    this.events = events;
    this.hub = new NativeRpcHub(events);
    this.processes = processes;
    this.launcher = launcher;
    this.clock = clock;
    this.environment = environment;
    this.choices = choices == null ? WorkspaceManagerChoices.instance() : choices;
    this.workbench = new RpcWorkspaceWorkbenchClient(this, clock);
    workbench.timelineName = timelineName;
    workbench.workspaceIdentity = function() return serviceTarget == null ? null : serviceTarget.workspace;
  }

  /** The workspace this attachment's events are filed under in the ConnectTimeline. */
  public function timelineName():String {
    var active = serviceTarget;
    return active == null ? (root == null ? "" : root) : active.workspace;
  }

  function get_ready():Bool return verified
    && client != null && client.current() != null && replica != null && replica.ready;

  public function view():Array < WorkspaceGroup > return ready && replica != null ? replica.view() :[];

  public function rpc():Null < RpcConnection > return ready && client != null ? client.current() : null;

  public function rootPath():Null<String> return root;
  /**
    The machine workspace whose service this client is attached to, or null for a folder's own service or while not
    attached. Its `rootPath()` is then the folder that service started in, which need not be one of the workspace's folders now.
  **/
  public function servedWorkspace():Null<String> {
    var target = serviceTarget;
    return ready && target != null ? target.workspace : null;
  }
  /**
    Whether a terminal keyed by `path` belongs to the service this client attaches to: its root, or, for a machine
    workspace's service, any of the workspace's folders (the service keeps the folder it started in).
  **/
  public function servesRoot(path:String):Bool {
    if (root == null) return false;
    if (root == path) return true;
    var target = serviceTarget;
    return target != null && (target.folders.indexOf(path) >= 0 || target.scratch == path);
  }
  public function serviceGeneration():String return instance;
  /**
    Whether this client is attached (or attaching) to the service a terminal pool would use for `target`, or for the
    folder `path` when `target` is null: the same workspace or folder on the same state.
  **/
  public function attachedTo(target:Null<WorkspaceServiceTarget>, path:String):Bool {
    if (disposed || error != null || root == null) return false;
    var active = serviceTarget;
    if (target == null) return active == null && root == path && stateDir == choices.stateFor(path);
    return active != null && active.workspace == target.workspace && stateDir == choices.stateFor(target.choiceKey());
  }
  var terminalEventRouter:Null<WorkspaceTerminalEvents>;
  public function terminalEvents():Null<WorkspaceTerminalEvents> {
    var c = rpc();
    if (c == null) { terminalEventRouter = null; return null; }
    if (terminalEventRouter == null || terminalEventRouter.connection != c)
      terminalEventRouter = new WorkspaceTerminalEvents(c);
    return terminalEventRouter;
  }
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
  /** Local desktop roots use Application.scm; this attachment owns no second SCM source. */
  public function sourceControlSource():Null<scm.ScmSource> return null;

  public function hasGroupTree():Bool return client != null && client.capabilities().indexOf(WorkspaceProtocol.TREE) >= 0;
  public function canEditGroups():Bool return workbench.canEditGroups();

  public function workspaceConnected():Bool return ready;
  public function serviceStatus():Null<workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus> return lifecycle;
  /** The attached manager runs another build tree's launcher, another worktree's say: this editor never updates it. */
  public function managerFromOtherBuild():Bool
    return managerLauncher.length > 0 && !samePath(managerLauncher, launcher);
  /** The manager's state folder this client uses; null for the folder's default state. */
  public function attachedState():Null<String> return stateDir;
  public function serviceUpdateAvailable():Bool return ready && !managerFromOtherBuild() && (!hasCapability(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY)
    || lifecycle != null && (lifecycle.protocol != workspace.service.WorkspaceLifecycleProtocol.VERSION
      || expectedBuild.length > 0 && lifecycle.build != expectedBuild));
  public function serviceUpdateBusy():Bool return updateHelper != null || updateRequestPending;
  public function serviceUpdateError():Null<String> return updateFailure;

  public function requestServiceUpdate(mode:String):Void {
    if (!ready || serviceUpdateBusy() || root == null || mode != "idle" && mode != "now" && mode != "cancel") return;
    if (managerFromOtherBuild()) {
      updateFailure = "This workspace service runs another build. Use the Machine view to start one on this editor's build.";
      pairingsRevision++;
      return;
    }
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
      arguments = managerArguments().concat(stateArguments());
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

  /**
    Tells the service to serve exactly `folders` now, with no restart (see WorkspaceFoldersProtocol). `done` gets the
    failure, or null once the service has changed its roots and watchers.
  **/
  /** The failure for a service that does not offer folder changes at all (as opposed to one not connected now). */
  public static inline final CANNOT_SET_FOLDERS = "The workspace service cannot change its folders; restart it to pick them up.";

  public function setServedFolders(folders:Array<String>, done:Null<String>->Void):Void {
    var connection = rpc();
    if (connection == null) {
      done("The workspace service is not connected.");
      return;
    }
    if (!hasCapability(workspace.service.WorkspaceFoldersProtocol.CAPABILITY)) {
      done(CANNOT_SET_FOLDERS);
      return;
    }
    connection.call(workspace.service.WorkspaceFoldersProtocol.SET, {folders: folders}, 5000, function(_) done(null),
      function(failure) done(failure.message));
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
        var problem = WorkspaceServiceTarget.endpointProblem(serviceTarget, root, endpoint.workspaceId, endpoint.root);
        if (problem != null) throw "Update helper returned another workspace";
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
      // Only a manager known to run this editor's launcher updates by itself: an older one may be another build's.
      if (serviceUpdateAvailable() && managerLauncher.length > 0 && value.protocol == workspace.service.WorkspaceLifecycleProtocol.VERSION
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
  /** Not while a launcher helper runs: the client can be ready from the descriptor before its discover helper exits,
    and configuring starts a helper of its own. */
  public function canConfigureRelay():Bool
    return ready && helper == null && hasCapability(WorkspacePairingProtocol.STATUS_CAPABILITY);
  public function configureRelay(origin:String):Void {
    if (!canConfigureRelay() || relayStatus != null && relayStatus.configured) return;
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

  public function setPairingGrants(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void
    pairingAction(WorkspacePairingProtocol.SET_GRANTS, {deviceId: deviceId, grants: grants}, complete);

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
  public function agentCreation():Null<workspace.client.WorkspaceAgentCreation.AgentCreationStatus> return workbench.agentCreation();
  public function agentRevision():Int return workbench.agentRevision();
  public function agents():Null<AgentCatalog> return workbench.agents();
  public function agentError():Null<String> return workbench.agentError();
  public function refreshAgents():Void workbench.refreshAgents();
  public function createAgent(group:String, thread:Null<String>, ?created:AgentRecord->Void,
      ?defaults:AgentSessionDefaults):Void
    workbench.createAgent(group, thread, created, defaults);
  public function deleteAgent(id:String, ?deleted:Void->Void):Void workbench.deleteAgent(id, deleted);
  public function agentDeliveryUncertain(id:String):Bool return workbench.agentDeliveryUncertain(id);
  public function agentDeliveryReviewReady(id:String):Bool return workbench.agentDeliveryReviewReady(id);
  public function acknowledgeAgentDelivery(id:String):Bool return workbench.acknowledgeAgentDelivery(id);
  public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String, ?accepted:Void->Void, ?expectedNativeName:String, ?imageIds:Array<String>, ?order:Int):Void
    workbench.agentAction(id, action, text, request, model, effort, accepted, expectedNativeName, imageIds, order);
  public function uploadAgentImage(id:String, bytes:haxe.io.Bytes, done:(Null<String>, Null<String>)->Void):Void workbench.uploadAgentImage(id, bytes, done);
  public function removeAgentImage(id:String, upload:String):Void workbench.removeAgentImage(id, upload);
  public function loadAgentContent(id:String, turn:String, item:String, token:String, done:(Null<String>, Bool, Null<String>)->Void):Void workbench.loadAgentContent(id,turn,item,token,done);
  public function loadAgentImage(id:String, turn:String, item:String, imageId:String, done:(Null<haxe.io.Bytes>, Null<String>)->Void):Void workbench.loadAgentImage(id,turn,item,imageId,done);
  public function discoverAgents(group:String, cursor:Null<String>):Void workbench.discoverAgents(group, cursor);
  public function discoveredAgents():Null<AgentDiscovery> return workbench.discoveredAgents();
  public function agentView(id:String):Null<AgentView> return workbench.agentView(id);
  public function agentHistory(id:String):AgentHistoryState return workbench.agentHistory(id);
  public function loadOlderAgentItems(id:String, done:Null<String>->Void):Void workbench.loadOlderAgentItems(id,done);
  public function resetAgentHistory(id:String):Void workbench.resetAgentHistory(id);
  public function listModels(cursor:Null<String>, done:Null<AgentModelsPage>->Null<String>->Void):Void
    workbench.listModels(cursor, done);

  public function canReadTerminals():Bool return workbench.canReadTerminals();
  public function canControlTerminals():Bool return workbench.canControlTerminals();
  public function canCreateTerminals():Bool return workbench.canCreateTerminals();
  public function canCreateGroupedTerminals():Bool return workbench.canCreateGroupedTerminals();
  public function canReorder():Bool return workbench.canReorder();
  public function terminalCatalog():Null<TerminalCatalog> return workbench.terminalCatalog();
  public function terminalCatalogError():Null<String> return workbench.terminalCatalogError();
  public function terminalCatalogRevision():Int return workbench.terminalCatalogRevision();
  public function terminalCatalogBusy():Bool return workbench.terminalCatalogBusy();
  public function refreshTerminals(force:Bool):Void workbench.refreshTerminals(force);
  public function renameTerminal(record:TerminalRecord, name:String, group:String, ?order:Int):Void
    workbench.renameTerminal(record, name, group, order);
  public function canRemoveGroups():Bool return workbench.canRemoveGroups();
  public function removeGroup(owner:String, group:WorkspaceGroup):Void workbench.removeGroup(owner, group);
  public function changeGroup(owner:String, group:WorkspaceGroup, name:String, parent:Null<String>,
      cwd:Null<String>, order:Int, create:Bool, ?done:(Null<WorkspaceGroup>, Null<String>)->Void):Void
    workbench.changeGroup(owner, group, name, parent, cwd, order, create, done);
  public function stopTerminal(record:TerminalRecord):Void workbench.stopTerminal(record);
  public function restartTerminal(record:TerminalRecord):Void workbench.restartTerminal(record);
  public function forgetTerminal(record:TerminalRecord):Void workbench.forgetTerminal(record);
  public function closeTerminal(record:TerminalRecord, ?closed:Void->Void):Void workbench.closeTerminal(record, closed);

  public function failure():Null < String > return error;

  public function cursor():Int return replica == null ? 0 : replica.cursor;

  public function epoch():String return replica == null ? "" : replica.epoch;

  public function statusLabel():String {
    if (root == null) return "";
    if (error != null) return "Workspace unavailable";
    if (ready) return serviceUpdateAvailable() ? "Workspace update available"
      : managerFromOtherBuild() ? "Workspace connected (another build)" : "Workspace connected";
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
    if (disposed || path == selectedPath && serviceTarget == null) return;
    selectedPath = path;
    selectedTarget = null;
    var canonical:Null<String> = null;
    try canonical = path == null ? null : FileSystem.fullPath(path) catch (failure : Dynamic) {
      leave();
      selection++;
      stopConnection();
      stopHelper();
      root = path;
      fail(Std.string(failure));
      return;
    }
    if (canonical == root && serviceTarget == null) return;
    leave();
    serviceTarget = null;
    attach(canonical, canonical == null ? null : choices.stateFor(canonical));
  }

  /**
    Attaches to the service of a machine workspace, by its id: one service for all of its folders. It starts in the
    first folder, or the scratch folder of a workspace with none.
  **/
  public function selectWorkspace(next:WorkspaceServiceTarget):Void {
    var signature = next.signature();
    if (disposed || signature == selectedTarget) return;
    // The same workspace's service, already attached: only its folders changed, which the service follows without a
    // restart (`setServedFolders`). The connection stays, and with it the catalog, the terminals and the sessions.
    var attached = serviceTarget;
    if (ready && attached != null && attached.workspace == next.workspace) {
      selectedTarget = signature;
      serviceTarget = next;
      return;
    }
    leave();
    selectedTarget = signature;
    selectedPath = null;
    serviceTarget = next;
    var primary = next.root();
    if (primary == null) {
      selection++;
      stopConnection();
      stopHelper();
      root = null;
      fail("This workspace has no folder yet. Attach one, or turn on suit for a scratch folder.");
      return;
    }
    attach(primary, choices.stateFor(next.choiceKey()));
  }

  /** What manager choices and the machine view call this attachment's service: the workspace, else the folder. */
  function choiceKey():Null<String> {
    var active = serviceTarget;
    return active == null ? root : active.choiceKey();
  }

  /** The launcher and `--manager` arguments naming this attachment's service. */
  function managerArguments():Array<String> {
    var active = serviceTarget, path = root;
    if (active != null) return [launcher].concat(active.managerArguments());
    if (path == null) throw "No workspace selected";
    return [launcher, "--manager", path];
  }

  /** Starts over on `path`'s manager on `state` (null: the default state). */
  function attach(path:Null<String>, state:Null<String>):Void {
    leave();
    selection++;
    if (updateHelper != null) processes.release(updateHelper);
    updateHelper = null; updateFailure = null; autoUpdateAttempted = false; recoveringUntil = 0;
    workbench.expectReplacement();
    stopConnection();
    stopHelper();
    root = path;
    stateDir = state;
    choiceRevision = choices.revision;
    managerLauncher = "";
    expectedBuild = "";
    error = null;
    instance = "";
    replica = null;
    verified = false;
    wasReady = false;
    spawned = false;
    retryAt = 0;
    directAt = 0;
    directRefused.clear();
    if (path == null) return;
    startupDeadline = clock() + 120000;
    ConnectTimeline.mark("attach", timelineName(), path);
    // With no descriptor in the state folder no service runs there, which is all a discovery would report (about 0.2 s
    // later, as a process of its own): start one at once. A start finds a manager that is already coming up by itself.
    var directory = descriptorDirectory();
    if (directory != null && !FileSystem.exists(haxe.io.Path.join([directory, "endpoint.json"])) && canStart()) {
      spawned = true;
      startHelper("launch");
    } else startHelper("discover");
  }

  /** About to leave the service this client is ready on: `leaving` may take its connection (`handOver`). */
  function leave():Void {
    var notify = leaving;
    if (notify != null && !disposed && ready) notify(this);
  }

  /**
    A new client that goes on with this one's attachment on the same live connection: the RPC client, the terminal
    event router and the catalog replica move to it, so a terminal that reaches the service through it sees the same
    connection and service generation and keeps its screen and history. This client is left with no connection; the
    caller attaches it elsewhere next. Null unless this client is ready: the caller then lets a client of its own attach
    as before. A launcher helper still running (a connection from the descriptor is ready before its discovery answers)
    stays with this client, which stops it: the service's identity is verified already, and the new client goes without
    what only the launcher reports (the expected build), as with a launcher that reported none.

    The moved connection stays on this client's transport hub until it reconnects, so this client must outlive it:
    the window's client does, it is disposed only when the window closes.
  **/
  public function handOver():Null<LocalWorkspaceClient> {
    var link = owner;
    // Only a connection whose identity is verified moves: root, launcher and build are then committed (`directPrior` is
    // cleared), never the values a descriptor connection set before its verification.
    if (disposed || !ready || !verified || directPrior != null || link == null) return null;
    var next = new LocalWorkspaceClient(events, processes, launcher, clock, environment, choices);
    next.root = root;
    next.stateDir = stateDir;
    // Checked again on its first poll: a new manager choice is what may have made this client leave.
    next.choiceRevision = -1;
    next.managerLauncher = managerLauncher;
    next.expectedBuild = expectedBuild;
    next.serviceTarget = serviceTarget;
    var target = serviceTarget;
    next.selectedTarget = target == null ? null : target.signature();
    next.selectedPath = target == null ? root : null;
    next.instance = instance;
    next.client = client;
    next.replica = replica;
    next.terminalEventRouter = terminalEventRouter;
    next.verified = true;
    next.wasReady = true;
    next.autoUpdateAttempted = autoUpdateAttempted;
    next.deadline = deadline;
    next.startupDeadline = startupDeadline;
    next.selection = selection;
    next.owner = link;
    link.client = next;
    owner = null;
    client = null;
    replica = null;
    terminalEventRouter = null;
    verified = false;
    ConnectTimeline.mark("handed-over", timelineName());
    return next;
  }

  /**
    Starts a manager only on the folder's default state or on this editor's own state folder: a state folder chosen
    from another build stays that build's, even after its manager stops.
  **/
  function mayStart():Bool {
    if (canStart()) return true;
    fail("The workspace service chosen for this folder has stopped. Choose another in the Machine view.");
    return false;
  }

  function canStart():Bool {
    if (stateDir == null) return true;
    var name = haxe.io.Path.withoutDirectory(MachineWorkspaces.normalPath(stateDir));
    return StringTools.endsWith(name, "-" + MachineWorkspaces.launcherKey(launcher));
  }

  /** The state folder of the service this attachment follows: the chosen one, else the default; null with nothing selected. */
  function descriptorDirectory():Null<String> {
    var path = root, chosen = stateDir;
    if (path == null) return null;
    if (chosen != null) return chosen;
    var active = serviceTarget;
    var home = environment == null ? null : environment.get("EXOSUIT_AGENT_STATE_HOME");
    return LocalServiceDescriptor.defaultStateDirectory(active == null ? null : active.workspace, path, home);
  }

  function stateArguments():Array<String> return stateDir == null ? [] : ["--state-dir", stateDir];

  static function samePath(a:String, b:String):Bool {
    function normal(path:String):String {
      var value = StringTools.replace(path, "\\", "/");
      try value = StringTools.replace(FileSystem.fullPath(path), "\\", "/") catch (_:Dynamic) {}
      return Sys.systemName() == "Windows" ? value.toLowerCase() : value;
    }
    return normal(a) == normal(b);
  }

  function stopConnection():Void {
    // A descriptor connection that never verified must not leave the descriptor's (possibly stale) root behind.
    var prior = directPrior;
    directPrior = null;
    if (prior != null && !verified) { root = prior.root; managerLauncher = prior.launcher; expectedBuild = prior.build; }
    terminalEventRouter = null;
    lifecycle = null; lifecyclePending = false; lifecycleNext = 0; updateRequestPending = false;
    relayStatus = null; relayStatusPending = false; relayStatusNext = 0;
    pairings = null; pairingsError = null; pairingsPending = false; pairingsMutation = false; pairingsNext = 0; pairingsRevision++;
    if (client != null) client.close();
    client = null;
    verified = false;
    direct = false;
    workbench.poll();
  }

  /**
    While the launcher runs, connects to the service its own descriptor names (LocalServiceDescriptor), if there is one:
    a running service is reached without waiting about a second for the launcher's answer, and a starting one as soon
    as it listens. The launcher's answer then confirms the connection and adds what only it knows (`confirmDirect`), or
    replaces it. Nothing here is final: a connection that fails is dropped and the launcher decides, as before.
  **/
  function connectFromDescriptor(now:Float):Void {
    var directory = descriptorDirectory();
    if (directory == null || now < directAt || helperMode != "discover" && helperMode != "launch") return;
    directAt = now + 25;
    var endpoint = LocalServiceDescriptor.read(directory);
    if (endpoint == null || directRefused.exists(endpoint.generation)) return;
    if (now < retryAt) return;
    try {
      ConnectTimeline.mark("descriptor", timelineName(), helperMode);
      install(endpoint, true);
    } catch (failure:Dynamic) {
      directRefused.set(endpoint.generation, true);
    }
  }

  /** A connection made from the descriptor did not work out: forget it and let the launcher's answer decide. */
  function refuseDirect():Void {
    if (instance.length > 0) directRefused.set(instance, true);
    ConnectTimeline.mark("descriptor-refused", timelineName());
    stopConnection();
  }

  /** The launcher named the service the window already connected to: keep the connection, take what only the launcher knows. */
  function confirmDirect(endpoint:LocalWorkspaceEndpoint):Void {
    direct = false;
    expectedBuild = endpoint.expectedBuild == null ? "" : endpoint.expectedBuild;
    managerLauncher = endpoint.launcher == null ? "" : endpoint.launcher;
    lifecycleNext = 0;
    pairingsRevision++;
    ConnectTimeline.mark("descriptor-confirmed", timelineName());
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
      var active = serviceTarget;
      if (active != null) suit.SuitClient.editorUsesWorkspace(active.workspace);
      else suit.SuitClient.editorUsesRoot(path);
      var arguments = managerArguments().concat(stateArguments());
      var key = choiceKey();
      var seed = stateDir == null || key == null ? null : choices.seedFor(key);
      if (mode == "launch" && seed != null) arguments = arguments.concat(["--seed-from", seed]);
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
      ConnectTimeline.mark("helper-start", timelineName(), mode);
    } catch (failure:Dynamic) {
      fail(Std.string(failure));
    }
  }

  function helperEnvironment():Map<String, String> return agentEnvironment(launcher, environment);

  /** The environment an agent helper started with `launcher` needs: the launcher itself and its native libraries. */
  public static function agentEnvironment(launcher:String, environment:Null<Map<String, String>>):Map<String, String> {
    var result = new Map<String, String>();
    if (environment != null)
      for (key => value in environment)
        result.set(key, value);
    result.set("EXOSUIT_AGENT_LAUNCHER", launcher);
    for (key in ["EXOSUIT_AGENT_STATE_HOME", "EXOSUIT_AGENT_MANAGED_UPDATES", "EXOSUIT_STABLE_BUNDLE"])
      if (!result.exists(key)) {
        var inheritedValue = Sys.getEnv(key);
        if (inheritedValue != null && inheritedValue.length > 0) result.set(key, inheritedValue);
      }

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

  function install(endpoint:LocalWorkspaceEndpoint, fromDescriptor:Bool = false):Void {
    var path = root;
    if (path == null || endpoint.version != 1 || endpoint.protocol != 1 || endpoint.codec != 1
      || endpoint.workspace != "workspace" || endpoint.generation.length != 32
      || endpoint.socket.length == 0) throw "Invalid workspace discovery descriptor";
    var problem = WorkspaceServiceTarget.endpointProblem(serviceTarget, path, endpoint.workspaceId, endpoint.root);
    if (problem != null) throw problem;
    directPrior = fromDescriptor ? {root: root, launcher: managerLauncher, build: expectedBuild} : null;
    // A workspace's service keeps the root it started in, which later changes to the workspace's folders do not move.
    if (serviceTarget != null) { root = endpoint.root; path = endpoint.root; }
    var expectedInstance = endpoint.generation, expectedRoot = path, selected = selection;
    instance = expectedInstance;
    expectedBuild = endpoint.expectedBuild == null ? "" : endpoint.expectedBuild;
    managerLauncher = endpoint.launcher == null ? "" : endpoint.launcher;
    verified = false;
    if (replica == null) replica = new WorkspaceReplica("workspace", 2000);
    var required = [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.IDENTITY_CAPABILITY];
    var caps = required.copy();
    caps.push(WorkspaceProtocol.WRITE);
    caps.push(WorkspaceProtocol.TREE);
    caps.push(WorkspaceProtocol.REMOVE);
    caps.push(WorkspaceProtocol.ORDER);
    caps.push(WorkspaceTerminalProtocol.CATALOG);
    caps.push(WorkspaceAgentProtocol.READ);
    caps.push(WorkspaceAgentProtocol.CONTROL);
    caps.push(WorkspaceTerminalProtocol.READ);
    caps.push(WorkspaceTerminalProtocol.CONTROL);
    caps.push(WorkspaceFileProtocol.READ);
    caps.push(WorkspacePairingProtocol.ADMIN);
    caps.push(WorkspacePairingProtocol.STATUS_CAPABILITY);
    caps.push(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY);
    caps.push(workspace.service.WorkspaceFoldersProtocol.CAPABILITY);
    deadline = clock() + 12000;
    ConnectTimeline.mark("discovered", timelineName());
    direct = fromDescriptor;
    var link = new ConnectionOwner(this);
    owner = link;
    client = new RpcClient(new NativeRpcConnector(hub,
      NativeRpcHub.local(endpoint.socket)), clock, function() return Math.random(), new RpcPeerOptions(
        "exosuit-editor/1",
        caps,
        required,
        2000,
        262144,
        32,
        1048576
      ), function(connection, token, _) link.client.connected(connection, token, expectedInstance, expectedRoot, selected, link),
      100, 1000, 2000);
  }

  /**
    The connection made in `install` (or after it reconnected by itself) completed its handshake: checks the service's
    identity and restores the catalog. Runs on the client that owns the connection now (`handOver`).
  **/
  function connected(connection:RpcConnection, token:Int, expectedInstance:String, expectedRoot:String, selected:Int,
      link:ConnectionOwner):Void {
    var current = client;
    if (current == null || selected != selection) return;
    verified = false;
    if (current.remoteApplication != "exosuit-agent/1") {
      if (direct) refuseDirect() else fail("Unexpected workspace service");
      return;
    }
    connection.call(WorkspaceProtocol.IDENTITY, {workspace: "workspace"}, 2000, function(identity) {
      if (selected != selection || !current.isCurrent(token)) return;
      // Another generation means the descriptor was stale (a service restarted on the same pipe, perhaps in another
      // of its workspace's folders): discover it again. Only the generation it named may disagree about its root.
      if (identity.instance != expectedInstance) {
        if (direct) { refuseDirect(); return; }
        stopConnection();
        retryAt = clock() + 100;
        return;
      }
      if (identity.workspace != "workspace" || identity.root != expectedRoot) {
        if (direct) refuseDirect() else fail("Workspace service identity mismatch");
        return;
      }
      verified = true;
      directPrior = null;
      ConnectTimeline.mark("identity-verified", timelineName());
      var key = choiceKey();
      if (stateDir != null && key != null) choices.connected(key);
      deadline = clock() + 6000;
      spawned = false;
      var view = replica;
      if (view != null) view.restore(
        connection,
        function() {
          var active = link.client;
          return selected == active.selection && active.verified && current.isCurrent(token);
        }
      );
    }, function(failure) {
      if (selected != selection || !current.isCurrent(token)) return;
      if (direct) refuseDirect() else fail("Workspace identity validation failed: " + failure.code);
    }
    );
  }

  public function poll():Void {
    pollUpdateHelper();
    workbench.poll();
    if (!disposed && root != null && choices.revision != choiceRevision) {
      choiceRevision = choices.revision;
      var key = choiceKey();
      var chosen = key == null ? null : choices.stateFor(key);
      if (chosen != stateDir) attach(root, chosen);
    }
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
      if (process.running()) {
        if (client == null) connectFromDescriptor(now);
        if (client == null) return;
        pollConnection(now);
        return;
      }
      // Drain after exit so the final descriptor cannot be lost to a process-state race.
      output += process.readStdout();
      errors += process.readStderr();
      var code = process.exitStatus(), mode = helperMode;
      ConnectTimeline.mark("helper-exit", timelineName(), mode + " code " + code + (errors.length > 0 && errors.length < 400 ? " " + errors : ""));
      stopHelper();
      if (output.length > 16384 || errors.length > 16384) {
        fail("Workspace discovery exceeds its limit");
        return;
      }
      if (code == 0) {
        try {
          var endpoint:LocalWorkspaceEndpoint = JsonWire.decode(output);
          if (direct && client != null && endpoint.generation == instance) confirmDirect(endpoint);
          else {
            // The launcher names another service than the one the descriptor led to (which may already be in use):
            // the connection is replaced, not lost.
            if (client != null) { workbench.expectReplacement(); stopConnection(); }
            install(endpoint);
          }
        } catch (failure:Dynamic) {
          fail(Std.string(failure));
        }
      } else if (mode == "configure-relay") {
        var message = errors.length > 0 ? StringTools.trim(errors) : "Could not configure remote access";
        startHelper("discover");
        pairingsError = message;
        pairingsRevision++;
      } else if (mode == "discover" && code == 4) {
        // The launcher found no running service: a descriptor still there is a stopped service's.
        if (direct && instance.length > 0) directRefused.set(instance, true);
        if (client != null) workbench.expectReplacement();
        spawned = true;
        if (mayStart()) startHelper("launch");
      } else if (mode == "launch" && code == 3) {
        retryAt = now + 250;
      } else {
        fail(errors.length > 0 ? StringTools.trim(errors) : "Workspace startup failed");
      }
      return;
    }
    pollConnection(now);
  }

  /** Drives the connection to the service: the handshake, the catalog replica, readiness and its loss. */
  function pollConnection(now:Float):Void {
    var current = client;
    if (current == null) {
      if (helper == null && now >= retryAt) startHelper("discover");
      return;
    }
    current.poll();
    workbench.poll();
    if (client != current || error != null) return;
    if (current.state == Closed) {
      if (direct && !wasReady) { refuseDirect(); return; }
      if (wasReady) {
        // A dropped descriptor connection is not tried again while the launcher still runs; its answer decides.
        if (direct && instance.length > 0) directRefused.set(instance, true);
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
      if (!wasReady) ConnectTimeline.mark("ready", timelineName());
      recoveringUntil = 0;
      refreshServiceStatus();
      wasReady = true;
      deadline = now + 3000;
      return;
    }
    if (now >= deadline) {
      if (helper != null) {
        // Connected from the descriptor but never ready, and the launcher still runs: its answer decides.
        if (direct) refuseDirect();
      } else if (!spawned) {
        spawned = true;
        if (mayStart()) startHelper("launch");
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

/** Which client a connection's callbacks act on; `LocalWorkspaceClient.handOver` moves it to another client. */
private class ConnectionOwner {
  public var client:LocalWorkspaceClient;
  public function new(client:LocalWorkspaceClient) this.client = client;
}
