package ui;

import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitFileWatch;
import scm.ScmService;

/** Bridges native worktree/Git metadata watches into the shared SCM service. */
class ScmDirectoryWatch {
	final scm:ScmService;
	final events:NativeKitEvents;
	final states:Map<String, ScmWatchState> = [];
	var disposed:Bool = false;
	public var lastError(default, null):Null<String>;

	public function new(scm:ScmService, events:NativeKitEvents) {
		this.scm = scm;
		this.events = events;
	}

	/**
		Watches `paths` for one project root, leaving out `excluded`, by changing the root's watch rather than replacing
		it. SCM relies on the watch only while every directory in it is registered; until then, and when a watch cannot
		be armed, it polls.
	**/
	public function update(root:String, paths:Array<String>, ?excluded:Array<String>):Void {
		if (disposed) return;
		lastError = null;
		var key = NativeKitFileWatch.pathKey(root), state = states.get(key);
		var exclusions = excluded == null ? [] : excluded;
		if (paths == null || paths.length == 0) {
			if (state != null) disposeState(state);
			return;
		}
		var selected = outermost(paths);
		// A lifted exclusion means a subtree to watch again: start over rather than track which ones.
		if (state != null)
			for (path in state.watch.exclusions())
				if (!containsPath(exclusions, path)) {
					disposeState(state);
					state = null;
					break;
				}
		try {
			if (state == null) state = createState(key, root);
			var watch = state.watch;
			for (path in exclusions) watch.exclude(path);
			for (path in watch.directories()) if (!containsPath(selected, path)) watch.remove(path);
			for (path in selected) watch.add(path, true);
		} catch (error:NativeKitError) {
			lastError = error.message;
			if (state != null) disposeState(state);
			return;
		}
		syncAvailability(state);
	}

	public function isWatching(root:String):Bool {
		var state = states.get(NativeKitFileWatch.pathKey(root));
		return state != null && !state.watch.isDisposed() && state.watch.directories().length > 0;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (state in [for (value in states) value]) disposeState(state);
		states.clear();
	}

	function createState(key:String, root:String):ScmWatchState {
		var state = new ScmWatchState(key, root);
		state.watch = NativeKitFileWatch.create(events, event -> onEvent(state, event));
		states.set(key, state);
		return state;
	}

	function onEvent(state:ScmWatchState, event:FileWatchEvent):Void {
		switch event {
			case Changed(change): scm.notifyChanged(state.root, false, null, change.path);
			case Overflow | Lost(_): scm.notifyChanged(state.root, true);
			case Failed(error):
				lastError = "The SCM watch for " + state.root + " stopped: " + error.message;
				disposeState(state);
				return;
			case Ready:
		}
		syncAvailability(state);
	}

	function syncAvailability(state:ScmWatchState):Void
		scm.setWatchAvailable(state.root, isWatching(state.root) && state.watch.ready);

	function disposeState(state:ScmWatchState):Void {
		if (states.get(state.key) == state) states.remove(state.key);
		state.watch.dispose();
		scm.setWatchAvailable(state.root, false);
	}

	/** The paths not under another one, so a directory already watched recursively is not walked again. */
	static function outermost(paths:Array<String>):Array<String> {
		var ordered = paths.copy(), selected:Array<String> = [];
		ordered.sort((a, b) -> NativeKitFileWatch.pathKey(a).length - NativeKitFileWatch.pathKey(b).length);
		for (path in ordered) {
			var covered = false;
			for (parent in selected) if (NativeKitFileWatch.within(parent, path)) { covered = true; break; }
			if (!covered) selected.push(path);
		}
		return selected;
	}

	static function containsPath(paths:Array<String>, path:String):Bool {
		var key = NativeKitFileWatch.pathKey(path);
		for (candidate in paths) if (NativeKitFileWatch.pathKey(candidate) == key) return true;
		return false;
	}
}

private class ScmWatchState {
	public final key:String;
	public final root:String;
	public var watch:NativeKitFileWatch;

	public function new(key:String, root:String) {
		this.key = key;
		this.root = root;
	}
}
