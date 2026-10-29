package scm;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcError;
import workspace.client.WorkspaceScmClient;
import workspace.service.WorkspaceScmProtocol;
import workspace.service.WorkspaceScmProtocol.ScmWatchEvent;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmRepository;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmSnapshot;

private typedef SourceListener = ScmRepository->Null<ScmSnapshot>->Void;

/** Reconnecting, root-scoped SCM view over an authenticated workspace RPC connection. */
class RpcScmSource implements ScmSource implements ScmRemoteReader {
	final clientProvider:Void->Null<WorkspaceScmClient>;
	final workspace:String;
	final root:String;
	final sourceIdentity:String;
	final writeAllowed:Void->Bool;
	final remoteAllowed:Void->Bool;
	final listeners:Array<SourceListener> = [];
	final repositoryValues:Array<ScmRepository> = [];
	final repositoryById:Map<String, ScmRepository> = [];
	final featureValues:Map<String, ScmFeatures> = [];
	final originCapabilities:Map<String, Bool> = [];
	final snapshots:Map<String, ScmSnapshot> = [];
	final errors:Map<String, ScmError> = [];
	final activeJobs:Array<ScmJob<Dynamic>> = [];
	final pendingEvents:Array<ScmWatchEvent> = [];
	final watchListener:ScmWatchEvent->Void;
	var activeClient:Null<WorkspaceScmClient>;
	var watchEpoch:Null<String>;
	var watchCursor:Int = 0;
	var watchPending:Bool = false;
	var watchSubscribed:Bool = false;
	var watchRetryAt:Float = 0;
	var refreshPending:Bool = false;
	var refreshAgain:Bool = false;
	var nextGeneration:Int = 1;
	var disposed:Bool = false;

	public function new(clientProvider:Void->Null<WorkspaceScmClient>, workspace:String, root:String, identity:String,
			?writeAllowed:Void->Bool, ?remoteAllowed:Void->Bool) {
		if (clientProvider == null || workspace == null || workspace.length == 0 || root == null || root.length == 0
			|| identity == null || identity.length == 0)
			throw "Invalid RPC SCM source configuration";
		this.clientProvider = clientProvider;
		this.workspace = workspace;
		this.root = root;
		this.sourceIdentity = identity;
		this.writeAllowed = writeAllowed == null ? function() return false : writeAllowed;
		this.remoteAllowed = remoteAllowed == null ? function() return false : remoteAllowed;
		watchListener = onChanged;
	}

	public function identity():String return sourceIdentity;
	public function isRemote():Bool return true;
	public function connected():Bool return !disposed && activeClient != null && activeClient.connection.isOpen();
	public function canReadOrigin(repositoryId:String):Bool return connected() && originCapabilities.get(repositoryId) == true;
	public function origin(repositoryId:String, complete:ScmJobResult<String>->Void):ScmJob<String> {
		var job = newJob(complete), client = activeClient;
		if (!canReadOrigin(repositoryId) || client == null) {
			finish(job, complete, null, new ScmError("unsupported_operation", "Origin metadata is unavailable")); return job;
		}
		client.origin(workspace, repositoryId, function(result) {
			if (!current(client)) return;
			var canonical = result.origin == null ? null : GithubRemote.repository(result.origin);
			if (result.workspace != workspace || result.repository != repositoryId || canonical == null)
				finish(job, complete, null, new ScmError("invalid_response", "Invalid origin metadata"));
			else finish(job, complete, canonical, null);
		}, function(error) { if (current(client)) finish(job, complete, null, fromRpcError(error)); });
		return job;
	}
	public function repositories():Array<ScmRepository> return disposed ? [] : repositoryValues.copy();
	public function repository(repositoryId:String):Null<ScmRepository> return disposed ? null : repositoryById.get(repositoryId);
	public function features(repositoryId:String):Null<ScmFeatures> return disposed ? null : featureValues.get(repositoryId);
	public function canWrite(repositoryId:String):Bool {
		var repository = this.repository(repositoryId), value = features(repositoryId);
		return connected() && writeAllowed() && repository != null && repository.trusted && value != null && value.staging;
	}
	public function canUseRemotes(repositoryId:String):Bool {
		var repository = this.repository(repositoryId), value = features(repositoryId);
		return connected() && remoteAllowed() && repository != null && repository.trusted && value != null && value.remotes;
	}
	public function snapshot(repositoryId:String):Null<ScmSnapshot> return disposed || !knownRepository(repositoryId) ? null : snapshots.get(repositoryId);
	public function error(repositoryId:String):Null<ScmError> return disposed ? new ScmError("service_closed", "Workspace SCM source is closed")
		: knownRepository(repositoryId) ? errors.get(repositoryId) : new ScmError("not_found", "Repository is outside this workspace root");

	public function discover(complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		var job = newJob(complete);
		var client = activeClient;
		if (client == null || !client.connection.isOpen()) {
			finish(job, complete, null, new ScmError("disconnected", "Workspace SCM is not connected", true));
			return job;
		}
		client.repositories(workspace, root, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.root != root || result.repositories == null || result.repositories.length > 2048) {
				finish(job, complete, null, new ScmError("invalid_response", "Workspace SCM returned an invalid repository list"));
				return;
			}
			updateRepositories(result.repositories);
			fetchSnapshots(client, result.repositories);
			finish(job, complete, repositoryValues.copy(), null);
		}, function(failure) {
			if (current(client)) finish(job, complete, null, fromRpcError(failure));
		});
		return job;
	}

	public function refreshNow(repositoryId:String):Bool {
		var client = activeClient;
		if (client == null || !client.connection.isOpen() || !knownRepository(repositoryId)) return false;
		fetchSnapshot(client, repositoryId);
		return true;
	}

	public function branches(repositoryId:String, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		var job = newJob(complete), client = activeClient;
		if (!knownRepository(repositoryId)) {
			finish(job, complete, null, new ScmError("not_found", "Repository is outside this workspace root"));
			return job;
		}
		if (client == null || !client.connection.isOpen()) {
			finish(job, complete, null, new ScmError("disconnected", "Workspace SCM is not connected", true));
			return job;
		}
		client.branches({workspace: workspace, repository: repositoryId}, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.repository != repositoryId) {
				finish(job, complete, null, new ScmError("invalid_response", "Workspace SCM returned unrelated branch data"));
				return;
			}
			if (result.error != null || result.branches == null || result.branches.length > 4096) {
				finish(job, complete, null, result.error == null
					? new ScmError("invalid_response", "Workspace SCM returned an invalid branch list") : decodeError(result.error));
				return;
			}
			var branches:Array<ScmBranch> = [];
			for (branch in result.branches) {
				if (branch == null || branch.reference == null || branch.name == null || branch.reference.length == 0
					|| branch.name.length == 0 || branch.reference.length > 4096 || branch.name.length > 1024) {
					finish(job, complete, null, new ScmError("invalid_response", "Workspace SCM returned an invalid branch entry"));
					return;
				}
				branches.push(new ScmBranch(branch.reference, branch.name, branch.remote, branch.current));
			}
			finish(job, complete, branches, null);
		}, function(failure) {
			if (current(client)) finish(job, complete, null, fromRpcError(failure));
		});
		return job;
	}

	public function originalBytes(repositoryId:String, reference:ScmRef, path:Bytes,
			complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		var job = newJob(complete), client = activeClient;
		if (!knownRepository(repositoryId)) {
			finish(job, complete, null, new ScmError("not_found", "Repository is outside this workspace root"));
			return job;
		}
		if (client == null || !client.connection.isOpen()) {
			finish(job, complete, null, new ScmError("disconnected", "Workspace SCM is not connected", true));
			return job;
		}
		var referenceValue:Null<String>, referenceName:String;
		switch reference {
			case Head: referenceName = "head"; referenceValue = null;
			case Index: referenceName = "index"; referenceValue = null;
			case Commit(oid): referenceName = "commit"; referenceValue = oid;
			case ConflictStage(stage): referenceName = "conflict"; referenceValue = Std.string(stage);
		}
		client.original({workspace: workspace, repository: repositoryId, reference: referenceName,
			referenceValue: referenceValue, path: path}, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.repository != repositoryId || result.bytes == null) {
				finish(job, complete, null, new ScmError("invalid_response", "Workspace SCM returned invalid original content"));
				return;
			}
			finish(job, complete, new ScmBlob(result.bytes, result.binary == true), null);
		}, function(failure) {
			if (current(client)) finish(job, complete, null, fromRpcError(failure));
		});
		return job;
	}

	public function apply(repositoryId:String, operationId:String, expectedRevision:Int64, operation:ScmOperation,
			complete:ScmApplyCompletion):ScmJob<scm.ScmApplyResult> {
		if (complete == null) throw "SCM callback cannot be null";
		var job:ScmJob<scm.ScmApplyResult> = null;
		job = new ScmJob<scm.ScmApplyResult>(nextGeneration++, function() activeJobs.remove(cast job));
		activeJobs.push(cast job);
		if (!knownRepository(repositoryId)) {
			finish(job, complete, null, new ScmError("not_found", "Repository is outside this workspace root"));
			return job;
		}
		var client = activeClient;
		if (client == null || !client.connection.isOpen()) {
			finish(job, complete, null, new ScmError("disconnected", "Workspace SCM is not connected", true));
			return job;
		}
		if (operationId == null || operationId.length == 0 || operationId.length > 128) {
			finish(job, complete, null, new ScmError("invalid_request", "Invalid SCM operation id"));
			return job;
		}
		var request:WorkspaceScmProtocol.ScmApplyRequest;
		try request = encodeOperation(workspace, repositoryId, operationId, expectedRevision, operation) catch (failure:Dynamic) {
			finish(job, complete, null, new ScmError("invalid_request", Std.string(failure)));
			return job;
		}
		client.apply(request, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.repository != repositoryId || result.operationId != operationId) {
				finish(job, complete, null, new ScmError("invalid_response", "Workspace SCM returned an unrelated operation result"));
				return;
			}
			var snapshot = result.snapshot == null ? null : decodeSnapshot(result.snapshot);
			if (snapshot != null) putSnapshot(repositoryId, snapshot);
			finish(job, complete, new scm.ScmApplyResult(snapshot, result.message, result.recoveryToken), null);
		}, function(failure) {
			if (current(client)) finish(job, complete, null, fromRpcError(failure));
		});
		return job;
	}

	public function trust(repositoryId:String, complete:ScmJobResult<Bool>->Void):ScmJob<Bool> {
		var job = newJob(complete), client = activeClient;
		if (!knownRepository(repositoryId)) {
			finish(job, complete, false, new ScmError("not_found", "Repository is outside this workspace root"));
			return job;
		}
		if (client == null || !client.connection.isOpen()) {
			finish(job, complete, false, new ScmError("disconnected", "Workspace SCM is not connected", true));
			return job;
		}
		client.trust(workspace, repositoryId, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.repository != repositoryId || !result.trusted) {
				finish(job, complete, false, new ScmError("invalid_response", "Workspace SCM returned an invalid trust result"));
				return;
			}
			var repository = repositoryById.get(repositoryId);
			if (repository != null) {
				var trusted = new ScmRepository(repository.id, repository.providerId, repository.root,
					repository.kind, repository.parentId, true);
				putRepository(trusted, featureValues.get(repositoryId));
			}
			finish(job, complete, true, null);
		}, function(failure) {
			if (current(client)) finish(job, complete, false, fromRpcError(failure));
		});
		return job;
	}

	public function subscribe(listener:SourceListener):Void->Void {
		if (disposed || listener == null) return function() {};
		if (listeners.indexOf(listener) < 0) listeners.push(listener);
		return function() listeners.remove(listener);
	}

	/** Detect the authenticated connection identity, restore the watch, then refresh snapshots. */
	public function poll():Void {
		if (disposed) return;
		var next = clientProvider();
		if (next != activeClient) {
			if (activeClient != null) activeClient.unwatch(workspace, root, watchListener);
			retireJobs();
			refreshPending = false;
			refreshAgain = false;
			activeClient = next;
			watchPending = false;
			watchSubscribed = false;
			pendingEvents.resize(0);
			if (next == null || !next.connection.isOpen()) {
				activeClient = null;
				notifyCached();
				return;
			}
			watchRetryAt = 0;
			subscribeWatch(next);
			refreshRepositoryList(next);
			return;
		}
		if (next != null && next.connection.isOpen() && !watchPending && !watchSubscribed && Sys.time() >= watchRetryAt)
			subscribeWatch(next);
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		if (activeClient != null) activeClient.unwatch(workspace, root, watchListener);
		activeClient = null;
		watchPending = false;
		watchSubscribed = false;
		retireJobs();
		listeners.resize(0);
		pendingEvents.resize(0);
	}

	function subscribeWatch(client:WorkspaceScmClient):Void {
		if (!current(client) || watchPending) return;
		watchPending = true;
		watchSubscribed = false;
		client.watch(workspace, root, watchEpoch, watchCursor, watchListener, function(result) {
			if (!current(client)) return;
			watchPending = false;
			if (result.workspace != workspace || result.root != root || result.epoch == null || result.events == null) {
				watchRetryAt = Sys.time() + 1.0;
				return;
			}
			watchSubscribed = true;
			watchRetryAt = 0;
			var reset = result.reset || watchEpoch != result.epoch;
			watchEpoch = result.epoch;
			watchCursor = result.cursor;
			if (reset) clearCached();
			refreshRepositoryList(client);
			pendingEvents.resize(0);
		}, function(_) {
			if (!current(client)) return;
			watchPending = false;
			watchSubscribed = false;
			watchRetryAt = Sys.time() + 1.0;
		});
	}

	function onChanged(event:ScmWatchEvent):Void {
		if (!current(activeClient) || event.workspace != workspace || event.root != root || event.epoch == null || event.sequence <= 0) return;
		if (watchPending) {
			pendingEvents.push(event);
			if (pendingEvents.length > 256) pendingEvents.shift();
			return;
		}
		if (watchEpoch != event.epoch || event.sequence != watchCursor + 1) {
			subscribeWatch(activeClient);
			refreshRepositoryList(activeClient);
			return;
		}
		watchCursor = event.sequence;
		if (!repositoryById.exists(event.repository)) refreshRepositoryList(activeClient);
		else fetchSnapshot(activeClient, event.repository);
	}

	function refreshRepositoryList(client:WorkspaceScmClient):Void {
		if (!current(client)) return;
		if (refreshPending) { refreshAgain = true; return; }
		refreshPending = true;
		client.repositories(workspace, root, function(result) {
			if (!current(client)) return;
			refreshPending = false;
			if (result.workspace != workspace || result.root != root || result.repositories == null || result.repositories.length > 2048) {
				watchRetryAt = Sys.time() + 1.0;
				return;
			}
			updateRepositories(result.repositories);
			fetchSnapshots(client, result.repositories);
			if (refreshAgain) { refreshAgain = false; refreshRepositoryList(client); }
		}, function(_) {
			if (!current(client)) return;
			refreshPending = false;
			watchRetryAt = Sys.time() + 1.0;
			if (refreshAgain) { refreshAgain = false; refreshRepositoryList(client); }
		});
	}

	function fetchSnapshots(client:WorkspaceScmClient, repositories:Array<WorkspaceScmRepository>):Void
		for (repository in repositories) fetchSnapshot(client, repository.id);

	function fetchSnapshot(client:WorkspaceScmClient, repositoryId:String):Void {
		if (!current(client) || repositoryId == null || !repositoryById.exists(repositoryId)) return;
		client.snapshot(workspace, repositoryId, function(result) {
			if (!current(client)) return;
			if (result.workspace != workspace || result.repository != repositoryId) {
				errors.set(repositoryId, new ScmError("invalid_response", "Workspace SCM returned an unrelated snapshot"));
				return;
			}
			if (result.snapshot != null) {
				putSnapshot(repositoryId, decodeSnapshot(result.snapshot));
				if (result.error != null) errors.set(repositoryId, decodeError(result.error));
				else errors.remove(repositoryId);
			} else {
				snapshots.remove(repositoryId);
				if (result.error != null) errors.set(repositoryId, decodeError(result.error));
				var repository = repositoryById.get(repositoryId);
				if (repository != null) notifyListeners(repository, null);
			}
		}, function(failure) {
			if (!current(client)) return;
			errors.set(repositoryId, fromRpcError(failure));
			var repository = repositoryById.get(repositoryId);
			if (repository != null) notifyListeners(repository, snapshots.get(repositoryId));
		});
	}

	function updateRepositories(values:Array<WorkspaceScmRepository>):Void {
		var prior = repositoryById.copy(), seen:Map<String, Bool> = [];
		repositoryValues.resize(0);
		repositoryById.clear();
		featureValues.clear();
		originCapabilities.clear();
		for (record in values) {
			if (record == null || record.id == null || record.id.length == 0 || seen.exists(record.id)) continue;
			seen.set(record.id, true);
			var repository = decodeRepository(record);
			putRepository(repository, decodeFeatures(record));
			originCapabilities.set(repository.id, record.originRead == true);
		}
		for (id in [for (id in prior.keys()) id])
			if (!seen.exists(id)) {
				var removed = prior.get(id);
				snapshots.remove(id);
				errors.remove(id);
				if (removed != null) notifyListeners(removed, null);
			}
	}

	function putRepository(repository:ScmRepository, features:Null<ScmFeatures>):Void {
		var prior = repositoryById.get(repository.id);
		if (prior == null) repositoryValues.push(repository);
		else {
			var index = repositoryValues.indexOf(prior);
			if (index >= 0) repositoryValues[index] = repository;
		}
		repositoryById.set(repository.id, repository);
		if (features != null) featureValues.set(repository.id, features);
		else featureValues.remove(repository.id);
	}

	function putSnapshot(repositoryId:String, snapshot:ScmSnapshot):Void {
		var prior = snapshots.get(repositoryId);
		snapshots.set(repositoryId, snapshot);
		errors.remove(repositoryId);
		if (prior == null || Int64.compare(prior.revision, snapshot.revision) != 0) {
			var repository = repositoryById.get(repositoryId);
			if (repository != null) notifyListeners(repository, snapshot);
		}
	}

	function clearCached():Void {
		var prior = [for (repository in repositoryValues) repository];
		snapshots.clear();
		errors.clear();
		for (repository in prior) notifyListeners(repository, null);
	}

	function notifyCached():Void
		for (repository in repositoryValues) notifyListeners(repository, snapshots.get(repository.id));

	function notifyListeners(repository:ScmRepository, snapshot:Null<ScmSnapshot>):Void
		for (listener in listeners.copy()) listener(repository, snapshot);

	function newJob<T>(complete:ScmJobResult<T>->Void):ScmJob<T> {
		if (complete == null) throw "SCM callback cannot be null";
		var job:ScmJob<T> = null;
		job = new ScmJob<T>(nextGeneration++, function() activeJobs.remove(cast job));
		activeJobs.push(cast job);
		return job;
	}

	function finish<T>(job:ScmJob<T>, complete:ScmJobResult<T>->Void, value:Null<T>, error:Null<ScmError>):Void {
		activeJobs.remove(cast job);
		if (!disposed && job.finish()) complete(new ScmJobResult<T>(job.generation, value, error));
	}

	function retireJobs():Void {
		for (job in activeJobs.copy()) job.cancel();
		activeJobs.resize(0);
	}

	function current(client:Null<WorkspaceScmClient>):Bool
		return !disposed && client != null && activeClient == client && client.connection.isOpen();

	function knownRepository(repositoryId:String):Bool return !disposed && repositoryId != null && repositoryById.exists(repositoryId);

	public static function encodeOperation(workspace:String, repository:String, operationId:String, revision:Int64,
			operation:ScmOperation):WorkspaceScmProtocol.ScmApplyRequest {
		var request:WorkspaceScmProtocol.ScmApplyRequest = {
			workspace: workspace, repository: repository, operationId: operationId, expectedRevision: revision,
			kind: "", path: null, message: null, amend: null, patch: null, reference: null, remote: null, name: null, paths: null,
			recoveryToken: null, choice: null, folders: null
		};
		switch operation {
			case Stage(path): request.kind = "stage"; request.path = path;
			case StageAll: request.kind = "stage_all";
			case StagePaths(paths): request.kind = "stage_paths"; request.paths = paths;
			case Unstage(path): request.kind = "unstage"; request.path = path;
			case UnstageAll: request.kind = "unstage_all";
			case UnstagePaths(paths): request.kind = "unstage_paths"; request.paths = paths;
			case Discard(path): request.kind = "discard"; request.path = path;
			case RestoreDiscard(path, recoveryToken): request.kind = "restore_discard"; request.path = path; request.recoveryToken = recoveryToken;
			case ResolveConflict(path, choice): request.kind = "resolve_conflict"; request.path = path; request.choice = choice;
			case Commit(message, amend): request.kind = "commit"; request.message = message; request.amend = amend;
			case ScopedCommit(message, amend, folders):
				request.kind = "scoped_commit"; request.message = message; request.amend = amend; request.folders = folders.copy();
			case StagePatch(path, patch): request.kind = "stage_patch"; request.path = path; request.patch = patch;
			case UnstagePatch(path, patch): request.kind = "unstage_patch"; request.path = path; request.patch = patch;
			case RevertPatch(path, patch): request.kind = "revert_patch"; request.path = path; request.patch = patch;
			case Checkout(reference): request.kind = "checkout"; request.reference = reference;
			case CreateBranch(name): request.kind = "create_branch"; request.name = name;
			case CreateWorktree(directory, branch): request.kind = "create_worktree"; request.path = directory; request.name = branch;
			case Fetch(remote): request.kind = "fetch"; request.remote = remote;
			case Pull: request.kind = "pull";
			case Push: request.kind = "push";
		}
		return request;
	}

	static function decodeRepository(value:WorkspaceScmRepository):ScmRepository {
		var kind:ScmRepositoryKind = switch value.kind {
			case "linked-worktree": ScmRepositoryKind.LinkedWorktree;
			case "submodule": ScmRepositoryKind.Submodule;
			case "nested": ScmRepositoryKind.Nested;
			default: ScmRepositoryKind.Worktree;
		};
		return new ScmRepository(value.id, value.provider, value.root, kind, value.parentId, value.trusted);
	}

	static function decodeFeatures(value:WorkspaceScmRepository):ScmFeatures
		return new ScmFeatures(value.staging, value.partialStaging, value.amend, value.branches, value.remotes, value.stash, value.worktrees == true);

	static function decodeSnapshot(value:WorkspaceScmSnapshot):ScmSnapshot
		return workspace.service.WorkspaceScmSnapshotCodec.decode(value);

	static function decodeError(value:WorkspaceScmProtocol.WorkspaceScmError):ScmError
		return new ScmError(value.code, value.message, value.retryable);

	static function fromRpcError(value:RpcError):ScmError
		return new ScmError(value.code == null ? "operation_failed" : value.code,
			value.message == null ? "Workspace SCM request failed" : value.message, value.ambiguous);
}
