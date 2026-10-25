package scm.git;

import haxe.io.Bytes;
import jobs.JobHandle;
import jobs.JobScheduler;
import jobs.JobTask;
import process.ProcessManager;
import scm.ScmError;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmProvider;
import scm.ScmRepository;
import scm.ScmRepositoryHandle;
import scm.ScmRepositoryKind;
import scm.ScmTrustStore;
import sys.FileSystem;
import sys.FileSystem.FileSystemEntry;
import sys.thread.Lock;
import sys.thread.Mutex;
import config.ConfigurationPaths;

/** Discovers Git worktrees without invoking Git from the application frame. */
class GitScmProvider implements ScmProvider {
	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final gitPath:Null<String>;
	final emptyHooksPath:Null<String>;
	final trustStore:Null<ScmTrustStore>;
	final untrackedLimit:Int;
	final nestedScanDepth:Int;

	public function new(processes:ProcessManager, scheduler:JobScheduler, ?gitPath:String, ?emptyHooksPath:String,
			?trustStore:ScmTrustStore, untrackedLimit:Int = 10000, nestedScanDepth:Int = 3) {
		this.processes = processes;
		this.scheduler = scheduler;
		this.gitPath = gitPath;
		this.emptyHooksPath = emptyHooksPath == null || emptyHooksPath.length == 0 ? defaultHooksPath() : emptyHooksPath;
		this.trustStore = trustStore;
		this.untrackedLimit = untrackedLimit;
		this.nestedScanDepth = nestedScanDepth < 0 ? 0 : nestedScanDepth;
	}

	public function id():String return "git";

	public function detect(root:String, generation:Int, complete:ScmJobResult<Array<ScmRepositoryHandle>>->Void):ScmJob<Array<ScmRepositoryHandle>> {
		var task:Null<GitDetectTask> = null, handle:Null<JobHandle> = null;
		var job = new ScmJob<Array<ScmRepositoryHandle>>(generation, function() {
			if (handle != null) scheduler.cancel(handle);
			if (task != null) task.cancel();
		});
		try {
			var normalized = normalize(root);
			task = new GitDetectTask(normalized, generation, processes, scheduler, gitPath, this.emptyHooksPath, trustStore,
				untrackedLimit, nestedScanDepth, job, complete);
			handle = scheduler.schedule(task);
		} catch (failure:Dynamic) {
			if (job.finish()) complete(new ScmJobResult<Array<ScmRepositoryHandle>>(generation, null,
				new ScmError("invalid_root", "Could not inspect the selected project root: " + Std.string(failure))));
		}
		return job;
	}

	public function trust(root:String):Void {
		if (trustStore == null) throw "Local SCM trust storage is unavailable";
		trustStore.trust(normalize(root));
	}

	public function revokeTrust(root:String):Void {
		if (trustStore == null) throw "Local SCM trust storage is unavailable";
		trustStore.revoke(normalize(root));
	}

	static function normalize(path:String):String {
		var value = StringTools.replace(FileSystem.fullPath(path), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function defaultHooksPath():String {
		var path = ConfigurationPaths.stateRoot() + "/scm/empty-hooks";
		createParents(path);
		if (!FileSystem.isDirectory(path)) throw "Could not create the empty Git hooks directory";
		return normalize(path);
	}

	static function createParents(path:String):Void {
		if (FileSystem.exists(path)) return;
		var separator = path.lastIndexOf("/");
		if (separator > 2) createParents(path.substring(0, separator));
		FileSystem.createDirectory(path);
	}
}

private typedef GitCandidate = {
	var path:String;
	var depth:Int;
	var parentId:Null<String>;
}

private typedef GitMetadata = {
	var root:String;
	var gitDir:String;
	var commonDir:String;
	var superproject:Null<String>;
}

private typedef GitScanEntry = {
	var name:String;
	var isDirectory:Bool;
	var path:Null<String>;
}

private typedef GitScanResult = {
	var identity:String;
	var entries:Array<GitScanEntry>;
	var hasGitMarker:Bool;
}

private class GitDetectTask implements JobTask {
	final root:String;
	final generation:Int;
	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final gitPath:Null<String>;
	final emptyHooksPath:Null<String>;
	final trustStore:Null<ScmTrustStore>;
	final untrackedLimit:Int;
	final maxDepth:Int;
	final job:ScmJob<Array<ScmRepositoryHandle>>;
	final complete:ScmJobResult<Array<ScmRepositoryHandle>>->Void;
	final git:GitProcess;
	final candidates:Array<GitCandidate> = [];
	final seenDirectories:Map<String, Bool> = [];
	final seenRepositories:Map<String, Bool> = [];
	final handles:Array<ScmRepositoryHandle> = [];
	var scanDirectory:Null<GitCandidate>;
	var scanEntries:Array<GitScanEntry> = [];
	var scanEntryCursor:Int = 0;
	var child:Null<ScmJob<Dynamic>>;
	var commandResult:Null<ScmJobResult<Dynamic>>;
	var phase:String = "version";
	var pendingCandidate:Null<GitCandidate>;
	var cancelled:Bool = false;
	final readRequest:Lock = new Lock();
	final readComplete:Lock = new Lock();
	final readState:Mutex = new Mutex();
	var readerStarted:Bool = false;
	var readerStopped:Bool = false;
	var readerUnavailable:Bool = false;
	var readerPath:String = "";
	var readerResult:Null<GitScanResult>;
	var readerError:Null<String>;
	var directoryReadPending:Bool = false;

	public function new(root:String, generation:Int, processes:ProcessManager, scheduler:JobScheduler, gitPath:Null<String>,
			emptyHooksPath:Null<String>, trustStore:Null<ScmTrustStore>, untrackedLimit:Int, maxDepth:Int,
			job:ScmJob<Array<ScmRepositoryHandle>>, complete:ScmJobResult<Array<ScmRepositoryHandle>>->Void) {
		this.root = root;
		this.generation = generation;
		this.processes = processes;
		this.scheduler = scheduler;
		this.gitPath = gitPath;
		this.emptyHooksPath = emptyHooksPath;
		this.trustStore = trustStore;
		this.untrackedLimit = untrackedLimit;
		this.maxDepth = maxDepth;
		this.job = job;
		this.complete = complete;
		git = new GitProcess(processes, scheduler, gitPath, emptyHooksPath);
	}

	public function step():Bool {
		if (cancelled || job.cancelled || job.complete) return true;
		if (commandResult != null) {
			var result = commandResult;
			commandResult = null;
			child = null;
			if (phase == "version") {
				if (result.error != null) return finish(null, result.error);
				phase = "root";
				startRun(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir", "--show-superproject-working-tree"], root);
				return false;
			}
			if (phase == "root") {
				if (result.error == null && result.value != null) {
					try addRepository(metadata(result.value.stdout, root), null, ScmRepositoryKind.Worktree)
					catch (failure:Dynamic) return finish(null, new ScmError("invalid_repository", Std.string(failure)));
				} else if (result.error != null && result.error.code != "not_a_repository") {
					return finish(null, result.error);
				}
				candidates.push({path: root, depth: 0, parentId: null});
				phase = "scan";
			}
			if (phase == "candidate") {
				if (pendingCandidate == null) return finish(null, new ScmError("invalid_repository", "Repository scan lost a Git marker"));
				var candidate:GitCandidate = cast pendingCandidate;
				pendingCandidate = null;
				phase = "scan";
				if (result.error == null && result.value != null) {
					try {
						var info = metadata(result.value.stdout, candidate.path);
						var parent = parentIdFor(candidate, info.root);
						if (info.superproject != null)
							for (handle in handles) if (normalizeKey(handle.repository().root) == normalizeKey(info.superproject)) parent = handle.repository().id;
						addRepository(info, parent, null);
					}
					catch (failure:Dynamic) return finish(null, new ScmError("invalid_repository", Std.string(failure)));
				} else if (result.error != null && result.error.code != "not_a_repository") {
					return finish(null, result.error);
				}
			}
		}
		if (child != null) return false;
		if (phase == "version") {
			var versionJob:ScmJob<GitVersion> = git.probeVersion(generation, function(result) commandResult = cast result);
			child = cast versionJob;
			return false;
		}
		if (phase == "root") {
			startRun(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir", "--show-superproject-working-tree"], root);
			return false;
		}
		if (phase == "scan") {
			if (scanDirectory == null) {
				if (candidates.length == 0) return finish(handles, null);
				var next = candidates.shift();
				if (next.depth >= maxDepth) return false;
				scanDirectory = next;
				scanEntryCursor = 0;
				scanEntries = [];
				requestDirectoryRead(next.path);
				return false;
			}
			if (directoryReadPending) {
				if (!readComplete.wait(0)) return false;
				readState.acquire();
				var result = readerResult, error = readerError;
				readerResult = null;
				readerError = null;
				readState.release();
				directoryReadPending = false;
				if (error != null || result == null || readerUnavailable) {
					scanDirectory = null;
					scanEntries = [];
					if (readerUnavailable) return finish(handles, null);
					return false;
				}
				var directoryKey = normalizeKey(result.identity);
				if (seenDirectories.exists(directoryKey)) {
					scanDirectory = null;
					return false;
				}
				seenDirectories.set(directoryKey, true);
				scanEntries = result.entries;
				if (result.hasGitMarker && !seenRepositories.exists(directoryKey)) {
					var current:GitCandidate = cast scanDirectory;
					pendingCandidate = {path: result.identity, depth: current.depth, parentId: current.parentId};
					phase = "candidate";
					startRun(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir", "--show-superproject-working-tree"], result.identity);
					return false;
				}
			}
			var candidate:GitCandidate = cast scanDirectory, processed = 0;
			while (scanEntryCursor < scanEntries.length && processed < 16) {
				var entry = scanEntries[scanEntryCursor++], name = entry.name;
				processed++;
				if (name == "." || name == ".." || name == ".git" || name == ".hg" || name == ".svn" || name == "node_modules" || name == "build" || name == "out") continue;
				if (!entry.isDirectory || entry.path == null) continue;
				var full:String = cast entry.path;
				if (!within(root, full)) continue;
				var descendant:GitCandidate = {path: full, depth: candidate.depth + 1, parentId: parentIdFor(candidate, full)};
				candidates.push(descendant);
			}
			if (scanEntryCursor >= scanEntries.length) {
				scanDirectory = null;
				scanEntries = [];
			}
			return false;
		}
		return false;
	}

	public function cancel():Void {
		if (cancelled) return;
		cancelled = true;
		if (child != null) child.cancel();
		stopReader();
		for (handle in handles) handle.dispose();
		handles.resize(0);
	}

	function startRun(arguments:Array<String>, cwd:String):Void {
		var command = git.run(arguments, cwd, generation, function(result) {
			child = null;
			commandResult = cast result;
		}, true, true, 64 * 1024);
		child = cast command;
	}

	function metadata(bytes:Bytes, cwd:String):GitMetadata {
		var lines = bytes.toString().split("\n");
		while (lines.length > 0 && lines[lines.length - 1] == "") lines.pop();
		if (lines.length < 3) throw "Git returned incomplete repository metadata";
		for (index in 0...lines.length) if (StringTools.endsWith(lines[index], "\r")) lines[index] = lines[index].substr(0, lines[index].length - 1);
		var repoRoot = pathFrom(cwd, lines[0]), gitDir = pathFrom(cwd, lines[1]), commonDir = pathFrom(cwd, lines[2]);
		var superproject = lines.length >= 4 && lines[3].length > 0 ? pathFrom(cwd, lines[3]) : null;
		return {root: repoRoot, gitDir: gitDir, commonDir: commonDir, superproject: superproject};
	}

	function pathFrom(cwd:String, path:String):String {
		if (path == null || path.length == 0 || path.indexOf("\n") >= 0 || path.indexOf("\r") >= 0) throw "Git returned an invalid repository path";
		var normalized = StringTools.replace(path, "\\", "/");
		if (!isAbsolute(normalized)) normalized = cwd + "/" + normalized;
		return GitScmProvider.normalize(normalized);
	}

	function addRepository(info:GitMetadata, parentId:Null<String>, forcedKind:Null<ScmRepositoryKind>):Void {
		var key = normalizeKey(info.root);
		if (seenRepositories.exists(key)) return;
		seenRepositories.set(key, true);
		var kind:ScmRepositoryKind = forcedKind;
		if (kind == null) kind = info.superproject != null ? ScmRepositoryKind.Submodule
			: info.gitDir != info.commonDir ? ScmRepositoryKind.LinkedWorktree : ScmRepositoryKind.Nested;
		var id = "git:" + key;
		var repository = new GitScmRepositoryHandle(id, info.root, info.gitDir, info.commonDir, processes, scheduler,
			git, trustStore, untrackedLimit, kind, parentId);
		handles.push(repository);
	}

	function parentIdFor(candidate:GitCandidate, childPath:String):Null<String> {
		var best:Null<ScmRepositoryHandle> = null;
		for (handle in handles) {
			if (within(handle.repository().root, childPath)
				&& (best == null || handle.repository().root.length > best.repository().root.length)) best = handle;
		}
		return best == null ? candidate.parentId : best.repository().id;
	}

	function within(parent:String, child:String):Bool {
		var prefix = StringTools.endsWith(parent, "/") ? parent : parent + "/";
		var parentKey = normalizeKey(parent), childKey = normalizeKey(child);
		return childKey == parentKey || StringTools.startsWith(childKey, normalizeKey(prefix));
	}

	function finish(value:Null<Array<ScmRepositoryHandle>>, error:Null<ScmError>):Bool {
		stopReader();
		if (job.finish()) complete(new ScmJobResult<Array<ScmRepositoryHandle>>(generation, value, error));
		return true;
	}

	function requestDirectoryRead(path:String):Void {
		readState.acquire();
		readerPath = path;
		readState.release();
		directoryReadPending = true;
		if (!readerStarted && !readerUnavailable) {
			try {
				haxeon.Threads.create("exo.git.reader", directoryReaderLoop);
				readerStarted = true;
			} catch (failure:Dynamic) {
				readerUnavailable = true;
				readState.acquire();
				readerError = "Could not start the Git directory scan worker: " + Std.string(failure);
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
			var stop = readerStopped, path = readerPath;
			readState.release();
			if (stop) return;

			var result:Null<GitScanResult> = null, error:Null<String> = null;
			try {
				var identity = normalizeScannedPath(FileSystem.fullPath(path));
				var filesystemEntries:Array<FileSystemEntry> = FileSystem.readDirectoryEntries(path);
				filesystemEntries.sort(function(left, right) return Reflect.compare(left.name, right.name));
				var entries:Array<GitScanEntry> = [], hasGitMarker = false;
				for (entry in filesystemEntries) {
					if (entry.name == ".git") hasGitMarker = true;
					var childPath:Null<String> = entry.isDirectory ? normalizeScannedPath(FileSystem.fullPath(path + "/" + entry.name)) : null;
					entries.push({name: entry.name, isDirectory: entry.isDirectory, path: childPath});
				}
				result = {identity: identity, entries: entries, hasGitMarker: hasGitMarker};
			} catch (failure:Dynamic) error = Std.string(failure);
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

	static function normalizeScannedPath(path:String):String {
		var value = StringTools.replace(path, "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function normalizeKey(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/");
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	static function isAbsolute(path:String):Bool
		return StringTools.startsWith(path, "/") || (path.length >= 3 && path.charAt(1) == ":" && path.charAt(2) == "/");
}
