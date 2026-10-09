package scm;

enum ScmRef {
	Head;
	Index;
	Commit(oid:String);
	ConflictStage(stage:Int);
}
