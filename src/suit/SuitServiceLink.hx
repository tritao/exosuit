package suit;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.rpc.RpcConnectResult;
import sys.FileSystem;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	A workspace service's link to suit (suit's SuitServices on the other end). The service connects once it listens and
	says which workspace it serves on which pipe (`service-attach`), and keeps the connection open while it runs: suit
	hands that pipe to editors from the attach on, and learns that the service stopped when the connection closes. The
	attach also names the build the service runs (its program and the build stamp beside it), so suit can tell a service
	of another build. Over the same connection suit asks the service to stop (`stop`, `now` or once no agent turn runs).

	When suit is not running, or restarts, the link tries again every few seconds; it never starts suit and never
	blocks the service.

	A warm spare (`--spare`, which suit keeps ready while an editor is linked) connects before it has a workspace
	(`service-spare`) and waits for suit to hand it one (`adopt`); it then serves that workspace and reports it over the
	same connection, as any service does. A spare whose connection closes before that ends: suit is gone.
**/
class SuitServiceLink {
	/** The wait before connecting again while suit does not answer: doubling from RETRY_SECONDS to RETRY_MAX_SECONDS. */
	static inline final RETRY_SECONDS = 2.0;
	static inline final RETRY_MAX_SECONDS = 60.0;

	final hub:NativeRpcHub;
	final attach:Dynamic;
	var transport:Null<NativeRpcTransport>;
	var connecting = false;
	var sent = false;
	var retryAt = 0.0;
	var retryDelay:Float = RETRY_SECONDS;
	var serving = false;
	/** What suit asked: null, `now`, or `turn` (stop once no agent turn runs). */
	public var stopRequest(default, null):Null<String> = null;
	/** A spare only: the workspace suit handed it (`adopt`), with the folders and scratch folder to serve. */
	public var adoption(default, null):Null<{workspace:String, folders:Array<String>, scratch:Null<String>}> = null;
	/** A spare only: the connection to suit closed (or never opened) before suit handed it a workspace. */
	public var abandoned(default, null):Bool = false;
	var spare = false;

	/** `hub` is the service's own. */
	public function new(hub:NativeRpcHub) {
		this.hub = hub;
		var program = FileSystem.fullPath(Sys.programPath());
		attach = {op: "service-attach", pid: Sys.getPid(), launcher: program, build: buildOf(program)};
	}

	/** The build stamp the compiler writes beside a program (`main.hl.build-id`), or "" without one. */
	public static function buildOf(program:String):String {
		try {
			var stamp = program + ".build-id";
			if (FileSystem.exists(stamp)) return StringTools.trim(sys.io.File.getContent(stamp));
		} catch (_:Dynamic) {}
		return "";
	}

	/** The service listens on `endpoint` now: suit lists it from here on. `generation` and `root` are what its IDENTITY says. */
	public function serve(workspace:String, endpoint:String, generation:String, root:String):Void {
		attach.op = "service-attach";
		attach.workspace = workspace;
		attach.endpoint = endpoint;
		attach.generation = generation;
		attach.root = root;
		spare = false;
		serving = true;
		sent = false;
		poll();
	}

	/** Connects as a warm spare (`service-spare`): suit answers with `adopt` (see `adoption`) or `stop`. */
	public function offerSpare():Void {
		attach.op = "service-spare";
		spare = true;
		serving = true;
		poll();
	}

	/** Call from the service's loop. */
	public function poll():Void {
		if (!serving)
			return;
		var stream = transport;
		if (stream != null && !stream.isOpen()) {
			transport = null;
			later();
			stream = null;
			if (spare) abandoned = true;
		}
		if (stream == null) {
			if (!abandoned && !connecting && Sys.time() >= retryAt)
				connect();
			return;
		}
		if (!sent)
			sent = stream.send(Bytes.ofString(Json.stringify(attach)));
		for (_ in 0...16) {
			var received:Null<Bytes> = null;
			try received = stream.receive() catch (_:Dynamic) stream.close();
			if (received == null)
				break;
			var message:Dynamic = null;
			try message = Json.parse(received.toString()) catch (_:Dynamic) {}
			if (message != null && spare && Reflect.field(message, "op") == "adopt") {
				var workspace:Dynamic = Reflect.field(message, "workspace"), folders:Dynamic = Reflect.field(message, "folders");
				var scratch:Dynamic = Reflect.field(message, "scratch");
				if (Std.isOfType(workspace, String) && Std.isOfType(folders, Array))
					adoption = {workspace: workspace, folders: [for (folder in (folders : Array<Dynamic>)) if (Std.isOfType(folder, String)) folder],
						scratch: Std.isOfType(scratch, String) ? scratch : null};
				else
					abandoned = true;
			}
			if (message != null && Reflect.field(message, "op") == "stop") {
				var when:Dynamic = Reflect.field(message, "when");
				// "now" outranks a stop already waiting for a turn to end.
				if (stopRequest != "now")
					stopRequest = when == "turn" ? "turn" : "now";
			}
		}
	}

	function connect():Void {
		connecting = true;
		sent = false;
		try {
			hub.connect(NativeRpcHub.local(SuitPaths.endpoint()), function(result:RpcConnectResult) {
				connecting = false;
				switch result {
					case Opened(opened):
						transport = cast opened;
						retryDelay = RETRY_SECONDS;
						poll();
					default:
						later();
						if (spare) abandoned = true;
				}
			});
		} catch (_:Dynamic) {
			connecting = false;
			later();
		}
	}

	function later():Void {
		retryAt = Sys.time() + retryDelay;
		retryDelay = Math.min(retryDelay * 2, RETRY_MAX_SECONDS);
	}

	public function dispose():Void {
		var stream = transport;
		transport = null;
		serving = false;
		if (stream != null)
			stream.close();
	}
}
