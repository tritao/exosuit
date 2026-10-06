package workspace.runtime;

import haxe.Json;
import haxe.io.Bytes;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelaySocketTicket;

/** Loads opt-in relay identity from a private one-shot bootstrap file and OS storage. */
class WorkspaceRelaySettings {
	public final endpoint:RelayMachineEndpoint;
	public final machineToken:String;

	public function new(endpoint:RelayMachineEndpoint, machineToken:String) {
		if (endpoint == null || !RelaySocketTicket.isToken(machineToken))
			throw "Invalid workspace relay credentials";
		this.endpoint = endpoint;
		this.machineToken = machineToken;
	}

	/**
		The manager creates this mode-0600 file only when remote access is enabled.
		The bearer is moved into the OS credential store and the bootstrap is removed.
	*/
	public static function loadBootstrap(path:String, ?credentials:WorkspaceCredentialStore):WorkspaceRelaySettings {
		if (path == null || path == "")
			throw "Relay bootstrap path is required";
		if (credentials == null)
			credentials = new NativeWorkspaceCredentialStore();
		var metadata = sys.FileSystem.metadata(path);
		if (metadata == null || metadata.size <= 0 || metadata.size > 4096)
			throw "Invalid relay bootstrap file";
		var raw = sys.io.File.getContent(path);
		var parsed:Dynamic;
		try
			parsed = Json.parse(raw)
		catch (_:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw "Invalid relay bootstrap data";
		}
		if (parsed == null || !Reflect.isObject(parsed) || Reflect.field(parsed, "version") != 1) {
			sys.FileSystem.deleteFile(path);
			throw "Invalid relay bootstrap version";
		}
		var origin:Dynamic = Reflect.field(parsed, "origin");
		var machineId:Dynamic = Reflect.field(parsed, "machineId");
		var bootstrapToken:Dynamic = Reflect.field(parsed, "bootstrapToken");
		if (!Std.isOfType(origin, String) || !Std.isOfType(machineId, String)
			|| !Std.isOfType(bootstrapToken, String) || !RelaySocketTicket.isToken(bootstrapToken)) {
			sys.FileSystem.deleteFile(path);
			throw "Invalid relay bootstrap fields";
		}
		var endpoint:RelayMachineEndpoint;
		try
			endpoint = new RelayMachineEndpoint(cast origin, cast machineId)
		catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		var stored:Null<Bytes>;
		try
			stored = credentials.read(credentialAccount(endpoint))
		catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		var token:String;
		if (stored == null) {
			var bytes = Bytes.ofString(cast bootstrapToken);
			try
				credentials.write(credentialAccount(endpoint), bytes)
			catch (error:Dynamic) {
				clear(bytes);
				sys.FileSystem.deleteFile(path);
				throw error;
			}
			clear(bytes);
			token = cast bootstrapToken;
		} else {
			token = stored.toString();
			clear(stored);
		}
		sys.FileSystem.deleteFile(path);
		if (!RelaySocketTicket.isToken(token))
			throw "Invalid stored relay credential";
		return new WorkspaceRelaySettings(endpoint, token);
	}

	static function credentialAccount(endpoint:RelayMachineEndpoint):String
		return "relay:" + endpoint.origin + "/machine/" + endpoint.machineId;

	static function clear(bytes:Bytes):Void {
		for (index in 0...bytes.length)
			bytes.set(index, 0);
	}
}
