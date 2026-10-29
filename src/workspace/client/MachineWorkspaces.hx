package workspace.client;

import process.OwnedProcess;
import process.ProcessManager;

/** One running workspace manager on this machine, as `--machine` reports it. */
typedef MachineManager = {
	var root:String;
	var stateDir:String;
	/** On the folder's default state, the one an editor attaches to unless told otherwise. */
	var defaultState:Bool;
	var managerPid:Int;
	var generation:String;
	/** Its launcher; empty for a manager from before launchers were reported. */
	var launcher:String;
	/** When it started, in milliseconds since the epoch; null when not recorded. */
	var startedAt:Null<Float>;
}

typedef MachineListing = {
	var machine:String;
	/** The launcher that answered: this editor's own. */
	var launcher:String;
	/** The folder holding the default state folders, `workspaces/<hash>`. */
	var stateBase:String;
	var managers:Array<MachineManager>;
}

/** This machine's running workspace managers, refreshed in the background with the agent's `--machine`. */
class MachineWorkspaces {
	final processes:ProcessManager;
	final launcher:String;
	final clock:Void->Float;
	final environment:Null<Map<String, String>>;
	var helper:Null<OwnedProcess>;
	var output = "";
	var errors = "";
	var deadline:Float = 0;
	var nextRefresh:Float = 0;

	public var listing(default, null):Null<MachineListing>;
	public var error(default, null):Null<String>;
	/** Changes whenever the listing or error does. */
	public var revision(default, null):Int = 0;

	public function new(processes:ProcessManager, launcher:String, clock:Void->Float, ?environment:Map<String, String>) {
		this.processes = processes;
		this.launcher = launcher;
		this.clock = clock;
		this.environment = environment;
	}

	/** Lists again now, unless a listing is already running. */
	public function refresh():Void {
		if (helper != null) return;
		output = "";
		errors = "";
		try {
			helper = processes.start(Sys.executablePath(), [launcher, "--machine"], Sys.getCwd(),
				LocalWorkspaceClient.agentEnvironment(launcher, environment));
			deadline = clock() + 20000;
		} catch (failure:Dynamic) finish(null, Std.string(failure));
	}

	/** Collects a finished listing; with `every` milliseconds, also starts the next one when due. */
	public function poll(every:Float = 0):Void {
		var process = helper;
		if (process == null) {
			if (every > 0 && clock() >= nextRefresh) refresh();
			return;
		}
		output += process.readStdout();
		errors += process.readStderr();
		if (output.length > 1048576 || clock() >= deadline) {
			stop();
			finish(null, "Listing this machine's workspaces took too long");
			return;
		}
		if (process.running()) return;
		output += process.readStdout();
		errors += process.readStderr();
		var code = process.exitStatus();
		stop();
		if (code != 0) {
			finish(null, errors.length > 0 ? StringTools.trim(errors) : "Could not list this machine's workspaces");
			return;
		}
		try finish(parse(output), null) catch (failure:Dynamic) finish(null, Std.string(failure));
		nextRefresh = clock() + every;
	}

	public function dispose():Void stop();

	function stop():Void {
		var process = helper;
		helper = null;
		if (process != null) processes.release(process);
	}

	function finish(value:Null<MachineListing>, failure:Null<String>):Void {
		if (value != null) listing = value;
		error = failure;
		revision++;
	}

	/** Validates `--machine` output. */
	public static function parse(source:String):MachineListing {
		var value:Dynamic = haxe.Json.parse(source);
		if (value == null || Reflect.field(value, "version") != 1) throw "Unsupported machine listing";
		var entries:Dynamic = Reflect.field(value, "managers");
		if (!Std.isOfType(entries, Array)) throw "Invalid machine listing";
		var managers:Array<MachineManager> = [];
		for (entry in (entries : Array<Dynamic>)) {
			var root = text(entry, "root"), stateDir = text(entry, "stateDir");
			if (root.length == 0 || stateDir.length == 0) continue;
			var pid:Dynamic = Reflect.field(entry, "managerPid"), started:Dynamic = Reflect.field(entry, "startedAt");
			managers.push({
				root: root, stateDir: stateDir, defaultState: Reflect.field(entry, "defaultState") == true,
				managerPid: Std.isOfType(pid, Int) ? pid : 0, generation: text(entry, "generation"), launcher: text(entry, "launcher"),
				startedAt: Std.isOfType(started, Float) || Std.isOfType(started, Int) ? started : null
			});
		}
		return {machine: text(value, "machine"), launcher: text(value, "launcher"), stateBase: text(value, "stateBase"), managers: managers};
	}

	static function text(value:Dynamic, field:String):String {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) ? result : "";
	}

	/**
		The state folder a manager on `launcher`'s build uses for `root` when the editor starts its own: beside the
		folder's default state, keyed by the launcher too, so each build tree keeps its own.
	**/
	public static function ownState(listing:MachineListing, root:String, launcher:String):String {
		// Never a relative folder, which would land inside the workspace: an agent too old to report its base cannot do this.
		if (!haxe.io.Path.isAbsolute(listing.stateBase)) throw "Update this editor's workspace agent to start a service on its build";
		var key = haxe.crypto.Sha256.encode(root).substr(0, 20) + "-" + launcherKey(launcher);
		return haxe.io.Path.join([listing.stateBase, "workspaces", key]);
	}

	/** Names a launcher's own state folders, so a client knows which ones its build may start a manager on. */
	public static function launcherKey(launcher:String):String return haxe.crypto.Sha256.encode(normalPath(launcher)).substr(0, 8);

	/** A path in one spelling for comparison: forward slashes, and lower case on Windows. */
	public static function normalPath(path:String):String {
		var value = StringTools.replace(path, "\\", "/");
		return Sys.systemName() == "Windows" ? value.toLowerCase() : value;
	}

	/**
		A short name for the build a launcher belongs to: a worktree's name, "this editor's build", or the checkout's
		folder name.
	**/
	public static function buildLabel(launcher:String, editorLauncher:String):String {
		if (launcher.length == 0) return "older build";
		if (normalPath(launcher) == normalPath(editorLauncher)) return "this editor's build";
		var parts = normalPath(launcher).split("/"), original = StringTools.replace(launcher, "\\", "/").split("/");
		var worktrees = parts.indexOf("worktrees");
		if (worktrees > 0 && worktrees + 1 < parts.length && parts[worktrees - 1] == ".claude") return original[worktrees + 1] + " build";
		var agent = parts.lastIndexOf("agent");
		return agent > 0 ? original[agent - 1] + " build" : "another build";
	}
}
