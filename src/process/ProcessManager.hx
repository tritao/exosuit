package process;

#if !wasm
import sys.io.Process;
#end

class ProcessManager {
	final owned:Array<OwnedProcess> = [];

	public final available:Bool;

	public function new(available:Bool = true) this.available = available;

	public function start(executable:String, arguments:Array<String>, cwd:String = "", ?environment:Map<String, String>):OwnedProcess {
		if (!available) throw "Processes are unavailable on this host";
		#if wasm
		throw "Processes are unavailable on this host";
		#else
		var keys:Array<String> = [], values:Array<String> = [];
		if (environment != null)
			for (key => value in environment) { keys.push(key); values.push(value); }
		var child = Process.spawn(executable, arguments, cwd, keys, values);
		var process = new OwnedProcess(child);
		owned.push(process);
		return process;
		#end
	}

	public function release(process:OwnedProcess):Bool {
		if (!owned.remove(process)) return false;
		process.dispose();
		return true;
	}

	public function shutdown():Void {
		var index = owned.length;
		while (index > 0) {
			index--;
			owned[index].dispose();
		}
		owned.resize(0);
	}

	public function activeCount():Int return owned.length;
}
