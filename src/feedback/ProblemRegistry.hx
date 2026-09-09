package feedback;

class ProblemRegistry {
	final entries:Array<Problem> = [];
	public function new() {}
	public function values():Array<Problem> return entries.copy();
	public function add(value:Problem):Void entries.push(value);
	public function removeOwner(owner:String):Void {
		var index = entries.length;
		while (index > 0) { index--; if (entries[index].owner == owner) entries.splice(index, 1); }
	}
}
