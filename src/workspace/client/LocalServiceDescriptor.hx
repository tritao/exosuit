package workspace.client;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import workspace.client.LocalWorkspaceClient.LocalWorkspaceEndpoint;

@:hlNative("haxeon_runtime", "__host_check_private_directory")
extern function descriptorPrivateDirectory(path:String):Bool;

@:hlNative("haxeon_runtime", "__host_check_private_file")
extern function descriptorPrivateFile(path:String):Bool;

/**
	A running workspace service's own descriptor, read by the editor itself: `endpoint.json` in the service's state
	folder, which the manager writes once it listens. The agent's launcher (`--discover`) reads the same file, but as a
	process of its own it costs about a second before it answers (HashLink start, and the build identity it adds). Read
	here, a window can connect at once and let the launcher's answer follow.

	Only a descriptor in a folder private to this user counts, and only one that names a local endpoint of the agent's
	own shape. Whether a service still listens there is not decided here: the caller connects and checks the service's
	identity against `generation`. `expectedBuild` is absent: only the launcher knows it.
**/
class LocalServiceDescriptor {
	static inline final LIMIT = 16384;

	/**
		The default state folder of the service of `workspace` (or of the folder `root` when `workspace` is null), as the
		agent's `AgentManager.stateDirectory` names it. `stateHome` is EXOSUIT_AGENT_STATE_HOME as the launcher would see it.
	**/
	public static function defaultStateDirectory(workspace:Null<String>, root:String, stateHome:Null<String>):String {
		var base = stateHome != null && stateHome.length > 0 ? stateHome : suit.MachineCatalog.agentStateBase();
		var name = workspace != null ? workspace : haxe.crypto.Sha256.encode(root).substr(0, 20);
		return Path.join([base, "workspaces", name]);
	}

	/** The descriptor in `directory`, or null when there is none this editor may use. Never throws. */
	public static function read(directory:String):Null<LocalWorkspaceEndpoint> {
		try {
			var path = Path.join([directory, "endpoint.json"]);
			if (!FileSystem.exists(path) || !descriptorPrivateDirectory(directory) || !descriptorPrivateFile(path)) return null;
			var content = File.getContent(path);
			if (content.length > LIMIT) return null;
			var value:Dynamic = haxe.Json.parse(content);
			if (value == null || !Reflect.isObject(value) || Std.isOfType(value, Array)) return null;
			var generation = text(value, "generation"), socket = text(value, "socket"), root = text(value, "root");
			var windows = Sys.systemName() == "Windows";
			if (number(value, "version") != 1 || number(value, "protocol") != 1 || number(value, "codec") != 1
				|| text(value, "workspace") != "workspace" || generation.length != 32 || root.length == 0
				|| !WorkspaceConnections.validEndpoint(socket, windows)) return null;
			// As the launcher requires it: off Windows a service listens on the socket in its own state folder, and
			// nowhere else. (On Windows validEndpoint admits only a local pipe's name.)
			if (!windows && socket != Path.join([directory, "agent.sock"])) return null;
			var launcher = text(value, "launcher"), workspaceId = text(value, "workspaceId");
			return {
				version: 1, protocol: 1, codec: 1, workspace: "workspace", root: root, managerPid: number(value, "managerPid"),
				generation: generation, socket: socket, websocket: text(value, "websocket"), credentialFile: text(value, "credentialFile"),
				expectedBuild: null, launcher: launcher.length == 0 ? null : launcher, workspaceId: workspaceId.length == 0 ? null : workspaceId
			};
		} catch (_:Dynamic) return null;
	}

	static function text(value:Dynamic, field:String):String {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) ? result : "";
	}

	static function number(value:Dynamic, field:String):Int {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Int) ? result : -1;
	}
}
