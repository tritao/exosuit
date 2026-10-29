package app;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;

/**
	This machine's running workspace managers. Each ready manager writes `managers/<key>.json` beside the default
	state folders and removes it when it stops; `--machine` lists the ones still running, for the editor's Machine view.
	A record only helps discovery: a manager that cannot write one still serves its workspace.
**/
@:access(app.AgentManager)
class AgentMachine {
	static inline var RECORD_LIMIT = 16384;

	/** Records a ready manager. Returns the record's path, or null when none was written. */
	public static function register(base:String, root:String, stateDir:String, generation:String, launcher:String):Null<String> {
		// Temporary state is a test's or a fixture's. With EXOSUIT_AGENT_STATE_HOME set the registry is the caller's own.
		if (AgentManager.nonempty(Sys.getEnv("EXOSUIT_AGENT_STATE_HOME")) == null && suit.SuitClient.underTemp(stateDir))
			return null;
		try {
			var directory = Path.join([base, "managers"]);
			AgentManager.ensureStateDirectory(directory);
			var path = Path.join([directory, AgentManager.pipeKey(root, stateDir) + ".json"]);
			AtomicFile.write(path, Json.stringify({
				version: 1, root: root, stateDir: stateDir, managerPid: Sys.getPid(), generation: generation,
				launcher: launcher, startedAt: Date.now().getTime()
			}) + "\n");
			return path;
		} catch (_:Dynamic) return null;
	}

	/** Removes this manager's record, unless a newer manager for the same state has replaced it. */
	public static function unregister(path:String, generation:String):Void {
		try {
			if (!FileSystem.exists(path) || !AgentManagerNative.privateFile(path)) return;
			if (AgentManager.stringField(Json.parse(File.getContent(path)), "generation") == generation) FileSystem.deleteFile(path);
		} catch (_:Dynamic) {}
	}

	/**
		`--machine`: prints this machine's name, the launcher answering, the state base its folders live in, and every
		running manager as JSON. Managers
		from before the registry are found through their default state folder; stale records are removed.
	**/
	public static function run(arguments:Array<String>):Int {
		try {
			if (arguments.length != 0) throw "Usage: exosuit-agent.hl --machine";
			AgentManagerNative.setPrivateUmask();
			var base = AgentManager.stateBase(), managers:Array<Dynamic> = [], seen = new Map<String, Bool>();
			var registry = Path.join([base, "managers"]);
			if (FileSystem.exists(registry) && AgentManagerNative.privateDirectory(registry)) {
				for (name in FileSystem.readDirectory(registry)) {
					if (!StringTools.endsWith(name, ".json")) continue;
					var path = Path.join([registry, name]);
					try {
						var record = AgentManager.readPrivateJson(path, RECORD_LIMIT);
						var root = AgentManager.stringField(record, "root"), stateDir = AgentManager.stringField(record, "stateDir");
						if (AgentManager.intField(record, "version") != 1 || root == "" || stateDir == "") continue;
						var endpoint = AgentManager.readDiscovery(stateDir, root);
						if (endpoint == null || AgentManager.stringField(endpoint, "generation") != AgentManager.stringField(record, "generation")) {
							FileSystem.deleteFile(path);
							continue;
						}
						var startedAt:Dynamic = Reflect.field(record, "startedAt");
						managers.push(entry(base, root, stateDir, endpoint, AgentManager.stringField(record, "launcher"),
							Std.isOfType(startedAt, Float) || Std.isOfType(startedAt, Int) ? startedAt : null));
						seen.set(stateDir, true);
					} catch (_:Dynamic) {}
				}
			}
			var workspaces = Path.join([base, "workspaces"]);
			if (FileSystem.exists(workspaces) && FileSystem.isDirectory(workspaces)) {
				for (name in FileSystem.readDirectory(workspaces)) {
					var stateDir = AgentManager.absoluteStatePath(Path.join([workspaces, name]));
					if (seen.exists(stateDir) || !FileSystem.isDirectory(stateDir)) continue;
					try {
						var root = AgentManager.stringField(AgentManager.readPrivateJson(Path.join([stateDir, "workspace.json"]), RECORD_LIMIT), "root");
						var endpoint = root == "" ? null : AgentManager.readDiscovery(stateDir, root);
						if (endpoint != null) managers.push(entry(base, root, stateDir, endpoint, AgentManager.stringField(endpoint, "launcher"), null));
					} catch (_:Dynamic) {}
				}
			}
			Sys.println(Json.stringify({version: 1, machine: machineName(), launcher: AgentManager.managerBytecode(), stateBase: base,
				managers: managers}));
			Sys.stdout().flush();
			return 0;
		} catch (error:Dynamic) {
			Sys.stderr().writeString("Machine listing failed: " + Std.string(error) + "\n");
			Sys.stderr().flush();
			return 1;
		}
	}

	static function entry(base:String, root:String, stateDir:String, endpoint:Dynamic, launcher:String, startedAt:Null<Float>):Dynamic {
		var defaultState = AgentManager.absoluteStatePath(Path.join([base, "workspaces", Sha256.encode(root).substr(0, 20)]));
		return {
			root: root, stateDir: stateDir, defaultState: stateDir == defaultState,
			managerPid: AgentManager.intField(endpoint, "managerPid"), generation: AgentManager.stringField(endpoint, "generation"),
			launcher: launcher, startedAt: startedAt
		};
	}

	/** The name people know this machine by: lower case on Windows, whose COMPUTERNAME is upper case. */
	static function machineName():String {
		if (Sys.systemName() == "Windows") {
			var name = AgentManager.nonempty(Sys.getEnv("COMPUTERNAME"));
			return name == null ? "this machine" : name.toLowerCase();
		}
		var name = AgentManager.nonempty(Sys.getEnv("HOSTNAME"));
		if (name == null) try name = AgentManager.nonempty(StringTools.trim(File.getContent("/etc/hostname"))) catch (_:Dynamic) {}
		return name == null ? "this machine" : name;
	}
}
