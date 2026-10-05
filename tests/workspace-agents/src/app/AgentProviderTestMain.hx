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
	static function conversationTests():Void {
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

		var root = Sys.args()[0],
			executable = Sys.args()[1], bridge=Sys.args()[2],
			clock = function() return Sys.time() * 1000;
		var processes = new ProcessManager();
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
			executable,bridge);
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
		wait(function() return provider.status == "Codex connected");
		create("foreign-resource", "foreign");
		require(code == "provider_error", "Foreign thread attached");
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
		function action(kind:String, text:String = "", request:Null<String> = null):Void {
			code = "";
			view = null;
			var finished = false;
			client.call(WorkspaceAgentProtocol.ACTION, {
				workspace: "w",
				instance: "owner",
				id: "a",
				action: kind,
				text: text,
				request: request
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
		action("prompt", longPrompt);
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
		action("connect");
		require(code == "provider_starting", "Reconnect not explicit");
		wait(function() return provider.status == "Codex connected");
		action("connect");
		require(view != null && snapshot().record.state == "working" && snapshot().record.turn != null, "Active turn not reconciled");
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
			executable,bridge);
		var saved = store.loadAgents();
		require(saved.length == 2
			&& [for (r in saved) if (r.thread == thread) r].length == 1, "Thread identity did not survive workspace restart");
		provider.dispose();
		store.close();
		processes.shutdown();
		sys.io.File.saveContent(root + "/unsupported-version", "1");
		provider = new CodexProvider("w", "bad-version", new WorkspaceDirectories(root), function() return seed.snapshot().groups, processes, clock, null,
			executable,bridge);
		var badPair = MemoryTransport.pair(),
			badClient = new RpcConnection(badPair.client, clock),
			badServer = new RpcConnection(badPair.server, clock);
		provider.bind(badServer, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		badClient.call(WorkspaceAgentProtocol.CREATE, {
			workspace: "w",
			instance: "bad-version",
			id: "bad",
			name: "Codex",
			group: "work",
			thread: null
		}, 1000, function(_) throw "Unsupported version created thread", function(_) {});
		badClient.poll();
		badServer.poll();
		badClient.poll();
		wait(function() return provider.status.indexOf("Unsupported Codex version") >= 0);
		provider.dispose();
		badClient.close();
		badServer.close();
		processes.shutdown();

		Sys.println("PASS: Codex shared proxy, lazy/version handshake, create idempotence, streamed items, permission fencing, approval races, input, ambiguous prompt reconciliation, history, interruption and persisted thread identity");
	}
}
