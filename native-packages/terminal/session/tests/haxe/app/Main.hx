package app;

import haxe.io.Bytes;
import terminalkit.Emulator;
import terminalsession.TerminalBackend;
import terminalsession.TerminalEvent;
import terminalsession.TerminalSession;
import terminalsession.LocalPtyBackend;
import terminalsession.TerminalProfile;
import haxeon.platform.NativeKitRuntime;

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
    public function resize(columns:Int, rows:Int):Void {
        resizes++;
        events.push(TerminalEvent.geometry(columns, rows));
    }
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
        if (session.emulator.columns() != 20) throw "Resize speculatively changed the grid";
        session.pollEvents();
        if (session.emulator.columns() != 30 || session.emulator.rows() != 5)
            throw "Accepted geometry was not applied";
        session.detach();
        session.terminate(true);
        if (backend.writes.length != 3 || backend.writes[2] != "input" ||
                backend.resizes != 1 || backend.detaches != 1 || backend.terminations != 1)
            throw "backend operations were not forwarded";
        var checkpoint = session.emulator.checkpoint();
        var screenState = session.emulator.screenSnapshot();
        var replacement = new TerminalSession(new FakeBackend(), Emulator.open(5, 2, 2));
        replacement.applyCheckpoint(checkpoint, session.offset);
        replacement.emulator.snapshot();
        if (replacement.offset != session.offset || replacement.emulator.columns() != 30 ||
                replacement.emulator.rowText(0).substr(0, 18) != "hello world! after")
            throw "checkpoint did not restore session state";
        var screenReplacement = new TerminalSession(new FakeBackend(), Emulator.open(5, 2, 2, "xterm-256color", false));
        screenReplacement.applyScreenSnapshot(screenState, session.offset);
        screenReplacement.emulator.snapshot();
        if (screenReplacement.offset != session.offset || screenReplacement.emulator.columns() != 30
                || screenReplacement.emulator.rows() != 5
                || screenReplacement.emulator.rowText(0).substr(0, 18) != "hello world! after")
            throw "bounded screen snapshot did not restore the live viewport";
        screenReplacement.close();
        var modeSource = Emulator.open(20, 4, 8);
        modeSource.feedString("\x1b[?1049h\x1b[?1h\x1b=\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b[?2026h\x1b[31mR\x1b[0m界e\u0301");
        modeSource.snapshot();
        var modeCopy = Emulator.open(10, 3, 8, "xterm-256color", false);
        modeCopy.restoreScreenSnapshot(modeSource.screenSnapshot());
        modeCopy.snapshot();
        if (!modeCopy.alternateScreen() || !modeCopy.synchronizedOutput()
                || modeCopy.mouseMode() != modeSource.mouseMode()
                || !modeCopy.focusReporting()
                || modeCopy.rowText(0).indexOf("R界e\u0301") != 0
                || modeCopy.rowCells(0)[0].style != modeSource.rowCells(0)[0].style)
            throw "screen snapshot lost styled Unicode cells or VT modes";
        modeCopy.close();
        modeSource.close();
        // Screen snapshots contain rendered cursor inversion. Restoring twice
        // must preserve content defaults and keep exactly one cursor inversion.
        var cursorSource = Emulator.open(20, 4, 8, "xterm-256color", false);
        cursorSource.feedString("prompt$ ");
        var cursorCopy = Emulator.open(10, 3, 8, "xterm-256color", false);
        for (_ in 0...2) {
            cursorCopy.restoreScreenSnapshot(cursorSource.screenSnapshot());
            cursorSource.snapshot(); cursorCopy.snapshot();
            for (row in 0...4) for (column in 0...20)
                if (cursorSource.rowCells(row)[column].style != cursorCopy.rowCells(row)[column].style)
                    throw "Screen snapshot baked cursor inversion into content";
        }
        cursorSource.close(); cursorCopy.close();
        replacement.close();
        session.close();
        session.close();
        if (backend.closes != 1 || session.status != "closed")
            throw "session close was not idempotent";
        var remoteBackend = new FakeBackend();
        var remote = new TerminalSession(remoteBackend,Emulator.open(20,4),false);
        remoteBackend.events.push(output(0,"\x1b[6n"));
        remote.pollEvents();
        if(remoteBackend.writes.length!=0) throw "Remote renderer replied to server-owned VT query";
        remote.emulator.paste(Bytes.ofString("paste")); remote.flushInput();
        if(remoteBackend.writes.length!=1 || remoteBackend.writes[0]!="paste") throw "Remote paste was suppressed with query replies";
        remote.close();
        localPtySmoke();
        drainExitSmoke();
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
    static function drainExitSmoke():Void {
        var runtime=NativeKitRuntime.start();
        var backend=LocalPtyBackend.spawn(new TerminalProfile("/usr/bin/python3",["-c",
            "import os; os.write(1,b'x'*262144+b'END'); raise SystemExit(7)"],"/tmp"),80,24);
        var received=0, exited=false, code=0;
        var deadline=Sys.time()+10;
        while(!exited && Sys.time()<deadline) {
            backend.pollEvents(function(event) {
                if(event.kind=="output") received+=event.length;
                else if(event.kind=="status") {exited=true;code=event.exitCode;}
            });
            Sys.sleep(0.005);
        }
        backend.close(); runtime.dispose();
        if(!exited || code!=7 || received!=262147) throw "PTY exit overtook final bounded output drain";
        Sys.println("PASS: PTY exit follows complete burst output; remote query suppression preserves explicit input");
    }

}
