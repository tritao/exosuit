package terminalkit;

import terminalkit.ffi.TerminalKit;
import terminalkit.ffi.TerminalKitTypes;

/** Headless terminal emulator. Close it when the session ends. */
class Emulator {
    final handle:TerminalHandle;
    var closed:Bool = false;

    private function new(handle:TerminalHandle) this.handle = handle;

    public static function open(columns:Int, rows:Int, scrollbackLimit:Int = 1000,
            term:String = "xterm-256color"):Emulator {
        var opened = TerminalKit.terminalkit_open(columns, rows, scrollbackLimit, term);
        if (opened.status != 1 || opened.out_kit == null)
            throw "Terminal emulator open failed";
        return new Emulator(opened.out_kit);
    }

    public function feed(bytes:haxe.io.Bytes):Int
        return TerminalKit.terminalkit_feed(live(), bytes, bytes.length);

    public function feedString(text:String):Int
        return feed(haxe.io.Bytes.ofString(text));

    public function resize(columns:Int, rows:Int):Void
        TerminalKit.terminalkit_resize(live(), columns, rows);

    public function columns():Int return TerminalKit.terminalkit_columns(live());
    public function rows():Int return TerminalKit.terminalkit_rows(live());
    public function title():String return TerminalKit.terminalkit_title(live());
    public function synchronizedOutput():Bool
        return TerminalKit.terminalkit_synchronized_output(live()) != 0;
    public function focusReporting():Bool
        return TerminalKit.terminalkit_focus_reporting(live()) != 0;
    public function mouseMode():Int return TerminalKit.terminalkit_mouse_mode(live());

    /** Rebuilds the cached grid only after new output. Returns changed-row count. */
    public function snapshot():Int return TerminalKit.terminalkit_snapshot(live());
    public function rowChanged(row:Int):Bool
        return TerminalKit.terminalkit_row_changed(live(), row) != 0;
    public function rowId(row:Int):haxe.Int64
        return TerminalKit.terminalkit_row_id(live(), row);

    /** Copies one rendered row into Haxe-owned UTF-8 storage. */
    public function rowText(row:Int):String {
        var copied = TerminalKit.terminalkit_row_text_copy(live(), row);
        if (copied.status != 0) throw "Terminal row copy failed";
        return copied.buffer.toString();
    }

    public function cursor():{column:Int, row:Int, mode:Int} {
        var got = TerminalKit.terminalkit_cursor(live());
        if (got.status != 1) throw "Terminal cursor unavailable";
        return {column: got.column, row: got.row, mode: got.mode};
    }

    public function close():Void {
        if (closed) return;
        TerminalKit.terminalkit_close(handle);
        closed = true;
    }

    private function live():TerminalHandle {
        if (closed) throw "Terminal emulator is closed";
        return handle;
    }
}
