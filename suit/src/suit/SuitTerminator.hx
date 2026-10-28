package suit;

import processkit.Processes;
import processkit.ffi.ProcessKitConstants;
import suit.SuitInventory.SuitProcess;
import suit.SuitKind;

private typedef Target = {
	var process:SuitProcess;
	/** Descendants captured before anything was stopped. */
	var tree:Array<ProcessInfo>;
	var deadline:Float;
	var forceAtDeadline:Bool;
	var done:Bool;
}

/** What happened to one terminated process. */
typedef TerminationResult = {
	var pid:Int;
	var kind:SuitKind;
	var outcome:String;
}

/**
	Stops processes the way suit's menu and CLI promise: gracefully first, then the whole tree. Each kind's
	SuitStop says how:

	- CloseWindows (editors): asked to close, so they can save or prompt. An editor still open when the
	  grace period ends is left running and reported, never killed with unsaved work.
	- StopRequest (workspace managers): `stop-request.json` in the state directory, the cooperative path a
	  restart uses: the manager stops its daemon, removes its endpoint and releases its lock. Relay hosting
	  ends with it; device grants and relay settings stay on disk, so nothing is revoked.
	- ThroughManager (workspace daemons): stopped through their running manager.
	- Kill: killed with its descendants at once.

	When the grace period ends, suit takes a fresh process snapshot and kills the tree deepest first: the
	descendants captured before anything was stopped, plus any started since. It repeats until a snapshot
	finds nothing new, so a child started during the grace period or the kill does not survive. Every kill
	re-checks the pid's start time, and a process whose start time is unknown is reported, not touched.
	The job is ticked; it never blocks.
**/
class SuitTerminator {
	public static inline var SERVICE_GRACE_SECONDS:Float = 3;
	public static inline var EDITOR_GRACE_SECONDS:Float = 10;

	/** Snapshot-and-kill rounds before suit gives up on a tree that keeps spawning. */
	static inline var KILL_ROUNDS:Int = 4;

	final targets:Array<Target> = [];
	public final results:Array<TerminationResult> = [];
	final self:Int;

	public function new(inventory:SuitInventory, processes:Array<SuitProcess>) {
		var now = Sys.time();
		var chosen = new Map<Int, Bool>();
		self = Sys.getPid();
		for (process in processes) {
			var target = process;
			if (SuitKinds.stop(process.kind) == ThroughManager) {
				var manager = inventory.find(process.parent);
				if (manager != null && SuitKinds.stop(manager.kind) == StopRequest)
					target = manager;
			}
			if (target.pid == self || chosen.exists(target.pid))
				continue;
			chosen.set(target.pid, true);
			if (target.started <= 0) {
				results.push({pid: target.pid, kind: target.kind, outcome: "not stopped: its start time is unknown"});
				continue;
			}
			var strategy = SuitKinds.stop(target.kind);
			var graceful = requestStop(target, strategy);
			targets.push({
				process: target,
				tree: inventory.descendants(target.pid, target.started),
				deadline: now + (graceful ? (strategy == CloseWindows ? EDITOR_GRACE_SECONDS : SERVICE_GRACE_SECONDS) : 0.0),
				forceAtDeadline: strategy != CloseWindows,
				done: false
			});
		}
	}

	public function finished():Bool {
		for (target in targets)
			if (!target.done)
				return false;
		return true;
	}

	/** Advances the job; returns true once every target has been handled. */
	public function tick():Bool {
		var now = Sys.time();
		for (target in targets) {
			if (target.done)
				continue;
			var alive = Processes.alive(target.process.pid, target.process.started);
			if (alive && now < target.deadline)
				continue;
			if (alive && !target.forceAtDeadline) {
				finish(target, "still open");
				continue;
			}
			killTree(target);
			if (alive)
				Processes.terminate(target.process.pid, target.process.started);
			finish(target, alive ? "killed" : "stopped");
		}
		return finished();
	}

	/** Runs the job to completion; for the CLI, which has no event loop. */
	public function run():Array<TerminationResult> {
		while (!tick())
			Sys.sleep(0.1);
		return results;
	}

	/**
		Kills the target's descendants, deepest first: those captured at the start and any a fresh snapshot
		finds under the target or under them. Repeats while a snapshot finds a live one not yet killed.
	**/
	function killTree(target:Target):Void {
		var killed = new Map<String, Bool>();
		for (_ in 0...KILL_ROUNDS) {
			var snapshot = Processes.list("");
			var tree:Array<ProcessInfo> = [];
			if (snapshot != null) {
				tree = SuitInventory.descendantsIn(snapshot, target.process.pid, target.process.started, self);
				for (captured in target.tree)
					for (child in SuitInventory.descendantsIn(snapshot, captured.pid, captured.started, self))
						tree.push(child);
			}
			for (captured in target.tree)
				tree.push(captured);
			var progress = false;
			for (child in tree) {
				var key = child.pid + "@" + child.started;
				if (killed.exists(key) || !Processes.alive(child.pid, child.started))
					continue;
				killed.set(key, true);
				if (Processes.terminate(child.pid, child.started) == ProcessKitConstants.PROCESSKIT_OK)
					progress = true;
			}
			if (!progress)
				return;
		}
	}

	function finish(target:Target, outcome:String):Void {
		target.done = true;
		results.push({pid: target.process.pid, kind: target.process.kind, outcome: outcome});
	}

	/** Starts a graceful stop. Returns false when there is none and the process must simply be killed. */
	static function requestStop(process:SuitProcess, strategy:SuitStop):Bool {
		switch strategy {
			case CloseWindows:
				return Processes.requestClose(process.pid, process.started) == ProcessKitConstants.PROCESSKIT_OK;
			case StopRequest:
				if (process.stateDir == null || process.generation == null)
					return false;
				try {
					WorkspaceStopRequest.write(process.stateDir, process.generation);
					return true;
				} catch (_:Dynamic) {
					return false;
				}
			case ThroughManager | Kill:
				return false;
		}
	}
}
