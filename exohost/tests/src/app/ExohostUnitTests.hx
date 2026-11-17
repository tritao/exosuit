package app;

import processkit.Processes;
import exohost.ExohostClient;
import exohost.ExohostClock;
import exohost.ExohostInventory;
import exohost.ExohostInventory.ExohostProcess;
import exohost.ExohostGroup;
import exohost.ExohostKind;
import exohost.ExohostLineage;
import exohost.ExohostPaths;
import exohost.ExohostProcessTree;
import exohost.MachineCatalog;

/**
	exohost's ownership rules over made-up processes: which descendants a stop may kill, what exohost adopts,
	how a reused pid is caught, how registry times are checked, and where a registration goes. Nothing here lists or
	touches a real process. scripts/test-exohost.py runs this before its end-to-end tests.
**/
class ExohostUnitTests {
	static inline var WORKER:String = "hl.exe C:/Users/u/AppData/Local/haxeon/compiler/abc.hl C:/Users/u/AppData/Local/haxeon/compiler/abc.json";
	static inline var DAEMON:String = "hl.exe C:/x/agent/build/host/main.hl --workspace w1 --folder C:/root";
	static inline var HOME:String = "C:/Users/u/AppData/Local/exohost-unit-home";
	static inline var OWN:String = "EXOSUIT_EXOHOST_HOME=C:/Users/u/AppData/Local/exohost-unit-home\nPATH=C:/bin";

	static var failures:Int = 0;

	static function main():Void {
		descendantsFollowOnlyExosuitKinds();
		wholeTreeStopsAtHostsAndEditors();
		reusedPidKeepsTheOldTargetsChildren();
		sweepRespectsEnvironment();
		adoptionNeedsExosuitChainAndEnvironment();
		homesCompareResolved();
		registrationCreatesHome();
		registryTimes();
		deniedProcessKeepsItsRecord();
		temporaryStateIsDisposable();
		machineCatalog();
		windowFocus();
		terminalHosts();
		haxeonClients();
		failures += MachineRemoteUnitTests.run();
		if (failures > 0) {
			Sys.println('FAIL: $failures exohost unit check(s)');
			Sys.exit(1);
		}
		Sys.println("PASS: exohost unit tests");
	}

	static function process(pid:Int, parent:Int, started:Float, name:String, commandLine:String, environment:String = ""):ProcessInfo
		return {pid: pid, parent: parent, started: started, name: name, commandLine: commandLine, environment: environment};

	static function pids(list:Array<ProcessInfo>):String {
		var result = [for (info in list) info.pid];
		result.sort(Reflect.compare);
		return result.join(",");
	}

	/** A service's compiler worker dies with it; a terminal shell and what it started do not. */
	static function descendantsFollowOnlyExosuitKinds():Void {
		var snapshot = [
			process(11, 1, 110, "hl.exe", DAEMON),
			process(12, 11, 120, "hl.exe", WORKER),
			process(13, 11, 130, "pwsh.exe", "pwsh.exe -NoLogo"),
			process(14, 13, 140, "hl.exe", WORKER), // a build the user ran in an exosuit terminal
			process(15, 13, 150, "code.exe", "code.exe ."), // a program the user started from it
			process(16, 11, 90, "hl.exe", WORKER) // names 11 as parent but started first: an earlier owner of that pid
		];
		var found = pids(new ExohostLineage(snapshot, HOME).exosuitDescendants(11, 110, -1));
		check(found == "12", 'a stop kills only exosuit-spawned descendants, got $found');
	}

	/**
		An agent provider's whole tree ends with it, deepest first: an MCP server through `cmd /C`, and what that started.
		A terminal host below a service is not part of the service's tree, nor is anything under it; an editor started below
		is spared with the processes it runs under, and a reused pid never links.
	**/
	static function wholeTreeStopsAtHostsAndEditors():Void {
		var provider = "claude.exe -p --output-format stream-json --input-format stream-json --permission-prompt-tool stdio";
		var snapshot = [
			process(10, 1, 100, "hl.exe", DAEMON),
			process(11, 10, 110, "claude.exe", provider),
			process(12, 11, 120, "cmd.exe", "cmd.exe /C npx mcp-server"),
			process(13, 12, 130, "node.exe", "node.exe mcp-server.js"),
			process(14, 13, 140, "dev.exe", ""),
			process(15, 11, 90, "hl.exe", WORKER), // names 11 as parent but started first: an earlier owner of that pid
			process(20, 10, 200, "hl.exe", "hl.exe C:/s/terminal-hosts/runtime/main.hl --terminal-host C:/s/terminal-hosts/t1"),
			process(21, 20, 210, "pwsh.exe", ""), // the terminal's shell
			process(30, 11, 300, "python.exe", "python.exe scripts/run.py"), // an editor the agent started, through run.py
			process(31, 30, 310, "hl.exe", "hl.exe C:/x/graphical/build/host/main.hl"),
			process(32, 30, 320, "node.exe", "node.exe watcher.js"), // run.py's other child: no editor below it
			process(40, 11, 400, "python.exe", "python.exe live.py"),
			process(41, 40, 410, "hl.exe", "hl.exe C:/x/graphical/build/host/live.hl") // registered editor, read as a live host
		];
		var tree = new ExohostProcessTree(snapshot, info -> info.pid == 41);
		var provided = tree.descendants(11, 110, -1);
		check(pids(provided) == "12,13,14,32", 'a provider ends with its tree but not an editor or what it runs under, got ${pids(provided)}');
		check(provided.indexOf(snapshot[3]) < provided.indexOf(snapshot[2]) && provided.indexOf(snapshot[4]) < provided.indexOf(snapshot[3]),
			"the tree is listed deepest first");
		var served = pids(tree.descendants(10, 100, -1));
		// The provider runs editors here, so it is spared too: the editors keep what they run under.
		check(served == "12,13,14,32", 'a service ends with its tree but never with a terminal host or its shell, got $served');
		check(pids(tree.descendants(20, 200, -1)) == "21", "a terminal host killed by force takes its shell with it");
		check(tree.descendants(11, 110, 13).length == 2, "the caller and what is below it are never part of the tree");
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
		var lineage = new ExohostLineage(snapshot, HOME);
		check(pids(lineage.exosuitDescendants(20, 100, -1)) == "21", "a reused pid keeps the old target's children only");
		check(lineage.exosuitDescendants(20, 1000, -1).length == 0, "a snapshot older than the target follows nothing");
		var gone = new ExohostLineage([process(21, 20, 950, "hl.exe", WORKER)], HOME);
		check(gone.exosuitDescendants(20, 100, -1).length == 1, "an exited target's exosuit children are still swept");
	}

	/** The sweep never kills a process whose environment belongs elsewhere; an unreadable one is still swept. */
	static function sweepRespectsEnvironment():Void {
		var snapshot = [
			process(30, 1, 100, "hl.exe", DAEMON, OWN),
			process(32, 30, 120, "hl.exe", WORKER, "EXOSUIT_EXOHOST_HOME=C:/elsewhere\nPATH=C:/bin"),
			process(33, 30, 130, "hl.exe", WORKER, OWN),
			process(34, 30, 140, "hl.exe", WORKER, "")
		];
		var found = pids(new ExohostLineage(snapshot, HOME).exosuitDescendants(30, 100, -1));
		check(found == "33,34", 'the sweep skips another exohost\'s processes, got $found');
	}

	static function adoptionNeedsExosuitChainAndEnvironment():Void {
		var editor = process(30, 1, 100, "hl.exe", "hl.exe C:/x/graphical/build/host/main.hl");
		var shell = process(32, 30, 120, "cmd.exe", "cmd.exe");
		var base = [editor, shell, process(33, 32, 130, "hl.exe", WORKER, OWN), process(34, 30, 140, "node.exe", "node server.js", OWN)];
		var owned = [30 => true];
		function owner(environment:String, home:String):Null<Int> {
			var candidate = process(31, 30, 110, "hl.exe", WORKER, environment);
			return new ExohostLineage(base.concat([candidate]), home).adoptionOwner(candidate, owned);
		}
		check(owner(OWN, HOME) == 30, "a worker the editor started is adopted");
		var lineage = new ExohostLineage(base, HOME);
		check(lineage.adoptionOwner(base[2], owned) == null, "a worker started from a terminal is not adopted");
		check(lineage.adoptionOwner(base[3], owned) == null, "a program of another kind is never adopted");
		check(owner("", HOME) == null, "an unreadable environment is not adopted");
		check(owner(OWN, "C:/elsewhere") == null, "another exohost never adopts this exohost's processes");
	}

	/** An explicit default home and an unset one are the same exohost. */
	static function homesCompareResolved():Void {
		var defaultHome = ExohostPaths.defaultHome();
		var explicit = process(40, 1, 100, "hl.exe", WORKER, 'EXOSUIT_EXOHOST_HOME=$defaultHome\nPATH=C:/bin');
		var unset = process(41, 1, 100, "hl.exe", WORKER, "PATH=C:/bin");
		check(ExohostLineage.registersWith(explicit, defaultHome), "an explicit default home registers with the default exohost");
		check(ExohostLineage.registersWith(unset, defaultHome), "an unset home registers with the default exohost");
		check(!ExohostLineage.registersWith(unset, HOME), "an unset home does not register with an isolated exohost");
		check(ExohostLineage.registersWith(explicit, StringTools.replace(defaultHome, "\\", "/") + "/"),
			"homes compare as paths, not strings");
	}

	/** A registration goes to EXOSUIT_EXOHOST_HOME, even under the temp folder, creating its missing parent folders. */
	static function registrationCreatesHome():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp == null)
			return;
		// Last use of the environment in this test.
		Sys.putEnv("EXOSUIT_EXOHOST_HOME", temp + "/exohost-unit-" + Std.random(1000000) + "/a/b/home");
		Sys.putEnv("EXOSUIT_EXOHOST_AUTOSTART", "0");
		ExohostClient.registerWorkspaceService(WorkspaceHost, {root: temp, stateDir: temp + "/exohost-test/state", generation: "g", workspace: null});
		check(sys.FileSystem.exists(exohost.ExohostRecord.ExohostRecords.path(ExohostPaths.registry(), Sys.getPid())),
			"a registration creates the home's missing parent folders");
		ExohostClient.unregister();
	}

	static function registryTimes():Void {
		// A version 1 record holds Date.now(): whole seconds, so up to a second before a start in that second.
		check(ExohostClock.registeredAfterStart(1700000000500.25, 1700000000000.0, 1), "an old whole-second record from the start's second is kept");
		check(!ExohostClock.registeredAfterStart(1700000001500.0, 1700000000000.0, 1), "an old record from an earlier second is stale");
		check(!ExohostClock.registeredAfterStart(1700000000500.0, 1700000000000.0, 2), "a current record must be no earlier than the start");
		check(ExohostClock.registeredAfterStart(1700000000500.0, 1700000000500.4, 2), "a record written right after the start is kept");
		check(!ExohostClock.registeredAfterStart(0, 1700000000000.0, 2), "an unknown start time never validates");
		var now = ExohostClock.now();
		check(Math.abs(now - Date.now().getTime()) < 2000, "the registry clock is the wall clock");
	}

	/** A running process this user may not open (start time unknown) keeps its record; a gone one does not. */
	static function deniedProcessKeepsItsRecord():Void {
		check(ExohostInventory.keepsRecord(process(50, 1, 0, "hl.exe", ""), 1700000000000.0, 2), "a denied process keeps its record");
		check(!ExohostInventory.keepsRecord(null, 1700000000000.0, 2), "a process that is gone loses its record");
		check(!ExohostInventory.keepsRecord(process(50, 1, 1700000005000.0, "hl.exe", ""), 1700000000000.0, 2),
			"a record older than its process is stale");
	}

	static function temporaryStateIsDisposable():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp == null)
			return;
		check(ExohostClient.underTemp(temp + "/exohost-test-1/settings"), "state under the temp folder is disposable");
		check(!ExohostClient.underTemp(temp + "-elsewhere/settings"), "a sibling of the temp folder is not");
		check(!ExohostClient.underTemp(Sys.systemName() == "Windows" ? "C:/Users/someone/AppData/Local/exosuit" : "/home/someone/.local/state"),
			"a user's own state is not disposable");
	}

	/** The machine's workspaces: first-start import, edits, persistence, and the rules each edit keeps. */
	static function machineCatalog():Void {
		var temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		var base = haxe.io.Path.join([temp, "exohost-machine-" + Sys.getPid() + "-" + Std.int(Sys.time())]);
		var one = haxe.io.Path.join([base, "one"]), two = haxe.io.Path.join([base, "two"]), gone = haxe.io.Path.join([base, "gone"]);
		sys.FileSystem.createDirectory(base);
		sys.FileSystem.createDirectory(one);
		sys.FileSystem.createDirectory(two);
		var file = haxe.io.Path.join([base, "home", "machine.json"]);
		// Scratch folders go under the test's folder, never the user's home.
		var scratchHome = haxe.io.Path.join([base, "scratch"]);
		var previousScratchHome = Sys.getEnv("EXOSUIT_SCRATCH_HOME");
		Sys.putEnv("EXOSUIT_SCRATCH_HOME", scratchHome);
		try {
			var catalog = new MachineCatalog(file, [one, one, gone]);
			check(catalog.state.workspaces.length == 1 && catalog.state.workspaces[0].name == "one",
				"a new machine imports each existing folder once, named after it, and skips folders that are gone");
			check(catalog.state.name.length > 0 && StringTools.startsWith(catalog.state.id, "machine-"), "a new machine has a name and an id");
			var created = catalog.create(null, [two]);
			check(created.name == "two" && created.folders.length == 1 && created.scratch == null, "a workspace defaults to its folder's name");
			var replied = MachineCatalog.decodeWorkspace(haxe.Json.parse(haxe.Json.stringify({ok: true, workspace: created})).workspace);
			check(replied.id == created.id && replied.folders[0] == created.folders[0], "a reply's workspace decodes into a record");
			var bare = MachineCatalog.decodeWorkspace(haxe.Json.parse('{"id":"x","name":"x","folders":[]}'));
			check(bare.folders.length == 0 && bare.scratch == null, "a workspace may have no folders, and no scratch folder yet");
			check(fails(function() MachineCatalog.decodeWorkspace(haxe.Json.parse('{"id":"x","name":"x","folders":[],"scratch":3}'))),
				"a scratch folder is a path");
			check(fails(function() catalog.create("x", [gone])), "a workspace's folder must exist");
			check(fails(function() catalog.create("x", ["relative/folder"])), "a workspace's folder must be absolute");
			check(fails(function() catalog.create(" ", [])), "a workspace without folders needs a name");
			var both = catalog.addFolder(created.id, one);
			check(both.folders.length == 2, "a folder is added");
			check(fails(function() catalog.addFolder(created.id, one + "/")), "a folder is added once, however it is spelled");
			catalog.removeFolder(created.id, one);
			check(catalog.removeFolder(created.id, two).folders.length == 0, "a workspace's last folder can be removed");
			check(catalog.rename(created.id, "  Renamed  ").name == "Renamed", "names are trimmed");
			check(fails(function() catalog.rename(created.id, " ")), "a workspace needs a name");
			check(fails(function() catalog.rename("workspace-missing", "x")), "an unknown workspace is an error");

			// Scratch folders: named after the workspace, made valid, suffixed when taken, and recorded.
			check(MachineCatalog.scratchName(" a<b>c:d\"e/f\\g|h?i*j. . ") == "abcdefghij" && MachineCatalog.scratchName("?. ") == "Workspace"
				&& MachineCatalog.scratchName("con.txt") == "Workspace", "a scratch folder's name is valid on Windows");
			var notes = catalog.create("My: Notes.", []);
			check(notes.folders.length == 0 && notes.scratch == null, "a workspace is created with a name only");
			sys.FileSystem.createDirectory(scratchHome);
			sys.FileSystem.createDirectory(haxe.io.Path.join([scratchHome, "My Notes"]));
			var scratch = catalog.scratch(notes.id);
			check(haxe.io.Path.withoutDirectory(StringTools.replace(scratch, "\\", "/")) == "My Notes 2" && sys.FileSystem.isDirectory(scratch),
				'a scratch folder whose name is taken gets a suffix, got $scratch');
			check(catalog.scratch(notes.id) == scratch, "a workspace keeps its scratch folder");
			catalog.rename(notes.id, "Journal");
			check(catalog.scratch(notes.id) == scratch, "renaming a workspace does not move its scratch folder");
			var same = catalog.create("My Notes", []);
			var third = catalog.scratch(same.id);
			check(haxe.io.Path.withoutDirectory(StringTools.replace(third, "\\", "/")) == "My Notes 3", 'another workspace\'s scratch folder is skipped, got $third');
			sys.FileSystem.deleteDirectory(scratch);
			check(catalog.scratch(notes.id) == scratch && sys.FileSystem.isDirectory(scratch), "a deleted scratch folder is made again where it was");

			var reloaded = new MachineCatalog(file, [two]);
			check(reloaded.state.id == catalog.state.id && reloaded.state.workspaces.length == 4
				&& reloaded.state.workspaces[1].name == "Renamed" && reloaded.state.workspaces[1].folders.length == 0,
				"the catalog persists, folderless workspaces too, and an existing one imports nothing");
			check(reloaded.state.workspaces[2].scratch == scratch && reloaded.scratch(notes.id) == scratch, "a scratch folder persists");
			check(haxe.Json.parse(sys.io.File.getContent(file)).version == 2, "machine.json is written as version 2");
			reloaded.delete(created.id);
			check(new MachineCatalog(file).state.workspaces.length == 3, "a deleted workspace is gone after reload");

			var twoInJson = StringTools.replace(MachineCatalog.folderPath(two), "\\", "\\\\");
			sys.io.File.saveContent(file, '{"version":1,"id":"m","name":"x","workspaces":[{"id":"w","name":"n","folders":["$twoInJson"]}]}');
			var old = new MachineCatalog(file);
			check(old.state.id == "m" && old.state.workspaces.length == 1 && old.state.workspaces[0].folders.length == 1
				&& old.state.workspaces[0].scratch == null, "a version 1 catalog is read unchanged");
			old.rename("w", "n2");
			var written:Dynamic = haxe.Json.parse(sys.io.File.getContent(file));
			check(written.version == 2 && new MachineCatalog(file).state.workspaces[0].name == "n2", "a version 1 catalog is written back as version 2");
			machineReply(file, twoInJson);
	
			sys.io.File.saveContent(file, "{\"version\":1,\"id\":\"m\",\"name\":\"x\",\"workspaces\":[{\"id\":\"w\",\"name\":\"n\",\"folders\":\"x\"}]}");
			check(fails(function() new MachineCatalog(file)), "a damaged catalog is an error, not replaced");
			sys.io.File.saveContent(file, "{\"version\":3,\"id\":\"m\",\"name\":\"x\",\"workspaces\":[]}");
			check(fails(function() new MachineCatalog(file)), "a newer catalog version is an error");
		} catch (error:Dynamic) {
			check(false, "machine catalog: " + Std.string(error));
		}
		Sys.putEnv("EXOSUIT_SCRATCH_HOME", previousScratchHome == null ? "" : previousScratchHome);
		deleteTree(base);
	}

	/**
		The `machine` reply, version 2 (M19 Phase 0; proposed, pending the mobile-app review): every workspace has
		folders (possibly none), a scratch folder or null, a revision and a service or null.
	**/
	static function machineReply(file:String, twoInJson:String):Void {
		sys.io.File.saveContent(file, '{"version":2,"id":"m","name":"cube","workspaces":[{"id":"w1","name":"Notes","folders":[],'
			+ '"scratch":"/s/Notes","revision":3},{"id":"w2","name":"two","folders":["$twoInJson"],"scratch":null}]}');
		var catalog = new MachineCatalog(file);
		var services = function(entry:MachineWorkspace):Null<MachineService> {
			return entry.id == "w2" ? {endpoint: "pipe-w2", pid: 42, running: true} : null;
		};
		var reply:Dynamic = haxe.Json.parse(haxe.Json.stringify({ok: true, machine: catalog.json(services)})).machine;
		check(keys(reply) == "id,name,version,workspaces" && reply.version == 2 && reply.id == "m" && reply.name == "cube",
			"a machine reply is version 2, got " + keys(reply));
		var workspaces:Array<Dynamic> = reply.workspaces;
		check(workspaces.length == 2 && keys(workspaces[0]) == "folders,id,name,revision,scratch,service" && keys(workspaces[1]) == keys(workspaces[0]),
			"a reply's workspace has folders, id, name, revision, scratch and service, got " + keys(workspaces[0]));
		var notes = workspaces[0], two = workspaces[1];
		check((notes.folders : Array<Dynamic>).length == 0 && notes.scratch == "/s/Notes" && notes.revision == 3 && notes.service == null
			&& MachineCatalog.decodeService(notes) == null, "a folderless workspace's reply has its scratch folder, revision and no service");
		var service = MachineCatalog.decodeService(two);
		check(two.scratch == null && two.revision == 0 && service != null && service.endpoint == "pipe-w2" && service.pid == 42 && service.running,
			"a workspace's service is its endpoint, pid and whether it runs; a revision missing from the file is 0");
		check(fails(function() MachineCatalog.decodeService(haxe.Json.parse('{"service":{"endpoint":"p","pid":"42","running":true}}'))),
			"a malformed service is an error");
		check(MachineCatalog.decodeWorkspace(notes).revision == 3, "a reply's workspace decodes its revision");
		check(catalog.rename("w1", "Journal").revision == 4 && catalog.scratch("w2") != null && catalog.state.workspaces[1].revision == 1,
			"every change to a workspace counts in its revision");
		var unknown:Array<Dynamic> = catalog.json().workspaces;
		check(unknown[0].service == null && unknown[1].service == null, "exohost reports no service until it knows one");
	}

	/**
		Window focus (M19 Phase 8): each linked editor reports its window and context; a `machine` reply and the pushed
		`exosuit.machine.changed` list them in `windows`, next to `machine`. Frozen: the shape, the entry's fields, junk entries.
	**/
	static function windowFocus():Void {
		var reply:Dynamic = haxe.Json.parse(haxe.Json.stringify({ok: true, machine: {}, windows: [{window: "w7-1", pid: 7, context: "m/w1/g1"}]}));
		check(keys(reply) == "machine,ok,windows" && keys((reply.windows : Array<Dynamic>)[0]) == "context,pid,window", "a machine reply lists windows beside machine, got " + keys(reply));
		var windows = exohost.WindowFocus.WindowFocuses.decode(haxe.Json.parse('{"ok":true,"windows":[{"window":"a","pid":1,"context":"m/w1/g1"},{"window":"b","pid":2,"context":"m/w1/"},'
			+ '{"window":"c","pid":0,"context":"m/w2/"},{"window":7,"pid":3,"context":"x"},"junk",{"pid":4,"context":"m/w1/g1"}]}'));
		check(windows.length == 2 && windows[0].window == "a" && windows[1].context == "m/w1/", "malformed window entries are left out, got " + windows.length);
		check(exohost.WindowFocus.WindowFocuses.decode(haxe.Json.parse('{"ok":true,"machine":{}}')).length == 0, "a reply from an exohost without windows has none");
		check(exohost.WindowFocus.WindowFocuses.decode(null).length == 0, "no reply has no windows");
		var all = [{window: "a", pid: 1, context: "m/w1/g1"}, {window: "b", pid: 2, context: "m/w1/"}, {window: "c", pid: 3, context: "m/w2/g9"}];
		check(exohost.WindowFocus.WindowFocuses.elsewhere(all, "a", "w1").length == 1, "a workspace is marked by the other windows on it, not this one");
		check(exohost.WindowFocus.WindowFocuses.elsewhere(all, "a", "w1", "g1").length == 0 && exohost.WindowFocus.WindowFocuses.elsewhere(all, "x", "w1", "g1").length == 1,
			"a group is marked by the windows on that group");
		check(exohost.WindowFocus.WindowFocuses.elsewhere(all, "x", "w1", "").length == 1 && exohost.WindowFocus.WindowFocuses.elsewhere(all, "x", "w3").length == 0,
			"the workspace root is a group with an empty id; another workspace has no marker");
	}

	/** An object's field names, sorted and joined. */
	static function keys(value:Dynamic):String {
		var names = Reflect.fields(value);
		names.sort(Reflect.compare);
		return names.join(",");
	}

	static function deleteTree(path:String):Void {
		try {
			if (sys.FileSystem.isDirectory(path)) {
				for (name in sys.FileSystem.readDirectory(path))
					deleteTree(haxe.io.Path.join([path, name]));
				sys.FileSystem.deleteDirectory(path);
			} else
				sys.FileSystem.deleteFile(path);
		} catch (_:Dynamic) {}
	}

	static function fails(action:Void->Void):Bool {
		try action() catch (_:Dynamic) return true;
		return false;
	}

	/**
		A terminal host is its own kind: recognized before the agent's other forms, never orphaned, kept only by the
		polite quit, not swept with the service that started it, and adopted only on its own folder's word.
	**/
	static function terminalHosts():Void {
		var host = "C:/s/terminal-host/abc/hl.exe C:/s/terminal-host/abc/terminal-host.hl --terminal-host C:/s/workspaces/w1/terminal-hosts/0123";
		var found = exohost.ExohostClassifier.classify("hl.exe", host);
		check(found != null && found.kind == ExohostKind.TerminalHost, "a terminal host's command line is a terminal host");
		check(found != null && found.terminalDir == "C:/s/workspaces/w1/terminal-hosts/0123" && found.stateDir == "C:/s/workspaces/w1",
			"a terminal host names its folder and its workspace's state folder");
		var bundled = exohost.ExohostClassifier.classify("exosuit-agent.exe", "C:/s/terminal-host/abc/exosuit-agent.exe --terminal-host C:/s/workspaces/w1/terminal-hosts/0123");
		check(bundled != null && bundled.kind == ExohostKind.TerminalHost, "a bundle's terminal host is not taken for a workspace service");
		var service = exohost.ExohostClassifier.classify("hl.exe", DAEMON);
		check(service != null && service.kind == ExohostKind.WorkspaceHost && service.workspace == "w1" && service.root == "C:/root",
			"a service's command line is its workspace's service, started in its first folder");
		check(ExohostKinds.orphanRule(ExohostKind.TerminalHost) == Never, "a terminal host is never orphaned");
		check(ExohostKinds.keptByPoliteQuit(ExohostKind.TerminalHost) && !ExohostKinds.keptByPoliteQuit(ExohostKind.WorkspaceHost), "only terminal hosts are kept by the polite quit");
		check(!ExohostKinds.spawnedByExosuit(ExohostKind.TerminalHost), "a terminal host is not stopped as part of a service's tree");
		check(ExohostKinds.stop(ExohostKind.TerminalHost) == Kill && ExohostKinds.parse("terminal-host") == ExohostKind.TerminalHost, "exohost ends a terminal host by killing it");
		// Stopping a service never sweeps the host it started.
		var snapshot = [
			process(11, 1, 110, "hl.exe", DAEMON),
			process(17, 11, 120, "hl.exe", host, OWN)
		];
		var swept = pids(new ExohostLineage(snapshot, HOME).exosuitDescendants(11, 110, -1));
		check(swept == "", 'stopping a service leaves its terminal hosts, got $swept');
		var info = process(17, 11, 120, "hl.exe", host, OWN);
		check(ExohostInventory.ownsTerminalHost(info, 17, HOME), "a host whose folder names its pid, under this exohost, is exosuit's");
		check(!ExohostInventory.ownsTerminalHost(info, 18, HOME), "a host whose folder names another pid is not adopted");
		check(!ExohostInventory.ownsTerminalHost(info, null, HOME), "a host with no host.json is not adopted");
		check(!ExohostInventory.ownsTerminalHost(info, 17, "C:/elsewhere"), "another exohost's host is not adopted");
		check(!ExohostInventory.ownsTerminalHost(process(17, 11, 120, "hl.exe", host, ""), 17, HOME),
			"a host whose environment could not be read is not adopted");
		// What a terminal runs is the user's, even an SDK-mode claude: below a host found by its command line or its pid.
		var claude = "claude.exe --output-format stream-json --permission-prompt-tool stdio";
		var terminal = [
			process(17, 11, 120, "hl.exe", host, OWN),
			process(18, 17, 130, "claude.exe", claude, OWN),
			process(19, 18, 140, "node.exe", "node.exe x.js", OWN),
			process(20, 5, 100, "python.exe", "python.exe stand-in-host.py", OWN),
			process(21, 20, 110, "claude.exe", claude, OWN),
			process(22, 11, 150, "claude.exe", claude, OWN) // the daemon's own provider
		];
		var lineage = new ExohostLineage(terminal.concat([process(11, 10, 110, "hl.exe", DAEMON, OWN)]), HOME);
		check(lineage.belowTerminalHost(terminal[1], new Map()) && lineage.belowTerminalHost(terminal[2], new Map()),
			"a terminal's program and what it runs are below its host");
		check(lineage.belowTerminalHost(terminal[4], [20 => true]), "a host exohost knows by pid hides its program too");
		check(!lineage.belowTerminalHost(terminal[5], [20 => true]), "a daemon's own provider is not below a terminal host");
		check(exohost.ExohostReport.keptTerminals(0) == "" && exohost.ExohostReport.keptTerminals(2).indexOf("2 terminals keep running") == 0, "the polite quit says how many terminals stay");
	}

	/** A Haxeon client and the worker it starts run on one toolchain: the hl.exe folder, compared as paths are. */
	static function haxeonClients():Void {
		var cli = "\"C:/w/Haxeon/.tools/hashlink/hl.exe\" C:/w/haxeon/out/haxeon-cli.hl build --project C:/w/agent/haxeon.json";
		var worker = "\"C:\\w\\haxeon\\.tools\\hashlink\\hl.exe\" C:/Users/u/AppData/Local/haxeon/compiler/abc.hl C:/Users/u/AppData/Local/haxeon/compiler/k.json";
		var split = exohost.ExohostClassifier.split;
		check(exohost.ExohostClassifier.isHaxeonClient("hl.exe", split(cli)), "a haxeon-cli build is a Haxeon client");
		check(!exohost.ExohostClassifier.isHaxeonClient("hl.exe", split(worker)), "a compiler worker is not a client");
		check(!exohost.ExohostClassifier.isHaxeonClient("python.exe", split("python.exe scripts/haxeon_cli.py build")), "only HashLink running haxeon-cli.hl is a client");
		var toolchain = exohost.ExohostClassifier.toolchainOf(split(cli));
		check(toolchain != null && toolchain == exohost.ExohostClassifier.toolchainOf(split(worker)), "a client and its worker share a toolchain");
		check(toolchain != exohost.ExohostClassifier.toolchainOf(split("C:/other/haxeon/.tools/hashlink/hl.exe x.hl")), "another checkout's hl.exe is another toolchain");
		check(exohost.ExohostClassifier.toolchainOf(split("hl.exe x.hl")) == null && exohost.ExohostClassifier.toolchainOf([]) == null, "a bare program name names no toolchain");
		check(exohost.ExohostClassifier.toolchainOf(split("out/hl.exe x.hl")) == null, "a relative program path names no toolchain");
	}

	static function check(condition:Bool, message:String):Void {
		if (condition)
			return;
		failures++;
		Sys.println("FAIL: " + message);
	}
}
