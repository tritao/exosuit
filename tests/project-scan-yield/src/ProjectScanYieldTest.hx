import jobs.JobScheduler;
import workspace.FileSystemService;
import workspace.Project;
import sys.FileSystem.FileSystemEntry;

private class ScanFileSystem extends FileSystemService {
	public var checks:Int = 0;
	public var listings:Int = 0;
	public function new() super();
	override public function normalize(path:String):String return path;
	override public function exists(path:String):Bool return true;
	override public function isDirectory(path:String):Bool {
		checks++;
		return path == "/fixture" || path == "/fixture/nested";
	}
	override public function entries(path:String):Array<String> {
		listings++;
		var result = [for (index in 0...(path == "/fixture" ? 96 : 20)) "file-" + index + ".txt"];
		if (path == "/fixture") result.push("nested");
		return result;
	}
	override public function scanDirectory(path:String):{identity:String, entries:Array<FileSystemEntry>} {
		return {identity: path, entries: [for (name in entries(path)) new FileSystemEntry(name, isDirectory(join(path, name)))]};
	}
}

class ProjectScanYieldTest {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}
	static function main():Int {
		var fs = new ScanFileSystem(), scheduler = new JobScheduler();
		var project = new Project("/fixture", fs, scheduler);
		require(project.files().length <= 16 && !project.tree.loaded, "initial scan did not yield inside a large directory");
		var snapshot = project.files(), initialLength = snapshot.length;
		var deadline = Sys.time() + 5;
		while (scheduler.activeCount() > 0 && Sys.time() < deadline) {
			var before = project.files().length;
			scheduler.update(1);
			require(project.files().length - before <= 16, "one cooperative step published too many entries");
			Sys.sleep(0.001);
		}
		require(!project.indexing() && project.tree.loaded, "chunked scan did not finish");
		require(project.files().length == 116 && fs.listings == 2, "scan lost entries or reread a directory");
		require(snapshot.length == initialLength, "published file snapshot changed as the scan grew");
		var generation = project.indexGeneration();
		project.pollChanges(32, false);
		require(project.indexGeneration() == generation, "a periodic poll rescanned right after a scan finished");
		project.pollChanges(32, true);
		require(project.indexGeneration() == generation + 1 && !project.indexing(), "an immediate poll did not start a rescan");
		deadline = Sys.time() + 5;
		while (scheduler.activeCount() > 0 && Sys.time() < deadline) {
			scheduler.update(1);
			require(project.files().length == 116 && project.tree.loaded, "a rescan published a partial index");
			Sys.sleep(0.001);
		}
		require(scheduler.activeCount() == 0 && fs.listings == 4, "rescan did not finish or reread a directory");
		project.cancelIndex();
		require(scheduler.activeCount() == 0, "completed scan was not released");
		Sys.println("project scan yielding and snapshot checks passed");
		return 0;
	}
}
