package ui;

import haxeon.ui.widgets.collections.TreeView;

/**
	The Workbench's selection and scrolling that wait for a row instead of throwing. TreeView throws "selection key is
	not visible" for a row it does not (yet) show, as happens after a live reload rebuilt the tree: raised from a layout
	or event callback, that ended the window. A false answer means the row is not there; the caller keeps its wish and
	tries again at the next frame.
**/
class WorkbenchTreeSafe {
	public static function select(tree:TreeView, key:Null<String>, notify:Bool = true):Bool {
		try {
			tree.select(key, notify);
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	public static function scrollTo(tree:TreeView, key:String):Bool {
		try {
			tree.scrollTo(key);
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
