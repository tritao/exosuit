package scm.fake;

import scm.ScmError;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmProvider;
import scm.ScmRepositoryHandle;

class FakeScmProvider implements ScmProvider {
	final scheduler:jobs.JobScheduler;
	final scripts:Array<FakeScmRepositoryScript> = [];
	public var detectFailure:Null<ScmError>;

	public function new(scheduler:jobs.JobScheduler) this.scheduler = scheduler;

	public function id():String return "fake";

	public function add(script:FakeScmRepositoryScript):Void scripts.push(script);

	public function detect(root:String, generation:Int, complete:ScmJobResult<Array<ScmRepositoryHandle>>->Void):ScmJob<Array<ScmRepositoryHandle>> {
		var error = detectFailure;
		detectFailure = null;
		var handles:Array<ScmRepositoryHandle> = [];
		if (error == null)
			for (script in scripts) if (script.repository.root == root) handles.push(new FakeScmRepositoryHandle(script, scheduler));
		var scheduled:Null<jobs.JobHandle> = null;
		var job = new ScmJob<Array<ScmRepositoryHandle>>(generation, function() {
			if (scheduled != null) scheduler.cancel(scheduled);
		});
		scheduled = scheduler.schedule(new FakeScmTask(0, function() {
			if (job.finish()) complete(new ScmJobResult<Array<ScmRepositoryHandle>>(generation, error == null ? handles : null, error));
		}));
		return job;
	}
}
