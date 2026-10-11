package scm;

import haxe.Int64;
import haxe.io.Bytes;

/** Root-scoped view of the desktop's in-process SCM service. */
class LocalScmSource implements ScmSource {
	final service:ScmService;
	final root:String;
	final sourceIdentity:String;
	final subscriptions:Array<Void->Void> = [];
	var nextGeneration:Int = 1;
	var disposed:Bool = false;

	public function new(service:ScmService, root:String) {
		if (service == null || root == null || root.length == 0)
			throw "Local SCM source requires a service and root";
		this.service = service;
		this.root = normalize(root);
		this.sourceIdentity = "local:" + key(this.root);
	}

	public function identity():String return sourceIdentity;
	public function isRemote():Bool return false;
	public function connected():Bool return !disposed;
	public function repositories():Array<ScmRepository> return disposed ? []
		: [for (repository in service.repositories(root)) if (inScope(repository.root)) repository];
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
	public function snapshot(repositoryId:String):Null<ScmSnapshot> return scopedRepository(repositoryId) == null ? null : service.snapshot(repositoryId);
	public function error(repositoryId:String):Null<ScmError> return disposed ? new ScmError("service_closed", "Source control source is closed")
		: scopedRepository(repositoryId) == null ? new ScmError("not_found", "Repository is outside this workspace root") : service.error(repositoryId);

	public function discover(complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		if (disposed) return failed([], complete, "service_closed", "Source control source is closed");
		if (complete == null) throw "SCM discovery callback cannot be null";
		return service.discover(root, complete);
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
		if (scopedRepository(repositoryId) == null) return failed(null, complete, "not_found", "Repository is outside this workspace root");
		var current = service.snapshot(repositoryId);
		if (current == null || Int64.compare(current.revision, expectedRevision) != 0)
			return failed(null, complete, "stale_revision", "Repository changed before the operation started");
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
			if (!disposed && inScope(repository.root)) listener(repository, snapshot);
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

	function inScope(repositoryRoot:String):Bool return within(root, repositoryRoot) || within(repositoryRoot, root);

	function failed<T>(value:Null<T>, complete:ScmJobResult<T>->Void, code:String, message:String):ScmJob<T> {
		if (complete == null) throw "SCM callback cannot be null";
		var job = new ScmJob<T>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult<T>(job.generation, value, new ScmError(code, message)));
		return job;
	}

	static function normalize(path:String):String {
		var value = StringTools.replace(sys.FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function within(parent:String, child:String):Bool {
		var left = key(parent), right = key(normalize(child)), prefix = StringTools.endsWith(left, "/") ? left : left + "/";
		return left == right || StringTools.startsWith(right, prefix);
	}

	static function key(path:String):String return Sys.systemName() == "Windows" ? path.toLowerCase() : path;
}
