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
    public function alternateScreen():Bool
        return TerminalKit.terminalkit_alternate_screen(live()) != 0;
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

    /** Copies one styled row from the borrowed native snapshot. */
    public function rowCells(row:Int):Array<Cell> {
        var copied = TerminalKit.terminalkit_row_cells_copy(live(), row);
        if (copied.status != 0) throw "Terminal cell copy failed";
        var bytes:haxe.io.Bytes = copied.buffer;
        var cells:Array<Cell> = [];
        var offset = 0;
        for (_ in 0...columns()) {
            if (offset + 16 > bytes.length) throw "Terminal cell data is truncated";
            var low = read32(bytes, offset);
            var high = read32(bytes, offset + 4);
            var width = read32(bytes, offset + 8);
            var length = read32(bytes, offset + 12);
            offset += 16;
            if (length < 0 || length > bytes.length - offset)
                throw "Terminal cell text is truncated";
            cells.push({text: bytes.sub(offset, length).toString(), width: width,
                style: haxe.Int64.make(high, low)});
            offset += length;
        }
        if (offset != bytes.length) throw "Terminal cell data has trailing bytes";
        return cells;
    }

    /** Returns pending encoded replies; the native direct-callback path avoids this copy. */
    public function takeReplies():haxe.io.Bytes {
        var copied = TerminalKit.terminalkit_take_replies(live());
        if (copied.status == -2) throw "Terminal reply queue overflowed";
        if (copied.status != 0) throw "Terminal reply copy failed";
        return copied.buffer;
    }

    public function key(name:String, modifiers:Int = 0, unicode:Int = -1):Bool
        return TerminalKit.terminalkit_keyboard(live(), name, modifiers, unicode) != 0;

    public function mouse(x:Int, y:Int, button:Int, event:Int, modifiers:Int = 0):Bool
        return TerminalKit.terminalkit_mouse(live(), x, y, button, event, modifiers) != 0;

    public function focus(focused:Bool):Void
        TerminalKit.terminalkit_focus(live(), focused ? 1 : 0);

    public function checkpoint():haxe.io.Bytes {
        var size = haxe.Int64.toInt(TerminalKit.terminalkit_checkpoint_size(live()));
        if (size <= 0) throw "Terminal checkpoint unavailable";
        var bytes = haxe.io.Bytes.alloc(size);
        var saved = TerminalKit.terminalkit_checkpoint(live(), bytes, size);
        if (saved.status != 1 || saved.written != size)
            throw "Terminal checkpoint failed";
        return bytes;
    }

    public function restore(checkpoint:haxe.io.Bytes):Void {
        if (TerminalKit.terminalkit_restore(live(), checkpoint, checkpoint.length) != 1)
            throw "Terminal checkpoint restore failed";
    }

    private static function read32(bytes:haxe.io.Bytes, offset:Int):Int
        return bytes.get(offset) | (bytes.get(offset + 1) << 8) |
            (bytes.get(offset + 2) << 16) | (bytes.get(offset + 3) << 24);

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
