package app;

import haxe.io.Path;
import haxeon.agent.nativekit.NativeKitHttpTransport;
import haxeon.platform.NativeKitRuntime;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import sys.FileSystem;
import sys.io.File;
import workspace.provider.AgentKitProvider;
import workspace.provider.AgentKitSettings;
import workspace.provider.WorkspaceAgentService;
import workspace.runtime.WorkspaceDirectories;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceService;
import workspace.storage.WorkspaceSqliteStore;

/** Drives the built-in agent through the real RPC path against a local Anthropic-compatible server. */
class AgentKitProviderTestMain {
	static function require(ok:Bool, why:String):Void {
		if (!ok)
			throw "FAILED: " + why;
	}

	static function main():Void {
		var args = Sys.args(), root = FileSystem.fullPath(args[0]), port = args[1];
		var clock = function() return Sys.time() * 1000;
		var runtime = NativeKitRuntime.start();
		var directories = new WorkspaceDirectories(root);
		var seed = new WorkspaceService("w", "e", [{id: "work", name: "Work", cwd: root, revision: 1}]);
		var store = new WorkspaceSqliteStore(root + "/agents.sqlite", "w", seed.snapshot(), 32, root);
		var transport = new NativeKitHttpTransport(runtime.events, true);
		var state = Path.join([root, "state"]);

		function open(key:Null<String>):WorkspaceAgentService {
			var settings = new AgentKitSettings(key, "http://127.0.0.1:" + port, "mock-model", state);
			var kit = new AgentKitProvider(directories, function() return seed.snapshot().groups, clock, transport, settings, store);
			return new WorkspaceAgentService("w", "owner", directories.root, [kit], store);
		}
		var service = open("sk-test");
		var pair = MemoryTransport.pair(), client = new RpcConnection(pair.client, clock), server = new RpcConnection(pair.server, clock);
		service.bind(server, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		function pump():Void {
			runtime.events.wait(0.002);
			while (runtime.events.poll()) {}
			server.poll();
			service.poll();
			client.poll();
		}
		function wait(done:Void->Bool):Void {
			var end = clock() + 15000;
			while (!done()) {
				require(clock() < end, "Timed out waiting for the agent");
				pump();
			}
		}
		var code = "", view:Null<AgentView> = null;
		function current():AgentView
			return cast view;
		function items():Array<AgentActivityItem>
			return cast current().items;
		function create(id:String = "a", mode:Null<String> = null):Void {
			var done = false;
			code = "";
			client.call(WorkspaceAgentProtocol.CREATE, {
				workspace: "w",
				instance: "owner",
				id: id,
				name: "Agent " + id,
				group: "work",
				thread: null,
				provider: "agentkit",
				permissionProfile: mode
			}, 5000, function(_) done = true, function(e) {
				code = e.code;
				done = true;
			});
			wait(function() return done);
		}
		function act(action:String, text:String = "", ?request:String, ?model:String, id:String = "a"):Void {
			var done = false;
			code = "";
			view = null;
			client.call(WorkspaceAgentProtocol.ACTION, {
				workspace: "w",
				instance: "owner",
				id: id,
				action: action,
				text: text,
				request: request,
				model: model
			}, 5000, function(r) {
				view = r;
				done = true;
			}, function(e) {
				code = e.code;
				done = true;
			});
			wait(function() return done);
		}
		function until(target:String):Void
			wait(function() {
				act("read");
				return view != null && current().record.state == target;
			});
		function find(kind:String, title:String):Null<AgentActivityItem> {
			var found:Null<AgentActivityItem> = null;
			for (item in items())
				if (item.kind == kind && item.title == title)
					found = item;
			return found;
		}
		function lastMessage():String {
			var text = "";
			for (item in items())
				if (item.kind == "agentMessage")
					text = item.text;
			return text;
		}
		function dump():String
			return [for (item in items()) item.kind + "/" + item.title + "/" + item.state + "/" + item.text.substr(0, 40)].join(" | ");
		function file(name:String):String
			return Path.join([root, name]);

		File.saveContent(file("hello.txt"), "hello world\n");
		File.saveContent(Path.join([Path.directory(root), "agentkit-outside-" + port + ".txt"]), "TOP SECRET");

		// Creation: identity, provider routing and idempotence.
		create();
		require(code == "", "create failed: " + code);
		create();
		require(code == "", "duplicate create must be idempotent: " + code);
		create("bad", "root");
		require(code == "invalid_permissions", "unknown permission mode must be refused: " + code);
		act("read");
		require(current().record.provider == "agentkit" && current().record.permissionMode == "supervised" && current().connectionState == "connected",
			"fresh session is idle and supervised");

		// A read-only tool runs unattended and its result reaches the model.
		act("prompt", "read it");
		require(code == "", "prompt rejected: " + code);
		until("completed");
		var read = find("tool", "read_file");
		require(read != null && read.state == "completed" && read.text.indexOf("hello world") >= 0, "read_file result recorded: " + dump());
		require(lastMessage().indexOf("It says") >= 0 && lastMessage().indexOf("hello world") >= 0, "model saw the tool result: " + lastMessage());

		// A mutating tool waits for approval in supervised mode.
		act("prompt", "edit it");
		until("needs-attention");
		require(current().requests.length == 1 && File.getContent(file("hello.txt")) == "hello world\n", "edit waits for approval without touching the file");
		var requestId = current().requests[0].id;
		act("approve", "", requestId);
		require(code == "", "approve failed: " + code);
		until("completed");
		require(File.getContent(file("hello.txt")) == "goodbye world\n", "approved edit applied: " + File.getContent(file("hello.txt")));

		// Declining reports an error to the model and writes nothing.
		act("prompt", "write it");
		until("needs-attention");
		act("decline", "", current().requests[0].id);
		until("completed");
		require(!FileSystem.exists(file("new.txt")), "declined write must not create the file");
		var declined = find("tool", "write_file");
		require(declined != null && declined.state == "failed", "declined call shown as failed");

		// The sandbox refuses paths outside the workspace.
		act("prompt", "escape it");
		until("completed");
		var escape = find("tool", "read_file");
		require(escape != null && escape.state == "failed" && escape.text.indexOf("TOP SECRET") < 0, "path outside the workspace refused");

		// Stop interrupts a run and leaves the conversation usable.
		act("prompt", "slow");
		wait(function() {
			act("read");
			return current().record.state == "working" && lastMessage().length > 0;
		});
		act("stop");
		until("interrupted");
		act("prompt", "read it");
		require(code == "", "agent must accept a prompt after stop: " + code);
		until("completed");
		require(lastMessage().indexOf("It says") >= 0, "run after stop is healthy");

		// Permission modes: full access applies mutating tools without asking.
		act("permissions", "fullAccess");
		require(code == "" && current().record.permissionMode == "fullAccess", "permission change accepted");
		act("permissions", "bogus");
		require(code == "invalid_request", "invalid permission refused");
		File.saveContent(file("hello.txt"), "hello world\n");
		act("prompt", "edit it");
		until("completed");
		require(File.getContent(file("hello.txt")) == "goodbye world\n", "full access applied the edit unattended");

		// The model conversation survives a daemon restart.
		act("prompt", "count");
		until("completed");
		var before = Std.parseInt(lastMessage().substr(lastMessage().indexOf(":") + 1));
		require(before != null && before > 8, "history grows across prompts: " + lastMessage());
		service.dispose();
		service = open("sk-test");
		var pair2 = MemoryTransport.pair();
		client = new RpcConnection(pair2.client, clock);
		server = new RpcConnection(pair2.server, clock);
		service.bind(server, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		act("read");
		require(code == "" && current().record.state == "completed", "session restored after restart: " + code);
		act("prompt", "count");
		until("completed");
		var after = Std.parseInt(lastMessage().substr(lastMessage().indexOf(":") + 1));
		require(after != null && before != null && after == before + 2, "restored history reached the model: " + before + " -> " + after);

		// Without credentials a session can exist but cannot start a run.
		service.dispose();
		service = open(null);
		var pair3 = MemoryTransport.pair();
		client = new RpcConnection(pair3.client, clock);
		server = new RpcConnection(pair3.server, clock);
		service.bind(server, [WorkspaceAgentProtocol.READ, WorkspaceAgentProtocol.CONTROL]);
		act("prompt", "read it");
		require(code == "missing_credentials", "prompt without a key must be refused: " + code);
		act("read");
		require(current().error != null && current().error.indexOf("API key") >= 0, "view explains the missing key");

		transport.dispose();
		Sys.println("PASS: agentkit provider");
		Sys.exit(0);
	}
}
