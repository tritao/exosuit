package scm;

class ScmOperationAvailability {
	public static function supports(features:ScmFeatures, operation:ScmOperation):Bool {
		return switch operation {
			case Stage(_) | StageAll | StagePaths(_) | Unstage(_) | UnstageAll | UnstagePaths(_) | Discard(_) | RestoreDiscard(_, _) | ResolveConflict(_, _): features.staging;
			case Commit(_, amend) | ScopedCommit(_, amend, _): features.staging && (!amend || features.amend);
			case StagePatch(_, _) | UnstagePatch(_, _) | RevertPatch(_, _): features.partialStaging;
			case Checkout(_) | CreateBranch(_): features.branches;
			case CreateWorktree(_, _): features.worktrees;
			case Fetch(_) | Pull | Push: features.remotes;
		};
	}
}
