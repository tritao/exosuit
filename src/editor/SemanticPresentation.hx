package editor;

import language.LanguageSemanticSnapshot;
import style.Theme;

/** Semantic foreground overrides syntax without overlapping renderer ranges. */
class SemanticPresentation {
	public static function foreground(document:Document, theme:Theme, snapshot:Null<LanguageSemanticSnapshot>, start:Int, end:Int):Array<SyntaxColorRange> {
		var syntax = SyntaxPresentation.foreground(document, theme, start, end);
		if (snapshot == null || snapshot.documentId != document.id || snapshot.revision != document.buffer.stateId) return syntax;
		var semantic:Array<SyntaxColorRange> = [], tokens = snapshot.tokens;
		var low = 0, high = tokens.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (tokens[middle].end <= start) low = middle + 1; else high = middle;
		}
		while (low < tokens.length && tokens[low].start < end) {
			var token = tokens[low++], color = theme.semanticColor(token.type, token.modifiers);
			if (color != null) semantic.push(new SyntaxColorRange(Std.int(Math.max(start, token.start)), Std.int(Math.min(end, token.end)), color));
		}
		if (semantic.length == 0) return syntax;
		var result:Array<SyntaxColorRange> = [], index = 0;
		for (range in syntax) {
			var cursor = range.start;
			while (index < semantic.length && semantic[index].end <= cursor) index++;
			var current = index;
			while (current < semantic.length && semantic[current].start < range.end) {
				var overlay = semantic[current++];
				if (overlay.start > cursor) result.push(new SyntaxColorRange(cursor, overlay.start, range.color));
				cursor = Std.int(Math.max(cursor, overlay.end));
			}
			if (cursor < range.end) result.push(new SyntaxColorRange(cursor, range.end, range.color));
		}
		for (range in semantic) result.push(range);
		result.sort((left, right) -> left.start - right.start);
		return result;
	}
}
