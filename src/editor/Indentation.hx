package editor;

import syntax.Highlighter;
import syntax.HighlightToken;

/** Shared, conservative indentation policy. Offsets always refer to source text. */
class Indentation {
	public static function leading(text:String):Int {
		var i = 0;
		while (i < text.length && (text.charCodeAt(i) == 32 || text.charCodeAt(i) == 9)) i++;
		return i;
	}
	public static function prefix(columns:Int, tabWidth:Int, spaces:Bool):String {
		var result = "", width = Std.int(Math.max(1, tabWidth));
		if (!spaces) { for (_ in 0...Std.int(columns / width)) result += "\t"; columns %= width; }
		for (_ in 0...columns) result += " ";
		return result;
	}
	/** Mask comments and strings without moving any source offsets. */
	public static function code(text:String, line:Int, highlighter:Null<Highlighter>):String {
		if (highlighter == null || !highlighter.syntax.highlighting) return text;
		var result = new StringBuf(), offset = 0;
		for (token in highlighter.line(line).tokens) {
			if (token.start >= text.length) break;
			result.add(text.substring(offset, token.start));
			var end = Std.int(Math.min(text.length, token.start + token.length));
			if (token.kind == HighlightToken.COMMENT || token.kind == HighlightToken.STRING)
				for (i in token.start...end) result.add(token.kind == HighlightToken.STRING && i == token.start ? "s" : " ");
			else result.add(text.substring(token.start, end));
			offset = end;
		}
		result.add(text.substring(offset));
		return result.toString();
	}
	public static function detect(buffer:TextBuffer, highlighter:Highlighter):{width:Null<Int>, spaces:Null<Bool>} {
		var tabs = 0, spaces = 0, widths:Array<Int> = [], delimiterDepth = 0, bytes = 0;
		for (line in 0...Std.int(Math.min(1000, buffer.lineCount()))) {
			var text = buffer.line(line); bytes += text.length;
			if (bytes > 262144) break;
			var clean = code(text, line, highlighter), count = leading(text);
			if (StringTools.trim(clean).length > 0 && highlighter.line(line).stateBefore == 0 && delimiterDepth == 0 && count > 0) {
				var whitespace = text.substring(0, count);
				if (whitespace.charAt(0) == "\t") tabs++;
				else if (whitespace.indexOf("\t") < 0) { spaces++; widths.push(count); }
			}
			for (i in 0...clean.length) switch clean.charAt(i) {
				case "(", "[": delimiterDepth++;
				case ")", "]": delimiterDepth = Std.int(Math.max(0, delimiterDepth - 1));
				default:
			}
		}
		var total = tabs + spaces;
		if (total < 3) return {width: null, spaces: null};
		if (tabs >= 3 && tabs / total >= 0.8) return {width: null, spaces: false};
		if (spaces < 3 || spaces / total < 0.8) return {width: null, spaces: null};
		var best:Null<Int> = null, occurrences:Map<Int, Int> = [];
		for (width in widths) { var count = occurrences.get(width); occurrences.set(width, count == null ? 1 : count + 1); }
		// Prefer the largest supported unit explaining all observed indentation.
		// A lone odd alignment line may be ignored only with substantial evidence.
		for (candidate in [2, 3, 4, 8]) {
			var matches = 0, exact = 0, contradicted = false;
			for (width => count in occurrences) if (width < candidate && count >= 2) contradicted = true;
			for (width in widths) { if (width % candidate == 0) matches++; if (width == candidate) exact++; }
			if (!contradicted && exact >= 2 && matches >= 3 && matches / widths.length >= 0.9) best = candidate;
		}
		return {width: best, spaces: true};
	}

	public static function newline(buffer:TextBuffer, start:BufferPosition, end:BufferPosition, tabWidth:Int,
			spaces:Bool, highlighter:Null<Highlighter>, indentSize:Int, ?cache:IndentationCache):{text:String, caret:Int} {
		var line = buffer.line(start.line), indentation = line.substring(0, Std.int(Math.min(start.column, leading(line))));
		var left = StringTools.rtrim(code(line.substring(0, start.column), start.line, highlighter));
		var opener = left.length == 0 ? "" : left.charAt(left.length - 1);
		var bracket = highlighter != null && highlighter.syntax.highlighting && ["{", "[", "("].indexOf(opener) >= 0;
		var size = indentSize > 0 ? indentSize : tabWidth;
		if (highlighter != null && (highlighter.line(start.line).stateBefore != 0 || left.length == 0)) return {text: "\n" + indentation, caret: 1 + indentation.length};
		if (start.column >= leading(line) && highlighter != null && highlighter.syntax.name == "Haxe") {
			var state = cache == null ? new IndentationContext(size, tabWidth, false) : cache.context(start.line, size, tabWidth);
			if (cache == null) for (i in 0...start.line) {
				var text = buffer.line(i);
				state.consume(code(text, i, highlighter), EditorActions.visualColumn(text, leading(text), tabWidth));
			}
			var partial = line.substring(0, start.column);
			state.consume(code(partial, start.line, highlighter), EditorActions.visualColumn(partial, leading(partial), tabWidth));
			var right = code(buffer.line(end.line).substring(end.column), end.line, null);
			var closing = ~/^\s*[}\])]/.match(right);
			indentation = prefix(!bracket && closing ? state.before(right) : state.next(), tabWidth, spaces);
		} else if (bracket) {
			var columns = EditorActions.visualColumn(indentation, indentation.length, tabWidth);
			indentation = prefix(columns + size, tabWidth, spaces);
		}
		var text = "\n" + indentation, caret = text.length;
		var closer = opener == "{" ? "}" : opener == "[" ? "]" : ")";
		// Keep the caret on the interior line when splitting a matching pair.
		var right = buffer.line(end.line).substring(end.column);
		if (bracket && right.charAt(0) == closer) {
			var base = line.substring(0, Std.int(Math.min(start.column, leading(line))));
			text += "\n" + base;
		}
		return {text: text, caret: caret};
	}

	/** Canonical indentation for an explicit reindent action; null protects literal/comment lines. */
	public static function lineIndents(buffer:TextBuffer, highlighter:Highlighter, tabWidth:Int, indentSize:Int):Array<Null<Int>> {
		var result:Array<Null<Int>> = [], state = new IndentationContext(indentSize, tabWidth, true);
		for (line in 0...buffer.lineCount()) {
			var text = buffer.line(line), clean = code(text, line, highlighter);
			var protectedLine = highlighter.line(line).stateBefore != 0;
			var desired = state.before(clean);
			result.push(protectedLine || StringTools.trim(clean).length == 0 ? null : desired);
			state.consume(clean, desired);
		}
		return result;
	}
}

private typedef IndentFrame = {var opener:String; var base:Int; var child:Int; var caseBody:Bool; var control:Bool;};

/** Lightweight structural state, tolerant of incomplete Haxe. Never interprets literals. */
private class IndentationContext {
	final size:Int;
	final tabWidth:Int;
	final canonical:Bool;
	final frames:Array<IndentFrame> = [];
	var pending:Array<Int> = [];
	var lastBase:Int = 0;
	var lastControl:Null<Int>;
	var lastControlDepth:Int = -1;
	var continuation:Null<Int>;
	public function new(size:Int, tabWidth:Int, canonical:Bool) {
		this.size = Std.int(Math.max(1, size)); this.tabWidth = tabWidth; this.canonical = canonical;
	}
	public function copy():IndentationContext {
		var result = new IndentationContext(size, tabWidth, canonical);
		for (frame in frames) result.frames.push({opener: frame.opener, base: frame.base, child: frame.child, caseBody: frame.caseBody, control: frame.control});
		result.pending = pending.copy(); result.lastBase = lastBase; result.lastControl = lastControl; result.lastControlDepth = lastControlDepth; result.continuation = continuation;
		return result;
	}
	function structural():Int {
		if (frames.length == 0) return 0;
		var top = frames[frames.length - 1];
		return top.child + (top.caseBody ? size : 0);
	}
	public function next():Int {
		if (frames.length > 0 && frames[frames.length - 1].opener != "{") return structural();
		if (pending.length > 0) return pending[pending.length - 1] + size;
		if (continuation != null) return continuation + size;
		return frames.length > 0 ? structural() : lastBase;
	}
	public function before(text:String):Int {
		var trimmed = StringTools.trim(text);
		if (trimmed == "{" && pending.length > 0) return pending[pending.length - 1];
		if (~/^(else\b|catch\b)/.match(trimmed) && lastControl != null && lastControlDepth == frames.length) return lastControl;
		if (trimmed.length > 0 && ["}", "]", ")"].indexOf(trimmed.charAt(0)) >= 0) {
			var expected = trimmed.charAt(0) == "}" ? "{" : trimmed.charAt(0) == "]" ? "[" : "(";
			var i = frames.length;
			while (i > 0) { i--; if (frames[i].opener == expected) return frames[i].base; }
		}
		if (~/^(case\b|default\s*:)/.match(trimmed)) {
			var i = frames.length;
			while (i > 0) { i--; if (frames[i].opener == "{") return frames[i].child; }
		}
		return next();
	}
	public function consume(text:String, actual:Int):Void {
		var trimmed = StringTools.trim(text);
		if (trimmed.length == 0) return;
		var base = canonical ? before(text) : actual;
		lastBase = base;
		var hadPending = pending.length > 0, priorFrames = frames.copy();
		var changed = false;
		for (i in 0...trimmed.length) {
			var c = trimmed.charAt(i);
			if (["{", "[", "("].indexOf(c) >= 0) {
				frames.push({opener: c, base: base, child: base + size, caseBody: false, control: (c == "{" || c == "(") && ~/^(if\b|else\b|for\b|while\b|catch\b|try\b|do\b)/.match(trimmed)}); if (c == "{") changed = true;
			} else if (["}", "]", ")"].indexOf(c) >= 0) {
				var expected = c == "}" ? "{" : c == "]" ? "[" : "(";
				if (frames.length > 0 && frames[frames.length - 1].opener == expected) {
					var frame = frames.pop();
					if (c == ")" && frame.control && priorFrames.indexOf(frame) >= 0 && StringTools.trim(trimmed.substring(i + 1)).length == 0) { pending.push(frame.base); lastControl = frame.base; lastControlDepth = frames.length; }
					if (c == "}") { lastBase = frame.base; if (frame.control) { lastControl = frame.base; lastControlDepth = frames.length; } }
				}
			}
		}
		if (~/^(case\b|default\s*:)/.match(trimmed) && StringTools.endsWith(trimmed, ":")) {
			if (frames.length > 0) frames[frames.length - 1].caseBody = true;
		}
		// Control headers without braces own one statement, including nested headers.
		var control = ~/^(if\b|else\b|for\b|while\b|catch\b|try\b|do\b)/.match(trimmed);
		var header = control && !changed && !StringTools.endsWith(trimmed, ";") &&
			(StringTools.endsWith(trimmed, ")") || trimmed == "else" || trimmed == "try" || trimmed == "do");
		if (header) { pending.push(base); lastControl = base; lastControlDepth = frames.length; }
		else if (hadPending && (StringTools.endsWith(trimmed, ";") || changed)) {
			lastControl = pending[pending.length - 1]; lastControlDepth = frames.length;
			lastBase = pending[0]; pending = [];
		}
		// Hanging expression continuations stay one level deep across multiple lines.
		if (~/[=+\-*/&|?:,]$/.match(trimmed) && !StringTools.endsWith(trimmed, ":") && !changed && (frames.length == 0 || frames[frames.length - 1].opener == "{")) {
			if (continuation == null) continuation = base;
		} else if (StringTools.endsWith(trimmed, ";") || changed) continuation = null;
	}
}

/** Paragraph checkpoints keep repeated Enter near the end of large files incremental. */
class IndentationCache {
	final buffer:TextBuffer;
	final highlighter:Highlighter;
	final checkpoints:Map<Int, IndentationContext> = [];
	final release:BufferSubscription;
	var size:Int = 0;
	var width:Int = 0;
	public function new(buffer:TextBuffer, highlighter:Highlighter) {
		this.buffer = buffer; this.highlighter = highlighter;
		release = buffer.subscribe(function(change) {
			var invalid = Std.int(change.start.line / 64) * 64;
			for (line in [for (key in checkpoints.keys()) key]) if (line >= invalid) checkpoints.remove(line);
		});
	}
	public function dispose():Void release.release();
	public function context(line:Int, nextSize:Int, nextWidth:Int):IndentationContext {
		if (size != nextSize || width != nextWidth) { checkpoints.clear(); size = nextSize; width = nextWidth; }
		var start = Std.int(line / 64) * 64;
		while (start > 0 && !checkpoints.exists(start)) start -= 64;
		var cached = checkpoints.get(start), state = cached == null ? new IndentationContext(size, width, false) : cached.copy();
		for (index in start...line) {
			var text = buffer.line(index);
			state.consume(Indentation.code(text, index, highlighter), EditorActions.visualColumn(text, Indentation.leading(text), width));
			if ((index + 1) % 64 == 0) checkpoints.set(index + 1, state.copy());
		}
		return state;
	}
}
