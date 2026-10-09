package app;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.Int64;
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
import scm.ScmRepositoryKind;
import scm.ScmSnapshot;
import jobs.JobScheduler;
import scm.fake.FakeScmProvider;
import scm.fake.FakeScmRepositoryScript;
import scm.git.GitStatusParser;
import scm.git.GitProcess;
import scm.git.GitVersion;
import process.ProcessManager;
import sys.FileSystem;

class ScmGitTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function record(bytes:BytesBuffer, value:String):Void {
		bytes.addString(value);
		bytes.addByte(0);
	}

	static function group(result:scm.git.GitStatusParseResult, id:ScmGroupId):Array<scm.ScmResource> {
		for (value in result.groups) if (value.id == id) return value.resources;
		return [];
	}

	static function runDiff(oldText:String, newText:String, maxCost:Int = LineDiff.DEFAULT_MAX_COST, sliceCost:Int = LineDiff.DEFAULT_SLICE_COST):Array<LineDiffHunk> {
		var result:Null<Array<LineDiffHunk>> = null, task = new LineDiff(oldText, newText, value -> result = value, maxCost, sliceCost),
			scheduler = new JobScheduler();
		scheduler.schedule(task);
		var steps = 0;
		while (scheduler.activeCount() > 0 && steps < 100000) { scheduler.update(1); steps++; }
		require(task.finished && result != null && steps < 100000, "line diff did not finish as a scheduled job");
		return result;
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

	static function main():Int {
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
		var temporaryDirectory = Sys.getEnv("TEMP");
		if (temporaryDirectory == null || temporaryDirectory.length == 0) temporaryDirectory = Sys.getEnv("TMP");
		if (temporaryDirectory == null || temporaryDirectory.length == 0) temporaryDirectory = Sys.getCwd();
		var nonRepository = FileSystem.fullPath(temporaryDirectory + "/exosuit-scm-nonrepo-" + Std.string(Std.int(Sys.time() * 1000000)));
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
		var fallback = runDiff("one\ntwo", "other\nlines", 1);
		require(fallback.length == 1 && fallback[0].kind == LineDiffKind.Modified && fallback[0].oldStart == 0
			&& fallback[0].oldCount == 2 && fallback[0].newStart == 0 && fallback[0].newCount == 2,
			"cost budget did not degrade to one whole-range hunk");
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
		Sys.println('LINE_DIFF lines=10000 edits=50 elapsed_ms=${Std.int(largeMillis)}');
		Sys.println("PASS: SCM model, porcelain v2 parser, fake provider, Git process runner and line diff");
		return 0;
	}
}
