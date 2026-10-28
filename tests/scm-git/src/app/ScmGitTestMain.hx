package app;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.Int64;
import haxeon.wire.MessagePack;
import scm.ScmApplyResult;
import scm.ScmBlob;
import scm.ScmChangeKind;
import scm.ScmConflictKind;
import scm.ScmFeatures;
import scm.ScmGroupId;
import scm.ScmHeadOperation;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.LineDiff;
import scm.LineDiffHunk;
import scm.LineDiffKind;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmRepositoryHandle;
import scm.ScmRepositoryKind;
import scm.ScmSnapshot;
import scm.ScmHead;
import jobs.JobScheduler;
import scm.fake.FakeScmProvider;
import scm.fake.FakeScmRepositoryScript;
import scm.git.GitStatusParser;
import scm.git.GitBranchParser;
import scm.git.GitProcess;
import scm.git.GitScopedCommit;
import scm.git.GitBlobReader;
import scm.git.GitScmProvider;
import scm.git.GitVersion;
import scm.ScmTrustStore;
import scm.ScmService;
import workspace.service.WorkspaceScmSnapshotCodec;
import workspace.service.WorkspaceScmProtocol.ScmSnapshotResult;
import process.ProcessManager;
import sys.FileSystem;
import sys.io.File;

class ScmGitTestMain {
	static var lastMaxDiffSliceMillis:Float = 0;

	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	/** Where fixtures go: outside the working directory, which may itself be a Git work tree. */
	static function systemTemporaryDirectory():String {
		for (name in ["TEMP", "TMP", "TMPDIR"]) {
			var value = Sys.getEnv(name);
			if (value != null && value.length > 0) return value;
		}
		return Sys.systemName() == "Windows" ? Sys.getCwd() : "/tmp";
	}

	/** The full path of a file or directory not made yet: fullPath resolves only existing paths on POSIX, so the parent is resolved. */
	static function newPath(path:String):String {
		var full = FileSystem.fullPath(path);
		if (full != null) return full;
		var slash = Std.int(Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\")));
		var parent = slash > 0 ? FileSystem.fullPath(path.substr(0, slash)) : null;
		if (parent == null) throw "Cannot resolve the parent of " + path;
		return parent + path.substr(slash);
	}

	static function normalizeLineEndings(value:String):String
		return StringTools.replace(StringTools.replace(value, "\r\n", "\n"), "\r", "\n");

	static function pump(scheduler:JobScheduler, complete:Void->Bool, message:String, timeout:Float = 10.0):Void {
		var deadline = Sys.time() + timeout;
		while (!complete() && Sys.time() < deadline) { scheduler.update(32); Sys.sleep(0.001); }
		require(complete(), message);
	}

	static function pumpService(service:ScmService, scheduler:JobScheduler, complete:Void->Bool, message:String,
			timeout:Float = 10.0):Void {
		var deadline = Sys.time() + timeout;
		while (!complete() && Sys.time() < deadline) {
			service.update(Sys.time());
			scheduler.update(32);
			Sys.sleep(0.001);
		}
		require(complete(), message);
	}

	static function runGit(git:GitProcess, scheduler:JobScheduler, arguments:Array<String>, cwd:String, generation:Int,
			readOnly:Bool = false):scm.git.GitCommandResult {
		var result = runGitResult(git, scheduler, arguments, cwd, generation, readOnly);
		if (result.error != null || result.value == null)
			throw "Git fixture command failed: " + (result.error == null ? arguments.join(" ") : result.error.message);
		return result.value;
	}

	static function runGitResult(git:GitProcess, scheduler:JobScheduler, arguments:Array<String>, cwd:String, generation:Int,
			readOnly:Bool = false):ScmJobResult<scm.git.GitCommandResult> {
		var result:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(arguments, cwd, generation, value -> result = value, readOnly);
		pump(scheduler, () -> result != null, "Git fixture command timed out: " + arguments.join(" "));
		if (result == null) throw "Git fixture command returned no result: " + arguments.join(" ");
		return result;
	}

	static function applyOperation(handle:ScmRepositoryHandle, scheduler:JobScheduler, operation:ScmOperation,
			generation:Int):ScmJobResult<ScmApplyResult> {
		var result:Null<ScmJobResult<ScmApplyResult>> = null;
		handle.apply(operation, generation, value -> result = value);
		pump(scheduler, () -> result != null, "Git SCM operation timed out: " + Std.string(operation));
		if (result == null) throw "Git SCM operation returned no result: " + Std.string(operation);
		return result;
	}

	/** Runs a folder-scoped commit of `sub/` directly, with `afterCheck` racing it between the check and the commit. */
	static function scopedCommit(git:GitProcess, scheduler:JobScheduler, root:String, generation:Int, message:String, amend:Bool,
			?afterCheck:Void->Void):Null<scm.ScmError> {
		var failure:Null<scm.ScmError> = null, finished = false;
		new GitScopedCommit(git, root, generation, message, amend, ["sub/"], false, function(_, error) { failure = error; finished = true; },
			afterCheck).start();
		pump(scheduler, () -> finished, "a folder-scoped commit did not finish");
		return failure;
	}

	static function deleteTree(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path)) deleteTree(path + "/" + name);
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}

	static function normalizeNewlines(value:String):String return StringTools.replace(value, "\r\n", "\n");

	static function shellQuote(value:String):String
		return "'" + StringTools.replace(value, "'", "'\\''") + "'";

	static function markerCommand(directory:String, name:String, marker:String, consumeInput:Bool):String {
		var markerPath = marker, scriptPath = directory + "/" + name;
		scriptPath += ".sh";
		var content = "#!/bin/sh\nprintf 'ran\\n' >> " + shellQuote(markerPath) + "\n";
		if (consumeInput) content += "cat >/dev/null\n";
		if (name == "fsmonitor-hook") content += "printf 'token\\0marked.txt\\0'\n";
		else content += "printf 'token\\n'\n";
		File.saveContent(scriptPath, content);
		return "sh " + shellQuote(scriptPath);
	}

	static function readBlob(reader:GitBlobReader, scheduler:JobScheduler, reference:String, path:Bytes, generation:Int):ScmJobResult<ScmBlob> {
		var result:Null<ScmJobResult<ScmBlob>> = null;
		var job = reader.read(reference, path, generation, value -> result = value);
		pump(scheduler, () -> result != null, "Git blob request timed out");
		if (result == null) throw "Git blob result disappeared";
		require(job.complete, "Git blob job did not finish before its result callback");
		return result;
	}

	static function readBlobObject(reader:GitBlobReader, scheduler:JobScheduler, object:String, generation:Int):ScmJobResult<ScmBlob> {
		var result:Null<ScmJobResult<ScmBlob>> = null;
		var job = reader.readObject(object, generation, value -> result = value);
		pump(scheduler, () -> result != null, "Git object blob request timed out");
		if (result == null) throw "Git object blob result disappeared";
		require(job.complete, "Git object blob job did not finish before its result callback");
		return result;
	}

	static function record(bytes:BytesBuffer, value:String):Void {
		bytes.addString(value);
		bytes.addByte(0);
	}

	static function group(result:scm.git.GitStatusParseResult, id:ScmGroupId):Array<scm.ScmResource> {
		for (value in result.groups) if (value.id == id) return value.resources;
		return [];
	}

	static function snapshotGroup(snapshot:ScmSnapshot, id:ScmGroupId):Null<scm.ScmGroup> {
		for (value in snapshot.groups) if (value.id == id) return value;
		return null;
	}

	static function runDiff(oldText:String, newText:String, maxCost:Int = LineDiff.DEFAULT_MAX_COST, sliceCost:Int = LineDiff.DEFAULT_SLICE_COST):Array<LineDiffHunk> {
		var result:Null<Array<LineDiffHunk>> = null, task = new LineDiff(oldText, newText, value -> result = value, maxCost, sliceCost),
			scheduler = new JobScheduler(), maxSliceMillis = 0.0;
		scheduler.schedule(task);
		var steps = 0;
		while (scheduler.activeCount() > 0 && steps < 100000) {
			var sliceStarted = Sys.time();
			scheduler.update(1);
			var elapsed = (Sys.time() - sliceStarted) * 1000.0;
			if (elapsed > maxSliceMillis) maxSliceMillis = elapsed;
			steps++;
		}
		lastMaxDiffSliceMillis = maxSliceMillis;
		require(task.finished && result != null && steps < 100000, "line diff did not finish as a scheduled job");
		return result;
	}

	static function validateOpenDocumentMarkers():Void {
		var base = "one\ntwo\nthree\n";
		var resource = new scm.ScmResource(Bytes.ofString("Fixture.hx"), ScmChangeKind.Modified);
		var head = new ScmHead("main", null, false, null, 0, 0, false, ScmHeadOperation.None);
		var snapshot = new ScmSnapshot(Int64.ofInt(1), head,
			[new scm.ScmGroup(ScmGroupId.WorkingTree, [resource])]);
		var repository = new ScmRepository("open-document", "fake", "/fixture");
		var source = new ScmOpenDocumentMarkerTestSource(repository, snapshot, new ScmBlob(Bytes.ofString(base), false));
		var document = new editor.Document(null, base, new syntax.SyntaxRegistry(), null, null, "Fixture.hx");
		var registry = new plugin.PluginGutterMarkerRegistry(), scheduler = new JobScheduler();
		var tracker = new scm.ScmOpenDocumentMarkers(source, repository.id, Bytes.ofString("Fixture.hx"), document,
			"scm-open-test", registry, scheduler, 1024, function() {});
		tracker.update(snapshot, true, false, Sys.time());
		scheduler.update(64);
		tracker.update(snapshot, true, false, Sys.time());
		scheduler.update(64);
		require(registry.forDocument(document).length == 0, "unchanged open document produced SCM gutter markers");

		var selection = new editor.BufferSelection();
		document.buffer.replaceAllText("one\nedited\nthree\n", selection);
		tracker.update(snapshot, true, false, Sys.time());
		scheduler.update(64);
		require(registry.forDocument(document).length == 0, "SCM gutter diff ignored its 100 ms edit debounce");
		Sys.sleep(0.12);
		tracker.update(snapshot, true, false, Sys.time());
		while (scheduler.activeCount() > 0) scheduler.update(64);
		var markers = registry.forDocument(document);
		require(markers.length == 1 && markers[0].kind == plugin.PluginGutterMarkerKind.Modified &&
			markers[0].startLine == 1 && markers[0].endLine == 1,
			"SCM gutter diff did not mark the edited line after its debounce");
		require(source.originalCalls == 1, "SCM document marker tracker refetched the same index baseline");

		document.buffer.undo(selection);
		var cleanSnapshot = new ScmSnapshot(Int64.ofInt(2), head, []);
		tracker.update(cleanSnapshot, false, false, Sys.time());
		require(registry.forDocument(document).length == 0, "undo did not remove SCM gutter markers");
		tracker.dispose();
		document.dispose();
	}

	static function encodeLines(lines:Array<String>, trailingNewline:Bool):String {
		var result = new StringBuf();
		for (index in 0...lines.length) {
			result.add(lines[index]);
			if (index < lines.length - 1 || trailingNewline) result.add("\n");
		}
		return result.toString();
	}

	static function reconstruct(oldText:String, newText:String, hunks:Array<LineDiffHunk>):String {
		var oldLines = LineDiff.splitLines(oldText), newLines = LineDiff.splitLines(newText), output:Array<String> = [], oldCursor = 0;
		for (hunk in hunks) {
			while (oldCursor < hunk.oldStart) output.push(oldLines[oldCursor++]);
			oldCursor += hunk.oldCount;
			for (index in hunk.newStart...(hunk.newStart + hunk.newCount)) output.push(newLines[index]);
		}
		while (oldCursor < oldLines.length) output.push(oldLines[oldCursor++]);
		return output.join("");
	}

	static var randomState:Int = 0x1234567;
	static function nextRandom(limit:Int):Int {
		randomState ^= randomState << 13;
		randomState ^= randomState >>> 17;
		randomState ^= randomState << 5;
		return (randomState & 0x7fffffff) % limit;
	}

	static function median(values:Array<Float>):Float {
		var sorted = values.copy();
		sorted.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
		return sorted[Std.int(sorted.length / 2)];
	}

	static function resourceCount(snapshot:ScmSnapshot):Int {
		var count = 0;
		for (group in snapshot.groups) count += group.resources.length;
		return count;
	}

	static function benchmarkRoot(label:String, root:String, blobPath:String):Void {
		var temporaryDirectory = systemTemporaryDirectory();
		var identity = Std.string(Std.int(Sys.time() * 1000000)) + "-" + Std.string(Std.random(1000000));
		var privateDirectory = newPath(temporaryDirectory + "/exosuit-scm-benchmark-" + identity),
			emptyHooks = privateDirectory + "/empty-hooks", trustPath = privateDirectory + "/trust.json";
		FileSystem.createDirectory(privateDirectory);
		FileSystem.createDirectory(emptyHooks);
		var scheduler = new JobScheduler(), processes = new ProcessManager(), git = new GitProcess(processes, scheduler, "", emptyHooks),
			versionResult:Null<ScmJobResult<GitVersion>> = null, versionStarted = Sys.time();
		git.probeVersion(1, value -> versionResult = value);
		pump(scheduler, () -> versionResult != null, "SCM benchmark Git version probe timed out", 30.0);
		if (versionResult == null || versionResult.value == null) throw "SCM benchmark requires Git 2.25 or newer";
		var gitVersion = versionResult.value;
		var versionProbeMillis = (Sys.time() - versionStarted) * 1000.0;
		var service = new ScmService(processes, scheduler, git.executable, 50000, 0, false, trustPath, emptyHooks),
			discovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		service.discover(root, value -> discovery = value);
		pumpService(service, scheduler, () -> discovery != null, 'SCM benchmark discovery timed out for "$label"', 60.0);
		if (discovery == null || discovery.error != null || discovery.value == null || discovery.value.length == 0)
			throw 'SCM benchmark root "$label" is not a Git repository: ' + (discovery == null || discovery.error == null ? "no repository" : discovery.error.message);
		var repository:Null<ScmRepository> = null;
		var fullRoot = StringTools.replace(FileSystem.fullPath(root), "\\", "/");
		while (StringTools.endsWith(fullRoot, "/") && fullRoot.length > 1) fullRoot = fullRoot.substr(0, fullRoot.length - 1);
		for (candidate in discovery.value) if (candidate.root == fullRoot) { repository = candidate; break; }
		if (repository == null) repository = discovery.value[0];
		var repositoryId = repository.id;
		service.refreshNow(repositoryId);
		var statusStarted = Sys.time(), maxFrameMillis = 0.0, maxServiceMillis = 0.0, maxSchedulerMillis = 0.0,
			deadline = statusStarted + 600.0;
		while (service.snapshot(repositoryId) == null && Sys.time() < deadline) {
			var frameStarted = Sys.time(), serviceStarted = frameStarted;
			service.update(Sys.time());
			var serviceMillis = (Sys.time() - serviceStarted) * 1000.0;
			if (serviceMillis > maxServiceMillis) maxServiceMillis = serviceMillis;
			var schedulerStarted = Sys.time();
			scheduler.update(32);
			var schedulerMillis = (Sys.time() - schedulerStarted) * 1000.0;
			if (schedulerMillis > maxSchedulerMillis) maxSchedulerMillis = schedulerMillis;
			var frameMillis = (Sys.time() - frameStarted) * 1000.0;
			if (frameMillis > maxFrameMillis) maxFrameMillis = frameMillis;
			Sys.sleep(0.001);
		}
		var snapshot = service.snapshot(repositoryId);
		if (snapshot == null) throw 'SCM benchmark status refresh timed out for "$label"';
		require(maxFrameMillis < 16.67,
			'SCM status refresh exceeded a 60 Hz frame slice for "$label": ${Std.string(maxFrameMillis)} ms');
		var statusMillis = (Sys.time() - statusStarted) * 1000.0, resourceTotal = resourceCount(snapshot);
		var changeNotifications = 0;
		var unlisten = service.subscribe(function(_, _) changeNotifications++);
		service.refreshNow(repositoryId);
		var unchangedStarted = Sys.time(), observedRefreshWork = false, maxUnchangedFrameMillis = 0.0,
			unchangedDeadline = unchangedStarted + 600.0;
		while (Sys.time() < unchangedDeadline) {
			var frameStarted = Sys.time();
			service.update(Sys.time());
			scheduler.update(32);
			var frameMillis = (Sys.time() - frameStarted) * 1000.0;
			if (frameMillis > maxUnchangedFrameMillis) maxUnchangedFrameMillis = frameMillis;
			if (processes.activeCount() > 0 || scheduler.activeCount() > 0) observedRefreshWork = true;
			if (observedRefreshWork && processes.activeCount() == 0 && scheduler.activeCount() == 0) break;
			Sys.sleep(0.001);
		}
		var unchangedStatusMillis = (Sys.time() - unchangedStarted) * 1000.0,
			unchangedSnapshot = service.snapshot(repositoryId);
		require(observedRefreshWork && unchangedSnapshot != null && unchangedSnapshot.revision == snapshot.revision
			&& changeNotifications == 0, "unchanged SCM refresh changed its revision or notified listeners");
		require(maxUnchangedFrameMillis < 16.67,
			'Unchanged SCM refresh exceeded a 60 Hz frame slice for "$label": ${Std.string(maxUnchangedFrameMillis)} ms');
		unlisten();

		// Include the same model-to-record conversion, MessagePack encoding and
		// decoding used by the agent RPC response and browser/desktop client.
		var wireBuildSamples:Array<Float> = [], encodeSamples:Array<Float> = [], decodeSamples:Array<Float> = [],
			modelBuildSamples:Array<Float> = [], wireBytes = 0;
		for (sample in 0...6) {
			var started = Sys.time(), wireSnapshot = WorkspaceScmSnapshotCodec.encode(snapshot);
			var wireBuildMillis = (Sys.time() - started) * 1000.0;
			started = Sys.time();
			var response:ScmSnapshotResult = {workspace: "benchmark", repository: repositoryId,
				snapshot: wireSnapshot, error: null};
			var encoded = MessagePack.encode(response), encodeMillis = (Sys.time() - started) * 1000.0;
			started = Sys.time();
			var decoded:ScmSnapshotResult = MessagePack.decode(encoded), decodeMillis = (Sys.time() - started) * 1000.0;
			started = Sys.time();
			var decodedModel = WorkspaceScmSnapshotCodec.decode(decoded.snapshot);
			var modelBuildMillis = (Sys.time() - started) * 1000.0;
			require(resourceCount(decodedModel) == resourceTotal && decodedModel.revision == snapshot.revision,
				"SCM benchmark wire round-trip changed the snapshot");
			if (sample > 0) {
				wireBuildSamples.push(wireBuildMillis);
				encodeSamples.push(encodeMillis);
				decodeSamples.push(decodeMillis);
				modelBuildSamples.push(modelBuildMillis);
			}
			wireBytes = encoded.length;
		}

		var processStarted = Sys.time(), batchProcess = git.startBlobBatch(root, false),
			batchSpawnMillis = (Sys.time() - processStarted) * 1000.0;
		batchProcess.cancel();
		processes.release(batchProcess);
		var blobReader = new GitBlobReader(processes, scheduler, git, root, false, 1024 * 1024),
			blobStarted = Sys.time(), firstBlob = readBlob(blobReader, scheduler, "HEAD", Bytes.ofString(blobPath), 2),
			coldBlobMillis = (Sys.time() - blobStarted) * 1000.0;
		if (firstBlob.error != null || firstBlob.value == null) throw 'SCM benchmark could not read HEAD:$blobPath in "$label"';
		var warmBlobSamples:Array<Float> = [];
		for (index in 0...30) {
			blobStarted = Sys.time();
			var repeated = readBlob(blobReader, scheduler, "HEAD", Bytes.ofString(blobPath), 3 + index);
			warmBlobSamples.push((Sys.time() - blobStarted) * 1000.0);
			if (repeated.error != null || repeated.value == null) throw 'SCM benchmark warm blob read failed for "$label"';
		}
		var activeBatch = blobReader.activeProcessId();
		blobReader.dispose();
		service.dispose();
		processes.shutdown();
		deleteTree(privateDirectory);
		Sys.println('SCM_BENCH label=$label git_version=$gitVersion resources=$resourceTotal truncated=${snapshot.truncated}'
			+ ' status_ms=${Std.string(statusMillis)} max_frame_ms=${Std.string(maxFrameMillis)}'
			+ ' unchanged_status_ms=${Std.string(unchangedStatusMillis)} max_unchanged_frame_ms=${Std.string(maxUnchangedFrameMillis)}'
			+ ' unchanged_notifications=$changeNotifications'
			+ ' max_service_update_ms=${Std.string(maxServiceMillis)} max_scheduler_update_ms=${Std.string(maxSchedulerMillis)}'
			+ ' wire_build_median_ms=${Std.string(median(wireBuildSamples))} messagepack_encode_median_ms=${Std.string(median(encodeSamples))}'
			+ ' messagepack_decode_median_ms=${Std.string(median(decodeSamples))} model_build_median_ms=${Std.string(median(modelBuildSamples))}'
			+ ' wire_bytes=$wireBytes git_batch_spawn_ms=${Std.string(batchSpawnMillis)} cold_blob_ms=${Std.string(coldBlobMillis)}'
			+ ' warm_blob_median_ms=${Std.string(median(warmBlobSamples))} warm_blob_max_ms=${Std.string(maximum(warmBlobSamples))}'
			+ ' active_batch_id=$activeBatch');
	}

	static function maximum(values:Array<Float>):Float {
		var result = 0.0;
		for (value in values) if (value > result) result = value;
		return result;
	}

	static function benchmark(args:Array<String>):Int {
		if (args.length < 4 || (args.length - 1) % 3 != 0)
			throw "Usage: --scm-benchmark <label> <repository-root> <committed-blob-path> [<label> <root> <blob-path> ...]";
		var index = 1;
		while (index < args.length) {
			benchmarkRoot(args[index], args[index + 1], args[index + 2]);
			index += 3;
		}
		return 0;
	}

	static function main():Int {
		var arguments = Sys.args();
		if (arguments.length > 0 && arguments[0] == "--scm-benchmark") return benchmark(arguments);
		validateOpenDocumentMarkers();
		var bytes = new BytesBuffer();
		record(bytes, "# branch.oid abc123");
		record(bytes, "# branch.head feature/test");
		record(bytes, "# branch.upstream origin/feature/test");
		record(bytes, "# branch.ab +2 -1");
		record(bytes, "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb staged file.txt");
		record(bytes, "2 .R S..U 160000 160000 160000 aaaaaaa bbbbbbb R100 renamed file.txt");
		record(bytes, "old file.txt");
		record(bytes, "2 C. N... 100644 100644 100644 aaaaaaa bbbbbbb C80 copied file.txt");
		record(bytes, "copy source.txt");
		record(bytes, "? name with\nnewline.txt");
		record(bytes, "! ignored name");
		record(bytes, "? -leading.txt");
		bytes.addString("? invalid-");
		bytes.addByte(0xff);
		bytes.addString(".txt");
		bytes.addByte(0);
		for (xy in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"])
			record(bytes, 'u $xy N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc conflict-$xy.txt');
		var parsed = GitStatusParser.parse(bytes.getBytes(), true, ScmHeadOperation.Rebase);
		require(parsed.head.branch == "feature/test" && !parsed.head.unborn && parsed.head.upstream == "origin/feature/test"
			&& parsed.head.ahead == 2 && parsed.head.behind == 1 && parsed.head.upstreamGone
			&& parsed.head.operation == ScmHeadOperation.Rebase, "branch headers were not parsed");
		require(group(parsed, ScmGroupId.Index).length == 2 && group(parsed, ScmGroupId.Index)[0].path == "staged file.txt"
			&& group(parsed, ScmGroupId.Index)[0].changeKind == ScmChangeKind.Modified, "ordinary staged record was not parsed");
		var renamed = group(parsed, ScmGroupId.WorkingTree)[0];
		require(renamed.path == "renamed file.txt" && renamed.originalPath == "old file.txt" && renamed.renameScore == 100
			&& renamed.submoduleStatus == "S..U", "rename, score or submodule state was not retained");
		var copied = group(parsed, ScmGroupId.Index)[1];
		require(copied.path == "copied file.txt" && copied.originalPath == "copy source.txt" && copied.changeKind == ScmChangeKind.Copied
			&& copied.renameScore == 80, "copy record was not parsed");
		require(group(parsed, ScmGroupId.Untracked).length == 3
			&& group(parsed, ScmGroupId.Untracked)[0].path == "name with\\nnewline.txt"
			&& group(parsed, ScmGroupId.Untracked)[1].path == "-leading.txt", "newline or leading dash path was not handled");
		require(group(parsed, ScmGroupId.Untracked)[2].pathBytes.get(8) == 0xff
			&& group(parsed, ScmGroupId.Untracked)[2].path.indexOf("\\xff") >= 0, "non-UTF-8 filename bytes were lost or unsafe to display");
		require(parsed.ignored.length == 1 && parsed.ignored[0].path == "ignored name", "ignored status entry was not recognized");
		var conflicts = group(parsed, ScmGroupId.Merge);
		require(conflicts.length == 7, "not all unmerged records were parsed");
		var expected:Array<ScmConflictKind> = [ScmConflictKind.BothDeleted, ScmConflictKind.AddedByUs, ScmConflictKind.DeletedByThem,
			ScmConflictKind.AddedByThem, ScmConflictKind.DeletedByUs, ScmConflictKind.BothAdded, ScmConflictKind.BothModified];
		for (index in 0...expected.length) require(conflicts[index].conflictKind == expected[index], 'wrong conflict kind for ${conflicts[index].path}');
		var unbornBytes = new BytesBuffer();
		record(unbornBytes, "# branch.oid (initial)"); record(unbornBytes, "# branch.head main");
		var unborn = GitStatusParser.parse(unbornBytes.getBytes());
		require(unborn.head.unborn && unborn.head.branch == "main" && unborn.head.detachedCommit == null, "unborn branch was not represented");
		var detachedBytes = new BytesBuffer();
		record(detachedBytes, "# branch.oid deadbeef"); record(detachedBytes, "# branch.head (detached)");
		var detached = GitStatusParser.parse(detachedBytes.getBytes());
		require(detached.head.detachedCommit == "deadbeef" && detached.head.branch == null, "detached HEAD was not represented");
		var noUpstreamBytes = new BytesBuffer();
		record(noUpstreamBytes, "# branch.oid deadbeef"); record(noUpstreamBytes, "# branch.head main");
		var noUpstream = GitStatusParser.parse(noUpstreamBytes.getBytes());
		require(noUpstream.head.upstream == null && noUpstream.head.ahead == 0 && noUpstream.head.behind == 0, "missing upstream was not represented");
		var malformed = false;
		var malformedBytes = Bytes.ofString("1 M. N... truncated");
		var malformedNul = new BytesBuffer(); malformedNul.add(malformedBytes); malformedNul.addByte(0);
		try GitStatusParser.parse(malformedNul.getBytes()) catch (_:Dynamic) malformed = true;
		require(malformed, "malformed porcelain record was silently accepted");

		var repository = new ScmRepository("repo", "git", "C:/project/worktree", ScmRepositoryKind.LinkedWorktree, "parent"),
			features = new ScmFeatures(true, true, true, true, true, false),
			snapshot = new ScmSnapshot(Int64.make(1, 2), parsed.head, parsed.groups, true);
		require(repository.kind == ScmRepositoryKind.LinkedWorktree && repository.parentId == "parent"
			&& features.staging && features.partialStaging && features.amend && features.branches && features.remotes && !features.stash,
			"repository or feature model lost declared capabilities");
		require(snapshot.revision == Int64.make(1, 2) && snapshot.truncated && snapshot.groups[0].id == ScmGroupId.Merge,
			"snapshot revision, truncation or group ordering was not retained");
		var cancelCalled = false, job = new ScmJob<String>(19, function() cancelCalled = true);
		var jobResult = new ScmJobResult<String>(job.generation, null, new scm.ScmError("untrusted", "Trust this repository locally"));
		var jobError = jobResult.error;
		require(job.cancel() && cancelCalled && job.cancelled && jobResult.generation == 19 && jobError != null && jobError.code == "untrusted"
			&& !job.finish(), "generation-aware cancellable job state was inconsistent");
		var blob = new ScmBlob(Bytes.ofString("text"), false), applyResult = new ScmApplyResult(snapshot, "applied");
		var operation:ScmOperation = ScmOperation.Commit("message", true), reference:ScmRef = ScmRef.ConflictStage(3);
		var amend = false, stage = 0;
		switch operation { case Commit(_, value): amend = value; default: }
		switch reference { case ConflictStage(value): stage = value; default: }
		require(blob.bytes.toString() == "text" && !blob.binary && applyResult.snapshot == snapshot && applyResult.message == "applied"
			&& amend && stage == 3, "blob, apply result or operation/reference model was incomplete");
		var groupResources = [new scm.ScmResource(Bytes.ofString("path"), ScmChangeKind.Modified)],
			orderedSnapshot = new ScmSnapshot(Int64.ofInt(1), parsed.head, [
				new scm.ScmGroup(ScmGroupId.Untracked, groupResources), new scm.ScmGroup(ScmGroupId.WorkingTree, groupResources),
				new scm.ScmGroup(ScmGroupId.Index, groupResources), new scm.ScmGroup(ScmGroupId.Merge, groupResources)]);
		require(orderedSnapshot.groups[0].id == ScmGroupId.Merge && orderedSnapshot.groups[1].id == ScmGroupId.Index
			&& orderedSnapshot.groups[2].id == ScmGroupId.WorkingTree && orderedSnapshot.groups[3].id == ScmGroupId.Untracked,
			"snapshot did not canonicalize source control group ordering");
		var parsedBranches = GitBranchParser.parse(Bytes.ofString(
			"refs/heads/main\t*\t\nrefs/remotes/origin/main\t\t\nrefs/remotes/origin/HEAD\t\trefs/remotes/origin/main\n"));
		require(parsedBranches.length == 2 && parsedBranches[0].current && !parsedBranches[0].remote
			&& parsedBranches[1].remote && parsedBranches[1].name == "origin/main",
			"Git branch parser lost local/remote branch details or kept a symbolic remote HEAD");
		var fakeScheduler = new JobScheduler(), fake = new FakeScmProvider(fakeScheduler), script = new FakeScmRepositoryScript(
			new ScmRepository("fixture", "fake", "/fixture"), new ScmFeatures(true, false, true, false, false), [orderedSnapshot], 2);
		fake.add(script);
		var detectResult:Null<ScmJobResult<Array<scm.ScmRepositoryHandle>>> = null;
		var detectJob = fake.detect("/fixture", 41, value -> detectResult = value);
		require(detectJob.generation == 41 && detectResult == null, "fake discovery did not remain asynchronous");
		fakeScheduler.update(1);
		var detection = detectResult;
		if (detection == null || detection.value == null) throw "fake provider did not return a repository handle";
		require(detection.generation == 41 && detection.error == null && detection.value.length == 1,
			"fake provider did not return a generation-stamped repository handle");
		var fakeHandle = detection.value[0], refreshResult:Null<ScmJobResult<ScmSnapshot>> = null;
		var refreshJob = fakeHandle.refresh(42, value -> refreshResult = value);
		fakeScheduler.update(1); fakeScheduler.update(1);
		require(refreshResult == null, "fake provider ignored scripted latency");
		fakeScheduler.update(1);
		var refreshed = refreshResult;
		if (refreshed == null || refreshed.value == null) throw "fake provider refresh did not return a snapshot";
		require(refreshed.generation == 42 && refreshed.value.groups[0].id == ScmGroupId.Merge,
			"fake provider refresh lost its generation or ordered groups");
		var cancelledCallback = false, cancelledJob = fakeHandle.refresh(43, _ -> cancelledCallback = true);
		require(cancelledJob.cancel(), "fake operation refused cancellation");
		fakeScheduler.update(8);
		require(cancelledJob.cancelled && !cancelledCallback, "cancelled fake operation published a stale result");
		require(scm.ScmOperationAvailability.supports(script.features, ScmOperation.Stage("path"))
			&& scm.ScmOperationAvailability.supports(script.features, ScmOperation.Commit("message", false))
			&& !scm.ScmOperationAvailability.supports(script.features, ScmOperation.StagePatch("path", Bytes.alloc(0)))
			&& !scm.ScmOperationAvailability.supports(script.features, ScmOperation.Checkout("main"))
			&& !scm.ScmOperationAvailability.supports(script.features, ScmOperation.Push),
			"operation availability did not follow provider feature flags");
		fakeHandle.dispose();
		var gitScheduler = new JobScheduler(), processManager = new ProcessManager(), git = new GitProcess(processManager, gitScheduler, ""),
			versionResult:Null<ScmJobResult<GitVersion>> = null;
		var versionJob = git.probeVersion(51, value -> versionResult = value), deadline = Sys.time() + 10.0;
		while (gitScheduler.activeCount() > 0 && Sys.time() < deadline) { gitScheduler.update(32); Sys.sleep(0.001); }
		var checkedVersion = versionResult;
		if (checkedVersion == null || checkedVersion.value == null) throw "Git version probe did not complete";
		require(versionJob.complete && checkedVersion.generation == 51 && checkedVersion.error == null
			&& checkedVersion.value.supportsScm() && git.executable != null, "Git discovery or minimum-version probe failed");
		require(!GitVersion.parse("git version 2.24.9").supportsScm() && GitVersion.parse("git version 2.25").supportsScm(),
			"Git minimum-version boundary was incorrect");
		var boundedResult:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["--version"], "", 52, value -> boundedResult = value, false, false, 1);
		deadline = Sys.time() + 10.0;
		while (gitScheduler.activeCount() > 0 && Sys.time() < deadline) { gitScheduler.update(32); Sys.sleep(0.001); }
		if (boundedResult == null || boundedResult.error == null) throw "Git stdout limit did not produce an error";
		require(boundedResult.error.code == "output_too_large", "Git stdout limit returned the wrong error code");
		var temporaryDirectory = systemTemporaryDirectory();
		var fixtureId = Std.string(Std.int((Sys.time() * 1000) % 1000000000)) + "-" + Std.string(Std.random(1000000));
		var fixtureBase = newPath(temporaryDirectory + "/exosuit-scm-discovery-" + fixtureId),
			discoveryRoot = fixtureBase + "/project", nestedRoot = discoveryRoot + "/nested", emptyHooks = fixtureBase + "/empty-hooks";
		FileSystem.createDirectory(fixtureBase);
		FileSystem.createDirectory(discoveryRoot);
		FileSystem.createDirectory(nestedRoot);
		FileSystem.createDirectory(emptyHooks);
		runGit(git, gitScheduler, ["init"], discoveryRoot, 70);
		runGit(git, gitScheduler, ["init"], nestedRoot, 71);
		File.saveContent(discoveryRoot + "/one.txt", "one");
		File.saveContent(discoveryRoot + "/two.txt", "two");
		File.saveContent(discoveryRoot + "/filtered.txt", "before filter\n");
		File.saveContent(discoveryRoot + "/marked.txt", "before marker\n");
		runGit(git, gitScheduler, ["add", "filtered.txt"], discoveryRoot, 711);
		runGit(git, gitScheduler, ["add", "marked.txt"], discoveryRoot, 710);
		File.saveContent(discoveryRoot + "/.gitattributes", "filtered.txt filter=unsafe\nmarked.txt filter=marker\n");
		runGit(git, gitScheduler, ["add", ".gitattributes"], discoveryRoot, 712);
		runGit(git, gitScheduler, ["config", "filter.unsafe.clean", "exosuite-missing-filter-command"], discoveryRoot, 713);
		runGit(git, gitScheduler, ["config", "filter.unsafe.smudge", "cat"], discoveryRoot, 714);
		runGit(git, gitScheduler, ["config", "filter.unsafe.required", "true"], discoveryRoot, 715);
		var fsmonitorMarker = fixtureBase + "/fsmonitor-ran", cleanMarker = fixtureBase + "/clean-ran",
			smudgeMarker = fixtureBase + "/smudge-ran";
		var fsmonitorCommand = markerCommand(fixtureBase, "fsmonitor-hook", fsmonitorMarker, false),
			cleanCommand = markerCommand(fixtureBase, "clean-filter", cleanMarker, true),
			smudgeCommand = markerCommand(fixtureBase, "smudge-filter", smudgeMarker, true);
		runGit(git, gitScheduler, ["config", "core.fsmonitor", fsmonitorCommand], discoveryRoot, 716);
		runGit(git, gitScheduler, ["config", "core.fsmonitorHookVersion", "2"], discoveryRoot, 726);
		runGit(git, gitScheduler, ["config", "filter.marker.clean", cleanCommand], discoveryRoot, 717);
		runGit(git, gitScheduler, ["config", "filter.marker.smudge", smudgeCommand], discoveryRoot, 718);
		runGit(git, gitScheduler, ["config", "filter.marker.required", "true"], discoveryRoot, 719);
		File.saveContent(discoveryRoot + "/marked.txt", "after marker\n");
		File.saveContent(discoveryRoot + "/filtered.txt", "after filter\n");
		var trustStore = new ScmTrustStore(fixtureBase + "/trust.json"),
			provider = new GitScmProvider(processManager, gitScheduler, git.executable, emptyHooks, trustStore, 1, 2),
			discovered:Null<ScmJobResult<Array<ScmRepositoryHandle>>> = null;
		var discoveryJob = provider.detect(discoveryRoot, 72, value -> discovered = value);
		pump(gitScheduler, () -> discovered != null, "Git repository discovery timed out");
		if (discovered == null || discovered.value == null) throw "Git repository discovery returned no handle list";
		require(discoveryJob.complete && discovered.error == null && discovered.value.length == 2,
			"Git discovery did not find the root and nested repositories");
		var rootHandle:Null<ScmRepositoryHandle> = null, nestedHandle:Null<ScmRepositoryHandle> = null;
		for (handle in discovered.value) {
			if (handle.repository().root == StringTools.replace(FileSystem.fullPath(discoveryRoot), "\\", "/")) rootHandle = handle;
			if (handle.repository().root == StringTools.replace(FileSystem.fullPath(nestedRoot), "\\", "/")) nestedHandle = handle;
		}
		if (rootHandle == null || nestedHandle == null) throw "Git discovery lost a repository root";
		require(rootHandle.repository().kind == scm.ScmRepositoryKind.Worktree && !rootHandle.repository().trusted
			&& nestedHandle.repository().kind == scm.ScmRepositoryKind.Nested && nestedHandle.repository().parentId == rootHandle.repository().id,
			"Git discovery lost root kind, nested kind, trust default or parent relation: root=" + rootHandle.repository().kind
				+ ", trusted=" + rootHandle.repository().trusted + ", nested=" + nestedHandle.repository().kind
				+ ", parent=" + Std.string(nestedHandle.repository().parentId) + ", expected=" + rootHandle.repository().id);
		var normalFilterConversion:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["hash-object", "--path=filtered.txt", "filtered.txt"], discoveryRoot, 721,
			value -> normalFilterConversion = value, true, false);
		pump(gitScheduler, () -> normalFilterConversion != null, "Unrestricted Git filter fixture timed out");
		require(normalFilterConversion != null && normalFilterConversion.error != null,
			"Git filter fixture did not invoke the configured clean filter");
		var restrictedFilterGit = new GitProcess(processManager, gitScheduler, git.executable, emptyHooks),
			disabledFilterConversion:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		restrictedFilterGit.run(["hash-object", "--path=filtered.txt", "filtered.txt"], discoveryRoot, 722,
			value -> disabledFilterConversion = value, true, true, GitProcess.DEFAULT_MAX_STDOUT, ["unsafe"]);
		pump(gitScheduler, () -> disabledFilterConversion != null, "Restricted Git filter fixture timed out");
		require(disabledFilterConversion != null && disabledFilterConversion.error == null && disabledFilterConversion.value != null,
			"restricted Git did not disable the configured external clean filter");
		var firstSnapshot:Null<ScmJobResult<ScmSnapshot>> = null;
		rootHandle.refresh(73, value -> firstSnapshot = value);
		pump(gitScheduler, () -> firstSnapshot != null, "Git status refresh timed out");
		if (firstSnapshot == null || firstSnapshot.value == null) throw "Git status refresh returned no snapshot";
		var firstSnapshotValue:ScmSnapshot = cast firstSnapshot.value;
		var untrackedGroup = snapshotGroup(firstSnapshotValue, ScmGroupId.Untracked);
		require(firstSnapshot.error == null && firstSnapshotValue.truncated
			&& untrackedGroup != null && untrackedGroup.resources.length == 1
			&& snapshotGroup(firstSnapshotValue, ScmGroupId.WorkingTree) != null,
			"Git untracked limit did not mark a truncated status snapshot");
		require(firstSnapshotValue.head.unborn, "Git status lost the unborn repository state");
		require(!FileSystem.exists(fsmonitorMarker) && !FileSystem.exists(cleanMarker) && !FileSystem.exists(smudgeMarker),
			"restricted Git status or original-content setup ran an fsmonitor or filter command");
		var restrictedMutation = applyOperation(rootHandle, gitScheduler, ScmOperation.Stage("one.txt"), 730);
		require(restrictedMutation.error != null && restrictedMutation.error.code == "untrusted",
			"a restricted repository accepted a Git mutation");
		var restrictedOriginal:Null<ScmJobResult<ScmBlob>> = null;
		rootHandle.original(ScmRef.Index, "marked.txt", 731, value -> restrictedOriginal = value);
		pump(gitScheduler, () -> restrictedOriginal != null, "Restricted original-content read timed out");
		require(restrictedOriginal != null && restrictedOriginal.error == null && restrictedOriginal.value != null
			&& restrictedOriginal.value.bytes.toString() == "before marker\n" && !FileSystem.exists(smudgeMarker),
			"restricted original-content read ran the smudge filter or returned filtered content");
		var unchangedSnapshot:Null<ScmJobResult<ScmSnapshot>> = null;
		rootHandle.refresh(74, value -> unchangedSnapshot = value);
		pump(gitScheduler, () -> unchangedSnapshot != null, "Git unchanged refresh timed out");
		if (unchangedSnapshot == null || unchangedSnapshot.value == null) throw "Git unchanged refresh returned no snapshot";
		var unchangedSnapshotValue:ScmSnapshot = cast unchangedSnapshot.value;
		require(unchangedSnapshotValue.revision == firstSnapshotValue.revision,
			"Git status refresh advanced the revision without content changes");
		runGit(git, gitScheduler, ["config", "--unset-all", "filter.unsafe.clean"], discoveryRoot, 723);
		runGit(git, gitScheduler, ["config", "--unset-all", "filter.unsafe.smudge"], discoveryRoot, 724);
		runGit(git, gitScheduler, ["config", "--unset-all", "filter.unsafe.required"], discoveryRoot, 725);
		provider.trust(discoveryRoot);
		var reloadedTrust = new ScmTrustStore(fixtureBase + "/trust.json");
		require(rootHandle.repository().trusted && trustStore.isTrusted(discoveryRoot) && reloadedTrust.isTrusted(discoveryRoot),
			"Local trust decision was not persisted");
		var trustedSnapshot:Null<ScmJobResult<ScmSnapshot>> = null;
		rootHandle.refresh(732, value -> trustedSnapshot = value);
		pump(gitScheduler, () -> trustedSnapshot != null, "Trusted status refresh timed out");
		require(trustedSnapshot != null && trustedSnapshot.error == null && FileSystem.exists(fsmonitorMarker),
			"trusted status did not allow the configured fsmonitor command");
		var trustedFilterConversion:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["hash-object", "--path=marked.txt", "marked.txt"], discoveryRoot, 734,
			value -> trustedFilterConversion = value, true, false);
		pump(gitScheduler, () -> trustedFilterConversion != null, "Trusted Git filter fixture timed out");
		require(trustedFilterConversion != null && trustedFilterConversion.error == null && FileSystem.exists(cleanMarker),
			"trusted Git content conversion did not allow the configured clean filter");
		var trustedOriginal:Null<ScmJobResult<ScmBlob>> = null;
		rootHandle.original(ScmRef.Index, "marked.txt", 733, value -> trustedOriginal = value);
		pump(gitScheduler, () -> trustedOriginal != null, "Trusted original-content read timed out");
		require(trustedOriginal != null && trustedOriginal.error == null && trustedOriginal.value != null
			&& trustedOriginal.value.bytes.toString() == "before marker\n" && !FileSystem.exists(smudgeMarker),
			"original-content reads stopped returning raw Git objects after trust");
		runGit(git, gitScheduler, ["-c", "user.name=SCM Test", "-c", "user.email=scm@example.invalid", "commit", "--allow-empty", "-m", "initial"], discoveryRoot, 76);
		var mutationRoot = StringTools.replace(newPath(fixtureBase + "/real-operations"), "\\", "/");
		FileSystem.createDirectory(mutationRoot);
		runGit(git, gitScheduler, ["init"], mutationRoot, 760);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Test"], mutationRoot, 761);
		runGit(git, gitScheduler, ["config", "user.email", "scm@example.invalid"], mutationRoot, 762);
		File.saveContent(mutationRoot + "/tracked.txt", "base\n");
		File.saveContent(mutationRoot + "/other.txt", "other base\n");
		runGit(git, gitScheduler, ["add", "--", "tracked.txt", "other.txt"], mutationRoot, 763);
		runGit(git, gitScheduler, ["commit", "-m", "baseline"], mutationRoot, 764);
		var mutationTrust = new ScmTrustStore(fixtureBase + "/real-operation-trust.json");
		var mutationProvider = new GitScmProvider(processManager, gitScheduler, git.executable, emptyHooks, mutationTrust, 100, 0);
		mutationProvider.trust(mutationRoot);
		var mutationDiscovery:Null<ScmJobResult<Array<ScmRepositoryHandle>>> = null;
		mutationProvider.detect(mutationRoot, 765, value -> mutationDiscovery = value);
		pump(gitScheduler, () -> mutationDiscovery != null, "Git mutation repository discovery timed out");
		if (mutationDiscovery == null || mutationDiscovery.value == null || mutationDiscovery.value.length != 1)
			throw "Git mutation fixture returned no repository handle";
		var mutationHandle = mutationDiscovery.value[0];
		var initialBranches:Null<ScmJobResult<Array<scm.ScmBranch>>> = null;
		mutationHandle.branches(7651, value -> initialBranches = value);
		pump(gitScheduler, () -> initialBranches != null, "Git branch listing timed out");
		if (initialBranches == null || initialBranches.error != null || initialBranches.value == null)
			throw "Git branch listing failed: " + (initialBranches == null || initialBranches.error == null ? "unknown" : initialBranches.error.message);
		var currentReference:Null<String> = null;
		for (branch in initialBranches.value) if (branch.current && !branch.remote) currentReference = branch.reference;
		require(currentReference != null, "Git branch listing did not identify the current local branch");
		var originalBranchReference:String = cast currentReference;
		var createBranchResult = applyOperation(mutationHandle, gitScheduler, ScmOperation.CreateBranch("scm-branch-test"), 7652);
		require(createBranchResult.error == null && runGit(git, gitScheduler, ["symbolic-ref", "--short", "HEAD"], mutationRoot, 7653).stdout.toString() == "scm-branch-test\n",
			"Git branch creation did not create and check out the requested branch");
		var checkoutMainResult = applyOperation(mutationHandle, gitScheduler, ScmOperation.Checkout(originalBranchReference), 7654);
		require(checkoutMainResult.error == null
			&& runGit(git, gitScheduler, ["symbolic-ref", "--short", "HEAD"], mutationRoot, 7655).stdout.toString()
				== originalBranchReference.substring("refs/heads/".length) + "\n",
			"Git branch checkout did not return to the previous local branch");
		File.saveContent(mutationRoot + "/tracked.txt", "base\nchanged\n");
		var stagedMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.Stage("tracked.txt"), 766);
		require(stagedMutation.error == null && runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 767).stdout.toString() == "base\nchanged\n",
			"the SCM stage operation did not update the Git index");
		var unstagedMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.Unstage("tracked.txt"), 768);
		require(unstagedMutation.error == null && runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 769).stdout.toString() == "base\n",
			"the SCM unstage operation did not restore the index version");
		File.saveContent(mutationRoot + "/other.txt", "other staged in bulk\n");
		File.saveContent(mutationRoot + "/new.txt", "new staged in bulk\n");
		var stageAllMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.StageAll, 7681);
		require(stageAllMutation.error == null
			&& runGit(git, gitScheduler, ["diff", "--cached", "--name-only"], mutationRoot, 7682).stdout.toString().split("\n").filter(value -> value.length > 0).join(",") == "new.txt,other.txt,tracked.txt",
			"the SCM stage-all operation did not stage tracked and untracked changes");
		var unstageAllMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.UnstageAll, 7683);
		require(unstageAllMutation.error == null && runGit(git, gitScheduler, ["diff", "--cached", "--name-only"], mutationRoot, 7684).stdout.length == 0,
			"the SCM unstage-all operation did not clear the index");
		var stagePathsMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.StagePaths(["other.txt", "new.txt"]), 7685);
		require(stagePathsMutation.error == null
			&& runGit(git, gitScheduler, ["diff", "--cached", "--name-only"], mutationRoot, 7686).stdout.toString().split("\n").filter(value -> value.length > 0).join(",") == "new.txt,other.txt",
			"the SCM grouped stage operation did not stage its exact paths");
		var unstagePathsMutation = applyOperation(mutationHandle, gitScheduler, ScmOperation.UnstagePaths(["other.txt", "new.txt"]), 7687);
		require(unstagePathsMutation.error == null && runGit(git, gitScheduler, ["diff", "--cached", "--name-only"], mutationRoot, 7688).stdout.length == 0,
			"the SCM grouped unstage operation did not clear its exact paths");
		var stagedForCommit = applyOperation(mutationHandle, gitScheduler, ScmOperation.Stage("tracked.txt"), 770);
		require(stagedForCommit.error == null, "the SCM stage operation failed before commit");
		var indexedBeforeDiscard = runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 7690).stdout.toString();
		var trackedDiscardBytes = Bytes.ofString("discard me byte for byte\nwith a second line\n");
		File.saveBytes(mutationRoot + "/tracked.txt", trackedDiscardBytes);
		var discarded = applyOperation(mutationHandle, gitScheduler, ScmOperation.Discard("tracked.txt"), 7691);
		var discardToken = discarded.value == null ? null : discarded.value.recoveryToken;
		require(discarded.error == null && discardToken != null
			&& runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 7692).stdout.toString()
				== normalizeLineEndings(File.getContent(mutationRoot + "/tracked.txt"))
			&& normalizeLineEndings(File.getContent(mutationRoot + "/tracked.txt")) == indexedBeforeDiscard,
			"tracked discard did not restore the index version or return a recovery object (error="
				+ (discarded.error == null ? "none" : discarded.error.message) + ", token=" + (discardToken == null ? "null" : discardToken)
				+ ", index=" + runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 7698).stdout.toString()
				+ ", worktree=" + File.getContent(mutationRoot + "/tracked.txt") + ")");
		if (discardToken == null) throw "Tracked discard did not retain its recovery token";
		var restoredDiscard = applyOperation(mutationHandle, gitScheduler,
			ScmOperation.RestoreDiscard("tracked.txt", cast discardToken), 7693);
		require(restoredDiscard.error == null && File.getBytes(mutationRoot + "/tracked.txt").compare(trackedDiscardBytes) == 0,
			"tracked discard undo did not restore the exact worktree bytes");
		var stageAgainAfterUndo = applyOperation(mutationHandle, gitScheduler, ScmOperation.Stage("tracked.txt"), 7694);
		require(stageAgainAfterUndo.error == null, "could not restage tracked file after discard undo");
		var untrackedDiscardBytes = Bytes.ofString("recoverable untracked bytes\n");
		File.saveBytes(mutationRoot + "/untracked-discard.txt", untrackedDiscardBytes);
		var untrackedSnapshot:Null<ScmJobResult<ScmSnapshot>> = null;
		mutationHandle.refresh(7695, value -> untrackedSnapshot = value);
		pump(gitScheduler, () -> untrackedSnapshot != null, "Git status refresh before untracked discard timed out");
		var untrackedDiscard = applyOperation(mutationHandle, gitScheduler, ScmOperation.Discard("untracked-discard.txt"), 7696);
		var untrackedToken = untrackedDiscard.value == null ? null : untrackedDiscard.value.recoveryToken;
		require(untrackedDiscard.error == null && untrackedToken != null && !FileSystem.exists(mutationRoot + "/untracked-discard.txt"),
			"untracked Git discard did not remove the file and retain its recovery object");
		if (untrackedToken == null) throw "Untracked discard did not retain its recovery token";
		var restoredUntracked = applyOperation(mutationHandle, gitScheduler,
			ScmOperation.RestoreDiscard("untracked-discard.txt", cast untrackedToken), 7697);
		require(restoredUntracked.error == null && File.getBytes(mutationRoot + "/untracked-discard.txt").compare(untrackedDiscardBytes) == 0,
			"untracked Git discard undo did not restore the exact bytes");
		var hunkOldLines:Array<String> = [], hunkNewLines:Array<String> = [];
		for (line in 0...40) {
			hunkOldLines.push("line-" + line + "\n");
			hunkNewLines.push(line == 2 || line == 18 || line == 34 ? "changed-" + line + "\n" : "line-" + line + "\n");
		}
		var hunkOldText = hunkOldLines.join(""), hunkNewText = hunkNewLines.join("");
		File.saveBytes(mutationRoot + "/hunk.txt", Bytes.ofString(hunkOldText));
		runGit(git, gitScheduler, ["add", "--", "hunk.txt"], mutationRoot, 76981);
		runGit(git, gitScheduler, ["-c", "user.name=SCM Test", "-c", "user.email=scm@example.invalid", "commit", "-m", "hunk baseline"], mutationRoot, 76982);
		File.saveBytes(mutationRoot + "/hunk.txt", Bytes.ofString(hunkNewText));
		var lineDiff = new LineDiff(hunkOldText, hunkNewText);
		while (!lineDiff.step()) {}
		if (lineDiff.result == null) throw "the partial-stage fixture diff did not complete";
		var hunkChanges:Array<scm.LineDiffHunk> = cast lineDiff.result;
		require(hunkChanges.length == 3, "the partial-stage fixture did not produce three separated hunks");
		var hunkPatch = scm.ScmPatchBuilder.build(Bytes.ofString("hunk.txt"), hunkOldText, hunkNewText, hunkChanges, 1);
		require(hunkPatch != null, "the partial-stage patch builder returned no patch for the middle hunk");
		var stagedMiddleHunk = applyOperation(mutationHandle, gitScheduler,
			ScmOperation.StagePatch("hunk.txt", cast hunkPatch), 76983);
		var stagedHunkText = runGit(git, gitScheduler, ["show", ":hunk.txt"], mutationRoot, 76984).stdout.toString();
		require(stagedMiddleHunk.error == null && stagedHunkText == hunkOldLines.slice(0, 18).join("")
			+ hunkNewLines[18] + hunkOldLines.slice(19).join(""),
			"staging one generated hunk did not leave the other two changes unstaged");
		var failingHooks = fixtureBase + "/failing-hooks";
		FileSystem.createDirectory(failingHooks);
		File.saveBytes(failingHooks + "/pre-commit", Bytes.ofString("#!/bin/sh\necho EXOSUIT_TEST_HOOK_FAILURE >&2\nexit 1\n"));
		// Git skips a hook that is not executable, which only POSIX checks.
		if (Sys.systemName() != "Windows") require(Sys.command("chmod", ["+x", failingHooks + "/pre-commit"]) == 0, "the failing pre-commit hook could not be made executable");
		runGit(git, gitScheduler, ["config", "core.hooksPath", failingHooks], mutationRoot, 76985);
		var failedHookCommit = applyOperation(mutationHandle, gitScheduler,
			ScmOperation.Commit("Retain this message after hook failure", false), 76986);
		require(failedHookCommit.error != null && failedHookCommit.error.message.indexOf("EXOSUIT_TEST_HOOK_FAILURE") >= 0,
			"a failing pre-commit hook did not report its output");
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], mutationRoot, 76987);
		var committed = applyOperation(mutationHandle, gitScheduler, ScmOperation.Commit("SCM commit message", false), 771);
		require(committed.error == null && runGit(git, gitScheduler, ["log", "-1", "--format=%s"], mutationRoot, 772).stdout.toString() == "SCM commit message\n",
			"the SCM commit operation did not pass its message through stdin");
		File.saveContent(mutationRoot + "/tracked.txt", "base\namended\n");
		var stagedForAmend = applyOperation(mutationHandle, gitScheduler, ScmOperation.Stage("tracked.txt"), 773);
		var amended = stagedForAmend.error == null
			? applyOperation(mutationHandle, gitScheduler, ScmOperation.Commit("Amended SCM message", true), 774)
			: stagedForAmend;
		require(amended.error == null && runGit(git, gitScheduler, ["log", "-1", "--format=%s"], mutationRoot, 775).stdout.toString() == "Amended SCM message\n",
			"the SCM amend operation did not replace HEAD with the supplied message");
		// A folder-scoped commit (the Agents layout's narrowed Changes) snapshots the index, checks that tree against the
		// new commit's parents and commits exactly it, so files staged after the check cannot slip in.
		FileSystem.createDirectory(mutationRoot + "/sub");
		File.saveContent(mutationRoot + "/sub/a.txt", "inside\n");
		File.saveContent(mutationRoot + "/scoped-outside.txt", "outside\n");
		runGit(git, gitScheduler, ["add", "--", "sub/a.txt", "scoped-outside.txt"], mutationRoot, 77101);
		function lastSubject():String return runGit(git, gitScheduler, ["log", "-1", "--format=%s"], mutationRoot, 77199).stdout.toString();
		var lateOutside = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("Scoped", false, ["sub/"]), 77102);
		require(lateOutside.error != null && lateOutside.error.code == "outside_folder" && lateOutside.error.message.indexOf("scoped-outside.txt") >= 0
			&& lastSubject() == "Amended SCM message\n", "a folder-scoped commit took a file staged outside its folder");
		var configuredCase = runGitResult(git, gitScheduler, ["config", "--type=bool", "--get", "core.ignorecase"], mutationRoot, 77100, true);
		var configuredValue = configuredCase.value == null ? "" : StringTools.trim(configuredCase.value.stdout.toString());
		require(mutationHandle.repository().ignoreCase == (configuredValue == "true"),
			"the repository did not report its core.ignorecase");
		runGit(git, gitScheduler, ["reset", "-q", "--", "scoped-outside.txt"], mutationRoot, 77104);
		// Another process stages an outside file after the check (as an agent's `git add` could): the commit keeps the
		// checked tree, and the outside file stays staged, uncommitted.
		var scopedError = scopedCommit(git, gitScheduler, mutationRoot, 77105, "Scoped", false,
			function() { Sys.command("git", ["-C", mutationRoot, "add", "--", "scoped-outside.txt"]); });
		var committedNames = runGit(git, gitScheduler, ["show", "--name-only", "--format=", "HEAD"], mutationRoot, 77106).stdout.toString();
		var stillStaged = runGit(git, gitScheduler, ["diff", "--cached", "--name-only"], mutationRoot, 77113).stdout.toString();
		require(scopedError == null && lastSubject() == "Scoped\n" && StringTools.trim(committedNames) == "sub/a.txt"
			&& StringTools.trim(stillStaged) == "scoped-outside.txt", "a file staged after the check entered the folder-scoped commit: " + committedNames);
		runGit(git, gitScheduler, ["reset", "-q", "--", "scoped-outside.txt"], mutationRoot, 77114);
		// HEAD moving after the check fails the commit instead of dropping the other commit.
		File.saveContent(mutationRoot + "/sub/b.txt", "inside b\n");
		runGit(git, gitScheduler, ["add", "--", "sub/b.txt"], mutationRoot, 77115);
		var moved = scopedCommit(git, gitScheduler, mutationRoot, 77116, "Lost", false,
			function() { Sys.command("git", ["-C", mutationRoot, "commit", "-q", "--allow-empty", "-m", "Moved"]); });
		require(moved != null && moved.code == "head_moved" && lastSubject() == "Moved\n",
			"a folder-scoped commit replaced a commit made after its check");
		var scopedAmend = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("Scoped again", true, ["sub/"]), 77107);
		require(scopedAmend.error == null && lastSubject() == "Scoped again\n", "amending a commit inside the folder was refused");
		runGit(git, gitScheduler, ["add", "--", "scoped-outside.txt"], mutationRoot, 77109);
		runGit(git, gitScheduler, ["commit", "-q", "-m", "Outside"], mutationRoot, 77110);
		var outsideAmend = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("Rewritten", true, ["sub/"]), 77111);
		require(outsideAmend.error != null && outsideAmend.error.code == "outside_folder"
			&& outsideAmend.error.message.indexOf("commit being amended") >= 0 && outsideAmend.error.message.indexOf("scoped-outside.txt") >= 0
			&& lastSubject() == "Outside\n", "a folder-scoped amend rewrote a commit that touches paths outside the folder");
		// An amended merge is compared with each parent: the side it merged in brought an outside file.
		var mainBranch = StringTools.trim(runGit(git, gitScheduler, ["branch", "--show-current"], mutationRoot, 77120).stdout.toString());
		runGit(git, gitScheduler, ["checkout", "-q", "-b", "scoped-side"], mutationRoot, 77121);
		File.saveContent(mutationRoot + "/side-outside.txt", "side\n");
		runGit(git, gitScheduler, ["add", "--", "side-outside.txt"], mutationRoot, 77122);
		runGit(git, gitScheduler, ["commit", "-q", "-m", "Side"], mutationRoot, 77123);
		runGit(git, gitScheduler, ["checkout", "-q", mainBranch], mutationRoot, 77124);
		File.saveContent(mutationRoot + "/sub/c.txt", "inside c\n");
		runGit(git, gitScheduler, ["add", "--", "sub/c.txt"], mutationRoot, 77125);
		runGit(git, gitScheduler, ["commit", "-q", "-m", "Inside c"], mutationRoot, 77126);
		runGit(git, gitScheduler, ["merge", "-q", "--no-ff", "-m", "Merge side", "scoped-side"], mutationRoot, 77127);
		var mergeAmend = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("Merge rewritten", true, ["sub/"]), 77128);
		require(mergeAmend.error != null && mergeAmend.error.code == "outside_folder" && mergeAmend.error.message.indexOf("side-outside.txt") >= 0
			&& lastSubject() == "Merge side\n", "a folder-scoped amend of a merge ignored what the merge brought in");
		// A staged submodule outside the folder counts even when diff.ignoreSubmodules hides it from porcelain diffs.
		var headCommit = StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "HEAD"], mutationRoot, 77130).stdout.toString());
		runGit(git, gitScheduler, ["config", "diff.ignoreSubmodules", "all"], mutationRoot, 77131);
		runGit(git, gitScheduler, ["update-index", "--add", "--cacheinfo", "160000," + headCommit + ",vendor-module"], mutationRoot, 77132);
		File.saveContent(mutationRoot + "/sub/d.txt", "inside d\n");
		runGit(git, gitScheduler, ["add", "--", "sub/d.txt"], mutationRoot, 77133);
		var submodule = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("With module", false, ["sub/"]), 77134);
		require(submodule.error != null && submodule.error.code == "outside_folder" && submodule.error.message.indexOf("vendor-module") >= 0,
			"a staged submodule outside the folder was committed");
		runGit(git, gitScheduler, ["rm", "-q", "--cached", "vendor-module"], mutationRoot, 77135);
		runGit(git, gitScheduler, ["config", "--unset", "diff.ignoreSubmodules"], mutationRoot, 77136);
		// With a commit hook the provider runs `git commit` after the check, so the hook still runs.
		var scopedHooks = fixtureBase + "/scoped-hooks";
		FileSystem.createDirectory(scopedHooks);
		File.saveBytes(scopedHooks + "/pre-commit", Bytes.ofString("#!/bin/sh\necho ran > \"$(git rev-parse --absolute-git-dir)/scoped-hook-ran\"\nexit 0\n"));
		if (Sys.systemName() != "Windows") require(Sys.command("chmod", ["+x", scopedHooks + "/pre-commit"]) == 0, "the pre-commit hook could not be made executable");
		runGit(git, gitScheduler, ["config", "core.hooksPath", scopedHooks], mutationRoot, 77140);
		var hooked = applyOperation(mutationHandle, gitScheduler, ScmOperation.ScopedCommit("Hooked", false, ["sub/"]), 77142);
		var gitDirectory = StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "--absolute-git-dir"], mutationRoot, 77143).stdout.toString());
		require(hooked.error == null && lastSubject() == "Hooked\n" && FileSystem.exists(gitDirectory + "/scoped-hook-ran"),
			"a folder-scoped commit skipped the repository's pre-commit hook: " + (hooked.error == null ? "" : hooked.error.message));
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], mutationRoot, 77144);
		// With core.ignorecase unset the repository keeps the platform's rule: ignore case on Windows and macOS.
		var savedCase = runGitResult(git, gitScheduler, ["config", "--get", "core.ignorecase"], mutationRoot, 77145, true);
		if (savedCase.value != null) runGit(git, gitScheduler, ["config", "--unset", "core.ignorecase"], mutationRoot, 77146);
		var gitHandle = Std.downcast(mutationHandle, scm.git.GitScmRepositoryHandle);
		if (gitHandle == null) throw "the real-operations repository is not a Git handle";
		gitHandle.configurationChanged();
		var caseRefreshed = false;
		mutationHandle.refresh(77147, _ -> caseRefreshed = true);
		pump(gitScheduler, () -> caseRefreshed, "the refresh after unsetting core.ignorecase did not finish");
		require(!mutationHandle.repository().ignoreCase, "an unset core.ignorecase did not mean false, as in Git");
		var savedCaseValue = savedCase.value;
		if (savedCaseValue != null) runGit(git, gitScheduler, ["config", "core.ignorecase", StringTools.trim(savedCaseValue.stdout.toString())], mutationRoot, 77148);
		gitHandle.configurationChanged();
		// Amending on a branch without commits is refused clearly, before Git is asked to commit.
		var unbornRoot = fixtureBase + "/scoped-unborn";
		FileSystem.createDirectory(unbornRoot);
		runGit(git, gitScheduler, ["init", "-q"], unbornRoot, 77150);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Test"], unbornRoot, 77152);
		runGit(git, gitScheduler, ["config", "user.email", "scm@example.invalid"], unbornRoot, 77153);
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], unbornRoot, 77154);
		var unbornError = scopedCommit(git, gitScheduler, unbornRoot, 77151, "First", true);
		require(unbornError != null && unbornError.code == "nothing_to_amend", "an amend on an unborn branch did not say there is nothing to amend");
		// A first commit on an unborn branch, and one that another first commit overtakes.
		FileSystem.createDirectory(unbornRoot + "/sub");
		File.saveContent(unbornRoot + "/sub/first.txt", "first\n");
		runGit(git, gitScheduler, ["add", "--", "sub/first.txt"], unbornRoot, 77155);
		var racedFirst = scopedCommit(git, gitScheduler, unbornRoot, 77156, "Overtaken", false,
			function() { Sys.command("git", ["-C", unbornRoot, "commit", "-q", "--allow-empty", "-m", "Elsewhere"]); });
		var unbornSubject = runGit(git, gitScheduler, ["log", "-1", "--format=%s"], unbornRoot, 77157).stdout.toString();
		require(racedFirst != null && racedFirst.code == "head_moved" && unbornSubject == "Elsewhere\n",
			"a first commit replaced the commit that beat it to the unborn branch");
		var firstRoot = fixtureBase + "/scoped-first";
		FileSystem.createDirectory(firstRoot);
		FileSystem.createDirectory(firstRoot + "/sub");
		runGit(git, gitScheduler, ["init", "-q"], firstRoot, 77160);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Test"], firstRoot, 77161);
		runGit(git, gitScheduler, ["config", "user.email", "scm@example.invalid"], firstRoot, 77162);
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], firstRoot, 77163);
		File.saveContent(firstRoot + "/sub/first.txt", "first\n");
		runGit(git, gitScheduler, ["add", "--", "sub/first.txt"], firstRoot, 77164);
		var firstError = scopedCommit(git, gitScheduler, firstRoot, 77165, "First", false);
		var firstLog = runGit(git, gitScheduler, ["log", "--format=%s"], firstRoot, 77166).stdout.toString();
		require(firstError == null && firstLog == "First\n", "a first folder-scoped commit on an unborn branch failed: "
			+ (firstError == null ? firstLog : firstError.message));
		// An amend keeps the author from the raw commit.
		File.saveContent(firstRoot + "/sub/second.txt", "second\n");
		runGit(git, gitScheduler, ["add", "--", "sub/second.txt"], firstRoot, 77167);
		runGit(git, gitScheduler, ["commit", "-q", "--author=Original Author <original@example.invalid>", "--date=1700000000 +0100", "-m", "Authored"], firstRoot, 77168);
		File.saveContent(firstRoot + "/sub/third.txt", "third\n");
		runGit(git, gitScheduler, ["add", "--", "sub/third.txt"], firstRoot, 77169);
		var amendError = scopedCommit(git, gitScheduler, firstRoot, 77170, "Authored again", true);
		var author = runGit(git, gitScheduler, ["log", "-1", "--format=%an <%ae> %at %s"], firstRoot, 77171).stdout.toString();
		require(amendError == null && author == "Original Author <original@example.invalid> 1700000000 Authored again\n",
			"a folder-scoped amend changed the author: " + author);
		// A merge in progress is refused: committing the folder alone would drop the merge's second parent.
		runGit(git, gitScheduler, ["checkout", "-q", "-b", "merge-side"], firstRoot, 77172);
		File.saveContent(firstRoot + "/sub/first.txt", "side\n");
		runGit(git, gitScheduler, ["commit", "-q", "-am", "Side change"], firstRoot, 77173);
		runGit(git, gitScheduler, ["checkout", "-q", "-"], firstRoot, 77174);
		File.saveContent(firstRoot + "/sub/first.txt", "main\n");
		runGit(git, gitScheduler, ["commit", "-q", "-am", "Main change"], firstRoot, 77175);
		runGitResult(git, gitScheduler, ["merge", "merge-side"], firstRoot, 77176);
		File.saveContent(firstRoot + "/sub/first.txt", "resolved\n");
		runGit(git, gitScheduler, ["add", "--", "sub/first.txt"], firstRoot, 77177);
		var merging = scopedCommit(git, gitScheduler, firstRoot, 77178, "Resolved", false);
		require(merging != null && merging.code == GitScopedCommit.OPERATION_IN_PROGRESS && merging.message.indexOf("merge") >= 0
			&& runGit(git, gitScheduler, ["log", "-1", "--format=%s"], firstRoot, 77179).stdout.toString() == "Main change\n",
			"a folder-scoped commit went ahead during a merge");
		var parsedAuthor = GitScopedCommit.authorOf("tree x\nauthor A B <a@b> 1 +0000\ncommitter C <c@d> 2 +0000\n\nmessage author X <y> 3\n");
		require(parsedAuthor != null && parsedAuthor.get("GIT_AUTHOR_NAME") == "A B" && parsedAuthor.get("GIT_AUTHOR_DATE") == "1 +0000",
			"the raw commit author was not parsed");
		File.saveContent(mutationRoot + "/other.txt", "other changed\n");
		var foreignPatch = runGit(git, gitScheduler, ["diff", "--", "other.txt"], mutationRoot, 776).stdout;
		applyOperation(mutationHandle, gitScheduler, ScmOperation.StagePatch("tracked.txt", foreignPatch), 777);
		require(runGit(git, gitScheduler, ["show", ":other.txt"], mutationRoot, 778).stdout.toString() == "other base\n",
			"a hunk patch scoped to tracked.txt changed another file in the index");
		File.saveContent(mutationRoot + "/tracked.txt", "base\namended with patch\n");
		var trackedPatch = runGit(git, gitScheduler, ["diff", "--", "tracked.txt"], mutationRoot, 779).stdout;
		var patched = applyOperation(mutationHandle, gitScheduler, ScmOperation.StagePatch("tracked.txt", trackedPatch), 780);
		require(patched.error == null && runGit(git, gitScheduler, ["show", ":tracked.txt"], mutationRoot, 781).stdout.toString() == "base\namended with patch\n",
			"the SCM hunk-stage operation did not apply its patch to the index");
		var createdBranch = applyOperation(mutationHandle, gitScheduler, ScmOperation.CreateBranch("scm-operation-test"), 782);
		require(createdBranch.error == null && runGit(git, gitScheduler, ["branch", "--show-current"], mutationRoot, 783).stdout.toString() == "scm-operation-test\n",
			"the SCM create-branch operation did not check out the new branch");
		mutationHandle.dispose();
		for (handle in mutationDiscovery.value) handle.dispose();
		var mutationService = new ScmService(processManager, gitScheduler, git.executable, 100, 0, true,
			fixtureBase + "/real-operation-trust.json", emptyHooks), mutationServiceDiscovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		mutationService.discover(mutationRoot, value -> mutationServiceDiscovery = value);
		pumpService(mutationService, gitScheduler, () -> mutationServiceDiscovery != null && mutationServiceDiscovery.value != null
			&& mutationService.snapshot(mutationServiceDiscovery.value[0].id) != null, "Git mutation service discovery timed out");
		if (mutationServiceDiscovery == null || mutationServiceDiscovery.value == null || mutationServiceDiscovery.value.length != 1)
			throw "Git mutation service did not discover its repository";
		var serviceBranchResult:Null<ScmJobResult<ScmApplyResult>> = null;
		mutationService.apply(mutationServiceDiscovery.value[0].id, ScmOperation.CreateBranch("scm-service-operation"), 784,
			value -> serviceBranchResult = value);
		pumpService(mutationService, gitScheduler, () -> serviceBranchResult != null, "Git service branch operation timed out");
		require(serviceBranchResult != null && serviceBranchResult.error == null
			&& runGit(git, gitScheduler, ["branch", "--show-current"], mutationRoot, 785).stdout.toString() == "scm-service-operation\n",
			"the SCM service queue did not complete its Git branch operation");
		mutationService.dispose();
		var remoteRoot = fixtureBase + "/remote-operations", bareRemote = fixtureBase + "/scm-origin.git",
			remoteWriter = fixtureBase + "/remote-writer";
		FileSystem.createDirectory(remoteRoot);
		runGit(git, gitScheduler, ["init"], remoteRoot, 786);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Test"], remoteRoot, 787);
		runGit(git, gitScheduler, ["config", "user.email", "scm@example.invalid"], remoteRoot, 788);
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], remoteRoot, 789);
		File.saveContent(remoteRoot + "/README.txt", "remote base\n");
		runGit(git, gitScheduler, ["add", "README.txt"], remoteRoot, 790);
		runGit(git, gitScheduler, ["commit", "-m", "remote baseline"], remoteRoot, 791);
		var remoteBranch = StringTools.trim(runGit(git, gitScheduler, ["branch", "--show-current"], remoteRoot, 792).stdout.toString());
		runGit(git, gitScheduler, ["init", "--bare", bareRemote], fixtureBase, 793);
		runGit(git, gitScheduler, ["--git-dir", bareRemote, "symbolic-ref", "HEAD", "refs/heads/" + remoteBranch], fixtureBase, 794);
		runGit(git, gitScheduler, ["remote", "add", "origin", bareRemote], remoteRoot, 795);
		var remoteTrust = new ScmTrustStore(fixtureBase + "/remote-trust.json"),
			remoteProvider = new GitScmProvider(processManager, gitScheduler, git.executable, emptyHooks, remoteTrust, 100, 0);
		remoteProvider.trust(remoteRoot);
		require(remoteTrust.isTrusted(remoteRoot), "Could not trust the local bare-remote fixture");
		var remoteDiscovery:Null<ScmJobResult<Array<ScmRepositoryHandle>>> = null;
		remoteProvider.detect(remoteRoot, 796, value -> remoteDiscovery = value);
		pump(gitScheduler, () -> remoteDiscovery != null, "Bare-remote fixture discovery timed out");
		if (remoteDiscovery == null || remoteDiscovery.value == null || remoteDiscovery.value.length != 1)
			throw "Bare-remote fixture returned no repository handle";
		var remoteHandle = remoteDiscovery.value[0], remoteInitial:Null<ScmJobResult<ScmSnapshot>> = null;
		remoteHandle.refresh(797, value -> remoteInitial = value);
		pump(gitScheduler, () -> remoteInitial != null, "Bare-remote initial refresh timed out");
		var firstPush = applyOperation(remoteHandle, gitScheduler, ScmOperation.Push, 798);
		require(remoteInitial != null && remoteInitial.error == null && firstPush.error == null
			&& StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "refs/heads/" + remoteBranch], bareRemote, 799).stdout.toString())
				== StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "HEAD"], remoteRoot, 800).stdout.toString())
			&& StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], remoteRoot, 801).stdout.toString())
				== "origin/" + remoteBranch,
			"the first SCM push did not publish HEAD and set its origin upstream");
		runGit(git, gitScheduler, ["clone", bareRemote, remoteWriter], fixtureBase, 802);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Remote Writer"], remoteWriter, 803);
		runGit(git, gitScheduler, ["config", "user.email", "remote@example.invalid"], remoteWriter, 804);
		File.saveContent(remoteWriter + "/README.txt", "remote base\nremote change\n");
		runGit(git, gitScheduler, ["add", "README.txt"], remoteWriter, 805);
		runGit(git, gitScheduler, ["commit", "-m", "remote change"], remoteWriter, 806);
		runGit(git, gitScheduler, ["push"], remoteWriter, 807);
		var fetched = applyOperation(remoteHandle, gitScheduler, ScmOperation.Fetch(null), 808),
			remoteBranches:Null<ScmJobResult<Array<scm.ScmBranch>>> = null;
		remoteHandle.branches(809, value -> remoteBranches = value);
		pump(gitScheduler, () -> remoteBranches != null, "Fetched branch listing timed out");
		var foundRemoteBranch = false;
		if (remoteBranches != null && remoteBranches.value != null)
			for (branch in remoteBranches.value) if (branch.remote && branch.reference == "refs/remotes/origin/" + remoteBranch) foundRemoteBranch = true;
		var pulled = applyOperation(remoteHandle, gitScheduler, ScmOperation.Pull, 810);
		require(fetched.error == null && foundRemoteBranch && pulled.error == null
			&& normalizeLineEndings(File.getContent(remoteRoot + "/README.txt")) == "remote base\nremote change\n",
			"SCM fetch/pull did not fast-forward from the local bare remote");
		File.saveContent(remoteRoot + "/README.txt", "remote base\nremote change\nlocal change\n");
		runGit(git, gitScheduler, ["add", "README.txt"], remoteRoot, 811);
		runGit(git, gitScheduler, ["commit", "-m", "local change"], remoteRoot, 812);
		var refreshedRemote:Null<ScmJobResult<ScmSnapshot>> = null;
		remoteHandle.refresh(813, value -> refreshedRemote = value);
		pump(gitScheduler, () -> refreshedRemote != null, "Remote fixture refresh before push timed out");
		var pushed = applyOperation(remoteHandle, gitScheduler, ScmOperation.Push, 814);
		require(refreshedRemote != null && refreshedRemote.error == null && pushed.error == null
			&& StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "refs/heads/" + remoteBranch], bareRemote, 815).stdout.toString())
				== StringTools.trim(runGit(git, gitScheduler, ["rev-parse", "HEAD"], remoteRoot, 816).stdout.toString()),
			"SCM push did not publish a local commit to the bare remote");
		runGit(git, gitScheduler, ["checkout", "-b", "scm-checkout-target"], remoteRoot, 817);
		File.saveContent(remoteRoot + "/README.txt", "target branch content\n");
		runGit(git, gitScheduler, ["add", "README.txt"], remoteRoot, 818);
		runGit(git, gitScheduler, ["commit", "-m", "checkout target"], remoteRoot, 819);
		runGit(git, gitScheduler, ["switch", remoteBranch], remoteRoot, 820);
		var dirtyCheckoutBytes = Bytes.ofString("uncommitted local content\n");
		File.saveBytes(remoteRoot + "/README.txt", dirtyCheckoutBytes);
		var refreshedBeforeCheckout:Null<ScmJobResult<ScmSnapshot>> = null;
		remoteHandle.refresh(821, value -> refreshedBeforeCheckout = value);
		pump(gitScheduler, () -> refreshedBeforeCheckout != null, "Refresh before conflicting checkout timed out");
		var blockedCheckout = applyOperation(remoteHandle, gitScheduler, ScmOperation.Checkout("refs/heads/scm-checkout-target"), 822);
		require(refreshedBeforeCheckout != null && refreshedBeforeCheckout.error == null && blockedCheckout.error != null
			&& StringTools.trim(runGit(git, gitScheduler, ["branch", "--show-current"], remoteRoot, 823).stdout.toString()) == remoteBranch
			&& File.getBytes(remoteRoot + "/README.txt").compare(dirtyCheckoutBytes) == 0,
			"SCM checkout overwrote conflicting local changes instead of refusing safely");
		var fakeSsh = fixtureBase + "/fake-ssh.sh", shell = "/bin/sh";
		if (Sys.systemName() == "Windows") {
			// git.exe lives in cmd/, bin/ or mingw64/bin/ depending on which PATH entry found it; the shell is in
			// bin/ or usr/bin/ under the installation root.
			var directory = StringTools.replace(git.executable == null ? "" : git.executable, "\\", "/");
			shell = "";
			for (_ in 0...3) {
				directory = directory.substr(0, directory.lastIndexOf("/"));
				for (candidate in [directory + "/bin/sh.exe", directory + "/usr/bin/sh.exe"])
					if (shell == "" && FileSystem.exists(candidate)) shell = candidate;
			}
		}
		require(FileSystem.exists(shell), "Could not locate the shell bundled with Git for the fake SSH fixture");
		File.saveContent(fakeSsh, "#!/bin/sh\necho 'Permission denied (publickey)' >&2\nexit 255\n");
		runGit(git, gitScheduler, ["config", "core.sshCommand", shellQuote(shell) + " " + shellQuote(fakeSsh)], remoteRoot, 824);
		runGit(git, gitScheduler, ["config", "ssh.variant", "simple"], remoteRoot, 825);
		runGit(git, gitScheduler, ["remote", "set-url", "origin", "ssh://git@example.invalid/scm.git"], remoteRoot, 826);
		var refreshedBeforeAuth:Null<ScmJobResult<ScmSnapshot>> = null;
		remoteHandle.refresh(827, value -> refreshedBeforeAuth = value);
		pump(gitScheduler, () -> refreshedBeforeAuth != null, "Refresh before fake SSH auth failure timed out");
		var rejectedAuth = applyOperation(remoteHandle, gitScheduler, ScmOperation.Push, 828);
		require(refreshedBeforeAuth != null && refreshedBeforeAuth.error == null && rejectedAuth.error != null
			&& rejectedAuth.error.code == "authentication_required"
			&& rejectedAuth.error.message.indexOf("credential helper or SSH agent") >= 0,
			"SCM fake-SSH failure did not explain non-interactive authentication (code="
				+ (rejectedAuth.error == null ? "none" : rejectedAuth.error.code) + ", message="
				+ (rejectedAuth.error == null ? "none" : rejectedAuth.error.message) + ")");
		for (handle in remoteDiscovery.value) handle.dispose();
		var linkedRoot = discoveryRoot + "/linked";
		runGit(git, gitScheduler, ["worktree", "add", "-b", "scm-linked-fixture", linkedRoot, "HEAD"], discoveryRoot, 77);
		var submoduleSource = fixtureBase + "/submodule-source";
		FileSystem.createDirectory(submoduleSource);
		runGit(git, gitScheduler, ["init"], submoduleSource, 78);
		runGit(git, gitScheduler, ["-c", "user.name=SCM Test", "-c", "user.email=scm@example.invalid", "commit", "--allow-empty", "-m", "source"], submoduleSource, 79);
		runGit(git, gitScheduler, ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource, "submodule"], discoveryRoot, 80);
		var completeDetection:Null<ScmJobResult<Array<ScmRepositoryHandle>>> = null;
		provider.detect(discoveryRoot, 81, value -> completeDetection = value);
		pump(gitScheduler, () -> completeDetection != null, "Git worktree and submodule discovery timed out");
		if (completeDetection == null || completeDetection.value == null) throw "Git worktree discovery returned no handles";
		require(completeDetection.error == null && completeDetection.value.length == 4,
			"Git discovery did not find all nested repositories, linked worktrees and submodules");
		var linkedHandle:Null<ScmRepositoryHandle> = null, submoduleHandle:Null<ScmRepositoryHandle> = null;
		for (handle in completeDetection.value) {
			if (handle.repository().root == StringTools.replace(FileSystem.fullPath(linkedRoot), "\\", "/")) linkedHandle = handle;
			if (handle.repository().root == StringTools.replace(FileSystem.fullPath(discoveryRoot + "/submodule"), "\\", "/")) submoduleHandle = handle;
		}
		if (linkedHandle == null || submoduleHandle == null) throw "Git discovery lost the linked worktree or submodule";
		require(linkedHandle.repository().kind == scm.ScmRepositoryKind.LinkedWorktree
			&& linkedHandle.repository().parentId == rootHandle.repository().id
			&& submoduleHandle.repository().kind == scm.ScmRepositoryKind.Submodule
			&& submoduleHandle.repository().parentId == rootHandle.repository().id,
			"Git discovery did not classify linked worktree and submodule relationships");
		for (handle in discovered.value) handle.dispose();
		for (handle in completeDetection.value) handle.dispose();
		var service = new ScmService(processManager, gitScheduler, git.executable, 1, 2, true,
			fixtureBase + "/trust.json", emptyHooks), serviceResult:Null<ScmJobResult<Array<scm.ScmRepository>>> = null,
			serviceEvents = 0;
		service.subscribe(function(_, _) serviceEvents++);
		service.discover(discoveryRoot, value -> serviceResult = value);
		pump(gitScheduler, () -> serviceResult != null, "SCM service discovery timed out");
		if (serviceResult == null || serviceResult.value == null || serviceResult.value.length != 4)
			throw "SCM service did not publish discovered repositories";
		var serviceWatchPaths = service.watchDirectories(discoveryRoot);
		require(serviceWatchPaths.length > 1
			&& serviceWatchPaths[0] == StringTools.replace(FileSystem.fullPath(discoveryRoot), "\\", "/"),
			"SCM service did not expose the project and Git metadata directories for host watches");
		var serviceRepositories:Array<ScmRepository> = cast serviceResult.value;
		var serviceRepository = serviceRepositories[0];
		service.update(Sys.time());
		pump(gitScheduler, function() {
			for (repository in serviceRepositories) if (service.snapshot(repository.id) == null) return false;
			return true;
		}, "SCM service initial refresh timed out");
		var initialServiceSnapshot:Null<ScmSnapshot> = service.snapshot(serviceRepository.id);
		if (initialServiceSnapshot == null) throw "SCM service lost its initial snapshot";
		var serviceSnapshot:ScmSnapshot = cast initialServiceSnapshot;
		require(serviceEvents == serviceRepositories.length, "SCM service did not publish every initial snapshot");
		var lockedPath = discoveryRoot + "/lock-contention.txt", indexLock = discoveryRoot + "/.git/index.lock";
		File.saveContent(lockedPath, "lock fixture\n");
		File.saveContent(indexLock, "held by fixture\n");
		var lockedAdd = runGitResult(git, gitScheduler, ["add", "--", "lock-contention.txt"], discoveryRoot, 810);
		require(lockedAdd.error != null && lockedAdd.error.code == "lock_contention" && lockedAdd.error.retryable,
			"a held index.lock did not produce a retryable lock-contention error");
		FileSystem.deleteFile(indexLock);
		var releasedAdd = runGitResult(git, gitScheduler, ["add", "--", "lock-contention.txt"], discoveryRoot, 8101);
		require(releasedAdd.error == null && releasedAdd.value != null,
			"Git staging did not succeed after the held index.lock was released");
		runGit(git, gitScheduler, ["add", "one.txt"], discoveryRoot, 811);
		var externalRevision = serviceSnapshot.revision, pollStarted = Sys.time();
		while (Sys.time() - pollStarted < 2.0) {
			var latest = service.snapshot(serviceRepository.id);
			if (latest != null && latest.revision != externalRevision) break;
			service.update(Sys.time());
			gitScheduler.update(32);
			Sys.sleep(0.005);
		}
		var externalSnapshot = service.snapshot(serviceRepository.id);
			require(externalSnapshot != null && externalSnapshot.revision != externalRevision && Sys.time() - pollStarted < 2.0,
			"SCM polling did not observe an external Git add within two seconds");
		serviceSnapshot = cast externalSnapshot;
		var stableServiceEvents = serviceEvents;
		service.notifyChanged(discoveryRoot, true);
		service.update(Sys.time());
		pump(gitScheduler, () -> gitScheduler.activeCount() == 0, "SCM service overflow refresh timed out");
		var refreshedServiceSnapshot:ScmSnapshot = cast service.snapshot(serviceRepository.id);
		require(serviceEvents == stableServiceEvents && refreshedServiceSnapshot.revision == serviceSnapshot.revision,
			"An unchanged refresh caused snapshot revision or listener churn");
		service.dispose();

		var operationRoot = StringTools.replace(newPath(fixtureBase + "/operation-service"), "\\", "/");
		FileSystem.createDirectory(operationRoot);
		var operationsProvider = new FakeScmProvider(gitScheduler), operationsScript = new FakeScmRepositoryScript(
			new ScmRepository("operations", "fake", operationRoot), new ScmFeatures(true), [orderedSnapshot], 0);
		operationsProvider.add(operationsScript);
		var operationService = new ScmService(processManager, gitScheduler, git.executable, 10000, 0, true,
			fixtureBase + "/operation-trust.json", emptyHooks, operationsProvider),
			operationDiscovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		operationService.discover(operationRoot, value -> operationDiscovery = value);
		pumpService(operationService, gitScheduler, () -> operationDiscovery != null, "Fake SCM operation service discovery timed out");
		if (operationDiscovery == null || operationDiscovery.value == null || operationDiscovery.value.length != 1)
			throw "Fake SCM operation service returned no repository";
		var operationRepository = operationDiscovery.value[0];
		operationService.setWatchAvailable(operationRoot, true);
		pumpService(operationService, gitScheduler, () -> operationService.snapshot(operationRepository.id) != null,
			"Fake SCM operation service initial refresh timed out");
		var unsupportedError:Null<scm.ScmError> = null;
		var unsupportedOperation = operationService.apply(operationRepository.id, ScmOperation.StagePatch("blocked.txt", Bytes.alloc(0)), 900,
			result -> unsupportedError = result.error);
		require(unsupportedOperation.complete && unsupportedOperation.generation == 900 && unsupportedError != null
			&& unsupportedError.code == "unsupported_operation" && operationsScript.operations.length == 0,
			"SCM service did not enforce repository feature availability before queuing a mutation");
		unsupportedError = null;
		var unsupportedAmend = operationService.apply(operationRepository.id, ScmOperation.Commit("message", true), 901,
			result -> unsupportedError = result.error);
		require(unsupportedAmend.complete && unsupportedAmend.generation == 901 && unsupportedError != null
			&& unsupportedError.code == "unsupported_operation" && operationsScript.operations.length == 0,
			"SCM service allowed amend when the repository feature flag was disabled");
		for (_ in 0...3) operationsScript.failNext("apply", new scm.ScmError("lock_contention", "index.lock is held", true));
		var operationCompletions = 0, firstOperationError:Null<scm.ScmError> = null, secondOperationError:Null<scm.ScmError> = null;
		var firstOperation = operationService.apply(operationRepository.id, ScmOperation.Stage("first.txt"), 901, function(result) {
			operationCompletions++;
			firstOperationError = result.error;
		});
		var secondOperation = operationService.apply(operationRepository.id, ScmOperation.Unstage("second.txt"), 902, function(result) {
			operationCompletions++;
			secondOperationError = result.error;
		});
		pumpService(operationService, gitScheduler, () -> operationCompletions == 2,
			"SCM operation FIFO queue did not complete after three lock retries", 5.0);
		var operationOrder = [for (operation in operationsScript.operations) switch operation {
			case Stage(path): "stage:" + path;
			case Unstage(path): "unstage:" + path;
			case _: "other";
		}];
		require(firstOperation.complete && secondOperation.complete && firstOperationError == null && secondOperationError == null
			&& operationOrder.join(",") == "stage:first.txt,stage:first.txt,stage:first.txt,stage:first.txt,unstage:second.txt",
			"SCM operation queue did not retry the head three times before running the next operation");
		for (_ in 0...4) operationsScript.failNext("apply", new scm.ScmError("lock_contention", "index.lock remains held", true));
		var thirdOperationError:Null<scm.ScmError> = null, fourthOperationCompleted = false, retryCompletionCount = 0,
			retryOperationStart = operationsScript.operations.length;
		var thirdOperation = operationService.apply(operationRepository.id, ScmOperation.Stage("third.txt"), 903, function(result) {
			retryCompletionCount++;
			thirdOperationError = result.error;
		});
		var fourthOperation = operationService.apply(operationRepository.id, ScmOperation.Unstage("fourth.txt"), 904, function(_) {
			retryCompletionCount++;
			fourthOperationCompleted = true;
		});
		pumpService(operationService, gitScheduler, () -> retryCompletionCount == 2,
			"SCM operation queue did not report exhausted retries and advance", 5.0);
		var retryOrder = [for (operation in operationsScript.operations.slice(retryOperationStart)) switch operation {
			case Stage(path): "stage:" + path;
			case Unstage(path): "unstage:" + path;
			case _: "other";
		}];
		require(thirdOperation.complete && thirdOperationError != null && thirdOperationError.code == "lock_contention"
			&& thirdOperationError.retryable && fourthOperation.complete && fourthOperationCompleted
			&& retryOrder.join(",") == "stage:third.txt,stage:third.txt,stage:third.txt,stage:third.txt,unstage:fourth.txt",
			"SCM operation queue did not report lock contention after three retries before advancing");
		operationsScript.latencySteps = 8;
		var cancelledOperationCallback = false, afterCancelCompleted = false;
		var cancelledOperation = operationService.apply(operationRepository.id, ScmOperation.Stage("cancelled.txt"), 905,
			_ -> cancelledOperationCallback = true);
		var afterCancelOperation = operationService.apply(operationRepository.id, ScmOperation.Unstage("after-cancel.txt"), 906,
			_ -> afterCancelCompleted = true);
		operationService.update(Sys.time());
		gitScheduler.update(1);
		require(cancelledOperation.cancel(), "an active SCM queue head refused cancellation");
		pumpService(operationService, gitScheduler, () -> afterCancelCompleted,
			"Cancelling an active SCM queue head left the repository busy");
		require(!cancelledOperationCallback && afterCancelOperation.complete,
			"A cancelled SCM operation published a stale callback or blocked the next request");
		operationsScript.latencySteps = 0;

		var burstRoot = StringTools.replace(newPath(fixtureBase + "/burst-service"), "\\", "/");
		FileSystem.createDirectory(burstRoot);
		var burstScript = new FakeScmRepositoryScript(new ScmRepository("burst", "fake", burstRoot), new ScmFeatures(), [orderedSnapshot], 0);
		operationsProvider.add(burstScript);
		var burstDiscovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		operationService.discover(burstRoot, value -> burstDiscovery = value);
		pumpService(operationService, gitScheduler, () -> burstDiscovery != null, "Fake SCM burst service discovery timed out");
		if (burstDiscovery == null || burstDiscovery.value == null || burstDiscovery.value.length != 1)
			throw "Fake SCM burst service returned no repository";
		var burstRepository = burstDiscovery.value[0];
		operationService.setWatchAvailable(burstRoot, true);
		pumpService(operationService, gitScheduler, () -> operationService.snapshot(burstRepository.id) != null,
			"Fake SCM burst service initial refresh timed out");
		var burstRefreshBaseline = burstScript.refreshCalls, lastBurstEvent = Sys.time();
		for (index in 0...500) {
			File.saveContent(burstRoot + "/burst-" + index + ".txt", Std.string(index));
			lastBurstEvent = Sys.time();
			operationService.notifyChanged(burstRoot, false, lastBurstEvent);
		}
		operationService.update(lastBurstEvent + 0.301);
		pumpService(operationService, gitScheduler,
			() -> burstScript.refreshCalls > burstRefreshBaseline && gitScheduler.activeCount() == 0,
			"A 500-write SCM burst did not settle into a refresh");
		require(FileSystem.readDirectory(burstRoot).length == 500
			&& burstScript.refreshCalls - burstRefreshBaseline <= 3,
			"A burst of 500 file writes produced more than three SCM refreshes");
		var continuousStart = Sys.time() + 1.0, continuousBaseline = burstScript.refreshCalls,
			firstContinuousRefresh:Null<Float> = null;
		for (index in 0...500) {
			var eventAt = continuousStart + index * 0.005;
			operationService.notifyChanged(burstRoot, false, eventAt);
			operationService.update(eventAt);
			gitScheduler.update(32);
			if (firstContinuousRefresh == null && burstScript.refreshCalls > continuousBaseline) firstContinuousRefresh = eventAt;
		}
		var continuousLastEvent = continuousStart + 499 * 0.005;
		var finalContinuousBaseline = burstScript.refreshCalls;
		operationService.update(continuousLastEvent + 0.301);
		gitScheduler.update(32);
		pumpService(operationService, gitScheduler,
			() -> burstScript.refreshCalls > finalContinuousBaseline && gitScheduler.activeCount() == 0,
			"SCM continuous-change debounce did not issue its trailing refresh");
		require(firstContinuousRefresh != null && firstContinuousRefresh <= continuousStart + 2.0,
			"A continuous change stream postponed SCM refresh for more than two seconds");

		// A source narrowed to a sub-folder (the Agents layout's Changes) shows and writes only inside it.
		var narrowRoot = StringTools.replace(newPath(fixtureBase + "/narrowed-source"), "\\", "/");
		FileSystem.createDirectory(narrowRoot);
		FileSystem.createDirectory(narrowRoot + "/sub");
		var mixedSnapshot = new ScmSnapshot(Int64.ofInt(1), orderedSnapshot.head, [new scm.ScmGroup(ScmGroupId.Index, [
			new scm.ScmResource(Bytes.ofString("sub/inside.txt"), ScmChangeKind.Modified),
			new scm.ScmResource(Bytes.ofString("outside.txt"), ScmChangeKind.Modified)])]);
		var narrowScript = new FakeScmRepositoryScript(new ScmRepository("narrowed", "fake", narrowRoot), new ScmFeatures(true), [mixedSnapshot], 0);
		operationsProvider.add(narrowScript);
		var narrowDiscovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		operationService.discover(narrowRoot, value -> narrowDiscovery = value);
		pumpService(operationService, gitScheduler, () -> narrowDiscovery != null, "Fake SCM narrowed discovery timed out");
		if (narrowDiscovery == null || narrowDiscovery.value == null || narrowDiscovery.value.length != 1)
			throw "Fake SCM narrowed service returned no repository";
		var narrowRepository = narrowDiscovery.value[0];
		operationService.setWatchAvailable(narrowRoot, true);
		pumpService(operationService, gitScheduler, () -> operationService.snapshot(narrowRepository.id) != null,
			"Fake SCM narrowed initial refresh timed out");
		var narrowed = new scm.LocalScmSource(operationService, narrowRoot + "/sub", null, true);
		var narrowedView = narrowed.snapshot(narrowRepository.id);
		require(narrowedView != null && narrowedView.groups.length == 1 && narrowedView.groups[0].resources.length == 1
			&& narrowedView.groups[0].resources[0].path == "sub/inside.txt", "a narrowed source showed changes outside its folder");
		var narrowedStep = 0;
		function applyNarrowed(operation:ScmOperation):Null<scm.ScmError> {
			var latest = operationService.snapshot(narrowRepository.id);
			if (latest == null) throw "Fake SCM narrowed repository lost its snapshot";
			var done = false, error:Null<scm.ScmError> = null;
			narrowed.apply(narrowRepository.id, "narrowed-" + (narrowedStep++), latest.revision, operation, function(result) {
				done = true; error = result.error;
			});
			pumpService(operationService, gitScheduler, () -> done && gitScheduler.activeCount() == 0, "A narrowed SCM operation did not finish");
			return error;
		}
		var outsideStage = applyNarrowed(ScmOperation.Stage("outside.txt"));
		var climbingStage = applyNarrowed(ScmOperation.Stage("sub/../outside.txt"));
		var climbingDiscard = applyNarrowed(ScmOperation.Discard("sub/../outside.txt"));
		var climbingPaths = applyNarrowed(ScmOperation.StagePaths(["sub/inside.txt", "sub/../outside.txt"]));
		require(climbingStage != null && climbingStage.code == "outside_folder" && climbingDiscard != null && climbingDiscard.code == "outside_folder"
			&& climbingPaths != null && climbingPaths.code == "outside_folder" && narrowScript.operations.length == 0,
			"a narrowed source let a path climb out of its folder with ..");
		var mixedCommit = applyNarrowed(ScmOperation.Commit("message", false));
		require(outsideStage != null && outsideStage.code == "outside_folder" && mixedCommit != null && mixedCommit.code == "outside_folder"
			&& mixedCommit.message.indexOf("outside.txt") >= 0 && narrowScript.operations.length == 0,
			"a narrowed source staged outside its folder or committed changes staged outside it");
		var stagedFolder = applyNarrowed(ScmOperation.StageAll);
		var stagedOperation = narrowScript.operations.length == 1 ? Std.string(narrowScript.operations[0]) : "none";
		require(stagedFolder == null && stagedOperation == Std.string(ScmOperation.StagePaths(["sub"])),
			"a narrowed stage-all did not stage only its folder: " + stagedOperation);
		narrowed.dispose();
		operationService.dispose();

		var mergeRoot = fixtureBase + "/merge-conflict";
		FileSystem.createDirectory(mergeRoot);
		runGit(git, gitScheduler, ["init"], mergeRoot, 920);
		runGit(git, gitScheduler, ["config", "user.name", "SCM Test"], mergeRoot, 921);
		runGit(git, gitScheduler, ["config", "user.email", "scm@example.invalid"], mergeRoot, 922);
		runGit(git, gitScheduler, ["config", "core.hooksPath", emptyHooks], mergeRoot, 923);
		File.saveContent(mergeRoot + "/conflict.txt", "base\n");
		File.saveContent(mergeRoot + "/conflict-both.txt", "base both\n");
		runGit(git, gitScheduler, ["add", "conflict.txt"], mergeRoot, 924);
		runGit(git, gitScheduler, ["add", "conflict-both.txt"], mergeRoot, 924);
		runGit(git, gitScheduler, ["commit", "-m", "base"], mergeRoot, 925);
		var baseBranch = StringTools.trim(runGit(git, gitScheduler, ["symbolic-ref", "--short", "HEAD"], mergeRoot, 926).stdout.toString());
		runGit(git, gitScheduler, ["branch", "conflict-side"], mergeRoot, 927);
		File.saveContent(mergeRoot + "/conflict.txt", "ours\n");
		File.saveContent(mergeRoot + "/conflict-both.txt", "ours both\n");
		runGit(git, gitScheduler, ["add", "conflict.txt"], mergeRoot, 928);
		runGit(git, gitScheduler, ["add", "conflict-both.txt"], mergeRoot, 928);
		runGit(git, gitScheduler, ["commit", "-m", "ours"], mergeRoot, 929);
		runGit(git, gitScheduler, ["checkout", "conflict-side"], mergeRoot, 930);
		File.saveContent(mergeRoot + "/conflict.txt", "theirs\n");
		File.saveContent(mergeRoot + "/conflict-both.txt", "theirs both\n");
		runGit(git, gitScheduler, ["add", "conflict.txt"], mergeRoot, 931);
		runGit(git, gitScheduler, ["add", "conflict-both.txt"], mergeRoot, 931);
		runGit(git, gitScheduler, ["commit", "-m", "theirs"], mergeRoot, 932);
		runGit(git, gitScheduler, ["checkout", baseBranch], mergeRoot, 933);
		var mergeAttempt = runGitResult(git, gitScheduler, ["merge", "conflict-side"], mergeRoot, 934);
		require(mergeAttempt.error != null && File.getContent(mergeRoot + "/conflict.txt").indexOf("<<<<<<<") >= 0,
			"The real Git merge fixture did not leave a content conflict");
		var mergeService = new ScmService(processManager, gitScheduler, git.executable, 100, 0, false,
			fixtureBase + "/merge-trust.json", emptyHooks), mergeDiscovery:Null<ScmJobResult<Array<ScmRepository>>> = null;
		mergeService.discover(mergeRoot, value -> mergeDiscovery = value);
		pumpService(mergeService, gitScheduler, () -> mergeDiscovery != null, "Merge-conflict service discovery timed out");
		if (mergeDiscovery == null || mergeDiscovery.value == null || mergeDiscovery.value.length != 1)
			throw "Merge-conflict service returned no repository";
		var mergeRepository = mergeDiscovery.value[0];
		mergeService.setWatchAvailable(mergeRoot, true);
		pumpService(mergeService, gitScheduler, () -> mergeService.snapshot(mergeRepository.id) != null,
			"Merge-conflict service refresh timed out");
		var mergeSnapshot:ScmSnapshot = cast mergeService.snapshot(mergeRepository.id), mergeGroup = snapshotGroup(mergeSnapshot, ScmGroupId.Merge),
			mergeConflict:Null<scm.ScmResource> = null;
		if (mergeGroup != null) for (resource in mergeGroup.resources) if (resource.path == "conflict.txt") mergeConflict = resource;
		require(mergeSnapshot.head.operation == ScmHeadOperation.Merge && mergeConflict != null
			&& mergeConflict.conflictKind == ScmConflictKind.BothModified,
			"A real Git merge conflict was not refreshed into the merge group with its conflict kind");
		var trustNotices:Array<Bool> = [];
		var stopTrustNotices = mergeService.subscribe(function(repository, _) {
			if (repository.id == mergeRepository.id) trustNotices.push(repository.trusted);
		});
		require(mergeService.trust(mergeRepository.id), "Could not trust the merge-resolution fixture");
		require(trustNotices.length == 1 && trustNotices[0],
			"Trusting a repository did not notify subscribers, so views kept showing it as restricted");
		stopTrustNotices();
		pumpService(mergeService, gitScheduler, () -> {
			var repositories = mergeService.repositories(mergeRoot), current = mergeService.snapshot(mergeRepository.id);
			return repositories.length == 1 && repositories[0].trusted && current != null;
		}, "Trusted merge-resolution fixture did not refresh");
		var conflictResolution:Null<ScmJobResult<ScmApplyResult>> = null;
		mergeService.apply(mergeRepository.id, ScmOperation.ResolveConflict("conflict.txt", "ours"), 935,
			value -> conflictResolution = value);
		pumpService(mergeService, gitScheduler, () -> conflictResolution != null, "Git conflict resolution timed out");
		var resolvedConflictContent = File.getContent(mergeRoot + "/conflict.txt");
		var unresolvedConflictStages = runGit(git, gitScheduler, ["ls-files", "-u", "--", "conflict.txt"], mergeRoot, 936).stdout.toString();
		require(conflictResolution != null && conflictResolution.error == null
			&& normalizeLineEndings(resolvedConflictContent) == "ours\n" && unresolvedConflictStages.length == 0,
			"Accept Ours failed (error=" + (conflictResolution == null || conflictResolution.error == null ? "none" : conflictResolution.error.message)
				+ ", content=" + StringTools.replace(resolvedConflictContent, "\n", "\\n")
				+ ", unmerged=" + StringTools.replace(unresolvedConflictStages, "\n", "\\n") + ")");
		var bothResolution:Null<ScmJobResult<ScmApplyResult>> = null;
		mergeService.apply(mergeRepository.id, ScmOperation.ResolveConflict("conflict-both.txt", "both"), 937,
			value -> bothResolution = value);
		pumpService(mergeService, gitScheduler, () -> bothResolution != null, "Git Accept Both resolution timed out");
		var remainingConflictStages = runGit(git, gitScheduler, ["ls-files", "-u"], mergeRoot, 938).stdout.toString();
		require(bothResolution != null && bothResolution.error == null
			&& normalizeLineEndings(File.getContent(mergeRoot + "/conflict-both.txt")) == "ours both\ntheirs both\n"
			&& remainingConflictStages.length == 0,
			"Accept Both did not retain both sides in order and stage the resolved file");
		mergeService.dispose();

		var emptyDirectory = fixtureBase + "/not-a-repository";
		FileSystem.createDirectory(emptyDirectory);
		var emptyDetection:Null<ScmJobResult<Array<scm.ScmRepositoryHandle>>> = null;
		provider.detect(emptyDirectory, 75, value -> emptyDetection = value);
		pump(gitScheduler, () -> emptyDetection != null, "Non-repository detection timed out");
		require(emptyDetection != null && emptyDetection.error == null && emptyDetection.value != null && emptyDetection.value.length == 0,
			"A non-repository directory did not produce an empty discovery result");
		deleteTree(emptyDirectory);
		deleteTree(fixtureBase);
		var nonRepository = newPath(temporaryDirectory + "/exosuit-scm-nonrepo-" + fixtureId);
		FileSystem.createDirectory(nonRepository);
		var repositoryError:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["rev-parse", "--show-toplevel"], nonRepository, 53, value -> repositoryError = value);
		deadline = Sys.time() + 10.0;
		while (gitScheduler.activeCount() > 0 && Sys.time() < deadline) { gitScheduler.update(32); Sys.sleep(0.001); }
		FileSystem.deleteDirectory(nonRepository);
		if (repositoryError == null || repositoryError.error == null) throw "non-repository Git command unexpectedly succeeded";
		require(repositoryError.error.code == "not_a_repository" && processManager.activeCount() == 0,
			"Git error mapping or process cleanup was incorrect: " + repositoryError.error.code + ", active=" + processManager.activeCount()
				+ ", message=" + repositoryError.error.message);
		var repositoryRootResult:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["rev-parse", "--show-toplevel"], Sys.getCwd(), 54, value -> repositoryRootResult = value);
		deadline = Sys.time() + 10.0;
		while (gitScheduler.activeCount() > 0 && Sys.time() < deadline) { gitScheduler.update(32); Sys.sleep(0.001); }
		if (repositoryRootResult == null || repositoryRootResult.value == null) throw "could not locate the fixture repository for process cancellation";
		var repositoryRoot = StringTools.trim(repositoryRootResult.value.stdout.toString()), statusResult:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["status", "--porcelain=v2", "-z", "--branch"], repositoryRoot, 55, value -> statusResult = value);
		deadline = Sys.time() + 10.0;
		while (gitScheduler.activeCount() > 0 && Sys.time() < deadline) { gitScheduler.update(32); Sys.sleep(0.001); }
		if (statusResult == null || statusResult.value == null) throw "Git porcelain v2 status did not return its NUL-delimited bytes";
		var statusCommandResult = statusResult.value;
		if (statusCommandResult == null) throw "Git status result disappeared";
		var hasNul = false;
		for (index in 0...statusCommandResult.stdout.length) if (statusCommandResult.stdout.get(index) == 0) { hasNul = true; break; }
		require(hasNul, "Git process runner decoded or removed porcelain NUL delimiters");
		var processCallback = false, waitingJob = git.run(["cat-file", "--batch"], repositoryRoot, 56,
			_ -> processCallback = true);
		gitScheduler.update(1);
		require(processManager.activeCount() == 1 && waitingJob.cancel(), "Git process cancellation did not own the started process");
		require(processManager.activeCount() == 0 && !processCallback && waitingJob.cancelled,
			"cancelling Git work leaked a process or published a stale result");

		var blobReader = new GitBlobReader(processManager, gitScheduler, git, repositoryRoot, false, 4096),
			smallPath = Bytes.ofString("src/scm/ScmBlob.hx"), smallBytes = File.getBytes(repositoryRoot + "/src/scm/ScmBlob.hx"),
			firstBlob = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 60);
		require(firstBlob.error == null && firstBlob.value != null
			&& normalizeNewlines(firstBlob.value.bytes.toString()) == normalizeNewlines(smallBytes.toString()) && !firstBlob.value.binary,
			"cat-file batch did not return the raw text blob");
		var sharedProcessId = blobReader.activeProcessId();
		require(sharedProcessId > 0 && processManager.activeCount() == 1, "blob reader did not retain its batch process");
		for (index in 0...1000) {
			var repeated = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 61 + index);
			require(repeated.value != null && repeated.error == null
				&& normalizeNewlines(repeated.value.bytes.toString()) == normalizeNewlines(smallBytes.toString())
				&& blobReader.activeProcessId() == sharedProcessId && processManager.activeCount() == 1,
				'blob read $index did not reuse one process or preserve its bytes');
		}
		var objectNamesResult:Null<ScmJobResult<scm.git.GitCommandResult>> = null;
		git.run(["cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)"], repositoryRoot, 57,
			value -> objectNamesResult = value);
		pump(gitScheduler, () -> objectNamesResult != null, "Git object-prefix fixture did not finish");
		var objectNames = objectNamesResult;
		if (objectNames == null || objectNames.value == null) throw "Git object-prefix fixture returned no ids";
		var seenPrefixes:Map<String, Bool> = [], ambiguousPrefix:Null<String> = null;
		for (objectLine in objectNames.value.stdout.toString().split("\n")) {
			var fields = StringTools.trim(objectLine).split(" ");
			if (fields.length != 2 || fields[1] != "commit") continue;
			var candidate = fields[0];
			if (candidate.length < 4) continue;
			var prefix = candidate.substr(0, 4);
			if (seenPrefixes.exists(prefix)) { ambiguousPrefix = prefix; break; }
			seenPrefixes.set(prefix, true);
		}
		if (ambiguousPrefix != null) {
			var ambiguousBlob = readBlobObject(blobReader, gitScheduler, ambiguousPrefix, 58);
			require(ambiguousBlob.error != null && ambiguousBlob.error.code == "ambiguous_object",
				"ambiguous Git object prefix did not map to its stable error");
			var ambiguousPath = readBlob(blobReader, gitScheduler, ambiguousPrefix, Bytes.ofString("src/scm/ScmBlob.hx"), 59);
			require(ambiguousPath.error != null && ambiguousPath.error.code == "ambiguous_object",
				"ambiguous revision in a path request was mistaken for a missing file");
		}
		var binaryBlob = readBlob(blobReader, gitScheduler, "HEAD", Bytes.ofString("graphical/assets/icons/exosuit-16.png"), 1061);
		require(binaryBlob.value != null && binaryBlob.value.binary && binaryBlob.value.bytes.compare(File.getBytes(repositoryRoot + "/graphical/assets/icons/exosuit-16.png")) == 0,
			"NUL in the first 8000 bytes did not mark a blob as binary");
		var missingBlob = readBlob(blobReader, gitScheduler, "HEAD", Bytes.ofString("scm/no-such-file"), 1062);
		require(missingBlob.error != null && missingBlob.error.code == "missing_object"
			&& blobReader.activeProcessId() == sharedProcessId, "missing blob was not mapped without restarting the reader");
		var largeBlob = readBlob(blobReader, gitScheduler, "HEAD", Bytes.ofString("docs/roadmap/STATUS.md"), 1063);
		require(largeBlob.error != null && largeBlob.error.code == "blob_too_large"
			&& blobReader.activeProcessId() == sharedProcessId, "oversized blob was not drained by its header size");
		var afterOversized = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 1064);
		require(afterOversized.value != null
			&& normalizeNewlines(afterOversized.value.bytes.toString()) == normalizeNewlines(smallBytes.toString()),
			"a read after an oversized blob was misaligned");

		var blobCancelledCallback = false, cancelledBlob = blobReader.read("HEAD", Bytes.ofString("docs/roadmap/STATUS.md"), 1065,
			_ -> blobCancelledCallback = true);
		gitScheduler.update(1);
		var followingBlob:Null<ScmJobResult<ScmBlob>> = null;
		blobReader.read("HEAD", smallPath, 1066, value -> followingBlob = value);
		require(cancelledBlob.cancel(), "in-flight blob read refused cancellation");
		pump(gitScheduler, () -> followingBlob != null, "reader did not drain a cancelled blob before serving the next request");
			require(!blobCancelledCallback && followingBlob != null && followingBlob.error == null && followingBlob.value != null
			&& normalizeNewlines(followingBlob.value.bytes.toString()) == normalizeNewlines(smallBytes.toString())
			&& blobReader.activeProcessId() == sharedProcessId,
			"cancelled response bytes were misattributed or the reader process was not reused");
		// A reader disposed under a read in progress (its repository handle closed) answers it rather than leaving it
		// waiting: callers cannot see the handle go.
		var closingReader = new GitBlobReader(processManager, gitScheduler, git, repositoryRoot, false, 1024 * 1024),
			closedBlob:Null<ScmJobResult<ScmBlob>> = null;
		closingReader.read("HEAD", Bytes.ofString("docs/roadmap/STATUS.md"), 1067, value -> closedBlob = value);
		gitScheduler.update(1);
		closingReader.dispose();
		require(closedBlob != null && closedBlob.error != null && closedBlob.error.code == "repository_closed" && closedBlob.error.retryable,
			"a blob read in progress when its reader was disposed was left without an answer");

		var interrupted:Null<ScmJobResult<ScmBlob>> = null;
		blobReader.read("HEAD", Bytes.ofString("docs/roadmap/STATUS.md"), 1067, value -> interrupted = value);
		gitScheduler.update(1);
		blobReader.configurationChanged();
		pump(gitScheduler, () -> interrupted != null, "config change did not retire the active blob request");
		var interruptedResult = interrupted;
		if (interruptedResult == null) throw "config change result disappeared";
		require(interruptedResult.error != null && interruptedResult.error.retryable && processManager.activeCount() == 0,
			"repository config change did not return a retryable error and close the old process");
		var restarted = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 1068);
		var restartedProcessId = blobReader.activeProcessId();
		require(restarted.value != null && normalizeNewlines(restarted.value.bytes.toString()) == normalizeNewlines(smallBytes.toString()) && restartedProcessId > 0
			&& restartedProcessId != sharedProcessId, "reader did not start a fresh process after a config change");
		require(blobReader.expireIdle(Sys.time() + GitBlobReader.DEFAULT_IDLE_TIMEOUT_SECONDS + 1)
			&& processManager.activeCount() == 0, "idle timeout did not close the batch process");
		var afterIdle = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 1069);
		require(afterIdle.value != null && normalizeNewlines(afterIdle.value.bytes.toString()) == normalizeNewlines(smallBytes.toString())
			&& blobReader.activeProcessId() != restartedProcessId,
			"blob reader did not restart after its idle timeout");
		var interruptedByExit:Null<ScmJobResult<ScmBlob>> = null;
		blobReader.read("HEAD", Bytes.ofString("docs/roadmap/STATUS.md"), 1070, value -> interruptedByExit = value);
		gitScheduler.update(1);
		processManager.shutdown();
		gitScheduler.update(1);
		pump(gitScheduler, () -> interruptedByExit != null, "reader did not report a process exit mid-response");
		var exitResult = interruptedByExit;
		if (exitResult == null) throw "process exit result disappeared";
		require(exitResult.error != null && exitResult.error.retryable && processManager.activeCount() == 0,
			"process exit mid-response did not yield a retryable error");
		var afterExit = readBlob(blobReader, gitScheduler, "HEAD", smallPath, 1071);
		require(afterExit.value != null && normalizeNewlines(afterExit.value.bytes.toString()) == normalizeNewlines(smallBytes.toString()),
			"reader did not recover after its process exited");

		blobReader.dispose();
		require(processManager.activeCount() == 0, "disposing the blob reader leaked its owned process");

		var hooksTempDirectory = systemTemporaryDirectory();
		var hooksPath = newPath(hooksTempDirectory + "/exosuit-scm-empty-hooks-" + Std.string(Std.int(Sys.time() * 1000000)));
		FileSystem.createDirectory(hooksPath);
		var restrictedGit = new GitProcess(processManager, gitScheduler, "", hooksPath), restrictedVersion:Null<ScmJobResult<GitVersion>> = null;
		restrictedGit.probeVersion(1072, value -> restrictedVersion = value);
		pump(gitScheduler, () -> restrictedVersion != null, "restricted Git version probe did not finish");
		var restrictedReader = new GitBlobReader(processManager, gitScheduler, restrictedGit, repositoryRoot, true, 4096),
			restrictedBlob = readBlob(restrictedReader, gitScheduler, "HEAD", smallPath, 1073);
		require(restrictedBlob.value != null && restrictedBlob.error == null && processManager.activeCount() == 1,
			"restricted raw batch reader did not return its blob");
		restrictedReader.dispose();
		FileSystem.deleteDirectory(hooksPath);
		processManager.shutdown();

		var diff = runDiff("a\nb\nc\nd\n", "a\nB\nc\ne\n", LineDiff.DEFAULT_MAX_COST, 1);
		require(diff.length == 2 && diff[0].kind == LineDiffKind.Modified && diff[0].oldStart == 1 && diff[0].newStart == 1
			&& diff[1].oldStart == 3 && diff[1].newStart == 3, "Myers line diff did not isolate separated modifications");
		var added = runDiff("a\nb", "a\nx\nb");
		require(added.length == 1 && added[0].kind == LineDiffKind.Added && added[0].oldStart == 1 && added[0].oldCount == 0
			&& added[0].newStart == 1 && added[0].newCount == 1, "added hunk ranges were incorrect");
		var deleted = runDiff("a\nx\nb", "a\nb");
		require(deleted.length == 1 && deleted[0].kind == LineDiffKind.Deleted && deleted[0].oldStart == 1 && deleted[0].oldCount == 1
			&& deleted[0].newStart == 1 && deleted[0].newCount == 0, "deleted hunk ranges were incorrect");
		require(runDiff("a\n", "a").length == 1 && runDiff("same", "same").length == 0,
			"line diff ignored a final-newline change or reported an identical document");
		require(runDiff("a\r\nb\r\n", "a\nb\n").length == 0,
			"line diff treated CRLF and LF as different content");
		var fallback = runDiff("one\ntwo", "other\nlines", 1);
		require(fallback.length == 1 && fallback[0].kind == LineDiffKind.Modified && fallback[0].oldStart == 0
			&& fallback[0].oldCount == 2 && fallback[0].newStart == 0 && fallback[0].newCount == 2,
			"cost budget did not degrade to one whole-range hunk");
		var alignedDiff = new scm.ScmDiffDocument(gitScheduler, "fixture", "file.txt", "INDEX→WORKTREE", "1",
			"a\nremove\nc\nend\n", "a\nadd one\nadd two\nc\nend\n");
		pump(gitScheduler, () -> alignedDiff.hunks.length > 0, "side-by-side diff did not finish");
		require(alignedDiff.alignedOldText == "a\nremove\n\nc\nend\n"
			&& alignedDiff.alignedCurrentText == "a\nadd one\nadd two\nc\nend\n"
			&& alignedDiff.alignedOldChangedLines.length == 2 && alignedDiff.alignedCurrentChangedLines.length == 2,
			"side-by-side diff did not insert aligned padding rows around the changed hunk");
		alignedDiff.dispose();
		for (caseIndex in 0...100) {
			var original:Array<String> = [];
			for (index in 0...nextRandom(18)) original.push("line-" + nextRandom(9));
			var edited = original.copy();
			for (_ in 0...nextRandom(9)) {
				var action = nextRandom(3), at = nextRandom(edited.length + 1);
				if (action == 0 || edited.length == 0) edited.insert(at, "insert-" + caseIndex + "-" + nextRandom(20));
				else if (action == 1) edited.splice(at == edited.length ? at - 1 : at, 1);
				else edited[at == edited.length ? at - 1 : at] = "replace-" + caseIndex + "-" + nextRandom(20);
			}
			var oldText = encodeLines(original, (caseIndex & 1) == 0), newText = encodeLines(edited, (caseIndex & 2) == 0), hunks = runDiff(oldText, newText);
			require(reconstruct(oldText, newText, hunks) == newText, 'line diff reconstruction failed for deterministic edit case $caseIndex');
		}
		var largeOld:Array<String> = [], largeNew:Array<String> = [];
		for (index in 0...10000) largeOld.push("source-line-" + index);
		largeNew = largeOld.copy();
		for (index in 0...50) largeNew[index * 190 + 25] = "changed-line-" + index;
		var largeOldText = encodeLines(largeOld, true), largeNewText = encodeLines(largeNew, true), started = Sys.time();
		var largeHunks = runDiff(largeOldText, largeNewText);
		var largeMillis = (Sys.time() - started) * 1000.0;
		require(largeHunks.length == 50 && reconstruct(largeOldText, largeNewText, largeHunks) == largeNewText,
			"10,000-line scattered diff did not converge to its edits");
		require(largeMillis < 100.0, '10,000-line scattered diff exceeded 100 ms: ${largeMillis} ms');
		require(lastMaxDiffSliceMillis < 4.0, 'LineDiff slice exceeded 4 ms: ${lastMaxDiffSliceMillis} ms');
		Sys.println('LINE_DIFF lines=10000 edits=50 elapsed_ms=${Std.int(largeMillis)} max_slice_ms=${lastMaxDiffSliceMillis}');
		Sys.println("PASS: SCM model, porcelain parser, trust store, nested Git discovery, restricted filter status, service, blob reader and line diff");
		return 0;
	}
}
