package suit;

import haxe.Json;
import haxe.io.Path;
import processkit.Processes;
import suit.SuitGroup;
import suit.SuitKind;
import suit.SuitRecord.SuitRecords;
import sys.FileSystem;
import sys.io.File;

/**
	One process suit lists. `pid` plus `started` identifies it. Only registered and adopted processes
	(`source`) are exosuit's; a scanned one is shown but never stopped in bulk.
**/
typedef SuitProcess = {
	var pid:Int;
	var started:Float;
	var parent:Int;
	var kind:SuitKind;
	var source:SuitSource;
	var root:Null<String>;
	var roots:Array<String>;
	/** A workspace service's workspace id, when it is keyed by one. */
	var workspace:Null<String>;
	/** The workspaces an editor uses, by id. */
	var workspaces:Array<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;
	var owner:Null<Int>;
	var commandLine:String;
	var orphaned:Bool;
	/**
		A compiler worker of exosuit's that a build exosuit did not start (a `haxeon-cli` of the same toolchain run from a
		terminal, an agent or a build task) is using too: listed "shared with your builds", never orphaned, and left out of
		every bulk stop while that build runs (`suit kill <pid>` still ends it).
	**/
	var shared:Bool;
	var group:SuitGroup;
	/** A terminal host's folder, terminal and workspace (TerminalHostFolder); null for anything else. */
	var terminal:Null<suit.TerminalHostFolder.TerminalHostInfo>;
}

/**
	Builds the picture suit shows: the editors linked to suit (EditorDirectory), registered processes (validated against
	their start time) plus, unless `EXOSUIT_SUIT_SCAN=0`, exosuit-related processes found by scanning command lines.

	Ownership is positive, never guessed from a command line. A process is exosuit's when it is a linked editor or
	registered itself, or when SuitLineage ties it to a registered process: it is of a kind exosuit starts, its
	environment registers with this suit, and its parent chain reaches the registered process through
	exosuit kinds only. Anything else found by scanning (a build run in an exosuit terminal, a compiler
	worker another tool started, a test's workspace service) is listed as not started by exosuit and left
	out of every bulk stop.

	Reading has no side effects. Only an inventory built with `maintain` (the daemon's) deletes stale
	records and writes adoption records, which keep an adopted process exosuit's after its ancestor exits.

	Orphans follow each kind's SuitOrphanRule: a workspace service is orphaned when no linked editor
	uses its workspace, a compiler worker when no editor or live session runs and no build exosuit did not start uses it
	(`shared`, which also keeps it out of every bulk stop), and anything else when the process it belongs to is gone.

	Terminal hosts are the exception to both rules. A host is detached from the service that started it and
	outlives it, so no parent chain ties it to exosuit: it registers itself, and one that did not (started by
	an older build) is adopted when its environment registers with this suit and the `host.json` in the
	folder its command line names holds its pid (`ownsTerminalHost`). A host is never orphaned (so the orphan
	sweep never ends it), is part of `background()` (so the full Quit and `kill --all` end it), is left out of
	`backgroundButTerminals()` (the polite quit), and is listed by `terminals()`. What a host runs is the user's program:
	nothing below a terminal host is classified or adopted by its kind (SuitLineage.belowTerminalHost).
**/
class SuitInventory {
	/**
		Executables whose command lines suit reads when scanning. `cmd.exe` is read only for its parent link (the live
		session starts its live host, the editor, through `cmd /C`: hostedEditors follows it); it is never classified.
	**/
	public static inline var SCANNED_NAMES:String = "cmd.exe;hl.exe;hl;exosuit.exe;exosuit;exosuit-agent.exe;exosuit-agent;claude.exe;claude;codex.exe;codex;pi.exe;pi;node.exe;node;python.exe;python;python3.exe;python3;haxeon-lsp.exe;haxeon-lsp";

	public final processes:Array<SuitProcess> = [];
	public final snapshot:Array<ProcessInfo>;
	public final scanning:Bool;
	final self:Int;
	final byPid:Map<Int, ProcessInfo> = new Map();
	/** False when this platform cannot list processes; records are then checked one pid at a time. */
	final listed:Bool;
	/** True for the daemon's inventory: it prunes stale records and persists adoptions. */
	final maintain:Bool;
	final lineage:SuitLineage;
	/** The toolchains of Haxeon clients exosuit did not start (foreignToolchainClients), filled by classify. */
	var buildsOutsideExosuit:Map<String, Bool> = new Map();

	/** `editors`: the editor windows linked to suit; editors have no registry records. */
	public function new(maintain:Bool = false, ?editors:Array<suit.LinkedEditor>) {
		self = Sys.getPid();
		this.maintain = maintain;
		scanning = Sys.getEnv("EXOSUIT_SUIT_SCAN") != "0";
		var list = Processes.list(SCANNED_NAMES, SuitLineage.VARIABLES);
		listed = list != null;
		snapshot = list == null ? [] : list;
		for (info in snapshot)
			byPid.set(info.pid, info);
		lineage = new SuitLineage(snapshot, SuitPaths.home());
		if (editors != null)
			addEditors(editors);
		readRegistry();
		if (scanning && listed) {
			scan();
			adoptCheckoutChains();
		}
		classify();
	}

	/** Processes exosuit started and may stop in bulk: registered or adopted, and not shared with a build (`shared`). */
	public function owned():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned && !process.shared) process];

	public function editors():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned && process.kind == SuitKind.Editor) process];

	/** exosuit's processes other than editors, terminal hosts included: what "all background processes", `kill --all` and the full Quit stop. */
	public function background():Array<SuitProcess>
		return [for (process in owned()) if (process.kind != SuitKind.Editor) process];

	/** exosuit's compiler workers that a build exosuit did not start is using too: listed, never stopped in bulk. */
	public function shared():Array<SuitProcess>
		return [for (process in processes) if (process.shared) process];

	/** exosuit's background processes other than terminal hosts: what the polite quit stops. */
	public function backgroundButTerminals():Array<SuitProcess>
		return [for (process in background()) if (!SuitKinds.keptByPoliteQuit(process.kind)) process];

	/** exosuit's terminal hosts. They outlive their service and editor; the full Quit and the "end terminals" actions end them. */
	public function terminals():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned && process.kind == SuitKind.TerminalHost) process];

	public function orphans():Array<SuitProcess>
		return [for (process in processes) if (process.orphaned) process];

	/** Processes found by scanning that exosuit did not start. */
	public function foreign():Array<SuitProcess>
		return [for (process in processes) if (process.source == Scanned) process];

	public function find(pid:Int):Null<SuitProcess> {
		for (process in processes)
			if (process.pid == pid)
				return process;
		return null;
	}

	/** One-line summary used for the tray title and tooltip. */
	public function summary():String {
		var editorCount = editors().length, backgroundCount = background().length, orphanCount = orphans().length;
		var text = 'Exosuit: $editorCount ${editorCount == 1 ? "editor" : "editors"}, $backgroundCount background ${backgroundCount == 1 ? "process" : "processes"}';
		if (orphanCount > 0)
			text += ' ($orphanCount orphaned)';
		var terminalCount = terminals().length;
		if (terminalCount > 0)
			text += ', $terminalCount ${terminalCount == 1 ? "terminal" : "terminals"}';
		var sharedCount = shared().length;
		if (sharedCount > 0)
			text += ', $sharedCount shared with your builds';
		var foreignCount = foreign().length;
		if (foreignCount > 0)
			text += ', $foreignCount not started by exosuit';
		return text;
	}

	/** The heading of a group: an editor's pid and workspaces, or the section name. */
	public function groupLabel(group:SuitGroup):String {
		return switch group {
			case EditorGroup(pid):
				var editor = find(pid);
				var names = editor == null ? [] : [for (root in editor.roots) workspaceName(root)];
				'Editor $pid' + (names.length > 0 ? ": " + names.join(", ") : "");
			case HaxeonGroup: "Haxeon";
			case OtherGroup: "Other";
			case TerminalsGroup: "Terminals (outlive their editor; Quit ends them, \"Quit, keep terminals running\" does not)";
			case OrphanedGroup: "Orphaned";
			case NotStartedByExosuit: "Not started by exosuit";
		};
	}

	/**
		The editors (registered or adopted) that run under `pid`, which started at `started`, through any processes (python,
		`cmd /C`, a live session): the editors a launcher or live session hosts. Each link obeys the start order.
	**/
	public function hostedEditors(pid:Int, started:Float):Array<SuitProcess> {
		var result:Array<SuitProcess> = [];
		for (editor in editors()) {
			var current = byPid.get(editor.pid);
			for (_ in 0...64) {
				if (current == null)
					break;
				var parent = byPid.get(current.parent);
				if (parent == null || parent.pid == current.pid || !SuitClock.startedBefore(parent.started, current.started))
					break;
				if (parent.pid == pid && parent.started == started) {
					result.push(editor);
					break;
				}
				current = parent;
			}
		}
		return result;
	}

	/**
		The terminal host this process runs under (suit's CLI typed into an Exosuit terminal), or null. Each link obeys the
		start order.
	**/
	public function ownTerminal():Null<SuitProcess> {
		var current = byPid.get(self);
		for (_ in 0...64) {
			if (current == null)
				return null;
			var parent = byPid.get(current.parent);
			if (parent == null || parent.pid == current.pid || !SuitClock.startedBefore(parent.started, current.started))
				return null;
			for (host in terminals())
				if (host.pid == parent.pid && host.started == parent.started)
					return host;
			current = parent;
		}
		return null;
	}

	/** The descendants of `pid` that exosuit spawned (SuitLineage.exosuitDescendants), from this inventory's snapshot. */
	public function exosuitDescendants(pid:Int, started:Float):Array<ProcessInfo>
		return lineage.exosuitDescendants(pid, started, self);

	/** The running process with `pid`, from the snapshot or, where listing is unsupported, asked directly. */
	function lookup(pid:Int):Null<ProcessInfo> {
		var info = byPid.get(pid);
		if (info != null || listed)
			return info;
		var started = Processes.started(pid);
		// A process this user may not open is running, but its start time is unknown (0).
		if (started == Processes.STARTED_DENIED)
			started = 0;
		return started < 0 ? null : {pid: pid, parent: 0, started: started, name: "", commandLine: "", environment: ""};
	}

	function addEditors(editors:Array<suit.LinkedEditor>):Void {
		for (editor in editors) {
			var info = lookup(editor.pid);
			if (info == null || find(info.pid) != null)
				continue;
			processes.push({
				pid: info.pid, started: info.started, parent: info.parent, kind: SuitKind.Editor, source: Registered, root: null,
				roots: editor.roots.copy(), workspace: null, workspaces: editor.workspaces.copy(), stateDir: null, generation: null,
				owner: null, commandLine: info.commandLine, orphaned: false, shared: false, group: OtherGroup, terminal: null
			});
		}
	}

	function readRegistry():Void {
		var directory = SuitPaths.registry();
		if (!FileSystem.exists(directory))
			return;
		for (name in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(name, ".json"))
				continue;
			var path = Path.join([directory, name]);
			// Records are renamed into place atomically, so an unreadable one is junk.
			var record = SuitRecords.read(path);
			if (record == null) {
				prune(path);
				continue;
			}
			if (record.pid == self)
				continue;
			var info = lookup(record.pid);
			if (info == null || !keepsRecord(info, record.registeredAt, record.version)) {
				prune(path);
				continue;
			}
			processes.push({
				pid: info.pid,
				started: info.started,
				parent: info.parent,
				kind: record.kind,
				source: record.adopted ? Adopted : Registered,
				root: record.root,
				roots: [],
				workspace: record.workspace,
				workspaces: [],
				stateDir: record.stateDir,
				generation: record.generation,
				owner: record.owner,
				commandLine: info.commandLine,
				orphaned: false,
				shared: false,
				group: OtherGroup,
				terminal: null
			});
		}
	}

	/**
		Whether a record still describes the running process `info`. A process registers after it starts, so
		one that started later reused the pid. A running process whose start time is unknown (one this user may
		not open) keeps its record: it is listed with an unknown start, and never acted on.
	**/
	public static function keepsRecord(info:Null<ProcessInfo>, registeredAt:Float, version:Int):Bool {
		if (info == null)
			return false;
		return info.started <= 0 || SuitClock.registeredAfterStart(info.started, registeredAt, version);
	}

	function scan():Void {
		var known = new Map<Int, Bool>();
		var owned = new Map<Int, Bool>();
		for (process in processes) {
			known.set(process.pid, true);
			// A terminal host owns nothing it runs: its terminal's program is the user's (SuitLineage.belowTerminalHost).
			if (process.kind != SuitKind.TerminalHost)
				owned.set(process.pid, true);
		}
		for (info in snapshot) {
			if (known.exists(info.pid) || info.pid == self || info.commandLine.length == 0 || belowTerminalHost(info))
				continue;
			var found = SuitClassifier.classify(info.name, info.commandLine);
			if (found == null || found.kind == SuitKind.Suit)
				continue;
			var owner = lineage.adoptionOwner(info, owned);
			// A host has no exosuit parent to be adopted under: it proves itself by its folder (ownsTerminalHost).
			var ownHost = found.kind == SuitKind.TerminalHost && found.terminalDir != null
				&& (ownsTerminalHost(info, suit.TerminalHostFolder.read(found.terminalDir).pid, SuitPaths.home())
					|| startedByService(info));
			var process:SuitProcess = {
				pid: info.pid,
				started: info.started,
				parent: info.parent,
				kind: found.kind,
				source: owner == null && !ownHost ? Scanned : Adopted,
				root: found.root,
				roots: [],
				workspace: found.workspace,
				workspaces: [],
				stateDir: found.stateDir,
				generation: found.generation,
				owner: owner,
				commandLine: info.commandLine,
				orphaned: false,
				shared: false,
				group: OtherGroup,
				terminal: null
			};
			processes.push(process);
			if ((owner != null || ownHost) && maintain)
				persistAdoption(process);
		}
	}

	/**
		The source-tree chain, `python scripts/run.py [--live]` -> `hl haxeon-cli.hl run --project <ROOT>/graphical/haxeon.json`
		-> (`cmd /C` ->) the live host that runs the editor, plus the resident compiler workers the session starts through
		`cmd /c start` (their parent exits at once). The editor registers, but the chain above it is not of kinds a lineage
		reaches through (python, cmd), so the scan alone lists it as not started by exosuit.

		A checkout is an Exosuit one when a registered editor runs from it (SuitClassifier.editorCheckout) or a run session
		of its `graphical/haxeon.json` was started by its `scripts/run.py`. Then, for processes whose environment registers
		with this suit: the run session is adopted (owned by the launcher when run.py started it), the launcher is added as
		`launcher`, and a scanned live host of `<ROOT>/graphical/build/` is adopted.

		A compiler worker whose hl.exe is `<ROOT>/haxeon/...` is adopted only while a run session of that checkout runs and
		only when it started after that session: the session starts its workers through `cmd /c start`, so no parent chain
		can show it, and an editor alone starts none. Such an adoption is never persisted: once the session exits the
		worker is no longer exosuit's (it is listed as not started by exosuit, so the orphan sweep never takes it). Workers
		are shared per compiler and project, so a build exosuit did not start may use one too: classify marks it `shared`.
	**/
	function adoptCheckoutChains():Void {
		var checkouts = new Map<String, String>();
		for (process in processes)
			if (process.source != Scanned && process.kind == SuitKind.Editor && process.commandLine.length > 0) {
				var root = SuitClassifier.editorCheckout(SuitClassifier.split(process.commandLine));
				if (root != null)
					checkouts.set(rootKey(root), root);
			}
		var home = SuitPaths.home();
		function registers(info:ProcessInfo):Bool
			return info.environment.length > 0 && SuitLineage.registersWith(info, home);
		var sessions:Array<{root:String, started:Float}> = [];
		for (info in snapshot) {
			if (info.pid == self || info.commandLine.length == 0)
				continue;
			var root = SuitClassifier.runSessionCheckout(info.name, SuitClassifier.split(info.commandLine));
			if (root == null || !registers(info) || belowTerminalHost(info))
				continue;
			var parent = byPid.get(info.parent);
			var launcher = parent != null && parent.commandLine.length > 0 && SuitClock.startedBefore(parent.started, info.started)
				&& SuitClassifier.isRunScript(parent.name, SuitClassifier.split(parent.commandLine)) && registers(parent) ? parent : null;
			if (launcher == null && !checkouts.exists(rootKey(root)))
				continue;
			checkouts.set(rootKey(root), root);
			if (launcher != null)
				adoptChain(launcher, SuitKind.DevLauncher, null);
			adoptChain(info, SuitKind.LiveSession, launcher == null ? null : launcher.pid);
			sessions.push({root: root, started: info.started});
		}
		if (!checkouts.keys().hasNext())
			return;
		for (process in processes) {
			if (process.source != Scanned || (process.kind != SuitKind.CompilerWorker && process.kind != SuitKind.LiveHost))
				continue;
			var info = byPid.get(process.pid);
			if (info == null || !registers(info))
				continue;
			var arguments = SuitClassifier.split(process.commandLine);
			if (process.kind == SuitKind.CompilerWorker) {
				for (session in sessions)
					if (SuitClassifier.inCheckout(arguments[0], session.root, "haxeon") && SuitClock.startedBefore(session.started, process.started)) {
						process.source = Adopted;
						break;
					}
				continue;
			}
			for (root in checkouts)
				if ([for (argument in arguments) if (SuitClassifier.inCheckout(argument, root, "graphical/build")) argument].length > 0) {
					process.source = Adopted;
					if (maintain)
						persistAdoption(process);
					break;
				}
		}
	}

	/** True when `info` runs in a terminal (SuitLineage.belowTerminalHost): the user's program, never listed by kind. */
	function belowTerminalHost(info:ProcessInfo):Bool {
		var hosts = new Map<Int, Bool>();
		for (process in processes)
			if (process.kind == SuitKind.TerminalHost)
				hosts.set(process.pid, true);
		return lineage.belowTerminalHost(info, hosts);
	}

	/** Lists `info` as exosuit's `kind`: a scanned entry for it is adopted, a missing one added. Registered ones stay. */
	function adoptChain(info:ProcessInfo, kind:SuitKind, owner:Null<Int>):Void {
		var process = find(info.pid);
		if (process != null && process.source != Scanned)
			return;
		if (process == null) {
			process = {
				pid: info.pid, started: info.started, parent: info.parent, kind: kind, source: Adopted, root: null, roots: [],
				workspace: null, workspaces: [], stateDir: null, generation: null, owner: owner,
				commandLine: info.commandLine, orphaned: false, shared: false, group: OtherGroup, terminal: null
			};
			processes.push(process);
		} else {
			process.kind = kind;
			process.source = Adopted;
			process.owner = owner;
		}
		if (maintain)
			persistAdoption(process);
	}

	/**
		Whether an unregistered terminal host is exosuit's, and this suit's: its environment was read and registers
		with the suit at `ownHome` (so a test's host under another home, or with suit off, is not), and the
		`host.json` in the folder it was started for names its own pid (`recordedPid`), which only the host writes.
	**/
	public static function ownsTerminalHost(info:ProcessInfo, recordedPid:Null<Int>, ownHome:String):Bool
		return recordedPid != null && recordedPid == info.pid && info.environment.length > 0 && SuitLineage.registersWith(info, ownHome);

	/**
		Whether a terminal host that has not registered nor written its `host.json` yet (still starting) was started by a
		workspace service this suit owns: its parent is that service (started before it) and its environment registers
		with this suit. Without this a host starting during a full Quit is in no list and survives it.
	**/
	function startedByService(info:ProcessInfo):Bool {
		if (info.environment.length == 0 || !SuitLineage.registersWith(info, SuitPaths.home()))
			return false;
		var parent = byPid.get(info.parent);
		if (parent == null || !SuitClock.startedBefore(parent.started, info.started))
			return false;
		for (process in processes)
			if (process.pid == parent.pid && process.started == parent.started && process.source != Scanned
				&& SuitKinds.isWorkspaceService(process.kind))
				return true;
		return false;
	}

	/** Records an adopted process, so it stays exosuit's after the ancestor that tied it exits. */
	function persistAdoption(process:SuitProcess):Void {
		try {
			var record = SuitRecords.create(process.pid, process.kind);
			record.root = process.root;
			record.workspace = process.workspace;
			record.stateDir = process.stateDir;
			record.generation = process.generation;
			record.owner = process.owner;
			record.adopted = true;
			SuitRecords.write(SuitPaths.registry(), record);
		} catch (_:Dynamic) {}
	}

	function classify():Void {
		var editorPids = new Map<Int, SuitProcess>();
		var claimed = new Map<String, SuitProcess>();
		var haxeonInUse = false;
		for (process in processes) {
			if (process.source == Scanned)
				continue;
			if (process.kind == SuitKind.Editor) {
				editorPids.set(process.pid, process);
				for (root in process.roots)
					if (!claimed.exists(rootKey(root)))
						claimed.set(rootKey(root), process);
				for (workspace in process.workspaces)
					if (!claimed.exists(workspaceKey(workspace)))
						claimed.set(workspaceKey(workspace), process);
				haxeonInUse = true;
			}
			if (process.kind == SuitKind.LiveSession || process.kind == SuitKind.LiveHost)
				haxeonInUse = true;
		}
		buildsOutsideExosuit = foreignToolchainClients();
		for (process in processes) {
			process.shared = process.source != Scanned && usedByBuild(process);
			if (process.kind == SuitKind.TerminalHost)
				describeTerminal(process);
			if (process.source == Scanned) {
				process.orphaned = false;
				process.group = NotStartedByExosuit;
				continue;
			}
			// The process this one belongs to: its recorded owner, else its parent.
			var belongsTo = process.owner != null ? process.owner : process.parent;
			var holder:Null<SuitProcess> = null;
			switch SuitKinds.orphanRule(process.kind) {
				case Never:
					process.orphaned = false;
					holder = SuitKinds.headsOwnGroup(process.kind) ? process : null;
				case NoEditorUsesRoot:
					holder = claimant(process, claimed);
					process.orphaned = holder == null;
				case NoHaxeonUser:
					// A worker a build outside exosuit is using is in use, whatever exosuit runs.
					process.orphaned = !haxeonInUse && !process.shared;
				case OwnerGone:
					process.orphaned = !isAlive(belongsTo, process.started);
					holder = process.orphaned ? null : editorPids.get(belongsTo);
			}
			process.group = if (process.orphaned) OrphanedGroup else if (holder != null) EditorGroup(holder.pid) else if (SuitKinds.isHaxeon(process.kind))
				HaxeonGroup else if (process.kind == SuitKind.TerminalHost) TerminalsGroup else OtherGroup;
		}
		processes.sort(function(left, right) {
			var byGroup = Reflect.compare(SuitGroups.rank(left.group), SuitGroups.rank(right.group));
			if (byGroup != 0)
				return byGroup;
			var byEditor = Reflect.compare(SuitGroups.editorOf(left.group), SuitGroups.editorOf(right.group));
			if (byEditor != 0)
				return byEditor;
			return Reflect.compare(left.started, right.started);
		});
	}

	/**
		The toolchains (SuitClassifier.toolchainOf) that a Haxeon client exosuit did not start is running on: a
		`haxeon-cli.hl` build or session run from a terminal, by an agent, or by an editor's build task. Its compiler
		workers are per compiler and project, so such a build may be using a worker exosuit's session started.
	**/
	function foreignToolchainClients():Map<String, Bool> {
		var result = new Map<String, Bool>();
		for (info in snapshot) {
			if (info.pid == self || info.commandLine.length == 0)
				continue;
			var arguments = SuitClassifier.split(info.commandLine);
			if (!SuitClassifier.isHaxeonClient(info.name, arguments))
				continue;
			var known = find(info.pid);
			if (known != null && known.source != Scanned)
				continue;
			// A client run as bare `hl` (found on PATH) or by a relative path may be on any toolchain: UNKNOWN_TOOLCHAIN.
			var toolchain = SuitClassifier.toolchainOf(arguments);
			result.set(toolchain != null ? toolchain : UNKNOWN_TOOLCHAIN, true);
		}
		return result;
	}

	/**
		Whether a build exosuit did not start may be using this compiler worker (SuitProcess.shared, for one exosuit owns):
		a Haxeon client on its toolchain, or one whose toolchain is unknown.
	**/
	public function usedByBuild(process:SuitProcess):Bool {
		if (process.kind != SuitKind.CompilerWorker)
			return false;
		var toolchain = SuitClassifier.toolchainOf(SuitClassifier.split(process.commandLine));
		return toolchain != null && buildsOutsideExosuit.exists(toolchain) || buildsOutsideExosuit.exists(UNKNOWN_TOOLCHAIN);
	}

	/** In `foreignToolchainClients`: a client whose toolchain is unknown, which may use any worker. */
	static inline final UNKNOWN_TOOLCHAIN = "?";

	/**
		Fills in a terminal host's folder, terminal and workspace: the folder from its command line, the rest from the
		files in it. A registered host's record already names its workspace; a scanned one's is read here.
	**/
	function describeTerminal(process:SuitProcess):Void {
		var directory = process.commandLine.length == 0 ? null : SuitClassifier.terminalDirectory(SuitClassifier.split(process.commandLine));
		if (directory == null)
			return;
		var info = suit.TerminalHostFolder.read(directory);
		process.terminal = info;
		if (process.root == null)
			process.root = info.root;
		if (process.workspace == null)
			process.workspace = info.workspace;
		if (process.stateDir == null)
			process.stateDir = SuitClassifier.stateOfTerminal(directory);
	}

	public static function workspaceName(root:Null<String>):String {
		if (root == null || root.length == 0)
			return "";
		var normalized = StringTools.replace(root, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substr(0, normalized.length - 1);
		var name = Path.withoutDirectory(normalized);
		return name.length > 0 ? name : normalized;
	}

	/** The editor that uses a workspace service's workspace: by id when the service is keyed by one, else by its root. */
	static function claimant(process:SuitProcess, claimed:Map<String, SuitProcess>):Null<SuitProcess> {
		var workspace = process.workspace;
		if (workspace != null)
			return claimed.get(workspaceKey(workspace));
		return process.root == null ? null : claimed.get(rootKey(process.root));
	}

	/** A workspace id's key among roots' keys, which are paths and so never start with "workspace:". */
	static function workspaceKey(id:String):String
		return "workspace:" + id;

	public static function rootKey(root:String):String {
		var normalized = StringTools.replace(root, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substr(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	/** True when `pid` runs and started before `childStarted`, so it can be the process that child belongs to. */
	function isAlive(pid:Int, childStarted:Float):Bool {
		if (pid <= 0)
			return false;
		var info = lookup(pid);
		return info != null && SuitClock.startedBefore(info.started, childStarted);
	}

	/** Deletes a stale or junk record; only the daemon's inventory does. */
	function prune(path:String):Void
		if (maintain)
			try FileSystem.deleteFile(path) catch (_:Dynamic) {}
}
