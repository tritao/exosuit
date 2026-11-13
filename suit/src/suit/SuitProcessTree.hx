package suit;

import processkit.Processes;
import suit.SuitKind;

/**
	A process's whole OS tree over one snapshot, followed by parent pid: what ends with an exosuit process suit ends
	(SuitKinds.endsTree), whatever started it: an agent's MCP servers and tool commands, a dev server it started, the
	program in a terminal host suit had to kill. Pure over the snapshot, so it can be tested with made-up processes.

	Each link obeys the start order (SuitClock.startedBefore), so a reused pid never links. Never part of a tree:

	- an editor (closed, never killed), and every process an editor runs under, so an editor started below a service is
	  not cut off from its session;
	- a terminal host and everything below it: a terminal ends only through its host's own end path, or when suit
	  ends that host by force (its tree is then followed from the host itself);
	- suit itself, and the process `exclude` names (the caller).
**/
class SuitProcessTree {
	static inline var MAX_DEPTH:Int = 64;

	final byPid:Map<Int, ProcessInfo> = new Map();
	final children:Map<Int, Array<ProcessInfo>> = new Map();
	final isEditor:ProcessInfo->Bool;

	/**
		`isEditor` tells the editors suit knows (registered or adopted) apart: an editor that runs as a live host reads as
		one only by its record.
	**/
	public function new(snapshot:Array<ProcessInfo>, isEditor:ProcessInfo->Bool) {
		this.isEditor = isEditor;
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

	/**
		The tree under `pid`, which started at `started`, deepest first (so it can be killed leaves first).

		When the snapshot lists `pid` with a later start time, the target exited and its pid was reused: only children that
		started before the new process are the target's. With an earlier start time the snapshot predates the target, and
		nothing is followed.
	**/
	public function descendants(pid:Int, started:Float, exclude:Int):Array<ProcessInfo> {
		var limit = Math.POSITIVE_INFINITY;
		var listed = byPid.get(pid);
		if (listed != null && listed.started != started) {
			if (listed.started <= started)
				return [];
			limit = listed.started;
		}
		var result:Array<ProcessInfo> = [];
		var visited = new Map<Int, Bool>();
		// Adds the parts of `parent`'s tree that end with it; true when an editor runs somewhere below it.
		function visit(parent:Int, parentStarted:Float, depth:Int):Bool {
			var list = children.get(parent);
			if (list == null || depth > MAX_DEPTH)
				return false;
			var hostsEditor = false;
			for (child in list) {
				if (visited.exists(child.pid) || child.pid == exclude || child.pid == parent
					|| !SuitClock.startedBefore(parentStarted, child.started) || (depth == 0 && child.started >= limit))
					continue;
				visited.set(child.pid, true);
				switch isEditor(child) ? SuitKind.Editor : kindOf(child) {
					case SuitKind.Editor:
						hostsEditor = true;
						continue;
					case SuitKind.TerminalHost | SuitKind.Suit:
						continue;
					default:
				}
				if (visit(child.pid, child.started, depth + 1))
					hostsEditor = true;
				else
					result.push(child);
			}
			return hostsEditor;
		}
		visit(pid, started, 0);
		return result;
	}

	static function kindOf(info:ProcessInfo):Null<SuitKind> {
		if (info.commandLine.length == 0)
			return null;
		var found = SuitClassifier.classify(info.name, info.commandLine);
		return found == null ? null : found.kind;
	}
}
