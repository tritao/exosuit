package scm;

enum abstract ScmChangeKind(String) from String to String {
	var Added = "added";
	var Modified = "modified";
	var Deleted = "deleted";
	var Renamed = "renamed";
	var Copied = "copied";
	var TypeChanged = "type-changed";
	var Unmerged = "unmerged";
	var Untracked = "untracked";
	var Ignored = "ignored";
}
