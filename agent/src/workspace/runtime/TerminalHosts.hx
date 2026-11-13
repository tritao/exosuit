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
import terminalsession.TerminalBackend;
import terminalsession.TerminalProfile;
import workspace.transport.NativeRpcHub;

/**
	A private copy of the running program and its libraries, outside any build tree: what terminal hosts run from.

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

	public static function ensureDirectory(path:String):Void {
		if (isDirectory(path)) return;
		var parent = Path.directory(path);
		if (parent != null && parent.length > 0 && parent != path) ensureDirectory(parent);
		if (!isDirectory(path)) FileSystem.createDirectory(path);
	}

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
			if (pid != null && pid > 0 && app.AgentManagerNative.processAlive(pid, executable == null || executable.length == 0 ? null : executable))
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

	public static function prepare(base:String):TerminalHostRuntime {
		var made = make(base, true);
		if (made == null) throw "Terminal host runtime copy was not made";
		return made;
	}

	/**
		What a service does at its start instead of copying (the copy waits for its first terminal): removes the older
		builds' copies that no host runs from, keeping this build's. Reads only file sizes and times.
	**/
	public static function sweep(base:String):Void
		make(base, false);

	static function make(base:String, copy:Bool):Null<TerminalHostRuntime> {
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
		// Not `main.hl`: suit recognizes services by that name and would stop a host with them.
		add("terminal-host.hl", program);
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
				for (folder in folders) ensureDirectory(folder == "" ? staging : Path.join([staging, folder]));
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

/** The messages of a host's final file, read as if the host sent them. */
class RecordedHostTransport implements MessageTransport {
	final messages:Array<Bytes>;

	public function new(messages:Array<Bytes>) this.messages = messages;

	public function isOpen():Bool return messages.length > 0;

	public function send(message:Bytes):Bool return true;

	public function receive():Null<Bytes> return messages.shift();

	public function close():Void messages.resize(0);
}

/**
	Starts and finds terminal hosts for one workspace's service (docs/design/terminal-host-status.md). Each terminal's
	host has a folder under `<state>/terminal-hosts/` with `host.json` (written by the host: its pipe and token) and
	`host.log`.
**/
class TerminalHosts {
	final stateDirectory:String;
	final hub:NativeRpcHub;
	/** Made when the first terminal starts, not with the service: the copy (about 15 MB after each build) is off the start. */
	var runtime:Null<TerminalHostRuntime> = null;
	/** Where runtime copies live; the copy is made again when another build's service removed it as unused. */
	final runtimeBase:String;
	final draining:Array<{transport:MessageTransport, messages:Array<Bytes>, until:Float}> = [];
	/** Earlier hosts of restarted terminals, held until they end or are killed (`endExisting`). */
	final retiring:Array<{handle:app.AgentManagerNative.AgentProcessIdentityHandle, pid:Int, until:Float}> = [];
	/** The folder the service started in and the workspace's id (null for a folder's service): written beside each host for suit. */
	final root:Null<String>;
	final workspace:Null<String>;

	function new(events:EventPump, stateDirectory:String, runtimeBase:String, root:Null<String>, workspace:Null<String>) {
		this.stateDirectory = stateDirectory;
		this.runtimeBase = runtimeBase;
		this.root = root;
		this.workspace = workspace;
		// Its own hub: a hub carries a bounded number of streams, and the service's is for its clients.
		hub = new NativeRpcHub(events);
	}

	/**
		Whether this service keeps its terminals in hosts. `EXOSUIT_TERMINAL_HOST` decides when set (`1` on, anything else
		off). Unset, hosts are on for a Windows service on the user's own state.
	**/
	public static function enabled():Bool {
		var asked = Sys.getEnv("EXOSUIT_TERMINAL_HOST");
		if (asked != null && asked.length > 0) return asked == "1";
		if (Sys.systemName() != "Windows") return false;
		// A test or a worktree run keeps its state apart; hosts it left behind would outlive it unseen.
		for (variable in ["EXOSUIT_AGENT_STATE_HOME", "PRAGTICAL_PORTABLE", "XDG_STATE_HOME"]) {
			var value = Sys.getEnv(variable);
			if (value != null && value.length > 0) return false;
		}
		return true;
	}

	/**
		The hosts of the service whose state is `stateDirectory`, or null when hosts are off; terminals then live inside the
		service, as before. The runtime copy hosts run from is made when the first terminal starts (`spawn`).
	**/
	public static function create(events:EventPump, stateDirectory:String, runtimeBase:String, ?root:String, ?workspace:String):Null<TerminalHosts> {
		if (!enabled()) return null;
		try {
			ServiceLog.note("terminal hosts on: new terminals outlive this service; runtime copies under " + runtimeBase);
			if (FileSystem.exists(runtimeBase)) TerminalHostRuntime.sweep(runtimeBase);
			return new TerminalHosts(events, stateDirectory, runtimeBase, root, workspace);
		} catch (failure:Dynamic) {
			ServiceLog.note("terminal hosts unavailable, terminals will end with this service: " + Std.string(failure));
			return null;
		}
	}

	/**
		Asks the host of `terminal` to end, through its folder: for a terminal whose record is being removed by a service
		that is not attached to the host (it runs without hosts, lost the host, or the host has not answered yet). Works
		with hosts off, so it is static. Nothing happens when the terminal never had a host.
	**/
	public static function endHostOf(stateDirectory:String, terminal:String, reason:String):Void {
		var directory = TerminalHostProtocol.directory(stateDirectory, terminal);
		if (!FileSystem.exists(directory)) return;
		try {
			// To the host that `host.json` names; with none written yet, to whichever host reads it.
			var pid = hostNumber(directory, "pid"), token = hostField(directory, "token");
			suit.TerminalHostFolder.requestEnd(directory, reason, pid > 0 ? pid : null, token == null ? null : TerminalHostProtocol.instanceOf(token));
			ServiceLog.note("terminal host asked to end for " + terminal + ": " + reason);
		} catch (_:Dynamic) {}
	}

	/** How old a folder with no running host and nothing to collect must be before a service start removes it. */
	static inline final DEAD_FOLDER_SECONDS = 60.0;

	/**
		Run once when a service starts, with hosts on or off. Ends nothing: a host whose terminal has no record here (the
		record was removed while no service with hosts ran, or the workspace's catalog was replaced or recreated) keeps
		its program and is logged; suit lists it under its workspace, and the user ends it there. A missing record is
		weak evidence: a replaced database lacks every record at once.

		`recorded` are the ids of the terminals the service loaded. The folder of a terminal with no record, no running
		host and no last screen to collect (`final.bin`) is removed once it is a minute old; while `recorded` is empty
		nothing is removed. Returns how many recorded terminals have a host that runs now.
	**/
	public static function sweep(stateDirectory:String, recorded:Array<String>):Int {
		var base = Path.join([stateDirectory, "terminal-hosts"]);
		if (!FileSystem.exists(base) || !FileSystem.isDirectory(base)) return 0;
		var known:Map<String, Bool> = [];
		for (terminal in recorded) known.set(Path.withoutDirectory(TerminalHostProtocol.directory(stateDirectory, terminal)), true);
		var running = 0;
		for (name in FileSystem.readDirectory(base)) {
			var directory = Path.join([base, name]);
			if (!FileSystem.isDirectory(directory)) continue;
			var pid = hostNumber(directory, "pid");
			var alive = pid > 0 && app.AgentManagerNative.processAlive(pid, hostField(directory, "executable"));
			if (known.exists(name)) {
				if (alive) running++;
				continue;
			}
			if (alive) {
				ServiceLog.note("terminal host folder " + name + " (host pid " + pid + ") has no terminal record in this workspace: left running;"
					+ " `suit terminals` lists it and `suit terminals end` ends it");
				continue;
			}
			if (recorded.length == 0) continue;
			try {
				var names = FileSystem.readDirectory(directory);
				if (names.indexOf(TerminalHostProtocol.FINAL_FILE) >= 0 || TerminalHostRuntime.age(directory) < DEAD_FOLDER_SECONDS) continue;
				for (file in names) FileSystem.deleteFile(Path.join([directory, file]));
				FileSystem.deleteDirectory(directory);
				ServiceLog.note("removed the folder of a terminal host that is gone: " + name);
			} catch (_:Dynamic) {}
		}
		return running;
	}

	/** Starts a host running `profile`'s program; `name` is the terminal's, for suit's list. Throws when the host cannot be started. */
	public function spawn(terminal:String, profile:TerminalProfile, columns:Int, rows:Int, ?name:String):TerminalBackend {
		var directory = TerminalHostProtocol.directory(stateDirectory, terminal);
		TerminalHostRuntime.ensureDirectory(Path.directory(directory));
		// Private to this user, as LocalServiceDescriptor wants a descriptor's folder: `spec.bin` holds the program's whole
		// environment and the pipe's token, and on Windows a file takes its folder's access list.
		if (!app.AgentManagerNative.prepareDirectory(directory)) throw "The terminal host folder is not private to this user: " + directory;
		// An unaddressed request was for whichever host was here before; the new one must not take it.
		var pending = suit.TerminalHostFolder.endRequest(directory);
		if (pending != null && pending.pid == null && pending.instance == null) suit.TerminalHostFolder.clearEndRequest(directory);
		// A host left for this terminal (its shell is being restarted) must not stay behind unseen.
		endExisting(directory);
		// Which terminal of which workspace this host keeps: suit lists it by this, with no service running.
		suit.TerminalHostFolder.writeTerminal(directory, terminal, name, workspace, root);
		// Made with the first terminal; and a service of another build may have removed this one's copy while no host ran from it.
		var runtime = this.runtime;
		if (runtime == null || !FileSystem.exists(runtime.executable) || !FileSystem.exists(runtime.program)) {
			runtime = TerminalHostRuntime.prepare(runtimeBase);
			this.runtime = runtime;
			ServiceLog.note("terminal host runtime copy " + Path.directory(runtime.executable));
		}
		var token = app.AgentManagerNative.randomToken();
		var pipe = Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-term-" + app.AgentManagerNative.randomToken().substr(0, 32)
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
			environment: profile.childEnvironment()
		}));
		if (!app.AgentManagerNative.privateFile(specPath)) {
			removeSpec(directory);
			throw "The terminal host's spec file is not private to this user: " + specPath;
		}
		var variable = Sys.systemName() == "Windows" ? "PATH" : Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH";
		// Detached: outside the service's job, so stopping or killing the service leaves the host running. Its own folder is
		// its working directory, so it does not pin the workspace's; the manager's lock is not passed on.
		var child = try sys.io.Process.spawn(runtime.executable, [runtime.program, "--terminal-host", directory], directory,
			[variable, "EXOSUIT_AGENT_LOCK_FD"], [runtime.libraryPath, ""], true) catch (failure:Dynamic) {
				removeSpec(directory);
				throw failure;
			}
		ServiceLog.note("terminal host starting for " + terminal + " in " + directory);
		return new HostedPtyBackend(this, hub, pipe, token, child, false, null, directory);
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

	/** How long an earlier host of a restarted terminal has to end when asked before it is killed. */
	static inline final RETIRE_SECONDS = 5.0;

	/**
		Ends the host `directory`'s `host.json` names, for Restart Terminal: over its pipe (KILL, END) and with an end
		request addressed to it, which the new host leaves alone. That host may run without answering (the reason its
		terminal showed as lost), so its process is held from now on and killed after RETIRE_SECONDS if it still runs: the
		held handle cannot reach another process that reused its id.
	**/
	function endExisting(directory:String):Void {
		var pipe = hostField(directory, "pipe"), token = hostField(directory, "token");
		var pid = hostNumber(directory, "pid"), executable = hostField(directory, "executable");
		var held:Null<app.AgentManagerNative.AgentProcessIdentityHandle> = null;
		if (pid > 0 && executable != null) try held = app.AgentManagerNative.openProcessIdentity(pid, executable) catch (_:Dynamic) {}
		try FileSystem.deleteFile(Path.join([directory, "host.json"])) catch (_:Dynamic) {}
		try FileSystem.deleteFile(Path.join([directory, TerminalHostProtocol.FINAL_FILE])) catch (_:Dynamic) {}
		if (pid > 0)
			try suit.TerminalHostFolder.requestEnd(directory, "the terminal was restarted", pid, token == null ? null : TerminalHostProtocol.instanceOf(token))
			catch (_:Dynamic) {}
		if (held != null) retiring.push({handle: held, pid: pid, until: Sys.time() + RETIRE_SECONDS});
		if (pipe == null || token == null) return;
		try hub.connect(NativeRpcHub.local(pipe), function(result) {
			switch result {
				case Opened(opened):
					drain(opened, [TerminalHostProtocol.message(TerminalHostProtocol.ATTACH, Bytes.ofString(token)),
						TerminalHostProtocol.message(TerminalHostProtocol.KILL), TerminalHostProtocol.message(TerminalHostProtocol.END)]);
				case Failed(_, _):
					// Not answering: the addressed request, and the kill after RETIRE_SECONDS, end it.
			}
		}) catch (_:Dynamic) {}
	}

	/** Kills the earlier hosts whose time to end has passed (all of them with `all`), and lets go of them. */
	function retire(all:Bool):Void {
		var now = Sys.time();
		for (entry in retiring.copy()) {
			if (!all && now < entry.until) continue;
			retiring.remove(entry);
			try {
				if (app.AgentManagerNative.terminateProcess(entry.handle))
					ServiceLog.note("the earlier terminal host (pid " + entry.pid + ") of a restarted terminal did not end when asked; it was killed");
			} catch (failure:Dynamic) ServiceLog.note("the earlier terminal host (pid " + entry.pid + ") could not be killed: " + Std.string(failure));
			try app.AgentManagerNative.closeProcessIdentity(entry.handle) catch (_:Dynamic) {}
		}
	}

	/**
		The host an earlier service generation left running for `terminal`, or null when there is none: no `host.json`, or
		one whose process is gone (a restart of the machine, a host ended by hand), which is then removed. A host that runs
		but does not answer in time reports the terminal lost when the backend is polled, and is tried again by the next
		service.
	**/
	public function adopt(terminal:String):Null<TerminalBackend> {
		var directory = TerminalHostProtocol.directory(stateDirectory, terminal);
		var pipe = hostField(directory, "pipe"), token = hostField(directory, "token");
		if (pipe == null || token == null || pipe.length == 0 || token.length == 0) return ended(terminal, directory);
		// A host started by a newer build may speak messages this service does not know. It is left alone, with its
		// record: the terminal shows as lost with its saved history, and a service of that build takes it back.
		var protocol = hostNumber(directory, "protocol");
		if (protocol > TerminalHostProtocol.VERSION) {
			ServiceLog.note('terminal host for ${terminal} speaks protocol ${protocol}, this service ${TerminalHostProtocol.VERSION}: left to a newer service');
			return null;
		}
		var pid = hostNumber(directory, "pid");
		if (pid > 0 && !app.AgentManagerNative.processAlive(pid, hostField(directory, "executable"))) {
			try FileSystem.deleteFile(Path.join([directory, "host.json"])) catch (_:Dynamic) {}
			return ended(terminal, directory);
		}
		return new HostedPtyBackend(this, hub, pipe, token, null, true, Path.join([directory, "host.json"]), directory, pid,
			hostField(directory, "executable"));
	}

	/**
		The last state of a terminal whose program ended while no service ran, from the file its host left: a backend that
		delivers the history, the screen and the exit code, then is done. Null when there is no such file.
	**/
	function ended(terminal:String, directory:String):Null<TerminalBackend> {
		var path = Path.join([directory, TerminalHostProtocol.FINAL_FILE]);
		if (!FileSystem.exists(path)) return null;
		try {
			var messages = TerminalHostProtocol.decodeFinal(File.getBytes(path));
			ServiceLog.note("terminal " + terminal + " ended while no service ran: its host left the last screen and exit code");
			// No folder: there is no host an end request could reach.
			return new HostedPtyBackend(this, hub, "", "", null, true, null, null, 0, null, new RecordedHostTransport(messages), path);
		} catch (failure:Dynamic) {
			ServiceLog.note("terminal " + terminal + ": the last screen its host left could not be read (" + Std.string(failure) + ")");
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

	/** Sends `messages` on `transport`, then closes it: a host being told to end must get the message first. */
	public function drain(transport:MessageTransport, messages:Array<Bytes>):Void
		draining.push({transport: transport, messages: messages, until: Sys.time() + 2});

	public function poll():Void {
		if (retiring.length > 0) retire(false);
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

	/** Detaches from every host; their programs keep running. Earlier hosts of restarted terminals that still run are killed. */
	public function dispose():Void {
		retire(true);
		for (entry in draining) {
			while (entry.messages.length > 0 && entry.transport.send(entry.messages[0])) entry.messages.shift();
			entry.transport.close();
		}
		draining.resize(0);
		hub.dispose();
	}
}
