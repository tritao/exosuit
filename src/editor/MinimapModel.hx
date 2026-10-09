package editor;

/** Bounded, theme-independent preview data. Scrolling never rebuilds these spans. */
class MinimapModel {
	public static inline final MAX_ROWS = 2048;
	static inline final MAX_COLORED_ROWS = 512;
	public static inline final MAX_COLUMNS = 80;
	public static inline final MAX_BITMAP_HEIGHT = 2048;
	public final rows:Array<MinimapRow> = [];
	public var generation(default, null):Int = 0;
	var revision:Int = -1;
	var documentId:Int = -1;
	var syntax:Null<syntax.SyntaxDefinition>;
	var rangeStart:Int = -1;
	var rangeEnd:Int = -1;
	var visualRevision:Int = -1;

	public function new() {}

	public function update(document:Document, firstLine:Int = -1, lastLine:Int = -1, ?visualRows:Array<{start:Int, end:Int, top:Float, bottom:Float}>, geometryRevision:Int = -1):Void {
		if (documentId == document.id && revision == document.buffer.stateId && syntax == document.syntax && rangeStart == firstLine && rangeEnd == lastLine && visualRevision == geometryRevision) return;
		generation++;
		visualRevision = geometryRevision;
		rangeStart = firstLine;
		rangeEnd = lastLine;
		documentId = document.id;
		revision = document.buffer.stateId;
		syntax = document.syntax;
		rows.resize(0);
		var count = visualRows == null ? document.buffer.lineCount() : visualRows.length;
		var start = firstLine < 0 ? 0 : Std.int(Math.max(0, Math.min(count - 1, firstLine)));
		var end = lastLine < 0 ? count : Std.int(Math.max(start + 1, Math.min(count, lastLine + 1)));
		var samples = Std.int(Math.min(end - start, MAX_ROWS));
		// Avoid advancing the stateful highlighter through a huge file just for its preview.
		var colored = document.buffer.lineCount() <= MAX_COLORED_ROWS && document.buffer.document.codepointCount <= 32768;
		for (sample in 0...samples) {
			var line = samples <= 1 ? start : start + Std.int(sample * (end - start - 1) / (samples - 1));
			var sourceLine = visualRows == null ? line : document.buffer.document.paragraphIndexAtOffset(visualRows[line].start);
			var text = document.buffer.line(sourceLine);
			var startOffset = visualRows == null ? 0 : EditorCoordinates.position(document, visualRows[line].start).column;
			var endOffset = visualRows == null ? text.length : document.buffer.document.utf16OffsetForCodepoint(visualRows[line].end) - document.buffer.document.utf16OffsetForCodepoint(document.buffer.document.paragraphRangeAtIndex(sourceLine).start);
			var tokens = colored ? document.highlighter.line(sourceLine).tokens : [];
			var spans:Array<MinimapSpan> = [];
			var offset = startOffset, column = 0, token = 0;
			while (offset < Math.min(text.length, endOffset) && column < MAX_COLUMNS) {
				var code = text.charCodeAt(offset);
				while (token + 1 < tokens.length && offset >= tokens[token].start + tokens[token].length) token++;
				var kind = tokens.length == 0 ? 0 : tokens[token].kind;
				var width = code == 9 ? 4 - column % 4 : 1;
				if (code != 9 && code != 32 && code != 13) {
					var previous = spans.length == 0 ? null : spans[spans.length - 1];
					if (previous != null && previous.kind == kind && previous.start + previous.length == column) previous.length++;
					else spans.push({start: column, length: 1, kind: kind});
				}
				column += width;
				offset++;
				if (code >= 0xd800 && code <= 0xdbff && offset < text.length) {
					var next = text.charCodeAt(offset);
					if (next >= 0xdc00 && next <= 0xdfff) offset++;
				}
			}
			rows.push({line: line, spans: spans});
		}
	}

	/** A dense preview never expands into thousands of GPU path meshes. */
	public function rasterize(colors:Array<Int>, positions:Array<Float>, contentHeight:Float,
			height:Float, markHeight:Int = 1, rasterScale:Float = 1.0):MinimapBitmap {
		var pixelHeight = Std.int(Math.max(1, Math.min(MAX_BITMAP_HEIGHT, Math.ceil(height * rasterScale))));
		var pixels = haxe.io.Bytes.alloc(MAX_COLUMNS * pixelHeight * 4);
		markHeight = Std.int(Math.max(1, Math.min(2, markHeight)));
		for (index in 0...rows.length) {
			var y = index < positions.length
				? positions[index] / Math.max(1, contentHeight)
				: rows.length <= 1 ? 0.0 : index / (rows.length - 1);
			if (index < positions.length && (y < 0 || y >= 1)) continue;
			var row = Std.int(Math.max(0, Math.min(pixelHeight - 1, Math.floor(y * pixelHeight))));
			for (span in rows[index].spans) {
				var color = colors[span.kind];
				for (pixelRow in row...Std.int(Math.min(pixelHeight, row + markHeight)))
					for (column in span.start...Std.int(Math.min(MAX_COLUMNS, span.start + span.length))) {
						var offset = (pixelRow * MAX_COLUMNS + column) * 4;
						pixels.set(offset, (color >>> 24) & 255);
						pixels.set(offset + 1, (color >>> 16) & 255);
						pixels.set(offset + 2, (color >>> 8) & 255);
						pixels.set(offset + 3, Std.int((color & 255) * 0.4));
					}
			}
		}
		return {width: MAX_COLUMNS, height: pixelHeight, pixels: pixels};
	}
}

typedef MinimapRow = {var line:Int; var spans:Array<MinimapSpan>;}
typedef MinimapSpan = {var start:Int; var length:Int; var kind:Int;}

typedef MinimapBitmap = {
	var width:Int;
	var height:Int;
	var pixels:haxe.io.Bytes;
}
