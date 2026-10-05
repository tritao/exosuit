package feedback;

class ProblemRegistry {
	final entries:Array<Problem> = [];
	public var revision(default, null):Int = 0;
	public function new() {}
	public function values():Array<Problem> return entries.copy();
	public function add(value:Problem):Void { for (index in 0...entries.length) if (entries[index].key() == value.key()) { if (!entries[index].same(value)) { entries[index] = value; revision++; } return; }
		entries.push(value); revision++; }
	/** A producer publishes one complete snapshot without intermediate empty states. */
	public function replaceOwner(owner:String, values:Array<Problem>):Void {
		var ids:Map<String, Bool> = [];
		for (value in values) {
			if (value.owner != owner || ids.exists(value.id)) throw "Invalid diagnostic snapshot for " + owner;
			ids.set(value.id, true);
		}
		var previous = [for (entry in entries) if (entry.owner == owner) entry];
		var unchanged = previous.length == values.length;
		if (unchanged) for (index in 0...previous.length) if (!previous[index].same(values[index])) unchanged = false;
		if (unchanged) return;
		var index = entries.length;
		while (index > 0) { index--; if (entries[index].owner == owner) entries.splice(index, 1); }
		for (value in values) entries.push(value);
		revision++;
	}

	public function removeOwner(owner:String):Void {
		var index = entries.length;
		while (index > 0) { index--; if (entries[index].owner == owner) { entries.splice(index, 1); revision++; } }
	}
}
