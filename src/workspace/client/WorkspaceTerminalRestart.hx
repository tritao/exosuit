package workspace.client;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceTerminalProtocol;

/** Shared explicit restart: inspect an existing resource, then start a replacement process. */
class WorkspaceTerminalRestart {
 public static function request(connection:RpcConnection, instance:String, id:String, theme:Null<TerminalTheme>,
   current:Void->Bool, done:TerminalInfo->Void, failed:RpcError->Void):Void {
  // OPEN with create=false restores metadata/history only. It also lets older services
  // advertise restart support without requiring a new catalog capability.
  connection.call(WorkspaceTerminalProtocol.OPEN, {
   workspace:"workspace",instance:instance,id:id,create:false,columns:80,rows:24
  },3000,function(info) {
   if (!current()) {failed({code:"disconnected",message:"Workspace connection or permissions changed",ambiguous:false});return;}
   if (info.id != id) {failed({code:"invalid_response",message:"Invalid terminal identity",ambiguous:false});return;}
   if (info.state == "running" || info.state == "starting") {
    failed({code:"terminal_running",message:"This terminal is already running",ambiguous:false});return;
   }
   if (info.restartable != true) {
    failed({code:"unsupported",message:"Update the workspace service in Remote Access to restart this terminal",ambiguous:false});return;
   }
   connection.call(WorkspaceTerminalProtocol.RESTART,{workspace:"workspace",instance:instance,id:id,theme:theme},5000,done,failed);
  },failed);
 }
 public static function message(error:RpcError):String {
  if (error.ambiguous || error.code == "timeout") return "The restart could not be confirmed. Refresh before trying again; saved history is retained.";
  return switch(error.code) {
   case "unsupported", "unknown_method": "Update the workspace service in Remote Access to restart this terminal.";
   case "unauthorized": "Restarting this terminal requires terminal read and control permissions.";
   case "terminal_running": "This terminal is already running.";
   case "disconnected": "The workspace connection changed. Reconnect before restarting this terminal.";
   default: error.message;
  };
 }
}
