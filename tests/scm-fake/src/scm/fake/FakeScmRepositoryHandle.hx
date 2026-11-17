package scm.fake;

import scm.ScmApplyResult;
import scm.ScmBlob;
import scm.ScmError;
import scm.ScmFeatures;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmRepositoryHandle;
import scm.ScmSnapshot;
import haxe.io.Bytes;

class FakeScmRepositoryHandle implements ScmRepositoryHandle {
	final repositoryValue:ScmRepository;
	final featuresValue:ScmFeatures;
	final script:FakeScmRepositoryScript;
	final scheduler:jobs.JobScheduler;
	var disposed:Bool = false;

	public function new(script:FakeScmRepositoryScript, scheduler:jobs.JobScheduler) {
		this.script = script;
		this.scheduler = scheduler;
		repositoryValue = script.repository;
		featuresValue = script.features;
	}

	public function repository():ScmRepository return repositoryValue;
	public function features():ScmFeatures return featuresValue;
	public function branches(generation:Int, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		var error = availableError("branches");
		return schedule(generation, error == null ? script.branches.copy() : null, error, complete);
	}

	public function refresh(generation:Int, complete:ScmJobResult<ScmSnapshot>->Void):ScmJob<ScmSnapshot> {
		script.refreshCalls++;
		var error = availableError("refresh"), value = error == null ? script.nextSnapshot() : null;
		if (error == null && value == null) error = new ScmError("operation_failed", "The fake repository has no snapshots");
		return schedule(generation, value, error, complete);
	}

	public function original(reference:ScmRef, path:String, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		return originalBytes(reference, Bytes.ofString(path), generation, complete);
	}

	public function originalBytes(reference:ScmRef, path:Bytes, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		var error = availableError("original"), value = error == null ? script.blobs.get(FakeScmRepositoryScript.blobKey(reference, path.toString())) : null;
		if (error == null && value == null) error = new ScmError("operation_failed", "No scripted blob for this reference and path");
		return schedule(generation, value, error, complete);
	}

	public function apply(operation:ScmOperation, generation:Int, complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		script.operations.push(operation);
		var error = availableError("apply"), snapshot = script.latestSnapshot();
		var value = error == null ? new ScmApplyResult(snapshot, "fake operation completed") : null;
		return schedule(generation, value, error, complete, function() script.cancelledOperations++);
	}

	function availableError(action:String):Null<ScmError>
		return disposed ? new ScmError("operation_failed", "The fake repository handle was disposed") : script.takeFailure(action);

	function schedule<T>(generation:Int, value:Null<T>, error:Null<ScmError>, complete:ScmJobResult<T>->Void,
			?onCancelled:Void->Void):ScmJob<T> {
		var scheduled:Null<jobs.JobHandle> = null;
		var job = new ScmJob<T>(generation, function() {
			if (scheduled != null) scheduler.cancel(scheduled);
			if (onCancelled != null) onCancelled();
		});
		var task = new FakeScmTask(script.latencySteps, function() {
			if (job.finish()) complete(new ScmJobResult<T>(generation, value, error));
		});
		scheduled = scheduler.schedule(task);
		return job;
	}

	public function dispose():Void disposed = true;
}
