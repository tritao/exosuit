package scm;

enum abstract ScmGroupId(String) from String to String {
	var Merge = "merge";
	var Index = "index";
	var WorkingTree = "workingTree";
	var Untracked = "untracked";
}
