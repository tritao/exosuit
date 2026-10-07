import jobs.JobScheduler;
import workspace.FileSystemService;
import workspace.Project;

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
}

class ProjectScanYieldTest {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}
	static function main():Int {
		var fs = new ScanFileSystem(), scheduler = new JobScheduler();
		var project = new Project("/fixture", fs, scheduler);
		require(fs.checks <= 17 && !project.tree.loaded, "initial scan did not yield inside a large directory");
		var snapshot = project.files(), initialLength = snapshot.length;
		var turns = 0;
		while (scheduler.activeCount() > 0 && turns++ < 64) {
			var before = fs.checks;
			scheduler.update(1);
			require(fs.checks - before <= 16, "one cooperative step processed too many entries");
		}
		require(!project.indexing() && project.tree.loaded, "chunked scan did not finish");
		require(project.files().length == 116 && fs.listings == 2, "scan lost entries or reread a directory");
		require(snapshot.length == initialLength, "published file snapshot changed as the scan grew");
		project.cancelIndex();
		require(scheduler.activeCount() == 0, "completed scan was not released");
		Sys.println("project scan yielding and snapshot checks passed");
		return 0;
	}
}
