package app;

import haxe.io.Bytes;
import terminalkit.Emulator;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;
import terminalsession.LocalPtyBackend;
import terminalsession.TerminalProfile;
import NativeKitRuntime;

class FakeBackend implements TerminalBackend {
    public function id():String return "remote-test";
    public final events:Array<TerminalEvent> = [];
    public final replays:Array<haxe.Int64> = [];
    public final writes:Array<String> = [];
    public var resizes:Int = 0;
    public var detaches:Int = 0;
    public var terminations:Int = 0;
    public var closes:Int = 0;

    public function new() {}
    public function write(bytes:Bytes):Void writes.push(bytes.toString());
    public function resize(columns:Int, rows:Int):Void resizes++;
    public function pollEvents(emit:TerminalEvent->Void):Void {
        var batch = events.copy();
        events.resize(0);
        for (event in batch) emit(event);
    }
    public function requestReplay(offset:haxe.Int64):Void replays.push(offset);
    public function terminate(force:Bool):Void terminations++;
    public function detach():Void detaches++;
    public function close():Void closes++;
}

class Main {
    static function output(offset:Int, text:String):TerminalEvent
        return TerminalEvent.output(offset, Bytes.ofString(text));

    static function main():Void {
        var backend = new FakeBackend();
        var session = new TerminalSession(backend, Emulator.open(20, 4, 8));
        session.emulator.feedString("\x1b[?2004h");
        session.emulator.paste(Bytes.ofString("hello\n日本語"));
        session.pollEvents();
        if (backend.writes.length != 1 || backend.writes[0] != "\x1b[200~hello\n日本語\x1b[201~")
            throw "bracketed paste was not delivered to the backend";
        session.emulator.feedString("\x1b[?2004l");
        session.emulator.paste(Bytes.ofString("plain"));
        session.pollEvents();
        if (backend.writes.length != 2 || backend.writes[1] != "plain")
            throw "plain paste was not delivered to the backend";
        backend.events.push(output(6, "world"));
        session.pollEvents();
        if (session.offset != 0 || backend.replays.length != 1 || backend.replays[0] != 0)
            throw "gap did not request replay";
        backend.events.push(output(0, "hello "));
        session.pollEvents();
        session.emulator.snapshot();
        if (session.offset != 11 || session.emulator.rowText(0).substr(0, 11) != "hello world")
            throw "out-of-order output did not join";
        backend.events.push(output(0, "hello"));
        backend.events.push(output(8, "rld!"));
        session.pollEvents();
        session.emulator.snapshot();
        if (session.offset != 12 || session.emulator.rowText(0).substr(0, 12) != "hello world!")
            throw "duplicate or overlapping output was misapplied";
        session.emulator.selectionStart(0, 0);
        session.emulator.selectionTarget(4, 0);
        if (session.emulator.selectionText() != "hello") throw "native selection binding lost text";
        session.emulator.selectionClear();
        if (session.emulator.selectionText() != null) throw "cleared selection should be absent";
        backend.events.push(TerminalEvent.status("exited", 7));
        backend.events.push(output(12, " after"));
        session.pollEvents();
        session.emulator.snapshot();
        if (session.status != "exited" || session.exitCode != 7 ||
                session.emulator.rowText(0).substr(0, 18) != "hello world! after")
            throw "output after exit was lost";
        session.write(Bytes.ofString("input"));
        session.resize(30, 5);
        session.detach();
        session.terminate(true);
        if (backend.writes.length != 3 || backend.writes[2] != "input" ||
                backend.resizes != 1 || backend.detaches != 1 || backend.terminations != 1)
            throw "backend operations were not forwarded";
        var checkpoint = session.emulator.checkpoint();
        var replacement = new TerminalSession(new FakeBackend(), Emulator.open(5, 2, 2));
        replacement.applyCheckpoint(checkpoint, session.offset);
        replacement.emulator.snapshot();
        if (replacement.offset != session.offset || replacement.emulator.columns() != 30 ||
                replacement.emulator.rowText(0).substr(0, 18) != "hello world! after")
            throw "checkpoint did not restore session state";
        replacement.close();
        session.close();
        session.close();
        if (backend.closes != 1 || session.status != "closed")
            throw "session close was not idempotent";
        localPtySmoke();
    }

    static function localPtySmoke():Void {
        var runtime = NativeKitRuntime.start();
        var profile = new TerminalProfile("/bin/sh", ["-c",
            "stty -echo; printf 'READY:%s:%s\\r\\n' \"$TERM\" \"${NO_COLOR-unset}\"; " +
            "IFS= read -r line; printf 'GOT:%s\\r\\n' \"$line\""], "/tmp");
        var local = new TerminalSession(LocalPtyBackend.spawn(profile, 40, 4),
            Emulator.open(40, 4, 8));
        var sent = false;
        var deadline = Sys.time() + 5;
        while (Sys.time() < deadline) {
            local.pollEvents();
            local.emulator.snapshot();
            var first = local.emulator.rowText(0);
            if (!sent && first.indexOf("READY:xterm-256color:unset") >= 0) {
                local.write(Bytes.ofString("typed\n"));
                sent = true;
            }
            if (sent && local.emulator.rowText(1).indexOf("GOT:typed") >= 0 &&
                    local.status == "exited") break;
            Sys.sleep(0.01);
        }
        var okay = sent && local.emulator.rowText(1).indexOf("GOT:typed") >= 0 &&
            local.status == "exited" && local.exitCode == 0;
        local.close();
        runtime.dispose();
        if (!okay) throw "NativeKit PTY terminal session did not round-trip";
    }
}
