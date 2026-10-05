package workspace.service;

import haxe.io.Bytes;
import haxe.Int64;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire typedef TerminalOpen = {@: id(1) var workspace: String;
@:id(2) var instance:String;
@:id(3) var id:String;
@:id(4) var create:Bool;
@:id(5) var columns:Int;
@:id(6) var rows:Int;
}
@:wire typedef TerminalInfo = {@: id(1) var id: String;
@:id(2) var cwd:String;
@:id(3) var state:String;
@:id(4) var exitCode:Int;
@:id(5) var columns:Int;
@:id(6) var rows:Int;
@:id(7) var start:Int64;
@:id(8) var end:Int64;
}
@:wire typedef TerminalRead = {@: id(1) var workspace: String;
@:id(2) var instance:String;
@:id(3) var id:String;
@:id(4) var offset:Int64;
}
@:wire typedef TerminalOutput = {@: id(1) var terminal: TerminalInfo;
@:id(2) var offset:Int64;
@:id(3) var data:Bytes;
}
@:wire typedef TerminalInput = {@: id(1) var workspace: String;
@:id(2) var instance:String;
@:id(3) var id:String;
@:id(4) var sequence:Int;
@:id(5) var data:Bytes;
}
@:wire typedef TerminalResize = {@: id(1) var workspace: String;
@:id(2) var instance:String;
@:id(3) var id:String;
@:id(4) var columns:Int;
@:id(5) var rows:Int;
}
@:wire typedef TerminalTarget = {@: id(1) var workspace: String;
@:id(2) var instance:String;
@:id(3) var id:String;
}
/** Permanent method ids; output offsets count bytes. Input is never retried across connections. */
class WorkspaceTerminalProtocol {
  public static inline final READ = "workspace.terminals.read";
  public static inline final CONTROL = "workspace.terminals.control";
  public static final OPEN = new RpcMethod<TerminalOpen, TerminalInfo>(
    110,
    function(v:TerminalOpen) return MessagePack.encode(v),
    function(b:Bytes):TerminalOpen return MessagePack.decode(b),
    function(v:TerminalInfo) return MessagePack.encode(v),
    function(b:Bytes):TerminalInfo return MessagePack.decode(b)
  );
  public static final OUTPUT = new RpcMethod<TerminalRead, TerminalOutput>(
    111,
    function(v:TerminalRead) return MessagePack.encode(v),
    function(b:Bytes):TerminalRead return MessagePack.decode(b),
    function(v:TerminalOutput) return MessagePack.encode(v),
    function(b:Bytes):TerminalOutput return MessagePack.decode(b)
  );
  public static final INPUT = new RpcMethod<TerminalInput, TerminalInfo>(
    112,
    function(v:TerminalInput) return MessagePack.encode(v),
    function(b:Bytes):TerminalInput return MessagePack.decode(b),
    function(v:TerminalInfo) return MessagePack.encode(v),
    function(b:Bytes):TerminalInfo return MessagePack.decode(b)
  );
  public static final RESIZE = new RpcMethod<TerminalResize, TerminalInfo>(
    113,
    function(v:TerminalResize) return MessagePack.encode(v),
    function(b:Bytes):TerminalResize return MessagePack.decode(b),
    function(v:TerminalInfo) return MessagePack.encode(v),
    function(b:Bytes):TerminalInfo return MessagePack.decode(b)
  );
  public static final TERMINATE = new RpcMethod<TerminalTarget, TerminalInfo>(
    114,
    function(v:TerminalTarget) return MessagePack.encode(v),
    function(b:Bytes):TerminalTarget return MessagePack.decode(b),
    function(v:TerminalInfo) return MessagePack.encode(v),
    function(b:Bytes):TerminalInfo return MessagePack.decode(b)
  );
}
