package terminalsession;

import haxe.io.Bytes;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Bounded, nonblocking NativeKit PTY adapter. NativeKit must be initialized. */
class LocalPtyBackend implements TerminalBackend {
    static var nextId:Int = 1;
    public final idValue:String;
    final pty:OwnedPtyHandle;
    final readBuffer:Bytes = Bytes.alloc(65536);
    final writes:Array<Bytes> = [];
    var writeBytes:Int = 0;
    var streamOffset:haxe.Int64 = 0;
    var exited:Bool = false;
    var closed:Bool = false;
    final geometry:Array<TerminalEvent> = [];

    private function new(pty:OwnedPtyHandle) {
        this.pty = pty;
        idValue = "local-" + nextId++;
    }
    public function id():String return idValue;

    public static function spawn(profile:TerminalProfile, columns:Int, rows:Int):LocalPtyBackend {
        if (columns < 1 || columns > 65535 || rows < 1 || rows > 65535)
            throw "Terminal size is outside PTY limits";
        var opened = NativeKit.nk_pty_spawn(profile.program, profile.arguments,
            profile.cwd, profile.childEnvironment(), columns, rows);
        if (opened.status != 0) throw 'PTY spawn failed: ${NativeKit.nk_last_error()}';
        return new LocalPtyBackend(opened.out_pty);
    }

    public function write(bytes:Bytes):Void {
        ensureOpen();
        if (bytes == null || bytes.length == 0) return;
        if (writeBytes + bytes.length > 1048576) throw "PTY input queue is full";
        flushWrites();
        var sent = 0;
        if (writes.length == 0) {
            var result = NativeKit.nk_pty_write(pty.borrow(), bytes, bytes.length);
            if (result.status != 1) {
                check(result.status, "write");
                sent = haxe.Int64.toInt(result.out_written);
            }
        }
        if (sent < bytes.length) {
            writes.push(bytes.sub(sent, bytes.length - sent));
            writeBytes += bytes.length - sent;
        }
    }
    public function resize(columns:Int, rows:Int):Void {
        ensureOpen();
        if (columns < 1 || columns > 65535 || rows < 1 || rows > 65535)
            throw "Terminal size is outside PTY limits";
        check(NativeKit.nk_pty_resize(pty.borrow(), columns, rows), "resize");
        geometry.push(TerminalEvent.geometry(columns, rows));
    }
    public function pollEvents(emit:TerminalEvent->Void):Void {
        ensureOpen();
        for (event in geometry) emit(event);
        geometry.resize(0);
        flushWrites();
        var drained = false;
        for (_ in 0...4) {
            var read = NativeKit.nk_pty_read(pty.borrow(), readBuffer, readBuffer.length);
            if (read.status == 1 || read.status == -12) { drained = true; break; }
            check(read.status, "read");
            var count = haxe.Int64.toInt(read.out_read);
            if (count <= 0) { drained = true; break; }
            emit(TerminalEvent.output(streamOffset, readBuffer, count));
            streamOffset += count;
        }
        // Exit status must follow all queued output, including a final burst beyond this poll budget.
        if (!exited && drained) {
            var result = NativeKit.nk_pty_exit_status(pty.borrow());
            if (result.status == 0) {
                exited = true;
                emit(TerminalEvent.status("exited", result.out_code));
            } else if (result.status != 1) check(result.status, "exit status");
        }
    }
    public function requestReplay(offset:haxe.Int64):Void {
        throw "Local PTY output cannot replay";
    }
    public function terminate(force:Bool):Void {
        ensureOpen();
        if (force) check(NativeKit.nk_pty_kill(pty.borrow()), "kill");
        else write(Bytes.ofString("\x03"));
    }
    public function detach():Void { ensureOpen(); }
    public function close():Void {
        if (closed) return;
        pty.close();
        closed = true;
        writes.resize(0);
    }

    private function flushWrites():Void {
        while (writes.length > 0) {
            var bytes = writes[0];
            var sent = NativeKit.nk_pty_write(pty.borrow(), bytes, bytes.length);
            if (sent.status == 1) return;
            check(sent.status, "write");
            var count = haxe.Int64.toInt(sent.out_written);
            if (count <= 0) return;
            writeBytes -= count;
            if (count == bytes.length) writes.shift();
            else writes[0] = bytes.sub(count, bytes.length - count);
        }
    }
    private function ensureOpen():Void {
        if (closed) throw "PTY backend is closed";
    }
    private static function check(result:Int, operation:String):Void {
        if (result != 0) throw 'PTY $operation failed: ${NativeKit.nk_last_error()}';
    }
}
