package search;

import jobs.JobHandle;
import jobs.JobScheduler;
import workspace.ProjectNode;
import workspace.Workspace;

class WorkspaceSearch {
	public static inline final DEBOUNCE_SECONDS = 0.075;
	public final results:Array<SearchMatch> = [];
	public final errors:Array<String> = [];
	public var generation(default, null):Int = 0;
	public var complete(default, null):Bool = true;
	public var capped(default, null):Bool = false;
	public var query(default, null):String = "";
	final workspace:Workspace;
	final scheduler:JobScheduler;
	final onChange:Void->Void;
	/** The files to search; defaults to the active context's projects. */
	final scope:Null<Void->Array<ProjectNode>>;
	var handle:Null<JobHandle>;
	var pendingOptions:SearchOptions;
	var pendingMaximum:Int = 10000;
	var requestedAt:Float = 0.0;
	var pending:Bool = false;

	public function new(workspace:Workspace, scheduler:JobScheduler, onChange:Void->Void, ?scope:Void->Array<ProjectNode>) {
		this.workspace = workspace;
		this.scheduler = scheduler;
		this.onChange = onChange;
		this.scope = scope;
		pendingOptions = new SearchOptions();
	}

	public function request(query:String, options:SearchOptions, maximum:Int):Void {
		generation++;
		this.query = query;
		pendingOptions = options.copy();
		pendingMaximum = maximum;
		requestedAt = Sys.time();
		pending = true;
		complete = false;
		capped = false;
		results.resize(0);
		errors.resize(0);
		if (handle != null) scheduler.cancel(handle);
		handle = null;
		onChange();
	}

	public function update(now:Float):Void {
		if (pending && now - requestedAt >= DEBOUNCE_SECONDS) startPending();
	}

	public function flush():Void {
		if (pending) startPending();
	}

	function startPending():Void {
		pending = false;
		if (query.length == 0) {
			complete = true;
			onChange();
			return;
		}
		try {
			var source = scope;
			var task = new WorkspaceSearchJob(this, generation, workspace, query, pendingOptions, pendingMaximum,
				source == null ? null : source());
			handle = scheduler.schedule(task);
		} catch (error:Dynamic) {
			errors.push('Invalid search pattern: ' + Std.string(error));
			complete = true;
			onChange();
		}
	}

	public function publish(sourceGeneration:Int, matches:Array<SearchMatch>, ?error:String, isComplete:Bool = false,
			isCapped:Bool = false):Void {
		if (sourceGeneration != generation) return;
		for (match in matches) results.push(match);
		if (error != null) errors.push(error);
		if (isComplete) complete = true;
		if (isCapped) capped = true;
		onChange();
	}

	public function cancel():Void {
		generation++;
		pending = false;
		if (handle != null) scheduler.cancel(handle);
		handle = null;
		complete = true;
	}
}
