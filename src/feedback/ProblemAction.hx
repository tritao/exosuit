package feedback;

/** Actions reference registered commands; producers do not embed UI callbacks. */
class ProblemAction {
	public final label:String;
	public final command:String;
	public function new(label:String, command:String) { this.label = label; this.command = command; }
}
