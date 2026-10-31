package workspace.client;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.rpc.RpcConnectResult;
import suit.MachineCatalog;
import suit.MachineCatalog.MachineService;
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
	/** The last `machine` reply as JSON, to tell a reply that changes nothing. */
	var lastSignature:Null<String>;

	public var machine(default, null):Null<MachineState>;
	/** Why the last request failed; null after one succeeds. */
	public var error(default, null):Null<String>;
	/** Changes whenever `machine` or `error` does. */
	public var revision(default, null):Int = 0;
	/** False when suit is off: the editor then has no machine and works on open folders only. */
	public final enabled:Bool;
	/** Scratch folders suit made on request, until a listing reports them. */
	final scratches:Map<String, String> = [];
	/** The service of each workspace suit reported one for (M19 Phase 6). */
	final services:Map<String, MachineService> = [];

	public function new(events:EventPump, clock:Void->Float) {
		hub = new NativeRpcHub(events);
		this.clock = clock;
		enabled = SuitClient.current() != Off;
	}

	public function refresh():Void
		request({op: "machine"});

	/** Creates a workspace with these folders, which may be none if it has a name; `done` gets it, or the error. */
	public function create(name:Null<String>, folders:Array<String>, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-create", name: name, folders: folders.copy()}, workspaceReply(done, false));

	/** The workspace's scratch folder, which suit creates on first request; `done` gets its path, or the error. */
	public function scratch(id:String, done:(Null<String>, Null<String>) -> Void):Void
		request({op: "workspace-scratch", workspace: id}, function(reply, failure) {
			var path:Null<String> = null;
			if (reply != null) {
				var value:Dynamic = Reflect.field(reply, "scratch");
				if (Std.isOfType(value, String) && (value : String).length > 0)
					path = value;
				else if (failure == null)
					failure = "suit sent no scratch folder";
			}
			if (path != null) scratches.set(id, path);
			done(path, failure);
		});

	public function rename(id:String, name:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-rename", workspace: id, name: name}, workspaceReply(done, false));

	public function delete(id:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-delete", workspace: id}, workspaceReply(done, true));

	public function addFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-add-folder", workspace: id, folder: folder}, workspaceReply(done, false));

	public function removeFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		request({op: "workspace-remove-folder", workspace: id, folder: folder}, workspaceReply(done, false));

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

	/** The workspace with this id, if the machine has one. */
	public function workspaceById(id:String):Null<MachineWorkspace> {
		var state = machine;
		if (state == null)
			return null;
		for (workspace in state.workspaces)
			if (workspace.id == id)
				return workspace;
		return null;
	}

	/** The workspace that has `folder` among its folders, or as its scratch folder. */
	public function workspaceHolding(folder:String):Null<MachineWorkspace> {
		var state = machine;
		if (state == null)
			return null;
		for (workspace in state.workspaces) {
			var scratch = scratchOf(workspace);
			if (scratch != null && PathKey.same(scratch, folder))
				return workspace;
			for (attached in workspace.folders)
				if (PathKey.same(attached, folder))
					return workspace;
		}
		return null;
	}

	/** The workspace's scratch folder if suit already made one, as a listing or a scratch request reported it. */
	public function scratchOf(workspace:MachineWorkspace):Null<String>
		return workspace.scratch != null ? workspace.scratch : scratches.get(workspace.id);

	/**
		The service a workspace's folder belongs to when workspaces have services of their own: null until the machine's
		workspaces are known (check `machine`), and for a folder no workspace holds.
	**/
	public function serviceTargetFor(folder:String):Null<WorkspaceServiceTarget> {
		var workspace = workspaceHolding(folder);
		return workspace == null ? null : serviceTarget(workspace);
	}

	public function serviceTarget(workspace:MachineWorkspace):WorkspaceServiceTarget
		return WorkspaceServiceTarget.forWorkspace(workspace.id, workspace.folders, scratchOf(workspace));

	public function busy():Bool
		return current != null || queue.length > 0;

	/** `removed`: the request deletes the workspace, otherwise the reply's workspace replaces what is known of it. */
	function workspaceReply(done:Null<(Null<MachineWorkspace>, Null<String>) -> Void>, removed:Bool):(Null<Dynamic>, Null<String>) -> Void
		return function(reply, failure) {
			var workspace:Null<MachineWorkspace> = null;
			var entry:Dynamic = reply == null ? null : Reflect.field(reply, "workspace");
			if (entry != null)
				try workspace = MachineCatalog.decodeWorkspace(entry) catch (error:Dynamic) failure = "suit sent an invalid workspace: " + Std.string(error);
			if (workspace != null && failure == null)
				know(workspace, removed);
			if (done != null)
				done(workspace, failure);
		};

	/** Keeps the listing current between refreshes: the service a workspace's folders belong to follows its folders. */
	function know(workspace:MachineWorkspace, removed:Bool):Void {
		var state = machine;
		if (state == null)
			return;
		var found = -1;
		for (index in 0...state.workspaces.length)
			if (state.workspaces[index].id == workspace.id)
				found = index;
		if (removed) {
			if (found >= 0)
				state.workspaces.splice(found, 1);
		} else if (found >= 0)
			state.workspaces[found] = workspace;
		else
			state.workspaces.push(workspace);
		revision++;
	}

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
		var signature:Null<String> = null;
		var before = error;
		if (reply != null && reply.ok == true && Reflect.hasField(reply, "machine")) {
			try machine = MachineCatalog.decode(Json.stringify({version: MachineCatalog.VERSION, id: reply.machine.id,
				name: reply.machine.name, workspaces: reply.machine.workspaces})) catch (error:Dynamic) problem = Std.string(error);
			if (problem == null) {
				readServices(reply.machine.workspaces);
				signature = Json.stringify(reply.machine);
			}
		}
		if (request != null && request.message.op == "machine" || problem == null)
			error = problem;
		// A reply that says what the last one did, with the same error, changes nothing: no revision, so nothing re-syncs.
		var unchanged = signature != null && signature == lastSignature && error == before;
		lastSignature = signature;
		if (!unchanged)
			revision++;
		if (request != null) {
			var callback:Null<(Null<Dynamic>, Null<String>) -> Void> = request.answer;
			// A failing callback must not take the editor's frame loop down with it.
			if (callback != null)
				try callback(problem == null ? reply : null, problem) catch (thrown:Dynamic) {
					error = Std.string(thrown);
					revision++;
				}
		}
	}

	/** The services suit reports in a `machine` reply; one that is malformed counts as none. */
	function readServices(entries:Dynamic):Void {
		services.clear();
		if (!Std.isOfType(entries, Array))
			return;
		for (entry in (entries : Array<Dynamic>)) {
			var id:Dynamic = Reflect.field(entry, "id");
			if (!Std.isOfType(id, String))
				continue;
			var service:Null<MachineService> = null;
			try service = MachineCatalog.decodeService(entry) catch (_:Dynamic) {}
			// The window connects to what suit reports, so only an endpoint of the agent's own shape counts.
			if (service != null && !WorkspaceConnections.validEndpoint(service.endpoint, Sys.systemName() == "Windows"))
				service = null;
			if (service != null)
				services.set(id, service);
		}
	}

	/** The service suit last reported for workspace `id`: null when it reported none. */
	public function serviceOf(id:String):Null<MachineService>
		return services.get(id);

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
