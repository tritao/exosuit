package scm;

class ScmFeatures {
	public final staging:Bool;
	public final partialStaging:Bool;
	public final amend:Bool;
	public final branches:Bool;
	public final remotes:Bool;
	public final stash:Bool;

	public function new(staging:Bool = false, partialStaging:Bool = false, amend:Bool = false, branches:Bool = false,
			remotes:Bool = false, stash:Bool = false) {
		this.staging = staging;
		this.partialStaging = partialStaging;
		this.amend = amend;
		this.branches = branches;
		this.remotes = remotes;
		this.stash = stash;
	}
}
