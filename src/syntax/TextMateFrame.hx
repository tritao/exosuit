package syntax;

import textmateregex.RegexScanner;

/** Immutable multiline state for a TextMate begin/end or begin/while rule. */
class TextMateFrame {
	public final grammar:TextMateGrammar;
	public final rule:Null<TextMateRule>;
	public final parent:Null<TextMateFrame>;
	public final endPattern:Null<String>;
	public final regionScopes:Array<String>;
	public final contentScopes:Array<String>;
	public final candidates:Array<TextMateCandidate>;
	public final scanner:Null<RegexScanner>;
	public final whileScanner:Null<RegexScanner>;
	public final signature:String;
	public final depth:Int;

	public function new(grammar:TextMateGrammar, rule:Null<TextMateRule>, parent:Null<TextMateFrame>,
			endPattern:Null<String>, regionScopes:Array<String>, contentScopes:Array<String>,
			candidates:Array<TextMateCandidate>, scanner:Null<RegexScanner>, whileScanner:Null<RegexScanner>, signature:String, depth:Int) {
		this.grammar = grammar;
		this.rule = rule;
		this.parent = parent;
		this.endPattern = endPattern;
		this.regionScopes = regionScopes;
		this.contentScopes = contentScopes;
		this.candidates = candidates;
		this.scanner = scanner;
		this.whileScanner = whileScanner;
		this.signature = signature;
		this.depth = depth;
	}
}

class TextMateCandidate {
	public final rule:TextMateRule;
	public final isEnd:Bool;
	public function new(rule:TextMateRule, isEnd:Bool) {
		this.rule = rule;
		this.isEnd = isEnd;
	}
}
