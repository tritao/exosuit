package terminalsession;

import haxe.io.Bytes;

/** Transport side of a terminal session; remote backends can replay output. */
interface TerminalBackend {
    public function id():String;
    public function write(bytes:Bytes):Void;
    public function resize(columns:Int, rows:Int):Void;
    /** Emit borrowed output synchronously; callers copy only gapped events. */
    public function pollEvents(emit:TerminalEvent->Void):Void;
    public function requestReplay(offset:haxe.Int64):Void;
    public function terminate(force:Bool):Void;
    public function detach():Void;
    public function close():Void;
}
