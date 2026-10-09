package syntax;

class SyntaxDefinition {
	public final name:String;
	public final extensions:Array<String>;
	public final headers:Array<String>;
	public final keywords:Map<String, Int>;
	public final highlighting:Bool;
	public final lineComment:String;
	public final blockCommentStart:String;
	public final blockCommentEnd:String;
	public final multilineStringStart:String;
	public final multilineStringEnd:String;
	public final stringsContinueAcrossLines:Bool;
	public final grammar:Null<TextMateGrammar>;

	public function new(name:String, extensions:Array<String>, highlighting:Bool, ?keywords:Map<String, Int>, ?headers:Array<String>, lineComment:String = "//",
			blockCommentStart:String = "/*", blockCommentEnd:String = "*/", multilineStringStart:String = "", multilineStringEnd:String = "",
			stringsContinueAcrossLines:Bool = false, ?grammar:TextMateGrammar) {
		this.name = name;
		this.extensions = extensions;
		this.headers = headers == null ? [] : headers;
		this.highlighting = highlighting;
		this.keywords = keywords == null ? [] : keywords;
		this.lineComment = lineComment;
		this.blockCommentStart = blockCommentStart;
		this.blockCommentEnd = blockCommentEnd;
		this.multilineStringStart = multilineStringStart;
		this.multilineStringEnd = multilineStringEnd;
		this.stringsContinueAcrossLines = stringsContinueAcrossLines;
		this.grammar = grammar;
	}
}
