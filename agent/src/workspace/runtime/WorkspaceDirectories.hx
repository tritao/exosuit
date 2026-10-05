package workspace.runtime;

import sys.FileSystem;
import haxe.io.Path;

/** Resolve authorized directories on the owning machine, including symlink targets. */
class WorkspaceDirectories {
	public final root:String;

	public function new(root:String) {
		this.root = FileSystem.fullPath(root);
		if (!FileSystem.isDirectory(this.root)) throw "Workspace root is not a directory";
	}

	public function resolve(value:String):Null<String> {
		try {
			if (value == null || value.length == 0 || value.length > 1024)
				return null;
			var result = FileSystem.fullPath(Path.isAbsolute(value) ? value : Path.join([root, value]));
			if ((result != root && !StringTools.startsWith(result, root == "/" ? "/" : root + "/")) || !FileSystem.isDirectory(result))
				return null;
			return result;
		} catch (_:Dynamic)
			return null;
	}
}
