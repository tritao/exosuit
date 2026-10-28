package suit.relay;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import suit.SuitInventory;
import suit.SuitPaths;
import workspace.transport.RelayMachineEndpoint;

/** Creates a directory readable only by this user, or checks that an existing one is. */
@:hlNative("haxeon_runtime", "__host_prepare_private_directory")
extern function preparePrivateRelayDirectory(path:String):Bool;

/** A workspace suit hosts: what it needs to hold its machine socket and start its manager. No secrets. */
typedef SuitRelayHost = {
	var root:String;
	var stateDir:String;
	var machineId:String;
	var origin:String;
	var executable:String;
	var launcher:String;
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
			try host = parse(readJson(path)) catch (_:Dynamic) {}
			if (host == null || readSettings(host.stateDir) == null) {
				try FileSystem.deleteFile(path) catch (_:Dynamic) {}
				continue;
			}
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
			launcher: host.launcher
		}) + "\n");
	}

	public static function remove(machineId:String):Void {
		var path = Path.join([directory(), machineId + ".json"]);
		try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}

	/**
		Checks a daemon's `relay-attach` request against its private state directory and returns the host.
		Throws a short reason the daemon can act on: `hosting_paused` keeps it from dialling the relay itself.
	**/
	public static function validate(request:Dynamic):SuitRelayHost {
		if (SuitInventory.intField(request, "version") != SuitRelayProtocol.VERSION)
			throw "unsupported_relay_attach";
		var host:Null<SuitRelayHost> = parse(request);
		if (host == null)
			throw "invalid_relay_attach";
		if (!FileSystem.exists(host.stateDir) || !FileSystem.isDirectory(host.stateDir) || !preparePrivateRelayDirectory(host.stateDir))
			throw "workspace_state_not_private";
		var identity:Dynamic = null;
		try identity = readJson(Path.join([host.stateDir, "workspace.json"])) catch (_:Dynamic) {}
		if (identity == null || SuitInventory.stringField(identity, "root") != host.root)
			throw "workspace_mismatch";
		var settings = readSettings(host.stateDir);
		if (settings == null)
			throw "relay_not_configured";
		var configured = new RelayMachineEndpoint(SuitInventory.stringField(settings, "origin"), host.machineId);
		if (configured.origin != new RelayMachineEndpoint(host.origin, host.machineId).origin)
			throw "relay_mismatch";
		if (configured.isLoopbackHttp && Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") != "1")
			throw "relay_loopback_disabled";
		if (SuitInventory.stringField(settings, "hosting") == "paused")
			throw "hosting_paused";
		var machine:Dynamic = null;
		try machine = readJson(Path.join([host.stateDir, "relay-machine.json"])) catch (_:Dynamic) {}
		if (machine == null || SuitInventory.stringField(machine, "machineId") != host.machineId)
			throw "relay_mismatch";
		if (!FileSystem.exists(host.executable) || !FileSystem.exists(host.launcher))
			throw "invalid_relay_attach";
		host.origin = configured.origin;
		return host;
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
		try settings = readJson(path) catch (_:Dynamic) {}
		return settings != null && SuitInventory.intField(settings, "version") == 1 ? settings : null;
	}

	public static function isPaused(stateDir:Null<String>):Bool {
		var settings = readSettings(stateDir);
		return settings != null && SuitInventory.stringField(settings, "hosting") == "paused";
	}

	/** Pauses or resumes hosting in `relay-settings.json`; false when the workspace has no relay settings. */
	public static function setPaused(stateDir:Null<String>, paused:Bool):Bool {
		var settings = readSettings(stateDir);
		if (settings == null || stateDir == null)
			return false;
		if ((SuitInventory.stringField(settings, "hosting") == "paused") == paused)
			return true;
		var origin = SuitInventory.stringField(settings, "origin");
		var updated:Dynamic = paused ? {version: 1, origin: origin, hosting: "paused"} : {version: 1, origin: origin};
		try sys.io.AtomicFile.write(Path.join([stateDir, "relay-settings.json"]), Json.stringify(updated) + "\n") catch (_:Dynamic) return false;
		return true;
	}

	/** Matches a root path or a workspace's folder name, like `suit relay stop`. */
	public static function matches(host:SuitRelayHost, query:Null<String>):Bool {
		if (query == null)
			return true;
		if (SuitInventory.rootKey(host.root) == SuitInventory.rootKey(query))
			return true;
		var name = SuitInventory.workspaceName(host.root);
		return Sys.systemName() == "Windows" ? name.toLowerCase() == query.toLowerCase() : name == query;
	}

	static function parse(value:Dynamic):Null<SuitRelayHost> {
		if (value == null)
			return null;
		var host:SuitRelayHost = {
			root: SuitInventory.stringField(value, "root"),
			stateDir: SuitInventory.stringField(value, "stateDir"),
			machineId: SuitInventory.stringField(value, "machineId"),
			origin: SuitInventory.stringField(value, "origin"),
			executable: SuitInventory.stringField(value, "executable"),
			launcher: SuitInventory.stringField(value, "launcher")
		};
		for (field in [host.root, host.stateDir, host.machineId, host.origin, host.executable, host.launcher])
			if (field == null || field.length == 0)
				return null;
		if (!Path.isAbsolute(host.root) || !Path.isAbsolute(host.stateDir))
			return null;
		try new RelayMachineEndpoint(host.origin, host.machineId) catch (_:Dynamic) return null;
		return host;
	}

	static function readJson(path:String):Dynamic {
		var info = FileSystem.metadata(path);
		if (info == null || info.size > MAX_JSON_BYTES)
			throw "file too large";
		return Json.parse(File.getContent(path));
	}
}
