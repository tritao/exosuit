package workspace.client;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.client.WorkspaceAgentCreation.AgentCreationStatus;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentProtocol.AgentImageUploadResult;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

private typedef PendingModelList = {
  var cursor:Null<String>;
  var done:Null<WorkspaceAgentProtocol.AgentModelsPage>->Null<String>->Void;
  var connection:RpcConnection;
  var deadline:Float;
  var next:Float;
}

/** Typed terminal and agent RPC resources shared by local and remote transports. */
class RpcWorkspaceWorkbenchClient implements WorkspaceWorkbenchClient implements WorkspaceAgentClient {
  final endpoint:WorkspaceRpcEndpoint;
  final clock:Void -> Float;
  var disposed:Bool = false;
  var observedConnection:Null<RpcConnection>;
  var observedGeneration:Null<String>;

  var catalog:Null<WorkspaceTerminalProtocol.TerminalCatalog>;
  var catalogError:Null<String>;
  var catalogActionError:Null<String>;
  var catalogRevision:Int = 0;
  var catalogPending:Bool = false;
  var catalogMutation:Bool = false;
  var catalogNext:Float = 0;
  var catalogKey:String = "";
  var observedTerminalCreation:Int = 0;

  var agentCatalog:Null<WorkspaceAgentProtocol.AgentCatalog>;
  var agentViews:Map<String, WorkspaceAgentProtocol.AgentView> = [];
  var agentHistoryWindows:Map<String,AgentHistoryWindow> = [];
  var agentTokens:Map<String, Int> = [];
  var agentReadPending:Map<String, Bool> = [];
  var agentReadCount:Int = 0;
  var agentsError:Null<String>;
  var agentActionError:Null<String>;
  var creationError:Null<String>;
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
  var creation:Null<WorkspaceAgentCreation>;
  var pendingModels:Null<PendingModelList>;

  public function new(endpoint:WorkspaceRpcEndpoint, clock:Void -> Float) {
    this.endpoint = endpoint;
    this.clock = clock;
  }

  function rpc():Null < RpcConnection > return disposed ? null : endpoint.rpcConnection();
  function root():Null < String > return endpoint.rootPath();
  function instance():String return endpoint.serviceGeneration();
  function has(capability:String):Bool return endpoint.hasCapability(capability);

  public function poll():Void {
    var current = rpc();
    var generation = current == null ? null : instance();
    if (current != observedConnection || generation != observedGeneration) {
      if (pendingModels != null) {
        var cancelled = pendingModels;
        pendingModels = null;
        cancelled.done(null, "Workspace connection changed");
      }
      var lost = observedConnection != null;
      observedConnection = current;
      observedGeneration = generation;
      catalogActionError = null;
      catalog = null;
      catalogPending = false;
      catalogMutation = false;
      catalogNext = 0;
      catalogKey = "";
      observedTerminalCreation = 0;
      catalogRevision++;
      agentsPending = false;
      agentsRequestToken++;
      agentMutation = false;
      creation = null;
      pendingDiscovery = null;
      discovery = null;
      discoveryToken++;
      agentViews.clear();
      agentHistoryWindows.clear();
      agentTokens.clear();
      agentReadPending.clear();
      agentReadCount = 0;
      agentMutationId = null;
      agentCatalog = null;
      agentActionError = null;
      creationError = null;
      agentsNext = 0;
      agentsRevision++;
      if (lost) {
        catalogError = "Workspace connection changed; refresh terminal sessions";
        agentsError = "Workspace connection changed; reconcile agents before retrying";
      }
    }
    var terminalEvents = current == null ? null : endpoint.terminalEvents();
    if (terminalEvents != null && terminalEvents.catalogRevision != observedTerminalCreation && !catalogPending) {
      // Leave an invalidation unconsumed while a paged catalog read is in flight.
      // Its snapshot may predate creation; fetch again as soon as it completes.
      observedTerminalCreation = terminalEvents.catalogRevision;
      refreshTerminals(true);
    }
    continueDiscovery();
    continueAgentCreate();
    continueModels();
  }

  public function dispose():Void {
    if (disposed) return;
    disposed=true;
    if (pendingModels != null) {
      var cancelled = pendingModels;
      pendingModels = null;
      cancelled.done(null, "Workspace connection closed");
    }
    observedConnection = null;
    observedGeneration = null;
    pendingDiscovery = null;
    discovery = null;
    discoveryToken++;
    creation = null;
    agentViews.clear();
    agentHistoryWindows.clear();
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
  public function agentCreation():Null<AgentCreationStatus> return creation == null ? null : creation.status();
  public function agentRevision():Int return agentsRevision;
  public function agents():Null < WorkspaceAgentProtocol.AgentCatalog > return agentCatalog;
  public function agentError():Null < String > return creationError != null ? creationError : agentActionError == null ? agentsError : agentActionError;
  public function agentView(id:String):Null < WorkspaceAgentProtocol.AgentView > return agentViews.get(id);
  public function listModels(cursor:Null<String>, done:Null<WorkspaceAgentProtocol.AgentModelsPage>->Null<String>->Void):Void {
    var connection = rpc();
    if (connection == null || !canReadAgents()) {
      done(null, "Connect a workspace to load Codex models");
      return;
    }
    pendingModels = {cursor: cursor, done: done, connection: connection, deadline: clock() + 60000, next: 0};
    continueModels();
  }

  function continueModels():Void {
    var pending = pendingModels;
    if (pending == null || clock() < pending.next) return;
    if (clock() >= pending.deadline || rpc() != pending.connection) {
      pendingModels = null;
      pending.done(null, "Codex model catalog did not load");
      return;
    }
    pending.next = pending.deadline;
    pending.connection.call(WorkspaceAgentProtocol.MODELS,
      {workspace: "workspace", instance: instance(), cursor: pending.cursor}, 20000,
      function(page) {
        if (pendingModels != pending) return;
        pendingModels = null;
        pending.done(page, null);
      }, function(error) {
        if (pendingModels != pending) return;
        if (error.code == "provider_starting" && !error.ambiguous) {
          pending.next = clock() + 500;
          return;
        }
        pendingModels = null;
        pending.done(null, error.message);
      });
  }
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
      value.records = records;
      // The catalog is listed every second; an identical listing must not redraw the window.
      var changed = agentsError != null || agentCatalog == null
        || haxe.Json.stringify(agentCatalog) != haxe.Json.stringify(value);
      agentsError = null;
      agentCatalog = value;
      if (changed) agentsRevision++;
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

  public function createAgent(group:String,thread:Null<String>,?created:AgentRecord->Void,?defaults:AgentSessionDefaults):Void {
    var connection=rpc(),workspaceRoot=root();
    if(connection == null || workspaceRoot == null || !canControlAgents() || creation != null) {
      creationError=creation != null ? "A session is already being created. Wait for it to finish."
        : "Connect to a workspace with agent control permission before creating a session.";
      agentsRevision++;return;
    }
    agentsError=null;creationError=null;
    var query:AgentCreate={workspace:"workspace",instance:instance(),id:WorkspaceIds.create("agent"),group:group,
      name:defaults != null && defaults.provider == "claude" ? "Claude" : defaults != null && defaults.provider == "pi" ? "Pi" : defaults != null && defaults.provider == "agentkit" ? "Exosuit" : "Codex",
      provider:defaults == null ? null : defaults.provider,thread:thread,
      defaultModel:thread == null && defaults != null ? defaults.model : null,
      defaultEffort:thread == null && defaults != null ? defaults.effort : null,
      permissionProfile:thread == null && defaults != null ? defaults.permissionProfile : null};
    creation=new WorkspaceAgentCreation(query,connection,workspaceRoot,clock()+60000,created);
    agentsRevision++;continueAgentCreate();
  }

  function failCreation(operation:WorkspaceAgentCreation,message:String):Void {
    if(creation != operation) return;
    creation=null;creationError=message;agentsRevision++;
  }

  function continueAgentCreate():Void {
    var operation=creation;
    if(operation == null) return;
    var connection=operation.connection,query=operation.query;
    if(rpc() != connection || query.instance != instance() || root() != operation.root) {
      failCreation(operation,"Workspace changed; reconcile sessions before retrying creation");return;
    }
    if(operation.inFlight || clock()<operation.next) return;
    if(clock()>=operation.deadline) {failCreation(operation,query.name+" session creation did not complete");return;}
    if(query.provider != null && query.provider != "codex") {
      if(agentCatalog == null) {operation.next=clock()+100;refreshAgents();return;}
      var supported=agentCatalog.providers;
      if(supported == null || !supported.contains(query.provider)) {
        failCreation(operation,"This workspace service does not support "+query.name
          +" sessions. Open Remote Access and update the workspace service, then retry.");return;
      }
    }
    operation.inFlight=true;operation.phase="creating";agentsRevision++;
    connection.call(WorkspaceAgentProtocol.CREATE,query,20000,function(record) {
      if(creation != operation || rpc() != connection || query.instance != instance() || root() != operation.root) return;
      var expected=query.provider == null ? "codex" : query.provider;
      var actual=record.provider == null ? "codex" : record.provider;
      if(record.workspaceRoot != operation.root || record.id != query.id || record.group != query.group || actual != expected) {
        failCreation(operation,"Invalid created agent resource; reconcile sessions before retrying");return;
      }
      creation=null;agentsError=null;creationError=null;
      // Fence catalog snapshots issued before this resource was reserved.
      agentsRequestToken++;agentsPending=false;agentsNext=0;
      if(agentCatalog != null) {
        agentCatalog.records=[for(r in agentCatalog.records) if(r.id != record.id) r];
        agentCatalog.records.push(record);
        agentCatalog.records.sort(function(a,b) return Reflect.compare(a.id,b.id));
      }
      agentsRevision++;
      // Open from the resource itself, never by looking it up in a mutable catalog.
      var completed=operation.completed;
      if(completed != null) completed(record);
      if(rpc() != connection || query.instance != instance()) return;
      agentAction(record.id,"read","",null);
      refreshAgents();
    },function(error) {
      if(creation != operation || rpc() != connection) return;
      operation.inFlight=false;
      if(error.code == "provider_starting" && !error.ambiguous) {
        operation.phase="starting-provider";operation.next=clock()+500;agentsRevision++;return;
      }
      failCreation(operation,error.message);agentsNext=0;
    });
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

  public function agentAction(id:String, action:String, text:String, request:Null<String>, ?model:String, ?effort:String, ?accepted:Void->Void, ?expectedNativeName:String, ?imageIds:Array<String>):Void {
    var connection = rpc();
    if (connection == null ||(action == "read" ? !canReadAgents() : !canControlAgents())) return;
    if ((action == "move" && (agentCatalog == null || agentCatalog.canMove != true))
      || (action == "rename" && (agentCatalog == null || agentCatalog.canRename != true))) {
      agentActionError = "Update the workspace service in Remote Access to " + (action == "rename" ? "rename" : "move")
        + " agent sessions. Restarting the app does not update a service with active sessions.";
      agentsRevision++;
      return;
    }
    if (action == "inspect-name" || action == "rename-native") {
      var catalog = agentCatalog;
      var record = catalog == null ? null : Lambda.find(catalog.records,function(record) return record.id==id);
      var kind = record == null || record.provider == null ? "codex" : record.provider;
      if (catalog == null || catalog.nativeRenameProviders == null || catalog.nativeRenameProviders.indexOf(kind)<0) {
        agentActionError = "Native session renaming is unavailable. Use Rename in Workbench, or update the workspace service and provider adapter.";
        agentsRevision++;return;
      }
    }
    if (request == null && (action == "queue" || action == "steer" || action == "clear-native-queue")) {
      var current = agentViews.get(id);
      request = current == null ? null : current.inputToken;
      if (request == null) {agentActionError = "Refresh this session before submitting a message";agentsRevision++;return;}
    }
    var mutate = action != "read";
    if (mutate ? agentMutation
      : agentReadCount >= 4 || agentReadPending.exists(id) || (agentMutation && agentMutationId == id)) return;
    if (mutate) {
      // User actions take priority over a background read for this session. The
      // token below makes the read response stale, and removing it here keeps
      // the bounded read count accurate when that response eventually arrives.
      if (agentReadPending.exists(id)) {
        cancelHistoryLoad(id,"History loading was interrupted by a session action.");
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
    var generation=instance();
    var query:AgentAction = {workspace:"workspace",instance:generation,id:id,action:action,text:text,request:request,
      model:model,effort:effort,expectedNativeName:expectedNativeName,imageIds:imageIds};
    requestAgentView(connection,id,selected,generation,query,function(inputToken) {
      if (mutate) {
        agentMutation=false; agentMutationId=null;
        // Keep assembly as a preemptible background read. New mutations invalidate it.
        if (!agentReadPending.exists(id)) { agentReadPending.set(id,true); agentReadCount++; }
      }
      var current=agentViews.get(id);
      if (current != null && inputToken != null) current.inputToken=inputToken;
      if (accepted != null) accepted();
      if (mutate) agentActionError=null; else agentsError=null;
      agentsRevision++;
    },function(value) {
      if (rpc()!=connection || instance()!=generation || agentTokens.get(id)!=selected) return;
      if ((action == "rename" || action == "move" || action == "inspect-name" || action == "rename-native") && agentCatalog != null) {
        agentsRequestToken++; agentsPending=false; agentsNext=0;
        for (index in 0...agentCatalog.records.length) if (agentCatalog.records[index].id == id) agentCatalog.records[index]=value.record;
      }
      publishLatestAgentView(connection,id,selected,value);
    },function(error,acknowledged) {
      if (rpc()!=connection || instance()!=generation || agentTokens.get(id)!=selected) return;
      var errorsBefore=agentsError+"\n"+agentActionError;
      if (mutate) { agentMutation=false; agentMutationId=null; }
      finishAgentRead(id);
      if (acknowledged) {
        var message=mutate ? "Action completed, but the session view is unavailable. Refresh the session." : "Session view is unavailable. Refresh the session.";
        if (mutate) agentActionError=message; else agentsError=message;
      } else if (mutate) {
        if (error.code == "provider_starting") { agentActionError=null; agentsError=error.message; }
        else agentActionError=action == "permissions" && error.code == "resolved"
          ? "This workspace service does not support permission changes yet. Update it from Remote Access, then try again." : error.message;
      } else agentsError=error.message;
      if (mutate || errorsBefore != agentsError+"\n"+agentActionError) agentsRevision++;
    });
  }

  public function uploadAgentImage(id:String, bytes:haxe.io.Bytes, done:(Null<String>, Null<String>)->Void):Void {
    var connection = rpc(), view = agentViews.get(id), generation = instance();
    if (connection == null || !canControlAgents() || view == null || view.supportsImageUpload != true
      || bytes == null || bytes.length == 0 || bytes.length > 2 * 1024 * 1024) { done(null, "Image upload is unavailable or the image exceeds 2 MiB."); return; }
    var upload:Null<String> = null, finished = false;
    function fail(message:String):Void {
      if (finished) return; finished = true;
      if (upload != null && rpc() == connection && instance() == generation) removeAgentImage(id, upload);
      done(null, message);
    }
    function send(operation:String, offset:Int, chunk:Null<haxe.io.Bytes>, success:AgentImageUploadResult->Void):Void {
      if (rpc() != connection || instance() != generation) { fail("Workspace connection changed; upload the image again."); return; }
      connection.call(WorkspaceAgentProtocol.IMAGE_UPLOAD, {workspace:"workspace", instance:generation, session:id,
        operation:operation, upload:upload, size:bytes.length, offset:offset, bytes:chunk}, 20000,
        function(result) {
          if (finished) return;
          if (rpc() != connection || instance() != generation) { fail("Workspace connection changed; upload the image again."); return; }
          success(result);
        }, function(error) fail(error == null ? "Image upload failed; select the image to retry" : error.message + "; select the image to retry"));
    }
    var next:Int->Void = null;
    next = function(offset:Int) {
      if (offset == bytes.length) {
        send("finish", offset, null, function(result) {
          if (result == null || result.upload != upload || result.offset != bytes.length || !result.complete) { fail("Invalid image upload response"); return; }
          finished = true; done(upload, null);
        }); return;
      }
      var count = Std.int(Math.min(32768, bytes.length - offset));
      send("chunk", offset, bytes.sub(offset,count), function(result) {
        if (result == null || result.upload != upload || result.offset != offset + count || result.complete) { fail("Invalid image upload response"); return; }
        next(offset + count);
      });
    };
    send("begin", 0, null, function(result) {
      if (result == null || result.upload == null || result.upload.length == 0 || result.offset != 0 || result.complete) { fail("Invalid image upload response"); return; }
      upload = result.upload; next(0);
    });
  }

  public function loadAgentImage(id:String,turn:String,item:String,imageId:String,done:(Null<haxe.io.Bytes>,Null<String>)->Void):Void {
    var connection=rpc(),generation=instance();
    if (connection == null || !canReadAgents() || agentViews.get(id) == null || imageId == null || imageId == "") {done(null,"Sent image is unavailable");return;}
    var finished=false,total = -1,data:Null<haxe.io.Bytes>=null;
    function fail(message:String):Void {if (!finished) {finished=true;done(null,message);}}
    var next:Int->Void=null;
    next=function(offset:Int) {
      if (rpc()!=connection || instance()!=generation || agentViews.get(id)==null) {fail("Workspace connection changed; retry the image");return;}
      connection.call(WorkspaceAgentProtocol.MESSAGE_IMAGE,{workspace:"workspace",instance:generation,session:id,turn:turn,item:item,token:imageId,offset:offset},20000,function(chunk) {
        if (finished) return;
        if (rpc()!=connection || instance()!=generation || agentViews.get(id)==null) {fail("Workspace connection changed; retry the image");return;}
        if (chunk == null || chunk.token != imageId || chunk.offset != offset || chunk.total <= 0 || chunk.total > 2*1024*1024
            || chunk.bytes == null || chunk.bytes.length <= 0 || chunk.bytes.length > 24*1024 || offset+chunk.bytes.length > chunk.total
            || chunk.partial || (total >= 0 && total != chunk.total)) {fail("Invalid sent image response");return;}
        if (data == null) {total=chunk.total;data=haxe.io.Bytes.alloc(total);}
        var target:haxe.io.Bytes=cast data;target.blit(offset,chunk.bytes,0,chunk.bytes.length);
        var end=offset+chunk.bytes.length;
        if (end==total) {finished=true;done(target,null);} else next(end);
      },function(_) fail("Sent image is no longer available"));
    };
    next(0);
  }

  public function loadAgentContent(id:String, turn:String, item:String, token:String, done:(Null<String>, Bool, Null<String>)->Void):Void {
    var connection=rpc(), generation=instance(), view=agentViews.get(id);
    if (connection == null || !canReadAgents() || view == null || view.supportsMessageContent != true || token == null || token == "") {
      done(null,false,"Full message is unavailable"); return;
    }
    var finished=false, data:Null<haxe.io.Bytes> = null, total = -1, partial=false;
    function fail(message:String):Void { if (!finished) { finished=true; done(null,false,message); } }
    var next:Int->Void = null;
    next=function(offset:Int) {
      if (rpc()!=connection || instance()!=generation) { fail("Workspace connection changed; retry loading the message"); return; }
      connection.call(WorkspaceAgentProtocol.MESSAGE_CONTENT,{workspace:"workspace",instance:generation,session:id,turn:turn,item:item,token:token,offset:offset},20000,
        function(chunk) {
          if (finished) return;
          if (rpc()!=connection || instance()!=generation) { fail("Workspace connection changed; retry loading the message"); return; }
          if (chunk == null || chunk.token != token || chunk.offset != offset || chunk.total < 0 || chunk.total > 256*1024
            || chunk.bytes == null || chunk.bytes.length > 24*1024 || chunk.offset+chunk.bytes.length > chunk.total
            || (chunk.bytes.length == 0 && offset != chunk.total) || (total >= 0 && (chunk.total != total || chunk.partial != partial))) {
            fail("Invalid message content response"); return;
          }
          if (data == null) { total=chunk.total; partial=chunk.partial; data=haxe.io.Bytes.alloc(total); }
          var target:haxe.io.Bytes = cast data; target.blit(offset,chunk.bytes,0,chunk.bytes.length);
          var end=offset+chunk.bytes.length;
          if (end == total) {
            if (!workspace.TextFileContent.validUtf8(target)) { fail("Message content has invalid text encoding"); return; }
            finished=true; done(target.toString(),partial,null);
          } else next(end);
        },function(error) fail(error == null ? "Message content is unavailable" : error.message));
    };
    next(0);
  }

  public function removeAgentImage(id:String, upload:String):Void {
    var connection = rpc();
    if (connection == null || !canControlAgents() || upload == null || upload == "") return;
    connection.call(WorkspaceAgentProtocol.IMAGE_UPLOAD, {workspace:"workspace", instance:instance(), session:id,
      operation:"remove", upload:upload, size:0, offset:0, bytes:null}, 5000, function(_) {}, function(_) {});
  }

  function finishAgentRead(id:String):Void {
    if (agentReadPending.exists(id)) {
      agentReadPending.remove(id);
      agentReadCount = Std.int(Math.max(0, agentReadCount - 1));
    }
  }

  /** Snapshot acknowledgement is independent of assembling its potentially large view. */
  function requestAgentView(connection:RpcConnection,id:String,selected:Int,generation:String,query:AgentAction,
      acknowledged:Null<String>->Void, success:AgentView->Void, failure:(RpcError,Bool)->Void):Void {
    var expectedRoot=root(), done=false, ack=false;
    function current():Bool return rpc()==connection && instance()==generation && root()==expectedRoot && agentTokens.get(id)==selected;
    function fail(message:String):Void {
      if (!done && current()) { done=true; failure({code:"invalid_snapshot",message:message,ambiguous:false},ack); }
    }
    if (expectedRoot == null) { fail("Workspace is unavailable"); return; }
    if (agentCatalog == null || agentCatalog.supportsSnapshots != true) {
      connection.call(WorkspaceAgentProtocol.ACTION,query,query.action == "rename-native" ? 60000 : 20000,function(view) {
        if (done || !current()) return;
        if (view == null || view.record == null || view.record.id != id || view.record.workspaceRoot != expectedRoot) { fail("Invalid agent view"); return; }
        ack=true; acknowledged(view.inputToken);
        if (!current()) return;
        done=true; success(view);
      },function(error) { if (!done && current()) {done=true; failure(error,false);} });
      return;
    }
    connection.call(WorkspaceAgentProtocol.ACTION_SNAPSHOT,query,query.action == "rename-native" ? 60000 : 20000,function(first) {
      if (done || !current()) return;
      if (first == null || first.session != id || first.root != expectedRoot) { fail("Invalid session snapshot scope"); return; }
      ack=true; acknowledged(first.inputToken);
      if (!current()) return;
      if (first.snapshotError != null) { fail("Session snapshot unavailable"); return; }
      var assembler:AgentSnapshotAssembler;
      try assembler=new AgentSnapshotAssembler(first,id,cast expectedRoot) catch (_:Dynamic) { fail("Invalid session snapshot"); return; }
      var next:Void->Void = null;
      next=function() {
        if (done || !current()) return;
        if (assembler.complete()) {
          try { var view=assembler.view(); done=true; success(view); } catch (_:Dynamic) fail("Invalid session snapshot view");
          return;
        }
        var offset=assembler.offset;
        connection.call(WorkspaceAgentProtocol.SNAPSHOT_READ,{workspace:"workspace",instance:generation,session:id,
          token:assembler.snapshotToken(),offset:offset},20000,function(chunk) {
          if (done || !current()) return;
          try assembler.add(chunk) catch (_:Dynamic) { fail("Invalid session snapshot chunk"); return; }
          next();
        },function(_) fail("Session snapshot unavailable"));
      };
      next();
    },function(error) { if (!done && current()) {done=true; failure(error,false);} });
  }

  function historyWindow(id:String):AgentHistoryWindow {
    var state=agentHistoryWindows.get(id);
    if (state == null) {state=new AgentHistoryWindow(); agentHistoryWindows.set(id,state);}
    return state;
  }
  public function agentHistory(id:String):AgentHistoryState {
    var state=agentHistoryWindows.get(id);
    return state == null ? {loading:false,error:null,hasOlder:false,detached:false,resetRequired:false} : state.status();
  }
  function cancelHistoryLoad(id:String,reason:String):Void {
    var state=agentHistoryWindows.get(id); if (state == null || !state.loading) return;
    state.loading=false; state.error=reason;
    var done=state.pendingDone; state.pendingDone=null;
    if (done != null) done(reason);
  }
  function publishAgentView(id:String,value:AgentView):Void {
    var previous=agentViews.get(id); agentViews.set(id,value);
    if (previous == null || haxe.Json.stringify(previous) != haxe.Json.stringify(value)) { agentsNext=0; agentsRevision++; }
  }
  function publishLatestAgentView(connection:RpcConnection,id:String,selected:Int,value:AgentView):Void {
    var state=historyWindow(id), previous=agentViews.get(id);
    state.remember(value);
    if (previous == null || previous.items == null || value.items == null) {
      state.cursor=value.itemsNext; state.epoch=value.historyEpoch; state.seen=[]; state.detached=false; state.resetRequired=false; state.error=null;
      finishAgentRead(id); publishAgentView(id,value); return;
    }
    var old:Array<AgentActivityItem>=cast previous.items, fresh:Array<AgentActivityItem>=cast value.items;
    var same=AgentHistoryWindow.sameEpoch(state.epoch,value.historyEpoch);
    // A legacy first page can be reconciled only while no older cursor has been consumed.
    var legacySafe=state.epoch == null && value.historyEpoch == null && state.seen.keys().hasNext() == false;
    if (!same && !legacySafe) {
      state.resetRequired=true; state.error="Activity history changed. Reset to latest to continue.";
      value.items=old.copy(); value.itemsNext=state.cursor;
      finishAgentRead(id); publishAgentView(id,value); return;
    }
    if (state.resetRequired) {
      value.items=old.copy(); value.itemsNext=state.cursor;
      finishAgentRead(id); publishAgentView(id,value); return;
    }
    var watched:Map<String,Bool>=[];
    for (item in old) if (item.state == "inProgress") watched.set(AgentHistoryWindow.key(item),true);
    for (item in fresh) watched.remove(AgentHistoryWindow.key(item));
    if (watched.keys().hasNext()) {
      value.items=old.copy(); value.itemsNext=state.cursor; publishAgentView(id,value);
      bridgeAgentHistory(connection,id,selected,state,old,fresh,cast state.latest,watched,state.detached); return;
    }
    if (state.detached) {
      var replacements:Map<String,AgentActivityItem>=[];
      for (item in fresh) replacements.set(AgentHistoryWindow.key(item),item);
      value.items=[for (item in old) replacements.exists(AgentHistoryWindow.key(item)) ? replacements.get(AgentHistoryWindow.key(item)) : item];
      value.itemsNext=state.cursor; finishAgentRead(id); publishAgentView(id,value); return;
    }
    var combined=AgentHistoryWindow.merge(old,fresh);
    if (combined == null && fresh.length > 0 && old.length > 0) {
      value.items=old.copy(); value.itemsNext=state.cursor; publishAgentView(id,value);
      bridgeAgentHistory(connection,id,selected,state,old,fresh,cast state.latest,[],false); return;
    }
    if (combined == null) combined=old.copy();
    if (!AgentHistoryWindow.within(combined)) {state.detached=true; value.items=old.copy();}
    else value.items=combined;
    if (state.cursor == null && state.seen.keys().hasNext() == false && old.length == 0) state.cursor=value.itemsNext;
    value.itemsNext=state.cursor; state.epoch=value.historyEpoch;
    finishAgentRead(id); publishAgentView(id,value);
  }
  function bridgeAgentHistory(connection:RpcConnection,id:String,selected:Int,state:AgentHistoryWindow,
      old:Array<AgentActivityItem>,fresh:Array<AgentActivityItem>,latest:AgentView,
      watched:Map<String,Bool>,detached:Bool):Void {
    var generation=instance(), cursor=latest.itemsNext, visited:Map<String,Bool>=[];
    state.loading=true; state.error=null; agentsRevision++;
    function fail(reason:String):Void {
      state.loading=false; state.resetRequired=true; state.error=reason;
      finishAgentRead(id); agentsRevision++;
    }
    var step:Void->Void=null;
    step=function() {
      if (rpc()!=connection || instance()!=generation || agentTokens.get(id)!=selected) return;
      if (cursor == null || visited.exists(cursor) || !AgentHistoryWindow.within(fresh)) { fail("History has a gap. Reset to latest to continue."); return; }
      var requested:String=cast cursor; visited.set(requested,true);
      var query:AgentAction={workspace:"workspace",instance:generation,id:id,action:"read",text:"",request:null,after:requested};
      requestAgentView(connection,id,selected,generation,query,function(_) {},function(page) {
        if (page.items == null || (state.epoch != null && page.historyEpoch != state.epoch)
            || (page.itemsNext != null && visited.exists(page.itemsNext))) { fail("History changed while connecting pages. Reset to latest."); return; }
        var pageItems:Array<AgentActivityItem>=cast page.items;
        for (item in pageItems) watched.remove(AgentHistoryWindow.key(item));
        fresh=AgentHistoryWindow.prepend(fresh,pageItems);
        if (!AgentHistoryWindow.within(fresh)) { fail("History has a gap. Reset to latest to continue."); return; }
        var merged=AgentHistoryWindow.merge(old,fresh);
        if (merged != null && !watched.keys().hasNext()) {
          var current=agentViews.get(id);
          if (current != null) {
            var updated=AgentHistoryWindow.copyView(current);
            if (detached || !AgentHistoryWindow.within(merged)) {
              var replacements:Map<String,AgentActivityItem>=[];
              for (item in fresh) replacements.set(AgentHistoryWindow.key(item),item);
              updated.items=[for (item in old) replacements.exists(AgentHistoryWindow.key(item)) ? replacements.get(AgentHistoryWindow.key(item)) : item];
              state.detached=true;
            } else updated.items=merged;
            updated.itemsNext=state.cursor; publishAgentView(id,updated);
          }
          state.loading=false; state.error=null; finishAgentRead(id); agentsRevision++; return;
        }
        cursor=page.itemsNext; step();
      },function(_,_) fail("History changed while connecting pages. Reset to latest."));
    };
    step();
  }
  public function loadOlderAgentItems(id:String,done:Null<String>->Void):Void {
    var state=agentHistoryWindows.get(id), connection=rpc(), current=agentViews.get(id);
    if (state == null || connection == null || current == null || state.cursor == null || state.loading || state.resetRequired
        || agentReadPending.exists(id) || (agentMutation && agentMutationId == id) || agentReadCount >= 4) {
      done("Older activity is unavailable right now."); return;
    }
    var requested:String=cast state.cursor, generation=instance(), selected=++agentSelection;
    agentTokens.set(id,selected); agentReadPending.set(id,true); agentReadCount++;
    state.loading=true; state.error=null; state.pendingDone=done; agentsRevision++;
    var query:AgentAction={workspace:"workspace",instance:generation,id:id,action:"read",text:"",request:null,after:requested};
    function fail(reason:String,reset:Bool):Void {
      state.loading=false; state.error=reason; state.resetRequired=reset;
      finishAgentRead(id); var callback=state.pendingDone; state.pendingDone=null; agentsRevision++;
      if (callback != null) callback(reason);
    }
    requestAgentView(connection,id,selected,generation,query,function(_) {},function(page) {
      if (page.items == null || (state.epoch != null && page.historyEpoch != state.epoch)
        || (page.itemsNext != null && (page.itemsNext == requested || state.seen.exists(page.itemsNext)))) {
        fail("History changed or returned an invalid cursor. Reset to latest.",true); return;
      }
      var old:Array<AgentActivityItem>=current.items == null ? [] : cast current.items;
      var older:Array<AgentActivityItem>=cast page.items;
      var merged=AgentHistoryWindow.prepend(old,older);
      if (merged.length == old.length && page.itemsNext != null) {fail("History page made no progress. Reset to latest.",true);return;}
      while (!AgentHistoryWindow.within(merged) && merged.length > older.length) { merged.pop(); state.detached=true; }
      if (!AgentHistoryWindow.within(merged)) {fail("This activity page exceeds the history window limit.",false);return;}
      state.seen.set(requested,true); state.cursor=page.itemsNext; state.loading=false; state.error=null;
      var updated=AgentHistoryWindow.copyView(current); updated.items=merged; updated.itemsNext=state.cursor;
      finishAgentRead(id); publishAgentView(id,updated);
      var callback=state.pendingDone; state.pendingDone=null; agentsRevision++;
      if (callback != null) callback(null);
    },function(error,_) fail(error.code == "invalid_cursor" ? "History changed. Reset to latest." : error.message,error.code == "invalid_cursor"));
  }
  public function resetAgentHistory(id:String):Void {
    var state=agentHistoryWindows.get(id); if (state == null) return;
    if (state.loading) { agentTokens.set(id,++agentSelection); cancelHistoryLoad(id,"History loading was cancelled."); finishAgentRead(id); }
    var latest=state.reset(); if (latest != null) { publishAgentView(id,latest); agentsRevision++; }
  }

  public function canEditGroups():Bool return rpc() != null
    && endpoint.supportsWorkspaceGroups() && has(WorkspaceProtocol.TREE) && has(WorkspaceProtocol.WRITE);

  public function canRemoveGroups():Bool return canEditGroups() && has(WorkspaceProtocol.REMOVE);

  public function canReadTerminals():Bool return rpc() != null && has(WorkspaceTerminalProtocol.READ);

  public function canControlTerminals():Bool return rpc() != null
    && has(WorkspaceTerminalProtocol.CONTROL) && has(WorkspaceTerminalProtocol.CATALOG);

  public function canCreateTerminals():Bool return canReadTerminals()
    && canControlTerminals();

  public function canCreateGroupedTerminals():Bool return canCreateTerminals()
    && endpoint.supportsWorkspaceGroups() && has(WorkspaceProtocol.TREE);

  public function terminalCatalog():Null < WorkspaceTerminalProtocol.TerminalCatalog > return catalog;
  public function terminalCatalogError():Null < String > return catalogActionError == null ? catalogError : catalogActionError;
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
    if (force) {catalogError = null;catalogActionError = null;}
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
      // A refresh that clears an error must redraw even when the catalog itself is unchanged.
      var errorCleared = catalogError != null;
      catalogError = null;
      if (key != catalogKey || errorCleared) {
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
    catalogError = null;catalogActionError = null;
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
    catalogActionError = error.ambiguous ? "Session change may have completed; refresh before retrying"
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
    create:Bool,
    ?done:(Null<WorkspaceProtocol.WorkspaceGroup>, Null<String>)->Void
  ):Void {
    var connection = rpc(), epoch = endpoint.workspaceEpoch();
    if (owner != instance()) {
      catalogError = "Workspace changed; reopen the group action";
      catalogRevision++;
      if (done != null) done(null, catalogError);
      return;
    }
    if (connection == null || epoch == null || !canEditGroups() || !catalogReady()) {
      if (done != null) done(null, "Workspace group editing is unavailable");
      return;
    }
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
      function(result) { catalogCompleted(connection); if (done != null) done(result.group, null); },
      function(error) { catalogFailed(connection, error); if (done != null) done(null, error.message); }
    );
  }

  public function removeGroup(owner:String, group:WorkspaceProtocol.WorkspaceGroup):Void {
    var connection = rpc(), epoch = endpoint.workspaceEpoch();
    if (owner != instance() || connection == null || epoch == null || !canRemoveGroups() || !catalogReady()) return;
    connection.call(WorkspaceProtocol.GROUP, {
      workspace:"workspace", epoch:epoch, operation:WorkspaceIds.create("operation"), group:group.id,
      expectedRevision:group.revision, name:group.name, action:"delete", parent:group.parent, cwd:group.cwd, order:group.order
    }, 2000, function(_) catalogCompleted(connection), function(error) catalogFailed(connection,error));
  }

  public function restartTerminal(record:TerminalRecord):Void {
    var connection = rpc(), snapshot = catalog;
    if (connection == null || snapshot == null || !canReadTerminals() || !canControlTerminals() || catalogMutation) return;
    if (record.workspaceRoot != root() || !Lambda.exists(snapshot.terminals, function(current)
      return current.id == record.id && current.instance == record.instance && haxe.Int64.compare(current.revision, record.revision) == 0)) {
      catalogActionError = "This terminal changed. Refresh before restarting it.";catalogRevision++;return;
    }
    if (record.state == "running" || record.state == "starting" || !catalogReady()) return;
    var owner = instance();
    WorkspaceTerminalRestart.request(connection,owner,record.id,null,
      function() return rpc() == connection && instance() == owner && root() == record.workspaceRoot && canReadTerminals() && canControlTerminals(),
      function(_) catalogCompleted(connection),function(error) {
        if (error.code == "terminal_running") {catalogCompleted(connection);return;}
        catalogFailed(connection,{code:error.code,message:WorkspaceTerminalRestart.message(error),ambiguous:false});
      });
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

  public function closeTerminal(record:TerminalRecord, ?closed:Void->Void):Void {
    var connection=rpc(),snapshot=catalog,owner=instance(),scope=root();
    if(connection==null || snapshot==null || !canControlTerminals() || catalogMutation) return;
    if(record.workspaceRoot!=scope || !Lambda.exists(snapshot.terminals,function(current)
      return current.id==record.id && current.instance==record.instance && haxe.Int64.compare(current.revision,record.revision)==0)) {
      catalogActionError="This terminal changed. Refresh before closing it.";catalogRevision++;return;
    }
    if(!catalogReady()) return;
    connection.call(WorkspaceTerminalProtocol.FORGET,{
      workspace:"workspace",instance:owner,id:record.id,resourceInstance:record.instance,
      expectedRevision:record.revision,terminate:true
    },5000,function(result) {
      if(rpc()!=connection || instance()!=owner || root()!=scope) return;
      if(result.id!=record.id || result.instance!=owner || result.workspace!="workspace") {
        catalogFailed(connection,{code:"invalid_response",message:"Terminal close could not be confirmed. Refresh before retrying.",ambiguous:false});return;
      }
      if(catalog!=null) catalog.terminals=[for(current in catalog.terminals) if(current.id!=record.id) current];
      catalogCompleted(connection);
      if(closed!=null) closed();
    },function(error) {
      var message=error.code=="terminal_running" || error.code=="unknown_method"
        ? "Update the workspace service in Remote Access to close running terminals."
        : error.ambiguous || error.code=="timeout" ? "Terminal close could not be confirmed. Refresh before retrying; its views have been kept open."
        : error.message;
      catalogFailed(connection,{code:error.code,message:message,ambiguous:false});
    });
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
