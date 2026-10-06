package workspace;

import jobs.JobTask;

class ProjectScan implements JobTask {
	public final generation:Int;
	public final tree:ProjectNode;
	public final files:Array<ProjectNode> = [];
	public var complete(default, null):Bool = false;
	public var snapshot(default, null):String = "";
	final owner:Project;
	final fileSystem:FileSystemService;
	final ignored:Map<String, Bool>;
	final directories:Array<ProjectNode>;
	final snapshotParts:Array<String> = [];
	final seen:Map<String, Bool> = [];
	var cursor:Int = 0;
	var cancelled:Bool = false;
	var pendingDirectory:Null<ProjectNode>;
	var pendingEntries:Array<String> = [];
	var entryCursor:Int = 0;

	public function new(owner:Project, generation:Int, fileSystem:FileSystemService, ignored:Map<String, Bool>) {
		this.owner = owner;
		this.generation = generation;
		this.fileSystem = fileSystem;
		this.ignored = ignored;
		tree = new ProjectNode(owner.name, owner.root, true, 0, true);
		directories = [tree];
	}

	public function step():Bool {
		if (cancelled || complete) return true;
		var deadline = Sys.time() + 0.002;
		if (pendingDirectory == null) {
			if (cursor >= directories.length) {
				finish();
				return true;
			}
			var nextDirectory = directories[cursor++];
			pendingDirectory = nextDirectory;
			entryCursor = 0;
			pendingEntries = [];
			try {
				var identity = fileSystem.normalize(nextDirectory.path);
				if (!seen.exists(identity)) {
					seen.set(identity, true);
					pendingEntries = fileSystem.entries(nextDirectory.path);
				}
			} catch (error:Dynamic) {
				owner.scanFailed(generation, nextDirectory.path, Std.string(error));
			}
		}
		var node:ProjectNode = cast pendingDirectory;
		var processed = 0;
		// A large directory must yield before the scheduler's time budget can
		// be checked. Never perform all of its file-status calls in one step.
		while (entryCursor < pendingEntries.length && processed < 16) {
			var entry = pendingEntries[entryCursor++];
			processed++;
			if (!ignored.exists(entry)) {
				try {
					var path = fileSystem.join(node.path, entry), directory = fileSystem.isDirectory(path),
						child = new ProjectNode(entry, path, directory, node.depth + 1);
					node.children.push(child);
					snapshotParts.push(path);
					if (directory) directories.push(child); else files.push(child);
				} catch (error:Dynamic) {
					owner.scanFailed(generation, node.path, Std.string(error));
				}
			}
			if (Sys.time() >= deadline) break;
		}
		owner.publishScan(this, false);
		if (entryCursor < pendingEntries.length) return false;
		node.loaded = true;
		pendingDirectory = null;
		pendingEntries = [];
		if (cursor >= directories.length) {
			finish();
			return true;
		}
		return false;
	}

	function finish():Void {
		snapshot = snapshotParts.join("\n") + (snapshotParts.length == 0 ? "" : "\n");
		complete = true;
		owner.publishScan(this, true);
	}

	public function cancel():Void cancelled = true;
}
