package suit;

import processkit.Processes;
import suit.SuitClassifier.SuitClassification;
import suit.SuitClient.SuitMode;
import suit.SuitKind;

/**
	Which processes descend from exosuit through exosuit's own spawn paths, over one process snapshot.

	A link counts only when every process on it is of a kind exosuit starts itself (SuitKinds.spawnedByExosuit):
	a workspace manager starting its daemon, a live session starting its host. A shell, a terminal, an
	agent CLI or a test runner in between breaks the tie, so a build someone runs in an exosuit terminal,
	a compiler worker Claude Code starts, or a test's workspace manager is never exosuit's. Each link also
	obeys the start order (SuitClock.startedBefore), so a reused pid never links.

	It also holds suit's adoption policy (`registersWith`): which environments belong to this suit. Build
	one per snapshot (a scan, or one round of a stop's sweep); it caches each pid's classification for that
	snapshot. Pure over the snapshot, so it can be tested with made-up processes.
**/
class SuitLineage {
	/**
		The environment variables suit reads from candidate processes: the suit switch, the state variables
		its temp-folder rule looks at, and PATH. PATH is always set, so an empty result means the environment
		could not be read.
	**/
	public static inline var VARIABLES:String = "EXOSUIT_SUIT;EXOSUIT_SUIT_HOME;PRAGTICAL_PORTABLE;XDG_STATE_HOME;EXOSUIT_AGENT_STATE_HOME;PATH";

	static inline var MAX_DEPTH:Int = 64;

	final byPid:Map<Int, ProcessInfo> = new Map();
	final children:Map<Int, Array<ProcessInfo>> = new Map();
	final kinds:Map<Int, Null<SuitClassification>> = new Map();
	final ownHome:String;

	/** `ownHome` is this suit's resolved home (SuitPaths.home()). */
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
	public function spawnedKind(info:ProcessInfo):Null<SuitClassification> {
		if (kinds.exists(info.pid))
			return kinds.get(info.pid);
		var found = info.commandLine.length == 0 ? null : SuitClassifier.classify(info.name, info.commandLine);
		var result = found != null && SuitKinds.spawnedByExosuit(found.kind) ? found : null;
		kinds.set(info.pid, result);
		return result;
	}

	/**
		The descendants of `pid`, which started at `started`, that exosuit spawned: processes of exosuit's
		kinds reached only through such processes, whose environment does not belong elsewhere (`EXOSUIT_SUIT=off`
		or another suit's home; an environment that could not be read does not exclude). Deepest first.
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
					|| !SuitClock.startedBefore(parentStarted, child.started) || (depth == 0 && child.started >= limit))
					continue;
				var kind = spawnedKind(child);
				if (kind == null || (child.environment.length > 0 && !registersWith(child, kind.stateDir, ownHome)))
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
		exosuit starts, its environment must have been read and register with this suit (`registersWith`),
		and its parent chain must reach a registered or adopted process (`owned`) through exosuit kinds only.
	**/
	public function adoptionOwner(info:ProcessInfo, owned:Map<Int, Bool>):Null<Int> {
		var kind = spawnedKind(info);
		if (kind == null || info.environment.length == 0 || !registersWith(info, kind.stateDir, ownHome))
			return null;
		var current = info;
		for (_ in 0...MAX_DEPTH) {
			var parent = byPid.get(current.parent);
			if (parent == null || parent.pid == current.pid || !SuitClock.startedBefore(parent.started, current.started))
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
		suit's adoption policy: true when a process started with this environment (and, for a workspace
		service, this state directory) registers with the suit at `ownHome`. It applies the mode rule a
		process applies to itself (SuitClient.modeOf: `off`, or unset with temporary state, is off), then
		compares resolved homes, so an explicit default home and an unset one are the same suit.

		The temp-folder rule is applied here again because what suit reads differs by platform: Windows shows
		a process's current environment, including the `EXOSUIT_SUIT=off` it sets itself at startup, while
		Linux shows the environment it started with. Both decide alike this way.
	**/
	public static function registersWith(info:ProcessInfo, stateDir:Null<String>, ownHome:String):Bool {
		var home = Processes.variable(info, "EXOSUIT_SUIT_HOME");
		var states = [for (name in SuitClient.STATE_VARIABLES) Processes.variable(info, name)];
		states.push(stateDir);
		if (SuitClient.modeOf(Processes.variable(info, "EXOSUIT_SUIT"), home, states) == SuitMode.Off)
			return false;
		var target = home != null && home.length > 0 ? home : SuitPaths.defaultHome();
		return SuitInventory.rootKey(target) == SuitInventory.rootKey(ownHome);
	}
}
