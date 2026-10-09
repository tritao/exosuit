package scm;

import jobs.JobTask;

/** Step-sliced Myers O(ND) diff. Work and trace memory are bounded by maxCost. */
class LineDiff implements JobTask {
	public static inline final DEFAULT_MAX_COST = 250000;
	public static inline final DEFAULT_SLICE_COST = 256;

	public final oldLines:Array<String>;
	public final newLines:Array<String>;
	public var result(default, null):Null<Array<LineDiffHunk>>;
	public var finished(default, null):Bool = false;
	public var cancelled(default, null):Bool = false;
	public var cost(default, null):Int = 0;

	final maxCost:Int;
	final sliceCost:Int;
	final complete:Null<Array<LineDiffHunk>->Void>;
	final textsEqual:Bool;
	final maxDistance:Int;
	final offset:Int;
	final frontier:Array<Int> = [];
	final trace:Array<Array<Int>> = [];
	var distance:Int = 0;
	var diagonal:Int = 0;
	var active:Bool = false;
	var x:Int = 0;
	var y:Int = 0;

	public function new(oldText:String, newText:String, ?complete:Array<LineDiffHunk>->Void,
			maxCost:Int = DEFAULT_MAX_COST, sliceCost:Int = DEFAULT_SLICE_COST) {
		oldLines = splitLines(oldText);
		newLines = splitLines(newText);
		this.complete = complete;
		textsEqual = oldText == newText;
		this.maxCost = maxCost < 1 ? 1 : maxCost;
		this.sliceCost = sliceCost < 1 ? 1 : sliceCost;
		maxDistance = oldLines.length + newLines.length;
		offset = maxDistance + 1;
		for (_ in 0...(maxDistance * 2 + 3)) frontier.push(-1);
		frontier[offset + 1] = 0;
	}

	/** Lines retain LF termination; CRLF is normalized so repository EOL policy does not mark every line changed. */
	public static function splitLines(text:String):Array<String> {
		var result:Array<String> = [], start = 0;
		for (index in 0...text.length) if (text.charCodeAt(index) == 10) {
			var end = index > start && text.charCodeAt(index - 1) == 13 ? index - 1 : index;
			result.push(text.substring(start, end) + "\n");
			start = index + 1;
		}
		if (start < text.length) result.push(text.substring(start));
		return result;
	}

	/** Performs at most sliceCost frontier/comparison units and can be scheduled as a JobTask. */
	public function step():Bool {
		if (finished || cancelled) return true;
		var units = 0;
		while (units < sliceCost) {
			if (!active) {
				if (diagonal > distance) {
					distance++;
					if (distance > maxDistance) {
						finish(fallback());
						return true;
					}
					capture(distance - 1);
					diagonal = -distance;
				}
				if (!charge()) return true;
				units++;
				if (diagonal == -distance || (diagonal != distance && valueAt(diagonal - 1) < valueAt(diagonal + 1)))
					x = valueAt(diagonal + 1);
				else
					x = valueAt(diagonal - 1) + 1;
				y = x - diagonal;
				active = true;
			}
			if (x < oldLines.length && y < newLines.length) {
				if (!charge()) return true;
				units++;
				if (oldLines[x] == newLines[y]) {
					x++;
					y++;
					if (units >= sliceCost) return false;
					continue;
				}
			}
			setValue(diagonal, x);
			active = false;
			if (x >= oldLines.length && y >= newLines.length) {
				finish(buildHunks(backtrack(distance)));
				return true;
			}
			diagonal += 2;
		}
		return false;
	}

	function charge():Bool {
		cost++;
		if (cost > maxCost) {
			finish(fallback());
			return false;
		}
		return true;
	}

	function valueAt(k:Int):Int {
		var index = offset + k;
		return index < 0 || index >= frontier.length ? -1 : frontier[index];
	}

	function setValue(k:Int, value:Int):Void frontier[offset + k] = value;

	function capture(previousDistance:Int):Void {
		var layer:Array<Int> = [], k = -previousDistance;
		while (k <= previousDistance) {
			layer.push(valueAt(k));
			k++;
		}
		trace.push(layer);
	}

	function backtrack(finalDistance:Int):Array<Int> {
		var reversed:Array<Int> = [], oldIndex = oldLines.length, newIndex = newLines.length;
		var d = finalDistance;
		while (d > 0) {
			var previousDistance = d - 1, layer = trace[d - 1], k = oldIndex - newIndex;
			var previousK = (k == -d || (k != d && traceValue(layer, previousDistance, k - 1) < traceValue(layer, previousDistance, k + 1)))
				? k + 1 : k - 1;
			var previousX = traceValue(layer, previousDistance, previousK), previousY = previousX - previousK;
			while (oldIndex > previousX && newIndex > previousY) {
				reversed.push(0);
				oldIndex--;
				newIndex--;
			}
			if (oldIndex == previousX) {
				newIndex--;
				reversed.push(2);
			} else {
				oldIndex--;
				reversed.push(1);
			}
			d--;
		}
		while (oldIndex > 0 && newIndex > 0) {
			reversed.push(0);
			oldIndex--;
			newIndex--;
		}
		while (oldIndex > 0) { oldIndex--; reversed.push(1); }
		while (newIndex > 0) { newIndex--; reversed.push(2); }
		reversed.reverse();
		return reversed;
	}

	static function traceValue(layer:Array<Int>, distance:Int, diagonal:Int):Int {
		var index = diagonal + distance;
		return index < 0 || index >= layer.length ? -1 : layer[index];
	}

	function buildHunks(edits:Array<Int>):Array<LineDiffHunk> {
		var hunks:Array<LineDiffHunk> = [], oldIndex = 0, newIndex = 0;
		var startOld = -1, startNew = -1, removed = 0, added = 0;
		function flush():Void {
			if (startOld < 0) return;
			var kind = removed == 0 ? LineDiffKind.Added : added == 0 ? LineDiffKind.Deleted : LineDiffKind.Modified;
			hunks.push(new LineDiffHunk(kind, startOld, removed, startNew, added));
			startOld = -1;
			startNew = -1;
			removed = 0;
			added = 0;
		}
		for (edit in edits) {
			if (edit == 0) {
				flush();
				oldIndex++;
				newIndex++;
			} else {
				if (startOld < 0) { startOld = oldIndex; startNew = newIndex; }
				if (edit == 1) { oldIndex++; removed++; } else { newIndex++; added++; }
			}
		}
		flush();
		return hunks;
	}

	function fallback():Array<LineDiffHunk> {
		if (oldLines.length == 0 && newLines.length == 0) return [];
		if (textsEqual) return [];
		var kind = oldLines.length == 0 ? LineDiffKind.Added : newLines.length == 0 ? LineDiffKind.Deleted : LineDiffKind.Modified;
		return [new LineDiffHunk(kind, 0, oldLines.length, 0, newLines.length)];
	}

	function finish(value:Array<LineDiffHunk>):Void {
		if (finished || cancelled) return;
		result = value;
		finished = true;
		if (complete != null) complete(value);
	}

	public function cancel():Void cancelled = true;
}
