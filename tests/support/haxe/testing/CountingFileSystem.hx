package testing;

import workspace.EditorFileSystem;
import workspace.FileStamp;
import workspace.FileSystemService;

/** The real file system, counting whole-file reads and writes, to check that unchanged files are neither read nor
	written again. */
class CountingFileSystem implements EditorFileSystem {
	final delegate = new FileSystemService();
	public var reads(default, null) = 0;
	public var writes(default, null) = 0;
	public function new() {}
	public function normalize(path:String):String return delegate.normalize(path);
	public function exists(path:String):Bool return delegate.exists(path);
	public function isDirectory(path:String):Bool return delegate.isDirectory(path);
	public function entries(path:String):Array<String> return delegate.entries(path);
	public function join(parent:String, name:String):String return delegate.join(parent, name);
	public function read(path:String):String { reads++; return delegate.read(path); }
	public function stamp(path:String):Null<FileStamp> return delegate.stamp(path);
	public function writeAtomic(path:String, content:String):Bool { writes++; return delegate.writeAtomic(path, content); }
	public function createFile(path:String):Bool return delegate.createFile(path);
	public function createFolder(path:String):Bool return delegate.createFolder(path);
	public function rename(path:String, destination:String):Bool return delegate.rename(path, destination);
	public function deleteFile(path:String):Bool return delegate.deleteFile(path);
}
