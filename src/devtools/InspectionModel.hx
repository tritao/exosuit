package devtools;

typedef InspectionDelta = {
	var full:Bool;
	var changed:Array<Dynamic>;
	var removed:Array<Int>;
	var next:Map<Int, String>;
}

/** Bounded wire model. Rows contain only values; render nodes never leave the UI thread. */
class InspectionModel {
	public static inline final VERSION = 1;
	public static inline final FRAME_LIMIT = 240;
	public static inline final NODE_LIMIT = 1000;
	public final frames:Array<Dynamic> = [];
	public var nodes(default, null):Array<Dynamic> = [];
	public var selected:Dynamic = null;
	public var sequence(default, null):Int = 0;
	public var truncated = false;
	public var droppedFrames = 0;

	public function new() {}

	public function addFrame(frame:Dynamic):Void {
		frames.push(frame);
		if (frames.length > FRAME_LIMIT) { frames.shift(); droppedFrames++; }
	}

	public function update(rows:Array<Dynamic>):Void {
		truncated = rows.length > NODE_LIMIT;
		nodes = rows.slice(0, NODE_LIMIT);
		sequence++;
	}

	/** Deltas are relative to one acknowledged response. A reconnect requests a full snapshot. */
	public function delta(previous:Map<Int, String>, full:Bool):InspectionDelta {
		var next:Map<Int, String> = [], changed:Array<Dynamic> = [], removed:Array<Int> = [];
		for (row in nodes) {
			var id:Int = row.id;
			var encoded = haxe.Json.stringify(row);
			next.set(id, encoded);
			if (full || previous.get(id) != encoded) changed.push(row);
		}
		if (!full) for (id in previous.keys()) if (!next.exists(id)) removed.push(id);
		return {full:full, changed:changed, removed:removed, next:next};
	}
}
