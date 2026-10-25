package scm;

import haxe.Int64;
import haxe.io.Bytes;
import jobs.JobScheduler;
import process.ProcessManager;
import scm.ScmRepositoryHandle;
import scm.ScmProvider;
import scm.git.GitScmProvider;
import sys.FileSystem;

private class ScmRootState {
	public final root:String;
	public var handles:Array<ScmRepositoryHandle> = [];
	public final snapshots:Map<String, ScmSnapshot> = [];
	public final errors:Map<String, ScmError> = [];
	public final refreshJobs:Map<String, ScmJob<ScmSnapshot>> = [];
	public final rerun:Map<String, Bool> = [];
	public final operations:Map<String, Array<ScmOperationRequest>> = [];
	public final operationBusy:Map<String, Bool> = [];
	public var detectJob:Null<ScmJob<Array<ScmRepositoryHandle>>>;
	public var detectGeneration:Int = 0;
	public var changedAt:Null<Float>;
	public var refreshAt:Null<Float>;
	public var lastPoll:Float = 0;
	public var watchAvailable:Bool = false;
	/** Directories host watches leave out (see GitScmRepositoryHandle.watchExclusions); null until known. */
	public var excluded:Null<Array<String>>;
	public var exclusionsJobs:Array<ScmJob<Array<String>>> = [];
	public var exclusionsGeneration:Int = 0;

	public function new(root:String) this.root = root;
}

private class ScmOperationRequest {
	public final repositoryId:String;
	public final operation:ScmOperation;
	public final generation:Int;
	public final complete:ScmJobResult<ScmApplyResult>->Void;
	public var job:Null<ScmJob<ScmApplyResult>>;
	public var child:Null<ScmJob<ScmApplyResult>>;
	public var retryAt:Float = 0;
	public var retries:Int = 0;
	public var finished:Bool = false;

	public function new(repositoryId:String, operation:ScmOperation, generation:Int, complete:ScmJobResult<ScmApplyResult>->Void) {
		this.repositoryId = repositoryId;
		this.operation = operation;
		this.generation = generation;
		this.complete = complete;
	}
}

/** Owns local Git discovery, refresh scheduling, trust and serialized operations. */
class ScmService {
	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final trustStore:ScmTrustStore;
	final providerOverride:Null<ScmProvider>;
	var provider:ScmProvider;
	final roots:Map<String, ScmRootState> = [];
	final listeners:Array<(ScmRepository, ScmSnapshot)->Void> = [];
	final watchPathListeners:Array<(String, Array<String>, Array<String>)->Void> = [];
	var enabled:Bool = true;
	var autoRefresh:Bool = true;
	var pollingInterval:Float = 1.5;
	var gitPath:Null<String>;
	var untrackedLimit:Int;
	var diffSizeLimit:Int;
	var nestedScanDepth:Int;
	var disposed:Bool = false;
	var nextGeneration:Int = 1;

	public function new(processes:ProcessManager, scheduler:JobScheduler, ?gitPath:String,
			untrackedLimit:Int = 10000, nestedScanDepth:Int = 3, autoRefresh:Bool = true,
			?trustStorePath:String, ?emptyHooksPath:String, ?provider:ScmProvider) {
		this.processes = processes;
		this.scheduler = scheduler;
		providerOverride = provider;
		this.autoRefresh = autoRefresh;
		this.gitPath = gitPath;
		this.untrackedLimit = untrackedLimit;
		this.diffSizeLimit = 16 * 1024 * 1024;
		this.nestedScanDepth = nestedScanDepth;
		trustStore = new ScmTrustStore(trustStorePath == null ? config.ConfigurationPaths.stateRoot() + "/scm/trust.json" : trustStorePath);
		this.provider = provider == null
			? new GitScmProvider(processes, scheduler, gitPath, emptyHooksPath, trustStore, untrackedLimit, nestedScanDepth)
			: provider;
	}

	public function configure(settings:config.Settings):Void {
		if (settings == null || disposed) return;
		var providerChanged = gitPath != settings.scmGitPath || untrackedLimit != settings.scmUntrackedLimit
			|| nestedScanDepth != settings.scmNestedScanDepth;
		var wasEnabled = enabled, wasAutoRefresh = autoRefresh;
		gitPath = settings.scmGitPath;
		untrackedLimit = settings.scmUntrackedLimit;
		diffSizeLimit = settings.scmDiffSizeLimit;
		nestedScanDepth = settings.scmNestedScanDepth;
		autoRefresh = settings.scmAutoRefresh;
		if (providerChanged) {
			for (state in roots) cancelState(state);
			if (providerOverride == null)
				provider = new GitScmProvider(processes, scheduler, gitPath, null, trustStore, untrackedLimit, nestedScanDepth);
		}
		enabled = settings.scmEnabled;
		if (!enabled) {
			if (wasEnabled) for (state in roots) {
				cancelJobs(state);
				publishWatchPaths(state);
			}
			return;
		}
		var now = Sys.time();
		for (state in roots) {
			if (autoRefresh && !wasAutoRefresh) state.lastPoll = now;
			publishWatchPaths(state);
			if (providerChanged || state.handles.length == 0) discover(state.root, _ -> {});
			else scheduleRoot(state, now, true);
		}
	}

	public function setEnabled(value:Bool):Void {
		if (enabled == value || disposed) return;
		enabled = value;
		if (enabled) {
			var now = Sys.time();
			for (state in roots) {
				state.lastPoll = now;
				publishWatchPaths(state);
				if (state.handles.length == 0) discover(state.root, _ -> {});
				else scheduleRoot(state, now, true);
			}
		} else {
			for (state in roots) {
				cancelJobs(state);
				publishWatchPaths(state);
			}
		}
	}

	public function setAutoRefresh(value:Bool):Void {
		if (autoRefresh == value || disposed) return;
		autoRefresh = value;
		if (value) {
			var now = Sys.time();
			for (state in roots) state.lastPoll = now;
		}
	}

	public function discover(root:String, complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		if (disposed) return failed([], complete, "service_closed", "Source control service is closed");
		if (!enabled) return failed([], complete, "disabled", "Source control is disabled in settings");
		var normalized:String;
		try normalized = normalize(root) catch (failure:Dynamic) return failed([], complete, "invalid_root", Std.string(failure));
		var state = roots.get(normalized);
		if (state == null) { state = new ScmRootState(normalized); roots.set(normalized, state); }
		if (state.detectJob != null) state.detectJob.cancel();
		state.detectGeneration = nextGeneration++;
		var generation = state.detectGeneration;
		var job = provider.detect(normalized, generation, function(result) {
			if (disposed || state.detectGeneration != generation) {
				if (result.value != null) for (handle in result.value) handle.dispose();
				return;
			}
			state.detectJob = null;
			if (result.error != null || result.value == null) {
				complete(new ScmJobResult<Array<ScmRepository>>(generation, null, result.error));
				return;
			}
			cancelJobs(state);
			for (handle in state.handles) handle.dispose();
			state.handles = result.value;
			state.excluded = null;
			var discovered:Map<String, Bool> = [];
			for (handle in state.handles) discovered.set(handle.repository().id, true);
			for (id in [for (id in state.snapshots.keys()) id])
				if (!discovered.exists(id)) state.snapshots.remove(id);
			state.errors.clear();
			state.lastPoll = Sys.time();
			publishWatchPaths(state);
			scheduleRoot(state, state.lastPoll, true);
			complete(new ScmJobResult<Array<ScmRepository>>(generation, [for (handle in state.handles) handle.repository()]));
		});
		state.detectJob = job;
		return cast job;
	}

	public function repositories(root:String):Array<ScmRepository> {
		var state = stateForPath(root);
		return state == null ? [] : [for (handle in state.handles) handle.repository()];
	}

	public function repository(repositoryId:String):Null<ScmRepository> {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		return handle == null ? null : handle.repository();
	}

	public function features(repositoryId:String):Null<ScmFeatures> {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		return handle == null ? null : handle.features();
	}

	public function branches(repositoryId:String, generation:Int, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		if (!enabled || disposed || handle == null)
			return failedAt(generation, null, complete, !enabled ? "disabled" : "not_found",
				!enabled ? "Source control is disabled" : "Repository is unavailable");
		return handle.branches(generation, complete);
	}

	/** Returns worktree plus Git metadata directories for host file watches. */
	public function watchDirectories(root:String):Array<String> {
		if (!enabled || disposed) return [];
		var normalized:String;
		try normalized = normalize(root) catch (_:Dynamic) return [];
		var state = roots.get(normalized);
		if (state == null) return [];
		var seen:Map<String, Bool> = [], result:Array<String> = [];
		function add(path:String):Void {
			var key = Sys.systemName() == "Windows" ? path.toLowerCase() : path;
			if (!seen.exists(key)) { seen.set(key, true); result.push(path); }
		}
		add(state.root);
		for (handle in state.handles) {
			var gitHandle:scm.git.GitScmRepositoryHandle = Std.isOfType(handle, scm.git.GitScmRepositoryHandle) ? cast handle : null;
			if (gitHandle != null) for (path in gitHandle.watchDirectories()) add(path);
		}
		return result;
	}

	/** Whether a root relies on its host watch rather than polling. */
	public function isWatchAvailable(root:String):Bool {
		var normalized:String;
		try normalized = normalize(root) catch (_:Dynamic) return false;
		var state = roots.get(normalized);
		return state != null && state.watchAvailable;
	}

	/** Directories host watches of a root leave out; empty until they are known. */
	public function watchExclusions(root:String):Array<String> {
		var normalized:String;
		try normalized = normalize(root) catch (_:Dynamic) return [];
		var state = roots.get(normalized);
		return state == null || state.excluded == null ? [] : state.excluded.copy();
	}

	public function snapshot(repositoryId:String):Null<ScmSnapshot> {
		var state = stateForRepository(repositoryId);
		return state == null ? null : state.snapshots.get(repositoryId);
	}

	/** Starts an immediate refresh for a repository already discovered under a root. */
	public function refreshNow(repositoryId:String):Bool {
		var state = stateForRepository(repositoryId);
		if (state == null || disposed || !enabled) return false;
		scheduleRoot(state, Sys.time(), true);
		return true;
	}

	public function originalBytes(repositoryId:String, reference:ScmRef, path:Bytes, generation:Int,
			complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		if (disposed || handle == null)
			return failed(null, complete, disposed ? "service_closed" : "not_found",
				disposed ? "Source control service is closed" : "Repository is unavailable");
		return handle.originalBytes(reference, path, generation, complete);
	}

	public function error(repositoryId:String):Null<ScmError> {
		var state = stateForRepository(repositoryId);
		return state == null ? null : state.errors.get(repositoryId);
	}

	/** Call for worktree or Git-directory watch events; overflow bypasses debounce. */
	public function notifyChanged(root:String, overflow:Bool = false, ?now:Float, ?changedPath:String):Void {
		if (!enabled || disposed) return;
		var state = stateForPath(root);
		if (state == null) return;
		if (overflow) {
			for (handle in state.handles) {
				var gitHandle:scm.git.GitScmRepositoryHandle = Std.isOfType(handle, scm.git.GitScmRepositoryHandle) ? cast handle : null;
				if (gitHandle != null) gitHandle.configurationChanged();
			}
		} else if (changedPath != null) {
			var key = StringTools.replace(changedPath, "\\", "/"), isGitMarker = StringTools.endsWith(key, "/.git");
			var metadataChanged = false;
			for (handle in state.handles) {
				var gitHandle:scm.git.GitScmRepositoryHandle = Std.isOfType(handle, scm.git.GitScmRepositoryHandle) ? cast handle : null;
				if (gitHandle != null && gitHandle.metadataChanged(key)) {
					gitHandle.configurationChanged();
					metadataChanged = true;
				}
			}
			if (isGitMarker || metadataChanged) {
				discover(state.root, _ -> {});
				return;
			}
			for (handle in state.handles) {
				var gitHandle:scm.git.GitScmRepositoryHandle = Std.isOfType(handle, scm.git.GitScmRepositoryHandle) ? cast handle : null;
				if (gitHandle != null && gitHandle.ignoreRulesChanged(key)) {
					state.excluded = null;
					publishWatchPaths(state);
					break;
				}
			}
		}
		scheduleRoot(state, now == null ? Sys.time() : now, overflow);
	}

	/** Lets a native host use polling only when its file-watch backend is unavailable. */
	public function setWatchAvailable(root:String, available:Bool):Void {
		if (disposed) return;
		var normalized:String;
		try normalized = normalize(root) catch (_:Dynamic) return;
		var state = roots.get(normalized);
		if (state == null || state.watchAvailable == available) return;
		state.watchAvailable = available;
		if (!available && enabled && autoRefresh) state.lastPoll = Sys.time() - pollingInterval;
	}

	public function operationCompleted(repositoryId:String):Void notifyRepository(repositoryId, Sys.time(), true);

	/** Refresh after a saved document in any discovered repository. */
	public function documentSaved(path:String):Void notifyPath(path, Sys.time());

	/** Refresh when the host window regains focus. */
	public function windowFocused():Void {
		var now = Sys.time();
		for (state in roots) scheduleRoot(state, now, true);
	}

	public function trust(repositoryId:String):Bool {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		if (handle == null) return false;
		try trustStore.trust(handle.repository().root) catch (_:Dynamic) return false;
		cancelRefresh(cast state, repositoryId);
		scheduleRoot(state, Sys.time(), true);
		publishTrust(cast state, handle);
		return true;
	}

	public function revokeTrust(repositoryId:String):Bool {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		if (handle == null) return false;
		try trustStore.revoke(handle.repository().root) catch (_:Dynamic) return false;
		cancelRefresh(cast state, repositoryId);
		scheduleRoot(state, Sys.time(), true);
		publishTrust(cast state, handle);
		return true;
	}

	/** Trust changes no Git status, so the refresh that follows reports nothing new; tell subscribers now. */
	function publishTrust(state:ScmRootState, handle:ScmRepositoryHandle):Void {
		var repository = handle.repository(), snapshot = state.snapshots.get(repository.id);
		if (snapshot != null) for (listener in listeners.copy()) listener(repository, snapshot);
	}

	public function apply(repositoryId:String, operation:ScmOperation, generation:Int,
			complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		var state = stateForRepository(repositoryId), handle = state == null ? null : findHandle(state, repositoryId);
		if (!enabled || disposed || handle == null)
			return failedAt(generation, null, complete, !enabled ? "disabled" : "not_found", !enabled ? "Source control is disabled" : "Repository is unavailable");
		if (!ScmOperationAvailability.supports(handle.features(), operation))
			return failedAt(generation, null, complete, "unsupported_operation", "This operation is not available for this repository");
		var activeState:ScmRootState = cast state;
		var queue = activeState.operations.get(repositoryId);
		if (queue == null) { queue = []; activeState.operations.set(repositoryId, queue); }
		var request = new ScmOperationRequest(repositoryId, operation, generation, complete);
		var job = new ScmJob<ScmApplyResult>(generation, function() {
			var child = request.child;
			request.child = null;
			if (child != null) {
				child.cancel();
				activeState.operationBusy.set(repositoryId, false);
			}
			if (!request.finished) queue.remove(request);
		});
		request.job = job;
		queue.push(request);
		return job;
	}

	public function subscribe(listener:(ScmRepository, ScmSnapshot)->Void):Void->Void {
		if (listener != null && listeners.indexOf(listener) < 0) listeners.push(listener);
		return function() listeners.remove(listener);
	}

	/** Subscribes a desktop host to watch path changes after discovery/settings updates. */
	/** Calls `listener(root, paths, excluded)` whenever the directories a host should watch for a root change. */
	public function subscribeWatchPaths(listener:(String, Array<String>, Array<String>)->Void):Void->Void {
		if (listener != null && watchPathListeners.indexOf(listener) < 0) watchPathListeners.push(listener);
		return function() watchPathListeners.remove(listener);
	}

	/** Called from Application.update; Git subprocesses remain scheduler jobs. */
	public function update(now:Float):Void {
		if (disposed) return;
		for (state in roots) {
			if (autoRefresh && enabled && !state.watchAvailable && now - state.lastPoll >= pollingInterval) {
				state.lastPoll = now;
				scheduleRoot(state, now, false);
			}
			if (enabled && state.refreshAt != null && now >= state.refreshAt) {
				state.refreshAt = null;
				state.changedAt = null;
				for (handle in state.handles) startRefresh(state, handle);
			}
			for (handle in state.handles) {
				var gitHandle:scm.git.GitScmRepositoryHandle = Std.isOfType(handle, scm.git.GitScmRepositoryHandle) ? cast handle : null;
				if (gitHandle != null) gitHandle.expireBlobReader(now);
			}
			processOperations(state, now);
		}
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (state in roots) cancelState(state);
		roots.clear();
		listeners.resize(0);
		watchPathListeners.resize(0);
	}

	function scheduleRoot(state:ScmRootState, now:Float, immediate:Bool):Void {
		if (immediate) {
			state.changedAt = now;
			state.refreshAt = now;
			return;
		}
		if (state.changedAt == null) state.changedAt = now;
		var proposed = now + 0.3, maximum = state.changedAt + 2.0;
		state.refreshAt = Math.min(proposed, maximum);
		for (id in state.refreshJobs.keys()) state.rerun.set(id, true);
	}

	function startRefresh(state:ScmRootState, handle:ScmRepositoryHandle):Void {
		var repository = handle.repository(), id = repository.id;
		if (state.refreshJobs.exists(id)) { state.rerun.set(id, true); return; }
		var generation = nextGeneration++;
		var callbackRan = false;
		var job = handle.refresh(generation, function(result) {
			callbackRan = true;
			state.refreshJobs.remove(id);
			if (findHandle(state, id) != handle) return;
			if (result.error != null || result.value == null) {
				state.errors.set(id, result.error == null ? new ScmError("operation_failed", "Git refresh returned no snapshot") : result.error);
			} else {
				state.errors.remove(id);
				var previous = state.snapshots.get(id), received = result.value;
				var changed = previous == null || !sameSnapshotContent(previous, received);
				var revision = previous == null ? received.revision
					: changed ? Int64.add(previous.revision, Int64.ofInt(1)) : previous.revision;
				var snapshot = revision == received.revision ? received
					: new ScmSnapshot(revision, received.head, received.groups, received.truncated);
				state.snapshots.set(id, snapshot);
				if (changed)
					for (listener in listeners.copy()) listener(repository, snapshot);
			}
			if (state.rerun.exists(id)) {
				state.rerun.remove(id);
				if (state.refreshAt == null) state.refreshAt = Sys.time();
			}
		});
		if (!callbackRan && !job.complete && !job.cancelled) state.refreshJobs.set(id, job);
	}

	function processOperations(state:ScmRootState, now:Float):Void {
		for (repositoryId in state.operations.keys()) {
			var queue = state.operations.get(repositoryId);
			if (queue == null || queue.length == 0 || state.operationBusy.get(repositoryId) == true) continue;
			var request = queue[0];
			if (request.job == null || request.job.cancelled || request.finished) { queue.shift(); continue; }
			if (request.child != null || now < request.retryAt) continue;
			var handle = findHandle(state, repositoryId);
			if (handle == null) {
				finishOperation(state, queue, request, null, new ScmError("not_found", "Repository is no longer available"));
				continue;
			}
			state.operationBusy.set(repositoryId, true);
			var child = handle.apply(request.operation, request.generation, function(result) {
				state.operationBusy.set(repositoryId, false);
				request.child = null;
				if (request.job == null || request.job.cancelled) { request.finished = true; queue.remove(request); return; }
				if (result.error != null && result.error.code == "lock_contention" && request.retries < 3) {
					var delays = [0.1, 0.3, 0.8];
					request.retryAt = Sys.time() + delays[request.retries++];
					return;
				}
				finishOperation(state, queue, request, result.value, result.error);
				if (result.error == null) notifyRepository(repositoryId, Sys.time(), true);
			});
			if (!request.finished && request.job != null && !request.job.cancelled && !child.complete && !child.cancelled)
				request.child = child;
		}
	}

	function finishOperation(state:ScmRootState, queue:Array<ScmOperationRequest>, request:ScmOperationRequest,
			value:Null<ScmApplyResult>, error:Null<ScmError>):Void {
		request.finished = true;
		queue.remove(request);
		if (request.job != null && request.job.finish())
			request.complete(new ScmJobResult<ScmApplyResult>(request.generation, value, error));
	}

	function notifyRepository(repositoryId:String, now:Float, immediate:Bool):Void {
		var state = stateForRepository(repositoryId);
		if (state != null) scheduleRoot(state, now, immediate);
	}

	function notifyPath(path:String, now:Float):Void {
		var state = stateForPath(path);
		if (state != null) scheduleRoot(state, now, false);
	}

	function stateForRepository(id:String):Null<ScmRootState> {
		for (state in roots) if (findHandle(state, id) != null) return state;
		return null;
	}

	function stateForPath(path:String):Null<ScmRootState> {
		var normalized:String;
		try normalized = normalize(path) catch (_:Dynamic) return null;
		var best:Null<ScmRootState> = null;
		for (state in roots) {
			if (within(state.root, normalized) && (best == null || state.root.length > best.root.length)) best = state;
		}
		return best;
	}

	function findHandle(state:ScmRootState, id:String):Null<ScmRepositoryHandle> {
		for (handle in state.handles) if (handle.repository().id == id) return handle;
		return null;
	}

	function cancelState(state:ScmRootState):Void {
		cancelJobs(state);
		for (handle in state.handles) handle.dispose();
		state.handles.resize(0);
		state.snapshots.clear();
		state.errors.clear();
		publishWatchPaths(state);
	}

	/** Publishes a root's watch directories once its exclusions are known, so a host never walks the trees they leave
		out. Until then the root has no watch and is polled. */
	function publishWatchPaths(state:ScmRootState):Void {
		var paths = watchDirectories(state.root);
		if (paths.length > 0 && state.excluded == null) {
			queryExclusions(state);
			return;
		}
		var excluded = paths.length == 0 || state.excluded == null ? [] : state.excluded;
		for (listener in watchPathListeners.copy()) listener(state.root, paths.copy(), excluded.copy());
	}

	function queryExclusions(state:ScmRootState):Void {
		for (job in state.exclusionsJobs) job.cancel();
		state.exclusionsJobs.resize(0);
		var generation = ++state.exclusionsGeneration;
		var gitHandles = [for (handle in state.handles) if (Std.isOfType(handle, scm.git.GitScmRepositoryHandle)) (cast handle : scm.git.GitScmRepositoryHandle)];
		var pending = gitHandles.length, excluded:Array<String> = [];
		function finish():Void {
			state.exclusionsJobs.resize(0);
			state.excluded = excluded;
			publishWatchPaths(state);
		}
		if (pending == 0) {
			finish();
			return;
		}
		for (handle in gitHandles)
			state.exclusionsJobs.push(handle.watchExclusions(generation, function(result) {
				if (disposed || state.exclusionsGeneration != generation) return;
				if (result.value != null) for (path in result.value) if (excluded.indexOf(path) < 0) excluded.push(path);
				if (--pending == 0) finish();
			}));
	}

	function cancelJobs(state:ScmRootState):Void {
		if (state.detectJob != null) state.detectJob.cancel();
		state.detectJob = null;
		for (job in state.exclusionsJobs) job.cancel();
		state.exclusionsJobs.resize(0);
		state.exclusionsGeneration++;
		for (job in state.refreshJobs) job.cancel();
		for (queue in state.operations) for (request in queue.copy()) if (request.job != null) request.job.cancel();
		state.refreshJobs.clear();
		state.operations.clear();
		state.operationBusy.clear();
		state.rerun.clear();
		state.refreshAt = null;
		state.changedAt = null;
	}

	function cancelRefresh(state:ScmRootState, repositoryId:String):Void {
		var job = state.refreshJobs.get(repositoryId);
		if (job != null) job.cancel();
		state.refreshJobs.remove(repositoryId);
		state.rerun.remove(repositoryId);
	}

	static function within(parent:String, child:String):Bool {
		var prefix = StringTools.endsWith(parent, "/") ? parent : parent + "/";
		var left = key(parent), right = key(child);
		return left == right || StringTools.startsWith(right, key(prefix));
	}

	static function key(path:String):String return Sys.systemName() == "Windows" ? path.toLowerCase() : path;

	static function normalize(path:String):String {
		var value = StringTools.replace(FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	function failed<T>(value:Null<T>, complete:ScmJobResult<T>->Void, code:String, message:String):ScmJob<T> {
		var job = new ScmJob<T>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult<T>(job.generation, value, new ScmError(code, message)));
		return job;
	}

	function failedAt<T>(generation:Int, value:Null<T>, complete:ScmJobResult<T>->Void, code:String, message:String):ScmJob<T> {
		var job = new ScmJob<T>(generation);
		if (job.finish()) complete(new ScmJobResult<T>(generation, value, new ScmError(code, message)));
		return job;
	}

	static function sameSnapshotContent(left:ScmSnapshot, right:ScmSnapshot):Bool {
		if (left.truncated != right.truncated || !sameHead(left.head, right.head) || left.groups.length != right.groups.length)
			return false;
		for (index in 0...left.groups.length) {
			var a = left.groups[index], b = right.groups[index];
			if (a.id != b.id || a.resources.length != b.resources.length) return false;
			for (resourceIndex in 0...a.resources.length) {
				var x = a.resources[resourceIndex], y = b.resources[resourceIndex];
				if (!sameBytes(x.pathBytes, y.pathBytes) || !sameOptionalBytes(x.originalPathBytes, y.originalPathBytes)
					|| x.changeKind != y.changeKind || x.conflictKind != y.conflictKind
					|| x.submoduleStatus != y.submoduleStatus || x.renameScore != y.renameScore)
					return false;
			}
		}
		return true;
	}

	static function sameHead(left:ScmHead, right:ScmHead):Bool {
		return left == right || (left != null && right != null && left.branch == right.branch
			&& left.detachedCommit == right.detachedCommit && left.unborn == right.unborn && left.upstream == right.upstream
			&& left.ahead == right.ahead && left.behind == right.behind && left.upstreamGone == right.upstreamGone
			&& left.operation == right.operation);
	}

	static function sameOptionalBytes(left:Null<Bytes>, right:Null<Bytes>):Bool {
		if (left == null || right == null) return left == right;
		return sameBytes(left, right);
	}

	static function sameBytes(left:Bytes, right:Bytes):Bool return left.compare(right) == 0;
}
