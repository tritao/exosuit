package editor;

/** Bounded, theme-independent preview data. Scrolling never rebuilds these spans. */
class MinimapModel {
	public static inline final MAX_ROWS = 512;
	public static inline final MAX_COLUMNS = 80;
	public final rows:Array<MinimapRow> = [];
	public var generation(default, null):Int = 0;
	var revision:Int = -1;
	var documentId:Int = -1;
	var syntax:Null<syntax.SyntaxDefinition>;

	public function new() {}

	public function update(document:Document):Void {
		if (documentId == document.id && revision == document.buffer.stateId && syntax == document.syntax) return;
		generation++;
		documentId = document.id;
		revision = document.buffer.stateId;
		syntax = document.syntax;
		rows.resize(0);
		var count = document.buffer.lineCount();
		var samples = Std.int(Math.min(count, MAX_ROWS));
		// Avoid advancing the stateful highlighter through a huge file just for its preview.
		var colored = count <= MAX_ROWS && document.buffer.document.codepointCount <= 32768;
		for (sample in 0...samples) {
			var line = samples <= 1 ? 0 : Std.int(sample * (count - 1) / (samples - 1));
			var text = document.buffer.line(line);
			var tokens = colored ? document.highlighter.line(line).tokens : [];
			var spans:Array<MinimapSpan> = [];
			var offset = 0, column = 0, token = 0;
			while (offset < text.length && column < MAX_COLUMNS) {
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

	/** Center a viewport on a map coordinate; safe for empty/short documents. */
	public static function scrollTarget(y:Float, mapHeight:Float, contentHeight:Float, viewportHeight:Float):Float {
		if (mapHeight <= 0 || contentHeight <= viewportHeight) return 0;
		return Math.max(0, Math.min(contentHeight - viewportHeight,
			y / mapHeight * contentHeight - viewportHeight / 2));
	}
}

typedef MinimapRow = {var line:Int; var spans:Array<MinimapSpan>;}
typedef MinimapSpan = {var start:Int; var length:Int; var kind:Int;}
