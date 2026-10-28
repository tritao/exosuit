package app;

import processkit.Processes;
import processkit.ffi.ProcessKitConstants;

/** The Haxe binding over processkit: the owned snapshot handle and the identity rule. */
class Main {
	static function main():Void {
		var self = Processes.currentPid();
		var listed = Processes.list("*");
		if (listed == null) {
			Sys.println("SKIP: process listing is not implemented on this platform");
		} else {
			var mine:Null<ProcessInfo> = null;
			for (info in listed)
				if (info.pid == self)
					mine = info;
			require(mine != null, "the snapshot lists this process");
			if (mine != null) {
				require(mine.started == Processes.started(self), "listing and started agree");
				require(mine.commandLine.length > 0, "\"*\" reads this process's command line");
			}
			// Each list closes its owned snapshot, so many in a row never exhaust processkit's handle table.
			for (_ in 0...100)
				require(Processes.list("") != null, "snapshots are released");
		}
		var started = Processes.started(self);
		require(started > 0, "this process has a start time");
		require(Processes.alive(self, started), "the same pid and start time are alive");
		require(!Processes.alive(self, started + 1), "another start time is another process");
		require(!Processes.alive(self, 0), "an unknown start time proves nothing");
		require(Processes.terminate(self, 0) == ProcessKitConstants.PROCESSKIT_UNKNOWN_START, "terminate refuses an unknown start");
		require(Processes.terminate(self, started - 1) == ProcessKitConstants.PROCESSKIT_NOT_FOUND, "terminate refuses a reused pid");
		Sys.println("PASS: processkit Haxe binding");
	}

	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw "FAIL: " + message;
	}
}
