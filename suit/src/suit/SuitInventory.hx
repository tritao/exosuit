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
	var stateDir:Null<String>;
	var generation:Null<String>;
	var owner:Null<Int>;
	var commandLine:String;
	var orphaned:Bool;
	var group:SuitGroup;
	var relay:Null<SuitRelayStatus>;
}

/** Relay hosting state a workspace daemon publishes in its state directory; device ids only, never keys. */
typedef SuitRelayStatus = {
	var configured:Bool;
	var connected:Bool;
	var origin:Null<String>;
	var error:Null<String>;
	var devices:Array<{deviceId:String, connected:Bool, revoked:Bool}>;
	var pending:Int;
	var updatedAt:Float;
}

/**
	Builds the picture suit shows: registered processes (validated against their start time) plus, unless
	`EXOSUIT_SUIT_SCAN=0`, exosuit-related processes found by scanning command lines.

	Ownership is positive, never guessed from a command line. A process is exosuit's when it registered
	itself, or when SuitLineage ties it to a registered process: it is of a kind exosuit starts, its
	environment registers with this suit, and its parent chain reaches the registered process through
	exosuit kinds only. Anything else found by scanning (a build run in an exosuit terminal, a compiler
	worker another tool started, a test's workspace manager) is listed as not started by exosuit and left
	out of every bulk stop.

	Reading has no side effects. Only an inventory built with `maintain` (the daemon's) deletes stale
	records and writes adoption records, which keep an adopted process exosuit's after its ancestor exits.

	Orphans follow each kind's SuitOrphanRule: a workspace service is orphaned when no registered editor
	uses its root, a compiler worker when no editor or live session runs, and anything else when the
	process it belongs to is gone.
**/
class SuitInventory {
	/** Executables whose command lines suit reads when scanning. */
	public static inline var SCANNED_NAMES:String = "hl.exe;hl;exosuit.exe;exosuit;exosuit-agent.exe;exosuit-agent";

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

	public function new(maintain:Bool = false) {
		self = Sys.getPid();
		this.maintain = maintain;
		scanning = Sys.getEnv("EXOSUIT_SUIT_SCAN") != "0";
		var list = Processes.list(SCANNED_NAMES, SuitLineage.VARIABLES);
		listed = list != null;
		snapshot = list == null ? [] : list;
		for (info in snapshot)
			byPid.set(info.pid, info);
		lineage = new SuitLineage(snapshot, SuitPaths.home());
		readRegistry();
		if (scanning && listed)
			scan();
		classify();
	}

	/** Processes exosuit started: registered or adopted. */
	public function owned():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned) process];

	public function editors():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned && process.kind == SuitKind.Editor) process];

	/** exosuit's processes other than editors. */
	public function background():Array<SuitProcess>
		return [for (process in processes) if (process.source != Scanned && process.kind != SuitKind.Editor) process];

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

	/** Workspaces with relay hosting configured, one entry per root (the manager when both are listed). */
	public function hosted():Array<SuitProcess> {
		var seen = new Map<String, Bool>();
		var result:Array<SuitProcess> = [];
		for (kind in [SuitKind.WorkspaceManager, SuitKind.WorkspaceHost])
			for (process in processes)
				if (process.kind == kind && process.relay != null && process.relay.configured && process.root != null
					&& !seen.exists(rootKey(process.root))) {
					seen.set(rootKey(process.root), true);
					result.push(process);
				}
		return result;
	}

	/** One-line summary used for the tray title and tooltip. */
	public function summary():String {
		var editorCount = editors().length, backgroundCount = background().length, orphanCount = orphans().length;
		var text = 'Exosuit: $editorCount ${editorCount == 1 ? "editor" : "editors"}, $backgroundCount background ${backgroundCount == 1 ? "process" : "processes"}';
		if (orphanCount > 0)
			text += ' ($orphanCount orphaned)';
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
			case OrphanedGroup: "Orphaned";
			case NotStartedByExosuit: "Not started by exosuit";
		};
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
				roots: record.roots,
				stateDir: record.stateDir,
				generation: record.generation,
				owner: record.owner,
				commandLine: info.commandLine,
				orphaned: false,
				group: OtherGroup,
				relay: null
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
			owned.set(process.pid, true);
		}
		for (info in snapshot) {
			if (known.exists(info.pid) || info.pid == self || info.commandLine.length == 0)
				continue;
			var found = SuitClassifier.classify(info.name, info.commandLine);
			if (found == null || found.kind == SuitKind.Suit)
				continue;
			var owner = lineage.adoptionOwner(info, owned);
			var process:SuitProcess = {
				pid: info.pid,
				started: info.started,
				parent: info.parent,
				kind: found.kind,
				source: owner == null ? Scanned : Adopted,
				root: found.root,
				roots: [],
				stateDir: found.stateDir,
				generation: found.generation,
				owner: owner,
				commandLine: info.commandLine,
				orphaned: false,
				group: OtherGroup,
				relay: null
			};
			processes.push(process);
			if (owner != null && maintain)
				persistAdoption(process);
		}
	}

	/** Records an adopted process, so it stays exosuit's after the ancestor that tied it exits. */
	function persistAdoption(process:SuitProcess):Void {
		try {
			var record = SuitRecords.create(process.pid, process.kind);
			record.root = process.root;
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
		var hostedWorkspaces = new Map<String, Bool>();
		for (host in suit.relay.SuitRelayHosts.active()) {
			hostedWorkspaces.set("state:" + rootKey(host.stateDir), true);
			hostedWorkspaces.set("root:" + rootKey(host.root), true);
		}
		for (process in processes) {
			if (process.source == Scanned)
				continue;
			if (process.kind == SuitKind.Editor) {
				editorPids.set(process.pid, process);
				for (root in process.roots)
					if (!claimed.exists(rootKey(root)))
						claimed.set(rootKey(root), process);
				haxeonInUse = true;
			}
			if (process.kind == SuitKind.LiveSession || process.kind == SuitKind.LiveHost)
				haxeonInUse = true;
		}
		for (process in processes) {
			if (SuitKinds.isWorkspaceService(process.kind) && process.stateDir != null)
				process.relay = readRelay(process.stateDir);
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
					holder = process.root == null ? null : claimed.get(rootKey(process.root));
					process.orphaned = holder == null && !keptByHosting(process, hostedWorkspaces);
				case NoHaxeonUser:
					process.orphaned = !haxeonInUse;
				case OwnerGone:
					process.orphaned = !isAlive(belongsTo, process.started);
					holder = process.orphaned ? null : editorPids.get(belongsTo);
			}
			process.group = if (process.orphaned) OrphanedGroup else if (holder != null) EditorGroup(holder.pid) else if (SuitKinds.isHaxeon(process.kind))
				HaxeonGroup else OtherGroup;
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

	public static function workspaceName(root:Null<String>):String {
		if (root == null || root.length == 0)
			return "";
		var normalized = StringTools.replace(root, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substr(0, normalized.length - 1);
		var name = Path.withoutDirectory(normalized);
		return name.length > 0 ? name : normalized;
	}

	/**
		True for a workspace service of a workspace suit hosts (SuitRelayHosts.active): suit starts and
		keeps those services itself while hosting is on, so they are in use without an editor. A service is
		matched by its state directory, or by its root when it names no state directory.
	**/
	static function keptByHosting(process:SuitProcess, hostedWorkspaces:Map<String, Bool>):Bool {
		if (process.stateDir != null)
			return hostedWorkspaces.exists("state:" + rootKey(process.stateDir));
		return process.root != null && hostedWorkspaces.exists("root:" + rootKey(process.root));
	}

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

	/** Reads `relay-status.json`, which a hosting workspace daemon rewrites while it runs. */
	public static function readRelay(stateDir:String):Null<SuitRelayStatus> {
		// A daemon can also host because EXOSUIT_RELAY_ORIGIN was set in its environment; its status file says so.
		var configured = FileSystem.exists(Path.join([stateDir, "relay-settings.json"]));
		var path = Path.join([stateDir, "relay-status.json"]);
		var status:Dynamic = null;
		try {
			var metadata = FileSystem.exists(path) ? FileSystem.metadata(path) : null;
			if (metadata != null && metadata.size < 262144)
				status = Json.parse(File.getContent(path));
		} catch (_:Dynamic) {}
		if (status == null)
			return configured ? {configured: true, connected: false, origin: null, error: null, devices: [], pending: 0, updatedAt: 0} : null;
		var devices:Array<{deviceId:String, connected:Bool, revoked:Bool}> = [];
		var listed:Dynamic = Reflect.field(status, "devices");
		if (Std.isOfType(listed, Array))
			for (device in (listed : Array<Dynamic>)) {
				var id = SuitRecords.stringField(device, "deviceId");
				if (id != null)
					devices.push({deviceId: id, connected: Reflect.field(device, "connected") == true, revoked: Reflect.field(device, "revoked") == true});
			}
		var pending = SuitRecords.intField(status, "pending");
		var updatedAt = SuitRecords.floatField(status, "updatedAt");
		return {
			configured: configured || Reflect.field(status, "configured") == true,
			connected: Reflect.field(status, "connected") == true,
			origin: SuitRecords.stringField(status, "origin"),
			error: SuitRecords.stringField(status, "error"),
			devices: devices,
			pending: pending == null ? 0 : pending,
			updatedAt: updatedAt == null ? 0 : updatedAt
		};
	}

	/** Deletes a stale or junk record; only the daemon's inventory does. */
	function prune(path:String):Void
		if (maintain)
			try FileSystem.deleteFile(path) catch (_:Dynamic) {}
}
