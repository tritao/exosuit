package scm;

import haxe.Int64;
import haxe.io.Bytes;
import workspace.PathKey;

/** An operation limited to a source's folders, or why it was refused (see LocalScmSource.narrowOperation). */
typedef NarrowedOperation = {
	var operation:Null<ScmOperation>;
	var error:Null<String>;
}

/** Root-scoped view of the desktop's in-process SCM service. */
class LocalScmSource implements ScmSource {
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
	public function repositories():Array<ScmRepository> {
		var result:Array<ScmRepository> = [], seen:Map<String, Bool> = [];
		if (!disposed) for (root in roots) for (repository in service.repositories(root))
			if (inScope(repository.root) && !seen.exists(repository.id)) { seen.set(repository.id, true); result.push(repository); }
		return result;
	}
	public function repository(repositoryId:String):Null<ScmRepository> return scopedRepository(repositoryId);
	public function features(repositoryId:String):Null<ScmFeatures> return scopedRepository(repositoryId) == null ? null : service.features(repositoryId);
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
		var current = service.snapshot(repositoryId);
		if (current == null || Int64.compare(current.revision, expectedRevision) != 0)
			return failed(null, complete, "stale_revision", "Repository changed before the operation started");
		var folders = narrowToFolders ? prefixes(repository) : null;
		if (folders != null) {
			var narrowed = narrowOperation(operation, folders, current);
			if (narrowed.error != null) return failed(null, complete, "outside_folder", narrowed.error);
			operation = narrowed.operation;
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
		var result = folders == null ? snapshot : narrowSnapshot(snapshot, folders);
		narrowedSnapshots.set(repository.id, {source: snapshot, result: result});
		return result;
	}

	static function insideFolders(path:Null<String>, folders:Array<String>):Bool {
		if (path == null) return false;
		for (folder in folders) if (PathKey.within(folder, path)) return true;
		return false;
	}

	/** Keeps the changes under any of the repository-relative folders (each ending in `/`); empty groups are dropped. */
	public static function narrowSnapshot(snapshot:ScmSnapshot, folders:Array<String>):ScmSnapshot {
		var groups:Array<ScmGroup> = [];
		for (group in snapshot.groups) {
			var kept = [for (resource in group.resources)
				if (insideFolders(resource.path, folders) || insideFolders(resource.originalPath, folders)) resource];
			if (kept.length > 0) groups.push(new ScmGroup(group.id, kept, false));
		}
		return new ScmSnapshot(snapshot.revision, snapshot.head, groups, snapshot.truncated);
	}

	/**
		An operation limited to the repository-relative folders (each ending in `/`), checked against the repository's full
		snapshot. Paths outside them are refused; stage-all and unstage-all become the folders themselves. A commit takes
		the whole index, so it is refused while changes outside the folders are staged. Branch and remote operations act
		on the repository as before.
	**/
	public static function narrowOperation(operation:ScmOperation, folders:Array<String>, full:Null<ScmSnapshot>):NarrowedOperation {
		var names = folders.join(", ");
		function result(next:Null<ScmOperation>, error:Null<String>):NarrowedOperation return {operation: next, error: error};
		function allow(paths:Array<String>):NarrowedOperation {
			for (path in paths) if (!insideFolders(path, folders)) return result(null, path + " is outside " + names);
			return result(operation, null);
		}
		var whole = [for (folder in folders) folder.substring(0, folder.length - 1)];
		switch operation {
			case Stage(path) | Unstage(path) | Discard(path) | RestoreDiscard(path, _) | ResolveConflict(path, _)
				| StagePatch(path, _) | UnstagePatch(path, _) | RevertPatch(path, _):
				return allow([path]);
			case StagePaths(paths) | UnstagePaths(paths):
				return allow(paths);
			case StageAll:
				return result(ScmOperation.StagePaths(whole), null);
			case UnstageAll:
				return result(ScmOperation.UnstagePaths(whole), null);
			case Commit(_, _):
				if (full == null) return result(null, "Refresh the repository before committing");
				if (full.truncated) return result(null, "Too many changes to confirm this commit stays inside " + names);
				var staged:Array<String> = [];
				for (group in full.groups) if (group.id == ScmGroupId.Index) for (resource in group.resources)
					if (!insideFolders(resource.path, folders) || resource.originalPath != null && !insideFolders(resource.originalPath, folders))
						staged.push(resource.path);
				if (staged.length == 0) return result(operation, null);
				return result(null, "Staged changes outside " + names + " would be committed too: " + staged.slice(0, 3).join(", ")
					+ (staged.length > 3 ? " and " + (staged.length - 3) + " more" : "")
					+ ". Unstage them, or commit from the Editor layout's Source Control.");
			case Checkout(_) | CreateBranch(_) | Fetch(_) | Pull | Push:
				return result(operation, null);
		}
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
