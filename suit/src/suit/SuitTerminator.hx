package suit;

import haxe.Json;
import haxe.io.Path;
import processkit.Processes;
import processkit.Processes.ProcessInfo;
import suit.SuitInventory.SuitProcess;

private typedef Target = {
	var process:SuitProcess;
	var tree:Array<ProcessInfo>;
	var deadline:Float;
	var forceAtDeadline:Bool;
	var done:Bool;
}

/** What happened to one terminated process. */
typedef TerminationResult = {
	var pid:Int;
	var kind:String;
	var outcome:String;
}

/**
	Stops processes the way suit's menu and CLI promise: gracefully first, then the whole tree.

	- A workspace manager gets `stop-request.json` in its state directory, the same cooperative path as a
	  restart request: it stops its daemon, removes its endpoint and releases its lock. Relay hosting
	  ends with it; device grants and relay settings stay on disk, so nothing is revoked.
	- A workspace daemon is stopped through its manager when the manager is running.
	- An editor is asked to close its windows, so it can save or prompt. An editor that is still open
	  when the grace period ends is left running and reported, never killed with unsaved work.
	- Everything else is killed with its descendants at once.

	After the grace period, whatever remains of each tree (captured before anything was stopped) is killed
	deepest first. Every kill re-checks the pid's start time. The job is ticked; it never blocks.
**/
class SuitTerminator {
	public static inline var SERVICE_GRACE_SECONDS:Float = 3;
	public static inline var EDITOR_GRACE_SECONDS:Float = 10;

	final targets:Array<Target> = [];
	public final results:Array<TerminationResult> = [];

	public function new(inventory:SuitInventory, processes:Array<SuitProcess>) {
		var now = Sys.time();
		var chosen = new Map<Int, Bool>();
		var self = Sys.getPid();
		for (process in processes) {
			var target = process;
			// Stop a daemon through its running manager, so the manager does not restart or outlive it.
			if (process.kind == "workspace-host") {
				var manager = inventory.find(process.parent);
				if (manager != null && manager.kind == "workspace-manager")
					target = manager;
			}
			if (target.pid == self || chosen.exists(target.pid))
				continue;
			chosen.set(target.pid, true);
			var graceful = requestStop(target);
			targets.push({
				process: target,
				tree: inventory.descendants(target.pid),
				deadline: now + (graceful ? (target.kind == "editor" ? EDITOR_GRACE_SECONDS : SERVICE_GRACE_SECONDS) : 0.0),
				forceAtDeadline: target.kind != "editor",
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
			// Kill what is left of the tree, deepest first, then the process itself.
			for (child in target.tree)
				Processes.terminate(child.pid, child.started);
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

	function finish(target:Target, outcome:String):Void {
		target.done = true;
		results.push({pid: target.process.pid, kind: target.process.kind, outcome: outcome});
	}

	/** Starts a graceful stop when the process kind has one. Returns false when it must simply be killed. */
	static function requestStop(process:SuitProcess):Bool {
		switch process.kind {
			case "editor":
				return Processes.requestClose(process.pid, process.started) == processkit.ffi.ProcessKitConstants.PROCESSKIT_OK;
			case "workspace-manager":
				if (process.stateDir == null || process.generation == null)
					return false;
				try {
					sys.io.AtomicFile.write(Path.join([process.stateDir, "stop-request.json"]),
						Json.stringify({version: 1, generation: process.generation}) + "\n");
					return true;
				} catch (_:Dynamic) {
					return false;
				}
			default:
				return false;
		}
	}
}
