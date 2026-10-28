package workspace.provider;

import haxe.io.Path;
import haxe.crypto.Sha256;
import haxeon.agent.Agent;
import haxeon.agent.AgentEvent;
import haxeon.agent.AgentTool;
import haxeon.agent.AnthropicProvider;
import haxeon.agent.HttpTransport;
import haxeon.agent.PolicyDecision;
import haxeon.agent.ToolPolicy;
import haxeon.agent.JsonObject;
import haxeon.rpc.RpcContext;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceAgentPersistence;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;

private typedef KitApproval = {
	var detail:String;
	var reviewable:Bool;
}

/** Supervised sessions ask before mutating tools; the other modes let the agent edit freely. */
private class ModePolicy implements ToolPolicy {
	public var mode:String;

	public function new(mode:String)
		this.mode = mode;

	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return mode == "supervised" && tool.access == Mutating ? Ask : Allow;
}

private class KitSession {
	public final record:AgentRecord;
	public final conversation:AgentKitConversation;
	public final policy:ModePolicy;
	public final approvals:Map<String, KitApproval> = [];
	public var agent:Null<Agent>;
	public var busy = false;
	public var error:Null<String>;
	public var model:String;
	public var serial = 0;
	public var message = 0;

	public function new(record:AgentRecord, model:String) {
		this.record = record;
		this.model = model;
		conversation = new AgentKitConversation(record.replay);
		policy = new ModePolicy(record.permissionMode == null ? "supervised" : record.permissionMode);
	}
}

/**
	The built-in Exosuit agent: agentkit running inside the workspace daemon.
	There is no child process; the model conversation lives in the daemon and the
	NativeKit event pump delivers every response, so `poll` has nothing to do.
**/
class AgentKitProvider implements LocalAgentProvider {
	static inline var MaxPrompt = 8192;
	static inline var MaxHistoryBytes = 4194304;
	static final modes = ["supervised", "acceptEdits", "fullAccess"];
	static final catalog:Array<AgentModel> = [
		{model: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", supportedEfforts: []},
		{model: "claude-opus-5-5", name: "Claude Opus 5.5", supportedEfforts: []},
		{model: "claude-haiku-5-5", name: "Claude Haiku 5.5", supportedEfforts: []},
		{model: "claude-fable-5-1", name: "Claude Fable 5.1", supportedEfforts: []}
	];

	final directories:WorkspaceDirectories;
	final groups:Void->Array<WorkspaceGroup>;
	final clock:Void->Float;
	final persistence:Null<WorkspaceAgentPersistence>;
	final transport:HttpTransport;
	final settings:AgentKitSettings;
	final sessions:Map<String, KitSession> = [];
	var storageFailed = false;

	public function new(directories:WorkspaceDirectories, groups:Void->Array<WorkspaceGroup>, clock:Void->Float, transport:HttpTransport,
			settings:AgentKitSettings, ?persistence:WorkspaceAgentPersistence) {
		this.directories = directories;
		this.groups = groups;
		this.clock = clock;
		this.transport = transport;
		this.settings = settings;
		this.persistence = persistence;
		if (persistence != null)
			for (r in persistence.loadAgents())
				if (r.provider == "agentkit") {
					if (!valid(r.id, 128) || !valid(r.name, 256) || r.workspaceRoot != directories.root || !inside(r.cwd) || !mode(r.permissionMode)
						|| sessions.exists(r.id))
						throw "Invalid persisted Exosuit agent session";
					// A run cannot survive the daemon, and history is written only when a run ends, so the stored conversation is consistent.
					if (r.state == "working" || r.state == "needs-attention")
						r.state = "interrupted";
					r.turn = null;
					sessions.set(r.id, new KitSession(r, r.preferredModel == null ? settings.model : r.preferredModel));
				}
	}

	public function driverKind():String
		return "agentkit";

	public function nativeNamingSupported():Bool
		return false;

	public function summary():String
		return "Exosuit agent: " + [for (_ in sessions) true].length + " sessions";

	public function owns(id:String):Bool
		return sessions.exists(id);

	public function records():Array<AgentRecord>
		return [for (s in sessions) copy(s.record)];

	public function modelCatalog(q:AgentModelsQuery, ctx:RpcContext<AgentModelsPage>):Void
		ctx.respond({models: catalog, next: null});

	public function discover(q:AgentDiscoveryQuery, ctx:RpcContext<AgentDiscovery>):Void
		ctx.fail({code: "unsupported_operation", message: "Session discovery is not supported by this provider", ambiguous: false});

	public function poll():Void {}

	public function activeCount():Int
		return [for (s in sessions) if (s.busy || s.record.state == "needs-attention") true].length;

	public function updateActivityCount():Int
		return activeCount();

	public function dispose():Void {
		for (s in sessions)
			if (s.agent != null)
				s.agent.abort();
	}

	static function valid(v:Null<String>, n:Int):Bool
		return v != null && v.length > 0 && v.length <= n;

	static function mode(v:Null<String>):Bool
		return v != null && modes.indexOf(v) >= 0;

	function inside(path:Null<String>):Bool
		return directories.inside(path);

	static function copy(r:AgentRecord):AgentRecord {
		var result:AgentRecord = cast Reflect.copy(r);
		// Replay is returned through paged views, never in the catalog.
		result.replay = null;
		return result;
	}

	function save(s:KitSession):Void {
		if (storageFailed)
			throw "Agent storage requires recovery";
		s.record.replay = s.conversation.snapshot();
		if (persistence != null)
			try
				persistence.saveAgent(s.record)
			catch (e:Dynamic) {
				storageFailed = true;
				throw e;
			}
	}

	function historyPath(s:KitSession):String
		return Path.join([settings.stateDirectory, "agentkit-" + Sha256.encode(s.record.id).substr(0, 32) + ".json"]);

	function saveHistory(s:KitSession):Void {
		var agent = s.agent;
		if (agent == null)
			return;
		if (!FileSystem.exists(settings.stateDirectory))
			FileSystem.createDirectory(settings.stateDirectory);
		AtomicFile.write(historyPath(s), agent.snapshot());
	}

	function systemPrompt(s:KitSession):String
		return "You are the Exosuit coding agent, built into a code editor. Your working directory is " + s.record.cwd
			+ ". Use the provided tools to read, search and change files there; paths are relative to it. "
			+ "Read before you edit, make focused changes, and say briefly what you did. Do not claim to have run code: you cannot run commands.";

	/** Builds the agent on first use so a changed API key or model applies without recreating the session. */
	function agentFor(s:KitSession):Null<Agent> {
		var existing = s.agent;
		if (existing != null)
			return existing;
		var key = settings.apiKey;
		if (key == null)
			return null;
		var provider = new AnthropicProvider(transport, key, settings.baseUrl);
		var agent = new Agent(new haxeon.agent.AgentOptions(provider, s.model, systemPrompt(s), AgentKitTools.forDirectory(s.record.cwd), s.policy));
		var path = historyPath(s);
		if (FileSystem.exists(path)) {
			var metadata = FileSystem.metadata(path);
			if (metadata == null || metadata.size > MaxHistoryBytes || !agent.restore(File.getContent(path))) {
				s.error = "The saved conversation could not be restored";
				return null;
			}
		}
		agent.onEvent = function(event) onEvent(s, event);
		s.agent = agent;
		return agent;
	}

	function onEvent(s:KitSession, event:AgentEvent):Void {
		var turn = s.record.turn == null ? "session" : s.record.turn;
		switch event {
			case TurnStarted(_):
				s.message++;
			case TextDelta(text):
				s.conversation.delta(turn + ":m" + s.message, turn, text, "Exosuit");
			case ToolStarted(call):
				s.conversation.put(call.id, turn, "tool", call.name, "", call.inputJson, "inProgress");
			case ApprovalRequested(call, summary):
				var detail = summary + "\n" + call.inputJson;
				s.approvals.set(call.id, {detail: detail.substring(0, 2048), reviewable: detail.length <= 2048});
				s.conversation.put(call.id, turn, "tool", call.name, "", summary, "inProgress");
				s.record.state = "needs-attention";
			case ToolCompleted(call, result):
				s.approvals.remove(call.id);
				s.conversation.put(call.id, turn, "tool", call.name, result.content, "", result.isError ? "failed" : "completed");
				if (s.record.state == "needs-attention" && !s.approvals.keys().hasNext())
					s.record.state = "working";
			case RunEnded(reason):
				s.approvals.clear();
				s.busy = false;
				s.record.state = switch reason {
					case Aborted: "interrupted";
					case Failed(_): "failed";
					default: "completed";
				};
				switch reason {
					case Failed(message):
						s.error = message.substring(0, 2048);
					default:
				}
				s.conversation.finish(turn, s.record.state);
				s.record.turn = null;
				try {
					saveHistory(s);
					save(s);
				} catch (_:Dynamic)
					s.error = "The conversation could not be saved";
			default:
		}
	}

	function view(s:KitSession, ?before:Int):AgentView {
		var pending:Array<AgentRequest> = [for (id => r in s.approvals) {id:id,method:"item/commandExecution/requestApproval",detail:r.detail,reviewable:r.reviewable}];
		var page = AgentRequestPage.project(pending);
		return {
			record: copy(s.record),
			activity: "",
			items: s.conversation.page(before),
			itemsNext: s.conversation.next(before),
			historyEpoch: s.conversation.epoch(),
			historyOmitted: s.conversation.hasOmitted(),
			itemsOmitted: false,
			requests: page.requests,
			requestsOmitted: page.omitted,
			models: catalog,
			modelsNext: null,
			currentModel: s.model,
			currentEffort: null,
			connectionState: "connected",
			recoveryReason: null,
			error: s.error != null ? s.error : settings.apiKey == null ? "No API key: set ANTHROPIC_API_KEY or EXOSUIT_AGENT_API_KEY where the workspace daemon runs" : null
		};
	}

	public function create(q:AgentCreate, ctx:RpcContext<AgentRecord>):Void {
		if (storageFailed) {
			ctx.fail({code: "storage_unavailable", message: "Agent storage requires recovery", ambiguous: false});
			return;
		}
		if (!valid(q.id, 128) || !valid(q.name, 256) || q.thread != null || (q.defaultModel != null && !valid(q.defaultModel, 256)) || q.defaultEffort != null) {
			ctx.fail({
				code: "invalid_request",
				message: "Invalid Exosuit agent configuration; existing threads and effort overrides are not supported",
				ambiguous: false
			});
			return;
		}
		var previous = sessions.get(q.id);
		if (previous != null) {
			if (previous.record.name != q.name || previous.record.group != q.group)
				ctx.fail({code: "conflict", message: "Agent identity is already reserved", ambiguous: false});
			else
				ctx.respond(copy(previous.record));
			return;
		}
		var cwd:Null<String> = null;
		for (g in groups())
			if (g.id == q.group)
				cwd = directories.resolve(g.cwd);
		if (cwd == null || !inside(cwd)) {
			ctx.fail({code: "invalid_request", message: "Invalid agent group directory", ambiguous: false});
			return;
		}
		var selected = q.permissionProfile == null ? "supervised" : q.permissionProfile;
		if (!mode(selected)) {
			ctx.fail({code: "invalid_permissions", message: "Choose supervised, acceptEdits or fullAccess", ambiguous: false});
			return;
		}
		var s = new KitSession({
			id: q.id,
			name: q.name,
			group: q.group,
			cwd: cwd,
			thread: "agentkit:" + q.id,
			state: "idle",
			turn: null,
			workspaceRoot: directories.root,
			provider: "agentkit",
			nameMetadata: {source: "workbench", nativeName: null},
			permissionMode: selected,
			preferredModel: q.defaultModel
		}, q.defaultModel == null ? settings.model : q.defaultModel);
		try
			save(s)
		catch (_:Dynamic) {
			ctx.fail({code: "storage_unavailable", message: "Exosuit agent reservation failed", ambiguous: false});
			return;
		}
		sessions.set(q.id, s);
		ctx.respond(copy(s.record));
	}

	public function action(q:AgentAction, ctx:RpcContext<AgentView>):Void {
		var s = sessions.get(q.id);
		if (s == null) {
			ctx.fail({code: "unknown_agent", message: "Unknown Exosuit agent", ambiguous: false});
			return;
		}
		function error(code:String, message:String, ambiguous:Bool = false):Void
			ctx.fail({code: code, message: message, ambiguous: ambiguous});
		if (q.action == "read") {
			var before = q.after == null ? null : s.conversation.offset(q.after);
			if (q.after != null && before == null) {
				error("invalid_cursor", "Refresh activity history");
				return;
			}
			ctx.respond(view(s, before));
			return;
		}
		if (storageFailed) {
			error("storage_unavailable", "Agent storage requires recovery");
			return;
		}
		switch q.action {
			case "move", "rename":
				try {
					var problem = q.action == "move" ? AgentMetadata.move(s.record, q.request, q.text, groups(), function() save(s)) : AgentMetadata.rename(s.record,
						q.request, q.text, function() save(s));
					if (problem != null) {
						error(problem, "Session metadata changed or the new name or destination is invalid");
						return;
					}
				} catch (_:Dynamic) {
					storageFailed = true;
					error("storage_unavailable", "Session metadata could not be saved");
					return;
				}
				ctx.respond(view(s));
			case "connect", "models":
				ctx.respond(view(s));
			case "delete":
				if (s.busy || s.record.state == "needs-attention") {
					error("busy", "Stop the run before removing this session");
					return;
				}
				var result = view(s);
				try {
					if (persistence != null)
						persistence.removeAgent(q.id);
				} catch (_:Dynamic) {
					storageFailed = true;
					error("storage_unavailable", "Session could not be removed");
					return;
				}
				var path = historyPath(s);
				if (FileSystem.exists(path))
					FileSystem.deleteFile(path);
				sessions.remove(q.id);
				ctx.respond(result);
			case "stop":
				var running = s.agent;
				if (running != null)
					running.abort();
				ctx.respond(view(s));
			case "permissions":
				if (!mode(q.text)) {
					error("invalid_request", "Unsupported permission mode");
					return;
				}
				s.policy.mode = q.text;
				s.record.permissionMode = q.text;
				try
					save(s)
				catch (_:Dynamic) {
					error("storage_unavailable", "Permission change could not be saved", true);
					return;
				}
				ctx.respond(view(s));
			case "model-settings":
				if (q.effort != null || q.model == null || !valid(q.model, 256)) {
					error("invalid_request", "Unsupported model setting");
					return;
				}
				s.model = q.model;
				s.record.preferredModel = q.model;
				if (s.agent != null)
					s.agent.model = q.model;
				try
					save(s)
				catch (_:Dynamic) {
					error("storage_unavailable", "Model change could not be saved", true);
					return;
				}
				ctx.respond(view(s));
			case "prompt":
				prompt(s, q, ctx);
			case "approve", "decline":
				var request = q.request == null ? null : s.approvals.get(q.request);
				var running = s.agent;
				if (request == null || running == null || q.request == null) {
					error("resolved", "Request has resolved or disconnected");
					return;
				}
				if (q.action == "approve" && !request.reviewable) {
					error("unsupported_request", "Review the complete request before approving");
					return;
				}
				running.resolveApproval(q.request, q.action == "approve");
				ctx.respond(view(s));
			default:
				error("unsupported_operation", "This action is not supported by the Exosuit agent");
		}
	}

	function prompt(s:KitSession, q:AgentAction, ctx:RpcContext<AgentView>):Void {
		function error(code:String, message:String):Void
			ctx.fail({code: code, message: message, ambiguous: false});
		if (!valid(q.text, MaxPrompt)) {
			error("invalid_request", "Prompt must be between 1 and 8192 characters");
			return;
		}
		if (s.busy) {
			error("busy", "The agent is already working");
			return;
		}
		if (q.effort != null) {
			error("invalid_request", "Effort overrides are not supported");
			return;
		}
		if (q.model != null && q.model != s.model) {
			error("invalid_request", "Set the model before sending");
			return;
		}
		if (settings.apiKey == null) {
			error("missing_credentials", "Set ANTHROPIC_API_KEY or EXOSUIT_AGENT_API_KEY where the workspace daemon runs");
			return;
		}
		s.error = null;
		var agent = agentFor(s);
		if (agent == null) {
			error("history_unavailable", s.error == null ? "The agent could not start" : s.error);
			return;
		}
		var turn = "turn-" + (++s.serial) + "-" + Std.string(clock());
		s.record.state = "working";
		s.record.turn = turn;
		s.busy = true;
		s.message = 0;
		s.conversation.put(turn, turn, "userMessage", "You", q.text, "", "completed");
		try
			save(s)
		catch (_:Dynamic) {
			s.busy = false;
			s.record.state = "idle";
			s.record.turn = null;
			error("storage_unavailable", "Prompt was not started");
			return;
		}
		if (!agent.send(q.text)) {
			s.busy = false;
			error("busy", "The agent is already working");
			return;
		}
		ctx.respond(view(s));
	}
}
