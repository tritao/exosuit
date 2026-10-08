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
}

/** Exosuit workspace daemon supervisor and discovery launcher. */
class AgentManager {
	static final DISCOVERY_FIELDS = ["version", "protocol", "codec", "workspace", "root", "managerPid", "generation", "socket", "websocket", "credentialFile", "expectedBuild"];
	static final MAX_OUTPUT_LINE = 1048576;

	public static function run(arguments:Array<String>):Int {
		try {
			AgentManagerNative.setPrivateUmask();
			var options = parse(arguments);
			var directory = stateDirectory(options);
			if (options.configureRelay != null) {
				var endpoint = existingWorkspace(directory, options.root);
				configureRelay(directory, options.configureRelay);
				emitDiscovery(endpoint, options.wire);
				return 0;
			}
			if (options.prepareUpdate) {
				var endpoint = existingWorkspace(directory, options.root);
				prepareUpdate(directory, options.root);
				emitDiscovery(endpoint, options.wire);
				return 0;
			}
			if (options.restart) {
				var endpoint = existingWorkspace(directory, options.root);
				var previousGeneration = stringField(endpoint, "generation");
				if (previousGeneration != options.expectedGeneration)
					throw "Workspace service changed; refresh before restarting";
				prepareUpdate(directory, options.root);
				var managerRestartsItself = restartManager(directory, options.root, options.expectedGeneration);
				if (managerRestartsItself) {
					var restarted = waitForNewWorkspace(directory, options.root, previousGeneration);
					emitDiscovery(restarted, options.wire);
					return 0;
				}
				return startDetached(options, directory);
			}
			if (options.discover) {
				if (!FileSystem.exists(directory)) return 4;
				if (!AgentManagerNative.privateDirectory(directory))
					throw "Workspace state directory must be private and owned by this user";
				var endpoint = readDiscovery(directory, options.root);
				if (endpoint == null) return 4;
				emitDiscovery(endpoint, options.wire);
				return 0;
			}
			ensureStateDirectory(directory);
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
		if (arguments.length == 0) throw "Usage: exosuit-agent.hl --manager WORKSPACE [--discover|--detach] [--wire]";
		var root = FileSystem.fullPath(arguments[0]);
		if (!FileSystem.isDirectory(root)) throw "Workspace root is not a directory";
		var options:ManagerOptions = {
			root: root, stateDir: null, port: 0, idleSeconds: 60,
			alwaysAvailable: Sys.getEnv("EXOSUIT_AGENT_ALWAYS_AVAILABLE") == "1",
			discover: false, configureRelay: null, prepareUpdate: false,
			restart: false, expectedGeneration: null,
			detach: false, background: false, wire: false, generation: null
		};
		var index = 1;
		while (index < arguments.length) {
			var value = arguments[index++];
			switch value {
				case "--state-dir":
					if (index >= arguments.length) throw "--state-dir requires a directory";
					options.stateDir = FileSystem.fullPath(arguments[index++]);
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
		var maintenanceModes = (options.configureRelay != null ? 1 : 0) + (options.prepareUpdate ? 1 : 0) + (options.restart ? 1 : 0);
		if (maintenanceModes > 1 || maintenanceModes > 0 && (options.discover || options.detach || options.background))
			throw "Workspace maintenance cannot be combined with another manager mode";
		if (options.restart && options.expectedGeneration == null)
			throw "Restart requires the expected service generation";
		if (!options.restart && options.expectedGeneration != null)
			throw "--expected-generation requires --restart";
		if (options.discover && (options.detach || options.background))
			throw "Discovery cannot be combined with manager startup";
		if (options.detach && options.background)
			throw "Detached startup cannot run as a background manager";
		return options;
	}

	static function stateDirectory(options:ManagerOptions):String {
		if (options.stateDir != null) return options.stateDir;
		var base:String;
		if (Sys.systemName() == "Windows") {
			var local = nonempty(Sys.getEnv("LOCALAPPDATA"));
			if (local == null) local = nonempty(Sys.getEnv("APPDATA"));
			if (local == null) local = Path.join([Sys.getEnv("USERPROFILE") == null ? Sys.getCwd() : Sys.getEnv("USERPROFILE"), "AppData", "Local"]);
			base = Path.join([local, "Exosuit", "workspaces"]);
		} else {
			var state = nonempty(Sys.getEnv("XDG_STATE_HOME"));
			var home = nonempty(Sys.getEnv("HOME"));
			if (home == null) home = Sys.getCwd();
			base = Path.join([state == null ? Path.join([home, ".local", "state"]) : state, "exosuit", "workspaces"]);
		}
		return FileSystem.fullPath(Path.join([base, Sha256.encode(options.root).substr(0, 20)]));
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

	static function existingWorkspace(directory:String, root:String):Dynamic {
		if (!FileSystem.exists(directory) || !AgentManagerNative.privateDirectory(directory))
			throw "Workspace state directory must be private and owned by this user";
		var endpoint = readDiscovery(directory, root);
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
		var origin = stringField(settings, "origin");
		var relay = relayEndpoint(origin);
		if (relay.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
			throw "Enter an HTTPS relay address";
		return relay.origin;
	}

	static function restartManager(directory:String, root:String, expectedGeneration:Null<String>):Bool {
		if (expectedGeneration == null) throw "Restart requires the expected service generation";
		var endpoint = existingWorkspace(directory, root);
		if (stringField(endpoint, "generation") != expectedGeneration)
			throw "Workspace service changed; refresh before restarting";
		var pid = intField(endpoint, "managerPid");
		var kind = managerProcessKind(pid, root);
		if (kind == "haxe") {
			var requestPath = Path.join([directory, "restart-request.json"]);
			AtomicFile.write(requestPath, Json.stringify({version: 1, generation: expectedGeneration}) + "\n");
			if (waitForManagerStop(directory, expectedGeneration, 5)) return true;
			var endpointPath = Path.join([directory, "endpoint.json"]);
			var current = readDiscovery(directory, root);
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
				restarted = restartHaxeManagerWithProcess(directory, root, expectedGeneration, pid, process);
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
			if (managerProcessKind(pid, root) != "legacy")
				throw "Workspace manager process identity could not be verified";
			var current = existingWorkspace(directory, root);
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

	static function restartHaxeManagerWithProcess(directory:String, root:String, generation:String, pid:Int,
		process:AgentProcessIdentityHandle):Bool {
		// Older Haxe managers do not consume restart-request.json; preserve the
		// cooperative path and force-stop only after confirming the old generation remains.
		var endpointPath = Path.join([directory, "endpoint.json"]);
		var current = readDiscovery(directory, root);
		if (current != null && stringField(current, "generation") != generation) return true;
		if (current == null) {
			if (!FileSystem.exists(endpointPath)) return true;
			if (!waitForProcessLockRelease(directory, 15)) return true;
			cleanupStoppedEndpoint(directory, generation, pid);
			return false;
		}
		if (intField(current, "managerPid") != pid || managerProcessKind(pid, root) != "haxe")
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

	static function waitForNewWorkspace(directory:String, root:String, previousGeneration:String):Dynamic {
		var deadline = Sys.time() + 90;
		while (Sys.time() < deadline) {
			try {
				var endpoint = readDiscovery(directory, root);
				if (endpoint != null && stringField(endpoint, "generation") != previousGeneration) return endpoint;
			} catch (_:Dynamic) {}
			Sys.sleep(0.05);
		}
		throw "Timed out waiting for the restarted workspace service";
	}

	static function managerProcessKind(pid:Int, root:String):String {
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
			if (argument == root) hasRoot = true;
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
				copyOutput(child, buffer, false, logPath);
				copyOutput(child, buffer, true, logPath);
				status = child.pollExit();
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

	static function agentBuildId():String {
		var overridePath = nonempty(Sys.getEnv("EXOSUIT_AGENT_BUILD_ID_FILE"));
		if (overridePath != null) {
			var value = StringTools.trim(File.getContent(overridePath));
			if (!isHex(value, 64)) throw "Invalid workspace build identity override";
			return value;
		}
		var repository = repositoryRoot();
		var files:Array<String> = [];
		if (repository != null) {
			for (relative in ["agent/haxeon.json", "haxeon.json", "release.lock", "scripts/run-codex-proxy.py",
				"scripts/run-agent.py",
				"haxeon/vendor/nativekit/CMakeLists.txt"])
				addBuildFile(files, Path.join([repository, relative]));
			for (relative in ["agent/src", "agent/native", "src", "native-packages", "haxeon/src", "haxeon/stdlib",
				"haxeon/native", "haxeon/packages/platform", "haxeon/packages/credentials", "haxeon/packages/filesystem",
				"haxeon/packages/gpu", "haxeon/vendor/nativekit"])
				collectBuildFiles(Path.join([repository, relative]), files, true);
		}
		var launcher = managerBytecode();
		var proxy = findProxy(launcher);
		if (proxy != null) addBuildFile(files, proxy);
		var installRoot = Path.directory(Path.directory(launcher));
		if (repository == null) {
			// Bundles do not include sources, so fingerprint the installed runtime itself.
			addBuildFile(files, launcher);
			var runtime = FileSystem.fullPath(Sys.executablePath());
			addBuildFile(files, runtime);
			collectRuntimeArtifacts(Path.join([Path.directory(launcher), "native"]), files);
			if (Path.directory(runtime) != Path.directory(launcher))
				collectRuntimeArtifacts(Path.directory(runtime), files);
			for (name in ["exosuit-agent.hl", "exosuit-agent", "exosuit-agent.exe", "hl", "hl.exe"])
				addBuildFile(files, Path.join([Path.directory(launcher), name]));
			collectRuntimeArtifacts(Path.join([installRoot, "lib"]), files);
		}
		files.sort(Reflect.compare);
		var identityRoot = repository == null ? installRoot : repository;
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
		return result.toLowerCase();
	}

	static function addBuildFile(files:Array<String>, path:String):Void {
		if (FileSystem.exists(path) && !FileSystem.isDirectory(path) && files.indexOf(path) < 0) files.push(path);
	}

	static function collectBuildFiles(directory:String, files:Array<String>, includeVendor:Bool = false):Void {
		if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory)) return;
		var names = FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			if (name == "build" || name == "out" || name == ".git" || name == "__pycache__"
				|| name == "test" || name == "tests" || name == "bench" || name == "benchmarks"
				|| name == "examples" || name == "docs" || name == "doc" || (name == "vendor" && !includeVendor)) continue;
			var path = Path.join([directory, name]);
			if (FileSystem.isDirectory(path)) {
				collectBuildFiles(path, files, includeVendor);
			} else {
				var dot = name.lastIndexOf(".");
				var extension = dot < 0 ? "" : name.substr(dot + 1).toLowerCase();
				if (extension == "hx" || extension == "c" || extension == "h" || extension == "cpp" || extension == "json"
					|| extension == "hxi" || extension == "hxmap" || extension == "inc" || extension == "in"
					|| extension == "cmake" || extension == "hxml" || extension == "def" || extension == "rc"
					|| Path.withoutDirectory(path) == "CMakeLists.txt") addBuildFile(files, path);
			}
		}
	}

	static function collectRuntimeArtifacts(directory:String, files:Array<String>):Void {
		if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory)) return;
		var names = FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			var path = Path.join([directory, name]);
			if (FileSystem.isDirectory(path)) {
				collectRuntimeArtifacts(path, files);
				continue;
			}
			var dot = name.lastIndexOf(".");
			var extension = dot < 0 ? "" : name.substr(dot + 1).toLowerCase();
			var lowerName = name.toLowerCase();
			if (extension == "hl" || extension == "hdll" || extension == "so" || extension == "dylib" || extension == "dll"
				|| extension == "a" || extension == "lib" || lowerName.indexOf(".so.") >= 0 || lowerName.indexOf(".dylib.") >= 0)
				addBuildFile(files, path);
		}
	}

	static function readDiscovery(directory:String, root:String):Null<Dynamic> {
		var endpointPath = Path.join([directory, "endpoint.json"]);
		if (!FileSystem.exists(endpointPath)) return null;
		var endpoint = readPrivateJson(endpointPath, 16384);
		if (!isObject(endpoint) || intField(endpoint, "version") != 1 || intField(endpoint, "protocol") != 1 ||
			intField(endpoint, "codec") != 1 || stringField(endpoint, "root") != root ||
			stringField(endpoint, "workspace") != "workspace")
			throw "Unsupported workspace descriptor";
		var generation = stringField(endpoint, "generation");
		var managerPid = intField(endpoint, "managerPid");
		var socket = stringField(endpoint, "socket");
		var credential = stringField(endpoint, "credentialFile");
		var websocket = stringField(endpoint, "websocket");
		var expectedSocket = localEndpoint(directory, pipeKey(root, directory));
		if (!isHex(generation, 32) || managerPid <= 0 || socket != expectedSocket ||
			credential != Path.join([directory, "credential"]))
			throw "Workspace descriptor identity mismatch";
		var url = ~/^ws:\/\/127\.0\.0\.1:([0-9]{1,5})\/workspace$/;
		if (!url.match(websocket)) throw "Invalid workspace loopback endpoint";
		var port = Std.parseInt(url.matched(1));
		if (port == null || port < 1 || port > 65535) throw "Invalid workspace loopback endpoint";
		var identityPath = Path.join([directory, "workspace.json"]);
		var identity = readPrivateJson(identityPath, 16384);
		if (!isObject(identity) || intField(identity, "version") != 1 || stringField(identity, "root") != root)
			throw "Workspace state directory identity mismatch";
		if (!AgentManagerNative.privateFile(credential)) throw "Invalid session credential file";
		var token = File.getContent(credential);
		if (!isHex(token, 64)) throw "Invalid session credential";
		var probe = AgentManagerNative.acquireLock(Path.join([directory, "agent.lock"]));
		if (probe != null) {
			AgentManagerNative.releaseLock(probe);
			return null;
		}
		return endpoint;
	}

	static function readPrivateJson(path:String, limit:Int):Dynamic {
		if (!AgentManagerNative.privateFile(path)) throw 'Expected a private owned file: $path';
		var info = FileSystem.metadata(path);
		if (info == null || info.size > limit) throw 'Invalid private file: $path';
		try return Json.parse(File.getContent(path)) catch (_:Dynamic) throw 'Invalid JSON file: $path';
	}

	static function startDetached(options:ManagerOptions, directory:String):Int {
		var launcher = managerBytecode();
		var generation = AgentManagerNative.randomToken().substr(0, 32);
		var logPath = Path.join([directory, "manager.log"]);
		prepareLog(logPath);
		var command = [launcher, "--manager", options.root, "--state-dir", directory, "--port", Std.string(options.port),
			"--idle-seconds", Std.string(options.idleSeconds), "--generation", generation, "--background"];
		if (options.alwaysAvailable) command.push("--always-available");
		var child = sys.io.Process.spawn(Sys.executablePath(), command, options.root, null, null, true);
		var buffer = Bytes.alloc(16384), deadline = Sys.time() + 90.0;
		var complete = false, result = 1;
		try {
			while (Sys.time() < deadline) {
				copyOutput(child, buffer, false, logPath);
				copyOutput(child, buffer, true, logPath);
				var status = child.pollExit();
				if (status >= 0) { result = status; complete = true; break; }
				try {
					var endpoint = readDiscovery(directory, options.root);
					if (endpoint != null && endpoint.generation == generation) {
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

	static function runManaged(options:ManagerOptions, directory:String):Int {
		var lockPath = Path.join([directory, "agent.lock"]);
		var lock = AgentManagerNative.acquireLock(lockPath);
		if (lock == null) {
			Sys.stderr().writeString("workspace_in_use: another manager owns this workspace state\n");
			Sys.stderr().flush();
			return 3;
		}
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
		var pending = "";
		var exitCode = 0;
		try {
			if (generation.length == 0) generation = AgentManagerNative.randomToken().substr(0, 32);
			prepareLog(logPath);
			ensureIdentity(identityPath, options.root);
			prepareEndpointForLaunch(endpointPath);
			clearRestartRequest(directory);
			ensureCredential(credentialPath);
			relayBootstrap = AgentRelayBootstrap.create(directory, configuredRelayOrigin(directory));
			for (path in [database, database + "-wal", database + "-shm", database + ".sqlitekit-lock"])
				if (FileSystem.exists(path) && !AgentManagerNative.privateFile(path))
					throw 'Workspace state file is not private: $path';
			var port = options.port == 0 ? choosePort() : options.port;
			var socket = localEndpoint(directory, pipeKey(options.root, directory));
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
							websocket: "ws://127.0.0.1:" + port + "/workspace", credentialFile: credentialPath
						};
						AtomicFile.write(endpointPath, Json.stringify(descriptor) + "\n");
						ready = true;
						if (!options.background) emitDiscovery(descriptor, options.wire);
					}
					newline = pending.indexOf("\n");
				}
				var status = daemon.pollExit();
				if (status >= 0) {
					if (status == 0 && idleShutdown) { exitCode = 0; break; }
					if (status == 0 && updateShutdown) { restartRequested = true; exitCode = 0; break; }
					throw 'Workspace daemon exited with status $status';
				}
				if (AgentManagerNative.stopRequested()) { exitCode = 0; break; }
				if (consumeRestartRequest(directory, generation)) { restartRequested = true; exitCode = 0; break; }
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
		if (relayBootstrap != null && FileSystem.exists(relayBootstrap))
			try FileSystem.deleteFile(relayBootstrap) catch (_:Dynamic) {}
		try AgentManagerNative.releaseLock(lock) catch (_:Dynamic) { exitCode = 1; }
		if (restartRequested && exitCode == 0)
			return startDetached(options, directory);
		return exitCode;
	}

	static function ensureIdentity(path:String, root:String):Void {
		if (FileSystem.exists(path)) {
			var identity = readPrivateJson(path, 16384);
			if (!isObject(identity) || intField(identity, "version") != 1 || stringField(identity, "root") != root)
				throw "Workspace state directory identity mismatch";
		} else {
			AtomicFile.create(path, Json.stringify({version: 1, root: root}) + "\n");
		}
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
		} else AtomicFile.create(path, "");
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
