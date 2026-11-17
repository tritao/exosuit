package exohost;

import processkit.Processes;
import exohost.ExohostClassifier.ExohostClassification;
import exohost.ExohostKind;

/**
	Which processes descend from exosuit through exosuit's own spawn paths, over one process snapshot.

	A link counts only when every process on it is of a kind exosuit starts itself (ExohostKinds.spawnedByExosuit):
	a live session starting its host. A shell, a terminal, an
	agent CLI or a test runner in between breaks the tie, so a build someone runs in an exosuit terminal,
	a compiler worker Claude Code starts, or a test's workspace service is never exosuit's. Each link also
	obeys the start order (ExohostClock.startedBefore), so a reused pid never links.

	It also holds exohost's adoption policy (`registersWith`): which environments belong to this exohost. Build
	one per snapshot (a scan, or one round of a stop's sweep); it caches each pid's classification for that
	snapshot. Pure over the snapshot, so it can be tested with made-up processes.
**/
class ExohostLineage {
	/**
		The environment variables exohost reads from candidate processes: the exohost home they belong to, and PATH. PATH is
		always set, so an empty result means the environment could not be read.
	**/
	public static inline var VARIABLES:String = "EXOSUIT_EXOHOST_HOME;PATH";

	static inline var MAX_DEPTH:Int = 64;

	final byPid:Map<Int, ProcessInfo> = new Map();
	final children:Map<Int, Array<ProcessInfo>> = new Map();
	final kinds:Map<Int, Null<ExohostClassification>> = new Map();
	final ownHome:String;

	/** `ownHome` is this exohost's resolved home (ExohostPaths.home()). */
	public function new(snapshot:Array<ProcessInfo>, ownHome:String) {
		this.ownHome = ownHome;
		for (info in snapshot) {
			byPid.set(info.pid, info);
			var list = children.get(info.parent);
			if (list == null) {
				list = [];
				children.set(info.parent, list);
			}
			list.push(info);
		}
	}

	/** The classification of a listed process exosuit starts itself, or null when it is not one. Cached per pid. */
	public function spawnedKind(info:ProcessInfo):Null<ExohostClassification> {
		if (kinds.exists(info.pid))
			return kinds.get(info.pid);
		var found = info.commandLine.length == 0 ? null : ExohostClassifier.classify(info.name, info.commandLine);
		var result = found != null && ExohostKinds.spawnedByExosuit(found.kind) ? found : null;
		kinds.set(info.pid, result);
		return result;
	}

	/**
		The descendants of `pid`, which started at `started`, that exosuit spawned: processes of exosuit's
		kinds reached only through such processes, whose environment does not belong to another exohost's home (an environment that
		could not be read does not exclude). Deepest first.
		Nothing else is included, so a program a user started from a terminal is never among them.

		When the snapshot lists `pid` with a later start time, the target exited and its pid was reused:
		only children that started before the new process are the target's. With an earlier start time the
		snapshot predates the target, and nothing is followed.
	**/
	public function exosuitDescendants(pid:Int, started:Float, exclude:Int):Array<ProcessInfo> {
		var limit = Math.POSITIVE_INFINITY;
		var listed = byPid.get(pid);
		if (listed != null && listed.started != started) {
			if (listed.started <= started)
				return [];
			limit = listed.started;
		}
		var result:Array<ProcessInfo> = [];
		var visited = new Map<Int, Bool>();
		function visit(parent:Int, parentStarted:Float, depth:Int):Void {
			var list = children.get(parent);
			if (list == null || depth > MAX_DEPTH)
				return;
			for (child in list) {
				if (visited.exists(child.pid) || child.pid == exclude || child.pid == parent
					|| !ExohostClock.startedBefore(parentStarted, child.started) || (depth == 0 && child.started >= limit))
					continue;
				var kind = spawnedKind(child);
				if (kind == null || (child.environment.length > 0 && !registersWith(child, ownHome)))
					continue;
				visited.set(child.pid, true);
				visit(child.pid, child.started, depth + 1);
				result.push(child);
			}
		}
		visit(pid, started, 0);
		return result;
	}

	/**
		The pid of the exosuit process `info` should be adopted under, or null. `info` must be of a kind
		exosuit starts, its environment must have been read and register with this exohost (`registersWith`),
		and its parent chain must reach a registered or adopted process (`owned`) through exosuit kinds only.
	**/
	public function adoptionOwner(info:ProcessInfo, owned:Map<Int, Bool>):Null<Int> {
		var kind = spawnedKind(info);
		if (kind == null || info.environment.length == 0 || !registersWith(info, ownHome))
			return null;
		var current = info;
		for (_ in 0...MAX_DEPTH) {
			var parent = byPid.get(current.parent);
			if (parent == null || parent.pid == current.pid || !ExohostClock.startedBefore(parent.started, current.started))
				return null;
			if (owned.exists(parent.pid))
				return parent.pid;
			if (spawnedKind(parent) == null)
				return null;
			current = parent;
		}
		return null;
	}

	/**
		True when `info` runs below a terminal host: a listed ancestor (each link obeying the start order) is in `hosts`
		(terminal hosts exohost knows by pid) or carries `--terminal-host DIR`. What runs in a terminal is the user's program,
		even when it is of a kind exosuit starts (an SDK-mode claude, a codex app-server): it is never classified or adopted
		by kind, and its host ends it when the terminal ends. A shell exohost does not list (pwsh, bash) hides the host; a
		process below one is still never adopted, since the shell breaks every chain.
	**/
	public function belowTerminalHost(info:ProcessInfo, hosts:Map<Int, Bool>):Bool {
		var current = info;
		for (_ in 0...MAX_DEPTH) {
			var parent = byPid.get(current.parent);
			if (parent == null || parent.pid == current.pid || !ExohostClock.startedBefore(parent.started, current.started))
				return false;
			if (hosts.exists(parent.pid)
				|| parent.commandLine.length > 0 && ExohostClassifier.terminalDirectory(ExohostClassifier.split(parent.commandLine)) != null)
				return true;
			current = parent;
		}
		return false;
	}

	/**
		exohost's adoption policy: true when a process started with this environment registers with the exohost at `ownHome`.
		Resolved homes are compared, so an explicit default home and an unset one are the same exohost.
	**/
	public static function registersWith(info:ProcessInfo, ownHome:String):Bool {
		var home = Processes.variable(info, "EXOSUIT_EXOHOST_HOME");
		var target = home != null && home.length > 0 ? home : ExohostPaths.defaultHome();
		return ExohostInventory.rootKey(target) == ExohostInventory.rootKey(ownHome);
	}
}