package syntax;

class HighlightedLine {
	public final text:String;
	public final tokens:Array<HighlightToken>;
	/** Legacy lexical state: zero means normal, nonzero means inside a multiline token. */
	public final stateBefore:Int;
	public final stateAfter:Int;
	/** Full tokenizer continuation state, which may be a TextMate frame. */
	public final tokenizerStateBefore:Dynamic;
	public final tokenizerStateAfter:Dynamic;

	public function new(text:String, tokens:Array<HighlightToken>, stateBefore:Int, stateAfter:Int,
			?tokenizerStateBefore:Dynamic, ?tokenizerStateAfter:Dynamic) {
		this.text = text;
		this.tokens = tokens;
		this.stateBefore = stateBefore;
		this.stateAfter = stateAfter;
		this.tokenizerStateBefore = tokenizerStateBefore == null ? stateBefore : tokenizerStateBefore;
		this.tokenizerStateAfter = tokenizerStateAfter == null ? stateAfter : tokenizerStateAfter;
	}
}
