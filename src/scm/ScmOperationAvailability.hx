package scm;

class ScmOperationAvailability {
	public static function supports(features:ScmFeatures, operation:ScmOperation):Bool {
		return switch operation {
			case Stage(_) | Unstage(_) | Discard(_) | Commit(_, _): features.staging;
			case StagePatch(_, _): features.partialStaging;
			case Checkout(_) | CreateBranch(_): features.branches;
			case Fetch(_) | Pull | Push: features.remotes;
		};
	}
}
