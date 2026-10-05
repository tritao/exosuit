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
	static function require(v:Bool, s:String):Void {
		if (!v)
			throw s;
	}

	static function main():Void {
		Platform.startHeadless();
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
		platform.Native.shutdown();
		Sys.println("PASS: Codex shared proxy, lazy/version handshake, create idempotence, streamed items, permission fencing, approval races, input, ambiguous prompt reconciliation, history, interruption and persisted thread identity");
	}
}
