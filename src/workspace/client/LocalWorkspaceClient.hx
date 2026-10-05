package workspace.client;

import haxeon.rpc.*;
import haxeon.wire.JsonWire;
import process.ProcessManager;
import process.OwnedProcess;
import sys.FileSystem;
import NativeKitEvents;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcConnector;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceReplica;
import workspace.service.WorkspaceAgentProtocol;

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
}

/** Nonblocking native attachment. Closing a client never owns/stops the shared daemon. */
class LocalWorkspaceClient implements WorkspaceAttachment implements workspace.client.WorkspaceWorkbenchClient implements workspace.client.WorkspaceAgentClient {
  public var root(default, null):Null<String>;
  public var error(default, null):Null<String>;
  public var instance(default, null):String = "";
  public var ready(get, never):Bool;

  final hub:NativeRpcHub;
  final processes:ProcessManager;
  final launcher:String;
  final clock:Void -> Float;
  final environment:Null<Map < String, String>>;
  var client:Null<RpcClient>;
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
  var catalog:Null<workspace.service.WorkspaceTerminalProtocol.TerminalCatalog>;
  var catalogError:Null<String>;
  var catalogRevision:Int = 0;
  var catalogPending:Bool = false;
  var catalogMutation:Bool = false;
  var catalogNext:Float = 0;
  var catalogKey:String = "";

  public function agentService():workspace.client.WorkspaceAgentClient return this;
  public function canReadAgents():Bool return ready && client!=null && client.capabilities().indexOf(WorkspaceAgentProtocol.READ)>=0;
  public function canControlAgents():Bool return canReadAgents() && client!=null && client.capabilities().indexOf(WorkspaceAgentProtocol.CONTROL)>=0;
  public function agentBusy():Bool return agentMutation;
  var agentCatalog:Null<AgentCatalog>;
  var agentConnection:Null<RpcConnection>;
  var discovery:Null<AgentDiscovery>;
  public function discoveredAgents():Null<AgentDiscovery> return discovery;
  public function discoverAgents(group:String,cursor:Null<String>):Void {
    var c=rpc();if(c==null) return;
    c.call(WorkspaceAgentProtocol.DISCOVER,{workspace:"workspace",instance:instance,group:group,cursor:cursor},20000,function(v) {if(rpc()!=c) return;discovery=v;agentsError=null;agentsRevision++;},function(e) {if(rpc()==c) {agentsError=e.message;agentsRevision++;}});
  }
  var agentViews:Map<String,AgentView> = [];
  var agentTokens:Map<String,Int> = [];
  var agentsError:Null<String>;
  var agentsPending=false;
  var agentsNext:Float=0;
  var agentMutation=false;
  var agentSelection=0;
  var agentsRevision=0;
  public function agentRevision():Int return agentsRevision;
  public function agents():Null<AgentCatalog> return agentCatalog;
  public function agentError():Null<String> return agentsError;
  public function agentView(id:String):Null<AgentView> return agentViews.get(id);
  public function refreshAgents():Void {
    var c=rpc();
    if(c==null||agentsPending||clock()<agentsNext||client==null||client.capabilities().indexOf(WorkspaceAgentProtocol.READ)<0) return;
    agentsPending=true;agentsNext=clock()+1000;
    agentPage(c,null,[]);
  }
  function agentPage(c:RpcConnection,after:Null<String>,records:Array<AgentRecord>):Void {
    c.call(WorkspaceAgentProtocol.LIST,{workspace:"workspace",instance:instance,after:after},3000,function(v) {
      if(rpc()!=c) return;
      if(v.root!=root||v.instance!=instance||v.records.length>6||records.length+v.records.length>32) {
        agentsPending=false;agentsError="Invalid agent catalog";agentsRevision++;return;
      }
      var last=after;
      for(r in v.records) {
        if(r.workspaceRoot!=root||(last!=null&&Reflect.compare(r.id,last)<=0)) {agentsPending=false;agentsError="Invalid agent scope or page";agentsRevision++;return;}
        records.push(r);last=r.id;
      }
      if(v.next!=null) {
        if(v.records.length==0||v.next!=last) {agentsPending=false;agentsError="Invalid agent cursor";agentsRevision++;return;}
        agentPage(c,v.next,records);return;
      }
      agentsPending=false;agentsRevision++;v.records=records;agentCatalog=v;
    },function(e) {if(rpc()==c) {agentsPending=false;agentsError=e.message;agentsRevision++;}});
  }

  var pendingAgentCreate:Null<AgentCreate>;
  var agentCreated:Null<String->Void>;
  var createNext:Float=0;
  var createDeadline:Float=0;
  public function createAgent(group:String,thread:Null<String>,?created:String->Void):Void {
    if(rpc()==null||agentMutation) return;
    agentMutation=true;agentsError=null;agentCreated=created;
    pendingAgentCreate={workspace:"workspace",instance:instance,id:WorkspaceIds.create("agent"),group:group,name:"Codex",thread:thread};
    createDeadline=clock()+60000;createNext=0;
    continueAgentCreate();
  }
  function continueAgentCreate():Void {
    var c=rpc(), q=pendingAgentCreate;
    if(c==null||q==null||clock()<createNext) return;
    if(clock()>=createDeadline||q.instance!=instance) {pendingAgentCreate=null;agentMutation=false;agentsError="Codex startup did not complete";agentsRevision++;return;}
    createNext=createDeadline;
    c.call(WorkspaceAgentProtocol.CREATE,q,20000,function(r) {
      if(rpc()!=c) return;
      pendingAgentCreate=null;agentMutation=false;agentsNext=0;agentsRevision++;
      if(r.workspaceRoot!=root) {agentsError="Invalid created agent scope";return;}
      agentsError=null;
      if(agentCatalog!=null) {
       var found=false;for(index in 0...agentCatalog.records.length) if(agentCatalog.records[index].id==r.id) {agentCatalog.records[index]=r;found=true;break;}
       if(!found) agentCatalog.records.push(r);
      }
      var created=agentCreated;agentCreated=null;if(created!=null) created(r.id);
      agentAction(r.id,"read","",null);
    },function(e) {
      if(rpc()!=c) return;
      if(e.code=="provider_starting"&&!e.ambiguous) {createNext=clock()+500;agentsError=e.message;agentsRevision++;return;}
      pendingAgentCreate=null;agentMutation=false;agentsError=e.message;agentsNext=0;agentsRevision++;
    });
  }
  public function agentAction(id:String,action:String,text:String,request:Null<String>):Void {
    var c=rpc();if(c==null||agentMutation) return;
    var mutate=action!="read";if(mutate) agentMutation=true;
    var selected=++agentSelection;agentTokens.set(id,selected);
    if(action!="read") agentsError=null;
    c.call(WorkspaceAgentProtocol.ACTION,{workspace:"workspace",instance:instance,id:id,action:action,text:text,request:request},20000,function(v) {
      if(rpc()!=c||agentTokens.get(id)!=selected) return;
      if(mutate) agentMutation=false;
      if(v.record.workspaceRoot!=root||v.record.id!=id) {agentsError="Invalid agent view";return;}
      agentViews.set(id,v);agentsNext=0;agentsRevision++;
    },function(e) {if(rpc()==c&&agentTokens.get(id)==selected) {if(mutate) agentMutation=false;agentsError=e.message;agentsRevision++;}});
  }
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
  }

  function get_ready():Bool return verified
    && client != null && client.current() != null && replica != null && replica.ready;

  public function view():Array < WorkspaceGroup > return ready && replica != null ? replica.view() :[];

  public function rpc():Null < RpcConnection > return ready && client != null ? client.current() : null;

  public function hasGroupTree():Bool return client != null && client.capabilities().indexOf(WorkspaceProtocol.TREE) >= 0;
  public function canEditGroups():Bool return ready && client != null && hasGroupTree() && client.capabilities().indexOf(WorkspaceProtocol.WRITE) >= 0;
  public function terminalCatalog():Null < workspace.service.WorkspaceTerminalProtocol.TerminalCatalog > return catalog;
  public function terminalCatalogError():Null < String > return catalogError;
  public function terminalCatalogRevision():Int return catalogRevision;
  public function terminalCatalogBusy():Bool return catalogMutation;
  public function refreshTerminals(force:Bool):Void {
    if (root == null) {
      if (force) {
        catalogError = "Open a folder to view workspace terminals";
        catalogRevision++;
      }
      return;
    }
    var c = rpc();
    if (c == null || catalogPending ||(!force && clock() < catalogNext)) return;
    if (client == null || client.capabilities().indexOf(WorkspaceTerminalProtocol.CATALOG) < 0) {
      if (catalogError == null) {
        catalogError = "This workspace service does not support terminal discovery";
        catalogRevision++;
      }
      return;
    }
    if (force) catalogError = null;
    catalogPending = true;
    catalogNext = clock() + 1000;
    catalogPage(c, null, []);
  }
  function catalogPage(
    c:haxeon.rpc.RpcConnection,
    after:Null<String>,
    records:Array<workspace.service.WorkspaceTerminalProtocol.TerminalRecord>
  ):Void {
    c.call(WorkspaceTerminalProtocol.LIST,
      {workspace: "workspace", instance: instance, after: after}, 2000, function(value) {
      if (rpc() != c) return;
      if (value.workspaceRoot == null && !hasGroupTree()) {
        value.workspaceRoot = root;
        for (record in value.terminals) if (record.workspaceRoot == null && record.cwd == root) record.workspaceRoot = root;
      }
      if (value.instance != instance || value.workspaceRoot != root || value.terminals.length > WorkspaceTerminalProtocol.CATALOG_PAGE_LIMIT || value.groups.length > 32 || records.length + value.terminals.length > 256) {
        catalogPending = false;
        catalogError = "Invalid terminal catalog";
        catalogRevision++;
        return;
      }
      var last = after;
      for (record in value.terminals) {
        if (record.workspaceRoot != root || record.id == null ||(last != null && Reflect.compare(record.id, last) <= 0)) {
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
        catalogPage(c, value.next, records);
        return;
      }
      catalogPending = false;
      value.terminals = records;
      var key = value.instance;
      for (g in value.groups) key += "|g:" + g.id + ":" + g.revision;
      for (r in records) key += "|t:" + r.id + ":" + r.revision + ":" + r.available;
      catalog = value;
      if (key != catalogKey) {
        catalogKey = key;
        catalogRevision++;
      }
    }, function(e) {
      if (rpc() == c) {
        catalogPending = false;
        catalogError = e.message;
        catalogRevision++;
      }
    }
    );
  }

  function catalogReady():Bool {
    if (catalogMutation) return false;
    if (rpc() == null || client == null || client.capabilities().indexOf(WorkspaceTerminalProtocol.CATALOG) < 0) {
      catalogError = "Workspace terminals are not connected";
      catalogRevision++;
      return false;
    }
    catalogError = null;
    catalogMutation = true;
    catalogRevision++;
    return true;
  }
  function catalogCompleted(c:haxeon.rpc.RpcConnection):Void {
    if (rpc() != c) return;
    catalogMutation = false;
    catalogNext = 0;
    catalogRevision++;
    refreshTerminals(false);
  }
  function catalogFailed(c:haxeon.rpc.RpcConnection, e:haxeon.rpc.RpcError):Void {
    if (rpc() != c) return;
    catalogMutation = false;
    catalogError = e.ambiguous ? "Session change may have completed; refresh before retrying"
      : e.code == "stale_revision" ? "This session changed. Reload its name/group before saving." : e.message;
    catalogNext = 0;
    catalogRevision++;
    refreshTerminals(false);
  }
  public function renameTerminal(
    record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord,
    name:String,
    group:String
  ):Void {
    var c = rpc();
    if (record.workspaceRoot != root || c == null || !catalogReady()) return;
    c.call(
      WorkspaceTerminalProtocol.RENAME,
      {
      workspace: "workspace",
      instance: instance,
      id: record.id,
      name: name,
      group: group,
      expectedRevision: record.revision
    },
      2000,
      function(_) catalogCompleted(c),
      function(e) catalogFailed(
        c,
        e
      )
    );
  }
  public function changeGroup(owner:String, group:WorkspaceGroup, name:String, parent:Null<String>, cwd:Null<String>, order:Int, create:Bool):Void {
    var c = rpc();
    var view = replica;
    if (owner != instance) { catalogError = "Workspace changed; reopen the group editor"; catalogRevision++; return; }
    if (c == null || view == null || !catalogReady()) return;
    if (client == null || client.capabilities().indexOf(WorkspaceProtocol.TREE) < 0) {
      catalogFailed(c, {code: "unsupported", message: "Group editing is not supported", ambiguous: false}); return;
    }
    c.call(WorkspaceProtocol.GROUP, {
      workspace: "workspace", epoch: view.epoch, operation: WorkspaceIds.create("operation"),
      group: group.id, expectedRevision: create ? 0 : group.revision, name: name,
      action: create ? "create" : "update", parent: parent, cwd: cwd, order: order
    }, 2000, function(_) catalogCompleted(c), function(e) catalogFailed(c, e));
  }
  public function stopTerminal(record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
    var c = rpc();
    if (record.workspaceRoot != root || c == null || !catalogReady()) return;
    c.call(
      WorkspaceTerminalProtocol.TERMINATE,
      {workspace: "workspace", instance: instance, id: record.id},
      2000,
      function(_) catalogCompleted(c),
      function(e) catalogFailed(
        c,
        e
      )
    );
  }
  public function forgetTerminal(record:workspace.service.WorkspaceTerminalProtocol.TerminalRecord):Void {
    var c = rpc();
    if (record.workspaceRoot != root || c == null || !catalogReady()) return;
    c.call(
      WorkspaceTerminalProtocol.FORGET,
      {
      workspace: "workspace",
      instance: instance,
      id: record.id,
      resourceInstance: record.instance,
      expectedRevision: record.revision
    },
      2000,
      function(_) catalogCompleted(c),
      function(e) catalogFailed(
        c,
        e
      )
    );
  }

  public function failure():Null < String > return error;

  public function cursor():Int return replica == null ? 0 : replica.cursor;

  public function epoch():String return replica == null ? "" : replica.epoch;

  public function statusLabel():String {
    if (root == null) return "";
    if (error != null) return "Workspace unavailable";
    if (ready) return "Workspace connected";
    return wasReady ? "Workspace reconnecting" : "Connecting workspace…";
  }

  public static function findLauncher():String {
    var configured = Sys.getEnv("EXOSUIT_AGENT_LAUNCHER");
    if (configured != null && configured.length > 0) return FileSystem.fullPath(configured);
    var directory = FileSystem.fullPath(Sys.getCwd());
    for (_ in 0...8) {
      var candidate = directory + "/scripts/run-agent.py";
      if (FileSystem.exists(candidate)) return candidate;
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
    catalog = null;
    agentConnection=null;agentCatalog=null;discovery=null;agentViews.clear();agentTokens.clear();agentsError=null;agentsPending=false;agentMutation=false;pendingAgentCreate=null;agentCreated=null;agentsNext=0;agentSelection++;agentsRevision++;
    catalogPending = false;
    catalogMutation = false;
    catalogKey = "";
    catalogNext = 0;
    catalogError = null;
    catalogRevision++;
    if (client != null) client.close();
    client = null;
    verified = false;
  }

  function stopHelper():Void {
    var process = helper;
    helper = null;
    if (process != null) processes.release(process);
  }

  function fail(message:String):Void {
    error = message;
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
      helper = processes.start(
        "python3",
        [launcher, path, mode == "discover" ? "--discover" : "--detach", "--wire"],
        path,
        environment
      );
      helperDeadline = clock() + 95000;
    } catch (failure:Dynamic) {
      fail(Std.string(failure));
    }
  }

  function install(endpoint:LocalWorkspaceEndpoint):Void {
    var path = root;
    if (path == null || endpoint.version != 1 || endpoint.protocol != 1 || endpoint.codec != 1
      || endpoint.workspace != "workspace" || endpoint.root != path || endpoint.generation.length != 32
      || endpoint.socket.length == 0) throw "Invalid workspace discovery descriptor";
    var expectedInstance = endpoint.generation, expectedRoot = path, selected = selection;
    instance = expectedInstance;
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

  function fenceAgentConnection():Void {
    var current=rpc();
    if(current==agentConnection) return;
    var lost=agentConnection!=null;
    agentConnection=current;
    agentsPending=false;agentMutation=false;pendingAgentCreate=null;agentCreated=null;
    agentCatalog=null;discovery=null;agentViews.clear();agentTokens.clear();agentsNext=0;agentsRevision++;
    if(lost) agentsError="Workspace connection changed; reconcile the agent before retrying";
  }
  public function poll():Void {
    fenceAgentConnection();
    continueAgentCreate();
    if (disposed || root == null || error != null) return;
    var now = clock(), process = helper;
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
    fenceAgentConnection();
    if (client != current || error != null) return;
    if (current.state == Closed) {
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
    selection++;
    stopConnection();
    stopHelper();
    hub.dispose();
    root = null;
  }
}
