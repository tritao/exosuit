package terminalsession;

import haxe.io.Bytes;
import terminalkit.Emulator;

/** Ordered output and lifecycle shared by local and remote terminal backends. */
class TerminalSession {
    public final id:String;
    public final emulator:Emulator;
    public var status(default, null):String = "running";
    public var exitCode(default, null):Int = 0;
    public var offset(default, null):haxe.Int64 = 0;

    final backend:TerminalBackend;
    final respondToQueries:Bool;
    final pending:Array<TerminalEvent> = [];
    var pendingBytes:Int = 0;
    var replayAt:haxe.Int64 = -1;
    var closed:Bool = false;

    public function new(backend:TerminalBackend, emulator:Emulator, respondToQueries:Bool = true) {
        if (backend == null || emulator == null) throw "Terminal session needs a backend and emulator";
        this.backend = backend;
        this.respondToQueries = respondToQueries;
        this.emulator = emulator;
        id = backend.id();
    }

    public function write(bytes:Bytes):Void {
        ensureOpen();
        backend.write(bytes);
    }
    public function resize(columns:Int, rows:Int):Void {
        ensureOpen();
        backend.resize(columns, rows);
        emulator.resize(columns, rows);
    }
    public function pollEvents():Void {
        ensureOpen();
        backend.pollEvents(applyEvent);
        var replies = emulator.takeReplies();
        if (respondToQueries && replies.length > 0) backend.write(replies);
    }
    /** Send explicit keyboard/paste replies even when server owns VT query responses. */
    public function flushInput():Void {
        ensureOpen();
        var bytes = emulator.takeReplies();
        if (bytes.length > 0) backend.write(bytes);
    }
    public function requestReplay(from:haxe.Int64):Void {
        ensureOpen();
        backend.requestReplay(from);
    }
    public function terminate(force:Bool = false):Void {
        ensureOpen();
        backend.terminate(force);
    }
    public function detach():Void {
        ensureOpen();
        backend.detach();
    }
    public function applyCheckpoint(checkpoint:Bytes, at:haxe.Int64):Void {
        ensureOpen();
        if (at < 0) throw "Terminal checkpoint offset is negative";
        emulator.restore(checkpoint);
        offset = at;
        pending.resize(0);
        pendingBytes = 0;
        replayAt = -1;
    }
    public function close():Void {
        if (closed) return;
        backend.close();
        emulator.close();
        pending.resize(0);
        closed = true;
        status = "closed";
    }

    private function applyEvent(event:TerminalEvent):Void {
        if (event.kind == "status") {
            status = event.state;
            exitCode = event.exitCode;
        } else if (event.kind == "geometry") {
            emulator.resize(event.columns, event.rows);
        } else if (event.kind == "output") {
            applyOutput(event);
        }
    }
    private function applyOutput(event:TerminalEvent):Void {
        if (event.data == null || event.offset < 0) throw "Invalid terminal output event";
        if (event.offset > offset) {
            queueGap(event);
            return;
        }
        append(event);
        drainPending();
    }
    private function append(event:TerminalEvent):Void {
        var alreadyApplied = offset - event.offset;
        if (alreadyApplied >= event.length) return;
        var skip = haxe.Int64.toInt(alreadyApplied);
        var count = event.length - skip;
        emulator.feedRange(event.data, skip, count);
        offset += count;
        replayAt = -1;
    }
    private function queueGap(event:TerminalEvent):Void {
        if (pendingBytes + event.length > 1048576 || pending.length >= 256) {
            pending.resize(0);
            pendingBytes = 0;
            replayAt = -1;
        } else {
            pending.push(TerminalEvent.output(event.offset, event.data.sub(0, event.length)));
            pendingBytes += event.length;
        }
        if (replayAt != offset) {
            replayAt = offset;
            backend.requestReplay(offset);
        }
    }
    private function drainPending():Void {
        var advanced = true;
        while (advanced) {
            advanced = false;
            for (index in 0...pending.length) {
                var event = pending[index];
                if (event.offset > offset) continue;
                pending.splice(index, 1);
                pendingBytes -= event.length;
                var before = offset;
                append(event);
                advanced = offset > before;
                break;
            }
        }
        if (pending.length > 0 && replayAt != offset) {
            replayAt = offset;
            backend.requestReplay(offset);
        }
    }
    private function ensureOpen():Void {
        if (closed) throw "Terminal session is closed";
    }
}
