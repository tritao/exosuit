package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceRpcEndpoint;
import workspace.client.RpcTerminalBackend;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.service.WorkspaceTerminalProtocol;
import terminalsession.TerminalSession;
import terminalkit.Emulator;

private class ThemeEndpoint implements WorkspaceRpcEndpoint {
  public final connection:RpcConnection;
  final root:String;
  final router:workspace.client.WorkspaceTerminalEvents;
  public function new(root:String,connection:RpcConnection) {
    this.root=root; this.connection=connection; router=new workspace.client.WorkspaceTerminalEvents(connection);
  }
  public function rootPath():Null<String> return root;
  public function serviceGeneration():String return "theme-test";
  public function workspaceEpoch():Null<String> return "theme-test";
  public function rpcConnection():Null<RpcConnection> return connection;
  public function failureReason():Null<String> return null;
  public function supportsWorkspaceGroups():Bool return true;
  public function hasCapability(value:String):Bool return true;
  public function terminalEvents():Null<workspace.client.WorkspaceTerminalEvents> return router;
}

class TerminalThemeTests {
  static function require(value:Bool,message:String):Void { if (!value) throw message; }
  static function text(e:Emulator):String {
    e.snapshot();
    return StringTools.replace([for (row in 0...e.rows()) e.rowText(row)].join("")," ","");
  }
  public static function run(root:String):Void {
    var script=root+"/query-terminal-colors.py";
    sys.io.File.saveContent(script,
      "import os,sys,termios,tty,select,time\n"
      +"fd=os.open('/dev/tty',os.O_RDWR); old=termios.tcgetattr(fd); result=b''\n"
      +"try:\n"
      +" tty.setraw(fd); os.write(fd,b'\\x1b]10;?\\x1b\\\\\\x1b]11;?\\x1b\\\\'); end=time.monotonic()+3\n"
      +" while result.count(b'\\x1b\\\\')<2 and time.monotonic()<end:\n"
      +"  if select.select([fd],[],[],.1)[0]: result+=os.read(fd,4096)\n"
      +"finally: termios.tcsetattr(fd,termios.TCSANOW,old); os.close(fd)\n"
      +"print(sys.argv[1]+result.hex(),flush=True)\n");
    var clock=function() return Sys.time()*1000;
    var pair=MemoryTransport.pair(), client=new RpcConnection(pair.client,clock), server=new RpcConnection(pair.server,clock);
    var manager=new WorkspaceTerminalManager("workspace","theme-test",root);
    manager.bind(server,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL]);
    var endpoint=new ThemeEndpoint(root,client);
    var backend=new RpcTerminalBackend(function() return endpoint,"theme-shell",root,true);
    backend.setDefaultColors(0x202a36,0xffffff);
    var session=new TerminalSession(backend,Emulator.open(80,24,1000,"xterm-256color",false),false);
    var step=function() { client.poll();server.poll();manager.poll();client.poll();session.pollEvents(); };
    var until=function(check:Void->Bool,message:String) {
      var deadline=Sys.time()+8;
      while (!check()) { require(Sys.time()<deadline,message+"\n"+text(session.emulator));step();Sys.sleep(0.005); }
    };
    until(function() return backend.isSynchronized(),"Theme shell failed to attach");
    session.write(Bytes.ofString("python3 '"+script+"' LIGHT:\n"));
    var light="LIGHT:1b5d31303b7267623a323032302f326132612f333633361b5c1b5d31313b7267623a666666662f666666662f666666661b5c";
    until(function() return text(session.emulator).indexOf(light)>=0,"Initial light theme was not reported by the service");
    // No geometry changes: theme-only updates must reach the service before
    // input starts another application that probes its background.
    backend.setDefaultColors(0xdce3ec,0x171c23);
    session.write(Bytes.ofString("python3 '"+script+"' DARK:\n"));
    var dark="DARK:1b5d31303b7267623a646364632f653365332f656365631b5c1b5d31313b7267623a313731372f316331632f323332331b5c";
    until(function() return text(session.emulator).indexOf(dark)>=0,"Theme change at unchanged geometry was not reported");
    session.write(Bytes.ofString("exit\n"));
    until(function() return session.status=="exited","Theme test shell did not exit");
    backend.setDefaultColors(0x202a36,0xffffff);
    backend.activateControl();
    until(function() return backend.canControl() && session.status=="running","Themed replacement shell did not start");
    session.write(Bytes.ofString("python3 '"+script+"' RESTART:\n"));
    var restarted=StringTools.replace(light,"LIGHT:","RESTART:");
    until(function() return text(session.emulator).indexOf(restarted)>=0,"Replacement shell did not receive the controlling theme");
    // A second reader cannot overwrite the controlling terminal's theme.
    var other=MemoryTransport.pair(), reader=new RpcConnection(other.client,clock), readServer=new RpcConnection(other.server,clock);
    manager.bind(readServer,[WorkspaceTerminalProtocol.READ,WorkspaceTerminalProtocol.CONTROL]);
    var denied="";
    reader.call(WorkspaceTerminalProtocol.RESIZE,{workspace:"workspace",instance:"theme-test",id:"theme-shell",columns:80,rows:24,
      theme:{foreground:0,background:0xffffff}},1000,function(_) { throw "Viewer changed terminal theme"; },function(e) denied=e.code);
    reader.poll();readServer.poll();reader.poll();require(denied=="terminal_controlled","Theme update ignored controller ownership");
    var invalid="";
    client.call(WorkspaceTerminalProtocol.RESIZE,{workspace:"workspace",instance:"theme-test",id:"theme-shell",columns:80,rows:24,
      theme:{foreground:-1,background:0xffffff}},1000,function(_) { throw "Invalid RGB accepted"; },function(e) invalid=e.code);
    step();step();require(invalid=="invalid_request","Invalid theme was not rejected");
    session.close();client.close();server.close();reader.close();readServer.close();manager.dispose();
    Sys.println("PASS: actual PTY reports light/dark defaults over RPC; theme-only updates precede input; viewer and RGB bounds enforced");
  }
}
