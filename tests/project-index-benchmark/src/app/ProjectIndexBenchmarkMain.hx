package app;

import platform.Platform;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import workspace.Workspace;
import search.SearchOptions;
import search.WorkspaceSearch;

class ProjectIndexBenchmarkMain {
	static function main():Int {
		var arguments = Sys.args();
		if (arguments.length != 2) throw "expected project root and file count";
		var expected = Std.parseInt(arguments[1]), syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);

		var workspace = new Workspace(syntaxes), retired = workspace.addProject(arguments[0]), updates = 0, maximumMillis = 0.0;
		for (index in 0...5) workspace.refreshProjects(32);
		var retiredCount = retired.files().length;
		if (!workspace.removeProject(retired) || workspace.jobs.activeCount() != 0) throw "project cancellation retained its scan job";
		var project = workspace.addProject(arguments[0]);
		while (project.files().length < expected && updates < expected) {
			var started = Sys.time();
			workspace.refreshProjects(32);
			var elapsed = (Sys.time() - started) * 1000.0;
			if (elapsed > maximumMillis) maximumMillis = elapsed;
			updates++;
		}
		var indexed = project.files().length;
		if (retired.files().length != retiredCount) throw "retired project accepted stale scan results";
		project.cancelIndex();
		var search = new WorkspaceSearch(workspace, workspace.jobs, function() {}), searchMaximumMillis = 0.0;
		search.request("obsolete", new SearchOptions(), 100);
		search.flush();
		workspace.jobs.update(1);
		var cancelledGeneration = search.generation;
		search.request("replacement", new SearchOptions(), 100);
		search.flush();
		var searchUpdates = 0;
		while (!search.complete && searchUpdates < expected + 1) {
			var searchStarted = Sys.time();
			workspace.jobs.update(1);
			var searchElapsed = (Sys.time() - searchStarted) * 1000.0;
			if (searchElapsed > searchMaximumMillis) searchMaximumMillis = searchElapsed;
			searchUpdates++;
		}
		if (!search.complete || search.generation != cancelledGeneration + 1 || workspace.jobs.activeCount() != 0)
			throw "replacement search did not retire its cancelled generation";

		if (indexed != expected) throw 'indexed $indexed of $expected files';
		if (maximumMillis >= 8.0) throw 'project scheduling batch exceeded 8 ms: $maximumMillis';
		if (searchMaximumMillis >= 8.0) throw 'search scheduling batch exceeded 8 ms: $searchMaximumMillis';
		Sys.println('PROJECT_INDEX files=$indexed updates=$updates max_update_ms=$maximumMillis input_ticks=$updates');
		Sys.println('PROJECT_SEARCH files=$indexed updates=$searchUpdates max_update_ms=$searchMaximumMillis cancelled_generation=$cancelledGeneration');
		return 0;
	}
}
