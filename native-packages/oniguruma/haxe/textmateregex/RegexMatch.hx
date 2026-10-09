package textmateregex;

/** One capture's UTF-16 offsets in the original Haxe string. */
class RegexCapture {
	public final start:Int;
	public final end:Int;

	public function new(start:Int, end:Int) {
		this.start = start;
		this.end = end;
	}
}

/** One TextMate pattern selected by the ordered scanner. */
class RegexMatch {
	public final patternIndex:Int;
	public final start:Int;
	public final end:Int;
	public final captures:Array<RegexCapture>;

	public function new(patternIndex:Int, start:Int, end:Int, captures:Array<RegexCapture>) {
		this.patternIndex = patternIndex;
		this.start = start;
		this.end = end;
		this.captures = captures;
	}
}
