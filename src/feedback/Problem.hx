package feedback;

class Problem {
	public final owner:String;
	public final id:String;
	public final path:String;
	public final line:Int;
	public final column:Int;
	public final endColumn:Int;
	public final message:String;
	public final severity:Int;

	public function new(owner:String, id:String, path:String, line:Int, column:Int, endColumn:Int, message:String, severity:Int) {
		this.owner = owner;
		this.id = id;
		this.path = path;
		this.line = line;
		this.column = column;
		this.endColumn = endColumn;
		this.message = message;
		this.severity = severity;
	}
}
