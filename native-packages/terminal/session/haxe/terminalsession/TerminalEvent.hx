package terminalsession;

import haxe.io.Bytes;

/** Output offsets count bytes, not Unicode characters. */
class TerminalEvent {
    public final kind:String;
    public final offset:haxe.Int64;
    public final data:Bytes;
    public final length:Int;
    public final state:String;
    public final exitCode:Int;

    private function new(kind:String, offset:haxe.Int64, data:Bytes, length:Int,
            state:String, exitCode:Int) {
        this.kind = kind;
        this.offset = offset;
        this.data = data;
        this.length = length;
        this.state = state;
        this.exitCode = exitCode;
    }

    /** The byte buffer may be borrowed for the duration of pollEvents. */
    public static function output(offset:haxe.Int64, data:Bytes, length:Int = -1):TerminalEvent {
        var count = length < 0 ? data.length : length;
        if (count < 0 || count > data.length) throw "Invalid terminal output length";
        return new TerminalEvent("output", offset, data, count, "", 0);
    }

    public static function status(state:String, exitCode:Int = 0):TerminalEvent
        return new TerminalEvent("status", 0, null, 0, state, exitCode);
}
