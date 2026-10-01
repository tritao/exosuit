package editor;

/** Shared conversion between buffer UTF-16 positions and retained layout codepoints. */
class EditorCoordinates {
	public static function codepoint(document:Document, position:BufferPosition):Int {
		var value = document.buffer.positionAt(position.line, position.column);
		var text = document.buffer.document;
		var paragraph = text.paragraphRangeAtIndex(value.line);
		return text.codepointOffsetForUtf16(text.utf16OffsetForCodepoint(paragraph.start) + value.column);
	}

	public static function position(document:Document, offset:Int):BufferPosition {
		var text = document.buffer.document;
		if (offset < 0 || offset > text.codepointCount) throw "Caret offset is outside the document";
		var line = text.paragraphIndexAtOffset(offset);
		var paragraph = text.paragraphRangeAtIndex(line);
		return new BufferPosition(line, text.utf16OffsetForCodepoint(offset) - text.utf16OffsetForCodepoint(paragraph.start));
	}
}
