package language;

/** A validated semantic entity in document codepoint coordinates. */
class LanguageSemanticToken {
	public final start:Int;
	public final end:Int;
	public final type:String;
	public final modifiers:Array<String>;

	public function new(start:Int, end:Int, type:String, modifiers:Array<String>) {
		this.start = start; this.end = end; this.type = type; this.modifiers = modifiers;
	}
}
