package syntax;

class HighlightToken {
	public static inline final NORMAL = 0;
	public static inline final KEYWORD = 1;
	public static inline final TYPE = 2;
	public static inline final NUMBER = 3;
	public static inline final STRING = 4;
	public static inline final COMMENT = 5;
	public static inline final OPERATOR = 6;
	public static inline final LITERAL = 7;

	public final kind:Int;
	public final start:Int;
	public final length:Int;
	/** Innermost TextMate scopes; empty for the built-in lexer. */
	public final scopes:Array<String>;

	public function new(kind:Int, start:Int, length:Int, ?scopes:Array<String>) {
		this.kind = kind;
		this.start = start;
		this.length = length;
		this.scopes = scopes == null ? [] : scopes;
	}
}
