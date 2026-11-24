package app;

import testing.TestEndpoint;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.RpcTerminalBackend;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import terminalsession.TerminalSession;
import terminalkit.Emulator;
import workspace.transport.RpcCalls;

class TerminalHistoryTests {
  static function historyEndpoint(root:String):TestEndpoint {
    var endpoint = new TestEndpoint();
    endpoint.root = root; endpoint.epoch = "history";
    return endpoint;
  }
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
  /**
    Separate client and daemon processes: the daemon stops between `create` and `restore`, and the next daemon takes back
    the same shell from its host, with its scrollback and its state.
  **/
  public static function process(client:workspace.client.WorkspaceLink, runtime:haxeon.platform.Runtime, root:String, create:Bool):Void {
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
      var flushUntil = Sys.time()+1;
      while (Sys.time()<flushUntil) step();
    } else {
      until(function() return session.status=="running" && backend.canControl(),"The next daemon did not take the shell back from its host");
      var text = allText(session.emulator);
      require(text.indexOf("PROCESS_000")>=0 && text.indexOf("PROCESS_059")>=0,"The shell came back without its scrollback");
      session.write(TestShell.variable("KEPT_ENV:","KEEP"));
      until(function() return allText(session.emulator).indexOf("KEPT_ENV:previous")>=0,"The shell came back without its state");
      session.write(TestShell.line("exit"));
      until(function() return session.status=="exited","The shell did not exit");
      Sys.println("PASS: a daemon process restart keeps the shell running in its host, with its scrollback and state");
    }
    session.close();
  }
  public static function run(root:String):Void {
    goneHost(root);
    var path = root + "/terminal-history.sqlite";
    var seed:WorkspaceSnapshot = {epoch:"history", cursor:0, groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(path,"workspace",seed);
    var manager = TestTerminals.manager("workspace","history-first",root,16777216,store,null,"history");
    var endpoint = historyEndpoint(root);
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
      var deadline = Sys.time()+15;
      while (!check()) { require(Sys.time()<deadline,message+"
"+allText(session.emulator)); step(); Sys.sleep(0.005); }
    };
    until(function() return backend.isSynchronized(),"Initial shell did not synchronize");
    session.write(TestShell.line(TestShell.assign("KEEP","previous")));
    session.write(TestShell.counted("SAVED_",60," 界"));
    until(function() return allText(session.emulator).indexOf("SAVED_059")>=0,"Shell output missing");
    // The service stops; its terminal goes on in its host and the next service takes it back.
    manager.dispose(); store.close();
    store = new WorkspaceSqliteStore(path,"workspace",seed);
    manager = TestTerminals.manager("workspace","history-second",root,16777216,store,null,"history");
    var record = manager.snapshot().terminals[0];
    require(record.state=="running" && manager.activeCount()==1,"The next service did not take the shell back from its host");
    connect("history-second");
    step(); // Observe the new endpoint before checking the view's state.
    until(function() return backend.isSynchronized() && backend.canControl() && session.status=="running" && allText(session.emulator).indexOf("SAVED_000")>=0,
      "The open pane did not come back with the shell's scrollback after the service changed");
    session.write(TestShell.variable("KEPT_ENV:","KEEP"));
    until(function() return allText(session.emulator).indexOf("KEPT_ENV:previous")>=0,"The shell taken back lost its state");
    // Duplicate restart requests cannot replace the running process.
    var error = "";
    RpcCalls.call(endpoint.connection, WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:"history-second",id:"history-shell"},1000,
      function(_) { throw "Running shell restarted"; },function(e) error=e.code);
    step(); step(); require(error=="terminal_running","Restart replaced a running shell");
    session.write(TestShell.line("exit"));
    until(function() return session.status=="exited","The shell did not exit");
    require(!backend.canControl() && backend.controlAction()=="Restart Terminal","An ended shell was writable or lacked its restart action");
    // Read-only peers cannot start a shell over the ended one.
    var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
    var reader = new RpcConnection(pair.client,clock), readServer = new RpcConnection(pair.server,clock);
    manager.bind(readServer,[WorkspaceTerminalProtocol.READ]);
    error = "";
    RpcCalls.call(reader, WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:"history-second",id:"history-shell"},1000,
      function(_) { throw "Read-only peer restarted shell"; },function(e) error=e.code);
    reader.poll(); readServer.poll(); reader.poll();
    require(error=="unauthorized","Restart ignored control grant"); reader.close(); readServer.close();
    // An ended terminal nobody reads is let go; a view that opens it later gets the last screen its host kept.
    manager.unloadSeconds = 0.2;
    var shown = allText(session.emulator);
    var settle = Sys.time() + 1;
    while (Sys.time() < settle) { step(); Sys.sleep(0.01); }
    require(allText(session.emulator)==shown && backend.isAvailable(),"The open view of an ended terminal changed");
    var later = new RpcTerminalBackend(function() return endpoint,"history-shell",root,false);
    var laterSession = new TerminalSession(later,Emulator.open(80,24,1000,"xterm-256color",false),false);
    until(function() { laterSession.pollEvents(); return later.isSynchronized(); },"A view of an ended terminal did not attach");
    var kept = allText(laterSession.emulator);
    require(kept.indexOf("SAVED_000")>=0 && kept.indexOf("KEPT_ENV:previous")>=0 && laterSession.status=="exited",
      "An ended terminal came back without the last screen its host kept");
    laterSession.close();
    manager.unloadSeconds = WorkspaceTerminalManager.UNLOAD_SECONDS;
    // Restart: a fresh shell whose screen starts with the earlier one's history and a separator.
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running","Explicit shell restart failed");
    // Shell startup programs often clear their new screen. Old output must already be in scrollback before that happens.
    session.write(TestShell.clearedJoined("NEW_","SHELL"));
    until(function() return allText(session.emulator).indexOf("NEW_SHELL")>=0,"New shell did not accept input");
    session.write(TestShell.variable("FRESH_ENV:","KEEP"));
    until(function() return allText(session.emulator).indexOf("FRESH_ENV:unset")>=0,"The restarted shell inherited the ended shell's state");
    var text = allText(session.emulator);
    require(text.indexOf("SAVED_000")>=0 && text.indexOf("SAVED_059")>=0 && text.indexOf("Shell restarted")>=0,
      "Restart or shell startup clear discarded old history
"+text);
    session.write(TestShell.line("exit"));
    until(function() return session.status=="exited","Replacement shell did not exit");
    store.removeTerminal("history-shell");
    require(store.loadTerminals().length==0,"Forget retained the terminal record");
    session.close(); endpoint.connection.close(); server.close(); manager.dispose(); store.close();
    Sys.println("PASS: a service restart keeps the shell, its scrollback and state; an ended shell shows its host's last screen; explicit restart keeps the history with a fresh shell");
  }

  /** A record whose host is gone and left no screen (the machine restarted) opens without spawning and restarts explicitly. */
  static function goneHost(root:String):Void {
    var seed:WorkspaceSnapshot = {epoch:"gone-host",cursor:0,groups:[{id:"work",name:"Work",cwd:root,revision:1}]};
    var store = new WorkspaceSqliteStore(root+"/gone-host-terminal.sqlite","workspace",seed);
    store.saveTerminal({id:"gone-shell",name:"Gone shell",group:"",cwd:root,workspaceRoot:root,
      instance:"previous-service",state:"running",exitCode:0,available:false,revision:1});
    var manager = TestTerminals.manager("workspace","gone-current",root,16777216,store);
    require(manager.snapshot().terminals[0].available && manager.snapshot().terminals[0].state=="lost","A terminal whose host is gone is not shown lost");
    var pair = MemoryTransport.pair(), clock = function() return Sys.time()*1000;
    var client = new RpcConnection(pair.client,clock), server = new RpcConnection(pair.server,clock);
    manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL,WorkspaceTerminalProtocol.CATALOG]);
    var endpoint = historyEndpoint(root); endpoint.connection=client; endpoint.generation="gone-current";
    var backend = new RpcTerminalBackend(function() return endpoint,"gone-shell",root,false);
    var session = new TerminalSession(backend,Emulator.open(80,24),false);
    var step = function() { client.poll();server.poll();manager.poll();client.poll();session.pollEvents(); };
    var until = function(check:Void->Bool,message:String) {
      var deadline=Sys.time()+15;
      while (!check()) { require(Sys.time()<deadline,message);step();Sys.sleep(0.005); }
    };
    until(function() return backend.isSynchronized(),"A terminal whose host is gone did not open");
    require(session.status=="lost" && manager.activeCount()==0,"Opening a terminal whose host is gone spawned a replacement");
    require(backend.controlStatus()=="Session ended · no saved history" && backend.controlAction()=="Restart Terminal",
      "A terminal whose host is gone lacks an honest explanation or restart action");
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running","A terminal whose host is gone could not restart explicitly");
    session.write(TestShell.joined("RECOVERED_","SHELL"));
    until(function() return allText(session.emulator).indexOf("RECOVERED_SHELL")>=0,"The restarted shell did not accept input");
    require(manager.snapshot().terminals[0].id=="gone-shell" && manager.activeCount()==1,"Restart changed terminal identity");
    session.write(TestShell.line("exit"));
    until(function() return session.status=="exited","The restarted shell did not exit");
    session.close();client.close();server.close();manager.dispose();store.close();
    Sys.println("PASS: a terminal whose host is gone opens without spawning and restarts explicitly under the same identity");
  }
}
