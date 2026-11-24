package app;

import haxeon.platform.Runtime;
import nativekit.ffi.NativeKit;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;
import workspace.transport.WorkspaceRpcServer;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceLifetime;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.ServiceLog;
import workspace.runtime.WorkspaceTerminalManager;
import exohost.ExohostServiceLink;

/** The workspace a service serves: its id in exohost's machine catalog and its folders, as exohost passed them. */
typedef ServiceTarget = {
	var workspace:String;
	var folders:Array<String>;
	var scratch:Null<String>;
}

/**
	The agent providers' programs. Finding one is a search of PATH on Windows (tens of milliseconds each), and none
	depends on the workspace, so a spare finds them before it is adopted.
**/
typedef ProviderPrograms = {
	var codex:String;
	var codexScript:Null<String>;
	var codexProxy:Null<String>;
	var claude:String;
	var claudeScript:Null<String>;
	var pi:String;
	var piScript:Null<String>;
}

/**
	A workspace's service: one process per running workspace, which exohost starts
	(`exosuit-agent.hl --workspace ID [--folder F]... [--scratch S]`). It takes its state folder's lock, listens on its
	pipe and then reports to exohost (ExohostServiceLink): that report is how exohost learns it is ready and which pipe to hand
	out, and its connection closing is how exohost learns that it stopped. It stops by itself after
	`EXOSUIT_SERVICE_IDLE_SECONDS` (600 by default) with no client and no busy agent turn, or when exohost asks.

	`exosuit-agent.hl --spare` is the warm spare exohost keeps while an editor is linked: loaded and linked to exohost, it
	serves the workspace exohost hands it (`adopt`) the moment one is opened, so an idle workspace opens without a process
	start.
**/
class AgentMain {
	/** The exit status of a service that found its workspace's state locked by another one. */
	static inline final IN_USE = 3;
	static inline final IDLE_SECONDS = 600;

	static function main():Void {
		var args = Sys.args();
		AgentNative.setPrivateUmask();
		var spare = args.length == 1 && args[0] == "--spare";
		var target:Null<ServiceTarget> = null;
		if (!spare)
			try target = parse(args) catch (error:Dynamic) {
				Sys.stderr().writeString("Usage: exosuit-agent.hl --workspace ID [--folder FOLDER]... [--scratch FOLDER] | --spare: " + Std.string(error) + "\n");
				Sys.exit(2);
				return;
			}
		var runtime = Runtime.start(), hub = new NativeRpcHub(runtime.events);
		var report = new ExohostServiceLink(hub);
		var code = 0;
		var programs:Null<ProviderPrograms> = null;
		if (spare)
			try {
				programs = providerPrograms();
				warm();
				target = awaitAdoption(runtime, report);
			} catch (error:Dynamic) {
				Sys.stderr().writeString("Spare: " + Std.string(error) + "\n");
				code = 2;
			}
		if (target != null)
			try code = serve(target, programs, runtime, hub, report) catch (error:Dynamic) {
				ServiceLog.note("Workspace startup failed: " + Std.string(error));
				code = 1;
			}
		report.dispose();
		hub.dispose();
		runtime.dispose();
		Sys.exit(code);
	}

	static function parse(args:Array<String>):ServiceTarget {
		if (args.length < 2 || args[0] != "--workspace")
			throw "--workspace requires a workspace id";
		var folders:Array<String> = [], scratch:Null<String> = null;
		var index = 2;
		while (index < args.length) {
			var option = args[index++];
			if ((option != "--folder" && option != "--scratch") || index >= args.length)
				throw 'Unknown workspace service option: $option';
			if (option == "--scratch") scratch = args[index++];
			else folders.push(args[index++]);
		}
		return targetOf(args[1], folders, scratch);
	}

	/** Workspace `id` with its folders and scratch folder as full paths; throws on a bad id or a folder that is not one. */
	static function targetOf(id:String, folders:Array<String>, scratch:Null<String>):ServiceTarget {
		if (!AgentStateIdentity.validWorkspaceId(id)) throw "--workspace requires a workspace id";
		var target:ServiceTarget = {workspace: id, folders: [], scratch: null};
		function full(folder:String):String {
			var path = FileSystem.fullPath(folder);
			if (path == null || !FileSystem.isDirectory(path)) throw 'Workspace folder is not a directory: $folder';
			return path;
		}
		for (folder in folders) {
			var path = full(folder);
			if (target.folders.indexOf(path) < 0) target.folders.push(path);
		}
		if (scratch != null) target.scratch = full(scratch);
		return target;
	}

	/**
		The spare's wait: linked to exohost, it idles until exohost hands it a workspace (whose target it returns), asks it to
		stop, or goes (null either way). It then runs in the first folder, as a started service does.
	**/
	static function awaitAdoption(runtime:Runtime, report:ExohostServiceLink):Null<ServiceTarget> {
		report.offerSpare();
		// Listed as the spare (exohost lists registered processes even when it does not scan); the record becomes the
		// service's once a workspace adopts it.
		exohost.ExohostClient.registerWorkspaceService(exohost.ExohostKind.WorkspaceSpare, {root: Sys.getCwd(), stateDir: "", generation: null, workspace: null});
		while (true) {
			runtime.events.wait(1.0);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			report.poll();
			var adopted = report.adoption;
			if (adopted != null) {
				// The editor that opened this workspace connects while it starts: see FineTimer.
				workspace.transport.FineTimer.hold(3.0);
				var target = targetOf(adopted.workspace, adopted.folders, adopted.scratch);
				var root = target.folders.length > 0 ? target.folders[0] : target.scratch;
				if (root != null) Sys.setCwd(root);
				return target;
			}
			if (report.abandoned || report.stopRequest != null) {
				exohost.ExohostClient.unregister();
				return null;
			}
		}
	}

	/**
		A spare runs once what every service's start runs first, so an adopted spare starts as fast as a running process
		can: SQLite loaded and opened, the hashing that names the pipe.
	**/
	static function warm():Void {
		var path = Path.join([AgentState.base(), "spare-" + Sys.getPid() + ".sqlite"]);
		try {
			var db = sqlitekit.Database.open(path, 1000);
			db.exec("PRAGMA journal_mode=WAL");
			db.exec("PRAGMA synchronous=FULL");
			db.exec("CREATE TABLE warm (id INTEGER PRIMARY KEY)");
			db.exec("INSERT INTO warm VALUES (1)");
			db.close();
		} catch (_:Dynamic) {}
		for (file in [path, path + "-wal", path + "-shm", path + ".sqlitekit-lock"])
			try if (FileSystem.exists(file)) FileSystem.deleteFile(file) catch (_:Dynamic) {}
		haxe.crypto.Sha256.encode("warm");
	}

	/** The providers' programs: the EXOSUIT_*_BIN overrides, else found on PATH. */
	static function providerPrograms():ProviderPrograms {
		function program(variable:String, name:String):String {
			var configured = Sys.getEnv(variable);
			return process.ExecutablePath.resolve(configured == null ? name : configured);
		}
		var codexProxy = Sys.getEnv("EXOSUIT_CODEX_PROXY_LAUNCHER");
		if (codexProxy == null || codexProxy.length == 0) codexProxy = AgentState.codexProxy();
		return {
			codex: program("EXOSUIT_CODEX_BIN", "codex"), codexScript: Sys.getEnv("EXOSUIT_CODEX_SCRIPT"), codexProxy: codexProxy,
			claude: program("EXOSUIT_CLAUDE_BIN", "claude"), claudeScript: Sys.getEnv("EXOSUIT_CLAUDE_SCRIPT"),
			pi: program("EXOSUIT_PI_BIN", "pi"), piScript: Sys.getEnv("EXOSUIT_PI_SCRIPT")
		};
	}

	/** The idle limit: `EXOSUIT_SERVICE_IDLE_SECONDS`, else ten minutes. */
	static function idleMilliseconds():Int {
		var configured = Std.parseFloat(Sys.getEnv("EXOSUIT_SERVICE_IDLE_SECONDS"));
		return Std.int((Math.isNaN(configured) || configured < 1 ? IDLE_SECONDS : configured) * 1000);
	}

	/** Serves `target` until it is idle or exohost asks it to stop; the exit status. */
	static function serve(target:ServiceTarget, programs:Null<ProviderPrograms>, runtime:Runtime, hub:NativeRpcHub, report:ExohostServiceLink):Int {
		var stateDirectory = AgentState.directoryOf(target.workspace);
		AgentState.prepare(stateDirectory);
		ServiceLog.open(Path.join([stateDirectory, "service.log"]));
		var lock = AgentNative.acquireLock(Path.join([stateDirectory, "agent.lock"]));
		if (lock == null) {
			ServiceLog.note("not started: another service runs this workspace");
			return IN_USE;
		}
		var code = 0;
		try code = serveLocked(target, programs, stateDirectory, runtime, hub, report) catch (error:Dynamic) {
			try AgentNative.releaseLock(lock) catch (_:Dynamic) {}
			throw error;
		}
		AgentNative.releaseLock(lock);
		return code;
	}

	static function serveLocked(target:ServiceTarget, programs:Null<ProviderPrograms>, stateDirectory:String, runtime:Runtime, hub:NativeRpcHub,
			report:ExohostServiceLink):Int {
		var workspaceId = target.workspace;
		var identity = AgentState.claim(stateDirectory, workspaceId, target.folders, target.scratch);
		var root = identity.primaryRoot();
		var instance = AgentNative.randomToken().substr(0, 32);
		ServiceLog.note('service starting: generation $instance, pid ${Sys.getPid()}');
		var stableLease:Null<String> = null;
		var stableBundle = Sys.getEnv("EXOSUIT_STABLE_BUNDLE");
		if (stableBundle != null && stableBundle.length > 0) {
			stableBundle = FileSystem.fullPath(stableBundle);
			if (!FileSystem.isDirectory(stableBundle)) throw "Stable workspace-agent snapshot is missing";
			stableLease = Path.join([stableBundle, ".running-daemon-" + Sys.getPid()]);
			AtomicFile.create(stableLease, Std.string(Sys.getPid()) + "\n");
		}
		// Listen, open the catalog and report before the rest starts: exohost answers the editor that waits on this start,
		// and its connection (and Hello) waits in the pipe while the terminals and agents come up. The server takes the
		// connections that came meanwhile once it exists.
		var socket = AgentState.endpointOf(workspaceId, stateDirectory);
		if (Sys.systemName() != "Windows" && socket.length > 100)
			throw "State directory path is too long for a local socket";
		AgentState.prepareSocketFolder(socket);
		var early:Array<NativeRpcTransport> = [];
		var accept:NativeRpcTransport->Void = function(transport) early.push(transport);
		hub.listen(NativeRpcHub.local(socket), function(transport) accept(transport));
		var directories = new workspace.runtime.WorkspaceDirectories(root);
		exohost.ExohostClient.registerWorkspaceService(exohost.ExohostKind.WorkspaceHost, {root: directories.root, stateDir: stateDirectory,
			generation: instance, workspace: workspaceId});
		// The catalog opens before the report (about 3 ms): a catalog that cannot be opened (damaged, or of a newer build)
		// ends the service before exohost hands its pipe out, so exohost answers the open with the reason service.log names.
		// The seed epoch is used only when creating a new catalog. Reopening preserves it. A new catalog has no groups:
		// the workspace itself holds sessions and terminals until groups are made.
		var database = Path.join([stateDirectory, "catalog.sqlite"]);
		var seedEpoch = AgentNative.randomToken().substr(0, 32);
		var seed = new WorkspaceService("workspace", seedEpoch, []);
		var store = new WorkspaceSqliteStore(database, "workspace", seed.snapshot(), AgentStateIdentity.catalogOwner(workspaceId));
		// Listening: exohost hands this pipe out from now on, and lists the service until this connection closes.
		report.serve(workspaceId, socket, instance, directories.root);
		var lifetime = new WorkspaceLifetime(idleMilliseconds());
		var processes = new process.ProcessManager();
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		var listed = workspace.WorkspaceFolders.select(identity.folders).folders;
		var folders = listed.length > 0 ? listed : [root];
		var files = new workspace.runtime.WorkspaceFileService("workspace", folders, clock, runtime.events);
		var scm = new workspace.runtime.WorkspaceScmService("workspace", folders, processes, Sys.getEnv("EXOSUITE_GIT_BIN"));
		var service = new WorkspaceService("workspace", seedEpoch, seed.snapshot().groups, 256, 16, store, directories.resolve);
		// Each terminal's PTY lives in a host process of its own that outlives this daemon; a later generation adopts it.
		var terminalHosts = new workspace.runtime.TerminalHosts(runtime.events, stateDirectory, Path.join([AgentState.base(), "terminal-host"]),
			Sys.programPath(), directories.root, workspaceId);
		var terminals = new WorkspaceTerminalManager("workspace", instance, directories.root, terminalHosts,
			WorkspaceTerminalManager.REPLAY_BYTES, store, function() return service.snapshot().groups);
		// Chat providers are built when first needed (WorkspaceAgentService). Their programs are found on PATH then,
		// unless a spare found them before it was adopted.
		var found = programs;
		function program():ProviderPrograms {
			if (found == null) found = providerPrograms();
			return found;
		}
		var groups = function() return service.snapshot().groups;
		var agents = new workspace.provider.WorkspaceAgentService("workspace", instance, directories.root, [
			new workspace.provider.AgentProviderFactory("codex", function() return new workspace.provider.CodexProvider(instance, directories,
				groups, processes, clock, store, program().codex, program().codexProxy, program().codexScript)),
			new workspace.provider.AgentProviderFactory("claude", function() return new workspace.provider.ClaudeProvider(directories, groups,
				processes, clock, store, program().claude, program().claudeScript)),
			new workspace.provider.AgentProviderFactory("pi", function() return new workspace.provider.PiProvider(directories, groups, processes,
				clock, stateDirectory, store, program().pi, program().piScript))
		], store, FileSystem.fullPath(database));
		service.canRemoveGroup = function(group) {
			for (terminal in terminals.snapshot().terminals) if (terminal.group == group) return false;
			return agents.groupIsEmpty(group);
		};
		var server = new WorkspaceRpcServer(service, clock, null, {workspace: "workspace", root: directories.root, instance: instance},
			terminals, agents, files, scm);
		var watch = new AgentIdentityWatch(Path.join([stateDirectory, "workspace.json"]), function() return identity);
		var name = Path.withoutDirectory(StringTools.replace(root, "\\", "/"));
		var catalog = new workspace.runtime.WorkspaceCatalogService(workspaceId, instance, function() {
			var current = watch.current();
			return {name: name, folders: current.folders.copy(), scratch: current.scratch};
		}, function() return service.snapshot().groups, agents.records, agents.requestCounts,
			function() return terminals.snapshot().terminals, function() return clock() / 1000);
		server.enableCatalog(catalog.bind);
		var catalogSnapshot = new workspace.runtime.CatalogSnapshotFile(stateDirectory, workspaceId, catalog, function() return clock() / 1000);
		server.enableFolders(function(requested) return workspace.runtime.WorkspaceFolderChange.apply(requested, stateDirectory, directories.root, files, scm).folders);
		accept = server.acceptLocal;
		for (transport in early)
			server.acceptLocal(transport);
		early.resize(0);
		ServiceLog.note('service ready on $socket for ${directories.root}');
		AgentNative.installStopSignals();
		// Busy until then: the loop turns every 10 ms for a moment after anything happened, so replies, catalog pushes and
		// file-change batches that follow it go out at once.
		var hotUntil:Float = clock() + 500;
		var reason = "idle";
		while (true) {
			// Provider processes are read by polling; everything else wakes the event wait.
			var polled = processes.activeCount() > 0;
			runtime.events.wait(clock() < hotUntil ? 0.01 : polled ? 0.05 : 1.0);
			for (_ in 0...128) {
				if (!runtime.events.poll())
					break;
				hotUntil = clock() + 500;
			}
			report.poll();
			server.poll();
			catalog.poll();
			catalogSnapshot.poll();
			files.poll();
			scm.poll();
			// Runtime ownership survives client disconnects.
			terminals.poll();
			agents.poll();
			// exohost asked: at once, or (a restart onto another build) once no agent turn runs.
			var asked = report.stopRequest;
			if (asked == "now" || asked == "turn" && agents.activeCount() == 0) {
				reason = asked == "now" ? "exohost asked it to stop" : "exohost restarts it on another build";
				break;
			}
			if (AgentNative.stopRequested()) {
				reason = "a stop signal (console close, Ctrl+C or logoff)";
				break;
			}
			// Terminals do not keep the service: their hosts keep them, and the next service adopts them.
			if (lifetime.shouldStop(clock(), server.clientCount(), agents.activeCount(), agents.updateActivityCount()))
				break;
		}
		catalogSnapshot.write();
		ServiceLog.note("service stopped: " + reason + ", " + terminals.activeCount() + " terminal(s) kept running by their hosts");
		exohost.ExohostClient.unregister();
		agents.dispose();
		processes.shutdown();
		terminals.dispose();
		server.dispose();
		files.dispose();
		store.close();
		if (stableLease != null && FileSystem.exists(stableLease))
			try FileSystem.deleteFile(stableLease) catch (_:Dynamic) {}
		return 0;
	}
}
