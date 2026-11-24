package app;

import testing.TestEndpoint;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.client.RpcWorkspaceWorkbenchClient;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Terminal UI decisions depend on negotiated workspace grants, without a local process host. */
class TerminalCapabilitiesTests {
  /** A connection whose grants the test sets. */
  static function grantedEndpoint(connection:RpcConnection):TestEndpoint {
    var endpoint = new TestEndpoint(connection);
    endpoint.epoch = null; endpoint.grants = [];
    return endpoint;
  }
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  public static function run():Void {
    var pair = MemoryTransport.pair(), connection = new RpcConnection(pair.client, () -> 0.0);
    var endpoint = grantedEndpoint(connection), client = new RpcWorkspaceWorkbenchClient(endpoint, () -> 0.0);
    endpoint.grants = [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CATALOG];
    require(client.canReadTerminals() && !client.canCreateTerminals(), "Read-only device can create terminals");
    endpoint.grants.push(WorkspaceTerminalProtocol.CONTROL);
    require(client.canCreateTerminals() && !client.canCreateGroupedTerminals(), "Ungrouped terminal requires unrelated tree permissions");
    endpoint.grants.push(WorkspaceProtocol.TREE);
    require(client.canCreateGroupedTerminals() && !client.canEditGroups(), "Terminal creation requires group editing permission");
    endpoint.grants.remove(WorkspaceTerminalProtocol.READ);
    require(!client.canCreateTerminals() && !client.canCreateGroupedTerminals(), "Creation allowed without terminal read permission");
    endpoint.connection = null;
    require(!client.canReadTerminals() && !client.canControlTerminals() && !client.canCreateTerminals(), "Disconnected device retained terminal actions");
    connection.close();
    creationCatalog(false);
    creationCatalog(true);
    Sys.println("PASS: remote terminal availability, read-only grants, group permissions and disconnect");
  }
  static function creationCatalog(holdInitial:Bool):Void {
    var pair=MemoryTransport.pair(), connection=new RpcConnection(pair.client,() -> 0.0);
    var server=new RpcConnection(pair.server,() -> 0.0), endpoint=grantedEndpoint(connection);
    endpoint.grants=[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG];
    var client=new RpcWorkspaceWorkbenchClient(endpoint,() -> 0.0);
    var lists=0, opened=false;
    var release:Void->Void=function() throw "Missing held catalog response";
    server.register(WorkspaceTerminalProtocol.LIST,function(_,context) {
      lists++;
      var records:Array<WorkspaceTerminalProtocol.TerminalRecord>=opened ? [{id:"created",name:"Terminal 1",group:"work",cwd:"/fixture",
        workspaceRoot:"/fixture",instance:"fixture",state:"running",exitCode:0,available:true,revision:1}] : [];
      var snapshot:WorkspaceTerminalProtocol.TerminalCatalog={instance:"fixture",workspaceRoot:"/fixture",groups:[],terminals:records,next:null};
      if (holdInitial && lists==1) release=function() context.respond(snapshot);
      else context.respond(snapshot);
    });
    server.register(WorkspaceTerminalProtocol.OPEN,function(request,context) {
      if (request.id=="failed") { context.fail(new RpcError("terminal_spawn_failed", "Terminal creation failed: The pi CLI was not found on the workspace host PATH", false));return; }
      opened=true;
      context.respond({id:request.id,cwd:"/fixture",state:"running",exitCode:0,columns:80,rows:24,start:0,end:0});
    });
    var step=function() { connection.poll();server.poll();connection.poll();client.poll(); };
    client.poll();
    for (_ in 0...5) step();
    require(lists==1,"Initial terminal catalog was not requested");
    var backend=new workspace.client.RpcTerminalBackend(() -> endpoint,"created","/fixture",true);
    backend.pollEvents(function(_) {});
    for (_ in 0...5) step();
    if (holdInitial) {
      require(lists==1,"Creation started an overlapping catalog request");
      release();for (_ in 0...5) step();
    }
    var catalog=client.terminalCatalog();
    require(lists==2 && catalog!=null && catalog.terminals.length==1,
      "Confirmed creation did not read the catalog again, or accepted a stale in-flight snapshot");
    for (_ in 0...5) step();
    require(lists==2,"An idle client listed terminals again");
    var attached=new workspace.client.RpcTerminalBackend(() -> endpoint,"created","/fixture",false);
    attached.pollEvents(function(_) {});for (_ in 0...5) step();
    require(lists==2,"Reattaching an existing terminal invalidated the catalog");
    var failed=new workspace.client.RpcTerminalBackend(() -> endpoint,"failed","/fixture",true);
    failed.pollEvents(function(_) {});for (_ in 0...5) step();
    require(lists==2,"Failed creation triggered a success refresh");
    require(failed.controlStatus()=="Terminal unavailable: Terminal creation failed: The pi CLI was not found on the workspace host PATH",
      "Terminal startup discarded the actionable service error");
    // A failed view offers Retry, which asks the service again; the same failure comes back from the service, not from the view.
    require(failed.controlAction()=="Retry","A failed terminal offered no retry");
    failed.activateControl();
    require(failed.controlStatus().indexOf("Terminal unavailable")!=0 && failed.controlAction()=="","Retry left the failure in place");
    for (_ in 0...5) {
      try failed.pollEvents(function(_) {}) catch (_:Dynamic) {}
      step();
    }
    require(failed.controlStatus()=="Terminal unavailable: Terminal creation failed: The pi CLI was not found on the workspace host PATH"
      && failed.controlAction()=="Retry" && lists==2,"A retried creation did not report the service's failure again");
    var closed=new workspace.client.RpcTerminalBackend(() -> endpoint,"created","/fixture",true);
    closed.pollEvents(function(_) {});closed.close();for (_ in 0...5) step();
    require(lists==3,"Closing the view discarded confirmed creation invalidation");
    backend.close();attached.close();failed.close();client.dispose();connection.close();server.close();
    Sys.println("PASS: confirmed terminal creation refreshes discovery with a fixed clock, including in-flight catalogs and closed views");
  }
}
