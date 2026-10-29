package ui;

import scm.LocalScmSource;
import scm.ScmService;
import workspace.PathKey;

/**
	The local SCM sources behind an Agent session's controls (branch, commit, worktree, GitHub), one per session folder.
	Unlike the Source Control panel's source they never narrow to the Workbench selection: each covers the active
	context's folders and the session's own folder, so a session's controls describe its folder whichever group is
	selected, and stay the same source (a prompt opened for it stays valid) while the selection changes.
**/
class SessionScmSources {
	/** A source unused for this many seconds is disposed: its session closed or moved to another folder. Generous, so a
		prompt left open behind a hidden session keeps its source. */
	public static final IDLE_SECONDS:Float = 300;

	final caches:Map<String, LocalScmSourceCache> = [];
	final used:Map<String, Float> = [];

	public function new() {}

	/** The context's roots, plus `cwd` when none of them holds it. Paths are expected normalized. */
	public static function roots(contextRoots:Array<String>, cwd:String):Array<String> {
		var result = contextRoots.copy();
		if (cwd != null && cwd.length > 0 && !Lambda.exists(result, function(root) return PathKey.within(root, cwd))) result.push(cwd);
		return result;
	}

	/**
		The unnarrowed source for a session in `cwd`; `created` runs when a new source replaces the last one for that folder.
		`now` is in seconds; sources of other folders unused for IDLE_SECONDS are disposed.
	**/
	public function get(service:ScmService, contextRoots:Array<String>, cwd:String, now:Float,
			?created:LocalScmSource->Void):Null<LocalScmSource> {
		var folders = roots(contextRoots, cwd);
		var key = PathKey.of(cwd == null ? "" : cwd);
		// Mark this folder used first, so pruning never disposes the source about to be returned.
		if (caches.exists(key)) used.set(key, now);
		prune(now);
		if (folders.length == 0) { remove(key); return null; }
		var cache = caches.get(key);
		if (cache == null) { cache = new LocalScmSourceCache(); caches.set(key, cache); }
		used.set(key, now);
		return cache.get(service, folders, false, created);
	}

	/** The number of live session folders. */
	public function count():Int {
		var result = 0;
		for (_ in caches.keys()) result++;
		return result;
	}

	/** Disposes the sources not used since `now - IDLE_SECONDS`. */
	public function prune(now:Float):Void {
		var stale:Array<String> = [];
		for (key in used.keys()) {
			var at = used.get(key);
			if (at == null || now - at >= IDLE_SECONDS) stale.push(key);
		}
		for (key in stale) remove(key);
	}

	/** Disposes every source. */
	public function clear():Void {
		var keys = [for (key in caches.keys()) key];
		for (key in keys) remove(key);
	}

	function remove(key:String):Void {
		var cache = caches.get(key);
		if (cache != null) cache.clear();
		caches.remove(key);
		used.remove(key);
	}
}
