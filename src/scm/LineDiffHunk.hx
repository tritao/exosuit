package scm;

/** Line positions are zero-based; counts are lengths in their respective texts. */
class LineDiffHunk {
	public final kind:LineDiffKind;
	public final oldStart:Int;
	public final oldCount:Int;
	public final newStart:Int;
	public final newCount:Int;

	public function new(kind:LineDiffKind, oldStart:Int, oldCount:Int, newStart:Int, newCount:Int) {
		this.kind = kind;
		this.oldStart = oldStart;
		this.oldCount = oldCount;
		this.newStart = newStart;
		this.newCount = newCount;
	}
}
