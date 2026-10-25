package workspace;

import jobs.JobTask;
import sys.FileSystem.FileSystemEntry;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

private typedef DirectoryRead = {result:Null<{identity:String, entries:Array<FileSystemEntry>}>, error:Null<String>};

class ProjectScan implements JobTask {
	/** Directories the reader thread may list ahead of the one being merged. */
	static inline final READ_AHEAD = 64;

	public final generation:Int;
	public final tree:ProjectNode;
	public final files:Array<ProjectNode> = [];
	public var complete(default, null):Bool = false;
	public var snapshot(default, null):String = "";
	public final startedAt:Float = Sys.time();
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
	var directoryReadPending:Bool = false;
	// Directories are queued for the reader thread in scan order; the reader lists each once and leaves the result for
	// the scan step that merges that directory.
	var queued:Int = 0;
	final readRequest:Lock = new Lock();
	final readComplete:Lock = new Lock();
	final readState:Mutex = new Mutex();
	final readQueue:Array<String> = [];
	final readResults:Map<String, DirectoryRead> = [];
	var readerStarted:Bool = false;
	var readerStopped:Bool = false;
	var readerUnavailable:Bool = false;
	var readerFailure:Null<String>;

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
			directoryReadPending = true;
			queueReads();
		}
		var node:ProjectNode = cast pendingDirectory;
		if (directoryReadPending) {
			if (readerUnavailable) {
				owner.scanFailed(generation, node.path, readerFailure);
				finish();
				return true;
			}
			var read = takeRead(node.path, deadline);
			if (read == null) return false;
			directoryReadPending = false;
			if (read.error != null) owner.scanFailed(generation, node.path, read.error);
			if (read.result != null && !seen.exists(read.result.identity)) {
				seen.set(read.result.identity, true);
				pendingEntries = read.result.entries;
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

	/** Hands the reader the directories found so far, up to READ_AHEAD past the one being merged. */
	function queueReads():Void {
		if (readerUnavailable) return;
		if (!readerStarted) {
			try {
				haxeon.Threads.create("exo.scan.reader", directoryReaderLoop);
				readerStarted = true;
			} catch (error:Dynamic) {
				readerUnavailable = true;
				readerFailure = "Could not start project scan worker: " + Std.string(error);
				return;
			}
		}
		var limit = cursor - 1 + READ_AHEAD;
		if (queued >= directories.length || queued >= limit) return;
		readState.acquire();
		while (queued < directories.length && queued < limit) readQueue.push(directories[queued++].path);
		readState.release();
		readRequest.release();
	}

	/** The reader's listing of `path`, waiting for it no later than `deadline`; null if it is not ready yet. */
	function takeRead(path:String, deadline:Float):Null<DirectoryRead> {
		while (true) {
			readState.acquire();
			var read = readResults.get(path);
			if (read != null) readResults.remove(path);
			readState.release();
			if (read != null) return read;
			var remaining = deadline - Sys.time();
			if (remaining <= 0 || !readComplete.wait(remaining)) return null;
		}
	}

	function directoryReaderLoop():Void {
		while (true) {
			readRequest.wait();
			while (true) {
				readState.acquire();
				var stop = readerStopped;
				var path = stop || readQueue.length == 0 ? null : readQueue.shift();
				readState.release();
				if (stop) return;
				if (path == null) break;
				var read:DirectoryRead = {result: null, error: null};
				try read.result = fileSystem.scanDirectory(path) catch (failure:Dynamic) read.error = Std.string(failure);
				readState.acquire();
				readResults.set(path, read);
				readState.release();
				readComplete.release();
			}
		}
	}

	function stopReader():Void {
		readState.acquire();
		readerStopped = true;
		readQueue.resize(0);
		readResults.clear();
		readState.release();
		if (readerStarted) readRequest.release();
	}

	public function cancel():Void {
		cancelled = true;
		stopReader();
	}
}
