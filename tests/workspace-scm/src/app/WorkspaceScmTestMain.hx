package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcHandshake;
import haxeon.rpc.RpcPeerOptions;
import process.ProcessManager;
import scm.RpcScmSource;
import scm.ScmApplyResult;
import scm.ScmJobResult;
import scm.ScmOperation;
import scm.ScmFeatures;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmRepositoryKind;
import scm.ScmSnapshot;
import scm.fake.FakeScmProvider;
import scm.fake.FakeScmRepositoryScript;
import jobs.JobScheduler;
import workspace.client.WorkspaceScmClient;
import workspace.runtime.WorkspaceScmService;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceService;
import workspace.transport.WorkspaceRpcServer;

private typedef ClientLink = {var connection:RpcConnection; var transport:haxeon.rpc.MessageTransport;}

class WorkspaceScmTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw "Workspace SCM test failed: " + message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length != 2) throw "Expected fixture root and trust-store path";
		compatibility();
		serviceAndClient(args[0], args[1]);
		cancellation(args[0] + "-fake", args[1] + ".fake");
		Sys.println("PASS: workspace SCM wire compatibility, local-only trust, read/write grants, operation deduplication, stale revisions, original reads and reconnect recovery");
	}

	static function compatibility():Void {
		var oldRequest = WorkspaceScmProtocol.SNAPSHOT.decodeRequest(bytes("8301a17702a17263928101a17892c301"));
		require(oldRequest.workspace == "w" && oldRequest.repository == "r",
			"an older SCM client must ignore an unknown optional field containing nested values");
		require(WorkspaceScmProtocol.READ == "workspace.scm.read"
			&& WorkspaceScmProtocol.WRITE == "workspace.scm.write"
			&& WorkspaceScmProtocol.REMOTE == "workspace.scm.remote",
			"SCM capabilities must remain stable protocol identifiers");
	}

	static function serviceAndClient(root:String, trustPath:String):Void {
		var processes = new ProcessManager(), now = function() return Sys.time() * 1000;
		var workspaces = new WorkspaceService("workspace", "test-epoch", [{id: "work", name: "Work", cwd: root, revision: 1}]);
		var scm = new WorkspaceScmService("workspace", [root], processes, gitPath(), null, trustPath);
		var server = new WorkspaceRpcServer(workspaces, now, null, null, null, null, null, null, scm);
		var connections:Array<RpcConnection> = [];
		var readGrants = [WorkspaceScmProtocol.READ];
		var readLink = connect(server, readGrants, false, now);
		connections.push(readLink.connection);
		var readClient = new WorkspaceScmClient(readLink.connection);
		var currentClient:Null<WorkspaceScmClient> = readClient;
		var source = new RpcScmSource(function() return currentClient, "workspace", "root", "workspace:fixture-root");
		var changed = 0;
		var removeListener = source.subscribe(function(_, _) changed++);
		var rawRepositories:Null<WorkspaceScmProtocol.ScmRepositoriesResult> = null;
		var rawRepositoryError:Null<haxeon.rpc.RpcError> = null;
		readClient.repositories("workspace", "root", function(value) rawRepositories = value,
			function(error) rawRepositoryError = error);
		wait(server, scm, connections, null, function() return rawRepositories != null || rawRepositoryError != null,
			"workspace RPC repository discovery responds");
		if (rawRepositoryError != null) throw "Workspace SCM discovery failed: " + rawRepositoryError.code + ": " + rawRepositoryError.message;
		require(rawRepositories != null && rawRepositories.repositories.length == 1,
			"workspace RPC discovers the real Git repository");
		source.poll();
		wait(server, scm, connections, source, function() return source.repositories().length == 1
			&& source.snapshot(source.repositories()[0].id) != null, "read-only client receives the real Git snapshot");
		var repository = source.repositories()[0];
		var initialSnapshot = source.snapshot(repository.id);
		require(initialSnapshot != null && repository.providerId == "git" && initialSnapshot.head.branch != null,
			"the RPC source decodes the agent's Git repository and branch state");
		require(!source.canWrite(repository.id) && !source.canUseRemotes(repository.id),
			"a read-only RPC source advertised write or remote access");
		if (initialSnapshot == null) throw "Missing initial SCM snapshot";

		var readOnlyError:Null<haxeon.rpc.RpcError> = null;
		readClient.apply({workspace: "workspace", repository: repository.id, operationId: "read-only-write",
			expectedRevision: initialSnapshot.revision, kind: "stage", path: "tracked.txt",
			message: null, amend: null, patch: null, reference: null, remote: null, name: null}, function(_) {
			throw "read-only client staged a file";
		}, function(error) readOnlyError = error);
		wait(server, scm, connections, source, function() return readOnlyError != null,
			"read-only mutation denial returns an RPC error");
		if (readOnlyError == null) throw "Missing read-only authorization error";
		require(readOnlyError.code == "unauthorized", "read-only mutation is denied by the SCM service");

		var allGrants = [WorkspaceScmProtocol.READ, WorkspaceScmProtocol.WRITE, WorkspaceScmProtocol.REMOTE];
		var remoteAdmin = connect(server, allGrants, false, now);
		connections.push(remoteAdmin.connection);
		var remoteAdminClient = new WorkspaceScmClient(remoteAdmin.connection);
		var remoteTrustError:Null<haxeon.rpc.RpcError> = null;
		remoteAdminClient.trust("workspace", repository.id, function(_) throw "remote device trusted a repository",
			function(error) remoteTrustError = error);
		wait(server, scm, connections, source, function() return remoteTrustError != null,
			"remote trust request returns an RPC error");
		if (remoteTrustError == null) throw "Missing remote trust error";
		require(remoteTrustError.code == "local_only", "all remote grants still cannot authorize repository trust");
		remoteAdmin.connection.close();
		server.poll();

		var local = connect(server, [WorkspaceScmProtocol.READ], true, now);
		connections.push(local.connection);
		var localClient = new WorkspaceScmClient(local.connection), localTrust:Null<workspace.service.WorkspaceScmProtocol.ScmTrustResult> = null;
		localClient.trust("workspace", repository.id, function(value) localTrust = value, function(error) throw error.message);
		wait(server, scm, connections, source, function() return localTrust != null,
			"local desktop connection can trust the fixture repository");
		if (localTrust == null) throw "Missing local trust result";
		require(localTrust.trusted, "local trust result is true");

		var staleLink = connect(server, [WorkspaceScmProtocol.WRITE], false, now);
		connections.push(staleLink.connection);
		var staleClient = new WorkspaceScmClient(staleLink.connection), staleError:Null<haxeon.rpc.RpcError> = null;
		var currentForStale = source.snapshot(repository.id);
		if (currentForStale == null) throw "Missing current SCM snapshot for stale-revision fixture";
		var remoteWithoutGrant:Null<haxeon.rpc.RpcError> = null;
		staleClient.apply({workspace: "workspace", repository: repository.id, operationId: "remote-without-grant",
			expectedRevision: currentForStale.revision, kind: "fetch", path: null, message: null, amend: null,
			patch: null, reference: null, remote: null, name: null}, function(_) throw "write-only device fetched a remote",
			function(error) remoteWithoutGrant = error);
		wait(server, scm, connections, source, function() return remoteWithoutGrant != null,
			"write-only remote operation is denied");
		if (remoteWithoutGrant == null) throw "Missing remote capability error";
		require(remoteWithoutGrant.code == "unauthorized", "remote Git operations require workspace.scm.remote separately from write");
		staleClient.apply({workspace: "workspace", repository: repository.id, operationId: "stale-write",
			expectedRevision: Int64.add(currentForStale.revision, Int64.ofInt(1)), kind: "stage",
			path: "tracked.txt", message: null, amend: null, patch: null, reference: null, remote: null, name: null},
			function(_) throw "stale SCM request was applied", function(error) staleError = error);
		wait(server, scm, connections, source, function() return staleError != null, "stale write fails promptly");
		if (staleError == null) throw "Missing stale revision error";
		require(staleError.code == "stale_revision", "write-only grants can use the write method and receive stale_revision");
		staleLink.connection.close();
		server.poll();

		var writerGrants = [WorkspaceScmProtocol.READ, WorkspaceScmProtocol.WRITE];
		var writerLink = connect(server, writerGrants, false, now);
		connections.push(writerLink.connection);
		var writerClient = new WorkspaceScmClient(writerLink.connection);
		var writerSource = new RpcScmSource(function() return writerClient, "workspace", "root", "workspace:fixture-root-writer",
			function() return true, function() return true);
		writerSource.poll();
		wait(server, scm, connections, writerSource, function() return writerSource.repositories().length == 1
			&& writerSource.snapshot(repository.id) != null, "write client receives repository snapshot");
		require(writerSource.canWrite(repository.id) && writerSource.canUseRemotes(repository.id),
			"a trusted source with write and remote grants hid its available operations");

		var decoded = false;
		writerSource.originalBytes(repository.id, ScmRef.Head, Bytes.ofString("tracked.txt"), function(result) {
			decoded = result.error == null && result.value != null && result.value.bytes.toString().indexOf("initial") >= 0;
		});
		wait(server, scm, connections, writerSource, function() return decoded, "original content is returned as raw bytes");
		var originalLimit:Null<String> = null;
		writerSource.originalBytes(repository.id, ScmRef.Head, Bytes.ofString("large.txt"), function(result) {
			originalLimit = result.error == null ? "success" : result.error.code;
		});
		wait(server, scm, connections, writerSource, function() return originalLimit != null,
			"oversized original content returns a bounded protocol error");
		require(originalLimit == "too_large", "oversized original content was not rejected with too_large");
		var beforeStage = writerSource.snapshot(repository.id);
		if (beforeStage == null) throw "Missing writer snapshot before staging";
		var beforeStageRevision = beforeStage.revision;
		sys.io.File.saveContent(root + "/tracked.txt", "workspace staged text\n");
		writerSource.refreshNow(repository.id);
		wait(server, scm, connections, writerSource, function() {
			var snapshot = writerSource.snapshot(repository.id);
			return snapshot != null && Int64.compare(snapshot.revision, beforeStageRevision) > 0;
		}, "write client receives a changed snapshot before staging");
		var stageSnapshot = writerSource.snapshot(repository.id);
		if (stageSnapshot == null) throw "Missing writer snapshot for stage operation";
		var stageResult:Null<String> = null;
		writerSource.apply(repository.id, "rpc-stage-tracked", stageSnapshot.revision, ScmOperation.Stage("tracked.txt"), function(result) {
			stageResult = result.error == null ? "success" : result.error.code;
		});
		wait(server, scm, connections, writerSource, function() return stageResult != null,
			"write-granted RPC source completes a stage operation");
		require(stageResult == "success", "write-granted RPC stage failed: " + Std.string(stageResult));
		var operationSnapshot = writerSource.snapshot(repository.id);
		if (operationSnapshot == null) throw "Missing writer snapshot after staging";
		var operationRevision = operationSnapshot.revision;
		wait(server, scm, connections, writerSource, function() {
			var latest = writerSource.snapshot(repository.id);
			return latest != null && Int64.compare(latest.revision, operationRevision) > 0;
		}, "write client receives the refreshed staged snapshot before its next mutation");

		var writerSnapshot = writerSource.snapshot(repository.id);
		if (writerSnapshot == null) throw "Missing writer SCM snapshot";
		var revision = writerSnapshot.revision;
		var applied = 0, failures:Array<String> = [];
		writerSource.apply(repository.id, "dedupe-create-branch", revision,
			ScmOperation.CreateBranch("scm-dedupe-test"), function(result) {
				if (result.error != null) failures.push(result.error.code + ": " + result.error.message);
				else if (result.value != null) applied++;
			});
		wait(server, scm, connections, writerSource, function() return applied == 1 || failures.length == 1,
			"branch operation resolves", 12, function() return " (applied=" + applied + ", failures=" + failures.join(",") + ")");
		require(applied == 1 && failures.length == 0,
			"a write-granted source could not create a branch: " + failures.join(", "));
		var replayed:Null<String> = null;
		writerSource.apply(repository.id, "dedupe-create-branch", revision,
			ScmOperation.CreateBranch("scm-dedupe-test"), function(result) replayed = result.error == null ? "success" : result.error.code);
		wait(server, scm, connections, writerSource, function() return replayed != null, "completed operation result remains deduplicated");
		require(replayed == "success", "completed operation replay returns the prior result");

		var beforeSnapshot = source.snapshot(repository.id);
		if (beforeSnapshot == null) throw "Missing reader SCM snapshot before reconnect";
		var beforeChange = beforeSnapshot.revision;
		sys.io.File.saveContent(root + "/tracked.txt", "changed while disconnected\n");
		require(Sys.command(gitPath(), ["-C", root, "diff", "--quiet", "--", "tracked.txt"]) != 0,
			"fixture mutation is visible to Git before reconnect");
	readLink.connection.close();
	currentClient = null;
	source.poll();
	server.poll();
	require(scm.refreshNow(repository.id), "workspace SCM refresh accepts the disconnected-reader fixture");
		wait(server, scm, connections, writerSource, function() {
			var snapshot = scm.snapshot(repository.id);
			return snapshot != null && Int64.compare(snapshot.revision, beforeChange) > 0;
		}, "Git snapshot advances while the reader is disconnected", 12, function() {
			var snapshot = scm.snapshot(repository.id);
			return " (priorRevision=" + Int64.toStr(beforeChange) + ", currentRevision="
				+ (snapshot == null ? "none" : Int64.toStr(snapshot.revision)) + ")";
		});
		var replayLink = connect(server, readGrants, false, now);
		connections.push(replayLink.connection);
		currentClient = new WorkspaceScmClient(replayLink.connection);
		source.poll();
		var recovered = false;
		wait(server, scm, connections, source, function() {
			var snapshot = source.snapshot(repository.id);
			recovered = snapshot != null && Int64.compare(snapshot.revision, beforeChange) > 0;
			return recovered;
		}, "RPC SCM source resubscribes and reconciles missed events after reconnect");
		require(changed > 0 && source.connected(), "reconnected source publishes the updated snapshot");

		removeListener();
		source.dispose();
		writerSource.dispose();
		for (connection in connections) connection.close();
		server.dispose();
		scm.dispose();
		processes.shutdown();
	}

	static function cancellation(root:String, trustPath:String):Void {
		// The fake provider has no repository on disk, but a workspace root must still be a directory.
		if (!sys.FileSystem.exists(root)) sys.FileSystem.createDirectory(root);
		var scheduler = new JobScheduler(), fake = new FakeScmProvider(scheduler), normalizedRoot = normalize(root);
		var snapshot = new ScmSnapshot(Int64.ofInt(1), new ScmHead("main", null, false, null, 0, 0, false, ScmHeadOperation.None), []);
		var script = new FakeScmRepositoryScript(new ScmRepository("fake-repository", "fake", normalizedRoot,
			ScmRepositoryKind.Worktree, null, true), new ScmFeatures(true), [snapshot], 0);
		fake.add(script);
		var processes = new ProcessManager(), now = function() return Sys.time() * 1000;
		var workspaces = new WorkspaceService("workspace", "fake-epoch", [{id: "work", name: "Work", cwd: root, revision: 1}]);
		var scm = new WorkspaceScmService("workspace", [root], processes, null, fake, trustPath, scheduler);
		var server = new WorkspaceRpcServer(workspaces, now, null, null, null, null, null, null, scm);
		var grants = [WorkspaceScmProtocol.READ, WorkspaceScmProtocol.WRITE];
		var link = connect(server, grants, false, now), connections = [link.connection];
		var client = new WorkspaceScmClient(link.connection), source = new RpcScmSource(function() return client,
			"workspace", "root", "workspace:fake-cancellation");
		source.poll();
		wait(server, scm, connections, source, function() return source.repositories().length == 1
			&& source.snapshot("fake-repository") != null && scm.watchCountForTest("root") == 1,
			"fake repository and live watch are ready before the cancellable operation");
		var dedupeResults = 0, dedupeErrors:Array<String> = [];
		for (_ in 0...2) source.apply("fake-repository", "dedupe-fake-operation", Int64.ofInt(1),
			ScmOperation.Stage("tracked.txt"), function(result) {
				if (result.error != null) dedupeErrors.push(result.error.code);
				else if (result.value != null) dedupeResults++;
			});
		wait(server, scm, connections, source, function() return dedupeResults == 2 || dedupeErrors.length == 2,
			"duplicate fake-provider operation resolves");
		require(dedupeResults == 2 && dedupeErrors.length == 0 && script.operations.length == 1,
			"duplicate operation id executes the provider once and returns its result to both callers");
		var replayed = false;
		source.apply("fake-repository", "dedupe-fake-operation", Int64.ofInt(1), ScmOperation.Stage("tracked.txt"),
			function(result) replayed = result.error == null && result.value != null);
		wait(server, scm, connections, source, function() return replayed, "fake-provider result remains deduplicated");
		require(script.operations.length == 1, "completed operation replay does not call the provider again");
		script.latencySteps = 100000;
		var operationCompleted = false;
		source.apply("fake-repository", "cancelled-operation", Int64.ofInt(1), ScmOperation.Stage("tracked.txt"),
			function(_) operationCompleted = true);
		wait(server, scm, connections, source, function() return script.operations.length == 2,
			"SCM apply reaches the repository operation queue");
		link.transport.close();
		server.poll();
		require(scm.watchCountForTest("root") == 0, "closing a revoked device removes its SCM watch");
		source.dispose();
		wait(server, scm, connections, null, function() return script.cancelledOperations == 1,
			"transport revocation cancels the in-flight SCM apply");
		require(!operationCompleted, "a cancelled RPC operation does not publish a stale completion");
		server.dispose();
		scm.dispose();
		processes.shutdown();
	}

	static function connect(server:WorkspaceRpcServer, grants:Array<String>, local:Bool, clock:Void->Float):ClientLink {
		var pair = MemoryTransport.pair(1024 * 1024, 64);
		if (local) server.acceptTestLocal(pair.server) else server.acceptRemote(pair.server, grants);
		var options = new RpcPeerOptions("exosuit-agent/1", grants, [], 5000, 262144, 32, 1048576);
		var handshake = RpcHandshake.client(pair.client, clock, options, grants), deadline = Sys.time() + 5;
		while (!handshake.isFinished() && Sys.time() < deadline) {
			server.poll();
			handshake.poll();
		}
		require(handshake.isFinished() && handshake.connection != null, "workspace SCM RPC handshake completes");
		return {connection: handshake.connection, transport: pair.client};
	}

	static function wait(server:WorkspaceRpcServer, scm:WorkspaceScmService, connections:Array<RpcConnection>,
			source:Null<RpcScmSource>, complete:Void->Bool, message:String, timeout:Float = 12,
			diagnostic:Null<Void->String> = null):Void {
		var deadline = Sys.time() + timeout;
		while (!complete() && Sys.time() < deadline) {
			scm.poll();
			server.poll();
			for (connection in connections) if (connection.isOpen()) connection.poll(32, 262144);
			if (source != null) source.poll();
			Sys.sleep(0.001);
		}
		if (!complete()) {
			var detail = "";
			if (source != null) {
				detail = " (connected=" + source.connected() + ", repositories=" + source.repositories().length;
				for (repository in source.repositories()) {
					var snapshot = source.snapshot(repository.id), error = source.error(repository.id);
					detail += ", " + repository.id + ":snapshot=" + (snapshot == null ? "none" : "present")
						+ ",error=" + (error == null ? "none" : error.code);
				}
				detail += ")";
			}
			throw "Workspace SCM test failed: " + message + detail + (diagnostic == null ? "" : diagnostic());
		}
	}

	static function gitPath():String {
		var configured = Sys.getEnv("EXOSUITE_GIT_BIN");
		return configured == null || configured.length == 0 ? "git" : configured;
	}

	static function normalize(path:String):String {
		var value = StringTools.replace(sys.FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function bytes(hex:String):Bytes {
		var result = Bytes.alloc(Std.int(hex.length / 2));
		for (index in 0...result.length) result.set(index, Std.parseInt("0x" + hex.substr(index * 2, 2)));
		return result;
	}
}
