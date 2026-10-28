package ui;

import scm.LocalScmSource;
import scm.ScmService;

/** One local SCM source over a set of folders, replaced when the folders or the narrowing change. */
class LocalScmSourceCache {
	var source:Null<LocalScmSource>;
	var rootsKey:Null<String>;
	var identity:String = "";

	public function new() {}

	/**
		The source for `roots` (the first one is its root); `created` runs when a new source replaces the last one. Null,
		with the last source disposed, when there are no roots.
	**/
	public function get(service:ScmService, roots:Array<String>, narrowToFolders:Bool, ?created:LocalScmSource->Void):Null<LocalScmSource> {
		if (roots.length == 0) { clear(); rootsKey = null; return null; }
		var key = haxe.Json.stringify(roots) + (narrowToFolders ? ":narrow" : "");
		if (rootsKey != key) { rootsKey = key; identity = LocalScmSource.identityFor(roots, narrowToFolders); }
		var current = source;
		if (current != null && current.identity() == identity) return current;
		clear();
		var next = new LocalScmSource(service, roots[0], roots, narrowToFolders);
		source = next;
		if (created != null) created(next);
		return next;
	}

	/** Disposes the source; false when there was none. */
	public function clear():Bool {
		var current = source;
		if (current == null) return false;
		current.dispose();
		source = null;
		return true;
	}
}
