package scm;

enum abstract ScmRepositoryKind(String) from String to String {
	var Worktree = "worktree";
	var LinkedWorktree = "linked-worktree";
	var Submodule = "submodule";
	var Nested = "nested";
}
