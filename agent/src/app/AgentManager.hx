package app;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.ChildProcess;
import sys.io.File;

private typedef ManagerOptions = {
	/** Whose state this is: a workspace's id and folders, or (before M19 Phase 4) one folder. */
	var identity:AgentStateIdentity;
	/** The folder the service starts in: the folder, or the workspace's first folder or scratch folder. */
	var root:String;
	var stateDir:Null<String>;
	var port:Int;
	var idleSeconds:Int;
	var alwaysAvailable:Bool;
	var discover:Bool;
	var configureRelay:Null<String>;
	var prepareUpdate:Bool;
	var restart:Bool;
	var expectedGeneration:Null<String>;
	var detach:Bool;
	var background:Bool;
	var wire:Bool;
	var generation:Null<String>;
	var seedFrom:Null<String>;
	var restoreMigration:Bool;
}

/** Exosuit workspace daemon supervisor and discovery launcher. */
class AgentManager {
	static final DISCOVERY_FIELDS = ["version", "protocol", "codec", "workspace", "root", "managerPid", "generation", "socket", "websocket", "credentialFile", "expectedBuild", "launcher", "workspaceId"];
	static final MAX_OUTPUT_LINE = 1048576;

	public static function run(arguments:Array<String>):Int {
		try {
			AgentManagerNative.setPrivateUmask();
			var options = parse(arguments);
			var directory = stateDirectory(options);
			var key = options.identity.key();
			if (options.configureRelay != null) {
				var endpoint = existingWorkspace(directory, key);
				configureRelay(directory, options.configureRelay);
				emitDiscovery(endpoint, options.wire);
				return 0;
			}
			if (options.prepareUpdate) {
				var endpoint = existingWorkspace(directory, key);
				prepareUpdate(directory, options.root);
				emitDiscovery(endpoint, options.wire);
				return 0;
			}
			if (options.restart) {
				var endpoint = existingWorkspace(directory, key);
				var previousGeneration = stringField(endpoint, "generation");
				if (previousGeneration != options.expectedGeneration)
					throw "Workspace service changed; refresh before restarting";
				prepareUpdate(directory, options.root);
				var managerRestartsItself = restartManager(directory, key, options.expectedGeneration);
				if (managerRestartsItself) {
					var restarted = waitForNewWorkspace(directory, key, previousGeneration);
					emitDiscovery(restarted, options.wire);
					return 0;
				}
				return startDetached(options, directory);
			}
			if (options.restoreMigration) return restoreMigration(directory, options.identity.workspace);
			if (options.discover) {
				phase("discover begins");
				if (!FileSystem.exists(directory)) return 4;
				if (!AgentManagerNative.privateDirectory(directory))
					throw "Workspace state directory must be private and owned by this user";
				phase("directory private");
				var endpoint = readDiscovery(directory, key);
				if (endpoint == null) return 4;
				emitDiscovery(endpoint, options.wire);
				phase("emitted");
				return 0;
			}
			ensureStateDirectory(directory);
			// Now that it exists, the path takes the folder's own spelling, as the manager started below sees it;
			// the pipe name derives from it, so both must agree.
			directory = absoluteStatePath(directory);
			if (options.detach)
				return startDetached(options, directory);
			return runManaged(options, directory);
		} catch (error:Dynamic) {
			Sys.stderr().writeString("Workspace startup failed: " + Std.string(error) + "\n");
			Sys.stderr().flush();
			return 1;
		}
	}

	static function parse(arguments:Array<String>):ManagerOptions {
		if (arguments.length == 0)
			throw "Usage: exosuit-agent.hl --manager (FOLDER | --workspace ID [--folder FOLDER]... [--scratch FOLDER] | --from-state DIR) "
				+ "[--discover|--detach] [--wire]";
		var workspace:Null<String> = null, root = "", index = 1;
		var folders:Array<String> = [], scratch:Null<String> = null, fromState:Null<String> = null;
		if (arguments[0] == "--workspace") {
			if (arguments.length < 2 || !AgentStateIdentity.validWorkspaceId(arguments[1])) throw "--workspace requires a workspace id";
			workspace = arguments[1];
			index = 2;
		} else if (arguments[0] == "--from-state") {
			// The service whose state this is, as its workspace.json names it: how suit starts a hosted workspace.
			if (arguments.length < 2) throw "--from-state requires a state directory";
			fromState = absoluteStatePath(arguments[1]);
			var recorded = AgentStateIdentity.read(Path.join([fromState, "workspace.json"]));
			if (recorded.migratedTo != null) throw "This state was moved into a workspace";
			workspace = recorded.workspace;
			if (workspace == null) root = directoryArgument(recorded.key());
			index = 2;
		} else {
			root = directoryArgument(arguments[0]);
		}
		var options:ManagerOptions = {
			identity: AgentStateIdentity.forFolder(root), root: root, stateDir: null, port: 0, idleSeconds: 60,
			alwaysAvailable: Sys.getEnv("EXOSUIT_AGENT_ALWAYS_AVAILABLE") == "1",
			discover: false, configureRelay: null, prepareUpdate: false,
			restart: false, expectedGeneration: null,
			detach: false, background: false, wire: false, generation: null, seedFrom: null, restoreMigration: false
		};
		while (index < arguments.length) {
			var value = arguments[index++];
			switch value {
				case "--folder" | "--scratch":
					if (workspace == null || fromState != null) throw '$value requires --workspace';
					if (index >= arguments.length) throw '$value requires a directory';
					var folder = directoryArgument(arguments[index++]);
					if (value == "--scratch") scratch = folder;
					else if (folders.indexOf(folder) < 0) folders.push(folder);
				case "--state-dir":
					if (index >= arguments.length) throw "--state-dir requires a directory";
					if (fromState != null) throw "--from-state names the state directory";
					options.stateDir = absoluteStatePath(arguments[index++]);
				case "--port":
					if (index >= arguments.length) throw "--port requires a value";
					var port = Std.parseInt(arguments[index++]);
					if (port == null || port < 0 || port > 65535) throw "Invalid workspace port";
					options.port = port;
				case "--idle-seconds":
					if (index >= arguments.length) throw "--idle-seconds requires a value";
					var seconds = Std.parseInt(arguments[index++]);
					if (seconds == null || seconds < 1 || seconds > 86400) throw "Invalid idle timeout";
					options.idleSeconds = seconds;
				case "--always-available": options.alwaysAvailable = true;
				case "--seed-from":
					if (index >= arguments.length) throw "--seed-from requires a state directory";
					options.seedFrom = absoluteStatePath(arguments[index++]);
				case "--discover": options.discover = true;
				case "--configure-relay":
					if (index >= arguments.length) throw "--configure-relay requires an origin";
					options.configureRelay = arguments[index++];
				case "--prepare-update": options.prepareUpdate = true;
				case "--restart": options.restart = true;
				case "--expected-generation":
					if (index >= arguments.length) throw "--expected-generation requires a value";
					options.expectedGeneration = arguments[index++];
				case "--detach": options.detach = true;
				case "--restore-migration": options.restoreMigration = true;
				case "--background": options.background = true;
				case "--wire": options.wire = true;
				case "--generation":
					if (index >= arguments.length) throw "--generation requires a value";
					var generation = arguments[index++];
					if (!isHex(generation, 32)) throw "Invalid manager generation";
					options.generation = generation;
				default: throw 'Unknown workspace manager option: $value';
			}
		}
		if (fromState != null) options.stateDir = fromState;
		if (workspace != null) {
			if (folders.length == 0 && scratch == null) {
				// Named by its id alone: the folders it had at its last start, those that still exist.
				var recorded = recordedWorkspace(options.stateDir != null ? options.stateDir : workspaceStateDirectory(workspace), workspace);
				if (recorded != null) {
					folders = [for (folder in recorded.folders) if (FileSystem.exists(folder) && FileSystem.isDirectory(folder)) folder];
					scratch = recorded.scratch;
				}
			}
			options.identity = AgentStateIdentity.forWorkspace(workspace, folders, scratch);
			// Discovery and restoring need no folder: only starting a service does.
			options.root = folders.length > 0 || scratch != null || !options.discover && !options.restoreMigration ? options.identity.primaryRoot() : "";
		}
		var maintenanceModes = (options.configureRelay != null ? 1 : 0) + (options.prepareUpdate ? 1 : 0) + (options.restart ? 1 : 0);
		if (maintenanceModes > 1 || maintenanceModes > 0 && (options.discover || options.detach || options.background))
			throw "Workspace maintenance cannot be combined with another manager mode";
		if (options.restart && options.expectedGeneration == null)
			throw "Restart requires the expected service generation";
		if (!options.restart && options.expectedGeneration != null)
			throw "--expected-generation requires --restart";
		if (options.seedFrom != null && (options.discover || maintenanceModes > 0))
			throw "--seed-from applies only when starting a manager";
		if (options.restoreMigration && (options.identity.workspace == null || maintenanceModes > 0 || options.discover || options.detach
			|| options.background))
			throw "--restore-migration applies only to a workspace, alone";
		if (options.discover && (options.detach || options.background))
			throw "Discovery cannot be combined with manager startup";
		if (options.detach && options.background)
			throw "Detached startup cannot run as a background manager";
		return options;
	}

	/** The identity a workspace's state recorded at its last start, or null when it has none yet. */
	static function recordedWorkspace(directory:String, workspace:String):Null<AgentStateIdentity> {
		var path = Path.join([directory, "workspace.json"]);
		if (!FileSystem.exists(path)) return null;
		var recorded = AgentStateIdentity.read(path);
		if (recorded.workspace != workspace) throw "Workspace state directory identity mismatch";
		return recorded;
	}

	static function directoryArgument(path:String):String {
		var full = FileSystem.fullPath(path);
		if (full == null || !FileSystem.isDirectory(full)) throw 'Workspace folder is not a directory: $path';
		return full;
	}

	static function stateDirectory(options:ManagerOptions):String {
		if (options.stateDir != null) return options.stateDir;
		var workspace = options.identity.workspace;
		return workspace == null ? folderStateDirectory(options.root) : workspaceStateDirectory(workspace);
	}

	/** A folder's default state, before M19 Phase 4: `workspaces/<hash of the folder>`. */
	public static function folderStateDirectory(root:String):String
		return absoluteStatePath(Path.join([stateBase(), "workspaces", Sha256.encode(root).substr(0, 20)]));

	/** A workspace's default state: `workspaces/<workspace id>`. */
	public static function workspaceStateDirectory(workspace:String):String
		return absoluteStatePath(Path.join([stateBase(), "workspaces", workspace]));

	/** The per-user folder holding `workspaces` (each root's default state) and `managers` (this machine's registry). */
	public static function stateBase():String {
		var stateHome = nonempty(Sys.getEnv("EXOSUIT_AGENT_STATE_HOME")), base:String;
		if (stateHome != null) {
			base = stateHome;
		} else if (Sys.systemName() == "Windows") {
			var local = nonempty(Sys.getEnv("LOCALAPPDATA"));
			if (local == null) local = nonempty(Sys.getEnv("APPDATA"));
			if (local == null) local = Path.join([Sys.getEnv("USERPROFILE") == null ? Sys.getCwd() : Sys.getEnv("USERPROFILE"), "AppData", "Local"]);
			base = Path.join([local, "Exosuit"]);
		} else {
			var state = nonempty(Sys.getEnv("XDG_STATE_HOME"));
			var home = nonempty(Sys.getEnv("HOME"));
			if (home == null) home = Sys.getCwd();
			base = Path.join([state == null ? Path.join([home, ".local", "state"]) : state, "exosuit"]);
		}
		return base;
	}

	static function absoluteStatePath(path:String):String {
		// fullPath uses realpath on POSIX, which fails before a new state directory exists.
		// Keep separators identical before and after creation: this path also identifies the socket.
		return Path.normalize(FileSystem.exists(path) ? FileSystem.fullPath(path)
			: Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));
	}

	static function ensureStateDirectory(directory:String):Void {
		var parent = Path.directory(directory);
		if (parent == directory || parent == "") throw "Invalid workspace state path";
		ensureDirectories(parent);
		if (!AgentManagerNative.prepareDirectory(directory))
			throw "Workspace state directory must be private and owned by this user";
	}

	static function ensureDirectories(path:String):Void {
		if (FileSystem.exists(path)) {
			if (!FileSystem.isDirectory(path)) throw 'Expected a directory: $path';
			return;
		}
		var parent = Path.directory(path);
		if (parent == path || parent == "") throw 'Could not create directory: $path';
		ensureDirectories(parent);
		FileSystem.createDirectory(path);
		if (!FileSystem.isDirectory(path)) throw 'Could not create directory: $path';
	}

	static function existingWorkspace(directory:String, key:String):Dynamic {
		if (!FileSystem.exists(directory) || !AgentManagerNative.privateDirectory(directory))
			throw "Workspace state directory must be private and owned by this user";
		var endpoint = readDiscovery(directory, key);
		if (endpoint == null) throw "Workspace service is not running";
		return endpoint;
	}

	static function configureRelay(directory:String, origin:String):Void {
		var relay = relayEndpoint(origin);
		if (relay.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
			throw "Enter an HTTPS relay address";
		var settingsPath = Path.join([directory, "relay-settings.json"]);
		if (FileSystem.exists(settingsPath)) {
			var settings = readPrivateJson(settingsPath, 4096);
			if (intField(settings, "version") != 1 || stringField(settings, "origin") != relay.origin)
				throw "This workspace already has a relay configured";
			// Enabling remote access again resumes hosting that suit's Stop hosting paused.
			if (stringField(settings, "hosting") == "paused")
				AtomicFile.write(settingsPath, Json.stringify({version: 1, origin: relay.origin}) + "\n");
		} else {
			AtomicFile.create(settingsPath, Json.stringify({version: 1, origin: relay.origin}) + "\n");
		}
		AgentRelayBootstrap.create(directory, relay.origin);
	}

	static function relayEndpoint(origin:String):workspace.transport.RelayMachineEndpoint {
		if (origin == null || origin.length > 2048) throw "Enter an HTTPS relay address";
		return new workspace.transport.RelayMachineEndpoint(StringTools.trim(origin), "00000000000000000000000000000000");
	}

	static function configuredRelayOrigin(directory:String):Null<String> {
		var configured = nonempty(Sys.getEnv("EXOSUIT_RELAY_ORIGIN"));
		if (configured != null) {
			var relay = relayEndpoint(configured);
			if (relay.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
				throw "Enter an HTTPS relay address";
			return relay.origin;
		}
		var settingsPath = Path.join([directory, "relay-settings.json"]);
		if (!FileSystem.exists(settingsPath)) return null;
		var settings = readPrivateJson(settingsPath, 4096);
		if (intField(settings, "version") != 1) throw "Invalid workspace relay settings";
		// Paused from suit's tray or `suit relay stop`: neither suit nor this workspace hosts until resumed.
		if (stringField(settings, "hosting") == "paused") return null;
		var origin = stringField(settings, "origin");
		var relay = relayEndpoint(origin);
		if (relay.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
			throw "Enter an HTTPS relay address";
		return relay.origin;
	}

	static function restartManager(directory:String, key:String, expectedGeneration:Null<String>):Bool {
		if (expectedGeneration == null) throw "Restart requires the expected service generation";
		var endpoint = existingWorkspace(directory, key);
		if (stringField(endpoint, "generation") != expectedGeneration)
			throw "Workspace service changed; refresh before restarting";
		var pid = intField(endpoint, "managerPid");
		var kind = managerProcessKind(pid, key);
		if (kind == "haxe") {
			var requestPath = Path.join([directory, "restart-request.json"]);
			AtomicFile.write(requestPath, Json.stringify({version: 1, generation: expectedGeneration}) + "\n");
			if (waitForManagerStop(directory, expectedGeneration, 5)) return true;
			var endpointPath = Path.join([directory, "endpoint.json"]);
			var current = readDiscovery(directory, key);
			if (current != null && stringField(current, "generation") != expectedGeneration) return true;
			if (current == null) {
				if (!FileSystem.exists(endpointPath)) return true;
				if (!waitForProcessLockRelease(directory, 15)) return true;
				cleanupStoppedEndpoint(directory, expectedGeneration, pid);
				return false;
			}
			if (intField(current, "managerPid") != pid) throw "Workspace service changed before restart";
			var process = AgentManagerNative.openProcessIdentity(pid, Sys.executablePath());
			if (process == null) throw "Workspace manager process identity could not be verified";
			var restarted:Bool;
			try {
				restarted = restartHaxeManagerWithProcess(directory, key, expectedGeneration, pid, process);
			} catch (error:Dynamic) {
				AgentManagerNative.closeProcessIdentity(process);
				throw error;
			}
			AgentManagerNative.closeProcessIdentity(process);
			return restarted;
		}
		if (kind != "legacy") throw "Workspace manager process identity could not be verified";
		var process = AgentManagerNative.openProcessIdentity(pid, Sys.executablePath());
		if (process == null) throw "Safe legacy restart requires Linux pidfd support";
		var terminated = false;
		try {
			if (managerProcessKind(pid, key) != "legacy")
				throw "Workspace manager process identity could not be verified";
			var current = existingWorkspace(directory, key);
			if (stringField(current, "generation") != expectedGeneration || intField(current, "managerPid") != pid)
				throw "Workspace service changed before restart";
			terminated = AgentManagerNative.terminateProcess(process);
		} catch (error:Dynamic) {
			AgentManagerNative.closeProcessIdentity(process);
			throw error;
		}
		AgentManagerNative.closeProcessIdentity(process);
		if (!terminated && waitForProcessLockRelease(directory, 15)) {
			cleanupStoppedEndpoint(directory, expectedGeneration, pid);
			return false;
		}
		if (!waitForManagerStop(directory, expectedGeneration, 15))
			throw "Workspace service did not finish stopping";
		return false;
	}

	static function restartHaxeManagerWithProcess(directory:String, key:String, generation:String, pid:Int,
		process:AgentProcessIdentityHandle):Bool {
		// Older Haxe managers do not consume restart-request.json; preserve the
		// cooperative path and force-stop only after confirming the old generation remains.
		var endpointPath = Path.join([directory, "endpoint.json"]);
		var current = readDiscovery(directory, key);
		if (current != null && stringField(current, "generation") != generation) return true;
		if (current == null) {
			if (!FileSystem.exists(endpointPath)) return true;
			if (!waitForProcessLockRelease(directory, 15)) return true;
			cleanupStoppedEndpoint(directory, generation, pid);
			return false;
		}
		if (intField(current, "managerPid") != pid || managerProcessKind(pid, key) != "haxe")
			throw "Workspace service changed before restart";
		if (!AgentManagerNative.terminateProcess(process)) {
			if (waitForManagerStop(directory, generation, 5)) return true;
			if (!waitForProcessLockRelease(directory, 15)) return true;
			cleanupStoppedEndpoint(directory, generation, pid);
			return false;
		}
		if (!waitForProcessLockRelease(directory, 15)) throw "Workspace service did not finish stopping";
		cleanupStoppedEndpoint(directory, generation, pid);
		return false;
	}

	static function waitForManagerStop(directory:String, generation:String, timeout:Float):Bool {
		var deadline = Sys.time() + timeout;
		var endpointPath = Path.join([directory, "endpoint.json"]);
		while (true) {
			if (!FileSystem.exists(endpointPath)) return true;
			try {
				var endpoint = readPrivateJson(endpointPath, 16384);
				if (stringField(endpoint, "generation") != generation) return true;
			} catch (_:Dynamic) {}
			if (Sys.time() >= deadline) return false;
			Sys.sleep(0.05);
		}
	}

	static function waitForProcessLockRelease(directory:String, timeout:Float):Bool {
		var deadline = Sys.time() + timeout;
		var lockPath = Path.join([directory, "agent.lock"]);
		while (Sys.time() < deadline) {
			var probe = AgentManagerNative.acquireLock(lockPath);
			if (probe != null) {
				AgentManagerNative.releaseLock(probe);
				return true;
			}
			Sys.sleep(0.05);
		}
		return false;
	}

	static function cleanupStoppedEndpoint(directory:String, generation:String, pid:Int):Void {
		var path = Path.join([directory, "endpoint.json"]);
		if (!FileSystem.exists(path)) return;
		if (!AgentManagerNative.privateFile(path)) throw "Existing workspace descriptor is not private";
		var endpoint = readPrivateJson(path, 16384);
		if (stringField(endpoint, "generation") == generation && intField(endpoint, "managerPid") == pid)
			FileSystem.deleteFile(path);
	}

	static function waitForNewWorkspace(directory:String, key:String, previousGeneration:String):Dynamic {
		var deadline = Sys.time() + 90;
		while (Sys.time() < deadline) {
			try {
				var endpoint = readDiscovery(directory, key);
				if (endpoint != null && stringField(endpoint, "generation") != previousGeneration) return endpoint;
			} catch (_:Dynamic) {}
			Sys.sleep(0.05);
		}
		throw "Timed out waiting for the restarted workspace service";
	}

	/** `key` is the service's key: a manager started for it has it among its arguments, as a folder or a workspace id. */
	static function managerProcessKind(pid:Int, key:String):String {
		if (Sys.systemName() == "Windows" || Sys.systemName() == "Mac") return "haxe";
		var path = '/proc/$pid/cmdline';
		var arguments:Array<String>;
		try {
			var bytes = File.getBytes(path);
			arguments = [];
			var start = 0;
			for (index in 0...bytes.length) {
				if (bytes.get(index) != 0) continue;
				arguments.push(bytes.sub(start, index - start).toString());
				start = index + 1;
			}
			if (start < bytes.length) arguments.push(bytes.sub(start, bytes.length - start).toString());
		} catch (_:Dynamic) return "unknown";
		var legacy = false, haxeManager = false, hasRoot = false, hasManagerFlag = false;
		var launcher = managerBytecode();
		for (argument in arguments) {
			if (argument == key) hasRoot = true;
			if (argument == "--manager") hasManagerFlag = true;
			if (Path.withoutDirectory(StringTools.replace(argument, "\\", "/")) == "run-agent.py") legacy = true;
			if (FileSystem.exists(argument)) {
				try if (FileSystem.fullPath(argument) == launcher) haxeManager = true catch (_:Dynamic) {}
			}
		}
		if (!hasRoot) return "unknown";
		if (legacy) return "legacy";
		return haxeManager && hasManagerFlag ? "haxe" : "unknown";
	}

	static function prepareUpdate(directory:String, workspaceRoot:String):Void {
		if (bundledRunner() != null) return;
		var repository = repositoryRoot();
		if (repository == null) throw "Workspace update source tree is not installed";
		var script = Path.join([repository, "scripts", "haxeon_cli.py"]);
		if (!FileSystem.exists(script)) throw "Haxeon build helper is not installed";
		var python = nonempty(Sys.getEnv("EXOSUIT_HAXEON_CLI_PYTHON"));
		if (python == null) python = Sys.systemName() == "Windows" ? "python" : "python3";
		var project = Path.join([repository, "agent", "haxeon.json"]);
		var arguments = [script, "build", "--project", project];
		if (Sys.getEnv("HAXEON_SELF_HOSTED") == "1") arguments.push("--self-hosted");
		var compilerRoot = nonempty(Sys.getEnv("HAXEON_HOME"));
		if (compilerRoot == null) compilerRoot = nonempty(Sys.getEnv("HAXEON_ROOT"));
		if (compilerRoot == null) compilerRoot = Path.join([repository, "haxeon"]);
		var environment = new Map<String, String>();
		environment.set("HAXEON_ROOT", compilerRoot);
		environment.set("HAXEON_HOME", compilerRoot);
		environment.set("EXOSUIT_PROJECT_ROOT", repository);
		var logPath = Path.join([directory, "update-build.log"]);
		if (FileSystem.exists(logPath)) {
			if (!AgentManagerNative.privateFile(logPath)) throw "Workspace update log is not private";
			AtomicFile.write(logPath, "");
		} else AtomicFile.create(logPath, "");
		runToLog(python, arguments, workspaceRoot, environment, logPath, 90);
	}

	static function runToLog(command:String, arguments:Array<String>, cwd:String, environment:Map<String, String>,
		logPath:String, timeout:Float):Void {
		var keys = [for (key in environment.keys()) key];
		var values = [for (key in keys) environment.get(key)];
		var child = sys.io.Process.spawn(command, arguments, cwd, keys, values);
		var buffer = Bytes.alloc(16384), deadline = Sys.time() + timeout;
		var status = -1;
		try {
			while (status < 0) {
				// Polled before copying, so a build's last output reaches the log before its exit ends the loop.
				status = child.pollExit();
				copyOutput(child, buffer, false, logPath);
				copyOutput(child, buffer, true, logPath);
				if (status >= 0) break;
				if (Sys.time() >= deadline) {
					child.cancel();
					throw "Workspace update build timed out; existing sessions are unchanged";
				}
				Sys.sleep(0.05);
			}
		} catch (error:Dynamic) {
			try child.close() catch (_:Dynamic) {}
			throw error;
		}
		child.close();
		if (status != 0) throw "Workspace update build failed; existing sessions are unchanged. Inspect update-build.log";
	}

	static function repositoryRoot():Null<String> {
		var directory = FileSystem.fullPath(Path.directory(managerBytecode()));
		for (_ in 0...12) {
			if (FileSystem.exists(Path.join([directory, "agent", "haxeon.json"]))) return directory;
			var parent = Path.directory(directory);
			if (parent == directory || parent.length == 0) break;
			directory = parent;
		}
		return null;
	}

	static function bundledRunner():Null<String> {
		var directory = Path.directory(managerBytecode());
		for (name in ["exosuit-agent", "exosuit-agent.exe"]) {
			var path = Path.join([directory, name]);
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) return FileSystem.fullPath(path);
		}
		return null;
	}

	static function hexOf(digest:haxe.io.Bytes):String {
		var result = "";
		for (index in 0...digest.length) result += StringTools.hex(digest.get(index), 2);
		return result.toLowerCase();
	}

	static function agentBuildId():String {
		var overridePath = nonempty(Sys.getEnv("EXOSUIT_AGENT_BUILD_ID_FILE"));
		if (overridePath != null) {
			var value = StringTools.trim(File.getContent(overridePath));
			if (!isHex(value, 64)) throw "Invalid workspace build identity override";
			return value;
		}
		var repository = repositoryRoot();
		var collector = new BuildFileCollector();
		var files = collector.files;
		if (repository != null) {
			for (relative in ["agent/haxeon.json", "haxeon.json", "release.lock", "scripts/run-codex-proxy.py",
				"scripts/run-agent.py", "agent/naming/claude-session-names.mjs", "agent/naming/package.json", "agent/naming/package-lock.json",
				"haxeon/vendor/nativekit/CMakeLists.txt"])
				collector.add(Path.join([repository, relative]));
			for (relative in ["agent/src", "agent/native", "src", "native-packages", "haxeon/src", "haxeon/stdlib",
				"haxeon/native", "haxeon/packages/platform", "haxeon/packages/credentials", "haxeon/packages/filesystem",
				"haxeon/packages/gpu", "haxeon/vendor/nativekit"])
				collector.collect(Path.join([repository, relative]));
		}
		var launcher = managerBytecode();
		var proxy = findProxy(launcher);
		if (proxy != null) collector.add(proxy);
		var names=workspace.provider.ClaudeNameBridge.findScript(launcher);
		if(names!=null) {
			collector.add(names);
			collector.add(haxe.io.Path.directory(names)+"/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs");
			collector.add(haxe.io.Path.directory(names)+"/node_modules/@anthropic-ai/claude-agent-sdk/package.json");
		}
		var installRoot = Path.directory(Path.directory(launcher));
		if (repository == null) {
			// Bundles do not include sources, so fingerprint the installed runtime itself.
			collector.add(launcher);
			var runtime = FileSystem.fullPath(Sys.executablePath());
			collector.add(runtime);
			collector.collect(Path.join([Path.directory(launcher), "native"]), true);
			if (Path.directory(runtime) != Path.directory(launcher))
				collector.collect(Path.directory(runtime), true);
			for (name in ["exosuit-agent.hl", "exosuit-agent", "exosuit-agent.exe", "hl", "hl.exe"])
				collector.add(Path.join([Path.directory(launcher), name]));
			collector.collect(Path.join([installRoot, "lib"]), true);
		}
		files.sort(Reflect.compare);
		var identityRoot = repository == null ? installRoot : repository;
		// Hashing every source file takes seconds, and every launcher run (each discovery, each start) asks. A source
		// checkout therefore keeps the answer keyed by the files' names, sizes and times, which a stat reads in a moment.
		var cachePath:Null<String> = null, fingerprint = "";
		if (repository != null) {
			try {
				var seen = new haxe.io.BytesBuffer();
				seen.addString("exosuit-agent-build-cache-v1\n");
				for (path in files) {
					var info = FileSystem.metadata(path);
					if (info == null) throw "unreadable";
					seen.addString(path + "\t" + info.size + "\t" + info.modified + "	" + info.changed + "\n");
				}
				fingerprint = hexOf(Sha256.make(seen.getBytes()));
				cachePath = Path.join([stateBase(), "build-id.cache"]);
				if (FileSystem.exists(cachePath)) {
					var lines = File.getContent(cachePath).split("\n");
					if (lines.length >= 2 && lines[0] == fingerprint && isHex(StringTools.trim(lines[1]), 64)) return StringTools.trim(lines[1]);
				}
			} catch (_:Dynamic) {
				cachePath = null;
			}
		}
		var material = new haxe.io.BytesBuffer();
		material.addString("exosuit-agent-build-v2");
		material.addByte(0);
		material.addString(Std.string(files.length));
		material.addByte(0);
		for (path in files) {
			var relative = StringTools.startsWith(path, identityRoot + "/") || StringTools.startsWith(path, identityRoot + "\\")
				? path.substr(identityRoot.length + 1) : "external/" + path;
			relative = StringTools.replace(relative, "\\", "/");
			var bytes = File.getBytes(path);
			material.addString(relative);
			material.addByte(0);
			material.addString(Std.string(bytes.length));
			material.addByte(0);
			material.addBytes(bytes, 0, bytes.length);
		}
		var digest = Sha256.make(material.getBytes());
		var result = "";
		for (index in 0...digest.length) result += StringTools.hex(digest.get(index), 2);
		result = result.toLowerCase();
		if (cachePath != null) {
			try {
				var temporary = cachePath + "." + Std.random(1000000000) + ".tmp";
				File.saveContent(temporary, fingerprint + "\n" + result + "\n");
				FileSystem.rename(temporary, cachePath);
			} catch (_:Dynamic) {}
		}
		return result;
	}

	/** The running service's endpoint for `key` (a workspace id, or a folder for a folder-keyed service), or null. */
	static var phaseStart:Float = Sys.time();
	static final phaseLog:Bool = Sys.getEnv("EXOSUIT_CONNECT_LOG") != null;

	/** With EXOSUIT_CONNECT_LOG set, writes how long the launcher has run to stderr at a named step (the editor shows it in its connect timeline). */
	static function phase(label:String):Void {
		if (phaseLog) Sys.stderr().writeString("[" + Std.int((Sys.time() - phaseStart) * 1000) + "ms " + label + "] ");
	}

	static function readDiscovery(directory:String, key:String):Null<Dynamic> {
		var endpointPath = Path.join([directory, "endpoint.json"]);
		if (!FileSystem.exists(endpointPath)) return null;
		phase("endpoint file found");
		var endpoint = readPrivateJson(endpointPath, 16384);
		phase("endpoint read");
		if (!isObject(endpoint) || intField(endpoint, "version") != 1 || intField(endpoint, "protocol") != 1 ||
			intField(endpoint, "codec") != 1 || endpointKey(endpoint) != key ||
			stringField(endpoint, "workspace") != "workspace")
			throw "Unsupported workspace descriptor";
		var generation = stringField(endpoint, "generation");
		var managerPid = intField(endpoint, "managerPid");
		var socket = stringField(endpoint, "socket");
		var credential = stringField(endpoint, "credentialFile");
		var websocket = stringField(endpoint, "websocket");
		var expectedSocket = localEndpoint(directory, pipeKey(key, directory));
		if (!isHex(generation, 32) || managerPid <= 0 || socket != expectedSocket ||
			credential != Path.join([directory, "credential"]))
			throw "Workspace descriptor identity mismatch";
		var url = ~/^ws:\/\/127\.0\.0\.1:([0-9]{1,5})\/workspace$/;
		if (!url.match(websocket)) throw "Invalid workspace loopback endpoint";
		var port = Std.parseInt(url.matched(1));
		if (port == null || port < 1 || port > 65535) throw "Invalid workspace loopback endpoint";
		var identity = AgentStateIdentity.read(Path.join([directory, "workspace.json"]));
		phase("identity read");
		if (identity.migratedTo != null || identity.key() != key)
			throw "Workspace state directory identity mismatch";
		if (!AgentManagerNative.privateFile(credential)) throw "Invalid session credential file";
		var token = File.getContent(credential);
		if (!isHex(token, 64)) throw "Invalid session credential";
		phase("credential read");
		var probe = AgentManagerNative.acquireLock(Path.join([directory, "agent.lock"]));
		phase("lock probed");
		if (probe != null) {
			AgentManagerNative.releaseLock(probe);
			return null;
		}
		return endpoint;
	}

	/** A descriptor's key: `workspaceId` for a workspace's service, else its folder. */
	static function endpointKey(endpoint:Dynamic):String {
		var workspace = stringField(endpoint, "workspaceId");
		return workspace != "" ? workspace : stringField(endpoint, "root");
	}

	static function readPrivateJson(path:String, limit:Int):Dynamic {
		if (!AgentManagerNative.privateFile(path)) throw 'Expected a private owned file: $path';
		var info = FileSystem.metadata(path);
		if (info == null || info.size > limit) throw 'Invalid private file: $path';
		try return Json.parse(File.getContent(path)) catch (_:Dynamic) throw 'Invalid JSON file: $path';
	}

	/** Why a background manager stopped, from the last "Workspace startup failed" line of its log. */
	static function lastFailure(logPath:String):String {
		var reason = "Workspace manager exited before it was ready; inspect manager.log";
		try for (line in File.getContent(logPath).split("\n"))
			if (StringTools.startsWith(line, "Workspace startup failed: ")) reason = StringTools.trim(line.substr("Workspace startup failed: ".length))
		catch (_:Dynamic) {}
		return reason;
	}

	/** The exit status of a manager that found another one owning the workspace state. */
	static inline final WORKSPACE_IN_USE = 3;

	/**
		True while a process with this id exists. Windows has no cheap check from here (managerProcessKind makes the same
		assumption), so it answers true there and relies on the held lock.
	**/
	static function processAlive(pid:Int):Bool {
		if (pid <= 0) return false;
		if (Sys.systemName() == "Windows") return true;
		try return Sys.command("kill", ["-0", Std.string(pid)]) == 0 catch (_:Dynamic) return true;
	}

	/**
		Another manager owns the state: waits for its endpoint. The endpoint counts only when the lock is held and its
		manager pid is alive, so a file left by a crashed manager is never returned. Returns null when the lock is free
		(the owner died before it was ready) and `died` is set; a timeout throws. An unreadable descriptor is logged once.
	**/
	static function waitForOtherManager(directory:String, key:String, deadline:Float, died:Array<Bool>):Null<Dynamic> {
		var lockPath = Path.join([directory, "agent.lock"]);
		var reported = "";
		while (Sys.time() < deadline) {
			var probe = AgentManagerNative.acquireLock(lockPath);
			if (probe != null) {
				AgentManagerNative.releaseLock(probe);
				died[0] = true;
				return null;
			}
			try {
				var endpoint = readDiscovery(directory, key);
				if (endpoint != null && processAlive(intField(endpoint, "managerPid"))) return endpoint;
			} catch (error:Dynamic) {
				var message = Std.string(error);
				if (message != reported) {
					reported = message;
					Sys.stderr().writeString("Workspace start warning: the other manager's descriptor is not usable yet: " + message + "
");
					Sys.stderr().flush();
				}
			}
			Sys.sleep(0.05);
		}
		throw "Timed out waiting for another manager of this workspace to become ready; inspect manager.log";
	}

	static function startDetached(options:ManagerOptions, directory:String, retry:Bool = true):Int {
		var launcher = managerBytecode();
		var generation = AgentManagerNative.randomToken().substr(0, 32);
		var logPath = Path.join([directory, "manager.log"]);
		prepareLog(logPath);
		var command = [launcher, "--manager"].concat(identityArguments(options.identity)).concat(["--state-dir", directory, "--port", Std.string(options.port),
			"--idle-seconds", Std.string(options.idleSeconds), "--generation", generation, "--background"]);
		if (options.alwaysAvailable) command.push("--always-available");
		if (options.seedFrom != null) command = command.concat(["--seed-from", options.seedFrom]);
		var child = sys.io.Process.spawn(Sys.executablePath(), command, options.root, null, null, true);
		var buffer = Bytes.alloc(16384), deadline = Sys.time() + 90.0;
		var complete = false, result = 1;
		try {
			while (Sys.time() < deadline) {
				var status = child.pollExit();
				copyOutput(child, buffer, false, logPath);
				copyOutput(child, buffer, true, logPath);
				if (status >= 0) {
					result = status;
					complete = true;
					if (status == WORKSPACE_IN_USE) {
						// Another start (the window's, or the Workbench tree's) owns the state and is still coming up: wait
						// for its endpoint instead of failing, whoever began first.
						var died = [false];
						var running = waitForOtherManager(directory, options.identity.key(), deadline, died);
						if (running == null) {
							// The owner exited before it was ready and its lock is free: start once more ourselves.
							child.close();
							if (retry) return startDetached(options, directory, false);
							throw lastFailure(logPath);
						}
						Sys.stderr().flush();
						emitDiscovery(running, options.wire);
						result = 0;
						break;
					}
					if (status != 0) throw lastFailure(logPath);
					break;
				}
				try {
					var endpoint = readDiscovery(directory, options.identity.key());
					if (endpoint != null && endpoint.generation == generation) {
						for (notice in AgentWorkspaceMigration.readNotices(directory)) Sys.stderr().writeString("Workspace start warning: " + notice + "\n");
						Sys.stderr().flush();
						emitDiscovery(endpoint, options.wire);
						result = 0;
						complete = true;
						break;
					}
				} catch (_:Dynamic) {}
				Sys.sleep(0.05);
			}
			if (!complete) {
				child.cancel();
				throw "Timed out starting workspace daemon; inspect manager.log";
			}
		} catch (error:Dynamic) {
			try child.close() catch (_:Dynamic) {}
			throw error;
		}
		child.close();
		return result;
	}

	/**
		`--restore-migration`: undoes a workspace's migration of its folders' old state (AgentWorkspaceMigration.restore)
		while its service is stopped, and sets the workspace's state aside. Prints the folders restored.
	**/
	static function restoreMigration(directory:String, workspace:Null<String>):Int {
		if (workspace == null) throw "--restore-migration applies only to a workspace";
		if (!FileSystem.exists(directory)) throw "This workspace has no state";
		var lock = AgentManagerNative.acquireLock(Path.join([directory, "agent.lock"]));
		if (lock == null) throw "Stop the workspace's service before restoring its folders' state";
		var restored:Array<AgentWorkspaceMigration.MigratedFolder>;
		try restored = AgentWorkspaceMigration.restore(directory, workspace) catch (error:Dynamic) {
			AgentManagerNative.releaseLock(lock);
			throw error;
		}
		AgentManagerNative.releaseLock(lock);
		var aside = directory + ".restored-" + AgentWorkspaceMigration.timestamp();
		FileSystem.rename(directory, aside);
		Sys.stderr().writeString("Warning: anything done in workspace " + workspace + " after its folders' state was migrated (sessions, terminals and settings "
			+ "changed since) is not in the restored folders. It was set aside, not deleted, in " + aside + "\n");
		Sys.stderr().flush();
		Sys.println(Json.stringify({restored: [for (entry in restored) entry.root], workspaceState: aside}));
		return 0;
	}

	/** The arguments after `--manager` that name `identity`'s service. */
	public static function identityArguments(identity:AgentStateIdentity):Array<String> {
		var workspace = identity.workspace;
		if (workspace == null) return [identity.key()];
		var result = ["--workspace", workspace];
		for (folder in identity.folders) result = result.concat(["--folder", folder]);
		var scratch = identity.scratch;
		if (scratch != null) result = result.concat(["--scratch", scratch]);
		return result;
	}

	static function runManaged(options:ManagerOptions, directory:String):Int {
		// Settles EXOSUIT_SUIT once, before the daemon and anything else is spawned, so they inherit it.
		suit.SuitClient.resolve(directory);
		var lockPath = Path.join([directory, "agent.lock"]);
		var lock = AgentManagerNative.acquireLock(lockPath);
		if (lock == null) {
			Sys.stderr().writeString("workspace_in_use: another manager owns this workspace state\n");
			Sys.stderr().flush();
			return WORKSPACE_IN_USE;
		}
		var stableLease:Null<String> = null;
		AgentManagerNative.installStopSignals();
		var generation = options.generation == null ? "" : options.generation;
		var endpointPath = Path.join([directory, "endpoint.json"]);
		var credentialPath = Path.join([directory, "credential"]);
		var identityPath = Path.join([directory, "workspace.json"]);
		var logPath = Path.join([directory, "manager.log"]);
		var database = Path.join([directory, "catalog.sqlite"]);
		var relayBootstrap:Null<String> = null;
		var child:Null<ChildProcess> = null;
		var idleShutdown = false;
		var updateShutdown = false;
		var restartRequested = false;
		var ready = false;
		var databaseIdentity:Null<String> = null;
		var registryRecord:Null<String> = null;
		var pending = "";
		var exitCode = 0;
		try {
			var stableBundle = nonempty(Sys.getEnv("EXOSUIT_STABLE_BUNDLE"));
			if (stableBundle != null) {
				stableBundle = FileSystem.fullPath(stableBundle);
				if (!FileSystem.isDirectory(stableBundle)) throw "Stable workspace-agent snapshot is missing";
				stableLease = Path.join([stableBundle, ".running-agent-" + Sys.getPid()]);
				AtomicFile.create(stableLease, Std.string(Sys.getPid()) + "\n");
			}
			if (generation.length == 0) generation = AgentManagerNative.randomToken().substr(0, 32);
			prepareLog(logPath);
			options.identity = catalogIdentity(options.identity);
			if (options.identity.workspace != null && (options.identity.folders.length > 0 || options.identity.scratch != null))
				options.root = options.identity.primaryRoot();
			ensureIdentity(identityPath, options.identity);
			var notices = AgentWorkspaceMigration.run(options.identity, directory);
			AgentWorkspaceMigration.writeNotices(directory, notices);
			for (notice in notices) Sys.stderr().writeString("Workspace start warning: " + notice + "\n");
			Sys.stderr().flush();
			if (options.seedFrom != null && !FileSystem.exists(database))
				AgentManagerSeed.copyCatalog(options.seedFrom, directory, options.identity.key());
			prepareEndpointForLaunch(endpointPath);
			clearRestartRequest(directory);
			ensureCredential(credentialPath);
			relayBootstrap = AgentRelayBootstrap.create(directory, configuredRelayOrigin(directory));
			for (path in [database, database + "-wal", database + "-shm", database + ".sqlitekit-lock"])
				if (FileSystem.exists(path) && !AgentManagerNative.privateFile(path))
					throw 'Workspace state file is not private: $path';
			var port = options.port == 0 ? choosePort() : options.port;
			var socket = localEndpoint(directory, pipeKey(options.identity.key(), directory));
			if (Sys.systemName() != "Windows" && socket.length > 100)
				throw "State directory path is too long for a local socket; use --state-dir";
			var launcher = managerBytecode();
			var daemonArgs = [socket, Std.string(port), credentialPath, AgentManagerNative.randomToken().substr(0, 32),
				database, options.root, generation, Std.string(options.alwaysAvailable ? 0 : options.idleSeconds * 1000)];
			if (relayBootstrap != null) daemonArgs.push(relayBootstrap);
			var environment = daemonEnvironment(lock, launcher);
			var keys = [for (key in environment.keys()) key];
			var values = [for (key in keys) environment.get(key)];
			var daemon = sys.io.Process.spawn(Sys.executablePath(), [launcher].concat(daemonArgs), options.root, keys, values);
			child = daemon;
			var outputBytes = Bytes.alloc(16384), deadline = Sys.time() + 90.0;
			while (true) {
				// Polled before reading: once the daemon has exited, all it wrote is readable now, so its last lines (an
				// idle or update stop) are seen before its exit is judged.
				var status = daemon.pollExit();
				var output = readAvailable(daemon, outputBytes, false, logPath);
				copyOutput(daemon, outputBytes, true, logPath);
				pending += output;
				if (pending.length > MAX_OUTPUT_LINE && pending.indexOf("\n") < 0)
					throw "Workspace daemon output line exceeds limit";
				var newline = pending.indexOf("\n");
				while (newline >= 0) {
					if (newline > MAX_OUTPUT_LINE) throw "Workspace daemon output line exceeds limit";
					// Windows text-mode stdout emits CRLF; trim the carriage return so
					// the idle-stop marker still matches exactly.
					var line = StringTools.trim(pending.substr(0, newline));
					pending = pending.substr(newline + 1);
					if (line == "STOPPED: exosuit-agent idle") idleShutdown = true;
					if (line == "STOPPED: exosuit-agent update") updateShutdown = true;
					if (!ready && StringTools.startsWith(line, "READY: exosuit-agent")) {
						if (!AgentManagerNative.privateFile(database))
							throw "Workspace database is not private";
						databaseIdentity = AgentManagerNative.fileIdentity(database);
						if (databaseIdentity == null) throw "Could not identify workspace database";
						var descriptor:Dynamic = {
							version: 1, protocol: 1, codec: 1, workspace: "workspace", root: options.root,
							managerPid: Sys.getPid(), generation: generation, socket: socket,
							websocket: "ws://127.0.0.1:" + port + "/workspace", credentialFile: credentialPath,
							launcher: launcher
						};
						var workspaceId = options.identity.workspace;
						if (workspaceId != null) Reflect.setField(descriptor, "workspaceId", workspaceId);
						AtomicFile.write(endpointPath, Json.stringify(descriptor) + "\n");
						ready = true;
						registryRecord = AgentMachine.register(stateBase(), options.identity, directory, generation, launcher);
						// Fire-and-forget: suit (the tray daemon) lists, and can cooperatively stop, this manager.
						suit.SuitClient.registerWorkspaceService(suit.SuitKind.WorkspaceManager,
							{root: options.root, stateDir: directory, generation: generation, workspace: options.identity.workspace});
						if (options.background) suit.SuitClient.ensureDaemon();
						if (!options.background) emitDiscovery(descriptor, options.wire);
					}
					newline = pending.indexOf("\n");
				}
				if (status >= 0) {
					if (status == 0 && idleShutdown) { exitCode = 0; break; }
					if (status == 0 && updateShutdown) { restartRequested = true; exitCode = 0; break; }
					throw 'Workspace daemon exited with status $status';
				}
				if (AgentManagerNative.stopRequested()) { exitCode = 0; break; }
				if (consumeRestartRequest(directory, generation)) { restartRequested = true; exitCode = 0; break; }
				if (consumeStopRequest(directory, generation)) { exitCode = 0; break; }
				if (!ready && Sys.time() >= deadline)
					throw "Workspace daemon did not become ready";
				if (ready && AgentManagerNative.fileIdentity(database) != databaseIdentity)
					throw "Workspace database was replaced; stopping the daemon";
				Sys.sleep(0.05);
			}
		} catch (error:Dynamic) {
			exitCode = 1;
			if (options.background) {
				try File.appendContent(logPath, "Workspace startup failed: " + Std.string(error) + "\n") catch (_:Dynamic) {}
			} else {
				Sys.stderr().writeString("Workspace startup failed: " + Std.string(error) + "\n");
				Sys.stderr().flush();
			}
		}
		if (child != null) {
			try {
				if (child.pollExit() < 0) child.cancel();
			} catch (cleanupError:Dynamic) {
				exitCode = 1;
				try File.appendContent(logPath, "Workspace daemon cleanup failed: " + Std.string(cleanupError) + "\n") catch (_:Dynamic) {}
			}
			try child.close() catch (cleanupError:Dynamic) {
				exitCode = 1;
				try File.appendContent(logPath, "Workspace daemon handle cleanup failed: " + Std.string(cleanupError) + "\n") catch (_:Dynamic) {}
			}
		}
		cleanupEndpoint(endpointPath, generation);
		if (registryRecord != null) AgentMachine.unregister(registryRecord, generation);
		suit.SuitClient.unregister();
		if (relayBootstrap != null && FileSystem.exists(relayBootstrap))
			try FileSystem.deleteFile(relayBootstrap) catch (_:Dynamic) {}
		try AgentManagerNative.releaseLock(lock) catch (_:Dynamic) { exitCode = 1; }
		if (restartRequested && exitCode == 0)
			exitCode = startDetached(options, directory);
		if (stableLease != null && FileSystem.exists(stableLease))
			try FileSystem.deleteFile(stableLease) catch (_:Dynamic) { exitCode = 1; }
		return exitCode;
	}

	/**
		A workspace's identity with the folders and scratch folder suit's catalog has for it now. The manager's own
		arguments are those of the start that launched it, and the folders may have changed since (see
		WorkspaceFoldersProtocol), so each spawn takes them from the catalog; without a catalog entry the arguments stand.
	**/
	static function catalogIdentity(identity:AgentStateIdentity):AgentStateIdentity {
		var id = identity.workspace;
		var file = suit.MachineCatalog.file();
		if (id == null || !FileSystem.exists(file)) return identity;
		var found:Null<suit.MachineCatalog.MachineWorkspace> = null;
		try {
			for (entry in new suit.MachineCatalog(file).state.workspaces) if (entry.id == id) found = entry;
		} catch (_:Dynamic) {}
		return found == null ? identity : AgentStateIdentity.forWorkspace(id, found.folders, found.scratch);
	}

	/**
		Checks that the state folder is `identity`'s, or claims a new one. A workspace's folders are rewritten each
		start: the workspace's id is its identity, and its folders may change between starts.
	**/
	static function ensureIdentity(path:String, identity:AgentStateIdentity):Void {
		if (!FileSystem.exists(path)) {
			identity.write(path);
			return;
		}
		var existing = AgentStateIdentity.read(path);
		var movedTo = existing.migratedTo;
		if (movedTo != null)
			throw 'This folder\'s workspace state moved to workspace $movedTo. Open that workspace from the Workbench; '
				+ "an editor from before workspaces were keyed by id cannot open it";
		if (existing.key() != identity.key()) throw "Workspace state directory identity mismatch";
		if (identity.workspace != null) identity.write(path);
	}

	static function prepareEndpointForLaunch(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (!AgentManagerNative.privateFile(path)) throw "Existing workspace descriptor is not private";
		FileSystem.deleteFile(path);
	}

	static function clearRestartRequest(directory:String):Void {
		var path = Path.join([directory, "restart-request.json"]);
		if (!FileSystem.exists(path)) return;
		if (!AgentManagerNative.privateFile(path)) throw "Workspace restart request is not private";
		FileSystem.deleteFile(path);
	}

	static function consumeRestartRequest(directory:String, generation:String):Bool {
		var path = Path.join([directory, "restart-request.json"]);
		if (!FileSystem.exists(path)) return false;
		var request = readPrivateJson(path, 4096);
		FileSystem.deleteFile(path);
		if (!isObject(request) || intField(request, "version") != 1 || stringField(request, "generation") != generation)
			return false;
		return true;
	}

	/**
		suit's graceful stop: like a restart request for this generation, except that the manager does not
		start again. The daemon stops as on any manager exit; relay settings and device grants stay on disk.
	**/
	static function consumeStopRequest(directory:String, generation:String):Bool {
		var path = suit.WorkspaceStopRequest.path(directory);
		if (!FileSystem.exists(path)) return false;
		var request:Dynamic = null;
		try request = readPrivateJson(path, suit.WorkspaceStopRequest.MAX_BYTES) catch (_:Dynamic) {}
		try FileSystem.deleteFile(path) catch (_:Dynamic) {}
		return suit.WorkspaceStopRequest.matches(request, generation);
	}

	static function ensureCredential(path:String):Void {
		if (FileSystem.exists(path)) {
			if (!AgentManagerNative.privateFile(path)) throw "Session credential is not private";
			var token = File.getContent(path);
			if (!isHex(token, 64)) throw "Invalid session credential";
		} else {
			AtomicFile.create(path, AgentManagerNative.randomToken());
		}
	}

	static function daemonEnvironment(lock:AgentManagerNative.AgentLockHandle, launcher:String):Map<String, String> {
		var environment = new Map<String, String>();
		environment.set("EXOSUIT_AGENT_BUILD_ID", agentBuildId());
		environment.set("EXOSUIT_AGENT_MANAGED_UPDATES", Sys.getEnv("EXOSUIT_AGENT_MANAGED_UPDATES") == "0" ? "0" : "1");
		var stableBundle = nonempty(Sys.getEnv("EXOSUIT_STABLE_BUNDLE"));
		if (stableBundle != null) environment.set("EXOSUIT_STABLE_BUNDLE", stableBundle);
		var descriptor = AgentManagerNative.lockDescriptor(lock);
		if (descriptor >= 0) environment.set("EXOSUIT_AGENT_LOCK_FD", Std.string(descriptor));
		if (nonempty(Sys.getEnv("EXOSUIT_CODEX_PROXY_LAUNCHER")) == null) {
			var proxy = findProxy(launcher);
			if (proxy != null) environment.set("EXOSUIT_CODEX_PROXY_LAUNCHER", proxy);
		}
		return environment;
	}

	static function findProxy(launcher:String):Null<String> {
		var directory = Path.directory(launcher);
		for (_ in 0...8) {
			var packaged = Path.join([directory, "run-codex-proxy.py"]);
			if (FileSystem.exists(packaged)) return packaged;
			var candidate = Path.join([directory, "scripts", "run-codex-proxy.py"]);
			if (FileSystem.exists(candidate)) return candidate;
			var parent = Path.directory(directory);
			if (parent == directory || parent.length == 0) break;
			directory = parent;
		}
		return null;
	}

	static function managerBytecode():String {
		var configured = nonempty(Sys.getEnv("EXOSUIT_AGENT_LAUNCHER"));
		if (configured != null)
			return FileSystem.fullPath(configured);
		var directory = FileSystem.fullPath(Sys.getCwd());
		for (_ in 0...10) {
			for (candidate in [Path.join([directory, "agent", "build", "host", "main.hl"]),
				Path.join([directory, "tools", "exosuit-agent.hl"])])
				if (FileSystem.exists(candidate)) return FileSystem.fullPath(candidate);
			var parent = Path.directory(directory);
			if (parent == directory || parent.length == 0) break;
			directory = parent;
		}
		if (configured != null) {
			var parent = Path.directory(Path.directory(configured));
			var candidate = Path.join([parent, "agent", "build", "host", "main.hl"]);
			if (FileSystem.exists(candidate)) return FileSystem.fullPath(candidate);
		}
		throw "Haxeon workspace agent bytecode is not installed";
	}

	static function localEndpoint(directory:String, key:String):String
		return Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-" + key : Path.join([directory, "agent.sock"]);

	static function pipeKey(root:String, directory:String):String
		return Sha256.encode(root + "\n" + directory).substr(0, 20);

	static function choosePort():Int {
		return AgentManagerNative.choosePort();
	}

	static function copyOutput(child:ChildProcess, buffer:Bytes, stderr:Bool, logPath:String):Void {
		readAvailable(child, buffer, stderr, logPath);
	}

	static function readAvailable(child:ChildProcess, buffer:Bytes, stderr:Bool, logPath:String):String {
		var output = "";
		while (true) {
			var count = stderr ? child.readStderr(buffer, 0, buffer.length) : child.readStdout(buffer, 0, buffer.length);
			if (count <= 0) break;
			var chunk = buffer.sub(0, count).toString();
			File.appendContent(logPath, chunk);
			if (!stderr) output += chunk;
		}
		return output;
	}

	static function prepareLog(path:String):Void {
		if (FileSystem.exists(path)) {
			if (!AgentManagerNative.privateFile(path)) throw "Manager log file is not private";
		} else {
			try AtomicFile.create(path, "") catch (error:Dynamic) {
				// Concurrent clients may both prepare the log before taking the manager lock.
				if (!FileSystem.exists(path) || !AgentManagerNative.privateFile(path)) throw error;
			}
		}
	}

	static function cleanupEndpoint(path:String, generation:String):Void {
		try {
			if (FileSystem.exists(path) && AgentManagerNative.privateFile(path)) {
				var endpoint = Json.parse(File.getContent(path));
				if (Reflect.field(endpoint, "generation") == generation) FileSystem.deleteFile(path);
			}
		} catch (_:Dynamic) {}
	}

	static function emitDiscovery(endpoint:Dynamic, wire:Bool):Void {
		Reflect.setField(endpoint, "expectedBuild", agentBuildId());
		if (!wire) {
			Sys.println(Json.stringify(endpoint));
		} else {
			var values:Array<Dynamic> = [];
			for (index in 0...DISCOVERY_FIELDS.length) {
				// A manager from before the launcher field leaves it out.
				if (Reflect.field(endpoint, DISCOVERY_FIELDS[index]) == null) continue;
				var pair:Array<Dynamic> = [];
				pair.push(Std.string(index + 1) + ":" + DISCOVERY_FIELDS[index]);
				pair.push(Reflect.field(endpoint, DISCOVERY_FIELDS[index]));
				values.push(pair);
			}
			Sys.println(Json.stringify({version: 1, value: values}));
		}
		Sys.stdout().flush();
	}

	static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	static function intField(value:Dynamic, field:String):Int {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Int) ? cast result : -1;
	}

	static function stringField(value:Dynamic, field:String):String {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) ? cast result : "";
	}

	static function isHex(value:String, length:Int):Bool {
		if (value == null || value.length != length) return false;
		for (index in 0...value.length) {
			var c = value.charCodeAt(index);
			if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
		}
		return true;
	}

	static function nonempty(value:Null<String>):Null<String>
		return value == null || value.length == 0 ? null : value;
}
