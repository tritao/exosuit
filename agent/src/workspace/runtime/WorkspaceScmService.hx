package workspace.runtime;

import haxe.Int64;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import jobs.JobScheduler;
import process.ProcessManager;
import scm.ScmApplyResult;
import scm.ScmBranch;
import scm.ScmBlob;
import scm.ScmChangeKind;
import scm.ScmConflictKind;
import scm.ScmError;
import scm.ScmFeatures;
import scm.ScmGroup;
import scm.ScmHead;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmSnapshot;
import scm.ScmService;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceScmProtocol.ScmWatchEvent;
import workspace.service.WorkspaceScmProtocol.ScmWatchResult;

private typedef ScmRootStream = {
	var id:String;
	var path:String;
	var epoch:String;
	var sequence:Int;
	var history:Array<ScmWatchEvent>;
	var listeners:Array<ScmWatchEvent->Void>;
}

private class ScmOperationListener {
	public final job:ScmJob<ScmApplyResult>;
	public final complete:ScmJobResult<ScmApplyResult>->Void;

	public function new(job:ScmJob<ScmApplyResult>, complete:ScmJobResult<ScmApplyResult>->Void) {
		this.job = job;
		this.complete = complete;
	}
}

private class ScmOperationRecord {
	public final id:String;
	public final signature:Bytes;
	public final listeners:Array<ScmOperationListener> = [];
	public var work:Null<ScmJob<ScmApplyResult>>;
	public var finished:Bool = false;
	public var result:Null<ScmApplyResult>;
	public var error:Null<ScmError>;

	public function new(id:String, signature:Bytes) {
		this.id = id;
		this.signature = signature;
	}
}

/** Agent-owned adapter for the shared SCM core and its workspace-scoped RPC bindings. */
class WorkspaceScmService {
	static inline final MAX_HISTORY = 128;
	static inline final MAX_OPERATIONS = 512;
	static inline final MAX_OPERATION_ID = 128;

	public final workspace:String;
	final scheduler:JobScheduler;
	final core:ScmService;
	final roots:Array<ScmRootStream> = [];
	final rootsById:Map<String, ScmRootStream> = [];
	final repositoryRoots:Map<String, Array<String>> = [];
	final operations:Map<String, ScmOperationRecord> = [];
	final operationOrder:Array<String> = [];
	final releaseSnapshots:Void->Void;
	var nextGeneration:Int = 1;
	var disposed:Bool = false;

	public function new(workspace:String, rootPaths:Array<String>, processes:ProcessManager, ?gitPath:String,
			?provider:scm.ScmProvider, ?trustStorePath:String, ?jobScheduler:JobScheduler) {
		if (workspace == null || workspace.length == 0 || workspace.length > 128 || rootPaths == null
			|| rootPaths.length == 0 || rootPaths.length > 16 || processes == null)
			throw "Invalid workspace SCM identity";
		this.workspace = workspace;
		scheduler = jobScheduler == null ? new JobScheduler() : jobScheduler;
		core = new ScmService(processes, scheduler, gitPath, 10000, 3, true, trustStorePath, null, provider);
		for (index in 0...rootPaths.length) {
			var path = normalize(rootPaths[index]);
			if (path.length == 0) throw "Invalid workspace SCM root";
			var root:ScmRootStream = {
				id: index == 0 ? "root" : "root-" + index,
				path: path,
				epoch: newEpoch(path),
				sequence: 0,
				history: [],
				listeners: []
			};
			roots.push(root);
			rootsById.set(root.id, root);
		}
		releaseSnapshots = core.subscribe(onSnapshot);
	}

	public function poll():Void {
		if (disposed) return;
		core.update(Sys.time());
		scheduler.update(128, 6.0);
		core.update(Sys.time());
	}

	public function rootPath(rootId:String):Null<String> {
		var root = rootsById.get(rootId);
		return root == null ? null : root.path;
	}

	public function bind(connection:haxeon.rpc.RpcConnection, grants:Array<String>, localOrigin:Bool):Void->Void
		return new WorkspaceScmBinding(this, connection, grants, localOrigin).start();

	public function discover(rootId:String, complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		var root = rootsById.get(rootId);
		if (disposed || root == null)
			return failed([], complete, disposed ? "service_closed" : "invalid_root", "Workspace SCM root is unavailable");
		return core.discover(root.path, function(result) {
			if (result.value != null) {
				unmapRoot(rootId);
				for (repository in result.value) {
					var mapped = repositoryRoots.get(repository.id);
					if (mapped == null) { mapped = []; repositoryRoots.set(repository.id, mapped); }
					if (mapped.indexOf(rootId) < 0) mapped.push(rootId);
				}
			}
			complete(result);
		});
	}

	public function repositories(rootId:String):Array<WorkspaceScmProtocol.WorkspaceScmRepository> {
		var root = rootsById.get(rootId);
		if (disposed || root == null) return [];
		return [for (repository in core.repositories(root.path)) repositoryRecord(repository)];
	}

	public function repository(repositoryId:String):Null<WorkspaceScmProtocol.WorkspaceScmRepository> {
		if (!knownRepository(repositoryId)) return null;
		var repository = core.repository(repositoryId);
		return repository == null ? null : repositoryRecord(repository);
	}

	public function snapshot(repositoryId:String):Null<WorkspaceScmProtocol.WorkspaceScmSnapshot> {
		if (!knownRepository(repositoryId)) return null;
		var snapshot = core.snapshot(repositoryId);
		return snapshot == null ? null : snapshotRecord(snapshot);
	}

	public function branches(repositoryId:String, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		if (disposed) return failed(null, complete, "service_closed", "Workspace SCM is closed");
		if (!knownRepository(repositoryId)) return failed(null, complete, "not_found", "Repository is outside this workspace");
		return core.branches(repositoryId, nextGeneration++, complete);
	}

	public function error(repositoryId:String):Null<WorkspaceScmError> {
		if (!knownRepository(repositoryId)) return null;
		var error = core.error(repositoryId);
		return error == null ? null : errorRecord(error);
	}

	public function refreshNow(repositoryId:String):Bool return knownRepository(repositoryId) && core.refreshNow(repositoryId);

	public function watch(rootId:String, epoch:Null<String>, cursor:Int, listener:ScmWatchEvent->Void):Null<ScmWatchResult> {
		var root = rootsById.get(rootId);
		if (disposed || root == null || listener == null || cursor < 0) return null;
		if (root.listeners.indexOf(listener) < 0) root.listeners.push(listener);
		var floor = root.history.length == 0 ? root.sequence : root.history[0].sequence - 1;
		var reset = epoch != root.epoch || cursor < floor || cursor > root.sequence;
		var replay:Array<ScmWatchEvent> = [];
		if (!reset)
			for (event in root.history)
				if (event.sequence > cursor) replay.push(copyEvent(event));
		return {workspace: workspace, root: rootId, epoch: root.epoch, cursor: root.sequence, reset: reset, events: replay};
	}

	public function unwatch(rootId:String, listener:ScmWatchEvent->Void):Bool {
		var root = rootsById.get(rootId);
		return root != null && listener != null ? root.listeners.remove(listener) : false;
	}

	@:allow(app.WorkspaceScmTestMain)
	function watchCountForTest(rootId:String):Int {
		var root = rootsById.get(rootId);
		return root == null ? 0 : root.listeners.length;
	}

	public function trust(repositoryId:String):Bool return !disposed && knownRepository(repositoryId) && core.trust(repositoryId);

	public function original(repositoryId:String, reference:ScmRef, path:Bytes,
			complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		if (disposed) return failed(null, complete, "service_closed", "Workspace SCM is closed");
		if (!knownRepository(repositoryId)) return failed(null, complete, "not_found", "Repository is outside this workspace");
		return core.originalBytes(repositoryId, reference, path, nextGeneration++, complete);
	}

	public function apply(request:WorkspaceScmProtocol.ScmApplyRequest,
			complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		if (disposed) return failed(null, complete, "service_closed", "Workspace SCM is closed");
		if (request == null || request.operationId == null || request.operationId.length == 0
			|| request.operationId.length > MAX_OPERATION_ID || request.repository == null)
			return failed(null, complete, "invalid_request", "Invalid SCM operation identity");
		if (!knownRepository(request.repository)) return failed(null, complete, "not_found", "Repository is outside this workspace");
		var signature:Bytes;
		try signature = WorkspaceScmProtocol.APPLY.encodeRequest(request) catch (_:Dynamic)
			return failed(null, complete, "invalid_request", "Invalid SCM operation payload");
		var existing = operations.get(request.operationId);
		if (existing != null) {
			if (existing.signature.compare(signature) != 0)
				return failed(null, complete, "operation_conflict", "SCM operation id was reused with different contents");
			return attach(existing, complete);
		}
		var current = core.snapshot(request.repository);
		if (current == null) {
			core.refreshNow(request.repository);
			return failed(null, complete, "pending", "Repository status is still loading", true);
		}
		if (Int64.compare(current.revision, request.expectedRevision) != 0)
			return failed(null, complete, "stale_revision", "Repository changed before the operation started");
		var operation:ScmOperation;
		try operation = decodeOperation(request) catch (failure:Dynamic)
			return failed(null, complete, "invalid_request", Std.string(failure));
		if (!makeRoom()) return failed(null, complete, "operation_limit", "SCM operation history is full");
		var record = new ScmOperationRecord(request.operationId, signature);
		operations.set(record.id, record);
		operationOrder.push(record.id);
		var listenerJob = attach(record, complete);
		record.work = core.apply(request.repository, operation, nextGeneration++, function(result) finish(record, result));
		return listenerJob;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		releaseSnapshots();
		for (record in operations)
			if (record.work != null && !record.finished) record.work.cancel();
		operations.clear();
		operationOrder.resize(0);
		for (root in roots) root.listeners.resize(0);
		core.dispose();
	}

	function attach(record:ScmOperationRecord, complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		var listener:Null<ScmOperationListener> = null;
		var job = new ScmJob<ScmApplyResult>(nextGeneration++, function() {
			if (listener != null) record.listeners.remove(listener);
			if (!record.finished && record.listeners.length == 0) {
				if (record.work != null) record.work.cancel();
				operations.remove(record.id);
				operationOrder.remove(record.id);
			}
		});
		listener = new ScmOperationListener(job, complete);
		if (record.finished) {
			if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(job.generation, record.result, record.error));
		} else record.listeners.push(listener);
		return job;
	}

	function finish(record:ScmOperationRecord, result:ScmJobResult<ScmApplyResult>):Void {
		if (record.finished) return;
		record.finished = true;
		record.result = result.value;
		record.error = result.error;
		for (listener in record.listeners.copy())
			if (listener.job.finish()) listener.complete(new ScmJobResult<ScmApplyResult>(listener.job.generation, result.value, result.error));
		record.listeners.resize(0);
	}

	function makeRoom():Bool {
		while (operationOrder.length >= MAX_OPERATIONS) {
			var removed = false;
			for (id in operationOrder.copy()) {
				var record = operations.get(id);
				if (record != null && record.finished) {
					operationOrder.remove(id);
					operations.remove(id);
					removed = true;
					break;
				}
			}
			if (!removed) return false;
		}
		return true;
	}

	function onSnapshot(repository:ScmRepository, snapshot:ScmSnapshot):Void {
		var rootIds = repositoryRoots.get(repository.id);
		if (rootIds == null || rootIds.length == 0) {
			rootIds = rootIdsForPath(repository.root);
			if (rootIds.length == 0) return;
			repositoryRoots.set(repository.id, rootIds.copy());
		}
		for (rootId in rootIds.copy()) publishSnapshot(rootId, repository, snapshot);
	}

	function publishSnapshot(rootId:String, repository:ScmRepository, snapshot:ScmSnapshot):Void {
		var root = rootsById.get(rootId);
		if (root == null) return;
		if (root.sequence == 0x7fffffff) {
			root.epoch = newEpoch(root.path);
			root.sequence = 0;
			root.history.resize(0);
		}
		root.sequence++;
		var event:ScmWatchEvent = {workspace: workspace, root: rootId, epoch: root.epoch,
			sequence: root.sequence, repository: repository.id, revision: snapshot.revision};
		root.history.push(event);
		if (root.history.length > MAX_HISTORY) root.history.shift();
		for (listener in root.listeners.copy()) listener(copyEvent(event));
	}

	function rootIdsForPath(path:String):Array<String> {
		var normalized = normalize(path), result:Array<String> = [];
		for (root in roots)
			if (within(root.path, normalized) || within(normalized, root.path)) result.push(root.id);
		return result;
	}

	function unmapRoot(rootId:String):Void {
		for (repositoryId in [for (repositoryId in repositoryRoots.keys()) repositoryId]) {
			var mapped = repositoryRoots.get(repositoryId);
			if (mapped == null) continue;
			mapped.remove(rootId);
			if (mapped.length == 0) repositoryRoots.remove(repositoryId);
		}
	}

	function knownRepository(repositoryId:String):Bool {
		return !disposed && repositoryId != null && repositoryRoots.exists(repositoryId)
			&& core.repository(repositoryId) != null;
	}

	function repositoryRecord(value:ScmRepository):WorkspaceScmProtocol.WorkspaceScmRepository {
		var features = core.features(value.id);
		if (features == null) features = new ScmFeatures();
		return {id: value.id, provider: value.providerId, root: value.root, kind: value.kind,
			parentId: value.parentId, trusted: value.trusted, staging: features.staging,
			partialStaging: features.partialStaging, amend: features.amend, branches: features.branches,
			remotes: features.remotes, stash: features.stash};
	}

	static function snapshotRecord(value:ScmSnapshot):WorkspaceScmProtocol.WorkspaceScmSnapshot {
		return workspace.service.WorkspaceScmSnapshotCodec.encode(value);
	}

	static function branchRecord(value:ScmBranch):WorkspaceScmProtocol.WorkspaceScmBranch
		return {reference: value.reference, name: value.name, remote: value.remote, current: value.current};

	public static function errorRecord(value:ScmError):WorkspaceScmProtocol.WorkspaceScmError
		return {code: value.code, message: value.message, retryable: value.retryable};

	public static function applyRecord(workspace:String, repository:String, operationId:String, value:ScmApplyResult):WorkspaceScmProtocol.ScmApplyResult
		return {workspace: workspace, repository: repository, operationId: operationId, message: value.message,
			snapshot: value.snapshot == null ? null : snapshotRecord(value.snapshot), recoveryToken: value.recoveryToken};

	static function decodeOperation(request:WorkspaceScmProtocol.ScmApplyRequest):ScmOperation {
		return switch request.kind {
			case "stage": Stage(required(request.path, "path"));
			case "stage_all": StageAll;
			case "stage_paths": StagePaths(required(request.paths, "paths"));
			case "unstage": Unstage(required(request.path, "path"));
			case "unstage_all": UnstageAll;
			case "unstage_paths": UnstagePaths(required(request.paths, "paths"));
			case "discard": Discard(required(request.path, "path"));
			case "restore_discard": RestoreDiscard(required(request.path, "path"), required(request.recoveryToken, "recovery token"));
			case "resolve_conflict": ResolveConflict(required(request.path, "path"), required(request.choice, "choice"));
			case "commit": Commit(required(request.message, "message"), request.amend == true);
			case "stage_patch": StagePatch(required(request.path, "path"), required(request.patch, "patch"));
			case "unstage_patch": UnstagePatch(required(request.path, "path"), required(request.patch, "patch"));
			case "revert_patch": RevertPatch(required(request.path, "path"), required(request.patch, "patch"));
			case "checkout": Checkout(required(request.reference, "reference"));
			case "create_branch": CreateBranch(required(request.name, "name"));
			case "fetch": Fetch(request.remote);
			case "pull": Pull;
			case "push": Push;
			default: throw "Unknown SCM operation";
		};
	}

	static function required<T>(value:Null<T>, name:String):T {
		if (value == null) throw "SCM operation requires " + name;
		return cast value;
	}

	static function copyEvent(value:ScmWatchEvent):ScmWatchEvent
		return {workspace: value.workspace, root: value.root, epoch: value.epoch, sequence: value.sequence,
			repository: value.repository, revision: value.revision};

	static function normalize(path:String):String {
		if (path == null || path.length == 0) return "";
		var value = StringTools.replace(sys.FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function within(parent:String, child:String):Bool {
		var left = key(parent), right = key(child), prefix = StringTools.endsWith(left, "/") ? left : left + "/";
		return left == right || StringTools.startsWith(right, prefix);
	}

	static function key(path:String):String return Sys.systemName() == "Windows" ? path.toLowerCase() : path;
	static function newEpoch(root:String):String return Sha256.encode(workspaceSeed(root) + ":" + Sys.time() + ":" + Math.random());
	static function workspaceSeed(root:String):String return root + ":workspace-scm";

	function failed<T>(value:Null<T>, complete:ScmJobResult<T>->Void, code:String, message:String, retryable:Bool = false):ScmJob<T> {
		var job = new ScmJob<T>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult<T>(job.generation, value, new ScmError(code, message, retryable)));
		return job;
	}
}

private class WorkspaceScmBinding {
	final service:WorkspaceScmService;
	final connection:haxeon.rpc.RpcConnection;
	final grants:Array<String>;
	final localOrigin:Bool;
	final watchers:Map<String, ScmWatchEvent->Void> = [];
	final activeJobs:Array<Void->Void> = [];
	var closed:Bool = false;

	public function new(service:WorkspaceScmService, connection:haxeon.rpc.RpcConnection, grants:Array<String>, localOrigin:Bool) {
		this.service = service;
		this.connection = connection;
		this.grants = grants == null ? [] : grants.copy();
		this.localOrigin = localOrigin;
	}

	public function start():Void->Void {
		connection.register(WorkspaceScmProtocol.REPOSITORIES, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.root == null || request.root.length == 0 || request.root.length > 128) {
				fail(context, "invalid_request", "Invalid SCM root");
				return;
			}
			var cancel:Void->Void = null;
			var job = service.discover(request.root, function(result) {
				untrack(cancel);
				if (closed || context.isCancelled()) return;
				if (result.error != null || result.value == null) {
					var error = result.error;
					fail(context, error == null ? "operation_failed" : error.code,
						error == null ? "Repository discovery returned no result" : error.message, error != null && error.retryable);
					return;
				}
				if (result.value.length > 2048) {
					fail(context, "too_many_repositories", "Repository list exceeds the response limit");
					return;
				}
				var repositories = service.repositories(request.root);
				context.respond({workspace: service.workspace, root: request.root, repositories: repositories});
			});
			cancel = track(job);
		});

		connection.register(WorkspaceScmProtocol.SNAPSHOT, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.repository == null || request.repository.length == 0 || request.repository.length > 256) {
				fail(context, "invalid_request", "Invalid repository identity");
				return;
			}
			if (service.repository(request.repository) == null) {
				fail(context, "not_found", "Repository is unavailable");
				return;
			}
			var snapshot = service.snapshot(request.repository), error = service.error(request.repository);
			if (snapshot == null && error == null) {
				service.refreshNow(request.repository);
				error = {code: "pending", message: "Repository status is still loading", retryable: true};
			}
			context.respond({workspace: service.workspace, repository: request.repository, snapshot: snapshot, error: error});
		});

		connection.register(WorkspaceScmProtocol.BRANCHES, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.repository == null || request.repository.length == 0 || request.repository.length > 256) {
				fail(context, "invalid_request", "Invalid repository identity");
				return;
			}
			var cancel:Void->Void = null;
			var job = service.branches(request.repository, function(result) {
				untrack(cancel);
				if (closed || context.isCancelled()) return;
				if (result.error != null || result.value == null) {
					var error = result.error;
					fail(context, error == null ? "operation_failed" : error.code,
						error == null ? "Branch listing returned no result" : error.message, error != null && error.retryable);
					return;
				}
				if (result.value.length > 4096) {
					fail(context, "too_many_branches", "Branch list exceeds the response limit");
					return;
				}
				context.respond({workspace: service.workspace, repository: request.repository,
					branches: [for (branch in result.value) WorkspaceScmService.branchRecord(branch)]});
			});
			cancel = track(job);
		});

		connection.register(WorkspaceScmProtocol.WATCH, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.root == null || request.root.length == 0 || request.root.length > 128 || request.cursor < 0) {
				fail(context, "invalid_request", "Invalid SCM watch");
				return;
			}
			unwatch(request.root);
			var listener:ScmWatchEvent->Void = function(event) {
				if (!closed && connection.isOpen()) connection.notify(WorkspaceScmProtocol.CHANGED, event, WorkspaceScmProtocol.encodeEvent);
			};
			var result = service.watch(request.root, request.epoch, request.cursor, listener);
			if (result == null) {
				fail(context, "invalid_request", "Unknown SCM watch root");
				return;
			}
			watchers.set(request.root, listener);
			context.respond(result);
		});

		connection.register(WorkspaceScmProtocol.UNWATCH, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.root == null || request.root.length == 0 || request.root.length > 128) {
				fail(context, "invalid_request", "Invalid SCM watch root");
				return;
			}
			unwatch(request.root);
			context.respond({unwatched: true});
		});

		connection.register(WorkspaceScmProtocol.ORIGINAL, function(request, context) {
			if (!allowRead(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.repository == null || request.repository.length == 0 || request.repository.length > 256
				|| request.path == null || request.path.length > 4096) {
				fail(context, "invalid_request", "Invalid original-content request");
				return;
			}
			var reference:ScmRef;
			try reference = parseReference(request.reference, request.referenceValue) catch (failure:Dynamic) {
				fail(context, "invalid_request", Std.string(failure));
				return;
			}
			var cancel:Void->Void = null;
			var job = service.original(request.repository, reference, request.path, function(result) {
				untrack(cancel);
				if (closed || context.isCancelled()) return;
				if (result.error != null || result.value == null) {
					var error = result.error;
					fail(context, error == null ? "operation_failed" : error.code,
						error == null ? "Original content is unavailable" : error.message, error != null && error.retryable);
					return;
				}
				if (result.value.bytes.length > WorkspaceScmProtocol.ORIGINAL_MAX_BYTES) {
					fail(context, "too_large", "Original content exceeds the RPC response limit");
					return;
				}
				context.respond({workspace: service.workspace, repository: request.repository,
					bytes: result.value.bytes, binary: result.value.binary});
			});
			cancel = track(job);
		});

		connection.register(WorkspaceScmProtocol.APPLY, function(request, context) {
			if (!allowWrite(context) || !checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (request.repository == null || request.repository.length == 0 || request.repository.length > 256) {
				fail(context, "invalid_request", "Invalid repository identity");
				return;
			}
			if (isRemoteOperation(request.kind) && !has(WorkspaceScmProtocol.REMOTE)) {
				fail(context, "unauthorized", "Git remote access denied");
				return;
			}
			var cancel:Void->Void = null;
			var job = service.apply(request, function(result) {
				untrack(cancel);
				if (closed || context.isCancelled()) return;
				if (result.error != null || result.value == null) {
					var error = result.error;
					fail(context, error == null ? "operation_failed" : error.code,
						error == null ? "SCM operation returned no result" : error.message, error != null && error.retryable);
					return;
				}
				context.respond(WorkspaceScmService.applyRecord(service.workspace, request.repository,
					request.operationId, result.value));
			});
			cancel = track(job);
		});

		connection.register(WorkspaceScmProtocol.TRUST, function(request, context) {
			if (!checkWorkspace(request == null ? null : request.workspace, context)) return;
			if (!localOrigin) {
				fail(context, "local_only", "Trust this repository from the machine running Git");
				return;
			}
			if (request.repository == null || request.repository.length == 0 || request.repository.length > 256) {
				fail(context, "invalid_request", "Invalid repository identity");
				return;
			}
			if (!service.trust(request.repository)) {
				fail(context, "not_found", "Repository is unavailable");
				return;
			}
			context.respond({workspace: service.workspace, repository: request.repository, trusted: true});
		});

		return function() cleanup();
	}

	function allowRead<T>(context:haxeon.rpc.RpcContext<T>):Bool {
		if (closed || !connection.isOpen()) return false;
		if (!has(WorkspaceScmProtocol.READ)) {
			fail(context, "unauthorized", "Source control read permission was not granted");
			return false;
		}
		return true;
	}

	function allowWrite<T>(context:haxeon.rpc.RpcContext<T>):Bool {
		if (closed || !connection.isOpen()) return false;
		if (!has(WorkspaceScmProtocol.WRITE)) {
			fail(context, "unauthorized", "Source control write permission was not granted");
			return false;
		}
		return true;
	}

	function checkWorkspace<T>(value:Null<String>, context:haxeon.rpc.RpcContext<T>):Bool {
		if (value == service.workspace) return true;
		fail(context, "invalid_request", "Invalid workspace identity");
		return false;
	}

	function has(capability:String):Bool return grants.indexOf(capability) >= 0;

	function track<T>(job:ScmJob<T>):Void->Void {
		if (job.complete || job.cancelled) return function() {};
		var cancel:Void->Void = null;
		cancel = function() {
			activeJobs.remove(cancel);
			job.cancel();
		};
		activeJobs.push(cancel);
		return cancel;
	}

	function untrack(cancel:Void->Void):Void {
		if (cancel != null) activeJobs.remove(cancel);
	}

	function unwatch(root:String):Void {
		var listener = watchers.get(root);
		if (listener == null) return;
		service.unwatch(root, listener);
		watchers.remove(root);
	}

	function cleanup():Void {
		if (closed) return;
		closed = true;
		for (root in [for (id in watchers.keys()) id]) unwatch(root);
		for (cancel in activeJobs.copy()) cancel();
		activeJobs.resize(0);
	}

	function fail<T>(context:haxeon.rpc.RpcContext<T>, code:String, message:String, retryable:Bool = false):Void
		context.fail({code: code, message: message, ambiguous: retryable});

	static function parseReference(kind:Null<String>, value:Null<String>):ScmRef {
		return switch kind {
			case "head": ScmRef.Head;
			case "index": ScmRef.Index;
			case "commit":
				if (value == null || value.length == 0 || value.length > 128) throw "Commit reference is missing";
				ScmRef.Commit(value);
			case "conflict":
				var stage = value == null ? null : Std.parseInt(value);
				if (stage == null || stage < 1 || stage > 3) throw "Conflict stage must be 1, 2 or 3";
				ScmRef.ConflictStage(stage);
			default: throw "Unknown original-content reference";
		};
	}

	static function isRemoteOperation(kind:Null<String>):Bool return kind == "fetch" || kind == "pull" || kind == "push";
}
