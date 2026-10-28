package suit;

import processkit.Processes;
import processkit.ffi.ProcessKitConstants;
import suit.SuitInventory.SuitProcess;
import suit.SuitKind;

private typedef Target = {
	var process:SuitProcess;
	/** exosuit-spawned descendants captured before anything was stopped (SuitLineage.exosuitDescendants). */
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
	Stops exosuit's processes the way closing them in the app would. Each kind's SuitStop says how:

	- CloseWindows (editors): asked to close, so they can save or prompt. An editor still open when the
	  grace period ends is left running and reported, never killed with unsaved work.
	- StopRequest (workspace managers): `stop-request.json` in the state directory, the cooperative path a
	  restart uses: the manager stops its daemon, which closes its terminals' PTYs and ConPTY sessions as
	  closing them in the app does, removes its endpoint and releases its lock. Relay hosting ends with it;
	  device grants and relay settings stay on disk, so nothing is revoked.
	- ThroughManager (workspace daemons): stopped through their running manager.
	- Kill: killed at once.

	suit never kills a process tree wholesale. When the grace period ends it kills the target if it still
	runs, and then sweeps: it kills only the target's descendants of kinds exosuit starts itself (a
	workspace daemon, a compiler worker, a live host), reached through such processes alone. A program
	started from a terminal, detached or not, is not one of them, and lives on as it would if the user
	closed that terminal. The target is killed before the sweep, so it cannot start more children after
	the last snapshot; the sweep repeats with a fresh snapshot until one finds nothing left. All targets
	that reach their deadline together share each round's snapshot.

	Every kill re-checks the pid's start time, and a process whose start time is unknown is reported, not
	touched. The job is ticked; it never blocks.
**/
class SuitTerminator {
	public static inline var SERVICE_GRACE_SECONDS:Float = 3;
	public static inline var EDITOR_GRACE_SECONDS:Float = 10;

	/** Snapshot-and-sweep rounds before suit gives up on a tree that keeps spawning. */
	static inline var SWEEP_ROUNDS:Int = 4;

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
				tree: inventory.exosuitDescendants(target.pid, target.started),
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
		var due:Array<Target> = [];
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
			// The target first: once it is gone it cannot start children the sweep's last snapshot misses.
			if (alive)
				Processes.terminate(target.process.pid, target.process.started);
			finish(target, alive ? "killed" : "stopped");
			due.push(target);
		}
		if (due.length > 0)
			sweep(due);
		return finished();
	}

	/** Runs the job to completion; for the CLI, which has no event loop. */
	public function run():Array<TerminationResult> {
		while (!tick())
			Sys.sleep(0.1);
		return results;
	}

	/**
		Kills what exosuit spawned under the targets: those captured at the start, and any a fresh snapshot
		finds under a target or under them. One snapshot per round serves every target. Repeats while a
		round still kills something.
	**/
	function sweep(due:Array<Target>):Void {
		var killed = new Map<String, Bool>();
		for (_ in 0...SWEEP_ROUNDS) {
			var snapshot = Processes.list(SuitInventory.SCANNED_NAMES, SuitLineage.VARIABLES);
			var lineage = snapshot == null ? null : new SuitLineage(snapshot, SuitPaths.home());
			var found:Array<ProcessInfo> = [];
			for (target in due) {
				if (lineage != null) {
					for (child in lineage.exosuitDescendants(target.process.pid, target.process.started, self))
						found.push(child);
					for (captured in target.tree)
						for (child in lineage.exosuitDescendants(captured.pid, captured.started, self))
							found.push(child);
				}
				for (captured in target.tree)
					found.push(captured);
			}
			var progress = false;
			for (child in found) {
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
