package editor;

import style.Theme;
import syntax.HighlightToken;

/** Adapts cached UTF-16 syntax tokens to visible Unicode codepoint ranges. */
class SyntaxPresentation {
	public static function foreground(document:Document, theme:Theme, start:Int, end:Int):Array<SyntaxColorRange> {
		var text = document.buffer.document;
		if (start < 0 || end < start || end > text.codepointCount)
			throw "Syntax presentation range is outside the document";
		var result:Array<SyntaxColorRange> = [];
		if (start == end) return result;
		var first = text.paragraphIndexAtOffset(start);
		var last = text.paragraphIndexAtOffset(end - 1);
		for (line in first...last + 1) {
			var paragraph = text.paragraphRangeAtIndex(line);
			var utf16Start = text.utf16OffsetForCodepoint(paragraph.start);
			for (token in document.highlighter.line(line).tokens) {
				if (token.kind == HighlightToken.NORMAL) continue;
				var from = Std.int(Math.max(start, text.codepointOffsetForUtf16(utf16Start + token.start)));
				var to = Std.int(Math.min(end, text.codepointOffsetForUtf16(utf16Start + token.start + token.length)));
				if (from < to) result.push(new SyntaxColorRange(from, to, theme.tokenColor(token.kind)));
			}
		}
		return result;
	}
}
