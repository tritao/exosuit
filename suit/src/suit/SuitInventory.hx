package suit;

import haxe.Json;
import haxe.io.Path;
import processkit.Processes;
import sys.FileSystem;
import sys.io.File;

/** One process suit tracks. `pid` plus `started` identifies it; `registered` is false for processes found only by scanning. */
typedef SuitProcess = {
	var pid:Int;
	var started:Float;
	var parent:Int;
	var kind:String;
	var registered:Bool;
	var root:Null<String>;
	var roots:Array<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;
	var owner:Null<Int>;
	var commandLine:String;
	var orphaned:Bool;
	var group:String;
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
	`EXOSUIT_SUIT_SCAN=0`, exosuit-related processes found by scanning command lines, so stragglers from
	older builds or crashes appear too.

	Ownership: an editor owns the services it started (`owner`) and the workspaces it reports using
	(`roots`). A workspace service is orphaned when no running editor owns it or uses its root. Haxeon
	compiler workers are resident by design; they count as orphaned only when no editor or live session
	is running. Anything else is orphaned when its owner, or failing that its parent, is gone.
**/
class SuitInventory {
	/** Executables whose command lines suit reads when scanning. */
	public static inline var SCANNED_NAMES:String = "hl.exe;hl;exosuit.exe;exosuit;exosuit-agent.exe;exosuit-agent";

	public final processes:Array<SuitProcess> = [];
	public final snapshot:Array<ProcessInfo>;
	public final scanning:Bool;
	final self:Int;

	public function new(?snapshotOverride:Array<ProcessInfo>) {
		self = Sys.getPid();
		scanning = Sys.getEnv("EXOSUIT_SUIT_SCAN") != "0";
		var listed = snapshotOverride != null ? snapshotOverride : Processes.list(SCANNED_NAMES);
		snapshot = listed == null ? [] : listed;
		var byPid = new Map<Int, ProcessInfo>();
		for (info in snapshot)
			byPid.set(info.pid, info);
		readRegistry(byPid);
		if (scanning && listed != null)
			scan();
		classify(byPid);
	}

	public function editors():Array<SuitProcess>
		return [for (process in processes) if (process.kind == "editor") process];

	public function background():Array<SuitProcess>
		return [for (process in processes) if (process.kind != "editor") process];

	public function orphans():Array<SuitProcess>
		return [for (process in processes) if (process.orphaned) process];

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
		for (kind in ["workspace-manager", "workspace-host"])
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
		return text;
	}

	/** Every live descendant of `pid`, deepest first, as pid/start pairs. */
	public function descendants(pid:Int):Array<ProcessInfo> {
		var children = new Map<Int, Array<ProcessInfo>>();
		var started = new Map<Int, Float>();
		for (info in snapshot) {
			started.set(info.pid, info.started);
			var list = children.get(info.parent);
			if (list == null) {
				list = [];
				children.set(info.parent, list);
			}
			list.push(info);
		}
		var result:Array<ProcessInfo> = [];
		var visited = new Map<Int, Bool>();
		function visit(parent:Int, parentStarted:Float):Void {
			var list = children.get(parent);
			if (list == null)
				return;
			for (child in list) {
				// A child cannot predate its parent; an older process with this ppid belongs to a reused pid.
				if (visited.exists(child.pid) || child.pid == self || (parentStarted > 0 && child.started > 0 && child.started + 1000 < parentStarted))
					continue;
				visited.set(child.pid, true);
				visit(child.pid, child.started);
				result.push(child);
			}
		}
		visit(pid, started.exists(pid) ? started.get(pid) : 0);
		return result;
	}

	function readRegistry(byPid:Map<Int, ProcessInfo>):Void {
		var directory = SuitPaths.registry();
		if (!FileSystem.exists(directory))
			return;
		for (name in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(name, ".json"))
				continue;
			var path = Path.join([directory, name]);
			var record:Dynamic = null;
			try {
				var info = FileSystem.metadata(path);
				if (info == null || info.size > 65536)
					throw "too large";
				record = Json.parse(File.getContent(path));
			} catch (_:Dynamic) {
				// A record being replaced is renamed into place atomically; an unreadable one is junk.
				removeRecord(path);
				continue;
			}
			var pid = intField(record, "pid");
			var registeredAt = floatField(record, "registeredAt");
			var info = pid == null ? null : byPid.get(pid);
			// A reused pid starts after the record was written; give clocks a little slack.
			if (info == null || pid == self || registeredAt == null || (info.started > 0 && info.started > registeredAt + 5000)) {
				if (info == null || pid != self)
					removeRecord(path);
				continue;
			}
			var roots:Array<String> = [];
			var listed:Dynamic = Reflect.field(record, "roots");
			if (Std.isOfType(listed, Array))
				for (value in (listed : Array<Dynamic>))
					if (Std.isOfType(value, String))
						roots.push(value);
			var kind = stringField(record, "kind");
			processes.push({
				pid: info.pid,
				started: info.started,
				parent: info.parent,
				kind: kind == null ? "other" : kind,
				registered: true,
				root: stringField(record, "root"),
				roots: roots,
				stateDir: stringField(record, "stateDir"),
				generation: stringField(record, "generation"),
				owner: intField(record, "owner"),
				commandLine: info.commandLine,
				orphaned: false,
				group: "",
				relay: null
			});
		}
	}

	function scan():Void {
		var known = new Map<Int, Bool>();
		for (process in processes)
			known.set(process.pid, true);
		for (info in snapshot) {
			if (known.exists(info.pid) || info.pid == self || info.commandLine.length == 0)
				continue;
			var found = SuitClassifier.classify(info.name, info.commandLine);
			if (found == null || found.kind == "suit")
				continue;
			processes.push({
				pid: info.pid,
				started: info.started,
				parent: info.parent,
				kind: found.kind,
				registered: false,
				root: found.root,
				roots: [],
				stateDir: found.stateDir,
				generation: found.generation,
				owner: null,
				commandLine: info.commandLine,
				orphaned: false,
				group: "",
				relay: null
			});
		}
	}

	function classify(byPid:Map<Int, ProcessInfo>):Void {
		var editorPids = new Map<Int, SuitProcess>();
		var claimed = new Map<String, SuitProcess>();
		var liveSession = false;
		for (process in processes) {
			if (process.kind == "editor") {
				editorPids.set(process.pid, process);
				for (root in process.roots)
					if (!claimed.exists(rootKey(root)))
						claimed.set(rootKey(root), process);
			}
			if (process.kind == "live-session" || process.kind == "live-host")
				liveSession = true;
		}
		var anyEditor = editorPids.keys().hasNext();
		for (process in processes) {
			var owner:Null<SuitProcess> = process.owner == null ? null : editorPids.get(process.owner);
			var parentAlive = isAlive(byPid, process.parent, process.started);
			switch process.kind {
				case "editor":
					process.orphaned = false;
					process.group = editorGroup(process);
				case "workspace-manager" | "workspace-host":
					var user = process.root == null ? null : claimed.get(rootKey(process.root));
					var holder = user != null ? user : owner;
					process.orphaned = holder == null;
					process.group = holder == null ? "Orphaned" : editorGroup(holder);
				case "compiler-worker":
					process.orphaned = !anyEditor && !liveSession;
					process.group = process.orphaned ? "Orphaned" : "Haxeon";
				case "live-session" | "live-host":
					process.orphaned = !parentAlive;
					process.group = process.orphaned ? "Orphaned" : "Haxeon";
				default:
					process.orphaned = process.owner != null ? owner == null && !isAlive(byPid, process.owner, 0) : !parentAlive;
					process.group = process.orphaned ? "Orphaned" : owner != null ? editorGroup(owner) : "Other";
			}
			if ((process.kind == "workspace-manager" || process.kind == "workspace-host") && process.stateDir != null)
				process.relay = readRelay(process.stateDir);
		}
		processes.sort(function(left, right) {
			var byGroup = Reflect.compare(groupRank(left.group), groupRank(right.group));
			if (byGroup != 0)
				return byGroup;
			var byName = Reflect.compare(left.group, right.group);
			if (byName != 0)
				return byName;
			return Reflect.compare(left.started, right.started);
		});
	}

	static function groupRank(group:String):Int
		return StringTools.startsWith(group, "Editor") ? 0 : group == "Haxeon" ? 1 : group == "Other" ? 2 : 3;

	static function editorGroup(editor:SuitProcess):String {
		var names = [for (root in editor.roots) workspaceName(root)];
		return 'Editor ${editor.pid}' + (names.length > 0 ? ": " + names.join(", ") : "");
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

	public static function rootKey(root:String):String {
		var normalized = StringTools.replace(root, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substr(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	static function isAlive(byPid:Map<Int, ProcessInfo>, pid:Null<Int>, childStarted:Float):Bool {
		if (pid == null || pid <= 0)
			return false;
		var info = byPid.get(pid);
		if (info == null)
			return false;
		return childStarted <= 0 || info.started <= 0 || info.started <= childStarted + 1000;
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
				var id = stringField(device, "deviceId");
				if (id != null)
					devices.push({deviceId: id, connected: Reflect.field(device, "connected") == true, revoked: Reflect.field(device, "revoked") == true});
			}
		var pending = intField(status, "pending");
		var updatedAt = floatField(status, "updatedAt");
		return {
			configured: configured || Reflect.field(status, "configured") == true,
			connected: Reflect.field(status, "connected") == true,
			origin: stringField(status, "origin"),
			error: stringField(status, "error"),
			devices: devices,
			pending: pending == null ? 0 : pending,
			updatedAt: updatedAt == null ? 0 : updatedAt
		};
	}

	static function removeRecord(path:String):Void
		try FileSystem.deleteFile(path) catch (_:Dynamic) {}

	public static function stringField(value:Dynamic, field:String):Null<String> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) && (result : String).length > 0 ? result : null;
	}

	public static function intField(value:Dynamic, field:String):Null<Int> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		if (Std.isOfType(result, Int))
			return result;
		if (Std.isOfType(result, Float) && Math.ffloor(result) == result)
			return Std.int(result);
		return null;
	}

	public static function floatField(value:Dynamic, field:String):Null<Float> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Float) || Std.isOfType(result, Int) ? (result : Float) : null;
	}
}
