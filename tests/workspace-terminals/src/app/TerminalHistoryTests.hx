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
  public static function process(client:workspace.client.LocalWorkspaceClient, runtime:haxeon.platform.Runtime, root:String, create:Bool):Void {
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
      session.write(TestShell.line(TestShell.assign("KEEP","previous")));
      session.write(TestShell.counted("PROCESS_",60));
      until(function() return allText(session.emulator).indexOf("PROCESS_059")>=0,"Process output missing");
      var flushUntil = Sys.time()+2.3;
      while (Sys.time()<flushUntil) step();
    } else {
      require(session.status=="lost" && !backend.canControl(),"Restarted daemon silently spawned a shell");
      var text = allText(session.emulator);
      // Attach shows the service's current screen: the saved history's last lines, not its scrollback.
      require(text.indexOf("PROCESS_059")>=0,"Daemon process restart lost the saved screen");
      backend.activateControl();
      until(function() return backend.canControl() && session.status=="running","Replacement shell did not start");
      session.write(TestShell.variable("FRESH_ENV:","KEEP"));
      until(function() return allText(session.emulator).indexOf("FRESH_ENV:unset")>=0,"Replacement shell inherited dead shell state");
      text = allText(session.emulator);
      require(text.indexOf("PROCESS_000")>=0 && text.indexOf("Shell restarted")>=0,"Replacement shell lost saved output: scrollback=" + (text.indexOf("PROCESS_000")>=0) + " separator=" + (text.indexOf("Shell restarted")>=0));
      session.write(TestShell.line("exit"));
      until(function() return session.status=="exited","Replacement shell did not exit");
      Sys.println("PASS: actual daemon process restart preserves scrollback; explicit replacement shell retains output with fresh shell state");
    }
    session.close();
  }
  public static function run(root:String):Void {
    legacyRecovery(root);
    widenedHistory(root);
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
    session.write(TestShell.counted("SAVED_",60," 界"));
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
    // Attach shows the service's current screen: the saved history's last lines, not its scrollback.
    require(text.indexOf("SAVED_059")>=0,"Recovered pane lost the saved screen");
    require(!backend.canControl() && backend.controlAction()=="Restart Terminal","Archived history was writable or lacked restart action");
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
    session.write(TestShell.clearedJoined("NEW_","SHELL"));
    until(function() return allText(session.emulator).indexOf("NEW_SHELL")>=0,"New shell did not accept input");
    text = allText(session.emulator);
    require(text.indexOf("SAVED_000")>=0 && text.indexOf("SAVED_059")>=0,"Restart or shell startup clear discarded old history");
    // Duplicate restart requests cannot replace the newly running process.
    error = "";
    endpoint.connection.call(WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:"history-second",id:"history-shell"},1000,
      function(_) { throw "Running shell restarted twice"; },function(e) error=e.code);
    step(); step(); require(error=="terminal_running","Duplicate restart replaced running shell");
    session.write(TestShell.line("exit"));
    until(function() return session.status=="exited","Replacement shell did not exit");
    // An ended terminal nobody reads gives up its emulator; the open view keeps what it shows, and a view that opens it
    // later gets its whole history from disk.
    manager.unloadSeconds = 0.2;
    until(function() return manager.loadedCount()==0,"Ended terminal kept its emulator");
    var shown = allText(session.emulator);
    for (_ in 0...20) step();
    require(manager.loadedCount()==0 && allText(session.emulator)==shown && backend.isAvailable(),"The open view of an unloaded terminal changed or reloaded it");
    var later = new RpcTerminalBackend(function() return endpoint,"history-shell",root,false);
    var laterSession = new TerminalSession(later,Emulator.open(80,24,1000,"xterm-256color",false),false);
    until(function() { laterSession.pollEvents(); return later.isSynchronized(); },"A view of an unloaded terminal did not attach");
    var reloaded = allText(laterSession.emulator);
    require(manager.loadedCount()==1 && reloaded.indexOf("SAVED_000")>=0 && reloaded.indexOf("NEW_SHELL")>=0 && laterSession.status=="exited",
      "An unloaded terminal came back without its history");
    laterSession.close();
    until(function() return manager.loadedCount()==0,"A reloaded ended terminal kept its emulator");
    manager.unloadSeconds = WorkspaceTerminalManager.UNLOAD_SECONDS;
    Sys.println("PASS: an ended terminal nobody reads is unloaded, and comes back with its whole history from disk");
    manager.dispose(); store.close();
    store = new WorkspaceSqliteStore(path,"workspace",seed);
    var combined:Null<workspace.service.TerminalHistory> = store.loadTerminalHistory("history-shell");
    require(combined != null && combined.data.toString().indexOf("SAVED_000")>=0 && combined.data.toString().indexOf("NEW_SHELL")>=0,"Second service restart lost combined history");
    store.removeTerminal("history-shell");
    require(!store.hasTerminalHistory("history-shell") && store.loadTerminals().length==0,"Forget retained terminal history");
    session.close(); endpoint.connection.close(); server.close(); store.close();
    Sys.println("PASS: durable styled history, live-pane recovery, explicit restart, permission checks and atomic removal");
  }

  /**
    10000 coloured lines render to up to 16 MiB, and the history table was made holding 4 MiB: every save of such a
    history failed, again every two seconds. A store opened on such a table widens it and keeps its rows.
  **/
  static function widenedHistory(root:String):Void {
    var path = root+"/narrow-terminal-history.sqlite";
    var seed:WorkspaceSnapshot = {epoch:"narrow",cursor:0,groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(path,"workspace",seed);
    store.saveTerminal({id:"narrow-shell",name:"Narrow shell",group:"",cwd:root,workspaceRoot:root,
      instance:"previous-service",state:"exited",exitCode:0,available:true,revision:1});
    store.saveTerminalHistory("narrow-shell",{version:1,columns:80,rows:24,data:Bytes.ofString("OLD_ROW")});
    store.close();
    var db = sqlitekit.Database.open(path,1000);
    db.exec("CREATE TABLE narrow_copy AS SELECT id,payload FROM workspace_terminal_history");
    db.exec("DROP TABLE workspace_terminal_history");
    db.exec("CREATE TABLE workspace_terminal_history (id TEXT PRIMARY KEY REFERENCES workspace_terminals(id) ON DELETE CASCADE, payload BLOB NOT NULL CHECK(length(payload)<=4194432))");
    db.exec("INSERT INTO workspace_terminal_history SELECT id,payload FROM narrow_copy");
    db.exec("DROP TABLE narrow_copy");
    db.close();
    store = new WorkspaceSqliteStore(path,"workspace",seed);
    var old = store.loadTerminalHistory("narrow-shell");
    require(old != null && old.data.toString()=="OLD_ROW","Widening the history table lost a saved history");
    var large:Bytes = Bytes.alloc(6*1024*1024);
    store.saveTerminalHistory("narrow-shell",{version:1,columns:80,rows:24,data:large});
    var back = store.loadTerminalHistory("narrow-shell");
    require(back != null && back.data.length==large.length,"A 6 MiB terminal history was not saved");
    store.close();
  }

  static function legacyRecovery(root:String):Void {
    var seed:WorkspaceSnapshot = {epoch:"legacy-recovery",cursor:0,groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(root+"/legacy-terminal-history.sqlite","workspace",seed);
    store.saveTerminal({id:"legacy-shell",name:"Legacy shell",group:"",cwd:root,workspaceRoot:root,
      instance:"previous-service",state:"running",exitCode:0,available:false,revision:1});
    var manager = new WorkspaceTerminalManager("workspace","legacy-current",root,16777216,store);
    require(manager.snapshot().terminals[0].available,"Metadata-only terminal cannot open its recovery view");
    var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
    var client = new RpcConnection(pair.client,clock), server = new RpcConnection(pair.server,clock);
    manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
    var endpoint = new HistoryEndpoint(root); endpoint.connection=client; endpoint.generation="legacy-current";
    var backend = new RpcTerminalBackend(function() return endpoint,"legacy-shell",root,false);
    var session = new TerminalSession(backend,Emulator.open(80,24),false);
    var step = function() { client.poll();server.poll();manager.poll();client.poll();session.pollEvents(); };
    var until = function(check:Void->Bool,message:String) {
      var deadline=Sys.time()+5;
      while (!check()) { require(Sys.time()<deadline,message);step();Sys.sleep(0.005); }
    };
    until(function() return backend.isSynchronized(),"Metadata-only terminal recovery failed");
    require(session.status=="lost" && manager.activeCount()==0,"Recovery view silently spawned a replacement");
    require(backend.controlStatus()=="Session ended · no saved history" && backend.controlAction()=="Restart Terminal",
      "Metadata-only terminal lacks an honest explanation or restart action");
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running","Metadata-only terminal could not restart explicitly");
    session.write(TestShell.joined("RECOVERED_","LEGACY"));
    until(function() return allText(session.emulator).indexOf("RECOVERED_LEGACY")>=0,"Recovered shell did not accept input");
    require(manager.snapshot().terminals[0].id=="legacy-shell" && manager.activeCount()==1,"Recovery changed terminal identity");
    session.close();client.close();server.close();manager.dispose();store.close();
    Sys.println("PASS: metadata-only terminal opens without spawning and restarts explicitly under the same identity");
  }
}
