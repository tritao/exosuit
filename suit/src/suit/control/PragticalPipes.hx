package suit.control;

import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.platform.event.EventPump;
import nativekit.ffi.NativeKitTypes;
import suit.LinkedEditor;
import suit.remote.MachineRemote.DeferredReply;
import sys.FileSystem;
import workspace.transport.NativeKitByteStream;
import workspace.transport.NativeRpcHub;

private class Client {
	public final stream:NativeKitByteStream;
	public var buffer:Bytes = Bytes.alloc(0);
	public var hello = false;
	public final ids:Map<String, Bool> = [];
	public final pending:Array<{id:Dynamic, reply:DeferredReply}> = [];
	public var lastActive:Float = Sys.time();

	public function new(stream:NativeKitByteStream)
		this.stream = stream;
}

private class Pipe {
	public final editor:LinkedEditor;
	public var listener:Null<OwnedListenerHandle> = null;
	/** The listener stopped (see `listen`) and is started again on the next poll. */
	public var failed = false;
	public final clients:Array<Client> = [];
	public var roots:String = "";

	public function new(editor:LinkedEditor) {
		this.editor = editor;
	}
}

/**
	Pragtical compatibility (docs/design/suitctl/TDD-exosuit-ctl.md §5.4, Q2=b): one pipe per linked editor window,
	`\\.\pipe\exosuit-suitctl-<user>-<instance id>`, that speaks Pragtical control protocol v1 byte for byte, and a
	descriptor per window in `<suit home>\runtime\instances`, so `pragtical-ctl` with `PRAGTICAL_USERDIR` set to suit's
	home lists, focuses and opens files in Exosuit windows. suit answers `control.hello` on a pipe itself and forwards
	every other method to the pipe's window through the ControlRouter, as the `control` op does. A pipe pushes only
	Pragtical's two events, `document.opened` and `project.changed`, to its clients that said hello.

	Pragtical's limits apply: hello first, requests only, a repeated id closes the connection, 10 s to finish a frame,
	300 s idle.
**/
class PragticalPipes {
	static inline final FRAME_SECONDS = 10.0;
	static inline final IDLE_SECONDS = 300.0;

	final hub:NativeRpcHub;
	final router:ControlRouter;
	final pipes:Map<String, Pipe> = [];
	var sequence = 0;

	public function new(events:EventPump, router:ControlRouter) {
		this.router = router;
		// A hub of its own: one listener per window, beside the main pipe's hub and its caps.
		hub = new NativeRpcHub(events, 128, 64);
		// Descriptors of an earlier suit point at pipes nobody serves now.
		try for (name in FileSystem.readDirectory(directory()))
			FileSystem.deleteFile(Path.join([directory(), name]))
		catch (_:Dynamic) {}
	}

	/** The pipe name of window `instance`. */
	public static function endpoint(instance:String):String
		return SuitPaths.instanceEndpoint(instance);

	/** `<suit home>/runtime/instances`: Pragtical's RUNTIME/instances with suit's home as its user folder. */
	public static function directory():String
		return Path.join([SuitPaths.home(), "runtime", "instances"]);

	/** A window linked: its pipe opens and its descriptor is written. A window unlinked: both go. */
	public function linked(editor:LinkedEditor, attached:Bool):Void {
		if (attached)
			open(editor);
		else
			close(editor.window);
	}

	function open(editor:LinkedEditor):Void {
		if (pipes.exists(editor.window))
			return;
		var pipe = new Pipe(editor);
		if (!listen(pipe))
			return; // Another process holds the name (a squatter): no Pragtical pipe for this window, and no descriptor.
		pipes.set(editor.window, pipe);
		describe(pipe);
	}

	/**
		Listens on the window's pipe. NativeKit's listener stops for good when a client connects and closes before it
		accepts (ConnectNamedPipe fails with ERROR_NO_DATA; docs/haxeon-compiler-bugs.md), which is what pragtical-ctl's
		health check does, so a stopped listener is started again on the next poll.
	**/
	function listen(pipe:Pipe):Bool {
		if (pipe.listener != null)
			try hub.forget(pipe.listener) catch (_:Dynamic) {}
		pipe.listener = null;
		pipe.failed = false;
		try {
			pipe.listener = hub.listenBytes(NativeRpcHub.local(endpoint(pipe.editor.window)), function(stream) pipe.clients.push(new Client(stream)),
				function() pipe.failed = true);
		} catch (_:Dynamic) {
			return false;
		}
		return true;
	}

	function close(window:String):Void {
		var pipe = pipes.get(window);
		if (pipe == null)
			return;
		pipes.remove(window);
		for (client in pipe.clients)
			client.stream.close();
		if (pipe.listener != null)
			try hub.forget(pipe.listener) catch (_:Dynamic) {}
		try FileSystem.deleteFile(descriptor(window)) catch (_:Dynamic) {}
	}

	static function descriptor(window:String):String
		return Path.join([directory(), window + ".msgpack"]);

	/** Writes a window's descriptor (Pragtical's `instance.lua` fields) when its roots changed. */
	function describe(pipe:Pipe):Void {
		var roots = router.projectRoots(pipe.editor);
		var key = roots.join("\n");
		if (key == pipe.roots && FileSystem.exists(descriptor(pipe.editor.window)))
			return;
		pipe.roots = key;
		try {
			createDirectory(directory());
			var path = descriptor(pipe.editor.window), content = PragticalCodec.encode({
				version: 1, instance_id: pipe.editor.window, pid: pipe.editor.pid, endpoint: endpoint(pipe.editor.window),
				started_at: Std.int(pipe.editor.started), project_roots: roots, protocol_version: 1
			});
			if (FileSystem.exists(path))
				sys.io.AtomicFile.writeBytes(path, content);
			else
				sys.io.AtomicFile.createBytes(path, content);
		} catch (_:Dynamic) {}
	}

	static function createDirectory(path:String):Void {
		if (FileSystem.exists(path))
			return;
		createDirectory(Path.directory(path));
		FileSystem.createDirectory(path);
	}

	/** A window's event: Pragtical's two events go to that window's pipe clients. */
	public function event(editor:LinkedEditor, name:String, data:Dynamic):Void {
		var pipe = pipes.get(editor.window);
		if (pipe == null)
			return;
		if (name == "exosuit.state")
			describe(pipe);
		if (name != "document.opened" && name != "project.changed")
			return;
		sequence++;
		for (client in pipe.clients)
			if (client.hello)
				send(client, {version: 1, kind: "event", sequence: sequence, event: name, data: data});
	}

	/** Reads every client's frames, answers them, and sends replies the windows have made. */
	public function poll():Void {
		var now = Sys.time();
		for (pipe in pipes) {
			if (pipe.failed)
				listen(pipe);
			var index = pipe.clients.length;
			while (index-- > 0) {
				var client = pipe.clients[index];
				read(pipe, client, now);
				var held = client.pending.length;
				while (held-- > 0) {
					var item = client.pending[held];
					if (item.reply.reply == null)
						continue;
					client.pending.splice(held, 1);
					var reply:Dynamic = item.reply.reply;
					send(client, Reflect.field(reply, "ok") == true
						? {version: 1, kind: "response", id: item.id, result: Reflect.field(reply, "result")}
						: {version: 1, kind: "response", id: item.id, error: Reflect.field(reply, "error")});
				}
				var stale = client.buffer.length > 0 ? now - client.lastActive > FRAME_SECONDS : now - client.lastActive > IDLE_SECONDS;
				if (stale && client.pending.length == 0)
					client.stream.close();
				if (!client.stream.isOpen())
					pipe.clients.splice(index, 1);
			}
		}
	}

	function read(pipe:Pipe, client:Client, now:Float):Void {
		var chunk = Bytes.alloc(16384);
		for (_ in 0...32) {
			var count = client.stream.receive(chunk);
			if (count <= 0) {
				if (count < 0)
					client.stream.close();
				break;
			}
			var joined = Bytes.alloc(client.buffer.length + count);
			joined.blit(0, client.buffer, 0, client.buffer.length);
			joined.blit(client.buffer.length, chunk, 0, count);
			client.buffer = joined;
			client.lastActive = now;
		}
		while (client.stream.isOpen() && client.buffer.length >= 4) {
			var length:Int;
			try length = PragticalCodec.frameLength(client.buffer, 0) catch (_:Dynamic) {
				client.stream.close();
				return;
			}
			if (client.buffer.length < 4 + length)
				return;
			var body = client.buffer.sub(4, length);
			client.buffer = client.buffer.sub(4 + length, client.buffer.length - 4 - length);
			var message:Dynamic = null;
			try message = PragticalCodec.decode(body) catch (error:Dynamic) {
				client.stream.close();
				return;
			}
			request(pipe, client, message);
		}
	}

	/** One request, under Pragtical's server rules (`server.lua`). */
	function request(pipe:Pipe, client:Client, message:Dynamic):Void {
		var id:Dynamic = message == null ? null : Reflect.field(message, "id");
		var method:Dynamic = message == null ? null : Reflect.field(message, "method");
		if (message == null || !Reflect.isObject(message) || Reflect.field(message, "kind") != "request" || !Std.isOfType(id, String)
			|| !Std.isOfType(method, String)) {
			fail(client, id, new ControlError("invalid_request", "clients send requests only"), true);
			return;
		}
		if (Reflect.field(message, "version") != 1) {
			fail(client, id, new ControlError("unsupported_version", "this server speaks control protocol version 1"), true);
			return;
		}
		if (client.ids.exists(id)) {
			client.stream.close();
			return;
		}
		client.ids.set(id, true);
		var params:Dynamic = Reflect.field(message, "params");
		if (params == null || Std.isOfType(params, Array))
			params = {};
		if (method == "control.hello") {
			client.hello = true;
			send(client, {version: 1, kind: "response", id: id, result: {
				protocol_version: 1, instance_id: pipe.editor.window,
				capabilities: ["editor.open", "editor.documents", "editor.save", "project.add", "project.change", "window.focus"]
			}});
			return;
		}
		if (!client.hello) {
			fail(client, id, new ControlError("permission_denied", "control.hello must come first"), true);
			return;
		}
		switch method {
			case "control.ping":
				send(client, {version: 1, kind: "response", id: id, result: {ok: true}});
			case "instance.status":
				send(client, {version: 1, kind: "response", id: id, result: router.describe(pipe.editor)});
			case "tab.drag.begin" | "tab.drag.update" | "tab.drag.drop" | "tab.drag.cancel":
				fail(client, id, new ControlError("unsupported", "Exosuit does not take tabs from other editors"), false);
			default:
				client.pending.push({id: id, reply: router.forward(pipe.editor, method, params, client.stream.peerProcess())});
		}
	}

	function fail(client:Client, id:Dynamic, error:ControlError, closing:Bool):Void {
		send(client, {version: 1, kind: "response", id: id, error: error.json()});
		if (closing)
			client.stream.close();
	}

	function send(client:Client, envelope:Dynamic):Void
		try client.stream.send(PragticalCodec.frame(envelope)) catch (_:Dynamic) client.stream.close();

	public function dispose():Void {
		for (window in [for (window in pipes.keys()) window])
			close(window);
		hub.dispose();
	}
}
