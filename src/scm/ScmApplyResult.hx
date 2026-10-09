package scm;

class ScmApplyResult {
	public final snapshot:Null<ScmSnapshot>;
	public final message:Null<String>;

	public function new(?snapshot:ScmSnapshot, ?message:String) {
		this.snapshot = snapshot;
		this.message = message;
	}
}
