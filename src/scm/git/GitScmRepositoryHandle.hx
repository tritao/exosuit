package scm.git;

import haxe.Int64;
import haxe.io.Bytes;
import jobs.JobScheduler;
import process.ProcessManager;
import scm.ScmApplyResult;
import scm.ScmBlob;
import scm.ScmError;
import scm.ScmFeatures;
import scm.ScmJob;
import scm.ScmJobResult;
import scm.ScmOperation;
import scm.ScmRef;
import scm.ScmRepository;
import scm.ScmSnapshot;
import scm.ScmRepositoryHandle;
import sys.FileSystem;

/** Git status and original-content access for one worktree. */
class GitScmRepositoryHandle implements ScmRepositoryHandle {
	final process:GitProcess;
	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final gitDir:String;
	final commonDir:String;
	final trustStore:Null<scm.ScmTrustStore>;
	final untrackedLimit:Int;
	final kind:scm.ScmRepositoryKind;
	final parentId:Null<String>;
	var blobReader:GitBlobReader;
	var blobReaderRestricted:Bool;
	var current:Null<ScmSnapshot>;
	var signature:Null<Bytes>;
	var signatureOperation:Null<scm.ScmHeadOperation>;
	var revision:Int64 = Int64.ofInt(0);
	var disposed:Bool = false;

	public final id:String;
	public final root:String;

	public function new(id:String, root:String, gitDir:String, commonDir:String, processes:ProcessManager,
			scheduler:JobScheduler, process:GitProcess, trustStore:Null<scm.ScmTrustStore>, untrackedLimit:Int,
			kind:scm.ScmRepositoryKind, ?parentId:String) {
		this.id = id;
		this.root = root;
		this.gitDir = gitDir;
		this.commonDir = commonDir;
		this.processes = processes;
		this.scheduler = scheduler;
		this.process = process;
		this.trustStore = trustStore;
		this.untrackedLimit = untrackedLimit < 0 ? 0 : untrackedLimit;
		this.kind = kind;
		this.parentId = parentId;
		blobReaderRestricted = !trusted();
		blobReader = new GitBlobReader(processes, scheduler, process, root, blobReaderRestricted, 64 * 1024 * 1024);
	}

	public function repository():ScmRepository return new ScmRepository(id, "git", root, kind, parentId, trusted());

	/** Directories whose changes can affect this repository's status or refs. */
	public function watchDirectories():Array<String> {
		var seen:Map<String, Bool> = [], result:Array<String> = [];
		for (path in [root, gitDir, commonDir]) {
			var key = Sys.systemName() == "Windows" ? path.toLowerCase() : path;
			if (!seen.exists(key)) { seen.set(key, true); result.push(path); }
		}
		return result;
	}

	public function metadataChanged(path:String):Bool {
		var changed = pathKey(path);
		for (candidate in [root + "/.git", gitDir + "/config", gitDir + "/config.worktree", gitDir + "/commondir", commonDir + "/config"])
			if (changed == pathKey(candidate)) return true;
		return false;
	}

	public function configurationChanged():Void {
		if (!disposed) blobReader.configurationChanged();
	}

	public function features():ScmFeatures {
		// Mutations are added in the operation slice; restricted roots never advertise them.
		return new ScmFeatures();
	}

	public function trusted():Bool return trustStore != null && trustStore.isTrusted(root);

	public function refresh(generation:Int, complete:ScmJobResult<ScmSnapshot>->Void):ScmJob<ScmSnapshot> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		var command:Null<ScmJob<GitCommandResult>> = null;
		var job = new ScmJob<ScmSnapshot>(generation, function() {
			if (command != null) command.cancel();
		});
		function finishStatus(result:ScmJobResult<GitCommandResult>):Void {
				if (job.cancelled || job.complete) return;
				if (result.error != null) {
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null, result.error));
					return;
				}
				var output = result.value == null ? Bytes.alloc(0) : result.value.stdout;
				try {
					var operationState = operation();
					var parsed = GitStatusParser.parse(output, false, operationState), groups = limitUntracked(parsed.groups);
					if (!sameBytes(signature, output) || signatureOperation != operationState) {
						revision = Int64.add(revision, Int64.ofInt(1));
						signature = output.sub(0, output.length);
						signatureOperation = operationState;
					}
					var snapshot = new ScmSnapshot(revision, parsed.head, groups.groups, groups.truncated);
					current = snapshot;
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, snapshot));
				} catch (failure:Dynamic) {
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null,
						new ScmError("invalid_status", "Git returned invalid status data: " + Std.string(failure))));
				}
		}
		function runStatus(disabledFilters:Array<String>):Void {
			command = process.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], root, generation,
				finishStatus, true, !trusted(), GitProcess.DEFAULT_MAX_STDOUT, disabledFilters);
		}
		if (trusted()) {
			runStatus([]);
		} else {
			// `status` may run clean filters while comparing a worktree file. Inspect
			// config names first, then override every external command for those filters.
			command = process.run(["config", "--null", "--name-only", "--list"], root, generation, function(result) {
				if (job.cancelled || job.complete) return;
				if (result.error != null || result.value == null) {
					var message = "Git configuration could not be inspected safely; repository status was not read";
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null,
						new ScmError("restricted_config_failed", message)));
					return;
				}
				try runStatus(configuredFilters(result.value.stdout)) catch (failure:Dynamic) {
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null,
						new ScmError("restricted_config_failed", "Git filter configuration was malformed; repository status was not read")));
				}
			}, true, true, 1024 * 1024);
		}
		return job;
	}

	public function original(reference:ScmRef, path:String, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		ensureBlobReaderTrustMode();
		var spec = switch reference {
			case Head: "HEAD";
			case Index: ":0";
			case Commit(oid): oid;
			case ConflictStage(stage): ":" + Std.string(stage);
		};
		return blobReader.read(spec, Bytes.ofString(path), generation, complete);
	}

	public function apply(operation:ScmOperation, generation:Int, complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		var code = trusted() ? "unsupported" : "untrusted";
		var message = trusted() ? "Git mutations are not available yet" : "Trust this repository on this machine before changing it";
		return failed(generation, complete, code, message);
	}

	public function expireBlobReader(now:Float):Void {
		if (disposed) return;
		ensureBlobReaderTrustMode();
		blobReader.expireIdle(now);
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		blobReader.dispose();
	}

	function operation():scm.ScmHeadOperation {
		if (FileSystem.exists(gitDir + "/MERGE_HEAD")) return scm.ScmHeadOperation.Merge;
		if (FileSystem.exists(gitDir + "/rebase-merge") || FileSystem.exists(gitDir + "/rebase-apply")) return scm.ScmHeadOperation.Rebase;
		if (FileSystem.exists(gitDir + "/CHERRY_PICK_HEAD")) return scm.ScmHeadOperation.CherryPick;
		if (FileSystem.exists(gitDir + "/REVERT_HEAD")) return scm.ScmHeadOperation.Revert;
		if (FileSystem.exists(gitDir + "/BISECT_LOG")) return scm.ScmHeadOperation.Bisect;
		return scm.ScmHeadOperation.None;
	}

	function ensureBlobReaderTrustMode():Void {
		var restricted = !trusted();
		if (restricted == blobReaderRestricted) return;
		blobReader.dispose();
		blobReaderRestricted = restricted;
		blobReader = new GitBlobReader(processes, scheduler, process, root, restricted, 64 * 1024 * 1024);
	}

	function limitUntracked(groups:Array<scm.ScmGroup>):{groups:Array<scm.ScmGroup>, truncated:Bool} {
		var remaining = untrackedLimit, truncated = false, result:Array<scm.ScmGroup> = [];
		for (group in groups) {
			if (group.id != scm.ScmGroupId.Untracked) {
				result.push(group);
				continue;
			}
			if (group.resources.length > remaining) truncated = true;
			var count = Std.int(Math.min(group.resources.length, remaining));
			result.push(new scm.ScmGroup(group.id, group.resources.slice(0, count)));
			remaining -= count;
		}
		return {groups: result, truncated: truncated};
	}

	static function sameBytes(left:Null<Bytes>, right:Bytes):Bool {
		if (left == null || left.length != right.length) return false;
		for (index in 0...right.length) if (left.get(index) != right.get(index)) return false;
		return true;
	}

	static function pathKey(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/")) normalized = normalized.substring(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	static function configuredFilters(bytes:Bytes):Array<String> {
		var filters:Map<String, Bool> = [];
		if (bytes.length == 0) return [];
		if (bytes.get(bytes.length - 1) != 0) throw "Git config names were not NUL terminated";
		var start = 0;
		for (index in 0...bytes.length) {
			if (bytes.get(index) != 0) continue;
			var key = bytes.sub(start, index - start).toString();
			start = index + 1;
			if (key.length == 0 || !StringTools.startsWith(key, "filter.")) continue;
			for (suffix in [".process", ".clean", ".smudge"]) {
				if (!StringTools.endsWith(key, suffix)) continue;
				var name = key.substring("filter.".length, key.length - suffix.length);
				if (name.length > 0) filters.set(name, true);
			}
		}
		var result = [for (name in filters.keys()) name];
		result.sort(Reflect.compare);
		return result;
	}

	function failed<T>(generation:Int, complete:ScmJobResult<T>->Void, code:String, message:String):ScmJob<T> {
		var job = new ScmJob<T>(generation);
		if (job.finish()) complete(new ScmJobResult<T>(generation, null, new ScmError(code, message)));
		return job;
	}
}
