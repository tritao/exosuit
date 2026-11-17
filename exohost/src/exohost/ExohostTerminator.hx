package exohost;

import processkit.Processes;
import processkit.ffi.ProcessKitConstants;
import exohost.ExohostInventory.ExohostProcess;
import exohost.ExohostKind;

private typedef Target = {
	var process:ExohostProcess;
	/** exosuit-spawned descendants captured before anything was stopped (ExohostLineage.exosuitDescendants). */
	var tree:Array<ProcessInfo>;
	/**
		Its whole OS tree captured before anything was stopped (ExohostProcessTree), deepest first: for a kind that ends its
		tree (ExohostKinds.endsTree), and for a terminal host, whose tree is used only when the host has to be killed. Empty
		for every other target. Captured first because a process killed or exited breaks the parent links a later
		snapshot would follow.
	**/
	var whole:Array<ProcessInfo>;
	/** Set when the target is done: true when its sweep ends its whole tree (`whole`, and what a fresh snapshot finds below). */
	var endsTree:Bool;
	var deadline:Float;
	var forceAtDeadline:Bool;
	var done:Bool;
	/**
		The editors running under it when the stop began, for a kind that hosts editors (ExohostKinds.hostsEditors): its
		stop starts once they are gone. Empty for every other target.
	**/
	var hosted:Array<ExohostProcess>;
}

/** What happened to one terminated process. */
typedef TerminationResult = {
	var pid:Int;
	var kind:ExohostKind;
	var outcome:String;
}

/**
	Stops exosuit's processes the way closing them in the app would. Each kind's ExohostStop says how:

	- QuitRequest (editors): asked over their exohost link to quit (`ask`), so they save first. An editor still
	  open when the grace period ends is left running and reported, never killed with unsaved work.
	- ServiceStop (workspace services): asked over their exohost link to stop (`ask`). The service ends its agent processes
	  and releases its lock; its terminals carry on in their hosts.
	- Kill: killed at once. Terminal hosts too, which closes their pseudoconsoles; the sweep then ends their programs'
	  trees. Hosts are stopped only when chosen: stopping a service never reaches its hosts, which are not of a kind
	  the sweep follows.

	When the grace period ends exohost kills the target if it still runs, and then sweeps. For a kind that ends its tree
	(ExohostKinds.endsTree: an agent provider, a workspace service, a live session, a worker...) the sweep ends its whole OS
	process tree (ExohostProcessTree), whether the target was killed or stopped by itself: what an agent started (MCP
	servers, tool commands, a dev server) ends with it. Editors, what an editor runs under, and terminal hosts with
	everything below them are never part of that tree. A terminal host chosen for the stop is killed and swept: its
	program and what that started end with it. For every target the sweep also kills the descendants of kinds exosuit starts itself, reached through such
	processes alone (ExohostLineage). The tree is captured when the stop begins, since a process that has exited no longer
	links its children to the target; the target is killed before the sweep, so it cannot start more children after the
	last snapshot; the sweep repeats with a fresh snapshot until one finds nothing left. All targets that reach their
	deadline together share each round's snapshot.

	Every kill re-checks the pid's start time, and a process whose start time is unknown is reported, not
	touched. The job is ticked; it never blocks.
**/
class ExohostTerminator {
	public static inline var SERVICE_GRACE_SECONDS:Float = 3;
	public static inline var EDITOR_GRACE_SECONDS:Float = 10;

	/** Snapshot-and-sweep rounds before exohost gives up on a tree that keeps spawning. */
	static inline var SWEEP_ROUNDS:Int = 4;

	final targets:Array<Target> = [];
	public final results:Array<TerminationResult> = [];
	final self:Int;
	/** The editors running when the stop began: never swept, and waited for by the kinds that host them. */
	final editors:Array<ExohostProcess>;
	/** Compiler workers a build exosuit did not start uses (ExohostProcess.shared): never swept, as no bulk stop ends them. */
	final shared:Array<ExohostProcess>;
	final ask:ExohostProcess->Bool;

	/**
		`ask` asks an editor to quit, or a workspace service to stop, over its link to exohost, and returns false when it has
		none: the daemon asks directly, the CLI through the daemon, which holds the links (`askThroughDaemon`).
	**/
	public function new(inventory:ExohostInventory, processes:Array<ExohostProcess>, ask:ExohostProcess->Bool) {
		this.ask = ask;
		var now = Sys.time();
		var chosen = new Map<Int, Bool>();
		self = Sys.getPid();
		editors = inventory.editors();
		shared = inventory.shared();
		var whole = new ExohostProcessTree(inventory.snapshot, isEditor);
		for (process in processes) {
			var target = process;
			if (target.pid == self || chosen.exists(target.pid))
				continue;
			chosen.set(target.pid, true);
			if (target.started <= 0) {
				results.push({pid: target.pid, kind: target.kind, outcome: "not stopped: its start time is unknown"});
				continue;
			}
			var strategy = ExohostKinds.stop(target.kind);
			var hosted = ExohostKinds.hostsEditors(target.kind) ? inventory.hostedEditors(target.pid, target.started) : [];
			var waits = hosted.length > 0;
			var graceful = !waits && requestStop(target, strategy);
			targets.push({
				process: target,
				tree: inventory.exosuitDescendants(target.pid, target.started),
				whole: ExohostKinds.endsTree(target.kind) || target.kind == ExohostKind.TerminalHost ? whole.descendants(target.pid, target.started, self) : [],
				endsTree: false,
				deadline: waits ? Math.POSITIVE_INFINITY : now + (graceful ? (strategy == QuitRequest ? EDITOR_GRACE_SECONDS : SERVICE_GRACE_SECONDS) : 0.0),
				forceAtDeadline: strategy != QuitRequest,
				done: false,
				hosted: hosted
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
		releaseEditorHosts(now);
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
			// A terminal host that ended by itself (its program ended) leaves nothing below it that is exohost's to end. One
			// exohost kills takes its program's tree with it.
			target.endsTree = ExohostKinds.endsTree(target.process.kind) || (alive && target.process.kind == ExohostKind.TerminalHost);
			if (!target.endsTree)
				target.whole = [];
			finish(target, alive ? "killed" : "stopped");
			due.push(target);
		}
		if (due.length > 0)
			sweep(due);
		return finished();
	}

	/**
		Starts the stop of a target that hosts editors (a live session, `scripts/run.py`, a terminal host with the editor
		running under them) once the editors under it have exited: its graceful stop is requested then (a session ends by
		itself when its editor exits; a terminal host is killed at once), and it has the service grace period before it is
		killed. While one of them is still open once every other target is done (one kept open over unsaved work, or one
		this stop did not choose), it is left running, so that editor keeps its session.
	**/
	function releaseEditorHosts(now:Float):Void {
		var waiting = [for (target in targets) if (!target.done && target.hosted.length > 0 && target.deadline == Math.POSITIVE_INFINITY) target];
		if (waiting.length == 0)
			return;
		var othersDone = true;
		for (target in targets)
			if (!target.done && target.hosted.length == 0)
				othersDone = false;
		for (target in waiting) {
			var open = false;
			for (editor in target.hosted)
				if (Processes.alive(editor.pid, editor.started))
					open = true;
			if (!open) {
				var graceful = requestStop(target.process, ExohostKinds.stop(target.process.kind));
				target.deadline = now + (graceful || target.process.kind != ExohostKind.TerminalHost ? SERVICE_GRACE_SECONDS : 0.0);
			} else if (othersDone)
				finish(target, "left running: an editor it hosts is still open");
		}
	}

	/** Runs the job to completion; for the CLI, which has no event loop. */
	public function run():Array<TerminationResult> {
		while (!tick())
			Sys.sleep(0.1);
		return results;
	}

	/**
		Kills what exosuit spawned under the targets, and the whole tree of each target that ends its tree: those captured
		at the start, and any a fresh snapshot finds under a target or under them, deepest first. One snapshot per round
		serves every target. Repeats while a round still kills something.
	**/
	function sweep(due:Array<Target>):Void {
		var killed = new Map<String, Bool>();
		for (_ in 0...SWEEP_ROUNDS) {
			var snapshot = Processes.list(ExohostInventory.SCANNED_NAMES, ExohostLineage.VARIABLES);
			var lineage = snapshot == null ? null : new ExohostLineage(snapshot, ExohostPaths.home());
			var trees = snapshot == null ? null : new ExohostProcessTree(snapshot, isEditor);
			var found:Array<ProcessInfo> = [];
			for (target in due) {
				if (target.endsTree) {
					if (trees != null) {
						for (child in trees.descendants(target.process.pid, target.process.started, self))
							found.push(child);
						for (captured in target.whole)
							for (child in trees.descendants(captured.pid, captured.started, self))
								found.push(child);
					}
					for (captured in target.whole)
						found.push(captured);
				}
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
				if (killed.exists(key) || isEditor(child) || isShared(child) || !Processes.alive(child.pid, child.started))
					continue;
				killed.set(key, true);
				if (Processes.terminate(child.pid, child.started) == ProcessKitConstants.PROCESSKIT_OK)
					progress = true;
			}
			if (!progress)
				return;
		}
	}

	/** An editor is closed, never killed, even when it runs as a live host under a session being stopped. */
	function isEditor(child:ProcessInfo):Bool {
		for (editor in editors)
			if (editor.pid == child.pid && editor.started == child.started)
				return true;
		return false;
	}

	function isShared(child:ProcessInfo):Bool {
		for (worker in shared)
			if (worker.pid == child.pid && worker.started == child.started)
				return true;
		return false;
	}

	function finish(target:Target, outcome:String):Void {
		target.done = true;
		results.push({pid: target.process.pid, kind: target.process.kind, outcome: outcome});
	}


	/** Starts a graceful stop. Returns false when there is none and the process must simply be killed. */
	function requestStop(process:ExohostProcess, strategy:ExohostStop):Bool {
		switch strategy {
			case QuitRequest | ServiceStop:
				return ask(process);
			case Kill:
				return false;
		}
	}

	/** Asks the running daemon, which holds the links, to quit an editor (`editor-quit`) or stop a service (`service-stop`). */
	public static function askThroughDaemon(process:ExohostProcess):Bool {
		var reply = ExohostControl.request(process.kind == ExohostKind.Editor ? {op: "editor-quit", pid: process.pid, mode: "prompt"}
			: {op: "service-stop", pid: process.pid});
		return reply != null && Reflect.field(reply, "ok") == true;
	}
}
