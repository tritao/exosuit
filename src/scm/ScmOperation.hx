package scm;

import haxe.io.Bytes;

enum ScmOperation {
	Stage(path:String);
	Unstage(path:String);
	Discard(path:String);
	Commit(message:String, amend:Bool);
	StagePatch(path:String, patch:Bytes);
	Checkout(reference:String);
	CreateBranch(name:String);
	Fetch(remote:Null<String>);
	Pull;
	Push;
}
