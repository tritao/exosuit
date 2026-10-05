package process;

#if !wasm
import sys.io.ChildProcess;
#end
import haxe.io.Bytes;

#if wasm
/** Browser hosts cannot create subprocesses; keep the shared ownership surface available. */
class OwnedProcess {
	public final id:Int;
	@:allow(process.ProcessManager)
	function new(id:Int) { this.id = id; throw "Processes are unavailable on this host"; }
	public function state():Int return ProcessState.INVALID;
	public function running():Bool return false;
	public function exited():Bool return false;
	public function exitStatus():Int return -1;
	public function readStdout():String return "";
	public function readStderr():String return "";
	public function writeStdin(data:String):Int { throw "Processes are unavailable on this host"; }
	public function writeBytes(bytes:Bytes, offset:Int, length:Int):Int { throw "Processes are unavailable on this host"; }
	public function closeStdin():Bool return false;
	public function cancel():Bool return false;
	public function dispose():Void {}
}
#else
class OwnedProcess {
	public final id:Int;
	static var nextId:Int = 1;
	final child:ChildProcess;
	final stdout = new ProcessTextStream();
	final stderr = new ProcessTextStream();
	var disposed:Bool = false;

	@:allow(process.ProcessManager)
	function new(child:ChildProcess) {
		this.id = nextId++;
		this.child = child;
	}

	public function state():Int
		return disposed ? ProcessState.INVALID : (child.pollExit() < 0 ? ProcessState.RUNNING : ProcessState.EXITED);

	public function running():Bool
		return state() == ProcessState.RUNNING;

	public function exited():Bool
		return state() == ProcessState.EXITED;

	public function exitStatus():Int
		return disposed ? -1 : child.pollExit();

	public function readStdout():String
		return disposed ? "" : stdout.read(child, false);

	public function readStderr():String
		return disposed ? "" : stderr.read(child, true);

	/** Returns UTF-8 bytes accepted, possibly partial, or zero for backpressure. */
	public function writeStdin(data:String):Int {
		var bytes = Bytes.ofString(data);
		return writeBytes(bytes, 0, bytes.length);
	}

	public function writeBytes(bytes:Bytes, offset:Int, length:Int):Int {
		if (disposed) throw "process is disposed";
		return child.writeStdin(bytes, offset, length);
	}

	public function closeStdin():Bool {
		if (disposed) return false;
		child.closeStdin();
		return true;
	}

	public function cancel():Bool {
		if (disposed) return false;
		child.cancel();
		return true;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		child.close();
	}
}

#end
