package scm;

class ScmApplyResult {
	public final snapshot:Null<ScmSnapshot>;
	public final message:Null<String>;
	/** Git blob id captured before discard; an empty token means the file did not exist. */
	public final recoveryToken:Null<String>;

	public function new(?snapshot:ScmSnapshot, ?message:String, ?recoveryToken:String) {
		this.snapshot = snapshot;
		this.message = message;
		this.recoveryToken = recoveryToken;
	}
}
