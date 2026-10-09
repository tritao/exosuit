package scm;

enum abstract ScmConflictKind(String) from String to String {
	var BothAdded = "both-added";
	var BothModified = "both-modified";
	var BothDeleted = "both-deleted";
	var AddedByUs = "added-by-us";
	var AddedByThem = "added-by-them";
	var DeletedByUs = "deleted-by-us";
	var DeletedByThem = "deleted-by-them";
	var Unknown = "unknown";
}
