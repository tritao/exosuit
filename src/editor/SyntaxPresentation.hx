package editor;

import style.Theme;
import haxeon.editor.TextDocument;
import syntax.Highlighter;
import syntax.HighlightToken;

/** Adapts cached UTF-16 syntax tokens to visible Unicode codepoint ranges. */
class SyntaxPresentation {
	public static function foreground(document:Document, theme:Theme, start:Int, end:Int):Array<SyntaxColorRange> {
		return foregroundText(document.buffer.document, document.highlighter, theme, start, end);
	}

	/** Adapts a cached highlighter to visible codepoint ranges without requiring a saveable Document. */
	public static function foregroundText(text:TextDocument, highlighter:Highlighter, theme:Theme,
			start:Int, end:Int):Array<SyntaxColorRange> {
		if (text == null || highlighter == null || theme == null)
			throw "Syntax presentation requires a document, highlighter and theme";
		if (start < 0 || end < start || end > text.codepointCount)
			throw "Syntax presentation range is outside the document";
		var result:Array<SyntaxColorRange> = [];
		if (start == end) return result;
		var first = text.paragraphIndexAtOffset(start);
		var last = text.paragraphIndexAtOffset(end - 1);
		for (line in first...last + 1) {
			var paragraph = text.paragraphRangeAtIndex(line);
			var utf16Start = text.utf16OffsetForCodepoint(paragraph.start);
			for (token in highlighter.line(line).tokens) {
				if (token.kind == HighlightToken.NORMAL) continue;
				var from = Std.int(Math.max(start, text.codepointOffsetForUtf16(utf16Start + token.start)));
				var to = Std.int(Math.min(end, text.codepointOffsetForUtf16(utf16Start + token.start + token.length)));
				if (from < to) result.push(new SyntaxColorRange(from, to, theme.tokenColor(token.kind)));
			}
		}
		return result;
	}
}
