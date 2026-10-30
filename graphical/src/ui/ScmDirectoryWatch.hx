package ui;

import haxeon.platform.NativeKitError;
import haxeon.platform.event.EventPump;
import haxeon.platform.FileWatch;
import haxeon.platform.FileWatchEvent;
import scm.ScmService;

/**
	Bridges native worktree/Git metadata watches into the shared SCM service.

	Roots that watch the same directories with the same exclusions share one native watch: several workspace folders
	inside one repository all watch that repository, and one watch of it serves them all. A root's set differs from
	another's only when their repositories differ, so exclusions never cross from one repository to another.
**/
class ScmDirectoryWatch {
	final scm:ScmService;
	final events:EventPump;
	/** Shared watches by the directories and exclusions they cover (see signature). */
	final watches:Map<String, SharedScmWatch> = [];
	/** Each watched root's shared watch, by root key. */
	final rootWatches:Map<String, SharedScmWatch> = [];
	var disposed:Bool = false;
	public var lastError(default, null):Null<String>;

	public function new(scm:ScmService, events:EventPump) {
		this.scm = scm;
		this.events = events;
	}

	/**
		Watches `paths` for one project root, leaving out `excluded`. SCM relies on the watch only while every directory
		in it is registered; until then, and when a watch cannot be armed, it polls.
	**/
	public function update(root:String, paths:Array<String>, ?excluded:Array<String>):Void {
		if (disposed) return;
		lastError = null;
		var rootKey = FileWatch.pathKey(root), current = rootWatches.get(rootKey);
		if (paths == null || paths.length == 0) {
			if (current != null) detach(rootKey, root, current);
			return;
		}
		var selected = outermost(paths), exclusions = excluded == null ? [] : excluded;
		var key = signature(selected, exclusions);
		if (current != null && current.key == key) {
			syncAvailability(current);
			return;
		}
		if (current != null) detach(rootKey, root, current);
		var shared = watches.get(key);
		if (shared == null) {
			shared = new SharedScmWatch(key);
			try {
				var created = shared;
				shared.watch = FileWatch.create(events, event -> onEvent(created, event));
				for (path in exclusions) shared.watch.exclude(path);
				for (path in selected) shared.watch.add(path, true);
			} catch (error:NativeKitError) {
				lastError = error.message;
				if (shared.watch != null) shared.watch.dispose();
				scm.setWatchAvailable(root, false);
				return;
			}
			watches.set(key, shared);
		}
		shared.roots.set(rootKey, root);
		rootWatches.set(rootKey, shared);
		syncAvailability(shared);
	}

	public function isWatching(root:String):Bool {
		var shared = rootWatches.get(FileWatch.pathKey(root));
		return shared != null && !shared.watch.isDisposed() && shared.watch.directories().length > 0;
	}

	/** Native watches in use, for diagnostics: roots sharing one count once. */
	public function watchCount():Int
		return [for (_ in watches) 1].length;

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (shared in [for (value in watches) value]) close(shared);
		watches.clear();
		rootWatches.clear();
	}

	function onEvent(shared:SharedScmWatch, event:FileWatchEvent):Void {
		var roots = [for (root in shared.roots) root];
		switch event {
			case Changed(change): for (root in roots) scm.notifyChanged(root, false, null, change.path);
			case Overflow | Lost(_): for (root in roots) scm.notifyChanged(root, true);
			case Failed(error):
				lastError = "The SCM watch for " + roots.join(", ") + " stopped: " + error.message;
				close(shared);
				return;
			case Ready:
		}
		syncAvailability(shared);
	}

	function syncAvailability(shared:SharedScmWatch):Void {
		var available = !shared.watch.isDisposed() && shared.watch.directories().length > 0 && shared.watch.ready;
		for (root in shared.roots) scm.setWatchAvailable(root, available);
	}

	/** Stops `root` using its shared watch, closing the watch once no root uses it. */
	function detach(rootKey:String, root:String, shared:SharedScmWatch):Void {
		rootWatches.remove(rootKey);
		shared.roots.remove(rootKey);
		scm.setWatchAvailable(root, false);
		if (!shared.roots.keys().hasNext()) {
			watches.remove(shared.key);
			shared.watch.dispose();
		}
	}

	function close(shared:SharedScmWatch):Void {
		watches.remove(shared.key);
		shared.watch.dispose();
		for (rootKey => root in shared.roots) {
			rootWatches.remove(rootKey);
			scm.setWatchAvailable(root, false);
		}
		shared.roots.clear();
	}

	static function signature(paths:Array<String>, excluded:Array<String>):String {
		var pathKeys = [for (path in paths) FileWatch.pathKey(path)], excludedKeys = [for (path in excluded) FileWatch.pathKey(path)];
		var byText = (a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0;
		pathKeys.sort(byText);
		excludedKeys.sort(byText);
		return pathKeys.join("\n") + "\n--\n" + excludedKeys.join("\n");
	}

	/** The paths not under another one, so a directory already watched recursively is not walked again. */
	static function outermost(paths:Array<String>):Array<String> {
		var ordered = paths.copy(), selected:Array<String> = [];
		ordered.sort((a, b) -> FileWatch.pathKey(a).length - FileWatch.pathKey(b).length);
		for (path in ordered) {
			var covered = false;
			for (parent in selected) if (FileWatch.within(parent, path)) { covered = true; break; }
			if (!covered) selected.push(path);
		}
		return selected;
	}
}

private class SharedScmWatch {
	public final key:String;
	public var watch:FileWatch;
	/** The roots using this watch, by root key. */
	public final roots:Map<String, String> = [];

	public function new(key:String)
		this.key = key;
}
