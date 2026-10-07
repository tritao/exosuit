package app;

import jobs.JobScheduler;
import workspace.FileSystemService;
import workspace.Project;

class DirectoryScanTestMain {
	static function main():Int {
		var root = Sys.args()[0], fs = new FileSystemService();
		for (path in [root + "/missing", root + "/a.txt", root + "/blocked"]) {
			var rejected = false;
			try {
				fs.entries(path);
			} catch (error:Dynamic) {
				rejected = Std.string(error).indexOf(path) >= 0;
			}
			if (!rejected) throw 'Directory listing must report failure for "$path"';
		}
		var entries = fs.entries(root);
		if (entries.length != 3 || entries[0] != "a.txt" || entries[1] != "blocked" || entries[2] != "vanishing")
			throw "Successful directory listings must remain sorted";
		var jobs = new JobScheduler(), project = new Project(root, fs, jobs);
		// The root was scanned in the constructor; remove a queued directory.
		sys.FileSystem.deleteDirectory(root + "/vanishing");
		jobs.update(32);
		if (jobs.activeCount() != 0 || project.diagnostics.length != 2 || project.files().length != 1)
			throw "Unreadable and removed folders must produce diagnostics and let the scan finish";
		Sys.println("PASS: directory failures are recoverable and project scanning completes");
		return 0;
	}
}
