package suit.relay;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import suit.SuitInventory;
import suit.SuitPaths;
import workspace.PathKey;
import workspace.transport.RelayMachineEndpoint;
import suit.SuitRecord.SuitRecords;

/** Creates a directory readable only by this user, or checks that an existing one is. */
@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateRelayDirectory(path:String):Bool;

/** A regular file of this user's, readable only by them, with one link and no reparse point. */
@:hlNative("haxeon_runtime", "__host_check_private_file")
extern function checkPrivateRelayFile(path:String):Bool;

/** A workspace suit hosts: what it needs to hold its machine socket and start its manager. No secrets. */
typedef SuitRelayHost = {
	var root:String;
	var stateDir:String;
	var machineId:String;
	var origin:String;
	var executable:String;
	var launcher:String;
	/** The workspace id of a state keyed by id, taken from its workspace.json and checked at each attach; null for a folder's state. */
	var workspace:Null<String>;
}

/**
	suit's list of hosted workspaces, one `relay-hosts/<machineId>.json` per workspace in its home, so it
	can host again after a reboot when nothing else is running. It also reads and pauses the workspace's
	own `relay-settings.json`, which stays the source of truth for whether a workspace hosts at all.
**/
class SuitRelayHosts {
	static inline var MAX_JSON_BYTES:Int = 16384;

	public static function directory():String
		return Path.join([SuitPaths.home(), "relay-hosts"]);

	/** Every valid record; a record whose workspace no longer has relay settings is removed. */
	public static function load():Array<SuitRelayHost> {
		var result:Array<SuitRelayHost> = [];
		var folder = directory();
		if (!FileSystem.exists(folder))
			return result;
		for (name in FileSystem.readDirectory(folder)) {
			if (!StringTools.endsWith(name, ".json"))
				continue;
			var path = Path.join([folder, name]);
			var host:Null<SuitRelayHost> = null;
			try host = parse(readPrivateJson(path)) catch (_:Dynamic) {}
			if (host == null || readSettings(host.stateDir) == null || !stateUsable(host)) {
				try FileSystem.deleteFile(path) catch (_:Dynamic) {}
				continue;
			}
			result.push(host);
		}
		return result;
	}

	/**
		The workspaces suit hosts now: valid records whose workspace has relay settings that are not paused.
		Reads only, so a listing can use it; `load` is the daemon's, and removes records that went stale.
	**/
	public static function active():Array<SuitRelayHost> {
		var result:Array<SuitRelayHost> = [];
		var folder = directory();
		if (!FileSystem.exists(folder))
			return result;
		for (name in FileSystem.readDirectory(folder)) {
			if (!StringTools.endsWith(name, ".json"))
				continue;
			var host:Null<SuitRelayHost> = null;
			try host = parse(readPrivateJson(Path.join([folder, name]))) catch (_:Dynamic) {}
			if (host != null && readSettings(host.stateDir) != null && stateUsable(host) && !isPaused(host.stateDir))
				result.push(host);
		}
		return result;
	}

	public static function save(host:SuitRelayHost):Void {
		var folder = directory();
		if (!preparePrivateRelayDirectory(folder))
			throw "suit's relay-hosts directory is not private";
		sys.io.AtomicFile.write(Path.join([folder, host.machineId + ".json"]), Json.stringify({
			version: 1,
			root: host.root,
			stateDir: host.stateDir,
			machineId: host.machineId,
			origin: host.origin,
			executable: host.executable,
			launcher: host.launcher,
			workspace: host.workspace
		}) + "\n");
	}

	public static function remove(machineId:String):Void {
		var path = Path.join([directory(), machineId + ".json"]);
		try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}

	/**
		Checks a daemon's `relay-attach` request and returns the host. Throws a short reason the daemon can
		act on: `hosting_paused` keeps it from dialling the relay itself.

		`caller` is the executable of the process at the other end of the pipe, from the OS. It must be the
		executable the request names, and that executable and the launcher must be an exosuit agent
		(`trustedAgent`), since suit runs them later to start the workspace on demand. Once a machine is
		recorded, an attach must name the same root, state directory, executable and launcher
		(`relay_host_changed`); `suit relay forget` clears a record. Everything read from the workspace's
		state directory is checked to be this user's private file first.
	**/
	public static function validate(request:Dynamic, caller:Null<String>, recorded:Null<SuitRelayHost>):SuitRelayHost {
		if (SuitRecords.intField(request, "version") != SuitRelayProtocol.VERSION)
			throw "unsupported_relay_attach";
		var host:Null<SuitRelayHost> = parse(request);
		if (host == null)
			throw "invalid_relay_attach";
		if (caller == null)
			throw "relay_attach_unverified";
		if (!PathKey.same(caller, host.executable) || !trustedAgent(host.executable, host.launcher)
			|| !FileSystem.exists(host.executable) || !FileSystem.exists(host.launcher))
			throw "relay_attach_untrusted";
		if (!FileSystem.exists(host.stateDir) || !FileSystem.isDirectory(host.stateDir) || !preparePrivateRelayDirectory(host.stateDir))
			throw "workspace_state_not_private";
		var identity:Dynamic = null;
		try identity = readPrivateJson(Path.join([host.stateDir, "workspace.json"])) catch (_:Dynamic) {}
		// A workspace keyed by id (M19 Phase 4) starts in its first folder, which changes as folders are attached and
		// detached: its state folder identifies it. A folder's service is identified by that folder.
		// A folder's old state that moved into a workspace is only a marker; the workspace hosts, never this state.
		if (movedAway(identity))
			throw "workspace_state_migrated";
		var keyedById = keyedByIdentity(identity);
		if (recorded != null && !sameHost(recorded, host, keyedById))
			throw "relay_host_changed";
		// A workspace keyed by id is hosted as that workspace: the state must still be the one the host was recorded for.
		var stateWorkspace:Null<String> = keyedById ? SuitRecords.stringField(identity, "workspace") : null;
		if (keyedById && (stateWorkspace == null || stateWorkspace.length == 0))
			throw "workspace_mismatch";
		if (recorded != null && recorded.workspace != null && recorded.workspace != stateWorkspace)
			throw "relay_host_changed";
		host.workspace = stateWorkspace;
		if (!keyedById && (identity == null || !PathKey.same(SuitRecords.stringField(identity, "root"), host.root)))
			throw "workspace_mismatch";
		var settings = readSettings(host.stateDir);
		if (settings == null)
			throw "relay_not_configured";
		var configured = new RelayMachineEndpoint(SuitRecords.stringField(settings, "origin"), host.machineId);
		if (configured.origin != new RelayMachineEndpoint(host.origin, host.machineId).origin)
			throw "relay_mismatch";
		if (configured.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
			throw "relay_loopback_disabled";
		if (SuitRecords.stringField(settings, "hosting") == "paused")
			throw "hosting_paused";
		var machine:Dynamic = null;
		try machine = readPrivateJson(Path.join([host.stateDir, "relay-machine.json"])) catch (_:Dynamic) {}
		if (machine == null || SuitRecords.stringField(machine, "machineId") != host.machineId)
			throw "relay_mismatch";
		host.origin = configured.origin;
		if (recorded != null) {
			// Keep the recorded spelling, so records and bridges compare alike.
			if (!keyedById)
				host.root = recorded.root;
			host.stateDir = recorded.stateDir;
		}
		return host;
	}

	/**
		An exosuit agent suit may run: HashLink (`hl`) running the agent bytecode of a source build
		(`agent/build/host/main.hl`), an installed bundle (`tools/exosuit-agent.hl`) or a stable snapshot
		(`agent/main.hl`).
	**/
	public static function trustedAgent(executable:String, launcher:String):Bool {
		var name = Path.withoutDirectory(StringTools.replace(executable, "\\", "/")).toLowerCase();
		if (name != "hl.exe" && name != "hl")
			return false;
		var key = PathKey.of(launcher, true);
		for (suffix in ["/agent/build/host/main.hl", "/tools/exosuit-agent.hl", "/agent/main.hl"])
			if (StringTools.endsWith(key, suffix))
				return true;
		return false;
	}

	/** Whether the service whose state is `stateDir` is a workspace's keyed by its id (M19 Phase 4), not a folder's. */
	public static function keyedById(stateDir:String):Bool {
		var identity:Dynamic = null;
		try identity = readPrivateJson(Path.join([stateDir, "workspace.json"])) catch (_:Dynamic) {}
		return keyedByIdentity(identity);
	}

	/** Whether a parsed workspace.json says the state moved into a workspace (M19 Phase 4's `migratedTo`). */
	static function movedAway(identity:Dynamic):Bool {
		if (identity == null)
			return false;
		var target = SuitRecords.stringField(identity, "migratedTo");
		return target != null && target.length > 0;
	}

	/**
		Whether suit may still host `host` from its state: not a state that moved into a workspace, and, for a workspace
		keyed by id, still that workspace's. An unreadable workspace.json is left to the checks at attach.
	**/
	public static function stateUsable(host:SuitRelayHost):Bool {
		var identity:Dynamic = null;
		try identity = readPrivateJson(Path.join([host.stateDir, "workspace.json"])) catch (_:Dynamic) {}
		if (movedAway(identity))
			return false;
		var recorded = host.workspace;
		if (recorded == null || identity == null)
			return true;
		return SuitRecords.stringField(identity, "workspace") == recorded;
	}

	static function keyedByIdentity(identity:Dynamic):Bool
		return identity != null && SuitRecords.stringField(identity, "workspace") != null;

	/** Whether two records name the same host; `ignoreRoot` for a workspace keyed by id, whose root follows its folders. */
	public static function sameHost(left:SuitRelayHost, right:SuitRelayHost, ignoreRoot = false):Bool
		return left.machineId == right.machineId && (ignoreRoot || PathKey.same(left.root, right.root))
			&& PathKey.same(left.stateDir, right.stateDir) && PathKey.same(left.executable, right.executable)
			&& PathKey.same(left.launcher, right.launcher);

	/** The recorded host for a machine id, or null. */
	public static function find(machineId:String):Null<SuitRelayHost> {
		for (host in load())
			if (host.machineId == machineId)
				return host;
		return null;
	}

	public static function endpoint(host:SuitRelayHost):RelayMachineEndpoint
		return new RelayMachineEndpoint(host.origin, host.machineId);

	/** The workspace's `relay-settings.json`, or null when hosting is not configured. */
	public static function readSettings(stateDir:Null<String>):Null<Dynamic> {
		if (stateDir == null)
			return null;
		var path = Path.join([stateDir, "relay-settings.json"]);
		if (!FileSystem.exists(path))
			return null;
		var settings:Dynamic = null;
		try settings = readPrivateJson(path) catch (_:Dynamic) {}
		return settings != null && SuitRecords.intField(settings, "version") == 1 ? settings : null;
	}

	public static function isPaused(stateDir:Null<String>):Bool {
		var settings = readSettings(stateDir);
		return settings != null && SuitRecords.stringField(settings, "hosting") == "paused";
	}

	/** Pauses or resumes hosting in `relay-settings.json`; false when the workspace has no relay settings. */
	public static function setPaused(stateDir:Null<String>, paused:Bool):Bool {
		var settings = readSettings(stateDir);
		if (settings == null || stateDir == null)
			return false;
		if ((SuitRecords.stringField(settings, "hosting") == "paused") == paused)
			return true;
		var origin = SuitRecords.stringField(settings, "origin");
		var updated:Dynamic = paused ? {version: 1, origin: origin, hosting: "paused"} : {version: 1, origin: origin};
		try sys.io.AtomicFile.write(Path.join([stateDir, "relay-settings.json"]), Json.stringify(updated) + "\n") catch (_:Dynamic) return false;
		return true;
	}

	/** Matches a root path or a workspace's folder name, like `suit relay stop`. */
	public static function matches(host:SuitRelayHost, query:Null<String>):Bool {
		if (query == null)
			return true;
		if (PathKey.same(host.root, query))
			return true;
		var name = SuitInventory.workspaceName(host.root);
		return Sys.systemName() == "Windows" ? name.toLowerCase() == query.toLowerCase() : name == query;
	}

	static function parse(value:Dynamic):Null<SuitRelayHost> {
		if (value == null)
			return null;
		var host:SuitRelayHost = {
			root: SuitRecords.stringField(value, "root"),
			stateDir: SuitRecords.stringField(value, "stateDir"),
			machineId: SuitRecords.stringField(value, "machineId"),
			origin: SuitRecords.stringField(value, "origin"),
			executable: SuitRecords.stringField(value, "executable"),
			launcher: SuitRecords.stringField(value, "launcher"),
			workspace: SuitRecords.stringField(value, "workspace")
		};
		for (field in [host.root, host.stateDir, host.machineId, host.origin, host.executable, host.launcher])
			if (field == null || field.length == 0)
				return null;
		if (!Path.isAbsolute(host.root) || !Path.isAbsolute(host.stateDir))
			return null;
		try new RelayMachineEndpoint(host.origin, host.machineId) catch (_:Dynamic) return null;
		return host;
	}

	/** Reads a small JSON file after checking that it is this user's private file (see checkPrivateRelayFile). */
	public static function readPrivateJson(path:String):Dynamic {
		if (!checkPrivateRelayFile(path))
			throw "not a private file";
		var info = FileSystem.metadata(path);
		if (info == null || info.size > MAX_JSON_BYTES)
			throw "file too large";
		return Json.parse(File.getContent(path));
	}
}
