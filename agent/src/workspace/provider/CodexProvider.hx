package workspace.provider;

import haxe.Json;
import language.JsonRpcResponse;
import process.ProcessManager;
import process.OwnedProcess;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceProtocol;
import workspace.runtime.WorkspaceDirectories;
import workspace.client.CodexPermissions;
import workspace.client.CodexPermissions.CodexPermissionProfile;
import haxeon.rpc.RpcContext;

private typedef Session = {
	var record:AgentRecord;
	var activity:String;
	var conversation:CodexConversation;
	var historyPages:CodexHistoryPages;
	var error:Null<String>;
	var attached:Bool;
	var busy:Bool;
	var requests:Map<String, PendingApproval>;
	var currentModel:Null<String>;
	var currentEffort:Null<String>;
	var reconnectAttempts:Int;
	var reconnectAt:Float;
	var reconnectBlocked:Bool;
	var eventRevision:Int;
}

private typedef PendingApproval = {var wireId:Dynamic; var method:String; var detail:String; var reviewable:Bool; var questions:Array<String>; var structured:Null<Array<AgentQuestion>>;}

/** Shared-daemon adapter. All policy/protocol interpretation stays on the owning machine. */
class CodexProvider implements AgentMessageSource {
	public var imageUploadAvailable:Bool = false;
	public static function turnInput(text:String, imagePaths:Array<String>):Array<Dynamic> {
		var input:Array<Dynamic> = [];
		if (text != "") input.push({type:"text", text:text, text_elements:new Array<String>()});
		for (path in imagePaths) input.push({type:"localImage", path:path});
		return input;
	}
	final instance:String;
	final directories:WorkspaceDirectories;
	final groups:Void->Array<WorkspaceGroup>;
	final persistence:Null<WorkspaceAgentPersistence>;
	final processes:ProcessManager;
	final clock:Void->Float;
	final executable:String;
	final commandPrefix:Array<String>;
	final bridge:Null<String>;
	final sessions:Map<String, Session> = [];
	final nameSync:Map<String,AgentNameSync> = [];
	var nativeNamingUnsupported=false;
	public function nativeNamingSupported():Bool return !nativeNamingUnsupported;
	function nameError(message:String):haxeon.rpc.RpcError {
		var lower=message.toLowerCase();
		var unsupported=lower.indexOf("method not found")>=0 || lower.indexOf("unknown method")>=0 || lower.indexOf("unsupported method")>=0;
		if(unsupported) nativeNamingUnsupported=true;
		return {code:unsupported ? "unsupported_operation" : phase!="ready" ? "provider_starting" : "provider_error",message:unsupported ? "This Codex version does not support native session naming. Update Codex or use Rename in Workbench." : message,ambiguous:lower.indexOf("timeout")>=0};
	}
	function names(s:Session):AgentNameSync {
		var existing=nameSync.get(s.record.id);if(existing!=null) return existing;
		var sync=new AgentNameSync(s.record,function() save(s),function(done) {
			if(s.record.thread=="") {done(null,{code:"unknown_session",message:"The native Codex thread has not been created",ambiguous:false});return;}
			call("thread/read",{threadId:s.record.thread,includeTurns:false},function(result) {
				if(result.error!=null) {done(null,nameError(result.error));return;}
				var thread=Reflect.field(result.result,"thread");
				if(string(thread,"id")!=s.record.thread || string(thread,"cwd")!=s.record.cwd) {
					done(null,{code:"invalid_scope",message:"Codex thread does not belong to this workspace resource",ambiguous:false});return;
				}
				var name:Dynamic=Reflect.field(thread,"name");
				if(name!=null && (!Std.isOfType(name,String) || Std.string(name).length>2048)) {
					done(null,{code:"invalid_response",message:"Invalid native Codex name",ambiguous:false});return;
				}
				done(name,null);
			});
		},function(name,expected,done) {
			call("thread/name/set",{threadId:s.record.thread,name:name},function(result) done(result.error==null ? null : nameError(result.error)));
		},clock);
		nameSync.set(s.record.id,sync);return sync;
	}
	var models:Null<Array<AgentModel>>;
	var modelsNext:Null<String>;
	var transport:Null<CodexTransport>;
	var proxy:Null<OwnedProcess>;
	var starter:Null<OwnedProcess>;
	var phase = "stopped";
	var output = "";
	var deadline:Float = 0;
	var serial = 0;
	var storageFailed = false;
	var connectionGeneration = 0;
	var retryAt:Float = 0;
	var retryDelay:Float = 1;
	var connectedAt:Float = 0;
	var startupBlocked = false;
	var recoveringSession:Null<Session>;
	var cliVersion = "unknown";
	var serverVersion = "unknown";

	public var status(default, null) = "Codex is not connected";

	public function new(instance:String, directories:WorkspaceDirectories, groups:Void->Array<WorkspaceGroup>, processes:ProcessManager,
			clock:Void->Float, ?persistence:WorkspaceAgentPersistence, executable:String = "codex", ?bridge:String, ?script:String) {
		this.instance = instance;
		this.directories = directories;
		this.groups = groups;
		this.processes = processes;
		this.clock = clock;
		this.persistence = persistence;
		this.executable = executable;
		this.commandPrefix = script == null || script.length == 0 ? [] : [script];
		this.bridge = bridge;
		if (persistence != null)
			for (r in persistence.loadAgents()) {
				if (r.provider != null && r.provider != "codex") continue;
				if (!valid(r.id, 128)
					|| !valid(r.name, 256)
					|| r.workspaceRoot != directories.root
					|| (!valid(r.cwd, 1024)
						|| !directories.inside(r.cwd))
					|| sessions.exists(r.id))
					throw "Invalid persisted Codex resource";
				// The proxy subscription/active turn must be reconciled, never invented after restart.
				r.state = r.thread == "" ? "uncertain" : "disconnected";
				sessions.set(r.id, {
					record: r,
					activity: "",
					conversation: new CodexConversation(),
					historyPages: new CodexHistoryPages(),
					error: null,
					attached: false,
					busy: false,
					requests: [],
					currentModel: null,
					currentEffort: null,
					reconnectAttempts: 0,
					reconnectAt: 0,
					reconnectBlocked: false,
					eventRevision: 0
				});
			}
	}

	static function valid(s:String, n:Int):Bool
		return s != null && s.length > 0 && s.length <= n;

	function catalogModel(id:Null<String>):Null<AgentModel> {
		if (id != null && models != null) for (entry in models) if (entry.model == id) return entry;
		return null;
	}

	function effortSupported(effort:Null<String>, model:Null<String>):Bool {
		if (effort == null) return true;
		if (!valid(effort, 64)) return false;
		var entry = catalogModel(model);
		return entry == null || entry.supportedEfforts == null || entry.supportedEfforts.contains(effort);
	}

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
			provider: "codex",
			name: r.name,
			group: r.group,
			cwd: r.cwd,
			thread: r.thread,
			state: r.state,
			turn: r.turn,
			workspaceRoot: r.workspaceRoot,
			sandboxPolicy: r.sandboxPolicy,
			approvalPolicy: r.approvalPolicy,
			permissionProfile: r.permissionProfile,
			preferredModel: r.preferredModel,
			preferredEffort: r.preferredEffort,
			nameMetadata:r.nameMetadata
		};

	function view(s:Session, ?before:Int):AgentView {
		var pending = AgentRequestPage.project([for (id => r in s.requests) {
			id:id, method:r.method, detail:r.detail, reviewable:r.reviewable, questions:r.structured
		}]);
		return {
			record: copy(s.record),
			activity: s.activity,
			items: s.conversation.page(before),
			itemsOmitted: false,
			itemsNext: s.conversation.next(before) != null ? s.conversation.next(before)
				: s.historyPages.firstCursor(s.conversation.epoch()),
			historyEpoch: s.conversation.epoch(),
			supportsImageUpload: imageUploadAvailable,
            supportsMessageContent: true,
			models: models,
			modelsNext: modelsNext,
			currentModel: s.currentModel,
			currentEffort: s.currentEffort,
			connectionState: s.attached ? "connected" : s.record.state == "reconnecting" ? "reconnecting" : "disconnected",
			recoveryReason: recoveryReason(s),
			requests: pending.requests,
			requestsOmitted: pending.omitted,
			error: s.error
		};
	}

	function nativeHistory(s:Session, cursor:String, ctx:RpcContext<AgentView>):Void {
		var epoch=s.conversation.epoch(), native=s.historyPages.resolve(epoch,cursor);
		if(native==null) {ctx.fail({code:"invalid_cursor",message:"Activity history changed; refresh the session",ambiguous:false});return;}
		function respond(page:workspace.provider.CodexHistoryPages.NativePage):Void {
			var result=view(s);
			result.items=CodexHistoryPages.merge(page,s.conversation);
			result.itemsNext=page.next==null ? null : s.historyPages.following(epoch,cursor,page.next);
			if(page.next!=null && result.itemsNext==null) {
				ctx.fail({code:"history_unavailable",message:"Earlier activity cursor limit or cycle reached; reconnect the session to restart history",ambiguous:false});return;
			}
			ctx.respond(result);
		}
		var cached=s.historyPages.get(native);
		if(cached!=null) {respond(cached);return;}
		var generation=connectionGeneration;
		call("thread/items/list",{threadId:s.record.thread,limit:8,sortDirection:"desc",cursor:native},function(reply) {
			if(ctx.isCancelled()) return;
			if(sessions.get(s.record.id)!=s || generation!=connectionGeneration || s.conversation.epoch()!=epoch) {
				ctx.fail({code:"invalid_cursor",message:"Activity history changed; refresh the session",ambiguous:false});return;
			}
			if(reply.error!=null) {ctx.fail({code:"history_unavailable",message:"Could not load earlier activity: "+reply.error,ambiguous:false});return;}
			var data:Dynamic=Reflect.field(reply.result,"data"), next=string(reply.result,"nextCursor");
			if(!Std.isOfType(data,Array) || (cast data:Array<Dynamic>).length>8
				|| !CodexHistoryPages.validNext(epoch,native,next,(cast data:Array<Dynamic>).length)) {
				ctx.fail({code:"invalid_response",message:"Invalid native activity history page",ambiguous:false});return;
			}
			respond(s.historyPages.remember(native,next=="" ? null : next,cast data));
		});
	}

    public function messageContent(session:String, turn:String, item:String, token:String, offset:Int):Null<AgentContentChunk> {
        var s=sessions.get(session);
        if(s == null) return null;
        var live=s.conversation.content(turn,item,token,offset);
        return live == null ? s.historyPages.content(turn,item,token,offset) : live;
    }

	function recoveryReason(s:Session):Null<String> {
		if (s.record.thread == "" || s.attached
			|| (s.record.state != "disconnected" && s.record.state != "reconnect-failed")) return null;
		var lower = s.error == null ? "" : s.error.toLowerCase();
		if (lower.indexOf("thread not found") >= 0 || lower.indexOf("unknown thread") >= 0)
			return "thread-unavailable";
		if (lower.indexOf("active writer") >= 0) return "active-writer";
		if (lower.indexOf("thread directory does not match") >= 0) return "workspace-mismatch";
		if (isPermanentProviderError(lower) || lower.indexOf("unsupported codex") >= 0) return "setup-required";
		return "temporary";
	}

	function append(s:Session, text:String):Void {
		s.activity += text;
		if (s.activity.length > 16384)
			s.activity = s.activity.substring(s.activity.length - 16384);
	}

	function retrySeconds(attempt:Int):Float {
		var base = Math.min(30, Math.pow(2, Math.min(5, Math.max(0, attempt - 1))));
		return base * (0.8 + Math.random() * 0.4);
	}

	function hasRecoverableSessions():Bool {
		for (s in sessions)
			if (s.record.thread != "" && !s.attached && !s.reconnectBlocked) return true;
		return false;
	}

	function isPermanentProviderError(reason:String):Bool {
		var lower = reason == null ? "" : reason.toLowerCase();
		return lower.indexOf("unsupported codex") >= 0 || lower.indexOf("authentication") >= 0
			|| lower.indexOf("unauthorized") >= 0 || lower.indexOf("invalid api key") >= 0
			|| lower.indexOf("not logged in") >= 0 || lower.indexOf("login required") >= 0
			|| lower.indexOf("forbidden") >= 0 || lower.indexOf("permission denied") >= 0
			|| lower.indexOf("method not found") >= 0 || lower.indexOf("unknown method") >= 0
			|| lower.indexOf("method not supported") >= 0 || lower.indexOf("unsupported protocol version") >= 0;
	}

	function isPermanentSessionError(reason:String):Bool {
		var lower = reason == null ? "" : reason.toLowerCase();
		return lower.indexOf("thread directory does not match") >= 0 || lower.indexOf("thread not found") >= 0
			|| lower.indexOf("unknown thread") >= 0 || lower.indexOf("not found") >= 0
			|| lower.indexOf("unauthorized") >= 0 || lower.indexOf("authentication") >= 0
			|| lower.indexOf("invalid api key") >= 0 || lower.indexOf("forbidden") >= 0
			|| lower.indexOf("unsupported codex") >= 0 || lower.indexOf("active writer") >= 0
			|| lower.indexOf("method not found") >= 0 || lower.indexOf("unknown method") >= 0
			|| lower.indexOf("method not supported") >= 0 || lower.indexOf("unsupported protocol version") >= 0;
	}

	function updateRecoveryStatus():Void {
		if (phase != "ready") return;
		var retrying = false, blocked = false;
		for (s in sessions) if (s.record.thread != "" && !s.attached) {
			if (s.reconnectBlocked) blocked = true; else retrying = true;
		}
		status = retrying ? "Reconnecting Codex sessions" : blocked ? "Codex connected; some sessions need attention" : "Codex connected";
		status += " (" + cliVersion + "; " + serverVersion + ")";
	}

	function withVersions(reason:String):String
		return reason + " (" + cliVersion + "; " + serverVersion + ")";

	function scheduleConnectionRetry():Void {
		if (startupBlocked) return;
		retryAt = clock() + retryDelay * 1000 * (0.8 + Math.random() * 0.4);
		retryDelay = Math.min(30, retryDelay * 2);
	}

	function failStartup(reason:String, permanent:Bool = false):Void {
		phase = "failed";
		status = withVersions(reason);
		if (permanent || isPermanentProviderError(reason)) {
			startupBlocked = true;
			for (s in sessions) if (s.record.thread != "") {
				s.attached = false;
				s.busy = false;
				s.reconnectBlocked = true;
				s.record.state = "reconnect-failed";
				s.error = reason;
			}
		} else scheduleConnectionRetry();
	}

	function start(manual:Bool = false):Void {
		if (manual) startupBlocked = false;
		if ((phase != "stopped" && phase != "failed") || startupBlocked)
			return;
		connectionGeneration++;
		retryAt = 0;
		for (s in sessions) if (s.record.thread != "" && !s.attached && !s.reconnectBlocked) {
			s.record.state = "reconnecting";
			s.error = null;
		}
		try {
			starter = processes.start(executable, commandPrefix.concat(["--version"]), directories.root);
			output = "";
			phase = "version";
			deadline = clock() + 15000;
			status = "Checking Codex version";
		} catch (e:Dynamic) {
			failStartup(Std.string(e));
		}
	}

	public function poll():Void {
		if (starter != null) {
			var process = starter;
			output += process.readStdout() + process.readStderr();
			if (output.length > 4096 || clock() >= deadline) {
				processes.release(process);
				starter = null;
				failStartup("Codex startup timed out");
				return;
			}
			if (process.exited()) {
				var exit = process.exitStatus();
				processes.release(process);
				starter = null;
				if (exit != 0) {
					failStartup("Codex startup failed" + (StringTools.trim(output) == "" ? "" : ": " + StringTools.trim(output)));
					return;
				}
				if (phase == "version") {
					var versionParts = StringTools.trim(output).split(" ");
					cliVersion = versionParts.length > 1 ? versionParts[1] : StringTools.trim(output);
					try {
						starter = processes.start(executable, commandPrefix.concat(["app-server", "daemon", "start"]), directories.root);
						phase = "daemon";
						output = "";
						deadline = clock() + 15000;
						status = "Starting shared Codex daemon";
					} catch (e:Dynamic) {
						failStartup(Std.string(e));
					}
				} else {
					try {
						if (bridge == null) throw "Codex WebSocket proxy bridge is not configured";
						var python = Sys.systemName() == "Windows" ? "python" : "python3";
						proxy = processes.start(python, [bridge, executable].concat(commandPrefix), directories.root);
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
								var agentParts = StringTools.trim(agent).split(" ");
								serverVersion = agentParts.length == 0 || agentParts[0] == "" ? "unknown server" : agentParts[0];
								if (!connection.send({method: "initialized"})) {
									connection.close("Codex initialization queue failed");
									return;
								}
								phase = "ready";
								connectedAt = clock();
								retryAt = 0;
								status = "Codex connected (" + cliVersion + "; " + serverVersion + ")";
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
		if ((phase == "stopped" || phase == "failed") && !startupBlocked && hasRecoverableSessions() && clock() >= retryAt)
			start();
		if (phase == "ready") {
			if(!storageFailed && !nativeNamingUnsupported) for(s in sessions) if(names(s).poll()) break;
			reconcileNextSession();
			updateRecoveryStatus();
		}
	}

	function disconnect(reason:String):Void {
		connectionGeneration++;
		recoveringSession = null;
		if (connectedAt > 0 && clock() - connectedAt >= 60000) retryDelay = 1;
		connectedAt = 0;
		var current = transport;
		transport = null;
		if (current != null)
			current.close(reason);
		if (proxy != null) {
			processes.release(proxy);
			proxy = null;
		}
		phase = "failed";
		status = withVersions(reason);
		var permanent = isPermanentProviderError(reason);
		if (permanent) startupBlocked = true;
		else scheduleConnectionRetry();
		for (s in sessions) {
			s.attached = false;
			s.busy = false;
			s.requests.clear();
			s.error = reason;
			if (s.record.thread != "") {
				if (permanent) {
					s.reconnectBlocked = true;
					s.record.state = "reconnect-failed";
				} else if (!s.reconnectBlocked) s.record.state = "disconnected";
			}
		}
	}

	function scheduleSessionRetry(s:Session):Void {
		s.reconnectAttempts++;
		s.reconnectAt = clock() + retrySeconds(s.reconnectAttempts) * 1000;
	}

	function reconcileNextSession():Void {
		if (phase != "ready" || recoveringSession != null) return;
		var candidates:Array<Session> = [];
		for (s in sessions)
			if (s.record.thread != "" && !s.attached && !s.busy && !s.reconnectBlocked && clock() >= s.reconnectAt)
				candidates.push(s);
		if (candidates.length == 0) return;
		candidates.sort(function(a, b) return Reflect.compare(a.record.id, b.record.id));
		var s = candidates[0];
		var generation = connectionGeneration;
		recoveringSession = s;
		s.busy = true;
		s.record.state = "reconnecting";
		s.error = null;
		loadThread(s, function(r) {
			if (generation != connectionGeneration) return;
			recoveringSession = null;
			s.busy = false;
			if (r.error != null) {
				s.attached = false;
				s.error = r.error;
				if (isPermanentSessionError(r.error)) {
					s.reconnectBlocked = true;
					s.record.state = "reconnect-failed";
				} else {
					s.record.state = "disconnected";
					scheduleSessionRetry(s);
				}
			} else {
				s.reconnectAttempts = 0;
				s.reconnectAt = 0;
				s.reconnectBlocked = false;
			}
			updateRecoveryStatus();
		});
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
  s.eventRevision++;
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
			questions: questions,
			structured: reviewable && method == "item/tool/requestUserInput" ? StructuredQuestions.project("codex", params) : null
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
		if (method == "thread/name/updated") {
			var name:Dynamic=Reflect.field(params,"threadName");
			if(name==null || Std.isOfType(name,String) && Std.string(name).length<=2048) names(s).observeExternal(name);
			return;
		}
		if (method == "turn/started") {
			s.eventRevision++;
			var t = Reflect.field(params, "turn");
			s.record.turn = string(t, "id");
			s.record.state = "working";
		} else if (method == "turn/completed") {
			var t = Reflect.field(params, "turn");
			if (s.record.turn != null && string(t, "id") != s.record.turn)
				return;
			s.eventRevision++;
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
			s.eventRevision++;
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

	/** Metadata reads require loaded threads on some supported servers. The
	 * directory-filtered catalog also exposes persisted threads without loading history. */
	function readThreadMetadata(s:Session, done:JsonRpcResponse->Void):Void {
		var generation = connectionGeneration;
		function page(cursor:Null<String>, count:Int):Void {
			call("thread/list", {cwd: s.record.cwd, limit: 32, cursor: cursor, archived: false}, function(r) {
				if (generation != connectionGeneration) { done(new JsonRpcResponse(null, "Codex connection changed")); return; }
				if (r.error != null) { done(r); return; }
				var data:Array<Dynamic> = Reflect.field(r.result, "data");
				if (data == null || data.length > 32) { done(new JsonRpcResponse(null, "Invalid thread metadata catalog")); return; }
				for (thread in data) if (string(thread, "id") == s.record.thread) {
					done(new JsonRpcResponse({thread: thread}, null)); return;
				}
				var next = string(r.result, "nextCursor");
				if (next == "" || count >= 8) { done(new JsonRpcResponse(null, "Thread not found in this workspace's bounded metadata catalog")); return; }
				if (next == cursor || next.length > 2048) { done(new JsonRpcResponse(null, "Invalid thread metadata cursor")); return; }
				page(next, count + 1);
			});
		}
		call("thread/read", {threadId: s.record.thread, includeTurns: false}, function(r) {
			if (generation != connectionGeneration) { done(new JsonRpcResponse(null, "Codex connection changed")); return; }
			if (r.error != null && r.error.toLowerCase().indexOf("thread not loaded") >= 0) page(null, 1);
			else done(r);
		});
	}

	function loadThread(s:Session, done:JsonRpcResponse->Void):Void {
		var generation = connectionGeneration;
		var eventRevision = s.eventRevision;
		var restoredActive = false;
		var restoredTurn:Null<String> = null;
		function stale():Bool return generation != connectionGeneration;
		function connectionChanged():Void done(new JsonRpcResponse(null, "Codex connection changed during session recovery"));
		// Read metadata first: no thread from another project is resumed or policy-mutated.
		readThreadMetadata(s, function(r) {
			if (stale()) { connectionChanged(); return; }
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
				if (stale()) { connectionChanged(); return; }
				if (resumed.error == null) {
					if (s.record.sandboxPolicy == null)
						s.record.sandboxPolicy = CodexPermissions.sandboxType(Reflect.field(resumed.result, "sandbox"));
					if (s.record.approvalPolicy == null)
						s.record.approvalPolicy = CodexPermissions.approvalType(Reflect.field(resumed.result, "approvalPolicy"));
					if (s.record.permissionProfile == null)
						s.record.permissionProfile = CodexPermissions.profileFor(s.record.sandboxPolicy, s.record.approvalPolicy);
					save(s);
					// Active turns are discovered from status; no prompt is replayed.
					var thread = Reflect.field(resumed.result, "thread"),
						state = Reflect.field(thread, "status");
					if (valid(string(thread, "model"), 256)) s.currentModel = string(thread, "model");
					var reasoningEffort = string(thread, "reasoningEffort");
					s.currentEffort = reasoningEffort == "" ? null : reasoningEffort;
					restoredActive = string(state, "type") == "active";
					append(s, "\nReattached to Codex thread " + s.record.thread + "\n");
					call("thread/turns/list", {
						threadId: s.record.thread,
						limit: 1,
						sortDirection: "desc",
						itemsView: "summary"
					}, function(turns) {
						if (stale()) { connectionChanged(); return; }
						if (turns.error != null) {
							done(turns);
							return;
						}
						var data:Array<Dynamic> = Reflect.field(turns.result, "data");
						if (data != null && data.length > 0 && string(data[0], "status") == "inProgress") {
							restoredTurn = string(data[0], "id");
						}
						var historyBaseline = s.conversation.historyBaseline();
						call("thread/items/list", {threadId:s.record.thread,limit:8,sortDirection:"desc"}, function(items) {
							if(stale() || sessions.get(s.record.id)!=s) {connectionChanged();return;}
							if(items.error != null) {done(items);return;}
							var data:Dynamic=Reflect.field(items.result,"data"), next=string(items.result,"nextCursor");
							if(!Std.isOfType(data,Array) || (cast data:Array<Dynamic>).length>8 || (next!="" && CodexHistoryPages.cursor(s.conversation.epoch(),next)==null)) {
								done(new JsonRpcResponse(null,"Invalid conversation history page"));return;
							}
							var historyTurn=s.eventRevision==eventRevision ? restoredTurn : s.record.turn;
							s.conversation.history(cast data,historyTurn,historyBaseline);
							s.historyPages.reset(next);
							s.attached=true;s.error=null;
							if(s.eventRevision==eventRevision) {s.record.turn=restoredTurn;s.record.state=restoredTurn!=null || restoredActive ? "working" : "idle";}
							save(s);done(resumed);
						});
					});
					return;
				}
				done(resumed);
			});
		});
	}

	public function driverKind():String return "codex";
	public function summary():String return status;
	public function owns(id:String):Bool return sessions.exists(id);
	public function records():Array<AgentRecord> return [for (s in sessions) copy(s.record)];

	public function modelCatalog(q:AgentModelsQuery, ctx:RpcContext<AgentModelsPage>):Void {
		if (storageFailed) {
			ctx.fail({code: "storage_unavailable", message: "Agent storage requires recovery", ambiguous: false});
			return;
		}
		if (q.cursor != null && !valid(q.cursor, 2048)) {
			ctx.fail({code: "invalid_cursor", message: "Invalid model catalog cursor", ambiguous: false});
			return;
		}
		if (phase != "ready") {
			start(true);
			ctx.fail({code: "provider_starting", message: status, ambiguous: false});
			return;
		}
		call("model/list", {limit: 32, includeHidden: false, cursor: q.cursor}, function(r) {
			if (r.error != null) {
				ctx.fail({code: "provider_error", message: r.error, ambiguous: false});
				return;
			}
			var data:Dynamic = Reflect.field(r.result, "data");
			if (!Std.isOfType(data, Array) || (cast data:Array<Dynamic>).length > 32) {
				ctx.fail({code: "provider_error", message: "Invalid model catalog", ambiguous: false});
				return;
			}
			var page:Array<AgentModel> = [];
			for (entry in (cast data:Array<Dynamic>)) {
				if (Reflect.field(entry, "hidden") == true) continue;
				var model = string(entry, "model"), name = string(entry, "displayName");
				if (!valid(model, 256) || !valid(name, 256)) {
					ctx.fail({code: "provider_error", message: "Invalid model catalog entry", ambiguous: false});
					return;
				}
				page.push({model: model, name: name, defaultEffort: null, supportedEfforts: null});
			}
			var next = string(r.result, "nextCursor");
			if (next.length > 2048) {
				ctx.fail({code: "provider_error", message: "Invalid model catalog cursor", ambiguous: false});
				return;
			}
			ctx.respond({models: page, next: next == "" ? null : next});
		});
	}

	public function discover(q:AgentDiscoveryQuery, ctx:RpcContext<AgentDiscovery>):Void {
		if (storageFailed) {
			ctx.fail({code: "storage_unavailable", message: "Agent storage requires recovery", ambiguous: false});
			return;
		}
		var cwd = directory(q.group);
		if (cwd == null || (q.cursor != null && q.cursor.length > 2048)) {
			ctx.fail({code: "invalid_request", message: "Invalid thread discovery directory or cursor", ambiguous: false});
			return;
		}
		if (phase != "ready") {
			start(true);
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
	}

	public function create(q:AgentCreate, ctx:RpcContext<AgentRecord>):Void {
		if (storageFailed) {
			ctx.fail({code: "storage_unavailable", message: "Agent storage requires recovery", ambiguous: false});
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
		var defaultModel:Null<String> = null;
		var defaultEffort:Null<String> = null;
		var permissionProfile:Null<CodexPermissionProfile> = null;
		if (q.thread == null) {
			if (q.defaultModel != null && StringTools.trim(q.defaultModel).length > 0) {
				defaultModel = StringTools.trim(q.defaultModel);
				if (!valid(defaultModel, 256)) {
					ctx.fail({code: "invalid_model", message: "Default Codex model must be a model ID of at most 256 characters", ambiguous: false});
					return;
				}
			}
			if (q.defaultEffort != null) {
				defaultEffort = q.defaultEffort;
				if (!effortSupported(defaultEffort, defaultModel)) {
					ctx.fail({code: "invalid_effort", message: "Choose an effort supported by the selected Codex model", ambiguous: false});
					return;
				}
			}
			var profileId = q.permissionProfile == null ? "workspace-write" : q.permissionProfile;
			permissionProfile = CodexPermissions.find(profileId);
			if (permissionProfile == null) {
				ctx.fail({code: "invalid_permissions", message: "Choose a supported default Codex permission preset", ambiguous: false});
				return;
			}
		}
		if (phase != "ready") {
			start(true);
			ctx.fail({code: "provider_starting", message: status + "; retry when connected", ambiguous: false});
			return;
		}
		var s:Session = {
			record: {
				id: q.id,
				provider: "codex",
				name: q.name,
				group: q.group,
				cwd: cwd,
				thread: q.thread == null ? "" : q.thread,
				state: "creating",
				turn: null,
				workspaceRoot: directories.root,
				sandboxPolicy: permissionProfile == null ? null : permissionProfile.sandboxPolicy,
				approvalPolicy: permissionProfile == null ? null : permissionProfile.approvalPolicy,
				permissionProfile: permissionProfile == null ? null : permissionProfile.id,
				preferredModel: defaultModel,
				preferredEffort: defaultEffort,
				nameMetadata:{source:"native",nativeName:null}
			},
			activity: "",
			conversation: new CodexConversation(),
			historyPages: new CodexHistoryPages(),
			error: null,
			attached: false,
			busy: true,
			requests: [],
			currentModel: null,
			currentEffort: null,
			reconnectAttempts: 0,
			reconnectAt: 0,
			reconnectBlocked: false,
			eventRevision: 0
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
				if (s.record.thread == "") s.record.state = "uncertain";
				else if (isPermanentSessionError(r.error)) {
					s.reconnectBlocked = true;
					s.record.state = "reconnect-failed";
				} else {
					s.record.state = "disconnected";
					scheduleSessionRetry(s);
				}
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
			if (valid(string(thread, "model"), 256)) s.currentModel = string(thread, "model");
			var reasoningEffort = string(thread, "reasoningEffort");
			s.currentEffort = reasoningEffort == "" ? null : reasoningEffort;
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
		if (q.thread == null) {
			var startProfile = permissionProfile;
			if (startProfile == null) {
				ctx.fail({code: "invalid_permissions", message: "Missing Codex permission preset", ambiguous: false});
				return;
			}
			call("thread/start", {
				cwd: cwd,
				sandbox: startProfile.threadSandbox,
				approvalPolicy: startProfile.approvalPolicy
			}, complete);
		} else
			loadThread(s, complete);
	}

	public function action(q:AgentAction, ctx:RpcContext<AgentView>):Void actionWithImages(q, ctx, []);

	public function actionWithImages(q:AgentAction, ctx:RpcContext<AgentView>, imagePaths:Array<String>, ?pinImages:String->Bool):Void {
		if (storageFailed) {
			ctx.fail({code: "storage_unavailable", message: "Agent storage requires recovery", ambiguous: false});
			return;
		}
		var s = sessions.get(q.id);
		if (s == null) {
			ctx.fail({code: "unknown_agent", message: "Unknown agent", ambiguous: false});
			return;
		}
		if(q.action == "inspect-name" || q.action == "rename-native") {
			if(!nativeNamingSupported()) {ctx.fail({code:"unsupported_operation",message:"This Codex version does not support native naming. Use Rename in Workbench or update Codex.",ambiguous:false});return;}
			var sync=names(s);
			if(q.action == "inspect-name") sync.inspect(function() ctx.respond(view(s)),function(problem) ctx.fail(problem));
			else if(q.request==null) ctx.fail({code:"invalid_request",message:"Reopen Rename before saving",ambiguous:false});
			else sync.rename(q.request,q.expectedNativeName,q.text,function() ctx.respond(view(s)),function(problem) ctx.fail(problem));
			return;
		}
		if (q.action == "read") {
			if(q.after != null && CodexHistoryPages.isNative(q.after)) {nativeHistory(s,q.after,ctx);return;}
			var before:Null<Int> = null;
			if (q.after != null) {
				before = s.conversation.cursorOffset(q.after);
				if (before == null) {
					ctx.fail({code: "invalid_cursor", message: "Activity history changed while loading. Refreshing activity.", ambiguous: false});
					return;
				}
			}
			ctx.respond(view(s, before));
			return;
		}
		if (q.action == "move" || q.action == "rename") {
			try {
				var error = q.action == "move"
					? AgentMetadata.move(s.record, q.request, q.text, groups(), function() save(s))
					: AgentMetadata.rename(s.record, q.request, q.text, function() save(s));
				if (error != null) {
					ctx.fail({code: error, message: "Session metadata changed or the new name or destination is invalid", ambiguous: false});
					return;
				}
			} catch (_:Dynamic) {
				storageFailed = true;
				ctx.fail({code: "storage_unavailable", message: "Session metadata could not be saved", ambiguous: false});
				return;
			}
			ctx.respond(view(s));
			return;
		}
		if (q.action == "delete") {
			if (s.busy || s.record.state == "working" || s.record.state == "needs-attention") {
				ctx.fail({code: "busy", message: "Wait for this Codex turn to finish before removing its Workbench leaf", ambiguous: false});
				return;
			}
			var result = view(s);
			try {
				if (persistence != null) persistence.removeAgent(q.id);
			} catch (e:Dynamic) {
				storageFailed = true;
				ctx.fail({code: "storage_unavailable", message: "Agent leaf could not be removed from storage", ambiguous: false});
				return;
			}
			var sync=nameSync.get(q.id);if(sync!=null) sync.dispose();nameSync.remove(q.id);
			sessions.remove(q.id);
			ctx.respond(result);
			return;
		}
		if (q.action == "models") {
                if (q.request != null && (q.request != modelsNext || models == null || models.length >= 128)) {
                    ctx.fail({code: "invalid_cursor", message: "Refresh the model catalog", ambiguous: false});
                    return;
                }
                call("model/list", {limit: 32, includeHidden: false, cursor: q.request}, function(r) {
                    if (r.error != null) {
                        ctx.fail({code: "provider_error", message: r.error, ambiguous: false});
                        return;
                    }
                    var data:Dynamic = Reflect.field(r.result, "data");
                    if (!Std.isOfType(data, Array) || (cast data:Array<Dynamic>).length > 32) {
                        ctx.fail({code: "provider_error", message: "Invalid model catalog", ambiguous: false});
                        return;
                    }
                    var found:Array<AgentModel> = q.request == null ? [] : models.copy();
                    for (entry in (cast data:Array<Dynamic>)) {
                        var model = string(entry, "model"), name = string(entry, "displayName");
                        if (!valid(model, 256) || !valid(name, 256)) {
                            ctx.fail({code: "provider_error", message: "Invalid model catalog entry", ambiguous: false});
                            return;
                        }
                        var duplicate = false;
                        for (existing in found) if (existing.model == model) duplicate = true;
					if (!duplicate && Reflect.field(entry, "hidden") != true) {
						var efforts:Array<String> = [];
						var rawEfforts:Dynamic = Reflect.field(entry, "supportedReasoningEfforts");
						if (rawEfforts != null) {
							if (!Std.isOfType(rawEfforts, Array) || (cast rawEfforts:Array<Dynamic>).length > 16) {
								ctx.fail({code: "provider_error", message: "Invalid model effort catalog", ambiguous: false});
								return;
							}
							for (option in (cast rawEfforts:Array<Dynamic>)) {
								var effort = string(option, "reasoningEffort");
								if (valid(effort, 64) && !efforts.contains(effort)) efforts.push(effort);
							}
						}
					found.push({
						model: model,
						name: name,
						defaultEffort: valid(string(entry, "defaultReasoningEffort"), 64) ? string(entry, "defaultReasoningEffort") : null,
						supportedEfforts: efforts
					});
					}
                    }
                    models = found;
                    var next = string(r.result, "nextCursor");
                    modelsNext = next == "" || found.length >= 128 ? null : next;
                    ctx.respond(view(s));
                });
                return;
            }
		if (q.action == "permissions") {
			var profile = CodexPermissions.find(q.text);
			if (profile == null) {
				ctx.fail({code: "invalid_permissions", message: "Choose a supported Codex permission preset", ambiguous: false});
				return;
			}
			if (s.busy || s.record.state == "working" || s.record.state == "needs-attention") {
				ctx.fail({code: "busy", message: "Wait for the Codex turn to finish before changing permissions", ambiguous: false});
				return;
			}
			s.record.sandboxPolicy = profile.sandboxPolicy;
			s.record.approvalPolicy = profile.approvalPolicy;
			s.record.permissionProfile = profile.id;
			try save(s) catch (_:Dynamic) {
				ctx.fail({code: "storage_unavailable", message: "Codex permission choice could not be saved", ambiguous: false});
				return;
			}
			ctx.respond(view(s));
			return;
		}
		if (q.action == "connect") {
			if (s.record.thread == "") {
				ctx.fail({code: "uncertain_create", message: "Creation outcome is uncertain; discover and attach the thread explicitly", ambiguous: false});
				return;
			}
			if (s.busy) {
				ctx.fail({code: "busy", message: "Agent request in progress", ambiguous: false});
				return;
			}
			if (startupBlocked) for (other in sessions) {
				other.reconnectBlocked = false;
				other.reconnectAttempts = 0;
				other.reconnectAt = 0;
			}
			s.reconnectBlocked = false;
			s.reconnectAttempts = 0;
			s.reconnectAt = 0;
			startupBlocked = false;
			s.record.state = "reconnecting";
			s.error = null;
			if (phase != "ready") {
				start();
				ctx.fail({code: "provider_starting", message: status, ambiguous: false});
				return;
			}
			s.busy = true;
			loadThread(s, function(r) {
				s.busy = false;
				if (r.error != null) {
					s.attached = false;
					s.error = r.error;
					if (isPermanentSessionError(r.error)) {
						s.reconnectBlocked = true;
						s.record.state = "reconnect-failed";
					} else {
						s.record.state = "disconnected";
						scheduleSessionRetry(s);
					}
				} else {
					s.reconnectAttempts = 0;
					s.reconnectAt = 0;
					s.reconnectBlocked = false;
				}
				ctx.respond(view(s));
			});
			return;
		}
		if (q.action == "model-settings") {
			if (q.model != null) {
				if (!valid(q.model, 256) || catalogModel(q.model) == null) {
					ctx.fail({code: "invalid_model", message: "Choose a model from the current catalog", ambiguous: false});
					return;
				}
			}
			if (q.effort != null) {
				var effortModel = q.model == null
					? (s.record.preferredModel == null ? s.currentModel : s.record.preferredModel) : q.model;
				if (!effortSupported(q.effort, effortModel)) {
					ctx.fail({code: "invalid_effort", message: "Choose a reasoning effort supported by the selected model", ambiguous: false});
					return;
				}
			}
			var previousModel = s.record.preferredModel, previousEffort = s.record.preferredEffort;
			s.record.preferredModel = q.model;
			s.record.preferredEffort = q.effort;
			try save(s) catch (_:Dynamic) {
				s.record.preferredModel = previousModel;
				s.record.preferredEffort = previousEffort;
				ctx.fail({code: "storage_unavailable", message: "Codex model and effort choice could not be saved", ambiguous: false});
				return;
			}
			ctx.respond(view(s));
			return;
		}
		if (!s.attached || phase != "ready") {
			ctx.fail({code: "disconnected", message: "Reconnect this agent before sending requests", ambiguous: false});
			return;
		}
		if (q.action == "prompt") {
			if (q.text == null || q.text.length > 8192 || (q.text.length == 0 && imagePaths.length == 0)
				|| s.busy
				|| (s.record.state != "idle" && s.record.state != "completed" && s.record.state != "failed" && s.record.state != "interrupted")) {
				ctx.fail({code: "busy", message: "Agent is busy or prompt is invalid", ambiguous: false});
				return;
			}
			var effectiveModel = q.model == null ? s.record.preferredModel : q.model;
			var effectiveEffort = q.effort == null ? s.record.preferredEffort : q.effort;
			if (effectiveModel != null && !valid(effectiveModel, 256)) {
				ctx.fail({code: "invalid_model", message: "Choose a valid Codex model ID", ambiguous: false});
				return;
			}
			if (effectiveModel != null && models != null && modelsNext == null && catalogModel(effectiveModel) == null) {
				ctx.fail({code: "invalid_model", message: "Choose a model from the current catalog", ambiguous: false});
				return;
			}
			var effortModel = effectiveModel == null ? s.currentModel : effectiveModel;
			if (!effortSupported(effectiveEffort, effortModel)) {
				ctx.fail({code: "invalid_effort", message: "Choose a reasoning effort supported by the selected model", ambiguous: false});
				return;
			}
			if (imagePaths.length > 0 && (pinImages == null || !pinImages(s.record.thread))) {
				ctx.fail({code:"image_unavailable",message:"An image expired or is unavailable. Remove it and upload it again.",ambiguous:false}); return;
			}
			s.busy = true;
			s.record.state = "working";
			s.error = null;
			append(s, "\nYou: " + q.text + "\n");
                var params:Dynamic = {threadId: s.record.thread, input: turnInput(q.text, imagePaths)};
                if (effectiveModel != null) Reflect.setField(params, "model", effectiveModel);
                if (effectiveEffort != null) Reflect.setField(params, "effort", effectiveEffort);
                if (s.record.approvalPolicy != null) Reflect.setField(params, "approvalPolicy", s.record.approvalPolicy);
                if (s.record.sandboxPolicy != null) Reflect.setField(params, "sandboxPolicy", {type: s.record.sandboxPolicy});
                call("turn/start", params, function(r) {
				s.busy = false;
				if (r.error != null) {
					var message = r.error;
					for (path in imagePaths) message = StringTools.replace(message, path, "[attached image]");
					s.error = message;
					s.record.state = "uncertain";
					ctx.fail({code: "provider_error", message: message, ambiguous: true});
					return;
				}
				var t = Reflect.field(r.result, "turn");
				s.record.turn = string(t, "id");
				if (effectiveModel != null) {
					s.currentModel = effectiveModel;
					s.currentEffort = effectiveEffort;
				} else if (effectiveEffort != null) s.currentEffort = effectiveEffort;
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
		if (q.text == null || haxe.io.Bytes.ofString(q.text).length > 8192) {
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
		} else if (pending.method == "item/tool/requestUserInput" && q.action == "answer-questions") {
			var validated = pending.reviewable ? StructuredQuestions.answers(pending.structured, q.text, "codex") : null;
			if (validated == null) { ctx.fail({code:"invalid_request", message:"Review and answer every question", ambiguous:false}); return; }
			var answers:Dynamic = {};
			for (id => values in validated) Reflect.setField(answers, id, {answers:values});
			result = {answers:answers};
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
		for(sync in nameSync) if(sync.busy) count++;
		return count;
	}

	public function dispose():Void {
		for(sync in nameSync) sync.dispose();
		if (starter != null) {
			processes.release(starter);
			starter = null;
		}
		disconnect("Workspace provider connection closed");
	}
}
