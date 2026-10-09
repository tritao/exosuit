package scm;

enum abstract ScmHeadOperation(String) from String to String {
	var None = "none";
	var Merge = "merge";
	var Rebase = "rebase";
	var CherryPick = "cherry-pick";
	var Revert = "revert";
	var Bisect = "bisect";
}
