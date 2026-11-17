package workspace.runtime;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import haxeon.rpc.MessageTransport;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import terminalsession.TerminalProfile;
import workspace.transport.NativeRpcHub;

/**
	A private copy of the terminal host program, HashLink and the libraries, outside any build tree: what terminal hosts run
	from.

	A host lives as long as its terminal, across rebuilds of the tree the service runs from. Run from that tree it would
	keep `hl.exe` and the libraries locked (a build could not replace them) and would have to be stopped for every
	build, which is what ended the user's terminals. The copy is named by the sizes and times of the files it was made
	from, so each build gets its own and a running host's files are never replaced.

	Each build that starts a terminal leaves one copy (about 15 MB). Making a copy removes the others that no host runs
	from (`removeUnused`): a running host holds a lease file in its copy, and on Windows its executable cannot be deleted.
**/
class TerminalHostRuntime {
	public final executable:String;
	public final program:String;
	/** The library search path a host needs: the copy's own folders and the system's, nothing from a build tree. */
	public final libraryPath:String;

	function new(executable:String, program:String, libraryPath:String) {
		this.executable = executable;
		this.program = program;
		this.libraryPath = libraryPath;
	}

	static function isLibrary(name:String):Bool {
		var lowered = name.toLowerCase();
		return StringTools.endsWith(lowered, ".hdll") || StringTools.endsWith(lowered, ".dll") || StringTools.endsWith(lowered, ".dylib")
			|| StringTools.endsWith(lowered, ".so") || lowered.indexOf(".so.") > 0;
	}

	static function isDirectory(path:String):Bool
		return FileSystem.exists(path) && FileSystem.isDirectory(path);

	/** A copy this young may belong to a service of another build that has not started its first host yet. */
	static inline final YOUNG_COPY_SECONDS = 600.0;
	/** A staging folder this old was left by a service that died while copying. */
	static inline final STALE_STAGING_SECONDS = 3600.0;

	/** The lease a host keeps in the copy it runs from, for as long as it runs. */
	public static function leasePath(copy:String, pid:Int):String
		return Path.join([copy, "host-" + pid + ".lease"]);

	public static function age(path:String):Float {
		// `modified` is in seconds since 1970.
		try {
			var metadata = FileSystem.metadata(path);
			return metadata == null ? 0 : Sys.time() - metadata.modified;
		} catch (_:Dynamic) return 0;
	}

	static function removeTree(path:String):Void {
		try {
			if (FileSystem.isDirectory(path)) {
				for (name in FileSystem.readDirectory(path)) removeTree(Path.join([path, name]));
				FileSystem.deleteDirectory(path);
			} else FileSystem.deleteFile(path);
		} catch (_:Dynamic) {}
	}

	/** True when a lease in `copy` names a process that runs. Leases of hosts that are gone are removed. */
	static function leased(copy:String):Bool {
		var held = false;
		for (name in FileSystem.readDirectory(copy)) {
			if (!StringTools.startsWith(name, "host-") || !StringTools.endsWith(name, ".lease")) continue;
			var pid = Std.parseInt(name.substr(5, name.length - 11));
			var path = Path.join([copy, name]);
			var executable:Null<String> = null;
			try executable = StringTools.trim(File.getContent(path)) catch (_:Dynamic) {}
			if (pid != null && pid > 0 && app.AgentNative.processAlive(pid, executable == null || executable.length == 0 ? null : executable))
				held = true;
			else try FileSystem.deleteFile(path) catch (_:Dynamic) {}
		}
		return held;
	}

	/**
		Removes the runtime copies under `base` that no host runs from, keeping `keep` (the running service's own) and
		copies made in the last ten minutes. A copy is in use when a host's lease in it names a running process, or when
		its executable cannot be deleted (Windows refuses for a running program, which also covers hosts from builds that
		wrote no lease). The executable goes first, so a copy in use loses nothing. Returns the names removed.
	**/
	public static function removeUnused(base:String, keep:String):Array<String> {
		var removed:Array<String> = [];
		if (!isDirectory(base)) return removed;
		for (name in FileSystem.readDirectory(base)) {
			var copy = Path.join([base, name]);
			if (name == keep || !isDirectory(copy)) continue;
			if (name.indexOf(".tmp-") > 0) {
				if (age(copy) >= STALE_STAGING_SECONDS) {
					removeTree(copy);
					removed.push(name);
				}
				continue;
			}
			var marker = Path.join([copy, "complete"]);
			if (FileSystem.exists(marker) && age(marker) < YOUNG_COPY_SECONDS) continue;
			try {
				if (leased(copy)) continue;
				for (file in FileSystem.readDirectory(copy)) {
					var lowered = file.toLowerCase();
					if (lowered == "hl" || lowered == "hl.exe" || StringTools.startsWith(lowered, "exosuit-agent")) FileSystem.deleteFile(Path.join([copy, file]));
				}
			} catch (_:Dynamic) {
				continue; // A host runs from it.
			}
			removeTree(copy);
			removed.push(name);
		}
		return removed;
	}

	public static function prepare(base:String, agentProgram:String):TerminalHostRuntime {
		var made = make(base, agentProgram, true);
		if (made == null) throw "Terminal host runtime copy was not made";
		return made;
	}

	/**
		What a service does at its start instead of copying (the copy waits for its first terminal): removes the older
		builds' copies that no host runs from, keeping this build's. Reads only file sizes and times.
	**/
	public static function sweep(base:String, agentProgram:String):Void
		make(base, agentProgram, false);

	/**
		The bytecode hosts run: the terminal host built on its own beside the agent program `agentProgram` (a source
		build's agent/build/terminal-host, a bundle's `exosuit-terminal-host.hl`). It is a small program that starts
		quickly, so a new terminal's shell starts sooner.
	**/
	static function hostProgram(agentProgram:String):String {
		var agentDirectory = Path.directory(FileSystem.fullPath(agentProgram));
		for (candidate in [Path.join([Path.directory(agentDirectory), "terminal-host", "host", "main.hl"]),
			Path.join([agentDirectory, "exosuit-terminal-host.hl"])])
			if (FileSystem.exists(candidate)) return FileSystem.fullPath(candidate);
		throw "The terminal host program is missing beside " + agentProgram + " (build agent/terminal-host)";
	}

	static function make(base:String, agentProgram:String, copy:Bool):Null<TerminalHostRuntime> {
		var windows = Sys.systemName() == "Windows";
		var executable = FileSystem.fullPath(Sys.executablePath());
		var program = FileSystem.fullPath(Sys.programPath());
		var executableDirectory = Path.directory(executable), programDirectory = Path.directory(program);
		var files:Array<{to:String, from:String}> = [];
		var seen:Map<String, Bool> = [];
		var folders:Array<String> = [""];
		function add(to:String, from:String):Void {
			var key = to.toLowerCase();
			if (seen.exists(key)) return;
			seen.set(key, true);
			files.push({to: to, from: from});
		}
		function addLibraries(directory:String, prefix:String):Void {
			for (name in FileSystem.readDirectory(directory)) {
				var source = Path.join([directory, name]);
				if (isLibrary(name) && !FileSystem.isDirectory(source)) add(prefix + name, source);
			}
		}
		var executableName = Path.withoutDirectory(executable);
		add(executableName, executable);
		// Not `main.hl`: exohost recognizes services by that name and would stop a host with them.
		add("terminal-host.hl", hostProgram(agentProgram));
		addLibraries(executableDirectory, "");
		// A source build keeps each package's libraries in native/<package> beside the program; an installed one in ../lib.
		var nativeRoot = Path.join([programDirectory, "native"]);
		if (isDirectory(nativeRoot)) {
			addLibraries(nativeRoot, "native/");
			folders.push("native");
			for (entry in FileSystem.readDirectory(nativeRoot)) {
				var inner = Path.join([nativeRoot, entry]);
				if (!FileSystem.isDirectory(inner)) continue;
				addLibraries(inner, "native/" + entry + "/");
				folders.push("native/" + entry);
			}
		}
		var installed = Path.join([Path.directory(programDirectory), "lib"]);
		if (isDirectory(installed)) addLibraries(installed, "");
		// Whatever else the running program loads its HashLink libraries from.
		var variable = windows ? "PATH" : Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH";
		var search = Sys.getEnv(variable);
		if (search != null)
			for (directory in search.split(windows ? ";" : ":")) {
				if (directory.length == 0 || !isDirectory(directory)) continue;
				var holdsHashLink = false;
				for (name in FileSystem.readDirectory(directory))
					if (StringTools.endsWith(name.toLowerCase(), ".hdll")) {
						holdsHashLink = true;
						break;
					}
				if (holdsHashLink) addLibraries(directory, "");
			}
		var lines:Array<String> = [];
		for (file in files) {
			var metadata = FileSystem.metadata(file.from);
			if (metadata == null) throw "Terminal host runtime file is missing: " + file.from;
			lines.push(file.to + "|" + metadata.size + "|" + metadata.modified);
		}
		lines.sort(Reflect.compare);
		var key = Sha256.encode(lines.join("\n")).substr(0, 16);
		var target = Path.join([base, key]);
		if (copy && !FileSystem.exists(Path.join([target, "complete"]))) {
			var staging = target + ".tmp-" + Sys.getPid();
			try {
				for (folder in folders) FileSystem.createDirectory(folder == "" ? staging : Path.join([staging, folder]));
				for (file in files) File.copy(file.from, Path.join([staging, file.to]));
				File.saveContent(Path.join([staging, "complete"]), lines.join("\n") + "\n");
				FileSystem.rename(staging, target);
			} catch (failure:Dynamic) {
				// A copy that failed half way, or lost to another service making the same one, leaves nothing behind.
				removeTree(staging);
				if (!FileSystem.exists(Path.join([target, "complete"]))) throw failure;
			}
		}
		// Older builds' copies that no host runs from any more: each is about 15 MB.
		try {
			var removed = removeUnused(base, key);
			if (removed.length > 0) ServiceLog.note("removed " + removed.length + " unused terminal host runtime cop" + (removed.length == 1 ? "y" : "ies") + ": " + removed.join(", "));
		} catch (_:Dynamic) {}
		if (!copy) return null;
		var path:Array<String> = [];
		for (folder in folders) {
			var directory = folder == "" ? target : Path.join([target, folder]);
			if (isDirectory(directory)) path.push(windows ? StringTools.replace(directory, "/", "\\") : directory);
		}
		if (windows) {
			var system = Sys.getEnv("SystemRoot");
			if (system != null && system.length > 0) {
				path.push(system + "\\System32");
				path.push(system);
			}
		}
		return new TerminalHostRuntime(Path.join([target, executableName]), Path.join([target, "terminal-host.hl"]), path.join(windows ? ";" : ":"));
	}
}

/**
	Starts, finds and ends the terminal hosts of one workspace's service (docs/design/terminal-host-status.md). Each
	terminal's host has a folder under `<state>/terminal-hosts/` with `host.json` (written by the host: its pid, pipe and
	token), `host.log` and the terminal's last screen (TerminalHostProtocol.SCREEN_FILE).
**/
class TerminalHosts {
	/** The service's state folder, which holds the hosts' folders. */
	public final stateDirectory:String;
	final hub:NativeRpcHub;
	/** Made when the first terminal starts, not with the service: the copy (about 15 MB after each build) is off the start. */
	var runtime:Null<TerminalHostRuntime> = null;
	/** Where runtime copies live; the copy is made again when another build's service removed it as unused. */
	final runtimeBase:String;
	/** The agent program this service runs: the terminal host program is the one built beside it. */
	final agentProgram:String;
	final draining:Array<{transport:MessageTransport, messages:Array<Bytes>, until:Float}> = [];
	/** Hosts told to end (`end`), held until they have or are killed. */
	final ending:Array<{handle:app.AgentNative.AgentProcessIdentityHandle, pid:Int, until:Float}> = [];
	/** The folder the service started in and the workspace's id (null for a folder's service): written beside each host for exohost. */
	final root:Null<String>;
	final workspace:Null<String>;

	/**
		The hosts of the service whose state is `stateDirectory`. The runtime copy hosts run from is made when the first
		terminal starts (`spawn`); older builds' copies that no host runs from are removed now.
	**/
	public function new(events:EventPump, stateDirectory:String, runtimeBase:String, agentProgram:String, ?root:String, ?workspace:String) {
		this.stateDirectory = stateDirectory;
		this.runtimeBase = runtimeBase;
		this.agentProgram = agentProgram;
		this.root = root;
		this.workspace = workspace;
		// Its own hub: a hub carries a bounded number of streams, and the service's is for its clients.
		hub = new NativeRpcHub(events);
		try {
			if (FileSystem.exists(runtimeBase)) TerminalHostRuntime.sweep(runtimeBase, agentProgram);
		} catch (failure:Dynamic) ServiceLog.note("unused terminal host runtime copies could not be removed: " + Std.string(failure));
	}

	function folder(terminal:String):String
		return TerminalHostProtocol.directory(stateDirectory, terminal);

	/** Whether the host `host.json` names in `directory` runs. */
	static function runs(directory:String):Bool {
		var pid = hostNumber(directory, "pid");
		return pid > 0 && app.AgentNative.processAlive(pid, hostField(directory, "executable"));
	}

	/** Whether a host of `terminal` runs, whether this service is attached to it or not. */
	public function hostRuns(terminal:String):Bool
		return runs(folder(terminal));

	/** How long a host told to end has before it is killed. */
	static inline final END_SECONDS = 5.0;

	/**
		Ends the host of `terminal` and its program, for a terminal that is closed while this service is not attached to
		its host (it was lost, or has not answered yet): over its pipe (KILL, END), and by killing its process after
		END_SECONDS if it still runs. A host that has not started yet finds no spec. Nothing happens when there is none.
	**/
	public function end(terminal:String, reason:String):Void
		endFolder(folder(terminal), reason);

	/** `end` for the host whose folder is `directory`. */
	public function endFolder(directory:String, reason:String):Void {
		removeSpec(directory);
		var pipe = hostField(directory, "pipe"), token = hostField(directory, "token");
		var pid = hostNumber(directory, "pid"), executable = hostField(directory, "executable");
		if (pid <= 0 || executable == null || !app.AgentNative.processAlive(pid, executable)) return;
		ServiceLog.note("terminal host " + Path.withoutDirectory(directory) + " (pid " + pid + ") told to end: " + reason);
		// Held from now on: the handle cannot reach another process that reuses the pid.
		try {
			var held = app.AgentNative.openProcessIdentity(pid, executable);
			if (held != null) ending.push({handle: held, pid: pid, until: Sys.time() + END_SECONDS});
		} catch (_:Dynamic) {}
		if (pipe == null || token == null) return;
		try hub.connect(NativeRpcHub.local(pipe), function(result) {
			switch result {
				case Opened(opened):
					drain(opened, [TerminalHostProtocol.message(TerminalHostProtocol.ATTACH, Bytes.ofString(token)),
						TerminalHostProtocol.message(TerminalHostProtocol.KILL), TerminalHostProtocol.message(TerminalHostProtocol.END)]);
				case Failed(_, _):
					// Not answering: killed after END_SECONDS.
			}
		}) catch (_:Dynamic) {}
	}

	/** Kills the hosts told to end whose time has passed (all of them with `all`), and lets go of them. */
	function reap(all:Bool):Void {
		var now = Sys.time();
		for (entry in ending.copy()) {
			if (!all && now < entry.until) continue;
			ending.remove(entry);
			try {
				if (app.AgentNative.terminateProcess(entry.handle))
					ServiceLog.note("the terminal host (pid " + entry.pid + ") did not end when told; it was killed");
			} catch (failure:Dynamic) ServiceLog.note("the terminal host (pid " + entry.pid + ") could not be killed: " + Std.string(failure));
			try app.AgentNative.closeProcessIdentity(entry.handle) catch (_:Dynamic) {}
		}
	}

	/** How old a folder with no running host and nothing to show must be before a service start removes it. */
	static inline final DEAD_FOLDER_SECONDS = 60.0;

	/**
		Run once when a service starts. Ends nothing: a host whose terminal has no record here (the record was removed
		while the host did not answer, or the workspace's catalog was replaced or recreated) keeps its program and is
		logged; exohost lists it under its workspace, and the user ends it there. A missing record is weak evidence: a
		replaced database lacks every record at once.

		`recorded` are the ids of the terminals the service loaded. The folder of a terminal with no record, no running
		host and no last screen is removed once it is a minute old; while `recorded` is empty nothing is removed.
	**/
	public function sweep(recorded:Array<String>):Void {
		var base = Path.join([stateDirectory, "terminal-hosts"]);
		if (!FileSystem.exists(base) || !FileSystem.isDirectory(base)) return;
		var known:Map<String, Bool> = [];
		for (terminal in recorded) known.set(Path.withoutDirectory(folder(terminal)), true);
		for (name in FileSystem.readDirectory(base)) {
			var directory = Path.join([base, name]);
			if (known.exists(name) || !FileSystem.isDirectory(directory)) continue;
			if (runs(directory)) {
				ServiceLog.note("terminal host folder " + name + " (host pid " + hostNumber(directory, "pid") + ") has no terminal record in this workspace: left running;"
					+ " `exohost terminals` lists it and `exohost terminals end` ends it");
				continue;
			}
			if (recorded.length == 0) continue;
			try {
				var names = FileSystem.readDirectory(directory);
				if (names.indexOf(TerminalHostProtocol.SCREEN_FILE) >= 0 || TerminalHostRuntime.age(directory) < DEAD_FOLDER_SECONDS) continue;
				for (file in names) FileSystem.deleteFile(Path.join([directory, file]));
				FileSystem.deleteDirectory(directory);
				ServiceLog.note("removed the folder of a terminal host that is gone: " + name);
			} catch (_:Dynamic) {}
		}
	}

	/**
		Starts a host running `profile`'s program; `name` is the terminal's, for exohost's list, and `prelude` what its
		emulator shows before the program starts. Throws when the host cannot be started, and when a host of this terminal
		still runs: that one is never replaced unasked.
	**/
	public function spawn(terminal:String, profile:TerminalProfile, columns:Int, rows:Int, ?name:String, ?prelude:Bytes):HostedPtyBackend {
		var directory = folder(terminal);
		// prepareDirectory below reports a parent that could not be created.
		try FileSystem.createDirectory(Path.directory(directory)) catch (_:Dynamic) {}
		// Private to this user, as the service's state folder is: `spec.bin` holds the program's whole
		// environment and the pipe's token, and on Windows a file takes its folder's access list.
		if (!app.AgentNative.prepareDirectory(directory)) throw "The terminal host folder is not private to this user: " + directory;
		if (runs(directory)) throw "A terminal host of this terminal still runs";
		try FileSystem.deleteFile(Path.join([directory, "host.json"])) catch (_:Dynamic) {}
		// Which terminal of which workspace this host keeps: exohost lists it by this, with no service running.
		exohost.TerminalHostFolder.writeTerminal(directory, terminal, name, workspace, root);
		// Made with the first terminal; and a service of another build may have removed this one's copy while no host ran from it.
		var runtime = this.runtime;
		if (runtime == null || !FileSystem.exists(runtime.executable) || !FileSystem.exists(runtime.program)) {
			runtime = TerminalHostRuntime.prepare(runtimeBase, agentProgram);
			this.runtime = runtime;
			ServiceLog.note("terminal host runtime copy " + Path.directory(runtime.executable));
		}
		var token = app.AgentNative.randomToken();
		var pipe = Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-term-" + app.AgentNative.randomToken().substr(0, 32)
			: Path.join([directory, "host.sock"]);
		var specPath = Path.join([directory, "spec.bin"]);
		AtomicFile.writeBytes(specPath, TerminalHostProtocol.encodeSpec({
			token: token,
			pipe: pipe,
			columns: columns,
			rows: rows,
			program: profile.program,
			cwd: profile.cwd == null ? "" : profile.cwd,
			arguments: profile.arguments,
			environment: profile.childEnvironment(),
			prelude: prelude == null ? Bytes.alloc(0) : prelude
		}));
		if (!app.AgentNative.privateFile(specPath)) {
			removeSpec(directory);
			throw "The terminal host's spec file is not private to this user: " + specPath;
		}
		var variable = Sys.systemName() == "Windows" ? "PATH" : Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH";
		// Detached: outside the service's job, so stopping or killing the service leaves the host running. Its own folder is
		// its working directory, so it does not pin the workspace's.
		var child = try sys.io.ChildProcess.spawn(runtime.executable, [runtime.program, "--terminal-host", directory], directory,
			[variable], [runtime.libraryPath], true) catch (failure:Dynamic) {
				removeSpec(directory);
				throw failure;
			}
		ServiceLog.note("terminal host starting for " + terminal + " in " + directory);
		return new HostedPtyBackend(this, hub, pipe, token, TerminalHostProtocol.VERSION, child, false, directory);
	}

	/**
		Kills the host of `terminal` once its program has ended and its last screen is written: it keeps nothing more, and
		a Restart must not wait for it to go on its own. Waits up to a second for it to be gone.
	**/
	public function endExited(terminal:String):Void {
		var directory = folder(terminal);
		if (!FileSystem.exists(Path.join([directory, TerminalHostProtocol.SCREEN_FILE]))) return;
		var pid = hostNumber(directory, "pid"), executable = hostField(directory, "executable");
		if (pid <= 0 || executable == null) return;
		try {
			var held = app.AgentNative.openProcessIdentity(pid, executable);
			if (held == null) return;
			app.AgentNative.terminateProcess(held);
			app.AgentNative.closeProcessIdentity(held);
		} catch (_:Dynamic) {}
		var until = Sys.time() + 1;
		while (runs(directory) && Sys.time() < until) Sys.sleep(0.02);
	}

	/**
		Removes the spec a host was started with, for a host that did not start (or was given up on before it was ready):
		its program's environment and its token must not stay on the disk. A host that started removed it already.
	**/
	public static function removeSpec(directory:String):Void
		try FileSystem.deleteFile(Path.join([directory, "spec.bin"])) catch (_:Dynamic) {}

	static function hostField(directory:String, field:String):Null<String> {
		var path = Path.join([directory, "host.json"]);
		if (!FileSystem.exists(path)) return null;
		try {
			var parsed:Dynamic = Json.parse(File.getContent(path));
			var value:Dynamic = Reflect.field(parsed, field);
			return Std.isOfType(value, String) ? cast value : null;
		} catch (_:Dynamic) {
			return null;
		}
	}

	static function hostNumber(directory:String, field:String):Int {
		try {
			var parsed:Dynamic = Json.parse(File.getContent(Path.join([directory, "host.json"])));
			var value:Dynamic = Reflect.field(parsed, field);
			return Std.isOfType(value, Int) ? cast value : 0;
		} catch (_:Dynamic) {
			return 0;
		}
	}

	/**
		The running host of `terminal` that this service is not attached to (an earlier service started it, or this one
		lost its connection), or null when none runs: no `host.json`, or one whose process is gone (a restart of the
		machine, a host ended by hand), which is then removed.
	**/
	public function adopt(terminal:String):Null<HostedPtyBackend> {
		var directory = folder(terminal);
		var pipe = hostField(directory, "pipe"), token = hostField(directory, "token");
		if (pipe == null || token == null || pipe.length == 0 || token.length == 0) return null;
		// A host started by a newer build may speak messages this service does not know. It is left alone, with its
		// record: the terminal shows as lost with its last screen, and a service of that build takes it back.
		var protocol = hostNumber(directory, "protocol");
		if (protocol > TerminalHostProtocol.VERSION) {
			ServiceLog.note('terminal host for ${terminal} speaks protocol ${protocol}, this service ${TerminalHostProtocol.VERSION}: left to a newer service');
			return null;
		}
		if (!runs(directory)) {
			try FileSystem.deleteFile(Path.join([directory, "host.json"])) catch (_:Dynamic) {}
			return null;
		}
		return new HostedPtyBackend(this, hub, pipe, token, protocol, null, true, directory, hostNumber(directory, "pid"),
			hostField(directory, "executable"));
	}

	/** The last screen a host of `terminal` kept (TerminalHostProtocol.SCREEN_FILE), or null when there is none to read. */
	public function lastScreen(terminal:String):Null<TerminalHostProtocol.TerminalScreen> {
		var path = Path.join([folder(terminal), TerminalHostProtocol.SCREEN_FILE]);
		if (!FileSystem.exists(path)) return null;
		try {
			return TerminalHostProtocol.screenOf(TerminalHostProtocol.decodeScreen(File.getBytes(path)));
		} catch (failure:Dynamic) {
			ServiceLog.note("terminal " + terminal + ": its last screen could not be read (" + Std.string(failure) + ")");
			return null;
		}
	}

	public function hasLastScreen(terminal:String):Bool
		return FileSystem.exists(Path.join([folder(terminal), TerminalHostProtocol.SCREEN_FILE]));

	/** Removes what is left of `terminal`'s host when the terminal is removed: its last screen and, once no host runs there, its folder. */
	public function forget(terminal:String):Void {
		var directory = folder(terminal);
		try FileSystem.deleteFile(Path.join([directory, TerminalHostProtocol.SCREEN_FILE])) catch (_:Dynamic) {}
		if (runs(directory)) return;
		try {
			for (file in FileSystem.readDirectory(directory)) FileSystem.deleteFile(Path.join([directory, file]));
			FileSystem.deleteDirectory(directory);
		} catch (_:Dynamic) {}
	}

	/** Sends `messages` on `transport`, then closes it: a host being told to end must get the message first. */
	public function drain(transport:MessageTransport, messages:Array<Bytes>):Void
		draining.push({transport: transport, messages: messages, until: Sys.time() + 2});

	public function poll():Void {
		if (ending.length > 0) reap(false);
		if (draining.length == 0) return;
		var now = Sys.time();
		for (entry in draining.copy()) {
			while (entry.messages.length > 0 && entry.transport.send(entry.messages[0])) entry.messages.shift();
			// Once everything is handed over, the pipe is held only long enough for it to leave: the host closes its end
			// when it has read an END.
			if (entry.messages.length == 0 && entry.until > now + 0.25) entry.until = now + 0.25;
			if (!entry.transport.isOpen() || now >= entry.until) {
				entry.transport.close();
				draining.remove(entry);
			}
		}
	}

	/** Detaches from every host; their programs keep running. Hosts told to end that still run are killed. */
	public function dispose():Void {
		reap(true);
		for (entry in draining) {
			while (entry.messages.length > 0 && entry.transport.send(entry.messages[0])) entry.messages.shift();
			entry.transport.close();
		}
		draining.resize(0);
		hub.dispose();
	}
}
