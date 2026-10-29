package workspace.client;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import haxeon.rpc.RpcConnectResult;
import suit.MachineCatalog;
import suit.MachineCatalog.MachineState;
import suit.MachineCatalog.MachineWorkspace;
import suit.SuitClient;
import suit.SuitPaths;
import workspace.PathKey;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

private typedef MachineRequest = {
	var message:Dynamic;
	var answer:Null<(Null<Dynamic>, Null<String>) -> Void>;
}

/**
	This machine and its workspaces, from suit's daemon (docs/architecture/0005-machines-and-workspaces.md). Requests
	go one at a time over suit's control endpoint, each on its own connection, without blocking the caller: `poll`
	moves them along. Starts suit when it does not answer, unless suit is off.
**/
class MachineClient {
	static inline final TIMEOUT = 5000.0;
	static inline final RETRY = 1000.0;

	final hub:NativeRpcHub;
	final clock:Void->Float;
	final queue:Array<MachineRequest> = [];
	var current:Null<MachineRequest>;
	var transport:Null<NativeRpcTransport>;
	var failure:Null<String>;
	var sent = false;
	var deadline:Float = 0;
	var started = false;
	var retryAt:Float = 0;

	public var machine(default, null):Null<MachineState>;
	/** Why the last request failed; null after one succeeds. */
	public var error(default, null):Null<String>;
	/** Changes whenever `machine` or `error` does. */
	public var revision(default, null):Int = 0;
	/** False when suit is off: the editor then has no machine and works on open folders only. */
	public final enabled:Bool;

	public function new(events:NativeKitEvents, clock:Void->Float) {
		hub = new NativeRpcHub(events);
		this.clock = clock;
		enabled = SuitClient.current() != Off;
	}

	public function refresh():Void
		request({op: "machine"});

	/** Creates a workspace with one folder; `done` gets it, or the error. */
	public function create(name:Null<String>, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-create", name: name, folder: folder}, workspaceReply(done));

	public function rename(id:String, name:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-rename", workspace: id, name: name}, workspaceReply(done));

	public function delete(id:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-delete", workspace: id}, workspaceReply(done));

	public function addFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-add-folder", workspace: id, folder: folder}, workspaceReply(done));

	public function removeFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-remove-folder", workspace: id, folder: folder}, workspaceReply(done));

	/** The workspace whose only folder is `folder`, if the machine has one. */
	public function workspaceFor(folder:String):Null<MachineWorkspace> {
		var state = machine;
		if (state == null)
			return null;
		for (workspace in state.workspaces)
			if (workspace.folders.length == 1 && PathKey.same(workspace.folders[0], folder))
				return workspace;
		return null;
	}

	public function busy():Bool
		return current != null || queue.length > 0;

	function workspaceReply(done:Null<(Null<MachineWorkspace>, Null<String>) -> Void>):(Null<Dynamic>, Null<String>) -> Void
		return function(reply, failure) {
			if (done != null)
				done(reply == null ? null : reply.workspace, failure);
		};

	function request(message:Dynamic, ?done:(Null<Dynamic>, Null<String>) -> Void):Void {
		if (!enabled) {
			if (done != null)
				done(null, "suit is off (EXOSUIT_SUIT=off), so this machine has no workspaces");
			return;
		}
		queue.push({message: message, answer: done});
	}

	/** Moves requests along; call every frame. */
	public function poll():Void {
		var now = clock();
		if (current == null) {
			if (queue.length == 0 || now < retryAt)
				return;
			begin(queue[0], now);
		}
		var request = current;
		if (request == null)
			return;
		if (failure == null && now >= deadline)
			failure = "suit did not answer";
		var stream = transport;
		if (failure == null && stream != null) {
			if (!stream.isOpen())
				failure = "suit closed the connection";
			else {
				if (!sent)
					sent = stream.send(Bytes.ofString(Json.stringify(request.message)));
				var received:Null<Bytes> = null;
				try received = stream.receive() catch (error:Dynamic) failure = Std.string(error);
				if (received != null) {
					var reply:Dynamic = null;
					try reply = Json.parse(received.toString()) catch (_:Dynamic) {}
					finish(reply);
					return;
				}
			}
		}
		if (failure != null) {
			// suit starts on demand: the editor asks once, then retries connecting until the deadline.
			if (!started) {
				started = true;
				SuitClient.ensureDaemon();
				deadline = now + TIMEOUT;
			}
			if (transport == null && now + RETRY < deadline) {
				current = null;
				retryAt = now + RETRY;
				return;
			}
			finish(null);
		}
	}

	function begin(request:MachineRequest, now:Float):Void {
		current = request;
		failure = null;
		sent = false;
		transport = null;
		if (deadline <= now)
			deadline = now + TIMEOUT;
		try {
			hub.connect(NativeRpcHub.local(SuitPaths.endpoint()), function(result:RpcConnectResult) {
				switch result {
					case Opened(opened):
						if (current == request && transport == null)
							transport = cast opened;
						else
							opened.close();
					default:
						if (current == request && failure == null)
							failure = "suit is not running";
				}
			});
		} catch (error:Dynamic) {
			failure = Std.string(error);
		}
	}

	function finish(reply:Null<Dynamic>):Void {
		var request = current;
		var problem:Null<String> = null;
		if (reply == null)
			problem = failure != null ? failure : "suit did not answer";
		else if (reply.ok != true)
			problem = Reflect.field(reply, "error") == null ? "suit refused the request" : Std.string(reply.error);
		close();
		if (request != null)
			queue.remove(request);
		current = null;
		deadline = 0;
		if (reply != null && reply.ok == true && Reflect.hasField(reply, "machine")) {
			try machine = MachineCatalog.decode(Json.stringify({version: MachineCatalog.VERSION, id: reply.machine.id,
				name: reply.machine.name, workspaces: reply.machine.workspaces})) catch (error:Dynamic) problem = Std.string(error);
		}
		if (request != null && request.message.op == "machine" || problem == null)
			error = problem;
		revision++;
		if (request != null) {
			var callback:Null<(Null<Dynamic>, Null<String>) -> Void> = request.answer;
			if (callback != null)
				callback(problem == null ? reply : null, problem);
		}
	}

	function close():Void {
		var stream = transport;
		transport = null;
		if (stream != null)
			stream.close();
	}

	public function dispose():Void {
		close();
		queue.resize(0);
		current = null;
		hub.dispose();
	}
}
