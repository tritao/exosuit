package syntax;

import textmateregex.RegexMatch.RegexCapture;
import textmateregex.RegexMatch;
import textmateregex.RegexInput;
import textmateregex.RegexScanner;

/** Incremental line tokenizer for TextMate JSON grammars. */
class TextMateTokenizer {
	static inline final MAX_LINE_STEPS = 20000;
	static inline final MAX_NESTING = 128;
	final grammar:TextMateGrammar;
	final grammars:SyntaxRegistry;
	final frames:Map<String, TextMateFrame> = [];
	final scanners:Array<RegexScanner> = [];
	final root:TextMateFrame;

	public function new(grammar:TextMateGrammar, grammars:SyntaxRegistry) {
		this.grammar = grammar;
		this.grammars = grammars;
		root = buildFrame(grammar, null, null, null, [], [grammar.scopeName]);
	}

	public function tokenize(text:String, initial:Dynamic):HighlightedLine {
		var input = new RegexInput(text), frame:TextMateFrame = initial == null ? root : cast initial;
		var before = frame, tokens:Array<HighlightToken> = [], position = 0, steps = 0;
		while (frame.rule != null && frame.rule.whilePattern != null) {
			var whileMatch = frame.whileScanner.findInput(input, 0);
			if (whileMatch != null && whileMatch.start == 0) {
				appendMatch(tokens, text, 0, whileMatch.end, frame.regionScopes,
					frame.rule.whileCaptures.keys().hasNext() ? frame.rule.whileCaptures : frame.rule.captures, whileMatch);
				position = whileMatch.end;
				break;
			}
			frame = frame.parent == null ? root : frame.parent;
		}
		while (position < text.length && steps++ < MAX_LINE_STEPS) {
			if (frame.scanner == null || frame.candidates.length == 0) {
				var next = nextCodePoint(text, position);
				append(tokens, kind(frame.contentScopes), position, next - position, frame.contentScopes);
				position = next;
				continue;
			}
			var match = frame.scanner.findInput(input, position);
			if (match == null) {
				append(tokens, kind(frame.contentScopes), position, text.length - position, frame.contentScopes);
				position = text.length;
				break;
			}
			if (match.start > position)
				append(tokens, kind(frame.contentScopes), position, match.start - position, frame.contentScopes);
			var candidate = frame.candidates[match.patternIndex];
			if (candidate.isEnd) {
				var parent = frame.parent;
				appendMatch(tokens, text, match.start, match.end, frame.regionScopes,
					candidate.rule.endCaptures.keys().hasNext() ? candidate.rule.endCaptures : candidate.rule.captures, match);
				position = match.end;
				frame = parent == null ? root : parent;
				if (position == match.start && position < text.length) {
					var next = nextCodePoint(text, position);
					append(tokens, kind(frame.contentScopes), position, next - position, frame.contentScopes);
					position = next;
				}
			} else if (candidate.rule.begin != null) {
				appendMatch(tokens, text, match.start, match.end,
					addScope(frame.contentScopes, candidate.rule.name),
					candidate.rule.beginCaptures.keys().hasNext() ? candidate.rule.beginCaptures : candidate.rule.captures, match);
				if (frame.depth >= MAX_NESTING) {
					append(tokens, kind(frame.contentScopes), match.start, text.length - match.start, frame.contentScopes);
					position = text.length;
					break;
				}
				var endPattern = candidate.rule.end == null ? null : substituteBackreferences(candidate.rule.end, text, match.captures);
				var region = addScope(frame.contentScopes, candidate.rule.name);
				var content = addScope(region, candidate.rule.contentName);
				frame = buildFrame(candidate.rule.grammar, candidate.rule, frame, endPattern, region, content);
				position = match.end;
				if (match.start == match.end && position < text.length) {
					var next = nextCodePoint(text, position);
					append(tokens, kind(frame.contentScopes), position, next - position, frame.contentScopes);
					position = next;
				}
			} else {
				var matchScopes = addScope(frame.contentScopes, candidate.rule.name);
				appendMatch(tokens, text, match.start, match.end, matchScopes, candidate.rule.captures, match);
				position = match.end;
				if (match.start == match.end && position < text.length) {
					var next = nextCodePoint(text, position);
					append(tokens, kind(matchScopes), position, next - position, matchScopes);
					position = next;
				}
			}
		}
		if (steps >= MAX_LINE_STEPS && position < text.length)
			append(tokens, kind(frame.contentScopes), position, text.length - position, frame.contentScopes);
		return new HighlightedLine(text, tokens, before.depth == 0 ? 0 : 1, frame.depth == 0 ? 0 : 1, before, frame);
	}

	public function dispose():Void {
		for (scanner in scanners) scanner.close();
		scanners.resize(0);
		frames.clear();
	}

	function buildFrame(owner:TextMateGrammar, rule:Null<TextMateRule>, parent:Null<TextMateFrame>,
			endPattern:Null<String>, regionScopes:Array<String>, contentScopes:Array<String>):TextMateFrame {
		var signature = (parent == null ? owner.scopeName : parent.signature) + "/" +
			(rule == null ? "root" : rule.id + ":" + (endPattern == null ? "" : endPattern));
		var cached = frames.get(signature);
		if (cached != null) return cached;
		var expanded = expand(owner, rule == null ? owner.patterns : rule.patterns);
		var candidates:Array<TextMateCandidate> = [];
		var endCandidate = rule != null && endPattern != null ? new TextMateCandidate(rule, true) : null;
		if (endCandidate != null && rule != null && !rule.applyEndPatternLast) candidates.push(endCandidate);
		for (nested in expanded)
			if (nested.match != null || nested.begin != null)
				candidates.push(new TextMateCandidate(nested, false));
		if (endCandidate != null && rule != null && rule.applyEndPatternLast) candidates.push(endCandidate);
		var scanner:Null<RegexScanner> = null;
		if (candidates.length > 0) {
			scanner = makeScanner();
			for (candidate in candidates) {
				var pattern = candidate.isEnd ? endPattern : candidate.rule.match == null ? candidate.rule.begin : candidate.rule.match;
				if (pattern == null) throw "TextMate scanner candidate has no expression";
				scanner.add(pattern);
			}
		}
		var whileScanner:Null<RegexScanner> = null;
		if (rule != null && rule.whilePattern != null) {
			whileScanner = makeScanner();
			whileScanner.add(rule.whilePattern);
		}
		var result = new TextMateFrame(owner, rule, parent, endPattern, regionScopes.copy(), contentScopes.copy(),
			candidates, scanner, whileScanner, signature, parent == null ? 0 : parent.depth + 1);
		frames.set(signature, result);
		return result;
	}

	function expand(owner:TextMateGrammar, rules:Array<TextMateRule>):Array<TextMateRule> {
		var result:Array<TextMateRule> = [];
		for (rule in rules) expandRule(rule.grammar, rule, result, []);
		return result;
	}

	function expandRule(owner:TextMateGrammar, rule:TextMateRule, result:Array<TextMateRule>, active:Array<String>):Void {
		if (rule.include == null) {
			if (rule.match != null || rule.begin != null || rule.whilePattern != null) result.push(rule);
			else for (nested in rule.patterns) expandRule(nested.grammar, nested, result, active);
			return;
		}
		var include = rule.include, grammar = owner, referenced:Null<TextMateRule> = null, patterns:Array<TextMateRule> = [];
		if (include == "$self" || include == "$base") {
			grammar = include == "$self" ? owner : this.grammar;
			patterns = grammar.patterns;
		} else {
			var separator = include.indexOf("#"), scope = separator < 0 ? null : include.substring(0, separator);
			var repository = separator < 0 ? include.substring(1) : include.substring(separator + 1);
			if (include.charAt(0) != "#" && scope == null) {
				grammar = grammars.grammar(include);
				if (grammar == null) return;
				patterns = grammar.patterns;
			} else {
				if (scope != null && scope.length > 0) grammar = grammars.grammar(scope);
				if (grammar == null) return;
				referenced = grammar.repositoryRule(repository);
				if (referenced == null) return;
				patterns = [referenced];
			}
		}
		var key = grammar.scopeName + "#" + (referenced == null ? "$self" : Std.string(referenced.id));
		if (active.indexOf(key) >= 0) return;
		var branch = active.copy();
		branch.push(key);
		for (nested in patterns) expandRule(nested.grammar, nested, result, branch);
	}

	function makeScanner():RegexScanner {
		var scanner = new RegexScanner();
		scanners.push(scanner);
		return scanner;
	}

	static function appendMatch(tokens:Array<HighlightToken>, text:String, start:Int, end:Int, base:Array<String>,
			captures:Map<Int, String>, match:RegexMatch):Void {
		if (end <= start) return;
		var segments:Array<Int> = [start, end];
		for (capture in match.captures)
			if (capture.start >= start && capture.end <= end && capture.start < capture.end) {
				segments.push(capture.start);
				segments.push(capture.end);
			}
		segments.sort(function(a, b) return a - b);
		var unique:Array<Int> = [];
		for (offset in segments) if (unique.length == 0 || unique[unique.length - 1] != offset) unique.push(offset);
		for (index in 0...unique.length - 1) {
			var first = unique[index], last = unique[index + 1], scopes = base.copy();
			for (captureIndex in 0...match.captures.length) {
				var capture = match.captures[captureIndex], captureScope = captures.get(captureIndex);
				if (captureScope != null && capture.start <= first && capture.end >= last)
					scopes = addScope(scopes, captureScope);
			}
			append(tokens, kind(scopes), first, last - first, scopes);
		}
	}

	static function append(tokens:Array<HighlightToken>, kind:Int, start:Int, length:Int, scopes:Array<String>):Void {
		if (length > 0) tokens.push(new HighlightToken(kind, start, length, scopes));
	}

	static function addScope(scopes:Array<String>, scope:Null<String>):Array<String> {
		if (scope == null || scope.length == 0) return scopes.copy();
		var result = scopes.copy();
		for (part in scope.split(" ")) if (part.length > 0) result.push(part);
		return result;
	}

	static function kind(scopes:Array<String>):Int {
		var index = scopes.length;
		while (index > 0) {
			var scope = scopes[--index];
			if (StringTools.startsWith(scope, "comment")) return HighlightToken.COMMENT;
			if (StringTools.startsWith(scope, "string")) return HighlightToken.STRING;
			if (StringTools.startsWith(scope, "constant.numeric")) return HighlightToken.NUMBER;
			if (StringTools.startsWith(scope, "constant.language")) return HighlightToken.LITERAL;
			if (StringTools.startsWith(scope, "keyword.operator")) return HighlightToken.OPERATOR;
			if (StringTools.startsWith(scope, "keyword")) return HighlightToken.KEYWORD;
			if (StringTools.startsWith(scope, "entity.name.type") || StringTools.startsWith(scope, "storage.type") ||
				StringTools.startsWith(scope, "support.type")) return HighlightToken.TYPE;
		}
		return HighlightToken.NORMAL;
	}

	static function substituteBackreferences(pattern:String, text:String, captures:Array<RegexCapture>):String {
		var result = new StringBuf(), index = 0;
		while (index < pattern.length) {
			var current = pattern.charAt(index);
			if (current == "\\" && index + 1 < pattern.length && pattern.charAt(index + 1) >= "0" && pattern.charAt(index + 1) <= "9") {
				var end = index + 1;
				while (end < pattern.length && pattern.charAt(end) >= "0" && pattern.charAt(end) <= "9") end++;
				var group = Std.parseInt(pattern.substring(index + 1, end));
				if (group != null && group < captures.length) {
					var capture = captures[group];
					if (capture.start >= 0) result.add("\\Q" + text.substring(capture.start, capture.end).split("\\E").join("\\E\\\\E\\Q") + "\\E");
				}
				index = end;
			} else {
				result.add(current);
				if (current == "\\" && index + 1 < pattern.length) result.add(pattern.charAt(++index));
				index++;
			}
		}
		return result.toString();
	}

	static function nextCodePoint(text:String, position:Int):Int {
		if (position + 1 < text.length) {
			var first = text.charCodeAt(position), next = text.charCodeAt(position + 1);
			if (first >= 0xd800 && first <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) return position + 2;
		}
		return position + 1;
	}
}
