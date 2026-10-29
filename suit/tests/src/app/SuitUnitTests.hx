package app;

import processkit.Processes;
import suit.SuitClient;
import suit.SuitClient.SuitMode;
import suit.SuitClock;
import suit.SuitInventory;
import suit.SuitLineage;
import suit.SuitPaths;
import suit.MachineCatalog;

/**
	suit's ownership rules over made-up processes: which descendants a stop may kill, what suit adopts,
	how a reused pid is caught, how registry times are checked, and the mode rule. Nothing here lists or
	touches a real process. scripts/test-suit.py runs this before its end-to-end tests.
**/
class SuitUnitTests {
	static inline var WORKER:String = "hl.exe C:/Users/u/AppData/Local/haxeon/compiler/abc.hl C:/Users/u/AppData/Local/haxeon/compiler/abc.json";
	static inline var DAEMON:String = "hl.exe C:/x/agent/build/host/main.hl \\\\.\\pipe\\p 1 C:/s/credential seed C:/s/db C:/root g1";
	static inline var HOME:String = "C:/Users/u/AppData/Local/suit-unit-home";
	static inline var OWN:String = "EXOSUIT_SUIT=isolated\nEXOSUIT_SUIT_HOME=C:/Users/u/AppData/Local/suit-unit-home\nPATH=C:/bin";

	static var failures:Int = 0;

	static function main():Void {
		descendantsFollowOnlyExosuitKinds();
		reusedPidKeepsTheOldTargetsChildren();
		sweepRespectsEnvironment();
		adoptionNeedsExosuitChainAndEnvironment();
		homesCompareResolved();
		modeRule();
		registryTimes();
		deniedProcessKeepsItsRecord();
		temporaryStateIsDisposable();
		machineCatalog();
		if (failures > 0) {
			Sys.println('FAIL: $failures suit unit check(s)');
			Sys.exit(1);
		}
		Sys.println("PASS: suit unit tests");
	}

	static function process(pid:Int, parent:Int, started:Float, name:String, commandLine:String, environment:String = ""):ProcessInfo
		return {pid: pid, parent: parent, started: started, name: name, commandLine: commandLine, environment: environment};

	static function pids(list:Array<ProcessInfo>):String {
		var result = [for (info in list) info.pid];
		result.sort(Reflect.compare);
		return result.join(",");
	}

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
		var found = pids(new SuitLineage(snapshot, HOME).exosuitDescendants(10, 100, -1));
		check(found == "11,12", 'a stop kills only exosuit-spawned descendants, got $found');
	}

	/**
		After the target exits its pid can be reused. Children that started between the target's start and
		the new process's are still the target's; the new process's own children are not.
	**/
	static function reusedPidKeepsTheOldTargetsChildren():Void {
		var snapshot = [
			process(20, 1, 900, "hl.exe", "hl.exe other.hl"), // the pid's new owner
			process(21, 20, 500, "hl.exe", WORKER), // started by the old target (start 100)
			process(22, 20, 950, "hl.exe", WORKER) // started by the new owner
		];
		var lineage = new SuitLineage(snapshot, HOME);
		check(pids(lineage.exosuitDescendants(20, 100, -1)) == "21", "a reused pid keeps the old target's children only");
		check(lineage.exosuitDescendants(20, 1000, -1).length == 0, "a snapshot older than the target follows nothing");
		var gone = new SuitLineage([process(21, 20, 950, "hl.exe", WORKER)], HOME);
		check(gone.exosuitDescendants(20, 100, -1).length == 1, "an exited target's exosuit children are still swept");
	}

	/** The sweep never kills a process whose environment belongs elsewhere; an unreadable one is still swept. */
	static function sweepRespectsEnvironment():Void {
		var snapshot = [
			process(30, 1, 100, "hl.exe", DAEMON, OWN),
			process(31, 30, 110, "hl.exe", WORKER, "EXOSUIT_SUIT=off\nPATH=C:/bin"),
			process(32, 30, 120, "hl.exe", WORKER, "EXOSUIT_SUIT=isolated\nEXOSUIT_SUIT_HOME=C:/elsewhere\nPATH=C:/bin"),
			process(33, 30, 130, "hl.exe", WORKER, OWN),
			process(34, 30, 140, "hl.exe", WORKER, "")
		];
		var found = pids(new SuitLineage(snapshot, HOME).exosuitDescendants(30, 100, -1));
		check(found == "33,34", 'the sweep skips EXOSUIT_SUIT=off and another suit\'s processes, got $found');
	}

	static function adoptionNeedsExosuitChainAndEnvironment():Void {
		var editor = process(30, 1, 100, "hl.exe", "hl.exe C:/x/graphical/build/host/main.hl");
		var shell = process(32, 30, 120, "cmd.exe", "cmd.exe");
		var base = [editor, shell, process(33, 32, 130, "hl.exe", WORKER, OWN), process(34, 30, 140, "node.exe", "node server.js", OWN)];
		var owned = [30 => true];
		function owner(environment:String, home:String):Null<Int> {
			var candidate = process(31, 30, 110, "hl.exe", WORKER, environment);
			return new SuitLineage(base.concat([candidate]), home).adoptionOwner(candidate, owned);
		}
		check(owner(OWN, HOME) == 30, "a worker the editor started is adopted");
		var lineage = new SuitLineage(base, HOME);
		check(lineage.adoptionOwner(base[2], owned) == null, "a worker started from a terminal is not adopted");
		check(lineage.adoptionOwner(base[3], owned) == null, "a program of another kind is never adopted");
		check(owner("EXOSUIT_SUIT=off\nPATH=C:/bin", HOME) == null, "EXOSUIT_SUIT=off is never adopted");
		check(owner("", HOME) == null, "an unreadable environment is not adopted");
		check(owner(OWN, "C:/elsewhere") == null, "another suit never adopts this suit's processes");
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp != null)
			check(owner('PRAGTICAL_PORTABLE=$temp/run-1\nPATH=C:/bin', SuitPaths.defaultHome()) == null,
				"unset EXOSUIT_SUIT with temporary state is off, on every platform");
	}

	/** An explicit default home and an unset one are the same suit. */
	static function homesCompareResolved():Void {
		var defaultHome = SuitPaths.defaultHome();
		var explicit = process(40, 1, 100, "hl.exe", WORKER, 'EXOSUIT_SUIT=on\nEXOSUIT_SUIT_HOME=$defaultHome\nPATH=C:/bin');
		var unset = process(41, 1, 100, "hl.exe", WORKER, "EXOSUIT_SUIT=on\nPATH=C:/bin");
		check(SuitLineage.registersWith(explicit, null, defaultHome), "an explicit default home registers with the default suit");
		check(SuitLineage.registersWith(unset, null, defaultHome), "an unset home registers with the default suit");
		check(!SuitLineage.registersWith(unset, null, HOME), "an unset home does not register with an isolated suit");
		check(SuitLineage.registersWith(explicit, null, StringTools.replace(defaultHome, "\\", "/") + "/"),
			"homes compare as paths, not strings");
	}

	static function modeRule():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp == null)
			return;
		var mine = Sys.systemName() == "Windows" ? "C:/Users/someone/AppData/Local/exosuit" : "/home/someone/.local/state";
		check(SuitClient.modeOf(null, null, [temp + "/suit-test/settings"]) == SuitMode.Off, "unset with temporary state is off");
		check(SuitClient.modeOf("on", null, [temp + "/suit-test/settings"]) == SuitMode.On, "an explicit on wins over temporary state");
		check(SuitClient.modeOf(null, null, [mine, null]) == SuitMode.On, "unset with the user's own state is on");
		check(SuitClient.modeOf("isolated", null, []) == SuitMode.Off, "isolated without a home is off");
		var before = Sys.getEnv("EXOSUIT_SUIT");
		SuitClient.mode(temp + "/suit-test/state");
		check(Sys.getEnv("EXOSUIT_SUIT") == before, "mode() is a query: it does not change EXOSUIT_SUIT");
		// Last use of the environment in this test: an explicit on registers even with temporary state, in a
		// home whose parent folders do not exist yet.
		Sys.putEnv("EXOSUIT_SUIT", "on");
		Sys.putEnv("EXOSUIT_SUIT_HOME", temp + "/suit-unit-" + Std.random(1000000) + "/a/b/home");
		Sys.putEnv("EXOSUIT_SUIT_AUTOSTART", "0");
		check(SuitClient.resolve(temp + "/suit-test/state") == SuitMode.On, "resolve() keeps an explicit on");
		SuitClient.registerWorkspaceService(suit.SuitKind.WorkspaceManager, {root: temp, stateDir: temp + "/suit-test/state", generation: "g"});
		check(sys.FileSystem.exists(suit.SuitRecord.SuitRecords.path(SuitPaths.registry(), Sys.getPid())),
			"an explicit on registers, creating the home's missing parent folders");
		SuitClient.unregister();
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

	/** A running process this user may not open (start time unknown) keeps its record; a gone one does not. */
	static function deniedProcessKeepsItsRecord():Void {
		check(SuitInventory.keepsRecord(process(50, 1, 0, "hl.exe", ""), 1700000000000.0, 2), "a denied process keeps its record");
		check(!SuitInventory.keepsRecord(null, 1700000000000.0, 2), "a process that is gone loses its record");
		check(!SuitInventory.keepsRecord(process(50, 1, 1700000005000.0, "hl.exe", ""), 1700000000000.0, 2),
			"a record older than its process is stale");
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

	/** The machine's workspaces: first-start import, edits, persistence, and the rules each edit keeps. */
	static function machineCatalog():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		var base = haxe.io.Path.join([temp, "suit-machine-" + Std.random(1000000000)]);
		var one = haxe.io.Path.join([base, "one"]), two = haxe.io.Path.join([base, "two"]), gone = haxe.io.Path.join([base, "gone"]);
		sys.FileSystem.createDirectory(one);
		sys.FileSystem.createDirectory(two);
		var file = haxe.io.Path.join([base, "home", "machine.json"]);
		try {
			var catalog = new MachineCatalog(file, [one, one, gone]);
			check(catalog.state.workspaces.length == 1 && catalog.state.workspaces[0].name == "one",
				"a new machine imports each existing folder once, named after it, and skips folders that are gone");
			check(catalog.state.name.length > 0 && StringTools.startsWith(catalog.state.id, "machine-"), "a new machine has a name and an id");
			var created = catalog.create(null, two);
			check(created.name == "two" && created.folders.length == 1, "a workspace defaults to its folder's name");
			check(fails(function() catalog.create("x", gone)), "a workspace's folder must exist");
			check(fails(function() catalog.create("x", "relative/folder")), "a workspace's folder must be absolute");
			var both = catalog.addFolder(created.id, one);
			check(both.folders.length == 2, "a folder is added");
			check(fails(function() catalog.addFolder(created.id, one + "/")), "a folder is added once, however it is spelled");
			catalog.removeFolder(created.id, one);
			check(fails(function() catalog.removeFolder(created.id, two)), "a workspace keeps its last folder");
			check(catalog.rename(created.id, "  Renamed  ").name == "Renamed", "names are trimmed");
			check(fails(function() catalog.rename(created.id, " ")), "a workspace needs a name");
			check(fails(function() catalog.rename("workspace-missing", "x")), "an unknown workspace is an error");
			var reloaded = new MachineCatalog(file, [two]);
			check(reloaded.state.id == catalog.state.id && reloaded.state.workspaces.length == 2
				&& reloaded.state.workspaces[1].name == "Renamed", "the catalog persists, and an existing one imports nothing");
			reloaded.delete(created.id);
			check(new MachineCatalog(file).state.workspaces.length == 1, "a deleted workspace is gone after reload");
			sys.io.File.saveContent(file, "{\"version\":1,\"id\":\"m\",\"name\":\"x\",\"workspaces\":[{\"id\":\"w\",\"name\":\"n\",\"folders\":[]}]}");
			check(fails(function() new MachineCatalog(file)), "a damaged catalog is an error, not replaced");
		} catch (error:Dynamic) {
			check(false, "machine catalog: " + Std.string(error));
		}
		for (path in [file, haxe.io.Path.join([base, "home"]), one, two, base])
			try (sys.FileSystem.isDirectory(path) ? sys.FileSystem.deleteDirectory(path) : sys.FileSystem.deleteFile(path)) catch (_:Dynamic) {}
	}

	static function fails(action:Void->Void):Bool {
		try action() catch (_:Dynamic) return true;
		return false;
	}

	static function check(condition:Bool, message:String):Void {
		if (condition)
			return;
		failures++;
		Sys.println("FAIL: " + message);
	}
}
