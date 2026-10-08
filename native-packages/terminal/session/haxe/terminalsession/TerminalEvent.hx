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
    public final columns:Int;
    public final rows:Int;

    private function new(kind:String, offset:haxe.Int64, data:Bytes, length:Int,
            state:String, exitCode:Int, columns:Int = 0, rows:Int = 0) {
        this.kind = kind;
        this.offset = offset;
        this.data = data;
        this.length = length;
        this.state = state;
        this.exitCode = exitCode;
        this.columns = columns;
        this.rows = rows;
    }

    /** The byte buffer may be borrowed for the duration of pollEvents. */
    public static function output(offset:haxe.Int64, data:Bytes, length:Int = -1):TerminalEvent {
        var count = length < 0 ? data.length : length;
        if (count < 0 || count > data.length) throw "Invalid terminal output length";
        return new TerminalEvent("output", offset, data, count, "", 0);
    }

    public static function status(state:String, exitCode:Int = 0):TerminalEvent
        return new TerminalEvent("status", 0, null, 0, state, exitCode);

    /** A bounded active-screen snapshot replaces the renderer before replay resumes. */
    public static function screenSnapshot(offset:haxe.Int64, data:Bytes):TerminalEvent {
        if (offset < 0 || data == null || data.length == 0)
            throw "Invalid terminal screen snapshot event";
        return new TerminalEvent("snapshot", offset, data, data.length, "", 0);
    }

    public static function geometry(columns:Int, rows:Int):TerminalEvent {
        if (columns < 1 || columns > 65535 || rows < 1 || rows > 65535) throw "Invalid terminal geometry";
        return new TerminalEvent("geometry", 0, null, 0, "", 0, columns, rows);
    }
}
