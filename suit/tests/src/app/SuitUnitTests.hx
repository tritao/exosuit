package app;

import processkit.Processes;
import suit.SuitClient;
import suit.SuitClock;
import suit.SuitLineage;

/**
	suit's ownership rules over made-up processes: which descendants a stop may kill, what suit adopts,
	how a reused pid is caught, and how registry times are checked. Nothing here lists or touches a real
	process. scripts/test-suit.py runs this before its end-to-end tests.
**/
class SuitUnitTests {
	static inline var WORKER:String = "hl.exe C:/Users/u/AppData/Local/haxeon/compiler/abc.hl C:/Users/u/AppData/Local/haxeon/compiler/abc.json";
	static inline var DAEMON:String = "hl.exe C:/x/agent/build/host/main.hl \\\\.\\pipe\\p 1 C:/s/credential seed C:/s/db C:/root g1";
	static inline var ON:String = "EXOSUIT_SUIT=on\nPATH=C:/bin";

	static var failures:Int = 0;

	static function main():Void {
		descendantsFollowOnlyExosuitKinds();
		reusedPidIsNotFollowed();
		adoptionNeedsExosuitChainAndEnvironment();
		registryTimes();
		temporaryStateIsDisposable();
		if (failures > 0) {
			Sys.println('FAIL: $failures suit unit check(s)');
			Sys.exit(1);
		}
		Sys.println("PASS: suit unit tests");
	}

	static function process(pid:Int, parent:Int, started:Float, name:String, commandLine:String, environment:String = ""):ProcessInfo
		return {pid: pid, parent: parent, started: started, name: name, commandLine: commandLine, environment: environment};

	/** The manager's daemon and its compiler worker die with it; a terminal shell and what it started do not. */
	static function descendantsFollowOnlyExosuitKinds():Void {
		var snapshot = [
			process(10, 1, 100, "hl.exe", "hl.exe C:/x/agent/build/host/main.hl --manager C:/root --state-dir C:/s"),
			process(11, 10, 110, "hl.exe", DAEMON),
			process(12, 11, 120, "hl.exe", WORKER),
			process(13, 11, 130, "pwsh.exe", "pwsh.exe -NoLogo"),
			process(14, 13, 140, "hl.exe", WORKER), // a build the user ran in an exosuit terminal
			process(15, 13, 150, "code.exe", "code.exe ."), // a program the user started from it
			process(16, 11, 90, "hl.exe", WORKER) // names 11 as parent but started first: an earlier owner of that pid
		];
		var found = [for (info in SuitLineage.exosuitDescendants(snapshot, 10, 100, -1)) info.pid];
		found.sort(Reflect.compare);
		check(found.join(",") == "11,12", 'a stop kills only exosuit-spawned descendants, got $found');
	}

	/** When the snapshot shows the target's pid with another start time, its new owner's children are left alone. */
	static function reusedPidIsNotFollowed():Void {
		var snapshot = [process(20, 1, 900, "hl.exe", "hl.exe other.hl"), process(21, 20, 950, "hl.exe", WORKER)];
		check(SuitLineage.exosuitDescendants(snapshot, 20, 100, -1).length == 0, "a reused pid's children are not followed");
		var gone = [process(21, 20, 950, "hl.exe", WORKER)];
		check(SuitLineage.exosuitDescendants(gone, 20, 100, -1).length == 1, "an exited target's exosuit children are still swept");
	}

	static function adoptionNeedsExosuitChainAndEnvironment():Void {
		var editor = process(30, 1, 100, "hl.exe", "hl.exe C:/x/graphical/build/host/main.hl");
		var direct = process(31, 30, 110, "hl.exe", WORKER, ON);
		var shell = process(32, 30, 120, "cmd.exe", "cmd.exe");
		var underShell = process(33, 32, 130, "hl.exe", WORKER, ON);
		var userProgram = process(34, 30, 140, "node.exe", "node server.js", ON);
		var all = [editor, direct, shell, underShell, userProgram];
		var byPid = new Map<Int, ProcessInfo>();
		for (info in all)
			byPid.set(info.pid, info);
		var owned = [30 => true];
		check(SuitLineage.adoptionOwner(direct, byPid, owned, null) == 30, "a worker the editor started is adopted");
		check(SuitLineage.adoptionOwner(underShell, byPid, owned, null) == null, "a worker started from a terminal is not adopted");
		check(SuitLineage.adoptionOwner(userProgram, byPid, owned, null) == null, "a program of another kind is never adopted");
		var off = process(31, 30, 110, "hl.exe", WORKER, "EXOSUIT_SUIT=off\nPATH=C:/bin");
		check(SuitLineage.adoptionOwner(off, byPid, owned, null) == null, "EXOSUIT_SUIT=off is never adopted");
		var unread = process(31, 30, 110, "hl.exe", WORKER, "");
		check(SuitLineage.adoptionOwner(unread, byPid, owned, null) == null, "an unreadable environment is not adopted");
		var isolated = process(31, 30, 110, "hl.exe", WORKER, "EXOSUIT_SUIT=isolated\nEXOSUIT_SUIT_HOME=C:/tmp/home\nPATH=C:/bin");
		check(SuitLineage.adoptionOwner(isolated, byPid, owned, "C:/tmp/home") == 30, "an isolated process is adopted by its own suit");
		check(SuitLineage.adoptionOwner(isolated, byPid, owned, null) == null, "the user's suit never adopts an isolated process");
		check(SuitLineage.adoptionOwner(direct, byPid, owned, "C:/tmp/home") == null, "an isolated suit never adopts the user's processes");
	}

	static function registryTimes():Void {
		// A version 1 record holds Date.now(): whole seconds, so up to a second before a start in that second.
		check(SuitClock.registeredAfterStart(1700000000500.25, 1700000000000.0, 1), "an old whole-second record from the start's second is kept");
		check(!SuitClock.registeredAfterStart(1700000001500.0, 1700000000000.0, 1), "an old record from an earlier second is stale");
		check(!SuitClock.registeredAfterStart(1700000000500.0, 1700000000000.0, 2), "a current record must be no earlier than the start");
		check(SuitClock.registeredAfterStart(1700000000500.0, 1700000000500.4, 2), "a record written right after the start is kept");
		check(!SuitClock.registeredAfterStart(0, 1700000000000.0, 2), "an unknown start time never validates");
		var now = SuitClock.now();
		check(Math.abs(now - Date.now().getTime()) < 2000, "the registry clock is the wall clock");
	}

	static function temporaryStateIsDisposable():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp == null)
			return;
		check(SuitClient.underTemp(temp + "/suit-test-1/settings"), "state under the temp folder is disposable");
		check(!SuitClient.underTemp(temp + "-elsewhere/settings"), "a sibling of the temp folder is not");
		check(!SuitClient.underTemp(Sys.systemName() == "Windows" ? "C:/Users/someone/AppData/Local/exosuit" : "/home/someone/.local/state"),
			"a user's own state is not disposable");
	}

	static function check(condition:Bool, message:String):Void {
		if (condition)
			return;
		failures++;
		Sys.println("FAIL: " + message);
	}
}
