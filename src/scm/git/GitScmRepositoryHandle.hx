package scm.git;

import haxe.Int64;
import haxe.io.Bytes;
import jobs.JobHandle;
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
import sys.io.File;

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

	/** Directories a watch of this repository can leave out: those Git ignores, which hold build output and other
		generated trees, and the object store, whose writes never change status on their own. Absolute paths. */
	public function watchExclusions(generation:Int, complete:ScmJobResult<Array<String>>->Void):ScmJob<Array<String>> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		var command:Null<ScmJob<GitCommandResult>> = null;
		var job = new ScmJob<Array<String>>(generation, function() {
			if (command != null) command.cancel();
		});
		command = process.run(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], root, generation,
			function(result) {
				if (job.cancelled || job.complete) return;
				var excluded:Array<String> = [];
				for (directory in [gitDir, commonDir]) {
					var objects = directory + "/objects";
					if (excluded.indexOf(objects) < 0) excluded.push(objects);
				}
				// Without the list, the watch covers everything, as it did before exclusions existed.
				if (result.error == null && result.value != null) {
					// NUL-separated entries; directories end with "/".
					var output = result.value.stdout, start = 0;
					for (index in 0...output.length + 1) {
						if (index < output.length && output.get(index) != 0) continue;
						if (index - start > 1 && output.get(index - 1) == "/".code)
							excluded.push(root + "/" + output.getString(start, index - start - 1));
						start = index + 1;
					}
				}
				if (job.finish()) complete(new ScmJobResult<Array<String>>(generation, excluded));
			}, true, !trusted(), 16 * 1024 * 1024);
		return job;
	}

	/** Whether a changed path can change which directories Git ignores. */
	public function ignoreRulesChanged(path:String):Bool {
		var changed = pathKey(path);
		return StringTools.endsWith(changed, "/.gitignore") || changed == pathKey(gitDir + "/info/exclude") ||
			changed == pathKey(commonDir + "/info/exclude");
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
		var allowed = trusted();
		return new ScmFeatures(allowed, allowed, allowed, allowed, allowed, false);
	}

	public function trusted():Bool return trustStore != null && trustStore.isTrusted(root);

	public function branches(generation:Int, complete:ScmJobResult<Array<ScmBranch>>->Void):ScmJob<Array<ScmBranch>> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		var command:Null<ScmJob<GitCommandResult>> = null;
		var job = new ScmJob<Array<ScmBranch>>(generation, function() {
			if (command != null) command.cancel();
		});
		command = process.run(["for-each-ref", "--format=%(refname)%09%(HEAD)%09%(symref)", "refs/heads", "refs/remotes"],
			root, generation, function(result) {
				if (job.cancelled || job.complete) return;
				if (result.error != null) {
					if (job.finish()) complete(new ScmJobResult<Array<ScmBranch>>(generation, null, result.error));
					return;
				}
				try {
					var branches = GitBranchParser.parse(result.value == null ? Bytes.alloc(0) : result.value.stdout);
					if (job.finish()) complete(new ScmJobResult<Array<ScmBranch>>(generation, branches));
				} catch (failure:Dynamic) {
					if (job.finish()) complete(new ScmJobResult<Array<ScmBranch>>(generation, null,
						new ScmError("invalid_refs", "Git returned invalid branch data: " + Std.string(failure))));
				}
			}, true, !trusted(), 1024 * 1024);
		return job;
	}

	public function refresh(generation:Int, complete:ScmJobResult<ScmSnapshot>->Void):ScmJob<ScmSnapshot> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		var command:Null<ScmJob<GitCommandResult>> = null, parserHandle:Null<JobHandle> = null;
		var job = new ScmJob<ScmSnapshot>(generation, function() {
			if (command != null) command.cancel();
			if (parserHandle != null) scheduler.cancel(parserHandle);
		});
		function finishStatus(result:ScmJobResult<GitCommandResult>):Void {
			if (job.cancelled || job.complete) return;
			if (result.error != null) {
				if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null, result.error));
				return;
			}
			var output = result.value == null ? Bytes.alloc(0) : result.value.stdout;
			var operationState = operation();
			var parser:GitStatusParser = null;
			parser = new GitStatusParser(output, false, operationState, untrackedLimit, signature, function(parsed, failure) {
				if (job.cancelled || job.complete) return;
				if (failure != null || parsed == null) {
					var detail = failure == null ? "parser returned no result" : Std.string(failure);
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null,
						new ScmError("invalid_status", "Git returned invalid status data: " + detail)));
					return;
				}
				try {
					if (signature == null || !parser.signatureMatches || signatureOperation != operationState) {
						revision = Int64.add(revision, Int64.ofInt(1));
						signature = output;
						signatureOperation = operationState;
					}
					var snapshot = new ScmSnapshot(revision, parsed.head, parsed.groups, parsed.truncated);
					current = snapshot;
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, snapshot));
				} catch (failure:Dynamic) {
					if (job.finish()) complete(new ScmJobResult<ScmSnapshot>(generation, null,
						new ScmError("invalid_status", "Git returned invalid status data: " + Std.string(failure))));
				}
			});
			parserHandle = scheduler.schedule(parser);
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
		return originalBytes(reference, Bytes.ofString(path), generation, complete);
	}

	public function originalBytes(reference:ScmRef, path:Bytes, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		ensureBlobReaderTrustMode();
		var spec = switch reference {
			case Head: "HEAD";
			case Index: ":0";
			case Commit(oid): oid;
			case ConflictStage(stage): ":" + Std.string(stage);
		};
		return blobReader.read(spec, path, generation, complete);
	}

	public function apply(operation:ScmOperation, generation:Int, complete:ScmJobResult<ScmApplyResult>->Void):ScmJob<ScmApplyResult> {
		if (disposed) return failed(generation, complete, "repository_closed", "The Git repository handle is closed");
		if (!trusted()) return failed(generation, complete, "untrusted", "Trust this repository on this machine before changing it");
		var child:Null<ScmJob<GitCommandResult>> = null;
		var recoveryToken:Null<String> = null;
		var job = new ScmJob<ScmApplyResult>(generation, function() {
			if (child != null) child.cancel();
		});
		function finish(result:ScmJobResult<GitCommandResult>, message:String):Void {
			if (job.cancelled || job.complete) return;
			if (result.error != null) {
				if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, result.error));
				return;
			}
			if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, new ScmApplyResult(current, message, recoveryToken)));
		}
		function run(arguments:Array<String>, input:Null<Bytes>, message:String):Void {
			child = process.run(arguments, root, generation, result -> finish(result, message), false, false,
				GitProcess.DEFAULT_MAX_STDOUT, [], input);
		}
		function validBranchName(name:String):Bool {
			return name != null && name.length > 0 && name.length <= 255 && name.charAt(0) != "-"
				&& name.indexOf("\n") < 0 && name.indexOf("\r") < 0;
		}
		function invalidBranch():Void {
				if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
					new ScmError("invalid_reference", "Enter a valid branch name")));
		}
		function validatePath(path:String):Bool {
			if (path == null || path.length == 0) return false;
			var normalized = StringTools.replace(path, "\\", "/");
			if (StringTools.startsWith(normalized, "/") ||
				(normalized.length >= 2 && normalized.charAt(1) == ":")) return false;
			for (part in normalized.split("/")) if (part == ".." || part == ".") return false;
			return true;
		}
		function allValid(paths:Array<String>):Bool {
			if (paths == null || paths.length == 0) return false;
			for (path in paths) if (!validatePath(path)) return false;
			return true;
		}
		function invalidPath():Void {
			if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
				new ScmError("invalid_path", "Git operation requires repository-relative paths")));
		}
		function relativePath(path:String):String return StringTools.replace(path, "\\", "/");
		function isUntracked(path:String):Bool {
			if (this.current == null) return false;
			var snapshot:ScmSnapshot = cast this.current;
			var normalized = relativePath(path);
			for (group in snapshot.groups) if (group.id == scm.ScmGroupId.Untracked)
				for (resource in group.resources) if (relativePath(resource.path) == normalized) return true;
			return false;
		}
		function validObjectId(value:String):Bool {
			if (value == null || (value.length != 40 && value.length != 64)) return false;
			for (index in 0...value.length) {
				var char = value.charCodeAt(index);
				if (!((char >= 48 && char <= 57) || (char >= 97 && char <= 102))) return false;
			}
			return true;
		}
		function completeDirect(message:String):Void {
			if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, new ScmApplyResult(current, message)));
		}
		function runForPath(path:String, arguments:Array<String>, message:String):Void {
			if (!validatePath(path)) {
				if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
					new ScmError("invalid_path", "Git operation requires a repository-relative path")));
				return;
			}
			run(arguments.concat(["--", StringTools.replace(path, "\\", "/")]), null, message);
		}
		function runCheckedPatch(path:String, arguments:Array<String>, patch:Bytes, message:String):Void {
			if (!validatePath(path)) {
				if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
					new ScmError("invalid_path", "Git operation requires a repository-relative path")));
				return;
			}
			// Patch bytes may come from an RPC client. Restrict Git to the declared
			// repository-relative file even if a malformed patch names other paths.
			var scopedArguments = arguments.copy();
			scopedArguments.push("--include=" + StringTools.replace(path, "\\", "/"));
			var checkArguments = scopedArguments.copy();
			checkArguments.push("--check");
			child = process.run(checkArguments, root, generation, function(check) {
				if (job.cancelled || job.complete) return;
				if (check.error != null) {
					if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, check.error));
				} else run(scopedArguments, patch, message);
			}, false, false, 8192, [], patch);
		}
		switch operation {
			case Stage(path): runForPath(path, ["add"], "Staged " + path);
			case StageAll: run(["add", "-A", "--", "."], null, "Staged all changes");
			case StagePaths(paths):
				var arguments = ["add", "-A", "--"];
				if (paths.length == 0 || !allValid(paths)) invalidPath();
				else { for (path in paths) arguments.push(StringTools.replace(path, "\\", "/")); run(arguments, null, "Staged " + paths.length + " files"); }
			case Unstage(path):
				if (!validatePath(path)) {
					if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, new ScmError("invalid_path", "Git operation requires a repository-relative path")));
				} else {
					var command = current != null && current.head.unborn ? ["rm", "--cached", "--ignore-unmatch"] : ["restore", "--staged"];
					runForPath(path, command, "Unstaged " + path);
				}
			case UnstageAll:
				var command = current != null && current.head.unborn
					? ["rm", "--cached", "-r", "--ignore-unmatch", "--", "."]
					: ["restore", "--staged", "--", "."];
				run(command, null, "Unstaged all changes");
			case UnstagePaths(paths):
				if (paths.length == 0 || !allValid(paths)) invalidPath();
				else {
					var arguments = current != null && current.head.unborn
						? ["rm", "--cached", "-r", "--ignore-unmatch", "--"]
						: ["restore", "--staged", "--"];
					for (path in paths) arguments.push(StringTools.replace(path, "\\", "/"));
					run(arguments, null, "Unstaged " + paths.length + " files");
				}
			case Discard(path):
				if (!validatePath(path)) invalidPath(); else {
				var relative = relativePath(path), target = root + "/" + relative;
				var exists = FileSystem.exists(target) && !FileSystem.isDirectory(target), untracked = isUntracked(path);
				function restoreDiscard():Void {
					if (!exists) recoveryToken = "";
					var args = untracked ? ["clean", "-f", "-d", "--", relative] : ["restore", "--worktree", "--", relative];
					run(args, null, "Discarded changes to " + path);
				}
				if (!exists) restoreDiscard();
				else child = process.run(["hash-object", "-w", "--", relative], root, generation, function(result) {
					if (job.cancelled || job.complete) return;
					if (result.error != null) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, result.error));
						return;
					}
					var token = result.value == null ? "" : StringTools.trim(result.value.stdout.toString());
					if (!validObjectId(token)) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
							new ScmError("operation_failed", "Git did not return a valid discard recovery object")));
						return;
					}
						recoveryToken = token;
					restoreDiscard();
				}, false, false, 256);
				}
			case RestoreDiscard(path, token):
				if (!validatePath(path) || (token != "" && !validObjectId(token))) invalidPath(); else {
				var target = root + "/" + relativePath(path);
				if (token == "") {
					var deleteFailed = false;
					if (FileSystem.exists(target) && !FileSystem.isDirectory(target)) {
						try FileSystem.deleteFile(target) catch (_:Dynamic) deleteFailed = true;
						if (FileSystem.exists(target)) deleteFailed = true;
					}
					if (deleteFailed) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
							new ScmError("restore_failed", "Could not restore the deleted-file state")));
					} else completeDirect("Restored the discarded state of " + path);
				} else child = process.run(["cat-file", "blob", token], root, generation, function(result) {
					if (job.cancelled || job.complete) return;
					if (result.error != null || result.value == null) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
							result.error == null ? new ScmError("restore_failed", "Git returned no discard recovery data") : result.error));
						return;
					}
					try {
						var slash = target.lastIndexOf("/");
						if (slash > 0 && !ensureDirectory(target.substring(0, slash))) throw "Could not create the discarded file's parent directory";
						File.saveBytes(target, result.value.stdout);
						completeDirect("Restored discarded changes to " + path);
					} catch (failure:Dynamic) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
							new ScmError("restore_failed", Std.string(failure))));
					}
				}, false, false, 64 * 1024 * 1024);
				}
			case ResolveConflict(path, choice):
				if (!validatePath(path)) invalidPath();
				else if (choice != "ours" && choice != "theirs" && choice != "both") {
					if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
						new ScmError("invalid_conflict_choice", "Choose the current branch, incoming branch, or both")));
				} else if (choice == "both") {
					var target = root + "/" + relativePath(path);
					if (!FileSystem.exists(target) || FileSystem.isDirectory(target)) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
							new ScmError("conflict_resolution_failed", "The conflicted file is unavailable")));
					} else {
						try {
							var original = File.getBytes(target), content = original.toString(), roundTrip = Bytes.ofString(content);
							var exact = roundTrip.length == original.length;
							if (exact) for (index in 0...original.length) if (roundTrip.get(index) != original.get(index)) { exact = false; break; }
							var combined = exact ? combineConflictBoth(content) : null;
							if (combined == null) {
							if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
								new ScmError("conflict_resolution_failed", exact
									? "Accept Both requires standard text conflict markers"
									: "Accept Both is unavailable for this binary or non-UTF-8 file")));
							} else {
								File.saveContent(target, combined);
								child = process.run(["add", "--", relativePath(path)], root, generation, function(result) {
									if (job.cancelled || job.complete) return;
								if (result.error != null) try File.saveBytes(target, original) catch (_:Dynamic) {}
								finish(result, "Resolved " + path + " using both sides");
								}, false, false, GitProcess.DEFAULT_MAX_STDOUT);
							}
						} catch (failure:Dynamic) {
							if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
								new ScmError("conflict_resolution_failed", Std.string(failure))));
						}
					}
				} else {
					var option = choice == "ours" ? "--ours" : "--theirs", relative = relativePath(path);
					child = process.run(["checkout", option, "--", relative], root, generation, function(check) {
						if (job.cancelled || job.complete) return;
						if (check.error != null) {
						if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, check.error));
					} else runForPath(path, ["add"], "Resolved " + path + " using " + choice);
					}, false, false, 8192);
				}
			case Commit(message, amend):
				if (StringTools.trim(message).length == 0) {
					if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null,
						new ScmError("empty_commit_message", "Commit message cannot be empty")));
				} else {
					var args = ["commit", "--file=-"];
					if (amend) args.insert(1, "--amend");
					run(args, Bytes.ofString(message), amend ? "Amended commit" : "Created commit");
				}
			case StagePatch(path, patch): runCheckedPatch(path, ["apply", "--cached", "--recount"], patch, "Staged hunk in " + path);
			case UnstagePatch(path, patch): runCheckedPatch(path, ["apply", "--cached", "--recount", "--reverse"], patch, "Unstaged hunk in " + path);
			case RevertPatch(path, patch): runCheckedPatch(path, ["apply", "--recount", "--reverse"], patch, "Reverted hunk in " + path);
			case Checkout(reference):
				var localPrefix = "refs/heads/", remotePrefix = "refs/remotes/";
				if (!validBranchName(reference) || (!StringTools.startsWith(reference, localPrefix)
					&& !StringTools.startsWith(reference, remotePrefix))) invalidBranch();
				else if (StringTools.startsWith(reference, remotePrefix))
					run(["checkout", "--quiet", "--track", reference], null, "Checked out " + reference);
				else run(["switch", "--quiet", reference.substr(localPrefix.length)], null, "Checked out " + reference);
			case CreateBranch(name):
				if (!validBranchName(name)) invalidBranch(); else run(["checkout", "--quiet", "-b", name], null, "Created branch " + name);
			case Fetch(remote):
				if (remote != null && (remote.length == 0 || remote.charAt(0) == "-" || remote.indexOf("\n") >= 0 || remote.indexOf("\r") >= 0)) {
					if (job.finish()) complete(new ScmJobResult<ScmApplyResult>(generation, null, new ScmError("invalid_remote", "Enter a valid Git remote name")));
				} else run(remote == null ? ["fetch", "--all", "--prune"] : ["fetch", "--prune", remote], null, "Fetched remote updates");
			case Pull: run(["pull", "--ff-only"], null, "Pulled fast-forward updates");
			case Push:
				var upstream = current == null ? null : current.head.upstream;
				run(upstream == null ? ["push", "--set-upstream", "origin", "HEAD"] : ["push"], null, "Pushed commits");
		}
		return job;
	}

	static function combineConflictBoth(text:String):Null<String> {
		var lines = text.split("\n"), output:Array<String> = [], ours:Array<String> = [], theirs:Array<String> = [];
		var side = 0, inBase = false, conflicts = 0;
		for (line in lines) {
			var marker = StringTools.endsWith(line, "\r") ? line.substring(0, line.length - 1) : line;
			if (side == 0) {
				if (StringTools.startsWith(marker, "<<<<<<<")) {
					side = 1;
					inBase = false;
					ours = [];
					theirs = [];
					conflicts++;
				} else output.push(line);
			} else if (side == 1) {
				if (StringTools.startsWith(marker, "|||||||")) inBase = true;
				else if (StringTools.startsWith(marker, "=======")) { side = 2; inBase = false; }
				else if (!inBase) ours.push(line);
			} else if (StringTools.startsWith(marker, ">>>>>>>")) {
				for (part in ours) output.push(part);
				for (part in theirs) output.push(part);
				side = 0;
			} else theirs.push(line);
		}
		return side == 0 && conflicts > 0 ? output.join("\n") : null;
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

	static function ensureDirectory(path:String):Bool {
		if (FileSystem.exists(path)) return FileSystem.isDirectory(path);
		var separator = path.lastIndexOf("/");
		if (separator > 0 && !ensureDirectory(path.substring(0, separator))) return false;
		try FileSystem.createDirectory(path) catch (_:Dynamic) return false;
		return FileSystem.exists(path) && FileSystem.isDirectory(path);
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
