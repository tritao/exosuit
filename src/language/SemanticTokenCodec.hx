package language;

import editor.Document;
import editor.EditorCoordinates;

/** Decodes LSP relative UTF-16 tokens, rejecting malformed or overlapping data. */
class SemanticTokenCodec {
	public static function decode(document:Document, data:Dynamic, types:Array<String>, modifiers:Array<String>):Null<Array<LanguageSemanticToken>> {
		if (!Std.isOfType(data, Array)) return null;
		var values:Array<Dynamic> = cast data;
		if (values.length % 5 != 0) return null;
		var result:Array<LanguageSemanticToken> = [], line = 0, column = 0, previousEnd = 0;
		for (index in 0...Std.int(values.length / 5)) {
			var at = index * 5;
			for (part in 0...5) if (!Std.isOfType(values[at + part], Int) || values[at + part] < 0) return null;
			var deltaLine:Int = values[at], deltaColumn:Int = values[at + 1], length:Int = values[at + 2],
				type:Int = values[at + 3], mask:Int = values[at + 4];
			line += deltaLine;
			column = deltaLine == 0 ? column + deltaColumn : deltaColumn;
			if (line < 0 || column < 0 || length <= 0 || type >= types.length || line >= document.buffer.lineCount() ||
				column > document.buffer.line(line).length - length) return null;
			var from = LspPositionCodec.decode(document.buffer, {line: line, character: column}),
				to = LspPositionCodec.decode(document.buffer, {line: line, character: column + length});
			if (from == null || to == null) return null;
			var start = EditorCoordinates.codepoint(document, from), end = EditorCoordinates.codepoint(document, to);
			var text = document.buffer.document, paragraph = text.paragraphRangeAtIndex(line);
			var utf16Start = text.utf16OffsetForCodepoint(paragraph.start);
			if (start < previousEnd || end <= start || text.utf16OffsetForCodepoint(start) != utf16Start + column ||
				text.utf16OffsetForCodepoint(end) != utf16Start + column + length) return null;
			var flags:Array<String> = [];
			for (bit in 0...31) if ((mask & (1 << bit)) != 0) {
				if (bit >= modifiers.length) return null;
				flags.push(modifiers[bit]);
			}
			result.push(new LanguageSemanticToken(start, end, types[type], flags));
			previousEnd = end;
		}
		return result;
	}
}
