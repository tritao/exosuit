package workspace;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.FileSystem.FileSystemEntry;
import sys.io.File;

class FileSystemService implements EditorFileSystem {
	public function new() {}

	public function normalize(path:String):String {
		if (!FileSystem.exists(path)) {
			var separator = path.lastIndexOf("/"), parent = separator < 0 ? "." : path.substring(0, separator), name = path.substring(separator + 1);
			if (parent.length == 0) parent = "/";
			if (name.length == 0 || name == "." || name == ".." || !FileSystem.isDirectory(parent)) throw 'Invalid destination "$path"';
			return join(normalize(parent), name);
		}
		var value = StringTools.replace(FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	public function exists(path:String):Bool
		return FileSystem.exists(path);

	public function isDirectory(path:String):Bool
		return FileSystem.isDirectory(path);

	public function entries(path:String):Array<String> {
		var values = FileSystem.readDirectory(path);
		if (values == null) throw 'Could not read directory "$path"';
		values.sort(Reflect.compare);
		return values;
	}

	/** Resolves directory identity and child kinds in one enumeration. */
	public function scanDirectory(path:String):{identity:String, entries:Array<FileSystemEntry>} {
		var identity = normalize(path);
		var entries = FileSystem.readDirectoryEntries(path);
		entries.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return {identity: identity, entries: entries};
	}

	public function join(parent:String, name:String):String
		return parent + "/" + name;

	public function read(path:String):String
		return TextFileContent.decode(File.getBytes(path), path);

	public function readBytes(path:String):Bytes
		return File.getBytes(path);

	public function writeAtomic(path:String, content:String):Bool {
		try {
			sys.io.AtomicFile.write(path, content);
			return true;
		} catch (error:Dynamic) {
			return false;
		}
	}

	public function createFile(path:String):Bool {
		try {
			sys.io.AtomicFile.create(path, "");
			return true;
		} catch (error:Dynamic) {
			return false;
		}
	}

	public function createFolder(path:String):Bool {
		if (exists(path)) return false;
		FileSystem.createDirectory(path);
		return exists(path) && isDirectory(path);
	}

	public function rename(path:String, destination:String):Bool {
		if (!exists(path) || exists(destination)) return false;
		try {
			FileSystem.rename(path, destination);
			return exists(destination) && !exists(path);
		} catch (error:Dynamic) {
			return false;
		}
	}

	public function deleteFile(path:String):Bool {
		if (!exists(path) || isDirectory(path)) return false;
		FileSystem.deleteFile(path);
		return !exists(path);
	}
}
