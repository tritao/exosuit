package scm;

enum abstract LineDiffKind(String) from String to String {
	var Added = "added";
	var Modified = "modified";
	var Deleted = "deleted";
}
