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
	StagePatch(path:String, patch:Bytes);
	UnstagePatch(path:String, patch:Bytes);
	RevertPatch(path:String, patch:Bytes);
	Checkout(reference:String);
	CreateBranch(name:String);
	CreateWorktree(directory:String, branch:String);
	Fetch(remote:Null<String>);
	Pull;
	Push;
}
