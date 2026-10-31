package workspace.client;

import process.OwnedProcess;
import process.ProcessManager;

/** What the starter needs of a launched service process; the default wraps an OwnedProcess, tests supply their own. */
interface StartedProcess {
	function running():Bool;
	function exitStatus():Int;
	function readStdout():String;
	function readStderr():String;
	function release():Void;
}

private class OwnedStarted implements StartedProcess {
	final processes:ProcessManager;
	final process:OwnedProcess;

	public function new(processes:ProcessManager, process:OwnedProcess) {
		this.processes = processes;
		this.process = process;
	}

	public function running():Bool return process.running();

	public function exitStatus():Int return process.exitStatus();

	public function readStdout():String return process.readStdout();

	public function readStderr():String return process.readStderr();

	public function release():Void processes.release(process);
}

private typedef Start = {
	var process:Null<StartedProcess>;
	var target:WorkspaceServiceTarget;
	var done:Null<String>->Void;
	var deadline:Float;
	var retryAt:Float;
	var errors:String;
	/** Launched at least once, so it holds a slot between BUSY retries. */
	var launched:Bool;
}

/**
	Starts a workspace's service without attaching to it (`--manager --workspace ID ... --detach`), so an idle
	workspace's catalog can appear in the tree when the user expands it. One start per workspace at a time, and at most
	MAX_CONCURRENT processes launched at once: expanding many idle workspaces queues the rest. The service then runs on its own,
	like any other, and suit reports it. The launch call (`processes.start`, a CreateProcess) runs on the frame that polls;
	`slowestLaunch` records the longest it blocked.
**/
class WorkspaceStarter {
	static inline final TIMEOUT = 95000.0;
	static inline final BUSY = 3;
	/** Service processes launched at once; further starts wait their turn. */
	public static inline final MAX_CONCURRENT = 2;

	final processes:Null<ProcessManager>;
	final launcher:String;
	final clock:Void->Float;
	final environment:Null<Map<String, String>>;
	final spawn:Null<(WorkspaceServiceTarget, String)->StartedProcess>;
	final starts:Map<String, Start> = [];
	/** Starts in the order they were asked for; a start launches when fewer than MAX_CONCURRENT run. */
	final order:Array<Start> = [];
	/** The longest the launch call (CreateProcess) blocked the caller, in seconds: it runs on the frame that polls. */
	public var slowestLaunch(default, null):Float = 0;

	public function new(processes:Null<ProcessManager>, launcher:String, clock:Void->Float, ?environment:Map<String, String>,
			?spawn:(WorkspaceServiceTarget, String)->StartedProcess) {
		this.spawn = spawn;
		this.processes = processes;
		this.launcher = launcher;
		this.clock = clock;
		this.environment = environment;
	}

	public function starting(workspace:String):Bool
		return starts.exists(workspace);

	/** Starts the service of `target`'s workspace; `done` gets null once it runs, else why it did not. */
	public function start(target:WorkspaceServiceTarget, done:Null<String>->Void):Void {
		if (starts.exists(target.workspace))
			return;
		var entry:Start = {
			process: null,
			target: target,
			done: done,
			deadline: 0,
			retryAt: 0,
			errors: "",
			launched: false
		};
		starts.set(target.workspace, entry);
		order.push(entry);
	}

	/**
		Drops a start that has not launched yet (the user collapsed the workspace, or left it); `done` gets null, as nothing failed.
		A start already launched runs on: the service is detached and suit will report it. True when a queued start was dropped.
	**/
	public function cancel(workspace:String):Bool {
		var entry = starts.get(workspace);
		if (entry == null || entry.launched)
			return false;
		finish(entry, null);
		return true;
	}

	/** Workspaces waiting for a free slot. */
	public function queued():Int {
		var waiting = 0;
		for (entry in order)
			if (entry.process == null && !entry.launched)
				waiting++;
		return waiting;
	}

	function launch(entry:Start):Void {
		var root = entry.target.root();
		if (root == null) {
			finish(entry, "This workspace has no folder yet.");
			return;
		}
		entry.launched = true;
		var began = Sys.time();
		try {
			var arguments = [launcher].concat(entry.target.managerArguments());
			var chosen = WorkspaceManagerChoices.instance().stateFor(entry.target.choiceKey());
			if (chosen != null) {
				arguments.push("--state-dir");
				arguments.push(chosen);
			}
			arguments.push("--detach");
			arguments.push("--wire");
			entry.errors = "";
			var make = spawn, manager = processes;
			if (make != null)
				entry.process = make(entry.target, root);
			else if (manager != null)
				entry.process = new OwnedStarted(manager, manager.start(Sys.executablePath(), arguments, root, LocalWorkspaceClient.agentEnvironment(launcher, environment)));
			else
				throw "No process manager";
		} catch (failure:Dynamic)
			finish(entry, Std.string(failure));
		slowestLaunch = Math.max(slowestLaunch, Sys.time() - began);
	}

	function finish(entry:Start, failure:Null<String>):Void {
		starts.remove(entry.target.workspace);
		order.remove(entry);
		var process = entry.process;
		entry.process = null;
		if (process != null)
			process.release();
		entry.done(failure);
	}

	/** Collects finished starts; call every frame. */
	public function poll():Void {
		if (order.length == 0)
			return;
		var now = clock();
		var slots = 0;
		for (entry in order)
			if (entry.launched)
				slots++;
		for (entry in order.copy()) {
			var process = entry.process;
			if (process == null) {
				if (entry.launched) {
					if (now >= entry.retryAt)
						launch(entry);
				} else if (slots < MAX_CONCURRENT) {
					slots++;
					entry.deadline = now + TIMEOUT;
					launch(entry);
				}
				continue;
			}
			entry.errors += process.readStderr();
			process.readStdout();
			if (now >= entry.deadline) {
				finish(entry, "The workspace service did not start in time");
				continue;
			}
			if (process.running())
				continue;
			entry.errors += process.readStderr();
			var code = process.exitStatus();
			if (code == 0)
				finish(entry, null);
			else if (code == BUSY) {
				// Another client is starting it; ask again shortly.
				entry.process = null;
				process.release();
				entry.retryAt = now + 250;
			} else
				finish(entry, entry.errors.length > 0 ? StringTools.trim(entry.errors) : "The workspace service did not start");
		}
	}
}
