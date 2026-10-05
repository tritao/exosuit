package feedback;

class ProblemDetail {
	public final message:String;
	public final location:Null<ProblemLocation>;
	public function new(message:String, ?location:ProblemLocation) { this.message = message; this.location = location; }
}
