package process;

import platform.Native;

class ProcessManager {
	final owned:Array<OwnedProcess> = [];

	public final available:Bool;

	public function new(available:Bool = true) this.available = available;

	public function start(executable:String, arguments:Array<String>, cwd:String = "", ?environment:Map<String, String>):OwnedProcess {
		if (!available) throw "Processes are unavailable on this host";
		var id = Native.process_create(executable, cwd);
		if (id == 0) throw Native.last_error();
		var process = new OwnedProcess(id), configured = true;
		for (argument in arguments)
			if (!Native.process_add_argument(id, argument)) {
				configured = false;
				break;
			}
		if (configured && environment != null)
			for (key => value in environment)
				if (!Native.process_set_environment(id, key, value)) {
					configured = false;
					break;
				}
		if (!configured || !Native.process_start(id)) {
			var message = Native.last_error();
			process.dispose();
			throw message;
		}
		owned.push(process);
		return process;
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
