package scm;

import haxe.io.Bytes;

enum ScmOperation {
	Stage(path:String);
	StageAll;
	StagePaths(paths:Array<String>);
	Unstage(path:String);
	UnstageAll;
	UnstagePaths(paths:Array<String>);
	Discard(path:String);
	RestoreDiscard(path:String, recoveryToken:String);
	ResolveConflict(path:String, choice:String);
	Commit(message:String, amend:Bool);
	/**
		A commit that may only touch paths under the repository-relative `folders` (each ending in `/`). The Git provider
		commits a snapshot of the index after checking it against every parent of the new commit (HEAD's parents with
		`amend`), and moves HEAD only if it has not moved; with commit hooks or signing it runs `git commit` right after
		that check instead (see GitScopedCommit).
	**/
	ScopedCommit(message:String, amend:Bool, folders:Array<String>);
	StagePatch(path:String, patch:Bytes);
	UnstagePatch(path:String, patch:Bytes);
	RevertPatch(path:String, patch:Bytes);
	Checkout(reference:String);
	CreateBranch(name:String);
	Fetch(remote:Null<String>);
	Pull;
	Push;
}
