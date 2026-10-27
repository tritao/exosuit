package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.RpcTerminalBackend;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import terminalsession.TerminalSession;
import terminalkit.Emulator;

private class HistoryEndpoint implements WorkspaceRpcEndpoint {
  public var connection:RpcConnection;
  public var generation:String;
  final root:String;
  var router:Null<workspace.client.WorkspaceTerminalEvents>;
  public function new(root:String) this.root = root;
  public function rootPath():Null<String> return root;
  public function serviceGeneration():String return generation;
  public function workspaceEpoch():Null<String> return "history";
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return true;
  public function hasCapability(value:String):Bool return true;
  public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> {
    if (router == null || router.connection != connection) router = new workspace.client.WorkspaceTerminalEvents(connection);
    return router;
  }
}

class TerminalHistoryTests {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  static function allText(e:Emulator):String {
    var total = e.scrollback(-1).total, lines:Array<String> = [];
    var position = total;
    while (position > 0) {
      e.scrollback(position); e.snapshot();
      for (row in 0...Std.int(Math.min(position,e.rows()))) lines.push(e.rowText(row));
      position -= e.rows();
    }
    e.scrollback(0); e.snapshot();
    for (row in 0...e.rows()) lines.push(e.rowText(row));
    return lines.join("\n");
  }
  /** Separate client and daemon processes exercise the actual durable boundary. */
  public static function process(client:workspace.client.LocalWorkspaceClient, runtime:haxeon.platform.NativeKitRuntime, root:String, create:Bool):Void {
    var backend = new RpcTerminalBackend(function() return client,"process-history-shell",root,create);
    var session = new TerminalSession(backend,Emulator.open(80,24,1000,"xterm-256color",false),false);
    var step = function() {
      runtime.events.wait(0.005);
      for (_ in 0...128) if (!runtime.events.poll()) break;
      client.poll(); require(client.error == null,"Workspace failed: " + client.error); session.pollEvents();
    };
    var until = function(check:Void->Bool, message:String) {
      var deadline = Sys.time()+15;
      while (!check()) { require(Sys.time()<deadline,message); step(); }
    };
    until(function() return backend.isSynchronized(),"Process history did not attach");
    if (create) {
      session.write(Bytes.ofString("KEEP=previous; i=0; while [ $i -lt 60 ]; do printf 'PROCESS_%03d\\n' $i; i=$((i+1)); done\n"));
      until(function() return allText(session.emulator).indexOf("PROCESS_059")>=0,"Process output missing");
      var flushUntil = Sys.time()+2.3;
      while (Sys.time()<flushUntil) step();
    } else {
      require(session.status=="lost" && !backend.canControl(),"Restarted daemon silently spawned a shell");
      var text = allText(session.emulator);
      require(text.indexOf("PROCESS_000")>=0 && text.indexOf("PROCESS_059")>=0,"Daemon process restart lost durable scrollback");
      backend.activateControl();
      until(function() return backend.canControl() && session.status=="running","Replacement shell did not start");
      session.write(Bytes.ofString("printf 'FRESH_ENV:%s\\n' \"${KEEP-unset}\"\n"));
      until(function() return allText(session.emulator).indexOf("FRESH_ENV:unset")>=0,"Replacement shell inherited dead shell state");
      text = allText(session.emulator);
      require(text.indexOf("PROCESS_000")>=0 && text.indexOf("Shell restarted")>=0,"Replacement shell lost saved output");
      session.write(Bytes.ofString("exit\n"));
      until(function() return session.status=="exited","Replacement shell did not exit");
      Sys.println("PASS: actual daemon process restart preserves scrollback; explicit replacement shell retains output with fresh shell state");
    }
    session.close();
  }
  public static function run(root:String):Void {
    var path = root + "/terminal-history.sqlite";
    var seed:WorkspaceSnapshot = {epoch:"history", cursor:0, groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(path,"workspace",seed);
    var manager = new WorkspaceTerminalManager("workspace","history-first",root,16777216,store);
    var endpoint = new HistoryEndpoint(root);
    var server:RpcConnection = null;
    var connect = function(generation:String) {
      if (endpoint.connection != null) endpoint.connection.close();
      if (server != null) server.close();
      var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
      endpoint.connection = new RpcConnection(pair.client,clock);
      endpoint.generation = generation;
      server = new RpcConnection(pair.server,clock);
      manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
    };
    connect("history-first");
    var backend = new RpcTerminalBackend(function() return endpoint,"history-shell",root,true);
    var session = new TerminalSession(backend,Emulator.open(80,24,1000,"xterm-256color",false),false);
    var step = function() {
      endpoint.connection.poll(); server.poll(); manager.poll(); endpoint.connection.poll(); session.pollEvents();
    };
    var until = function(check:Void->Bool, message:String) {
      var deadline = Sys.time()+5;
      while (!check()) { require(Sys.time()<deadline,message); step(); Sys.sleep(0.005); }
    };
    until(function() return backend.isSynchronized(),"Initial shell did not synchronize");
    session.write(Bytes.ofString("i=0; while [ $i -lt 60 ]; do printf 'SAVED_%03d 界\\n' $i; i=$((i+1)); done\n"));
    until(function() return allText(session.emulator).indexOf("SAVED_059")>=0,"Shell output missing");
    // A daemon shutdown flushes dirty history even inside the periodic save interval.
    manager.dispose(); store.close();
    store = new WorkspaceSqliteStore(path,"workspace",seed);
    var saved:Null<workspace.service.TerminalHistory> = store.loadTerminalHistory("history-shell");
    require(saved != null && saved.data.toString().indexOf("SAVED_000")>=0,"Durable history missing oldest scrollback");
    var rejected = false;
    try store.saveTerminalHistory("history-shell", {version:2,columns:80,rows:24,data:Bytes.ofString("invalid")})
    catch (_:Dynamic) rejected = true;
    require(rejected,"Unknown history format was committed");
    manager = new WorkspaceTerminalManager("workspace","history-second",root,16777216,store);
    var record = manager.snapshot().terminals[0];
    require(record.state=="lost" && record.available && manager.activeCount()==0,"Archived session was hidden or silently spawned");
    connect("history-second");
    until(function() return backend.isSynchronized() && session.status=="lost","Existing pane did not recover after generation change");
    var text = allText(session.emulator);
    require(text.indexOf("SAVED_000")>=0 && text.indexOf("SAVED_059")>=0,"Recovered pane lost scrollback or active output");
    require(!backend.canControl() && backend.controlAction()=="Restart shell","Archived history was writable or lacked restart action");
    // Read-only peers cannot start a shell from archived output.
    var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
    var reader = new RpcConnection(pair.client,clock), readServer = new RpcConnection(pair.server,clock);
    manager.bind(readServer,[WorkspaceTerminalProtocol.READ]);
    var error = "";
    reader.call(WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:"history-second",id:"history-shell"},1000,
      function(_) { throw "Read-only peer restarted shell"; },function(e) error=e.code);
    reader.poll(); readServer.poll(); reader.poll();
    require(error=="unauthorized","Restart ignored control grant"); reader.close(); readServer.close();
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running","Explicit shell restart failed");
    require(allText(session.emulator).indexOf("Shell restarted")>=0,"Restart separator missing");
    // Shell startup programs often clear their new screen. Old output must
    // already be in scrollback before that happens.
    session.write(Bytes.ofString("printf '\\033[2J\\033[H'; printf 'NEW_%s\\n' SHELL\n"));
    until(function() return allText(session.emulator).indexOf("NEW_SHELL")>=0,"New shell did not accept input");
    text = allText(session.emulator);
    require(text.indexOf("SAVED_000")>=0 && text.indexOf("SAVED_059")>=0,"Restart or shell startup clear discarded old history");
    // Duplicate restart requests cannot replace the newly running process.
    error = "";
    endpoint.connection.call(WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:"history-second",id:"history-shell"},1000,
      function(_) { throw "Running shell restarted twice"; },function(e) error=e.code);
    step(); step(); require(error=="terminal_running","Duplicate restart replaced running shell");
    session.write(Bytes.ofString("exit\n"));
    until(function() return session.status=="exited","Replacement shell did not exit");
    manager.dispose(); store.close();
    store = new WorkspaceSqliteStore(path,"workspace",seed);
    var combined:Null<workspace.service.TerminalHistory> = store.loadTerminalHistory("history-shell");
    require(combined != null && combined.data.toString().indexOf("SAVED_000")>=0 && combined.data.toString().indexOf("NEW_SHELL")>=0,"Second service restart lost combined history");
    store.removeTerminal("history-shell");
    require(!store.hasTerminalHistory("history-shell") && store.loadTerminals().length==0,"Forget retained terminal history");
    session.close(); endpoint.connection.close(); server.close(); store.close();
    Sys.println("PASS: durable styled history, live-pane recovery, explicit restart, permission checks and atomic removal");
  }
}
