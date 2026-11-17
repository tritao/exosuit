package workspace;

import sys.FileSystem;

/** Moves workspace entries into an application-owned recoverable trash directory. */
class TrashService {
	final root:String;
	final fileSystem:FileSystemService;
	var nextId:Int = 1;

	public function new(root:String, fileSystem:FileSystemService) {
		this.root = root;
		this.fileSystem = fileSystem;
	}

	public function move(path:String):Null<TrashEntry> {
		if (!fileSystem.exists(path) || !ensureDirectory(root)) return null;
		var slash = path.lastIndexOf("/"), name = slash < 0 ? path : path.substring(slash + 1), destination:String;
		do destination = root + "/" + nextId++ + "-" + name while (fileSystem.exists(destination));
		if (!fileSystem.rename(path, destination)) return null;
		return new TrashEntry(path, destination);
	}

	function ensureDirectory(path:String):Bool {
		if (FileSystem.exists(path)) return FileSystem.isDirectory(path);
		try FileSystem.createDirectory(path) catch (_:Dynamic) return false;
		return FileSystem.exists(path) && FileSystem.isDirectory(path);
	}
}
