package ui;

/**
	Decides when the Workbench model takes a change of the machine rows' inputs. A change to anything but the catalogs
	(structure: the machine, the open workspace, expansion) applies at once. A change to the catalogs alone, such as a
	busy session, applies at most every THROTTLE seconds; the last one is held and applies on the first check after
	that, so the tree never stays behind.
**/
class CatalogThrottle {
	public static inline final THROTTLE = 0.1;

	/** The inputs the model last took; "" before the first. */
	public var key(default, null):String = "";
	/** True after `due` held a catalog change back: ask for another frame so it is checked again. */
	public var waiting(default, null):Bool = false;
	var structure = "";
	var last = 0.0;

	public function new() {}

	/** Whether the model should take `nextKey` now. `nextStructure` is the part of the key that is not catalog revisions. */
	public function due(nextStructure:String, nextKey:String, now:Float):Bool {
		waiting = false;
		if (nextKey == key)
			return false;
		if (nextStructure == structure && now - last < THROTTLE) {
			waiting = true;
			return false;
		}
		return true;
	}

	/** The model took these inputs at `now`. */
	public function took(nextStructure:String, nextKey:String, now:Float):Void {
		structure = nextStructure;
		key = nextKey;
		last = now;
		waiting = false;
	}
}
