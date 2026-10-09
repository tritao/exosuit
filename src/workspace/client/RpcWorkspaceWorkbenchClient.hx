package workspace.client;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Typed terminal and agent RPC resources shared by local and remote transports. */
class RpcWorkspaceWorkbenchClient implements WorkspaceWorkbenchClient implements WorkspaceAgentClient {
  final endpoint:WorkspaceRpcEndpoint;
  final clock:Void -> Float;
  var observedConnection:Null<RpcConnection>;

  var catalog:Null<WorkspaceTerminalProtocol.TerminalCatalog>;
  var catalogError:Null<String>;
  var catalogRevision:Int = 0;
  var catalogPending:Bool = false;
  var catalogMutation:Bool = false;
  var catalogNext:Float = 0;
  var catalogKey:String = "";

  var agentCatalog:Null<WorkspaceAgentProtocol.AgentCatalog>;
  var agentViews:Map<String, WorkspaceAgentProtocol.AgentView> = [];
  var agentTokens:Map<String, Int> = [];
  var agentReadPending:Map<String, Bool> = [];
  var agentReadCount:Int = 0;
  var agentsError:Null<String>;
  var agentActionError:Null<String>;
  var agentsPending:Bool = false;
  var agentsRequestToken:Int = 0;
  var agentsNext:Float = 0;
  var agentMutation:Bool = false;
  var agentMutationId:Null<String>;
  var agentSelection:Int = 0;
  var agentsRevision:Int = 0;
  var pendingDiscovery:Null<WorkspaceAgentProtocol.AgentDiscoveryQuery>;
  var discovery:Null<WorkspaceAgentProtocol.AgentDiscovery>;
  var discoveryToken:Int = 0;
  var discoveryNext:Float = 0;
  var discoveryDeadline:Float = 0;
  var pendingAgentCreate:Null<WorkspaceAgentProtocol.AgentCreate>;
  var agentCreated:Null < String -> Void >;
  var createNext:Float = 0;
  var createDeadline:Float = 0;

  public function new(endpoint:WorkspaceRpcEndpoint, clock:Void -> Float) {
    this.endpoint = endpoint;
    this.clock = clock;
  }

  function rpc():Null < RpcConnection > return endpoint.rpcConnection();
  function root():Null < String > return endpoint.rootPath();
  function instance():String return endpoint.serviceGeneration();
  function has(capability:String):Bool return endpoint.hasCapability(capability);

  public function poll():Void {
    var current = rpc();
    if (current != observedConnection) {
      var lost = observedConnection != null;
      observedConnection = current;
      catalog = null;
      catalogPending = false;
      catalogMutation = false;
      catalogNext = 0;
      catalogKey = "";
      catalogRevision++;
      agentsPending = false;
      agentsRequestToken++;
      agentMutation = false;
      pendingAgentCreate = null;
      agentCreated = null;
      pendingDiscovery = null;
      discovery = null;
      discoveryToken++;
      agentViews.clear();
      agentTokens.clear();
      agentReadPending.clear();
      agentReadCount = 0;
      agentMutationId = null;
      agentCatalog = null;
      agentActionError = null;
      agentsNext = 0;
      agentsRevision++;
      if (lost) {
        catalogError = "Workspace connection changed; refresh terminal sessions";
        agentsError = "Workspace connection changed; reconcile agents before retrying";
      }
    }
    continueDiscovery();
    continueAgentCreate();
  }

  public function dispose():Void {
    observedConnection = null;
    pendingDiscovery = null;
    discovery = null;
    discoveryToken++;
    pendingAgentCreate = null;
    agentCreated = null;
    agentViews.clear();
    agentTokens.clear();
    agentReadPending.clear();
    agentReadCount = 0;
    agentMutationId = null;
    agentCatalog = null;
    catalog = null;
  }

  public function agentService():WorkspaceAgentClient return this;
  public function canReadAgents():Bool return rpc() != null && has(WorkspaceAgentProtocol.READ);
  public function canControlAgents():Bool return canReadAgents() && has(WorkspaceAgentProtocol.CONTROL);
  public function agentBusy():Bool return agentMutation;
  public function agentRevision():Int return agentsRevision;
  public function agents():Null < WorkspaceAgentProtocol.AgentCatalog > return agentCatalog;
  public function agentError():Null < String > return agentActionError == null ? agentsError : agentActionError;
  public function agentView(id:String):Null < WorkspaceAgentProtocol.AgentView > return agentViews.get(id);
  public function discoveredAgents():Null < WorkspaceAgentProtocol.AgentDiscovery > return discovery;

  public function refreshAgents():Void {
    var connection = rpc();
    if (connection == null || !has(WorkspaceAgentProtocol.READ) || agentsPending || clock() < agentsNext) return;
    agentsPending = true;
    var requestToken = ++agentsRequestToken;
    agentsNext = clock() + 1000;
    loadAgentPage(connection, requestToken, null, []);
  }

  function loadAgentPage(
    connection:RpcConnection,
    requestToken:Int,
    after:Null<String>,
    records:Array<WorkspaceAgentProtocol.AgentRecord>
  ):Void {
    connection.call(WorkspaceAgentProtocol.LIST,
      {workspace: "workspace", instance: instance(), after: after}, 3000, function(value) {
      if (rpc() != connection || requestToken != agentsRequestToken) return;
      var workspaceRoot = root();
      if (workspaceRoot == null || value.root != workspaceRoot
        || value.instance != instance() || value.records.length > 6 || records.length + value.records.length > 32) {
        agentsPending = false;
        agentsError = "Invalid agent catalog";
        agentsRevision++;
        return;
      }
      var last = after;
      for (record in value.records) {
        if (record.workspaceRoot != workspaceRoot ||(last != null && Reflect.compare(record.id, last) <= 0)) {
          agentsPending = false;
          agentsError = "Invalid agent scope or page";
          agentsRevision++;
          return;
        }
        records.push(record);
        last = record.id;
      }
      if (value.next != null) {
        if (value.records.length == 0 || value.next != last) {
          agentsPending = false;
          agentsError = "Invalid agent cursor";
          agentsRevision++;
          return;
        }
        loadAgentPage(connection, requestToken, value.next, records);
        return;
      }
      agentsPending = false;
      agentsError = null;
      agentsRevision++;
      value.records = records;
      agentCatalog = value;
    }, function(error) {
      if (rpc() == connection && requestToken == agentsRequestToken) {
        agentsPending = false;
        agentsError = error.message;
        agentsRevision++;
      }
    }
    );
  }

  public function discoverAgents(group:String, cursor:Null<String>):Void {
    if (rpc() == null || !canControlAgents()) return;
    discoveryToken++;
    discovery = null;
    agentsError = null;
    agentsRevision++;
    pendingDiscovery = {workspace: "workspace", instance: instance(), group: group, cursor: cursor};
    discoveryDeadline = clock() + 60000;
    discoveryNext = 0;
    continueDiscovery();
  }

  function continueDiscovery():Void {
    var connection = rpc(), query = pendingDiscovery;
    if (connection == null || query == null || clock() < discoveryNext) return;
    if (clock() >= discoveryDeadline || query.instance != instance()) {
      pendingDiscovery = null;
      agentsError = "Codex thread discovery did not complete";
      agentsRevision++;
      return;
    }
    var token = discoveryToken;
    discoveryNext = discoveryDeadline;
    connection.call(WorkspaceAgentProtocol.DISCOVER, query, 20000, function(value) {
      if (rpc() != connection || token != discoveryToken) return;
      pendingDiscovery = null;
      discovery = value;
      agentsError = null;
      agentsRevision++;
    }, function(error) {
      if (rpc() != connection || token != discoveryToken) return;
      if (error.code == "provider_starting" && !error.ambiguous) {
        discoveryNext = clock() + 500;
        return;
      }
      pendingDiscovery = null;
      agentsError = error.message;
      agentsRevision++;
    }
    );
  }

  public function createAgent(group:String, thread:Null<String>, ? created:String -> Void):Void {
    if (rpc() == null || !canControlAgents() || agentMutation) return;
    agentMutation = true;
    agentsError = null;
    agentCreated = created;
    pendingAgentCreate = {
      workspace: "workspace",
      instance: instance(),
      id: WorkspaceIds.create("agent"),
      group: group,
      name: "Codex",
      thread: thread
    };
    createDeadline = clock() + 60000;
    createNext = 0;
    continueAgentCreate();
  }

  function continueAgentCreate():Void {
    var connection = rpc(), query = pendingAgentCreate;
    if (connection == null || query == null || clock() < createNext) return;
    if (clock() >= createDeadline || query.instance != instance()) {
      pendingAgentCreate = null;
      agentMutation = false;
      agentsError = "Codex startup did not complete";
      agentsRevision++;
      return;
    }
    createNext = createDeadline;
    connection.call(WorkspaceAgentProtocol.CREATE, query, 20000, function(record) {
      if (rpc() != connection) return;
      pendingAgentCreate = null;
      agentMutation = false;
      agentsNext = 0;
      agentsRevision++;
      if (record.workspaceRoot != root()) {
        agentsError = "Invalid created agent scope";
        return;
      }
      agentsError = null;
      if (agentCatalog != null) {
        var found = false;
        for (index in 0...agentCatalog.records.length) if (agentCatalog.records[index].id == record.id) {
          agentCatalog.records[index] = record;
          found = true;
          break;
        }
        if (!found) agentCatalog.records.push(record);
      }
      var callback = agentCreated;
      agentCreated = null;
      if (callback != null) callback(record.id);
      agentAction(record.id, "read", "", null);
    }, function(error) {
      if (rpc() != connection) return;
      if (error.code == "provider_starting" && !error.ambiguous) {
        createNext = clock() + 500;
        agentsError = error.message;
        agentsRevision++;
        return;
      }
      pendingAgentCreate = null;
      agentMutation = false;
      agentsError = error.message;
      agentsNext = 0;
      agentsRevision++;
    }
    );
  }

  public function deleteAgent(id:String, ?deleted:Void->Void):Void {
    var connection = rpc();
    if (connection == null || !canControlAgents() || agentMutation || id == null || id.length == 0 || id.length > 128) return;
    if (agentReadPending.exists(id)) {
      agentReadPending.remove(id);
      agentReadCount = Std.int(Math.max(0, agentReadCount - 1));
    }
    agentMutation = true;
    agentMutationId = id;
    var selected = ++agentSelection;
    agentTokens.set(id, selected);
    agentsError = null;
    agentActionError = null;
    connection.call(WorkspaceAgentProtocol.ACTION, {
      workspace: "workspace",
      instance: instance(),
      id: id,
      action: "delete",
      text: "",
      request: null,
      model: null,
      effort: null
    }, 20000, function(value) {
      if (rpc() != connection || agentTokens.get(id) != selected) return;
      agentMutation = false;
      agentMutationId = null;
      if (value.record.id != id || value.record.workspaceRoot != root()) {
        agentActionError = "Invalid removed agent scope";
        agentsRevision++;
        return;
      }
      if (agentCatalog != null)
        agentCatalog.records = [for (record in agentCatalog.records) if (record.id != id) record];
      agentsRequestToken++;
      agentsPending = false;
      agentViews.remove(id);
      agentTokens.remove(id);
      agentsNext = 0;
      agentsRevision++;
      refreshAgents();
      if (deleted != null) deleted();
    }, function(error) {
      if (rpc() != connection || agentTokens.get(id) != selected) return;
      if (error.code == "unknown_agent") {
        agentMutation = false;
        agentMutationId = null;
        if (agentCatalog != null)
          agentCatalog.records = [for (record in agentCatalog.records) if (record.id != id) record];
        agentsRequestToken++;
        agentsPending = false;
        agentViews.remove(id);
        agentTokens.remove(id);
        agentsNext = 0;
        agentsRevision++;
        refreshAgents();
        if (deleted != null) deleted();
        return;
      }
      agentMutation = false;
      agentMutationId = null;
      agentActionError = error.message;
      agentsNext = 0;
      agentsRevision++;
    });
  }

  public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String):Void {
    var connection = rpc();
    if (connection == null ||(action == "read" ? !canReadAgents() : !canControlAgents())) return;
    var mutate = action != "read";
    if (mutate ? agentMutation
      : agentReadCount >= 4 || agentReadPending.exists(id) || (agentMutation && agentMutationId == id)) return;
    if (mutate) {
      // User actions take priority over a background read for this session. The
      // token below makes the read response stale, and removing it here keeps
      // the bounded read count accurate when that response eventually arrives.
      if (agentReadPending.exists(id)) {
        agentReadPending.remove(id);
        agentReadCount = Std.int(Math.max(0, agentReadCount - 1));
      }
      agentMutation = true;
      agentMutationId = id;
    } else {
      agentReadPending.set(id, true);
      agentReadCount++;
    }
    var selected =++ agentSelection;
    agentTokens.set(id, selected);
    if (mutate) {
      agentsError = null;
      agentActionError = null;
    }
    connection.call(WorkspaceAgentProtocol.ACTION, {
      workspace: "workspace",
      instance: instance(),
      id: id,
      action: action,
      text: text,
      request: request,
      model: model,
      effort: effort
    }, 20000, function(value) {
      if (rpc() != connection || agentTokens.get(id) != selected) return;
      if (mutate) {
        agentMutation = false;
        agentMutationId = null;
      } else {
        agentReadPending.remove(id);
        agentReadCount--;
      }
      if (value.record.workspaceRoot != root() || value.record.id != id) {
        agentsError = "Invalid agent view";
        return;
      }
      if (mutate) agentActionError = null;
      else agentsError = null;
      agentViews.set(id, value);
      agentsNext = 0;
      agentsRevision++;
    }, function(error) {
      if (rpc() == connection && agentTokens.get(id) == selected) {
        if (mutate) {
          agentMutation = false;
          agentMutationId = null;
        } else {
          agentReadPending.remove(id);
          agentReadCount--;
        }
        if (mutate) {
          if (error.code == "provider_starting") {
            agentActionError = null;
            agentsError = error.message;
          } else agentActionError = action == "permissions" && error.code == "resolved"
            ? "This workspace service does not support permission changes yet. Update it from Remote Access, then try again."
            : error.message;
        } else agentsError = error.message;
        agentsRevision++;
      }
    }
    );
  }

  public function canEditGroups():Bool return rpc() != null
    && endpoint.supportsWorkspaceGroups() && has(WorkspaceProtocol.TREE) && has(WorkspaceProtocol.WRITE);

  public function canReadTerminals():Bool return rpc() != null && has(WorkspaceTerminalProtocol.READ);

  public function canControlTerminals():Bool return rpc() != null
    && has(WorkspaceTerminalProtocol.CONTROL) && has(WorkspaceTerminalProtocol.CATALOG);

  public function canCreateTerminals():Bool return canReadTerminals()
    && canControlTerminals() && endpoint.supportsWorkspaceGroups() && has(WorkspaceProtocol.TREE);

  public function terminalCatalog():Null < WorkspaceTerminalProtocol.TerminalCatalog > return catalog;
  public function terminalCatalogError():Null < String > return catalogError;
  public function terminalCatalogRevision():Int return catalogRevision;
  public function terminalCatalogBusy():Bool return catalogMutation;

  public function refreshTerminals(force:Bool):Void {
    if (root() == null) {
      if (force) {
        catalogError = "Workspace is not connected";
        catalogRevision++;
      }
      return;
    }
    var connection = rpc();
    if (connection == null || catalogPending ||(!force && clock() < catalogNext)) return;
    if (!has(WorkspaceTerminalProtocol.READ) || !has(WorkspaceTerminalProtocol.CATALOG)) {
      if (catalogError == null) {
        catalogError = "This workspace service does not allow terminal discovery";
        catalogRevision++;
      }
      return;
    }
    if (force) catalogError = null;
    catalogPending = true;
    catalogNext = clock() + 1000;
    loadTerminalPage(connection, null, []);
  }

  function loadTerminalPage(
    connection:RpcConnection,
    after:Null<String>,
    records:Array<WorkspaceTerminalProtocol.TerminalRecord>
  ):Void {
    connection.call(WorkspaceTerminalProtocol.LIST,
      {workspace: "workspace", instance: instance(), after: after}, 2000, function(value) {
      if (rpc() != connection) return;
      var workspaceRoot = root();
      if (workspaceRoot == null) {
        catalogPending = false;
        catalogError = "Workspace disconnected";
        catalogRevision++;
        return;
      }
      if (value.workspaceRoot == null && !endpoint.supportsWorkspaceGroups()) {
        value.workspaceRoot = workspaceRoot;
        for (record in value.terminals) if (record.workspaceRoot == null
          && record.cwd == workspaceRoot) record.workspaceRoot = workspaceRoot;
      }
      if (value.instance != instance()
        || value.workspaceRoot != workspaceRoot || value.terminals.length > WorkspaceTerminalProtocol.CATALOG_PAGE_LIMIT
        || value.groups.length > 32 || records.length + value.terminals.length > 256) {
        catalogPending = false;
        catalogError = "Invalid terminal catalog";
        catalogRevision++;
        return;
      }
      var last = after;
      for (record in value.terminals) {
        if (record.workspaceRoot != workspaceRoot || record.id == null ||(last != null && Reflect.compare(
          record.id,
          last
        ) <= 0)) {
          catalogPending = false;
          catalogError = "Invalid terminal catalog page";
          catalogRevision++;
          return;
        }
        records.push(record);
        last = record.id;
      }
      if (value.next != null) {
        if (value.terminals.length == 0 || value.next != last) {
          catalogPending = false;
          catalogError = "Invalid terminal catalog cursor";
          catalogRevision++;
          return;
        }
        loadTerminalPage(connection, value.next, records);
        return;
      }
      catalogPending = false;
      value.terminals = records;
      var key = value.instance;
      for (group in value.groups) key += "|g:" + group.id + ":" + group.revision;
      for (record in records) key += "|t:" + record.id + ":" + record.revision + ":" + record.available;
      catalog = value;
      catalogError = null;
      if (key != catalogKey) {
        catalogKey = key;
        catalogRevision++;
      }
    }, function(error) {
      if (rpc() == connection) {
        catalogPending = false;
        catalogError = error.message;
        catalogRevision++;
      }
    }
    );
  }

  function catalogReady():Bool {
    if (catalogMutation) return false;
    if (rpc() == null || !canControlTerminals()) {
      catalogError = "Workspace terminal catalog is not available";
      catalogRevision++;
      return false;
    }
    catalogError = null;
    catalogMutation = true;
    catalogRevision++;
    return true;
  }

  function catalogCompleted(connection:RpcConnection):Void {
    if (rpc() != connection) return;
    catalogMutation = false;
    catalogNext = 0;
    catalogRevision++;
    refreshTerminals(false);
  }

  function catalogFailed(connection:RpcConnection, error:RpcError):Void {
    if (rpc() != connection) return;
    catalogMutation = false;
    catalogError = error.ambiguous ? "Session change may have completed; refresh before retrying"
      : error.code == "stale_revision" ? "This session changed. Reload its name/group before saving." : error.message;
    catalogNext = 0;
    catalogRevision++;
    refreshTerminals(false);
  }

  public function renameTerminal(record:WorkspaceTerminalProtocol.TerminalRecord, name:String, group:String):Void {
    var connection = rpc();
    if (record.workspaceRoot != root() || connection == null || !catalogReady()) return;
    connection.call(
      WorkspaceTerminalProtocol.RENAME,
      {
      workspace: "workspace",
      instance: instance(),
      id: record.id,
      name: name,
      group: group,
      expectedRevision: record.revision
    },
      2000,
      function(_) catalogCompleted(connection),
      function(error) catalogFailed(
        connection,
        error
      )
    );
  }

  public function changeGroup(
    owner:String,
    group:WorkspaceProtocol.WorkspaceGroup,
    name:String,
    parent:Null<String>,
    cwd:Null<String>,
    order:Int,
    create:Bool
  ):Void {
    var connection = rpc(), epoch = endpoint.workspaceEpoch();
    if (owner != instance()) {
      catalogError = "Workspace changed; reopen the group editor";
      catalogRevision++;
      return;
    }
    if (connection == null || epoch == null || !canEditGroups() || !catalogReady()) return;
    connection.call(
      WorkspaceProtocol.GROUP,
      {
      workspace: "workspace",
      epoch: epoch,
      operation: WorkspaceIds.create("operation"),
      group: group.id,
      expectedRevision: create ? 0 : group.revision,
      name : name,
      action : create ? "create" : "update",
      parent : parent,
      cwd : cwd,
      order : order
    },
      2000,
      function(_) catalogCompleted(connection),
      function(error) catalogFailed(
        connection,
        error
      )
    );
  }

  public function stopTerminal(record:WorkspaceTerminalProtocol.TerminalRecord):Void {
    var connection = rpc();
    if (record.workspaceRoot != root() || connection == null || !catalogReady()) return;
    connection.call(
      WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "workspace", instance: instance(), id: record.id},
      2000,
      function(_) catalogCompleted(connection),
      function(error) catalogFailed(
        connection,
        error
      )
    );
  }

  public function forgetTerminal(record:WorkspaceTerminalProtocol.TerminalRecord):Void {
    var connection = rpc();
    if (record.workspaceRoot != root() || connection == null || !catalogReady()) return;
    connection.call(
      WorkspaceTerminalProtocol.FORGET,
      {
      workspace: "workspace",
      instance: instance(),
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    },
      2000,
      function(_) catalogCompleted(connection),
      function(error) catalogFailed(
        connection,
        error
      )
    );
  }
}
