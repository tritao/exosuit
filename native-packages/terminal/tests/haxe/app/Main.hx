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
        var plain = emulator.rowCells(0);
        if (plain.length != 20 || plain[0].text != "h" || plain[0].width != 1)
            throw "cell grid missing";
        var cursor = emulator.cursor();
        if (cursor.column != 0 || cursor.row != 1)
            throw "cursor incorrect";
        emulator.feedString("\x1b[?2026h");
        if (!emulator.synchronizedOutput())
            throw "synchronized output mode missing";
        emulator.feedString("\x1b[?2026l\x1b[31mX\x1b[0m");
        emulator.snapshot();
        var styled = emulator.rowCells(1);
        if (styled[0].text != "X" || styled[0].style == plain[0].style)
            throw "styled cell missing";
        emulator.feedString("\x1b[?u");
        if (emulator.takeReplies().toString() != "\x1b[?0u" || emulator.takeReplies().length != 0)
            throw "terminal reply missing";
        emulator.feedString("\x1b[?1004h");
        emulator.focus(true);
        emulator.focus(false);
        if (emulator.takeReplies().toString() != "\x1b[I\x1b[O")
            throw "focus reply missing";
        emulator.feedString("\x1b[?1049h");
        if (!emulator.alternateScreen()) throw "alternate screen did not enter";
        emulator.feedString("\x1b[?1049l");
        if (emulator.alternateScreen()) throw "alternate screen did not leave";
        var checkpoint = emulator.checkpoint();
        var restored = Emulator.open(5, 2, 2);
        restored.restore(checkpoint);
        restored.snapshot();
        if (restored.columns() != 20 || restored.rows() != 4 ||
                restored.rowCells(1)[0].text != "X")
            throw "checkpoint restore differs";
        restored.close();
        emulator.close();
    }
}
