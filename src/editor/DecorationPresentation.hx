package editor;

import plugin.PluginDecoration;
import plugin.PluginDecorationKind;
import search.SearchMatch;
import style.Theme;

/** Converts current plugin and search ranges to the retained layout coordinate space. */
class DecorationPresentation {
	public static function ranges(document:Document, theme:Theme, plugins:Array<PluginDecoration>,
			matches:Array<SearchMatch>, start:Int, end:Int):Array<DecorationRange> {
		if (start < 0 || end < start || end > document.buffer.document.codepointCount)
			throw "Decoration presentation range is outside the document";
		var result:Array<DecorationRange> = [];
		for (value in plugins)
			if (value.document == document)
				append(result, document, value.line, value.startColumn, value.endColumn,
					value.color, value.kind, start, end);
		for (match in matches)
			if ((match.document == null || match.document == document) &&
				(match.revision < 0 || match.revision == document.buffer.stateId))
				append(result, document, match.line, match.column, match.column + match.length,
					theme.searchMatch, Background, start, end);
		return result;
	}

	static function append(result:Array<DecorationRange>, document:Document, line:Int, from:Int, to:Int,
			color:Int, kind:PluginDecorationKind, start:Int, end:Int):Void {
		var buffer = document.buffer;
		if (line < 0 || line >= buffer.lineCount()) return;
		var first = buffer.positionAt(line, from);
		var last = buffer.positionAt(line, to);
		if (last.before(first) || first.equals(last) && kind != WholeLineBackground) return;
		var text = buffer.document;
		var paragraph = text.paragraphRangeAtIndex(line);
		var utf16Start = text.utf16OffsetForCodepoint(paragraph.start);
		var rangeStart = text.codepointOffsetForUtf16(utf16Start + first.column);
		var rangeEnd = text.codepointOffsetForUtf16(utf16Start + last.column);
		if (rangeStart == rangeEnd ? rangeStart >= start && rangeStart <= end : rangeStart < end && rangeEnd > start)
			result.push(new DecorationRange(rangeStart, rangeEnd, color, kind));
	}
}
