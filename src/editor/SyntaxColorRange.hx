package editor;

/** Syntax foreground in absolute document codepoint coordinates. */
class SyntaxColorRange {
	public final start:Int;
	public final end:Int;
	public final color:Int;

	public function new(start:Int, end:Int, color:Int) {
		this.start = start;
		this.end = end;
		this.color = color;
	}
}
