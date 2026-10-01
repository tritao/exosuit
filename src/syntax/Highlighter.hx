package syntax;

import editor.TextBuffer;
import editor.BufferChange;

class Highlighter {
	static inline final NORMAL_STATE = 0;
	static inline final COMMENT_STATE = 1;
	static inline final DOUBLE_STRING_STATE = 2;
	static inline final SINGLE_STRING_STATE = 3;
	static inline final CUSTOM_STRING_STATE = 4;
	public final buffer:TextBuffer;
	public final syntax:SyntaxDefinition;
	final cache:Map<Int, HighlightedLine> = [];
	var validatedThrough:Int = -1;

	public function new(buffer:TextBuffer, syntax:SyntaxDefinition) {
		this.buffer = buffer;
		this.syntax = syntax;
	}

	public function invalidate(line:Int, removedLines:Int, insertedLines:Int):Void {
		var retained:Map<Int, HighlightedLine> = [], delta = insertedLines - removedLines;
		for (index => highlighted in cache)
			if (index < line) retained.set(index, highlighted);
			else if (index > line + removedLines) retained.set(index + delta, highlighted);
		var stale = [for (index in cache.keys()) index];
		for (index in stale) cache.remove(index);
		for (index => highlighted in retained) cache.set(index, highlighted);
		if (validatedThrough >= line) validatedThrough = line - 1;
	}

	public function bufferChanged(change:BufferChange):Void
		invalidate(change.start.line, change.removedLines, change.insertedLines);

	public function line(index:Int):HighlightedLine {
		if (index <= validatedThrough) return cache.get(index);
		var start = validatedThrough + 1, state = NORMAL_STATE;
		if (start > 0) {
			var previous = cache.get(start - 1);
			if (previous == null) {
				start = 0;
				validatedThrough = -1;
			} else state = previous.stateAfter;
		}
		for (lineIndex in start...index + 1) {
			var text = buffer.line(lineIndex), cached = cache.get(lineIndex);
			if (cached == null || cached.text != text || cached.stateBefore != state) {
				cached = tokenize(text, state);
				cache.set(lineIndex, cached);
			}
			state = cached.stateAfter;
		}
		validatedThrough = index;
		return cache.get(index);
	}

	function tokenize(text:String, initialState:Int):HighlightedLine {
		if (!syntax.highlighting)
			return new HighlightedLine(text, [new HighlightToken(HighlightToken.NORMAL, 0, text.length)], NORMAL_STATE, NORMAL_STATE);
		var tokens:Array<HighlightToken> = [], index = 0, state = initialState;
		while (index < text.length) {
			var start = index, kind = HighlightToken.NORMAL;
			if (state == COMMENT_STATE) {
				kind = HighlightToken.COMMENT;
				var close = text.indexOf(syntax.blockCommentEnd, index);
				if (close < 0) index = text.length;
				else {
					index = close + syntax.blockCommentEnd.length;
					state = NORMAL_STATE;
				}
			} else if (state == CUSTOM_STRING_STATE) {
				kind = HighlightToken.STRING;
				var close = text.indexOf(syntax.multilineStringEnd, index);
				if (close < 0) index = text.length;
				else {
					index = close + syntax.multilineStringEnd.length;
					state = NORMAL_STATE;
				}
			} else if (state == DOUBLE_STRING_STATE || state == SINGLE_STRING_STATE) {
				kind = HighlightToken.STRING;
				var quote = state == DOUBLE_STRING_STATE ? 34 : 39;
				index = stringEnd(text, index, quote);
				if (index > 0 && text.charCodeAt(index - 1) == quote) state = NORMAL_STATE;
			} else if (syntax.blockCommentStart.length > 0 && startsAt(text, index, syntax.blockCommentStart)) {
				kind = HighlightToken.COMMENT;
				var close = text.indexOf(syntax.blockCommentEnd, index + syntax.blockCommentStart.length);
				if (close < 0) {
					index = text.length;
					state = COMMENT_STATE;
				} else index = close + syntax.blockCommentEnd.length;
			} else if (syntax.lineComment.length > 0 && startsAt(text, index, syntax.lineComment)) {
				kind = HighlightToken.COMMENT;
				index = text.length;
			} else if (syntax.multilineStringStart.length > 0 && startsAt(text, index, syntax.multilineStringStart)) {
				kind = HighlightToken.STRING;
				var close = text.indexOf(syntax.multilineStringEnd, index + syntax.multilineStringStart.length);
				if (close < 0) {
					index = text.length;
					state = CUSTOM_STRING_STATE;
				} else index = close + syntax.multilineStringEnd.length;
			} else {
				var code = text.charCodeAt(index);
				if (code == 34 || code == 39) {
					kind = HighlightToken.STRING;
					var quote = code;
					index = stringEnd(text, index + 1, quote);
					if (syntax.stringsContinueAcrossLines && (index == 0 || text.charCodeAt(index - 1) != quote))
						state = quote == 34 ? DOUBLE_STRING_STATE : SINGLE_STRING_STATE;
				} else if (isDigit(code)) {
					kind = HighlightToken.NUMBER;
					index++;
					while (index < text.length && (isIdentifier(text.charCodeAt(index)) || text.charCodeAt(index) == 46)) index++;
				} else if (isIdentifierStart(code)) {
					index++;
					while (index < text.length && isIdentifier(text.charCodeAt(index))) index++;
					var symbol = text.substring(start, index), symbolKind = syntax.keywords.get(symbol);
					kind = symbolKind == null ? HighlightToken.NORMAL : symbolKind;
				} else {
					if (isSpace(code)) {
						kind = HighlightToken.NORMAL;
						index++;
						while (index < text.length && isSpace(text.charCodeAt(index))) index++;
					} else {
						kind = HighlightToken.OPERATOR;
						index++;
						// Keep token boundaries outside UTF-16 surrogate pairs.
						if (code >= 0xd800 && code <= 0xdbff && index < text.length) {
							var next = text.charCodeAt(index);
							if (next >= 0xdc00 && next <= 0xdfff) index++;
						}
					}
				}
			}
			push(tokens, kind, start, index - start);
		}
		return new HighlightedLine(text, tokens, initialState, state);
	}

	static function stringEnd(text:String, index:Int, quote:Int):Int {
		while (index < text.length) {
			var current = text.charCodeAt(index++);
			if (current == 92 && index < text.length) index++;
			else if (current == quote) break;
		}
		return index;
	}

	static function push(tokens:Array<HighlightToken>, kind:Int, start:Int, length:Int):Void {
		if (length > 0) tokens.push(new HighlightToken(kind, start, length));
	}

	static function startsAt(text:String, index:Int, value:String):Bool
		return text.substr(index, value.length) == value;

	static function isSpace(code:Int):Bool
		return code == 9 || code == 32;

	static function isDigit(code:Int):Bool
		return code >= 48 && code <= 57;

	static function isIdentifierStart(code:Int):Bool
		return code == 95 || code >= 65 && code <= 90 || code >= 97 && code <= 122;

	static function isIdentifier(code:Int):Bool
		return isIdentifierStart(code) || isDigit(code);
}
