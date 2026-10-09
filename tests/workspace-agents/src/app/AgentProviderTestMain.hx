package app;

import workspace.provider.CodexProvider;
import workspace.runtime.WorkspaceDirectories;
import workspace.storage.WorkspaceSqliteStore;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import process.ProcessManager;
import platform.Platform;

class AgentProviderTestMain {
	static function clientActionPriorityTest():Void {
		var clock = function() return Sys.time() * 1000;
		var pair = MemoryTransport.pair();
		var clientConnection = new RpcConnection(pair.client, clock);
		var serverConnection = new RpcConnection(pair.server, clock);
		var pendingRead:Null<haxeon.rpc.RpcContext<WorkspaceAgentProtocol.AgentView>> = null;
		serverConnection.register(WorkspaceAgentProtocol.ACTION, function(q, ctx) {
			if (q.action == "read") pendingRead = ctx;
			else ctx.respond({
				record: {id: "a", name: "Codex", group: "work", cwd: "C:/work", thread: "thread-a", state: "idle", turn: null,
					workspaceRoot: "C:/work", sandboxPolicy: null, approvalPolicy: null, permissionProfile: null},
				activity: "mutation", requests: [], error: null, connectionState: "connected", recoveryReason: null
			});
		});
		var client = new workspace.client.RpcWorkspaceWorkbenchClient(new AgentTestEndpoint(clientConnection), clock);
		client.poll();
		client.agentAction("a", "read", "", null);
		serverConnection.poll();
		require(pendingRead != null, "Background read was not started");
		client.agentAction("a", "prompt", "hello", null);
		require(client.agentBusy(), "Prompt was blocked by an in-flight background read");
		serverConnection.poll();
		clientConnection.poll();
		var mutationView = client.agentView("a");
		require(!client.agentBusy() && mutationView != null
			&& mutationView.activity == "mutation", "Prompt response did not replace the pending read");
		var stale = pendingRead;
		pendingRead = null;
		stale.respond({
			record: {id: "a", name: "Codex", group: "work", cwd: "C:/work", thread: "thread-a", state: "idle", turn: null,
				workspaceRoot: "C:/work", sandboxPolicy: null, approvalPolicy: null, permissionProfile: null},
			activity: "stale read", requests: [], error: null, connectionState: "connected", recoveryReason: null
		});
		serverConnection.poll();
		clientConnection.poll();
		var afterStale = client.agentView("a");
		require(afterStale != null && afterStale.activity == "mutation", "A stale background read overwrote the user action result");
		client.agentAction("a", "read", "", null);
		serverConnection.poll();
		require(pendingRead != null, "Preempted read still consumed a read slot");
		pendingRead.respond({
			record: {id: "a", name: "Codex", group: "work", cwd: "C:/work", thread: "thread-a", state: "idle", turn: null,
				workspaceRoot: "C:/work", sandboxPolicy: null, approvalPolicy: null, permissionProfile: null},
			activity: "fresh read", requests: [], error: null, connectionState: "connected", recoveryReason: null
		});
		serverConnection.poll();
		clientConnection.poll();
		var freshView = client.agentView("a");
		require(freshView != null && freshView.activity == "fresh read", "Read capacity was not restored after preemption");
		client.dispose();
		clientConnection.close();
		serverConnection.close();
		Sys.println("PASS: user action preempts a pending background read without stale overwrite or leaked read capacity");
	}

	static function conversationTests():Void {
        var blocks = workspace.client.CodexMarkdown.parse("Before\n\n```python\ndef primes():\n    return 2\n```\nAfter");
        require(blocks.length == 3 && blocks[1].kind == "code" && blocks[1].language == "python", "Markdown fences not parsed");
        require(blocks[1].text == "def primes():\n    return 2", "Code indentation changed");
        var streaming = workspace.client.CodexMarkdown.parse("~~~~python\n# 界\n```\n");
        require(streaming.length == 1 && streaming[0].text == "# 界\n```\n", "Streaming fence was closed by a different marker");
        var nested = workspace.client.CodexMarkdown.parse("````text\n```\n````");
        require(nested[0].text == "```", "Short fence closed a longer fence");

		var conversation = new workspace.provider.CodexConversation();
		conversation.delta("t", "m", "agentMessage", "Hello ");
		conversation.history([{turnId: "t", completedAtMs: null, item: {id: "m", type: "agentMessage", text: "stale"}}], "t");
		conversation.delta("t", "m", "agentMessage", "world");
		require(conversation.items()[0].text == "Hello world", "History replaced newer streamed text");
		conversation.put("t", {id: "m", type: "agentMessage", text: "Hello world"}, true);
		conversation.put("t", {id: "m", type: "agentMessage", text: "Hello world"}, true);
		conversation.put("t", {id: "m", type: "agentMessage", text: ""}, false);
		conversation.delta("t", "m", "agentMessage", "late");
		require(conversation.items().length == 1 && conversation.items()[0].text == "Hello world", "Duplicate/late events changed a completed item");
		conversation.history([{turnId: "t", item: {id: "m", type: "agentMessage", text: "Hello world"}}, {turnId: "old", item: {id: "m", type: "agentMessage", text: "Earlier turn"}}]);
		require(conversation.items().length == 2 && conversation.items()[0].turn == "old", "Turn identity or history order lost");
		conversation.put("t", {id: "cmd", type: "commandExecution", command: "echo hello", cwd: "/work", aggregatedOutput: "hello", exitCode: 0, status: "completed"}, true);
		require(conversation.items()[2].detail.indexOf("Exit code: 0") >= 0, "Command output/exit status lost");
		conversation.put("t", {id: "file", type: "fileChange", changes: [{path: "README.md", kind: {type: "update"}, diff: "+new line"}], status: "completed"}, true);
		require(conversation.items()[3].text.indexOf("README.md") >= 0 && conversation.items()[3].detail.indexOf("+new line") >= 0, "File change details lost");
		var longText = ""; for (_ in 0...5000) longText += "界";
		conversation.put("t", {id: "large", type: "agentMessage", text: longText}, true);
		require(conversation.items()[4].truncated && conversation.items()[4].text.length == 4096, "Truncation was not explicit");
		for (i in 0...40) conversation.put("t", {id: "next" + i, type: "agentMessage", text: longText}, true);
		var total = 0;
		for (item in conversation.items()) total += item.id.length + item.turn.length + item.kind.length + item.title.length + item.text.length + item.detail.length + item.state.length;
		require(total <= 8192 && conversation.items().length <= 32 && conversation.omitted, "Conversation exceeded its retention bounds");
		var ordering = new workspace.provider.CodexConversation();
		ordering.put("older", {id: "m", type: "agentMessage", text: "old window"}, true);
		var baseline = ordering.historyBaseline();
		ordering.delta("live", "m", "agentMessage", "arrived during history read");
		ordering.history([{turnId: "recent", item: {id: "m", type: "agentMessage", text: "new window"}}], "live", baseline);
		require(ordering.items().length == 2 && ordering.items()[0].turn == "recent" && ordering.items()[1].turn == "live", "History window reordered or lost concurrent live items");
		ordering.finish("live", "interrupted");
		ordering.delta("live", "m", "agentMessage", "late");
		require(ordering.items()[1].state == "interrupted" && ordering.items()[1].text == "arrived during history read", "Interrupted item accepted a late delta");
		Sys.println("PASS: structured conversation identity, streamed/history races, duplicate completion, commands, file changes and bounded retention");
	}
	static function require(v:Bool, s:String):Void {
		if (!v)
			throw s;
	}

	static function main():Void {
		conversationTests();
		clientActionPriorityTest();

		var root = Sys.args()[0],
			executable = Sys.args()[1], bridge=Sys.args()[2],
			codexScript:Null<String> = Sys.args().length >= 4 ? Sys.args()[3] : null,
			clock = function() return Sys.time() * 1000;
		var processes = new ProcessManager();
		var sources = new BuildFileCollector();
		sources.collect(root + "/build-inputs/source");
		sources.collect(root + "/build-inputs/source/nested");
		require(sources.files.length == 2, "Fingerprint source traversal followed a cycle, alias, broken link or excluded build directory");
		sources.collect(root + "/build-inputs/source", true);
		require(sources.files.length == 3, "Runtime traversal reused a source-only directory cache");
		var runtime = new BuildFileCollector();
		runtime.collect(root + "/build-inputs/runtime", true);
		require(runtime.files.length == 1, "Fingerprint runtime traversal duplicated a symlink or followed a cycle");
		var fresh = new BuildFileCollector();
		sys.io.File.saveContent(root + "/build-inputs/source/new.hx", "changed");
		fresh.collect(root + "/build-inputs/source");
		require(fresh.files.length == 3, "Fingerprint traversal retained a stale directory cache");
		var seed = new WorkspaceService("w", "e", [
			{
				id: "work",
				name: "Work",
				cwd: root,
				revision: 1
			}
		]);
		var store = new WorkspaceSqliteStore(root + "/agents.sqlite", "w", seed.snapshot(), 32, root);
		var provider = new CodexProvider("w", "owner", new WorkspaceDirectories(root), function() return seed.snapshot().groups, processes, clock, store,
			executable,bridge,codexScript);
		var pair = MemoryTransport.pair(),
			client = new RpcConnection(pair.client, clock),
			server = new RpcConnection(pair.server, clock);
		provider.bind(server, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		var pair2 = MemoryTransport.pair(),
			observer = new RpcConnection(pair2.client, clock),
			observerServer = new RpcConnection(pair2.server, clock);
		provider.bind(observerServer, [WorkspaceAgentProtocol.READ]);
		function pump():Void {
			client.poll();
			server.poll();
			observer.poll();
			observerServer.poll();
			provider.poll();
			client.poll();
			observer.poll();
			Sys.sleep(0.005);
		}
		function wait(done:Void->Bool):Void {
			var end = clock() + 20000;
			while (!done()) {
				require(clock() < end, "Timed out: " + provider.status);
				pump();
			}
		}
		var code = "", record:Null<AgentRecord> = null;
		function create(id:String, thread:Null<String>):Void {
			code = "";
			record = null;
			var finished = false;
			client.call(WorkspaceAgentProtocol.CREATE, {
				workspace: "w",
				instance: "owner",
				id: id,
				name: "Codex",
				group: "work",
				thread: thread
			}, 20000, function(r) {
				record = r;
				finished = true;
			}, function(e) {
				code = e.code;
				finished = true;
			});
			wait(function() return finished);
		}
		create("a", null);
		require(code == "provider_starting", "Lazy provider startup did not report state");
		wait(function() return StringTools.startsWith(provider.status, "Codex connected"));
		create("foreign-resource", "foreign");
		require(code == "provider_error", "Foreign thread attached");
		create("missing-resource", "missing");
		require(code == "provider_error", "Missing Codex thread attached");
		create("owned-resource", "owned");
		require(code == "provider_error", "Thread owned by another client attached");
		create("a", null);
		require(record != null && record.thread == "thread-1", "Thread creation failed");
		var created = record;
		if (created == null)
			throw "Missing created resource";
		var thread = created.thread;
		create("a", null);
		require(record != null && record.thread == thread, "Repeated create duplicated thread");
		var view:Null<AgentView> = null;
		function snapshot():AgentView {
			var v = view;
			if (v == null)
				throw "Missing view";
			return v;
		}
		function action(kind:String, text:String = "", request:Null<String> = null, model:Null<String> = null):Void {
			code = "";
			view = null;
			var finished = false;
			client.call(WorkspaceAgentProtocol.ACTION, {
				workspace: "w",
				instance: "owner",
				id: "a",
				action: kind,
				text: text,
				request: request,
				model: model
			}, 20000, function(v) {
				view = v;
				finished = true;
			}, function(e) {
				code = e.code;
				finished = true;
			});
			wait(function() return finished);
		}
		var longPrompt = "";
		for (_ in 0...2500)
			longPrompt += "界";
		action("models");
		require(snapshot().connectionState == "connected", "Connected agent view did not expose connection readiness");
		var catalogModels = snapshot().models;
		require(catalogModels != null && catalogModels.length == 1, "Model catalog missing");
		action("prompt", "invalid model", null, "unlisted-model");
		require(code == "invalid_model", "Unlisted model accepted");
		action("prompt", longPrompt, null, "fixture-model");
		wait(function() {
			action("read");
			return view != null && snapshot().requests.length == 1;
		});
		require(snapshot().activity.indexOf("Hello streamed world") >= 0, "Streamed text lost");
		require(snapshot().items != null && snapshot().items[0].text == "Hello streamed world", "Typed streamed item lost across RPC");
		require(snapshot().requests[0].detail.indexOf("Command: echo test") >= 0 && snapshot().requests[0].detail.indexOf("threadId") < 0, "Approval presentation leaked transport metadata or lost the command");
		var approval = snapshot().requests[0].id;
		var denied = false;
		observer.call(WorkspaceAgentProtocol.ACTION, {
			workspace: "w",
			instance: "owner",
			id: "a",
			action: "approve",
			text: "",
			request: approval
		}, 1000, function(_) throw "Read-only approval granted",
			function(e) denied = e.code == "unauthorized");
		wait(function() return denied);
		action("approve", "", approval);
		require(code == "", "Approval failed");
		action("approve", "", approval);
		require(code == "resolved", "Approval replied twice");
		wait(function() {
			action("read");
			return snapshot().requests.length == 1 && snapshot().requests[0].method == "item/tool/requestUserInput";
		});
		require(snapshot().requests[0].detail.indexOf("Pick a choice") >= 0 && snapshot().requests[0].detail.indexOf("yes: Proceed") >= 0, "Input question/options lost in presentation");
		action("answer", "choice=yes", snapshot().requests[0].id);
		wait(function() {
			action("read");
			return snapshot().record.state == "completed";
		});
		// A lost acknowledgement must not replay a turn.
		action("prompt", "disconnect");
		require(code == "provider_error", "Disconnected prompt not marked ambiguous");
		wait(function() {
			action("read");
			return snapshot().record.state == "working" && snapshot().record.turn != null;
		});
		require(view != null && snapshot().record.state == "working" && snapshot().record.turn != null,
			"Dropped Codex transport did not automatically restore its active turn");
		require(snapshot().activity.indexOf("Persisted history") >= 0, "Bounded persisted history not read");
		action("stop");
		wait(function() {
			action("read");
			return snapshot().record.state == "interrupted";
		});
		action("prompt", "oversize");
		require(code == "provider_error", "Oversized Codex frame accepted");
		action("read");
		require(snapshot().record.state == "disconnected" || snapshot().record.state == "uncertain", "Overflow did not fence provider");
		// Editor transport disposal owns neither provider nor the shared server.
		observer.close();
		observerServer.close();
		action("read");
		require(snapshot().record.thread == thread, "Second-client detach altered resource");
		provider.dispose();
		client.close();
		server.close();
		store.close();
		processes.shutdown();
		store = new WorkspaceSqliteStore(root + "/agents.sqlite", "w", seed.snapshot(), 32, root);
		processes = new ProcessManager();
		provider = new CodexProvider("w", "next-owner", new WorkspaceDirectories(root), function() return seed.snapshot().groups, processes, clock, store,
			executable,bridge,codexScript);
		var saved = store.loadAgents();
		require(saved.length == 4
			&& [for (r in saved) if (r.thread == thread) r].length == 1, "Thread identity did not survive workspace restart");
		var recoveryPair = MemoryTransport.pair(),
			recoveryClient = new RpcConnection(recoveryPair.client, clock),
			recoveryServer = new RpcConnection(recoveryPair.server, clock);
		provider.bind(recoveryServer, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		function recoveryPump():Void {
			recoveryClient.poll();
			recoveryServer.poll();
			provider.poll();
			recoveryClient.poll();
			Sys.sleep(0.005);
		}
		function recoveryWait(done:Void->Bool):Void {
			var end = clock() + 20000;
			while (!done()) {
				require(clock() < end, "Timed out during automatic recovery: " + provider.status);
				recoveryPump();
			}
		}
		recoveryWait(function() return StringTools.startsWith(provider.status, "Codex connected; some sessions need attention"));
		var recoveredView:Null<AgentView> = null, recoveredFinished = false;
		recoveryClient.call(WorkspaceAgentProtocol.ACTION, {
			workspace: "w", instance: "next-owner", id: "a", action: "read", text: "", request: null
		}, 5000, function(value) { recoveredView = value; recoveredFinished = true; }, function(error) throw error.message);
		recoveryWait(function() return recoveredFinished);
		require(recoveredView != null && recoveredView.record.state == "working" && recoveredView.record.turn != null
			&& recoveredView.error == null
			&& recoveredView.items != null && Lambda.exists(recoveredView.items, function(item) return item.text.indexOf("Persisted history") >= 0),
			"Persisted Codex sessions did not automatically resume and restore history");
		var blockedView:Null<AgentView> = null, blockedFinished = false;
		recoveryClient.call(WorkspaceAgentProtocol.ACTION, {
			workspace: "w", instance: "next-owner", id: "foreign-resource", action: "read", text: "", request: null
		}, 5000, function(value) { blockedView = value; blockedFinished = true; }, function(error) throw error.message);
		recoveryWait(function() return blockedFinished);
		require(blockedView != null && blockedView.record.state == "reconnect-failed"
			&& blockedView.error != null && blockedView.error.indexOf("directory") >= 0
			&& blockedView.connectionState == "disconnected" && blockedView.recoveryReason == "workspace-mismatch",
			"A thread with a workspace mismatch was not surfaced as a retryable recovery failure");
		var missingView:Null<AgentView> = null, missingFinished = false;
		recoveryClient.call(WorkspaceAgentProtocol.ACTION, {
			workspace: "w", instance: "next-owner", id: "missing-resource", action: "read", text: "", request: null
		}, 5000, function(value) { missingView = value; missingFinished = true; }, function(error) throw error.message);
		recoveryWait(function() return missingFinished);
		require(missingView != null && missingView.record.state == "reconnect-failed"
			&& missingView.connectionState == "disconnected" && missingView.recoveryReason == "thread-unavailable",
			"An unavailable Codex thread did not retain its record and recovery reason");
		var ownedView:Null<AgentView> = null, ownedFinished = false;
		recoveryClient.call(WorkspaceAgentProtocol.ACTION, {
			workspace: "w", instance: "next-owner", id: "owned-resource", action: "read", text: "", request: null
		}, 5000, function(value) { ownedView = value; ownedFinished = true; }, function(error) throw error.message);
		recoveryWait(function() return ownedFinished);
		require(ownedView != null && ownedView.record.state == "reconnect-failed"
			&& ownedView.recoveryReason == "active-writer",
			"An active-writer conflict did not expose its recovery reason");
		provider.dispose();
		recoveryClient.close();
		recoveryServer.close();
		store.close();
		processes.shutdown();
		sys.io.File.saveContent(root + "/newer-version", "1");
		provider = new CodexProvider("w", "bad-version", new WorkspaceDirectories(root), function() return seed.snapshot().groups, processes, clock, null,
			executable,bridge,codexScript);
		var badPair = MemoryTransport.pair(),
			badClient = new RpcConnection(badPair.client, clock),
			badServer = new RpcConnection(badPair.server, clock);
		provider.bind(badServer, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		var newerVersionCode = "", newerVersionDone = false;
		badClient.call(WorkspaceAgentProtocol.CREATE, {
			workspace: "w",
			instance: "bad-version",
			id: "bad",
			name: "Codex",
			group: "work",
			thread: null
		}, 1000, function(_) throw "Create completed before Codex startup", function(error) {
			newerVersionCode = error.code;
			newerVersionDone = true;
		});
		function badWait(done:Void->Bool):Void {
			var end = clock() + 20000;
			while (!done()) {
				require(clock() < end, "Timed out: " + provider.status);
				badClient.poll();
				badServer.poll();
				provider.poll();
				badClient.poll();
				Sys.sleep(0.005);
			}
		}
		badWait(function() return newerVersionDone);
		require(newerVersionCode == "provider_starting", "Newer Codex CLI version did not begin startup");
		badWait(function() return StringTools.startsWith(provider.status, "Codex connected"));
		require(provider.status.indexOf("0.999.0") >= 0 && provider.status.indexOf("codex-cli/0.162.0") >= 0,
			"Detected Codex versions were not reported after successful initialization");
		var newerRecord:Null<AgentRecord> = null, newerCreateDone = false;
		badClient.call(WorkspaceAgentProtocol.CREATE, {
			workspace: "w",
			instance: "bad-version",
			id: "newer-version-resource",
			name: "Codex",
			group: "work",
			thread: null
		}, 5000, function(value) {
			newerRecord = value;
			newerCreateDone = true;
		}, function(error) throw "Compatible newer Codex version could not create a thread: " + error.message);
		badWait(function() return newerCreateDone);
		require(newerRecord != null && newerRecord.thread != "", "Compatible newer Codex version did not create a thread");
		provider.dispose();
		badClient.close();
		badServer.close();
		processes.shutdown();

		Sys.println("PASS: Codex shared proxy, automatic newer-version acceptance and diagnostics, create idempotence, streamed items, permission fencing, approval races, input, automatic active-turn and persisted-session recovery, history, interruption and workspace mismatch handling");
	}
}

private class AgentTestEndpoint implements workspace.client.WorkspaceRpcEndpoint {
	final connection:haxeon.rpc.RpcConnection;
	public function new(connection:haxeon.rpc.RpcConnection) this.connection = connection;
	public function rootPath():Null<String> return "C:/work";
	public function serviceGeneration():String return "test-generation";
	public function rpcConnection():Null<haxeon.rpc.RpcConnection> return connection;
	public function failureReason():Null<String> return null;
	public function supportsWorkspaceGroups():Bool return false;
	public function workspaceEpoch():Null<String> return null;
	public function hasCapability(capability:String):Bool
		return capability == WorkspaceAgentProtocol.READ || capability == WorkspaceAgentProtocol.CONTROL;
}
