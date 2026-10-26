package workspace;

/**
	A file's size and change times: what writing a file changes, including replacing it by an atomic rename. Times have
	whole-second precision, so a stamp vouches for content only when the file had settled before the content was read
	(git's "racy" rule): a write in the same second as the read could leave the stamp unchanged.
**/
class FileStamp {
	final size:Int;
	final modified:Int;
	final changed:Int;

	public function new(size:Int, modified:Int, changed:Int) {
		this.size = size;
		this.modified = modified;
		this.changed = changed;
	}

	public function equals(other:Null<FileStamp>):Bool
		return other != null && size == other.size && modified == other.modified && changed == other.changed;

	/** True when the file last changed at least a full second before `time` (Unix seconds), so content read at `time`
		cannot hide a later write behind this stamp. */
	public function settledBefore(time:Float):Bool
		return (modified > changed ? modified : changed) < Math.ffloor(time) - 1.0;
}
