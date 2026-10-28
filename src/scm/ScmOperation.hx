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
		A commit that may only touch paths under the repository-relative `folders` (each ending in `/`). The provider
		checks the staged paths, and with `amend` the paths of the commit it rewrites, right before committing.
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
