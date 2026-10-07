package workspace;

import jobs.JobTask;
import sys.FileSystem.FileSystemEntry;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

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
	var pendingEntries:Array<FileSystemEntry> = [];
	var entryCursor:Int = 0;
	final readRequest:Lock = new Lock();
	final readComplete:Lock = new Lock();
	final readState:Mutex = new Mutex();
	var readerStarted:Bool = false;
	var readerStopped:Bool = false;
	var readerUnavailable:Bool = false;
	var readerPath:String;
	var readerResult:Null<{identity:String, entries:Array<FileSystemEntry>}>;
	var readerError:Null<String>;
	var directoryReadPending:Bool = false;

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
			requestDirectoryRead(nextDirectory.path);
			return false;
		}
		var node:ProjectNode = cast pendingDirectory;
		if (directoryReadPending) {
			if (!readComplete.wait(0)) return false;
			readState.acquire();
			var result = readerResult;
			var error = readerError;
			readerResult = null;
			readerError = null;
			readState.release();
			directoryReadPending = false;
			if (error != null) owner.scanFailed(generation, node.path, error);
			if (result != null && !seen.exists(result.identity)) {
				seen.set(result.identity, true);
				pendingEntries = result.entries;
			}
			if (readerUnavailable) {
				finish();
				return true;
			}
		}
		var processed = 0;
		// A large directory must yield before the scheduler's time budget can
		// be checked. Never perform all of its file-status calls in one step.
		while (entryCursor < pendingEntries.length && processed < 16) {
			var entry = pendingEntries[entryCursor++];
			processed++;
			if (!ignored.exists(entry.name)) {
				var path = fileSystem.join(node.path, entry.name);
				var child = new ProjectNode(entry.name, path, entry.isDirectory, node.depth + 1);
				node.children.push(child);
				snapshotParts.push(path);
				if (entry.isDirectory) directories.push(child); else files.push(child);
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
		stopReader();
		snapshot = snapshotParts.join("\n") + (snapshotParts.length == 0 ? "" : "\n");
		complete = true;
		owner.publishScan(this, true);
	}

	function requestDirectoryRead(path:String):Void {
		readState.acquire();
		readerPath = path;
		readState.release();
		directoryReadPending = true;
		if (!readerStarted && !readerUnavailable) {
			try {
				Thread.create(directoryReaderLoop);
				readerStarted = true;
			} catch (error:Dynamic) {
				readerUnavailable = true;
				readState.acquire();
				readerError = "Could not start project scan worker: " + Std.string(error);
				readState.release();
				readComplete.release();
				return;
			}
		}
		readRequest.release();
	}

	function directoryReaderLoop():Void {
		while (true) {
			readRequest.wait();
			readState.acquire();
			var stop = readerStopped;
			var path = readerPath;
			readState.release();
			if (stop) return;

			var result:Null<{identity:String, entries:Array<FileSystemEntry>}> = null;
			var error:Null<String> = null;
			try result = fileSystem.scanDirectory(path) catch (failure:Dynamic) error = Std.string(failure);
			readState.acquire();
			readerResult = result;
			readerError = error;
			readState.release();
			readComplete.release();
		}
	}

	function stopReader():Void {
		readState.acquire();
		readerStopped = true;
		readState.release();
		if (readerStarted) readRequest.release();
	}

	public function cancel():Void {
		cancelled = true;
		stopReader();
	}
}
