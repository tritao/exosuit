package editor;

/** Piecewise mapping from shaped visual row bounds to uniform preview rows. */
class MinimapLineMap {
	public final rows:Array<{start:Int, end:Int, top:Float, bottom:Float}>;
	public function new(rows:Array<{start:Int, end:Int, top:Float, bottom:Float}>) this.rows = rows;

	function rowTop(index:Int):Float return index == 0 ? 0 : rows[index].top;
	function rowBottom(index:Int):Float return index + 1 < rows.length ? rows[index + 1].top : rows[index].bottom;

	public function rowAt(y:Float):Int {
		var low = 0, high = rows.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (rowBottom(middle) <= y) low = middle + 1; else high = middle;
		}
		return Std.int(Math.min(Math.max(0, rows.length - 1), low));
	}

	public function previewAt(y:Float, pitch:Float):Float {
		if (rows.length == 0) return 0;
		var index = rowAt(y);
		return Math.max(0, (index + (y - rowTop(index)) / Math.max(1, rowBottom(index) - rowTop(index))) * pitch);
	}

	public function sourceAt(preview:Float, pitch:Float):Float {
		if (rows.length == 0) return 0;
		var position = Math.max(0, preview / pitch);
		var index = Std.int(Math.min(rows.length - 1, Math.floor(position)));
		return rowTop(index) + (position - index) * Math.max(1, rowBottom(index) - rowTop(index));
	}
}
