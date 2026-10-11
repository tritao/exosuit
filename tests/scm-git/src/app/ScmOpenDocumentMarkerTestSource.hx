package app;

import haxe.Int64;
import haxe.io.Bytes;
import scm.ScmApplyResult;
import scm.ScmBlob;
import scm.ScmError;
import scm.ScmFeatures;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmSnapshot;
import scm.ScmSource;

/** Minimal source fixture for open-buffer marker behavior. */
class ScmOpenDocumentMarkerTestSource implements ScmSource {
	final repositoryValue:ScmRepository;
	var snapshotValue:ScmSnapshot;
	final blob:ScmBlob;
	var nextGeneration:Int = 1;
	public var originalCalls:Int = 0;

	public function new(repository:ScmRepository, snapshot:ScmSnapshot, blob:ScmBlob) {
		repositoryValue = repository;
		snapshotValue = snapshot;
		this.blob = blob;
	}

	public function identity():String return "test:" + repositoryValue.id;
	public function isRemote():Bool return false;
	public function connected():Bool return true;
	public function repositories():Array<ScmRepository> return [repositoryValue];
	public function repository(repositoryId:String):Null<ScmRepository> return repositoryId == repositoryValue.id ? repositoryValue : null;
	public function features(repositoryId:String):Null<ScmFeatures> return repository(repositoryId) == null ? null : new ScmFeatures();
	public function canWrite(repositoryId:String):Bool return false;
	public function canUseRemotes(repositoryId:String):Bool return false;
	public function snapshot(repositoryId:String):Null<ScmSnapshot> return repository(repositoryId) == null ? null : snapshotValue;
	public function error(repositoryId:String):Null<ScmError> return null;

	public function branches(repositoryId:String, complete:ScmJobResult<Array<scm.ScmBranch>>->Void):ScmJob<Array<scm.ScmBranch>> {
		var job = new ScmJob<Array<scm.ScmBranch>>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult(job.generation, null, new ScmError("unsupported", "No branches in marker test source")));
		return job;
	}

	public function discover(complete:ScmJobResult<Array<ScmRepository>>->Void):ScmJob<Array<ScmRepository>> {
		var job = new ScmJob<Array<ScmRepository>>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult(job.generation, [repositoryValue]));
		return job;
	}

	public function refreshNow(repositoryId:String):Bool return repository(repositoryId) != null;

	public function originalBytes(repositoryId:String, reference:ScmRef, path:Bytes,
		complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		originalCalls++;
		var job = new ScmJob<ScmBlob>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult(job.generation, repository(repositoryId) == null ? null : blob));
		return job;
	}

	public function apply(repositoryId:String, operationId:String, expectedRevision:Int64, operation:ScmOperation,
		complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		var job = new ScmJob<ScmApplyResult>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult(job.generation, null, new ScmError("unsupported", "No mutations in marker test source")));
		return job;
	}

	public function trust(repositoryId:String, complete:ScmJobResult<Bool>->Void):ScmJob<Bool> {
		var job = new ScmJob<Bool>(nextGeneration++);
		if (job.finish()) complete(new ScmJobResult(job.generation, false));
		return job;
	}

	public function subscribe(listener:(ScmRepository, Null<ScmSnapshot>)->Void):Void->Void return function() {};
	public function poll():Void {}
	public function dispose():Void {}
}
