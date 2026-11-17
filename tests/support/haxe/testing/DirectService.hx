package testing;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import workspace.client.OpenedService;
import workspace.client.WorkspaceServiceTarget;

/**
	A workspace service for a test program without exohost: `open` starts the agent bytecode `launcher` the way exohost does
	(`--workspace ID --folder F...`, detached) and answers with the pipe and generation its `service.log` names. A
	service already running for the workspace (the start exits 3, the lock is held) is answered from the same log.
	The state is under EXOSUIT_AGENT_STATE_HOME and exohost's home is EXOSUIT_EXOHOST_HOME, both of which the test's driver sets.
**/
class DirectService {
	static inline final IN_USE = 3;
	static inline final START_SECONDS = 60.0;

	public final launcher:String;
	final targets:Map<String, WorkspaceServiceTarget> = [];

	/** Refuses to run without EXOSUIT_AGENT_STATE_HOME and EXOSUIT_EXOHOST_HOME: without them a service would keep its state in
		the user's own folder (%LOCALAPPDATA%\Exosuit, ~/.local/state/exosuit) and report to the user's exohost. **/
	public function new(launcher:String) {
		for (name in ["EXOSUIT_AGENT_STATE_HOME", "EXOSUIT_EXOHOST_HOME"]) {
			var value = Sys.getEnv(name);
			if (value == null || value.length == 0) throw name + " is not set: a test service needs state of its own (scripts/test_driver.py)";
		}
		this.launcher = FileSystem.fullPath(launcher);
	}

	/** The test workspace of folder `root`: its id is derived from the folder, so every run of a test finds the same one. */
	public function forRoot(root:String):WorkspaceServiceTarget
		return forWorkspace(idOf(root), [root], null);

	public function forWorkspace(id:String, folders:Array<String>, scratch:Null<String>):WorkspaceServiceTarget {
		var target = WorkspaceServiceTarget.forWorkspace(id, folders, scratch);
		targets.set(id, target);
		return target;
	}

	/** "test-" and the first 16 hex digits of the SHA-256 of `root` as spelled (scripts/test_driver.py `workspace_id`). */
	public static function idOf(root:String):String
		return "test-" + haxe.crypto.Sha256.encode(root).substr(0, 16);

	/** The state folder of workspace `id`, as the agent's AgentState names it. */
	public static function stateOf(id:String):String
		return Path.join([exohost.MachineCatalog.agentStateBase(), "workspaces", id]);

	/** A ServiceOpener. It blocks while the service starts: test programs have nothing else to do meanwhile. */
	public function open(id:String, done:(Null<OpenedService>, Null<String>) -> Void):Void {
		var target = targets.get(id);
		if (target == null) { done(null, "unknown test workspace " + id); return; }
		var log = Path.join([stateOf(id), "service.log"]);
		var before = FileSystem.exists(log) ? File.getContent(log).length : 0;
		var child = sys.io.Process.spawn(Sys.executablePath(), [launcher].concat(target.serviceArguments()), target.root(),
			[exohost.ExohostClient.libraryVariable()], [exohost.ExohostClient.nativePath(launcher)], true);
		var deadline = Sys.time() + START_SECONDS;
		while (Sys.time() < deadline) {
			// Negative while it runs (ChildProcess.pollExit).
			var status = child.pollExit();
			if (status != null && status >= 0 && status != IN_USE) {
				child.close();
				done(null, "the test service exited with " + status);
				return;
			}
			var found = ready(log, status == IN_USE ? 0 : before);
			if (found != null) {
				child.close();
				done(found, null);
				return;
			}
			Sys.sleep(0.02);
		}
		child.close();
		done(null, "the test service did not start in " + START_SECONDS + " s");
	}

	/** The last service that got ready in `log` after offset `from`, with the generation it started with. */
	static function ready(log:String, from:Int):Null<OpenedService> {
		if (!FileSystem.exists(log)) return null;
		var text = File.getContent(log);
		if (text.length <= from) return null;
		var generation:Null<String> = null;
		var found:Null<OpenedService> = null;
		for (line in text.substr(from).split("\n")) {
			var starting = line.indexOf("service starting: generation ");
			if (starting >= 0) {
				generation = line.substr(starting + "service starting: generation ".length).split(",")[0];
				found = null;
			}
			var at = line.indexOf("service ready on ");
			if (at >= 0 && generation != null) {
				var rest = StringTools.trim(line.substr(at + "service ready on ".length));
				var split = rest.indexOf(" for ");
				if (split > 0) found = {endpoint: rest.substr(0, split), generation: generation, root: rest.substr(split + 5)};
			}
			if (line.indexOf("service stopped") >= 0) found = null;
		}
		return found;
	}
}
