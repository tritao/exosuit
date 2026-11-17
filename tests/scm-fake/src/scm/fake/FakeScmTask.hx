package scm.fake;

import jobs.JobTask;

class FakeScmTask implements JobTask {
	var remaining:Int;
	final onComplete:Void->Void;
	var cancelled:Bool = false;

	public function new(latencySteps:Int, onComplete:Void->Void) {
		remaining = latencySteps < 0 ? 0 : latencySteps;
		this.onComplete = onComplete;
	}

	public function step():Bool {
		if (cancelled) return true;
		if (remaining > 0) { remaining--; return false; }
		onComplete();
		return true;
	}

	public function cancel():Void cancelled = true;
}
