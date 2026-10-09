package process;

import haxe.io.Bytes;

#if !wasm
import sys.io.ChildProcess;

/** Reads one bounded, byte-exact chunk from a nonblocking child pipe. */
class ProcessByteStream {
	final buffer:Bytes = Bytes.alloc(16384);

	public function new() {}

	public function read(child:ChildProcess, standardError:Bool = false):Bytes {
		var count = standardError ? child.readStderr(buffer, 0, buffer.length) : child.readStdout(buffer, 0, buffer.length);
		return count > 0 ? buffer.sub(0, count) : Bytes.alloc(0);
	}
}
#else
/** Browser hosts cannot read native process pipes. */
class ProcessByteStream {
	public function new() {}
	public function read(child:Dynamic, standardError:Bool = false):Bytes return Bytes.alloc(0);
}
#end
