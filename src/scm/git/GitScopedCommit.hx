package scm.git;

import haxe.io.Bytes;
import scm.ScmError;
import scm.ScmFolderScope;
import scm.ScmJob;
import scm.ScmJobResult;
import sys.FileSystem;

/**
	A commit that may only change paths under repository-relative folders (ScmOperation.ScopedCommit).

	It snapshots the index with `write-tree`, compares that tree with every parent the new commit gets (HEAD, or with
	amend HEAD's own parents, so an amended merge is compared with each side), and refuses when a path outside the
	folders differs, submodules included. Without commit hooks or signing it then commits that exact tree with
	`commit-tree` and moves HEAD with `update-ref` against the HEAD it started from, so nothing staged meanwhile can
	enter and a HEAD that moved fails the commit. With a pre-commit, prepare-commit-msg or commit-msg hook, or
	`commit.gpgsign`, it runs `git commit` right after the check instead, so hooks and signing behave as usual; a
	change staged between the check and that commit (by a hook or another process) is not caught then.
**/
class GitScopedCommit {
	static final COMMIT_HOOKS:Array<String> = ["pre-commit", "prepare-commit-msg", "commit-msg"];

	final process:GitProcess;
	final root:String;
	final generation:Int;
	final message:String;
	final amend:Bool;
	final folders:Array<String>;
	final ignoreCase:Bool;
	final complete:(Null<String>, Null<ScmError>)->Void;
	var child:Null<ScmJob<GitCommandResult>>;
	var done:Bool = false;
	var head:Null<String>;
	var tree:String = "";
	var parents:Array<String> = [];
	/** Test seam: runs after the tree passed the check and before the commit is written. */
	public static var afterCheck:Null<Void->Void>;

	/** `complete` gets the result message, or the error that stopped the commit. */
	public function new(process:GitProcess, root:String, generation:Int, message:String, amend:Bool, folders:Array<String>,
			ignoreCase:Bool, complete:(Null<String>, Null<ScmError>)->Void) {
		this.process = process; this.root = root; this.generation = generation; this.message = message; this.amend = amend;
		this.folders = folders; this.ignoreCase = ignoreCase; this.complete = complete;
	}

	public function start():Void {
		if (StringTools.trim(message).length == 0) return fail("empty_commit_message", "Commit message cannot be empty");
		if (folders.length == 0) return fail("outside_folder", "No folder to commit");
		for (folder in folders) if (!ScmFolderScope.plain(folder) || !StringTools.endsWith(folder, "/"))
			return fail("outside_folder", folder + " is not a plain repository folder");
		// A missing HEAD is an unborn branch: a first commit has no parents and there is nothing to amend.
		git(["rev-parse", "--verify", "--quiet", "HEAD"], null, function(result) {
			var value = result.value;
			head = result.error == null && value != null ? StringTools.trim(value.stdout.toString()) : null;
			var current = head;
			if (current == null || current.length == 0) {
				head = null;
				if (amend) return fail("nothing_to_amend", "There is no commit to amend yet on this branch");
				parents = [];
				writeTree();
			} else if (!amend) {
				parents = [current];
				writeTree();
			} else run(["rev-parse", current + "^@"], null, function(output) {
				parents = [for (line in output.toString().split("\n")) if (StringTools.trim(line).length > 0) StringTools.trim(line)];
				writeTree();
			});
		});
	}

	public function cancel():Void {
		done = true;
		var running = child;
		if (running != null) running.cancel();
	}

	function writeTree():Void run(["write-tree"], null, function(output) {
		tree = StringTools.trim(output.toString());
		checkParents(0, []);
	});

	/** Collects the paths in which the tree differs from each parent, then checks them against the folders. */
	function checkParents(index:Int, changed:Array<String>):Void {
		if (index < parents.length) {
			run(["diff-tree", "-r", "-z", "--name-only", "--no-renames", "--ignore-submodules=none", parents[index], tree], null,
				function(output) checkParents(index + 1, changed.concat(GitScopedCommit.names(output))));
			return;
		}
		if (parents.length == 0) {
			run(["ls-tree", "-r", "-z", "--name-only", "--full-tree", tree], null, output -> checked(GitScopedCommit.names(output)));
			return;
		}
		checked(changed);
	}

	function checked(changed:Array<String>):Void {
		if (!amend && changed.length == 0) return fail("nothing_staged", "There are no staged changes to commit");
		var outside = ScmFolderScope.outside(changed, folders, ignoreCase);
		if (outside.length > 0) {
			var what = amend ? "Changes in the commit being amended" : "Staged changes";
			return fail(ScmFolderScope.OUTSIDE_FOLDER, ScmFolderScope.refusal(what, outside, folders));
		}
		var seam = afterCheck;
		if (seam != null) seam();
		usesCommitCommand(function(porcelain) porcelain ? commitCommand() : commitTree());
	}

	/** Whether hooks or signing need `git commit` to run them. */
	function usesCommitCommand(next:Bool->Void):Void {
		git(["config", "--type=bool", "--get", "commit.gpgsign"], null, function(signing) {
			var value = signing.value;
			if (signing.error == null && value != null && StringTools.trim(value.stdout.toString()) == "true") return next(true);
			run(["rev-parse", "--git-path", "hooks"], null, function(output) {
				var hooks = StringTools.trim(output.toString());
				if (!haxe.io.Path.isAbsolute(hooks)) hooks = root + "/" + hooks;
				for (name in COMMIT_HOOKS) if (FileSystem.exists(hooks + "/" + name)) return next(true);
				next(false);
			});
		});
	}

	function commitCommand():Void {
		var arguments = ["commit", "--file=-"];
		if (amend) arguments.insert(1, "--amend");
		run(arguments, Bytes.ofString(message), _ -> succeed());
	}

	function commitTree():Void {
		run(["stripspace"], Bytes.ofString(message), function(cleaned) {
			var text = cleaned.toString();
			if (StringTools.trim(text).length == 0) return fail("empty_commit_message", "Commit message cannot be empty");
			var arguments = ["commit-tree", tree];
			for (parent in parents) { arguments.push("-p"); arguments.push(parent); }
			arguments.push("-F"); arguments.push("-");
			function write(environment:Null<Map<String, String>>):Void run(arguments, Bytes.ofString(text), function(created) {
				var commit = StringTools.trim(created.toString()), subject = text.split("\n")[0];
				var reason = (amend ? "commit (amend): " : head == null ? "commit (initial): " : "commit: ") + subject;
				var previous = head;
				git(["update-ref", "-m", reason, "HEAD", commit, previous == null ? "" : previous], null, function(moved) {
					var error = moved.error;
					if (error != null) return fail("head_moved",
						"The branch changed while committing, so nothing was committed. Refresh and try again. (" + error.message + ")");
					succeed();
				});
			}, environment);
			if (!amend) { write(null); return; }
			// An amended commit keeps its author, as `git commit --amend` does.
			run(["log", "-1", "--date=raw", "--format=%an%n%ae%n%ad", "HEAD"], null, function(output) {
				var fields = StringTools.replace(output.toString(), "\r", "").split("\n");
				if (fields.length < 3) return fail("operation_failed", "Git did not return the author of the commit being amended");
				write(["GIT_AUTHOR_NAME" => fields[0], "GIT_AUTHOR_EMAIL" => fields[1], "GIT_AUTHOR_DATE" => fields[2]]);
			});
		});
	}

	function succeed():Void {
		if (done) return;
		done = true;
		complete(amend ? "Amended commit" : "Created commit", null);
	}

	function fail(code:String, message:String):Void {
		if (done) return;
		done = true;
		complete(null, new ScmError(code, message));
	}

	/** Runs Git and passes its stdout on, or fails the commit with Git's error. */
	function run(arguments:Array<String>, input:Null<Bytes>, next:Bytes->Void, ?environment:Map<String, String>):Void {
		git(arguments, input, function(result) {
			var value = result.value, error = result.error;
			if (error != null) return fail(error.code, error.message);
			if (value == null) return fail("operation_failed", "Git returned nothing for " + arguments[0]);
			next(value.stdout);
		}, environment);
	}

	function git(arguments:Array<String>, input:Null<Bytes>, next:ScmJobResult<GitCommandResult>->Void, ?environment:Map<String, String>):Void {
		if (done) return;
		child = process.run(arguments, root, generation, function(result) { if (!done) next(result); }, false, false,
			GitProcess.DEFAULT_MAX_STDOUT, [], input, environment);
	}

	/** The non-empty names in Git's `-z` output, decoded one at a time so a NUL never reaches a string. */
	public static function names(bytes:Bytes):Array<String> {
		var result:Array<String> = [], start = 0;
		for (index in 0...bytes.length + 1) if (index == bytes.length || bytes.get(index) == 0) {
			if (index > start) result.push(bytes.getString(start, index - start));
			start = index + 1;
		}
		return result;
	}
}
