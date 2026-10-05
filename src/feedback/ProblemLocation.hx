package feedback;

class ProblemLocation {
	public final path:String;
	public final line:Int;
	public final column:Int;
	public final endColumn:Int;
	public function new(path:String, line:Int, column:Int, endColumn:Int) {
		this.path = path; this.line = line; this.column = column; this.endColumn = endColumn;
	}
}
