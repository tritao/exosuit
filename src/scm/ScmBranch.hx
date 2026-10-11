package scm;

/** A local or remote branch available to check out from this repository. */
class ScmBranch {
	/** Fully qualified ref, suitable for ScmOperation.Checkout. */
	public final reference:String;
	/** Short label for quick picks, such as `main` or `origin/main`. */
	public final name:String;
	public final remote:Bool;
	public final current:Bool;

	public function new(reference:String, name:String, remote:Bool, current:Bool) {
		this.reference = reference;
		this.name = name;
		this.remote = remote;
		this.current = current;
	}
}
