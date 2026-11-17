package jobs;

class JobScheduler {
	var nextId:Int = 1;
	final generations:Map<Int, Int> = [];
	final jobs:Array<ScheduledJob> = [];

	public function new() {}

	public function schedule(task:JobTask):JobHandle {
		var id = nextId++, handle = new JobHandle(id, 1);
		generations.set(id, 1);
		jobs.push(new ScheduledJob(handle, task));
		return handle;
	}

	public function replace(handle:JobHandle, task:JobTask):JobHandle {
		cancel(handle);
		var generation = currentGeneration(handle.id) + 1, replacement = new JobHandle(handle.id, generation);
		generations.set(handle.id, generation);
		jobs.push(new ScheduledJob(replacement, task));
		return replacement;
	}

	public function cancel(handle:JobHandle):Bool {
		for (index in 0...jobs.length) {
			var job = jobs[index];
			if (job.handle.id == handle.id && job.handle.generation == handle.generation) {
				job.task.cancel();
				jobs.splice(index, 1);
				return true;
			}
		}
		return false;
	}

	/** Runs cooperative work within both a step ceiling and an event-loop time slice. */
	public function update(maxSteps:Int, maxMillis:Float = 6.0):Int {
		if (maxSteps < 0) throw "job step budget must be non-negative";
		if (maxMillis < 0) throw "job time budget must be non-negative";
		if (maxSteps == 0 || maxMillis == 0) return 0;
		var performed = 0, deadline = Sys.time() + maxMillis / 1000.0;
		while (performed < maxSteps && jobs.length > 0) {
			var job = jobs.shift() ?? throw "No job", complete = job.task.step();
			performed++;
			if (!complete) jobs.push(job);
			if (Sys.time() >= deadline) break;
		}
		return performed;
	}

	public function isCurrent(handle:JobHandle):Bool
		return currentGeneration(handle.id) == handle.generation;

	public function activeCount():Int
		return jobs.length;

	function currentGeneration(id:Int):Int {
		var value = generations.get(id);
		return value == null ? 0 : value;
	}
}
