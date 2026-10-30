package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.RpcTerminalBackend;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.storage.WorkspaceSqliteStore;
import terminalsession.TerminalSession;
import terminalkit.Emulator;

private class ResizeEndpoint implements WorkspaceRpcEndpoint {
  public final connection:RpcConnection;
  final root:String;
  final router:workspace.client.WorkspaceTerminalEvents;
  public function new(root:String,connection:RpcConnection) {
    this.root=root; this.connection=connection; router=new workspace.client.WorkspaceTerminalEvents(connection);
  }
  public function rootPath():Null<String> return root;
  public function serviceGeneration():String return "resize-test";
  public function workspaceEpoch():Null<String> return "resize-test";
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return true;
  public function hasCapability(value:String):Bool return true;
  public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return router;
}

/** Pane size → grid → PTY for a live terminal; a local view fit for an ended one. */
class TerminalResizeTests {
  static function require(value:Bool,message:String):Void { if (!value) throw message; }
  public static function run(root:String):Void {
    var seed:WorkspaceSnapshot = {epoch:"resize-test",cursor:0,groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(root+"/terminal-resize.sqlite","workspace",seed);
    var manager = new WorkspaceTerminalManager("workspace","resize-test",root,16777216,store);
    var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
    var client = new RpcConnection(pair.client,clock), server = new RpcConnection(pair.server,clock);
    manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
    var readPair = MemoryTransport.pair();
    var reader = new RpcConnection(readPair.client,clock), readServer = new RpcConnection(readPair.server,clock);
    manager.bind(readServer,[WorkspaceTerminalProtocol.READ]);
    var endpoint = new ResizeEndpoint(root,client);
    // Like the editor's pane: no OPEN until the first layout supplies a grid.
    var backend = new RpcTerminalBackend(function() return endpoint,"resize-shell",root,true,null,null,true,true);
    var session = new TerminalSession(backend,Emulator.open(80,24,1000,"xterm-256color",false),false);
    var viewer:Null<TerminalSession> = null;
    var step = function() {
      client.poll(); server.poll(); readServer.poll(); manager.poll(); client.poll(); reader.poll(); session.pollEvents();
      var other = viewer;
      if (other != null) other.pollEvents();
    };
    var until = function(check:Void->Bool,message:String) {
      var deadline = Sys.time()+10;
      while (!check()) { require(Sys.time()<deadline,message); step(); Sys.sleep(0.005); }
    };
    var grid = function(columns:Int,rows:Int) return session.emulator.columns()==columns && session.emulator.rows()==rows;
    // The service's own record, as another viewer would replay it.
    var recorded = function():{columns:Int,rows:Int} {
      var result:Null<{columns:Int,rows:Int}> = null;
      reader.call(WorkspaceTerminalProtocol.REPLAY,{workspace:"workspace",instance:"resize-test",id:"resize-shell",cursor:0},1000,
        function(value) { result = {columns:value.terminal.columns,rows:value.terminal.rows}; },
        function(e) { throw "Service geometry unavailable: " + e.code; });
      until(function() return result != null,"Service geometry did not arrive");
      var found:{columns:Int,rows:Int} = result;
      return found;
    };
    session.resize(120,50);
    until(function() return backend.isSynchronized() && backend.canControl() && grid(120,50),"Terminal did not open at the pane's grid");
    session.resize(150,60);
    until(function() return grid(150,60),"Live terminal did not follow its pane");
    var live = recorded();
    require(live.columns==150 && live.rows==60,"Pane resize did not reach the service's PTY");
    session.write(Bytes.ofString("exit\r\n"));
    until(function() return session.status=="exited" && backend.isSynchronized(),"Shell did not exit");
    // An ended terminal has no PTY: the view fits the pane, the saved record keeps its grid.
    session.resize(200,70);
    until(function() return grid(200,70),"Ended terminal kept its recorded grid after the pane grew");
    session.resize(90,20);
    until(function() return grid(90,20),"Ended terminal did not follow a smaller pane");
    session.resize(150,60);
    until(function() return grid(150,60),"Ended terminal did not return to its recorded grid");
    session.resize(200,70);
    until(function() return grid(200,70),"Ended terminal did not grow again");
    var saved = recorded();
    require(saved.columns==150 && saved.rows==60,"Viewing an ended terminal rewrote its saved geometry");
    // A pane restored after the session ended attaches without control and fits too.
    var restoredBackend = new RpcTerminalBackend(function() return endpoint,"resize-shell",root,false,null,null,false,true);
    var restored = new TerminalSession(restoredBackend,Emulator.open(80,24,1000,"xterm-256color",false),false);
    viewer = restored;
    restored.resize(110,45);
    until(function() return restoredBackend.isSynchronized() && restored.status=="exited"
      && restored.emulator.columns()==110 && restored.emulator.rows()==45,"Restored saved history kept its recorded grid");
    viewer = null;
    restored.close();
    // A restart replays at the recorded grid, then the controller sizes the new PTY to the pane.
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running" && grid(200,70),"Restarted shell did not take the pane's grid");
    var restarted = recorded();
    require(restarted.columns==200 && restarted.rows==70,"Restarted PTY kept the old grid");
    session.close(); manager.dispose(); client.close(); server.close(); reader.close(); readServer.close(); store.close();
    Sys.println("PASS: pane size reaches a live PTY; an ended terminal's view fits its pane without rewriting saved geometry; restart resizes");
  }
}
