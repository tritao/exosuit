package scm;

import haxe.Int64;
import haxe.io.Bytes;
import workspace.PathKey;

/** Root-scoped view of the desktop's in-process SCM service. */
class LocalScmSource implements ScmSource implements ScmRemoteReader {
	final service:ScmService;
	final root:String;
	final roots:Array<String>;
	final sourceIdentity:String;
	final subscriptions:Array<Void->Void> = [];
	/** Scope decisions per repository root; resolving paths costs file-system calls and the app asks on every poll. */
	final scopes:Map<String, Bool> = [];
	var scopeEpoch:Int = 0;
	/**
		Whether a root inside a repository limits that repository to the root's folder: its snapshot shows only the folder's
		changes, and staging, discarding and committing act only inside it.
	**/
	final narrowToFolders:Bool;
	/** The last folder-narrowed snapshot per repository, with the full snapshot it came from. */
	final narrowedSnapshots:Map<String, {var source:ScmSnapshot; var result:ScmSnapshot;}> = [];
	var nextGeneration:Int = 1;
	var disposed:Bool = false;

	public function new(service:ScmService, root:String, ?roots:Array<String>, narrowToFolders:Bool = false) {
		if (service == null || root == null || root.length == 0)
			throw "Local SCM source requires a service and root";
		this.service = service;
		this.root = normalize(root);
		this.roots = roots == null ? [this.root] : [for (path in roots) normalize(path)];
		this.narrowToFolders = narrowToFolders;
		this.sourceIdentity = identityFor(this.roots, narrowToFolders);
	}
	public static function identityFor(roots:Array<String>, narrowToFolders:Bool = false):String
		return "local:" + [for (root in roots) PathKey.of(normalize(root))].join("|") + (narrowToFolders ? "|narrow" : "");

	public function identity():String return sourceIdentity;
	public function isRemote():Bool return false;
	public function connected():Bool return !disposed;
	public function canReadOrigin(repositoryId:String):Bool {
		var repository = scopedRepository(repositoryId);
		return repository != null && repository.providerId == "git";
	}
	public function origin(repositoryId:String, complete:ScmJobResult<String>->Void):ScmJob<String> {
		if (scopedRepository(repositoryId) == null) return failed(null, complete, "not_found", "Repository is outside this workspace root");
		return service.origin(repositoryId, nextGeneration++, complete);
	}
	public function repositories():Array<ScmRepository> {
		var result:Array<ScmRepository> = [], seen:Map<String, Bool> = [];
		if (!disposed) for (root in roots) for (repository in service.repositories(root))
			if (inScope(repository.root) && !seen.exists(repository.id)) { seen.set(repository.id, true); result.push(repository); }
		return result;
	}
	public function repository(repositoryId:String):Null<ScmRepository> return scopedRepository(repositoryId);
	public function features(repositoryId:String):Null<ScmFeatures> {
		var repository = scopedRepository(repositoryId), value = repository == null ? null : service.features(repositoryId);
		if (value == null || repository == null || !value.worktrees) return value;
		var allowed = false;
		for (scope in roots) if (within(scope, repository.root)) allowed = true;
		return new ScmFeatures(value.staging, value.partialStaging, value.amend, value.branches, value.remotes, value.stash, allowed);
	}
	public function branches(repositoryId:String, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		if (disposed) return failed(null, complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM branch callback cannot be null";
		if (scopedRepository(repositoryId) == null) return failed(null, complete, "not_found", "Repository is outside this workspace root");
		return service.branches(repositoryId, nextGeneration++, complete);
	}
	public function canWrite(repositoryId:String):Bool {
		var repository = scopedRepository(repositoryId), value = repository == null ? null : service.features(repositoryId);
		return !disposed && repository != null && repository.trusted && value != null && value.staging;
	}
	public function canUseRemotes(repositoryId:String):Bool {
		var repository = scopedRepository(repositoryId), value = repository == null ? null : service.features(repositoryId);
		return !disposed && repository != null && repository.trusted && value != null && value.remotes;
	}
	public function snapshot(repositoryId:String):Null<ScmSnapshot> {
		var repository = scopedRepository(repositoryId);
		return repository == null ? null : narrowedSnapshot(repository, service.snapshot(repositoryId));
	}
	public function error(repositoryId:String):Null<ScmError> return disposed ? new ScmError("service_closed", "Source control source is closed")
		: scopedRepository(repositoryId) == null ? new ScmError("not_found", "Repository is outside this workspace root") : service.error(repositoryId);

	public function discover(complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		if (disposed) return failed([], complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM discovery callback cannot be null";
		var children:Array<ScmJob<Array<ScmRepository>>> = [];
		var job = new ScmJob<Array<ScmRepository>>(nextGeneration++, function() { for (child in children) child.cancel(); });
		var remaining = roots.length, failure:Null<ScmError> = null;
		for (scope in roots) children.push(service.discover(scope, function(result) {
			if (result.error != null) failure = result.error;
			remaining--;
			if (remaining == 0 && job.finish()) complete(new ScmJobResult(job.generation, repositories(), failure));
		}));
		if (remaining == 0 && job.finish()) complete(new ScmJobResult(job.generation, repositories(), failure));
		return job;
	}

	public function refreshNow(repositoryId:String):Bool return !disposed && scopedRepository(repositoryId) != null && service.refreshNow(repositoryId);

	public function originalBytes(repositoryId:String, reference:ScmRef, path:Bytes,
			complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		if (disposed) return failed(null, complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM original-content callback cannot be null";
		if (scopedRepository(repositoryId) == null) return failed(null, complete, "not_found", "Repository is outside this workspace root");
		return service.originalBytes(repositoryId, reference, path, nextGeneration++, complete);
	}

	public function apply(repositoryId:String, operationId:String, expectedRevision:Int64, operation:ScmOperation,
			complete:ScmApplyCompletion):ScmJob<ScmApplyResult> {
		if (disposed) return failed(null, complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM operation callback cannot be null";
		var repository = scopedRepository(repositoryId);
		if (repository == null) return failed(null, complete, "not_found", "Repository is outside this workspace root");
		switch operation {
			case CreateWorktree(_, _):
				var available = features(repositoryId);
				if (available == null || !available.worktrees) return failed(null, complete, "invalid_directory", "Worktrees must be created inside the workspace");
			case _:
		}
		var current = service.snapshot(repositoryId);
		if (current == null || Int64.compare(current.revision, expectedRevision) != 0)
			return failed(null, complete, "stale_revision", "Repository changed before the operation started");
		var folders = narrowToFolders ? prefixes(repository) : null;
		if (folders != null) switch narrowOperation(operation, folders, current, repository.ignoreCase) {
			case Allowed(allowed): operation = allowed;
			case Refused(reason): return failed(null, complete, "outside_folder", reason);
		}
		return service.apply(repositoryId, operation, nextGeneration++, complete);
	}

	public function trust(repositoryId:String, complete:ScmJobResult<Bool>->Void):ScmJob<Bool> {
		if (disposed) return failed(false, complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM trust callback cannot be null";
		var job = new ScmJob<Bool>(nextGeneration++);
		var trusted = scopedRepository(repositoryId) != null && service.trust(repositoryId);
		if (job.finish()) complete(new ScmJobResult<Bool>(job.generation, trusted,
			trusted ? null : new ScmError("not_found", "Repository is unavailable")));
		return job;
	}

	public function subscribe(listener:(ScmRepository, Null<ScmSnapshot>)->Void):Void->Void {
		if (disposed || listener == null) return function() {};
		var cancel = service.subscribe(function(repository, snapshot) {
			if (!disposed && inScope(repository.root)) listener(repository, narrowedSnapshot(repository, snapshot));
		});
		subscriptions.push(cancel);
		return function() {
			if (subscriptions.remove(cancel)) cancel();
		};
	}

	public function poll():Void {}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (cancel in subscriptions.copy()) cancel();
		subscriptions.resize(0);
	}

	function scopedRepository(repositoryId:String):Null<ScmRepository> {
		if (disposed || repositoryId == null) return null;
		var repository = service.repository(repositoryId);
		return repository != null && inScope(repository.root) ? repository : null;
	}

	function inScope(repositoryRoot:String):Bool {
		if (scopeEpoch != service.discoveryEpoch) { scopes.clear(); scopeEpoch = service.discoveryEpoch; }
		var known = scopes.get(repositoryRoot);
		if (known != null) return known;
		var value = false;
		for (root in roots) if (within(root, repositoryRoot) || within(repositoryRoot, root)) { value = true; break; }
		scopes.set(repositoryRoot, value);
		return value;
	}

	/** The repository-relative folders this source narrows a repository to; null shows the whole repository. */
	function prefixes(repository:ScmRepository):Null<Array<String>> {
		var result:Array<String> = [], repositoryRoot = normalize(repository.root);
		for (root in roots) {
			var folder = PathKey.relative(repositoryRoot, root);
			if (folder == null) continue;
			if (folder == "") return null;
			result.push(folder + "/");
		}
		return result.length == 0 ? null : result;
	}

	function narrowedSnapshot(repository:ScmRepository, snapshot:Null<ScmSnapshot>):Null<ScmSnapshot> {
		if (!narrowToFolders || snapshot == null) return snapshot;
		var cached = narrowedSnapshots.get(repository.id);
		if (cached != null && cached.source == snapshot) return cached.result;
		var folders = prefixes(repository);
		var result = folders == null ? snapshot : narrowSnapshot(snapshot, folders, repository.ignoreCase);
		narrowedSnapshots.set(repository.id, {source: snapshot, result: result});
		return result;
	}

	/**
		Keeps the changes under any of the repository-relative folders (each ending in `/`); empty groups are dropped.
		`ignoreCase` is the repository's (see ScmRepository.ignoreCase).
	**/
	public static function narrowSnapshot(snapshot:ScmSnapshot, folders:Array<String>, ?ignoreCase:Bool):ScmSnapshot {
		var groups:Array<ScmGroup> = [];
		for (group in snapshot.groups) {
			var kept = [for (resource in group.resources)
				if (ScmFolderScope.inside(resource.path, folders, ignoreCase) || ScmFolderScope.inside(resource.originalPath, folders, ignoreCase)) resource];
			if (kept.length > 0) groups.push(new ScmGroup(group.id, kept, false));
		}
		return new ScmSnapshot(snapshot.revision, snapshot.head, groups, snapshot.truncated);
	}

	/**
		An operation limited to the repository-relative folders (each ending in `/`), checked against the repository's full
		snapshot. Paths outside them are refused, and so is any path that is not plain (a `..` or `.` segment, a leading
		separator or `:`, a drive letter), since it could name a file outside the folder it starts with. Stage-all and
		unstage-all become the folders themselves. A commit takes the whole index, so it is refused while changes outside
		the folders are staged, and goes to the provider as a ScopedCommit, which checks the exact tree it commits (see
		GitScopedCommit). A ScopedCommit asked for here keeps only the folders inside these, so a request can narrow the
		scope but never widen it. Branch and remote operations act on the repository as before.
	**/
	public static function narrowOperation(operation:ScmOperation, folders:Array<String>, full:Null<ScmSnapshot>,
			?ignoreCase:Bool):NarrowedOperation {
		var names = folders.join(", ");
		function allow(paths:Array<String>):NarrowedOperation {
			for (path in paths) {
				if (!ScmFolderScope.plain(path)) return Refused((path == null ? "An empty path" : path) + " is not a plain path inside " + names);
				if (!ScmFolderScope.inside(path, folders, ignoreCase)) return Refused(path + " is outside " + names);
			}
			return Allowed(operation);
		}
		var whole = [for (folder in folders) folder.substring(0, folder.length - 1)];
		switch operation {
			case Stage(path) | Unstage(path) | Discard(path) | RestoreDiscard(path, _) | ResolveConflict(path, _)
				| StagePatch(path, _) | UnstagePatch(path, _) | RevertPatch(path, _):
				return allow([path]);
			case StagePaths(paths) | UnstagePaths(paths):
				return allow(paths);
			case StageAll:
				return Allowed(ScmOperation.StagePaths(whole));
			case UnstageAll:
				return Allowed(ScmOperation.UnstagePaths(whole));
			case Commit(message, amend):
				return commit(message, amend, folders, full, ignoreCase);
			case ScopedCommit(message, amend, requested):
				var scope = ScmFolderScope.intersect(requested, folders, ignoreCase);
				if (scope.length == 0) return Refused("The commit's folders " + requested.join(", ") + " are outside " + names);
				return commit(message, amend, scope, full, ignoreCase);
			case Checkout(_) | CreateBranch(_) | CreateWorktree(_, _) | Fetch(_) | Pull | Push:
				return Allowed(operation);
		}
	}

	static function commit(message:String, amend:Bool, folders:Array<String>, full:Null<ScmSnapshot>, ?ignoreCase:Bool):NarrowedOperation {
		var names = folders.join(", ");
		if (full == null) return Refused("Refresh the repository before committing");
		if (full.truncated) return Refused("Too many changes to confirm this commit stays inside " + names);
		var staged:Array<String> = [];
		for (group in full.groups) if (group.id == ScmGroupId.Index) for (resource in group.resources)
			if (!ScmFolderScope.inside(resource.path, folders, ignoreCase)
				|| resource.originalPath != null && !ScmFolderScope.inside(resource.originalPath, folders, ignoreCase))
				staged.push(resource.path);
		if (staged.length > 0) return Refused(ScmFolderScope.refusal("Staged changes", staged, folders));
		return Allowed(ScmOperation.ScopedCommit(message, amend, folders));
	}

	function failed<T>(value:Null<T>, complete:ScmJobResult<T>->Void, code:String, message:String):ScmJob<T> {
		if (complete == null) throw "SCM callback cannot be null";
		var job = new ScmJob<T>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult<T>(job.generation, value, new ScmError(code, message)));
		return job;
	}

	/** The machine's full spelling with `/` separators and no trailing one; case is kept for display. */
	static function normalize(path:String):String return PathKey.of(sys.FileSystem.fullPath(path), false);

	static function within(parent:String, child:String):Bool return PathKey.within(parent, normalize(child));
}
