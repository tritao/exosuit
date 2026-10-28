package suit;

import processkit.Processes;
import suit.SuitClassifier.SuitClassification;
import suit.SuitKind;

/**
	Which processes descend from exosuit through exosuit's own spawn paths.

	A link counts only when every process on it is of a kind exosuit starts itself (SuitKinds.spawnedByExosuit):
	a workspace manager starting its daemon, a live session starting its host. A shell, a terminal, an
	agent CLI or a test runner in between breaks the tie, so a build someone runs in an exosuit terminal,
	a compiler worker Claude Code starts, or a test's workspace manager is never exosuit's. Each link also
	obeys the start order (SuitClock.startedBefore), so a reused pid never links.

	Pure functions over a snapshot, so they can be tested with made-up processes.
**/
class SuitLineage {
	/**
		The environment variables suit reads from candidate processes. PATH is always set, so an empty
		result means the environment could not be read, and suit then does not adopt.
	**/
	public static inline var VARIABLES:String = "EXOSUIT_SUIT;EXOSUIT_SUIT_HOME;PATH";

	static inline var MAX_DEPTH:Int = 64;

	/** The classification of a listed process exosuit starts itself, or null when it is not one. */
	public static function spawnedKind(info:ProcessInfo):Null<SuitClassification> {
		if (info.commandLine.length == 0)
			return null;
		var found = SuitClassifier.classify(info.name, info.commandLine);
		return found != null && SuitKinds.spawnedByExosuit(found.kind) ? found : null;
	}

	/**
		The descendants of `pid`, which started at `started`, that exosuit spawned: processes of exosuit's
		kinds reached only through such processes. Deepest first. Nothing else is included, so a program a
		user started from a terminal is never among them.

		When the snapshot lists `pid` with another start time, the pid now belongs to a newer process and
		nothing is followed through it.
	**/
	public static function exosuitDescendants(snapshot:Array<ProcessInfo>, pid:Int, started:Float, exclude:Int):Array<ProcessInfo> {
		var children = new Map<Int, Array<ProcessInfo>>();
		for (info in snapshot) {
			if (info.pid == pid && info.started != started)
				return [];
			var list = children.get(info.parent);
			if (list == null) {
				list = [];
				children.set(info.parent, list);
			}
			list.push(info);
		}
		var result:Array<ProcessInfo> = [];
		var visited = new Map<Int, Bool>();
		function visit(parent:Int, parentStarted:Float, depth:Int):Void {
			var list = children.get(parent);
			if (list == null || depth > MAX_DEPTH)
				return;
			for (child in list) {
				if (visited.exists(child.pid) || child.pid == exclude || child.pid == parent
					|| !SuitClock.startedBefore(parentStarted, child.started) || spawnedKind(child) == null)
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
		exosuit starts, its environment must register with this suit (so `EXOSUIT_SUIT=off` and other suits'
		processes are never taken), and its parent chain must reach a registered or adopted process (`owned`)
		through exosuit kinds only.
	**/
	public static function adoptionOwner(info:ProcessInfo, byPid:Map<Int, ProcessInfo>, owned:Map<Int, Bool>, ownHome:Null<String>):Null<Int> {
		if (spawnedKind(info) == null || info.environment.length == 0)
			return null;
		if (!SuitClient.registersWith(Processes.variable(info, "EXOSUIT_SUIT"), Processes.variable(info, "EXOSUIT_SUIT_HOME"), ownHome))
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
}
