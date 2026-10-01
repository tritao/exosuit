package app;

import terminalkit.Emulator;

class Main {
    static function main():Void {
        var emulator = Emulator.open(20, 4, 8);
        if (emulator.snapshot() != 4 || emulator.snapshot() != 0)
            throw "initial snapshot failed";
        emulator.feedString("hello\r\n");
        if (emulator.snapshot() < 1 || !emulator.rowChanged(0))
            throw "changed row missing";
        if (emulator.rowText(0).substr(0, 5) != "hello")
            throw "screen text missing";
        var cursor = emulator.cursor();
        if (cursor.column != 0 || cursor.row != 1)
            throw "cursor incorrect";
        emulator.feedString("\x1b[?2026h");
        if (!emulator.synchronizedOutput())
            throw "synchronized output mode missing";
        emulator.close();
    }
}
