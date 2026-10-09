package scm;

class ScmError {
	public final code:String;
	public final message:String;
	public final retryable:Bool;

	public function new(code:String, message:String, retryable:Bool = false) {
		this.code = code;
		this.message = message;
		this.retryable = retryable;
	}
}
