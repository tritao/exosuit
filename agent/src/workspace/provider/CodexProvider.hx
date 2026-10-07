package workspace.provider;

import haxe.Json;
import language.JsonRpcResponse;
import process.ProcessManager;
import process.OwnedProcess;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgents;
import workspace.service.WorkspaceProtocol;
import workspace.runtime.WorkspaceDirectories;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;

private typedef Session = {
	var record:AgentRecord;
	var activity:String;
	var conversation:CodexConversation;
	var error:Null<String>;
	var attached:Bool;
	var busy:Bool;
	var requests:Map<String, PendingApproval>;
}

private typedef PendingApproval = {var wireId:Dynamic; var method:String; var detail:String; var reviewable:Bool; var questions:Array<String>;}

/** Shared-daemon adapter. All policy/protocol interpretation stays on the owning machine. */
class CodexProvider implements WorkspaceAgents {
	final workspace:String;
	final instance:String;
	final directories:WorkspaceDirectories;
	final groups:Void->Array<WorkspaceGroup>;
	final persistence:Null<WorkspaceAgentPersistence>;
	final processes:ProcessManager;
	final clock:Void->Float;
	final executable:String;
 final bridge:Null<String>;
	final sessions:Map<String, Session> = [];
	var transport:Null<CodexTransport>;
	var proxy:Null<OwnedProcess>;
	var starter:Null<OwnedProcess>;
	var phase = "stopped";
	var output = "";
	var deadline:Float = 0;
	var serial = 0;
	var storageFailed = false;

	public var status(default, null) = "Codex is not connected";

	public function new(workspace:String, instance:String, directories:WorkspaceDirectories, groups:Void->Array<WorkspaceGroup>, processes:ProcessManager,
			clock:Void->Float, ?persistence:WorkspaceAgentPersistence, executable:String = "codex", ?bridge:String) {
		this.workspace = workspace;
		this.instance = instance;
		this.directories = directories;
		this.groups = groups;
		this.processes = processes;
		this.clock = clock;
		this.persistence = persistence;
		this.executable = executable;this.bridge=bridge;
		if (persistence != null)
			for (r in persistence.loadAgents()) {
				if (!valid(r.id, 128)
					|| !valid(r.name, 256)
					|| r.workspaceRoot != directories.root
					|| (!valid(r.cwd, 1024)
						|| (r.cwd != directories.root
							&& !StringTools.startsWith(r.cwd, directories.root == "/" ? "/" : directories.root + "/")))
					|| sessions.exists(r.id))
					throw "Invalid persisted Codex resource";
				// The proxy subscription/active turn must be reconciled, never invented after restart.
				r.state = r.thread == "" ? "uncertain" : "disconnected";
				sessions.set(r.id, {
					record: r,
					activity: "",
					conversation: new CodexConversation(),
					error: null,
					attached: false,
					busy: false,
					requests: []
				});
			}
	}

	static function valid(s:String, n:Int):Bool
		return s != null && s.length > 0 && s.length <= n;

	function save(s:Session):Void {
		if (storageFailed)
			throw "Agent storage requires recovery";
		if (persistence != null)
			try
				persistence.saveAgent(s.record)
			catch (e:Dynamic) {
				storageFailed = true;
				throw e;
			}
	}

	function copy(r:AgentRecord):AgentRecord
		return {
			id: r.id,
			name: r.name,
			group: r.group,
			cwd: r.cwd,
			thread: r.thread,
			state: r.state,
			turn: r.turn,
			workspaceRoot: r.workspaceRoot
		};

	function view(s:Session):AgentView
		return {
			record: copy(s.record),
			activity: s.activity,
			items: s.conversation.items(),
			itemsOmitted: s.conversation.omitted,
			requests: [
				for (id => r in s.requests)
					{
						id: id,
						method: r.method,
						detail: r.detail,
						reviewable: r.reviewable
					}
			],
			error: s.error
		};

	function append(s:Session, text:String):Void {
		s.activity += text;
		if (s.activity.length > 16384)
			s.activity = s.activity.substring(s.activity.length - 16384);
	}

	function start():Void {
		if (phase != "stopped" && phase != "failed")
			return;
		disconnect("Reconnecting Codex");
		try {
			starter = processes.start(executable, ["--version"], directories.root);
			output = "";
			phase = "version";
			deadline = clock() + 15000;
			status = "Checking Codex version";
		} catch (e:Dynamic) {
			phase = "failed";
			status = Std.string(e);
		}
	}

	public function poll():Void {
		if (starter != null) {
			var process = starter;
			output += process.readStdout();
			process.readStderr();
			if (output.length > 4096 || clock() >= deadline) {
				processes.release(process);
				starter = null;
				phase = "failed";
				status = "Codex startup timed out";
				return;
			}
			if (process.exited()) {
				var exit = process.exitStatus();
				processes.release(process);
				starter = null;
				if (exit != 0) {
					phase = "failed";
					status = "Codex startup failed";
					return;
				}
				if (phase == "version") {
					if (StringTools.trim(output) != "codex-cli 0.160.0") {
						phase = "failed";
						status = "Unsupported Codex version; this adapter requires 0.160.0";
						return;
					}
					try {
						starter = processes.start(executable, ["app-server", "daemon", "start"], directories.root);
						phase = "daemon";
						output = "";
						deadline = clock() + 15000;
						status = "Starting shared Codex daemon";
					} catch (e:Dynamic) {
						phase = "failed";
						status = Std.string(e);
					}
				} else {
					try {
						if(bridge==null) throw "Codex WebSocket proxy bridge is not configured";
      proxy = processes.start("python3", [bridge,executable], directories.root);
						var connection = new CodexTransport(proxy);
						transport = connection;
						phase = "initializing";
						status = "Initializing Codex";
						connection.notification = notify;
						connection.serverRequest = approval;
						connection.request("initialize",
							{clientInfo: {name: "exosuit", title: "Exosuit", version: "1"}, capabilities: {experimentalApi: false}}, clock(), function(r) {
								if (transport != connection)
									return;
								if (r.error != null) {
									connection.close(r.error);
									return;
								}
								var agent = string(r.result, "userAgent");
								if (!~/(^|[^0-9])0[.]160[.](0|1)([^0-9]|$)/.match(agent)) {
									connection.close("Unsupported Codex server version");
									return;
								}
								if (!connection.send({method: "initialized"})) {
									connection.close("Codex initialization queue failed");
									return;
								}
								phase = "ready";
								status = "Codex connected";
						});
					} catch (e:Dynamic) {
						disconnect(Std.string(e));
					}
				}
			}
		}
		var current = transport;
		if (current != null) {
			current.poll(clock());
			if (current.failure != null)
				disconnect(current.failure);
		}
	}

	function disconnect(reason:String):Void {
		var current = transport;
		transport = null;
		if (current != null)
			current.close(reason);
		if (proxy != null) {
			processes.release(proxy);
			proxy = null;
		}
		phase = "failed";
		status = reason;
		for (s in sessions) {
			s.attached = false;
			s.busy = false;
			s.requests.clear();
			s.error = reason;
			if (s.record.thread != "")
				s.record.state = "disconnected";
		}
	}

	function call(method:String, params:Dynamic, done:JsonRpcResponse->Void):Void {
		var c = transport;
		if (c == null || phase != "ready") {
			done(new JsonRpcResponse(null, status));
			return;
		}
		c.request(method, params, clock(), done);
	}

	static function string(v:Dynamic, key:String):String {
		var x = v == null ? null : Reflect.field(v, key);
		if (Std.isOfType(x, String) && Std.string(x).length > 8192)
			throw "Codex field exceeds bound";
		return Std.isOfType(x, String) ? x : "";
	}

	function threadSession(thread:String):Null<Session> {
		for (s in sessions)
			if (s.record.thread == thread && thread != "")
				return s;
		return null;
	}

	function approval(id:Dynamic, method:String, params:Dynamic):Void {
		var s = threadSession(string(params, "threadId"));
  // The shared server may route requests for other clients. Never answer those.
  if(s==null) return;
		if (s.requests.keys().hasNext() && requestCount(s) >= 16) {
			if (transport != null)
				transport.close("Too many Codex approval requests");
			return;
		}
		var key = instance + "-" + (++serial);
		var raw = Json.stringify(params);
		var detail = raw.length > 2048 ? raw : requestDetail(method, params);
		var reviewable = raw.length <= 2048 && detail.length <= 2048;
		var questions:Array<String> = [];
		if (method == "item/tool/requestUserInput") {
			var data:Array<Dynamic> = Reflect.field(params, "questions");
			if (data != null && data.length <= 16)
				for (q in data)
					questions.push(string(q, "id"));
		}
		if (detail.length > 2048)
			detail = detail.substring(0, 2048) + "…";
		s.requests.set(key, {
			wireId: id,
			method: method,
			detail: detail,
			reviewable: reviewable,
			questions: questions
		});
		s.record.state = "needs-attention";
		append(s, "\n" + method + "\n" + detail + "\n");
	}

	/** Keep decision data visible without transport identity clutter. */
	static function requestDetail(method:String, params:Dynamic):String {
		var parts:Array<String> = [];
		var fields = Reflect.fields(params);
		fields.sort(Reflect.compare);
		for (field in fields) {
			if (field == "threadId" || field == "turnId" || field == "itemId") continue;
			var value = Reflect.field(params, field);
			if (field == "questions" && method == "item/tool/requestUserInput") {
				var questions:Array<Dynamic> = value;
				if (questions != null) for (question in questions) {
					parts.push(string(question, "id") + " — " + string(question, "header") + "\n" + string(question, "question"));
					var options:Array<Dynamic> = Reflect.field(question, "options");
					if (options != null) for (option in options)
						parts.push(string(option, "label") + ": " + string(option, "description"));
					// Unknown question attributes remain visible, including input/privacy flags.
					for (key in Reflect.fields(question))
						if (key != "id" && key != "header" && key != "question" && key != "options")
							parts.push(key + ": " + Json.stringify(Reflect.field(question, key)));
				}
			} else {
				var label = field == "cwd" ? "Working directory" : field == "command" ? "Command" : field == "reason" ? "Reason" : field;
				parts.push(label + ": " + (Std.isOfType(value, String) ? Std.string(value) : Json.stringify(value, null, "  ")));
			}
		}
		return parts.join("\n");
	}

	function requestCount(s:Session):Int {
		var n = 0;
		for (_ in s.requests)
			n++;
		return n;
	}

	function notify(method:String, params:Dynamic):Void {
		if (method == "serverRequest/resolved") {
			var id = Reflect.field(params, "requestId");
			for (s in sessions)
				for (key in [
					for (key => r in s.requests)
						if (Json.stringify(r.wireId) == Json.stringify(id)) key
				])
					s.requests.remove(key);
			return;
		}
		var s = threadSession(string(params, "threadId"));
		if (s == null) {
			var t = Reflect.field(params, "thread");
			s = threadSession(string(t, "id"));
		}
		if (s == null)
			return;
		if (method == "turn/started") {
			var t = Reflect.field(params, "turn");
			s.record.turn = string(t, "id");
			s.record.state = "working";
		} else if (method == "turn/completed") {
			var t = Reflect.field(params, "turn");
			if (s.record.turn != null && string(t, "id") != s.record.turn)
				return;
			s.record.turn = null;
			var state = string(t, "status");
			if (state != "completed" && state != "failed" && state != "interrupted")
				throw "Invalid completed Codex turn";
			s.conversation.finish(string(t, "id"), state);
			s.record.state = state;
			s.requests.clear();
			s.busy = false;
			save(s);
		} else if (method == "thread/status/changed") {
			var state = Reflect.field(params, "status");
			var type = string(state, "type");
			if (type == "active")
				s.record.state = s.requests.keys().hasNext() ? "needs-attention" : "working";
			else if (type == "idle" && s.record.turn == null)
				s.record.state = "idle";
		} else if (method == "item/agentMessage/delta" || method == "item/commandExecution/outputDelta") {
			s.conversation.delta(string(params, "turnId"), string(params, "itemId"), method == "item/agentMessage/delta" ? "agentMessage" : "commandExecution", string(params, "delta"));
			append(s, string(params, "delta"));
		} else if (method == "item/completed" || method == "item/started" || method == "error") {
			if (method != "error") s.conversation.put(string(params, "turnId"), Reflect.field(params, "item"), method == "item/completed");
			var text = Json.stringify(params);
			append(s, "\n" + method + "\n" + (text.length > 4096 ? text.substring(0, 4096) + "…" : text) + "\n");
		}
	}

	function directory(group:String):Null<String> {
		var map:Map<String, WorkspaceGroup> = [];
		for (g in groups())
			map.set(g.id, g);
		var current = map.get(group);
		if (current == null)
			return null;
		var seen:Map<String, Bool> = [];
		while (current != null) {
			if (seen.exists(current.id))
				return null;
			seen.set(current.id, true);
			if (current.cwd != null)
				return directories.resolve(current.cwd);
			current = current.parent == null ? null : map.get(current.parent);
		}
		return directories.root;
	}

	function loadThread(s:Session, done:JsonRpcResponse->Void):Void {
		// Read metadata first: no thread from another project is resumed or policy-mutated.
		call("thread/read", {threadId: s.record.thread, includeTurns: false}, function(r) {
			if (r.error != null) {
				done(r);
				return;
			}
			var t = Reflect.field(r.result, "thread"), cwd = string(t, "cwd");
			if (directories.resolve(cwd) != s.record.cwd) {
				done(new JsonRpcResponse(null, "Thread directory does not match this resource"));
				return;
			}
			call("thread/resume", {threadId: s.record.thread, excludeTurns: true}, function(resumed) {
				if (resumed.error == null) {
					s.attached = true;
					s.error = null;
					// Active turns are discovered from status; no prompt is replayed.
					var thread = Reflect.field(resumed.result, "thread"),
						state = Reflect.field(thread, "status");
					s.record.state = string(state, "type") == "active" ? "working" : "idle";
					s.record.turn = null;
					append(s, "\nReattached to Codex thread " + s.record.thread + "\n");
					call("thread/turns/list", {
						threadId: s.record.thread,
						limit: 1,
						sortDirection: "desc",
						itemsView: "summary"
					}, function(turns) {
						if (turns.error != null) {
							done(turns);
							return;
						}
						var data:Array<Dynamic> = Reflect.field(turns.result, "data");
						if (data != null && data.length > 0 && string(data[0], "status") == "inProgress") {
							s.record.turn = string(data[0], "id");
							s.record.state = "working";
						}
						save(s);
						var historyBaseline = s.conversation.historyBaseline();
						call("thread/items/list", {threadId: s.record.thread, limit: 8, sortDirection: "desc"}, function(items) {
							if (items.error != null) {
								done(items);
								return;
							}
							var recent:Array<Dynamic> = Reflect.field(items.result, "data");
							s.conversation.history(recent == null ? [] : recent, s.record.turn, historyBaseline);
							if (Reflect.field(items.result, "nextCursor") != null) s.conversation.noteOmitted();
							var text = Json.stringify(Reflect.field(items.result, "data"));
							append(s, "\nRecent history (latest 8 items):\n" + (text.length > 8192 ? text.substring(0, 8192) + "…" : text) + "\n");
							done(resumed);
						});
					});
					return;
				}
				done(resumed);
			});
		});
	}

	public function bind(connection:RpcConnection, capabilities:Array<String>):Void {
		function allowed(workspaceId:String, owner:String, control:Bool):Bool
			return !storageFailed
				&& workspaceId == workspace
				&& owner == instance
				&& capabilities.indexOf(WorkspaceAgentProtocol.READ) >= 0
				&& (!control || capabilities.indexOf(WorkspaceAgentProtocol.CONTROL) >= 0);
		connection.register(WorkspaceAgentProtocol.LIST, function(q, ctx) {
			if (!allowed(q.workspace, q.instance, false)) {
				ctx.fail({code: "unauthorized", message: "Agent catalog denied", ambiguous: false});
				return;
			}
			var records = [for (s in sessions) copy(s.record)];
			records.sort(function(a, b) return Reflect.compare(a.id, b.id));
			records = [for (r in records) if (q.after == null || Reflect.compare(r.id, q.after) > 0) r];
			var more = records.length > 6;
			if (more)
				records.resize(6);
			ctx.respond({
				instance: instance,
				root: directories.root,
				records: records,
				status: status,
				next: more ? records[records.length - 1].id : null
			});
		});
		connection.register(WorkspaceAgentProtocol.DISCOVER, function(q, ctx) {
			if (!allowed(q.workspace, q.instance, false)) {
				ctx.fail({code: "unauthorized", message: "Thread discovery denied", ambiguous: false});
				return;
			}
			var cwd = directory(q.group);
			if (cwd == null || (q.cursor != null && q.cursor.length > 2048)) {
				ctx.fail({code: "invalid_request", message: "Invalid thread discovery directory or cursor", ambiguous: false});
				return;
			}
			if (phase != "ready") {
				start();
				ctx.fail({code: "provider_starting", message: status, ambiguous: false});
				return;
			}
			call("thread/list", {
				cwd: cwd,
				limit: 6,
				cursor: q.cursor,
				archived: false
			}, function(r) {
				if (r.error != null) {
					ctx.fail({code: "provider_error", message: r.error, ambiguous: false});
					return;
				}
				var data:Array<Dynamic> = Reflect.field(r.result, "data");
				if (data == null || data.length > 6) {
					ctx.fail({code: "provider_error", message: "Invalid Codex discovery page", ambiguous: false});
					return;
				}
				var threads:Array<AgentThread> = [];
				for (t in data) {
					var id = string(t, "id"),
						path = directories.resolve(string(t, "cwd"));
					if (!valid(id, 128) || path != cwd)
						continue;
					var title = string(t, "name");
					if (title == "")
						title = string(t, "preview");
					threads.push({id: id, cwd: cwd, title: title.length > 256 ? title.substring(0, 256) : title});
				}
				var next:Null<String> = Reflect.field(r.result, "nextCursor");
				if (next != null && next.length > 2048) {
					ctx.fail({code: "provider_error", message: "Invalid Codex discovery cursor", ambiguous: false});
					return;
				}
				ctx.respond({threads: threads, next: next});
			});
		});
		connection.register(WorkspaceAgentProtocol.CREATE, function(q, ctx) {
			if (!allowed(q.workspace, q.instance, true)) {
				ctx.fail({code: "unauthorized", message: "Agent creation denied", ambiguous: false});
				return;
			}
			if (!valid(q.id, 128) || !valid(q.name, 256) || (q.thread != null && !valid(q.thread, 128))) {
				ctx.fail({code: "invalid_request", message: "Invalid agent identity", ambiguous: false});
				return;
			}
			var cwd = directory(q.group);
			if (cwd == null) {
				ctx.fail({code: "invalid_request", message: "Invalid agent directory or group", ambiguous: false});
				return;
			}
			var previous = sessions.get(q.id);
			if (previous != null) {
				if (previous.record.group != q.group
					|| previous.record.name != q.name
					|| (q.thread != null && previous.record.thread != q.thread)) {
					ctx.fail({code: "conflict", message: "Agent id already belongs to another resource", ambiguous: false});
					return;
				}
				ctx.respond(copy(previous.record));
				return;
			}
			if (sessionsCount() >= 32) {
				ctx.fail({code: "limit", message: "Agent catalog is full", ambiguous: false});
				return;
			}
			if (q.thread != null && threadSession(q.thread) != null) {
				ctx.fail({code: "conflict", message: "Thread already attached", ambiguous: false});
				return;
			}
			if (phase != "ready") {
				if (phase == "failed") {
					ctx.fail({code: "provider_unavailable", message: status, ambiguous: false});
					return;
				}
				start();
				ctx.fail({code: "provider_starting", message: status + "; retry when connected", ambiguous: false});
				return;
			}
			var s:Session = {
				record: {
					id: q.id,
					name: q.name,
					group: q.group,
					cwd: cwd,
					thread: q.thread == null ? "" : q.thread,
					state: "creating",
					turn: null,
					workspaceRoot: directories.root
				},
				activity: "",
				conversation: new CodexConversation(),
				error: null,
				attached: false,
				busy: true,
				requests: []
			};
			// Reserve before the side effect. Ambiguous create is retained, never retried as new.
			try
				save(s)
			catch (e:Dynamic) {
				ctx.fail({code: "storage_unavailable", message: "Agent reservation failed", ambiguous: false});
				return;
			}
			sessions.set(q.id, s);
			function complete(r:JsonRpcResponse):Void {
				s.busy = false;
				if (r.error != null) {
					s.error = r.error;
					s.record.state = s.record.thread == "" ? "uncertain" : "disconnected";
					try
						save(s)
					catch (_:Dynamic) {}
					ctx.fail({code: "provider_error", message: r.error, ambiguous: true});
					return;
				}
				var thread = Reflect.field(r.result, "thread"),
					id = string(thread, "id");
				if (!valid(id, 128)) {
					s.error = "Invalid Codex thread response";
					s.record.state = "uncertain";
					ctx.fail({code: "provider_error", message: s.error, ambiguous: true});
					return;
				}
				s.record.thread = id;
				s.attached = true;
				if (q.thread == null)
					s.record.state = "idle";
				try
					save(s)
				catch (e:Dynamic) {
					ctx.fail({code: "storage_unavailable", message: "Codex thread created but resource storage failed", ambiguous: true});
					return;
				}
				ctx.respond(copy(s.record));
			}
			if (q.thread == null)
				call("thread/start", {cwd: cwd, sandbox: "workspace-write", approvalPolicy: "on-request"}, complete);
			else
				loadThread(s, complete);
		});
		connection.register(WorkspaceAgentProtocol.ACTION, function(q, ctx) {
			var control = q.action != "read";
			if (!allowed(q.workspace, q.instance, control)) {
				ctx.fail({code: "unauthorized", message: "Agent operation denied", ambiguous: false});
				return;
			}
			var s = sessions.get(q.id);
			if (s == null) {
				ctx.fail({code: "unknown_agent", message: "Unknown agent", ambiguous: false});
				return;
			}
			if (q.action == "read") {
				ctx.respond(view(s));
				return;
			}
			if (q.action == "connect") {
				if (s.record.thread == "") {
					ctx.fail({code: "uncertain_create", message: "Creation outcome is uncertain; discover and attach the thread explicitly", ambiguous: false});
					return;
				}
				if (phase != "ready") {
					start();
					ctx.fail({code: "provider_starting", message: status, ambiguous: false});
					return;
				}
				if (s.busy) {
					ctx.fail({code: "busy", message: "Agent request in progress", ambiguous: false});
					return;
				}
				s.busy = true;
				loadThread(s, function(r) {
					s.busy = false;
					if (r.error != null)
						s.error = r.error;
					ctx.respond(view(s));
				});
				return;
			}
			if (!s.attached || phase != "ready") {
				ctx.fail({code: "disconnected", message: "Reconnect this agent before sending requests", ambiguous: false});
				return;
			}
			if (q.action == "prompt") {
				if (!valid(q.text, 8192)
					|| s.busy
					|| (s.record.state != "idle" && s.record.state != "completed" && s.record.state != "failed" && s.record.state != "interrupted")) {
					ctx.fail({code: "busy", message: "Agent is busy or prompt is invalid", ambiguous: false});
					return;
				}
				s.busy = true;
				s.record.state = "working";
				s.error = null;
				append(s, "\nYou: " + q.text + "\n");
				call("turn/start", {threadId: s.record.thread, input: [{type: "text", text: q.text, text_elements: new Array<String>()}]}, function(r) {
					s.busy = false;
					if (r.error != null) {
						s.error = r.error;
						s.record.state = "uncertain";
						ctx.fail({code: "provider_error", message: r.error, ambiguous: true});
						return;
					}
					var t = Reflect.field(r.result, "turn");
					s.record.turn = string(t, "id");
					save(s);
					ctx.respond(view(s));
				});
				return;
			}
			if (q.action == "stop") {
				if (s.record.turn == null) {
					ctx.fail({code: "unknown_turn", message: "Reconcile the active turn before interrupting", ambiguous: false});
					return;
				}
				call("turn/interrupt", {threadId: s.record.thread, turnId: s.record.turn}, function(r) {
					if (r.error != null)
						s.error = r.error;
					ctx.respond(view(s));
				});
				return;
			}
			var pending = q.request == null ? null : s.requests.get(q.request);
			if (pending == null) {
				ctx.fail({code: "resolved", message: "This request has already resolved or disconnected", ambiguous: false});
				return;
			}
			if (q.text.length > 8192) {
				ctx.fail({code: "invalid_request", message: "Answer exceeds limit", ambiguous: false});
				return;
			}
			if (q.action == "approve" && !pending.reviewable) {
				ctx.fail({
					code: "unsupported_request",
					message: "Full request exceeds this view; review it in another compatible Codex client",
					ambiguous: false
				});
				return;
			}
			var result:Dynamic = null;
			if (pending.method == "item/commandExecution/requestApproval" || pending.method == "item/fileChange/requestApproval") {
				if (q.action != "approve" && q.action != "decline") {
					ctx.fail({code: "invalid_request", message: "Choose approve or decline", ambiguous: false});
					return;
				}
				result = {decision: q.action == "approve" ? "accept" : "decline"};
			} else if (pending.method == "item/tool/requestUserInput" && q.action == "answer") {
				// Each question uses its own id. The UI supplies one id=value per line.
				var answers:Dynamic = {};
				for (line in q.text.split("\n")) {
					var at = line.indexOf("=");
					if (at <= 0) {
						ctx.fail({code: "invalid_request", message: "Answer each question as id=value", ambiguous: false});
						return;
					}
					var id = line.substring(0, at);
					if (pending.questions.indexOf(id) < 0 || Reflect.hasField(answers, id)) {
						ctx.fail({code: "invalid_request", message: "Unknown or duplicate question", ambiguous: false});
						return;
					}
					Reflect.setField(answers, id, {answers: [line.substring(at + 1)]});
				}
				if (Reflect.fields(answers).length != pending.questions.length) {
					ctx.fail({code: "invalid_request", message: "Answer every question", ambiguous: false});
					return;
				}
				result = {answers: answers};
			} else {
				ctx.fail({code: "unsupported_request", message: "This Codex request requires another compatible client", ambiguous: false});
				return;
			}
			if (transport == null || !transport.send({id: pending.wireId, result: result})) {
				ctx.fail({code: "backpressure", message: "Codex reply was not queued", ambiguous: false});
				return;
			}
			s.requests.remove(q.request);
			ctx.respond(view(s));
		});
	}

	function sessionsCount():Int {
		var n = 0;
		for (_ in sessions)
			n++;
		return n;
	}

	public function activeCount():Int {
		var n = 0;
		for (s in sessions)
			if (s.record.state == "working" || s.record.state == "needs-attention" || s.busy)
				n++;
		return n;
	}

	/** Updates also preserve idle attached conversations and pending provider startup. */
	public function updateActivityCount():Int {
		var count = starter == null ? 0 : 1;
		for (session in sessions)
			if (session.attached || session.busy || session.record.state == "creating"
				|| session.record.state == "working" || session.record.state == "needs-attention") count++;
		return count;
	}

	public function dispose():Void {
		if (starter != null) {
			processes.release(starter);
			starter = null;
		}
		disconnect("Workspace provider connection closed");
	}
}
