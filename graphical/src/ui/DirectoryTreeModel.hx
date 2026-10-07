package ui;

import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;
import sys.thread.Thread;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.TextWrap;
import haxeon.ui.widgets.Icon;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.core.View;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.MiddleEllipsisText;

/** Asynchronous, paged directory listings for the Explorer tree. */
class DirectoryTreeModel implements ExplorerTreeModel {
	static final PAGE_SIZE:Int = 256;
	static final MAX_PREFETCH:Int = 4;
	static final NoChangedPaths:Array<String> = [];
	static final LOADING_SUFFIX:String = ".exosuit-tree-loading";
	static final RETRY_SUFFIX:String = ".exosuit-tree-retry";
	static final MORE_SUFFIX:String = ".exosuit-tree-more";
	final root:String;
	final theme:Theme;
	final queueLock:Mutex = new Mutex();
	final jobs:Array<DirectoryLoadJob> = [];
	final prefetchJobs:Array<DirectoryLoadJob> = [];
	var completed:Array<DirectoryLoadResult> = [];
	var workerCount:Int = 0;
	var prefetchWorkerRunning:Bool = false;
	var activePrefetch:Map<String, Int> = [];
	var boostedPrefetch:Map<String, Int> = [];
	var priorityClicks:Map<String, Float> = [];
	var visitedPaths:Array<String> = [];
	var expandedDirectories:Map<String, Bool> = [];
	var generation:Int = 0;
	var requestSequence:Int = 0;
	var listRevision:Int = 0;
	var listings:Map<String, DirectoryListing> = [];
	var errors:Map<String, Bool> = [];
	var pending:Map<String, Int> = [];
	var prefetching:Map<String, Bool> = [];
	var pageSizes:Map<String, Int> = [];
	var refreshCursor:Int = 0;
	public var watchChanges:Bool = false;
	public var observeDirectory:Null<String->Void>;
	var changesPending:Bool = true;

	public function markChanged():Void changesPending = true;

	public function visitedDirectories():Array<String> {
		return [for (path in visitedPaths) if (listings.exists(path)) path];
	}

	public function new(root:String, theme:Theme) {
		this.root = root;
		this.theme = theme;
		expandedDirectories.set(root, true);
	}

	public function setDirectoryExpanded(path:String, expanded:Bool):Void {
		if (expanded) expandedDirectories.set(path, true);
		else expandedDirectories.remove(path);
	}

	public function rootCount():Int return 1;
	public function rootIdentity():String return root;
	public function watchesChanges():Bool return watchChanges;
	public function dispose():Void invalidate();

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return start > 0 || count <= 0 ? [] : [new TreeRootMetadata(root, true)];

	public function rootKeyAt(index:Int):String return root;

	/** Fast hint used to draw expand arrows without starting background I/O. */
	public function hasChildrenHint(key:String):Bool {
		if (isSyntheticRow(key)) return false;
		if (listings.exists(key)) return listings.get(key).names.length > 0;
		if (!isKnownDirectory(key)) return false;
		if (!pending.exists(key) && !errors.exists(key) && prefetchingCount() < MAX_PREFETCH) {
			prefetching.set(key, true);
			requestLoad(key, false);
		}
		return true;
	}

	public function childCount(parentKey:String):Int {
		if (isSyntheticRow(parentKey)) return 0;
		if (!isKnownDirectory(parentKey)) return 0;
		if (!listings.exists(parentKey)) {
			if (!errors.exists(parentKey)) requestLoad(parentKey);
			return 1;
		}
		var names = listings.get(parentKey).names;
		var pageSize = pageSizes.exists(parentKey) ? pageSizes.get(parentKey) : PAGE_SIZE;
		return Std.int(Math.min(names.length, pageSize)) + (names.length > pageSize ? 1 : 0);
	}

	public function childKeyAt(parentKey:String, index:Int):String {
		if (isSyntheticRow(parentKey) || index < 0) return "";
		if (!listings.exists(parentKey)) {
			if (index != 0) return "";
			if (pending.exists(parentKey)) return syntheticKey(parentKey, LOADING_SUFFIX);
			if (errors.exists(parentKey)) return syntheticKey(parentKey, RETRY_SUFFIX);
			requestLoad(parentKey);
			return syntheticKey(parentKey, LOADING_SUFFIX);
		}
		var names = listings.get(parentKey).names;
		var pageSize = pageSizes.exists(parentKey) ? pageSizes.get(parentKey) : PAGE_SIZE;
		var shown = Std.int(Math.min(names.length, pageSize));
		if (index < shown) return parentKey + "/" + names[index];
		if (names.length > shown && index == shown) return syntheticKey(parentKey, MORE_SUFFIX);
		return "";
	}

	public function initiallyExpanded(key:String):Bool return key == root;

	public function estimatedExtent():Float return 26.0;

	public function extentIsUniform():Bool return true;

	public function extentAt(key:String):Float return 26.0;

	public function buildItem(key:String):View
		return new MiddleEllipsisText("filename", rowLabel(key), false,
			new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.text));

	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View {
		if (isSyntheticRow(key))
			return new MiddleEllipsisText("filename", rowLabel(key), false,
				new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.textSecondary));
		var name = baseName(key), directory = isKnownDirectory(key);
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(26.0);
		style.clipHorizontal = true;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 6.0;
		var icon:View = directory
			? new Icon("folder-icon", expanded ? IconName.FolderOpen : IconName.FolderClosed, 20.0, theme.tokens.textSecondary)
			: new SetiFileIcon(atlas, name, dark);
		return new Row("explorer-item", [
			new KeyedView("icon", icon),
			new KeyedView("name", new MiddleEllipsisText("filename", name, false,
				new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.text)))
		], style);
	}

	public function revision():Int return listRevision;

	public function isDirectoryPath(path:String):Bool
		return !isSyntheticRow(path) && isKnownDirectory(path);

	public function isSyntheticRow(path:String):Bool
		return path != root && (StringTools.endsWith(path, "/" + LOADING_SUFFIX) ||
			StringTools.endsWith(path, "/" + RETRY_SUFFIX) || StringTools.endsWith(path, "/" + MORE_SUFFIX));

	/** Handles retry and paging rows. Returns true when the visible tree changed. */
	public function activateSyntheticRow(key:String):Bool {
		if (StringTools.endsWith(key, "/" + MORE_SUFFIX)) {
			var directory = syntheticParent(key, MORE_SUFFIX);
			if (!listings.exists(directory)) return false;
			var names = listings.get(directory).names;
			var oldSize = pageSizes.exists(directory) ? pageSizes.get(directory) : PAGE_SIZE;
			if (oldSize >= names.length) return false;
			pageSizes.set(directory, Std.int(Math.min(names.length, oldSize + PAGE_SIZE)));
			listRevision++;
			return true;
		}
		if (StringTools.endsWith(key, "/" + RETRY_SUFFIX)) {
			var directory = syntheticParent(key, RETRY_SUFFIX);
			if (pending.exists(directory)) return false;
			requestLoad(directory);
			return true;
		}
		return false;
	}

	/** Applies completed worker results on the UI thread. */
	public function pollLoads():Array<String> {
		var results:Array<DirectoryLoadResult>;
		queueLock.acquire();
		if (completed.length == 0) {
			queueLock.release();
			return NoChangedPaths;
		}
		results = completed;
		completed = [];
		queueLock.release();

		var changedPaths:Array<String> = [];
		var changedSet:Map<String, Bool> = [];
		function markVisibleChanged(path:String):Void {
			if (!changedSet.exists(path)) {
				changedSet.set(path, true);
				changedPaths.push(path);
			}
		}
		for (result in results) {
			if (result.generation != generation) continue;
			if (!pending.exists(result.path) || pending.get(result.path) != result.requestId) continue;
			var priorityAt = priorityClicks.get(result.path);
			if (priorityAt != null) recordLoadTiming(result, priorityAt);
			priorityClicks.remove(result.path);
			boostedPrefetch.remove(result.path);
			pending.remove(result.path);
			prefetching.remove(result.path);

			var affectsVisibleTree = isVisibleExpandedPath(result.path);
			if (result.failed) {
				var wasFailed = errors.exists(result.path);
				errors.set(result.path, true);
				if (affectsVisibleTree && (!listings.exists(result.path) || !wasFailed))
					markVisibleChanged(result.path);
				continue;
			}

			var hadListing = listings.exists(result.path);
			var previous = hadListing ? listings.get(result.path) : null;
			if (errors.exists(result.path)) {
				errors.remove(result.path);
				if (affectsVisibleTree) markVisibleChanged(result.path);
			}
			if (!result.unchanged || !hadListing) {
				if (result.invalidated.length > 0) prunePaths(result.invalidated);
				if (!hadListing) visitedPaths.push(result.path);
				listings.set(result.path, {names: result.names, kinds: result.kinds});
				if (affectsVisibleTree) markVisibleChanged(result.path);
			}
			if (observeDirectory != null) observeDirectory(result.path);
		}
		if (changedPaths.length > 0) listRevision++;
		return changedPaths;
	}

	/**
	 * Refresh changed listings on watch events. Without watches, scan one visited
	 * directory per polling interval so a large workspace cannot monopolize a frame.
	 */
	public function refresh():Void {
		if (watchChanges && !changesPending) return;
		if (changesPending) {
			changesPending = false;
			for (directory in visitedDirectories()) requestLoad(directory, false);
			return;
		}
		if (watchChanges) return;
		var remaining = visitedPaths.length;
		while (remaining-- > 0) {
			if (refreshCursor >= visitedPaths.length) refreshCursor = 0;
			var directory = visitedPaths[refreshCursor++];
			if (listings.exists(directory)) {
				requestLoad(directory, false);
				return;
			}
		}
	}

	public function refreshDirectory(path:String):Void {
		if (listings.exists(path) || path == root) requestLoad(path, false);
	}

	/** Invalidates cached listings after the root/workspace changes. */
	public function invalidate():Void {
		generation++;
		listings.clear();
		visitedPaths = [];
		expandedDirectories.clear();
		expandedDirectories.set(root, true);
		errors.clear();
		pending.clear();
		prefetching.clear();
		priorityClicks.clear();
		boostedPrefetch.clear();
		pageSizes.clear();
		refreshCursor = 0;
		changesPending = true;
		queueLock.acquire();
		jobs.resize(0);
		prefetchJobs.resize(0);
		queueLock.release();
		listRevision++;
	}

	function requestLoad(path:String, priority:Bool = true):Void {
		var startWorkers = 0;
		var startPrefetchWorker = false;
		queueLock.acquire();
		if (pending.exists(path)) {
			if (priority) {
				var now = Sys.time();
				priorityClicks.set(path, now);
				prefetching.remove(path);
				var promoted = false;
				for (index in 0...prefetchJobs.length) {
					var queued = prefetchJobs[index];
					if (queued.path == path && queued.generation == generation) {
						prefetchJobs.splice(index, 1);
						queued.priority = true;
						queued.queuedAt = now;
						jobs.push(queued);
						promoted = true;
						if (workerCount < 2) {
							workerCount++;
							startWorkers++;
						}
						break;
					}
				}
				// If the single prefetch worker is already reading this path, let a
				// priority worker race it so a user click is not held behind I/O.
				if (!promoted && activePrefetch.get(path) == pending.get(path) &&
					boostedPrefetch.get(path) != pending.get(path)) {
					var requestId:Int = cast pending.get(path);
					boostedPrefetch.set(path, requestId);
					jobs.push({path: path, generation: generation, requestId: requestId,
						priority: true, queuedAt: now, previous: listings.get(path)});
					if (workerCount < 2) {
						workerCount++;
						startWorkers++;
					}
				}
			}
		} else {
			requestSequence++;
			var requestId = requestSequence;
			pending.set(path, requestId);
			if (priority) priorityClicks.set(path, Sys.time()); else priorityClicks.remove(path);
			var job:DirectoryLoadJob = {path: path, generation: generation, requestId: requestId,
				priority: priority, queuedAt: Sys.time(), previous: listings.get(path)};
			if (priority) {
				jobs.push(job);
				if (workerCount < 2) {
					workerCount++;
					startWorkers++;
				}
			} else {
				prefetchJobs.push(job);
				if (!prefetchWorkerRunning) {
					prefetchWorkerRunning = true;
					startPrefetchWorker = true;
				}
			}
		}
		queueLock.release();
		if (startWorkers > 0) startPriorityWorkers(startWorkers);
		if (startPrefetchWorker) startPrefetchWorkerThread();
	}

	function startPriorityWorkers(count:Int):Void {
		for (_ in 0...count) {
			try Thread.create(workerLoop) catch (_:Dynamic) {
				queueLock.acquire();
				workerCount--;
				if (workerCount == 0) failQueued(jobs);
				queueLock.release();
			}
		}
	}

	function startPrefetchWorkerThread():Void {
		try Thread.create(prefetchWorkerLoop) catch (_:Dynamic) {
			queueLock.acquire();
			prefetchWorkerRunning = false;
			failQueued(prefetchJobs);
			queueLock.release();
		}
	}

	function failQueued(queue:Array<DirectoryLoadJob>):Void {
		while (queue.length > 0) {
			var job = queue.shift();
			completed.push({path: job.path, generation: job.generation, requestId: job.requestId,
				names: [], kinds: [], unchanged: false, invalidated: [], failed: true,
				queuedAt: job.queuedAt, startedAt: 0, finishedAt: Sys.time()});
		}
	}

	function prefetchingCount():Int {
		var count = 0;
		for (_ in prefetching.keys()) count++;
		return count;
	}

	function workerLoop():Void {
		while (true) {
			var job:DirectoryLoadJob = null;
			queueLock.acquire();
			if (jobs.length == 0) {
				workerCount--;
				queueLock.release();
				return;
			}
			job = jobs.shift();
			queueLock.release();
			var result = loadJob(job);
			queueLock.acquire();
			completed.push(result);
			queueLock.release();
		}
	}

	function prefetchWorkerLoop():Void {
		while (true) {
			var job:DirectoryLoadJob = null;
			queueLock.acquire();
			if (prefetchJobs.length == 0) {
				prefetchWorkerRunning = false;
				queueLock.release();
				return;
			}
			job = prefetchJobs.shift();
			activePrefetch.set(job.path, job.requestId);
			queueLock.release();
			var result = loadJob(job);
			queueLock.acquire();
			if (activePrefetch.get(job.path) == job.requestId) activePrefetch.remove(job.path);
			completed.push(result);
			queueLock.release();
		}
	}

	function loadJob(job:DirectoryLoadJob):DirectoryLoadResult {
		var startedAt = Sys.time();
		var result = enumerate(job.path, job.previous);
		result.generation = job.generation;
		result.requestId = job.requestId;
		result.queuedAt = job.queuedAt;
		result.startedAt = startedAt;
		result.finishedAt = Sys.time();
		return result;
	}

	function recordLoadTiming(result:DirectoryLoadResult, priorityAt:Float):Void {
		var tracePath = Sys.getEnv("EXOSUIT_TREE_TRACE");
		if (tracePath == null || tracePath.length == 0 || result.startedAt <= 0 || result.finishedAt <= 0) return;
		var now = Sys.time();
		var queueMs = Std.int(Math.max(0, (result.startedAt - result.queuedAt) * 1000));
		var readMs = Std.int(Math.max(0, (result.finishedAt - result.startedAt) * 1000));
		var clickMs = Std.int(Math.max(0, (now - priorityAt) * 1000));
		try File.appendContent(tracePath,
			'click=${clickMs}ms queue=${queueMs}ms read+sort=${readMs}ms entries=${result.names.length} path=${result.path}\n') catch (_:Dynamic) {}
	}

	static function enumerate(directory:String, previous:Null<DirectoryListing>):DirectoryLoadResult {
		var names:Array<String> = [];
		var kinds:Map<String, Bool> = [];
		try {
			// readDirectoryEntries validates the path while enumerating it. Avoid
			// separate exists/isDirectory queries, which can each block on redirected
			// or network folders before enumeration even starts.
			var rawEntries = FileSystem.readDirectoryEntries(directory);
			var directories:Array<String> = [], files:Array<String> = [];
			for (entry in rawEntries) {
				var name = entry.name;
				if (StringTools.startsWith(name, ".")) continue;
				var path = directory + "/" + name;
				var isDirectory = entry.isDirectory;
				kinds.set(path, isDirectory);
				if (isDirectory) directories.push(name); else files.push(name);
			}
			directories.sort(Reflect.compare);
			files.sort(Reflect.compare);
			names = directories.concat(files);
		} catch (_:Dynamic) {
			return {path: directory, generation: 0, requestId: 0, names: [], kinds: [],
				unchanged: false, invalidated: [], failed: true,
				queuedAt: 0, startedAt: 0, finishedAt: 0};
		}
		return makeResult(directory, names, kinds, previous, false);
	}

	static function makeResult(path:String, names:Array<String>, kinds:Map<String, Bool>,
			previous:Null<DirectoryListing>, failed:Bool):DirectoryLoadResult {
		var unchanged = previous != null && sameNames(previous.names, names) && sameKinds(previous.kinds, kinds);
		var invalidated:Array<String> = [];
		if (previous != null) for (childPath in previous.kinds.keys())
			if (!kinds.exists(childPath) || kinds.get(childPath) != previous.kinds.get(childPath)) invalidated.push(childPath);
		return {path: path, generation: 0, requestId: 0, names: names, kinds: kinds,
			unchanged: unchanged, invalidated: invalidated, failed: failed,
			queuedAt: 0, startedAt: 0, finishedAt: 0};
	}

	function isKnownDirectory(path:String):Bool {
		if (path == root) return true;
		var slash = path.lastIndexOf("/");
		if (slash < 0) return false;
		var parent = path.substring(0, slash);
		var listing = listings.get(parent);
		return listing != null && listing.kinds.exists(path) && listing.kinds.get(path);
	}

	function isVisibleExpandedPath(path:String):Bool {
		if (path == root) return true;
		var current = path;
		while (current != root) {
			if (!expandedDirectories.exists(current)) return false;
			var slash = current.lastIndexOf("/");
			if (slash < root.length) return false;
			current = current.substring(0, slash);
		}
		return true;
	}

	function prunePaths(paths:Array<String>):Void {
		if (paths.length == 0) return;
		function underInvalidatedPath(candidate:String):Bool {
			for (path in paths)
				if (candidate == path || StringTools.startsWith(candidate, path + "/")) return true;
			return false;
		}
		for (path in [for (path in listings.keys()) if (underInvalidatedPath(path)) path]) listings.remove(path);
		for (path in [for (path in errors.keys()) if (underInvalidatedPath(path)) path]) errors.remove(path);
		for (path in [for (path in expandedDirectories.keys()) if (underInvalidatedPath(path)) path]) expandedDirectories.remove(path);
		for (path in [for (path in pageSizes.keys()) if (underInvalidatedPath(path)) path]) pageSizes.remove(path);
		for (path in [for (path in pending.keys()) if (underInvalidatedPath(path)) path]) pending.remove(path);
		for (path in [for (path in prefetching.keys()) if (underInvalidatedPath(path)) path]) prefetching.remove(path);
		visitedPaths = [for (path in visitedPaths) if (listings.exists(path)) path];
		if (refreshCursor >= visitedPaths.length) refreshCursor = 0;
	}

	static function sameNames(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length) return false;
		for (index in 0...left.length) if (left[index] != right[index]) return false;
		return true;
	}

	static function sameKinds(left:Map<String, Bool>, right:Map<String, Bool>):Bool {
		for (path => isDirectory in left)
			if (!right.exists(path) || right.get(path) != isDirectory) return false;
		for (path in right.keys()) if (!left.exists(path)) return false;
		return true;
	}

	function rowLabel(key:String):String {
		if (isSyntheticRow(key) && StringTools.endsWith(key, "/" + LOADING_SUFFIX)) return "Loading folder…";
		if (isSyntheticRow(key) && StringTools.endsWith(key, "/" + RETRY_SUFFIX)) return "Could not load folder — click to retry";
		if (isSyntheticRow(key) && StringTools.endsWith(key, "/" + MORE_SUFFIX)) {
			var directory = syntheticParent(key, MORE_SUFFIX);
			var total = listings.exists(directory) ? listings.get(directory).names.length : 0;
			var shown = pageSizes.exists(directory) ? pageSizes.get(directory) : PAGE_SIZE;
			return 'Load ${Std.int(Math.min(PAGE_SIZE, total - shown))} more…';
		}
		return baseName(key);
	}

	static function syntheticKey(parent:String, suffix:String):String return parent + "/" + suffix;

	static function syntheticParent(key:String, suffix:String):String
		return key.substring(0, key.length - suffix.length - 1);

	static function baseName(path:String):String {
		var slash = path.lastIndexOf("/");
		return slash < 0 ? path : path.substring(slash + 1);
	}
}

private typedef DirectoryLoadJob = {
	var path:String;
	var generation:Int;
	var requestId:Int;
	var priority:Bool;
	var queuedAt:Float;
	var previous:Null<DirectoryListing>;
}

private typedef DirectoryLoadResult = {
	var path:String;
	var generation:Int;
	var requestId:Int;
	var names:Array<String>;
	var kinds:Map<String, Bool>;
	var unchanged:Bool;
	var invalidated:Array<String>;
	var failed:Bool;
	var queuedAt:Float;
	var startedAt:Float;
	var finishedAt:Float;
}

private typedef DirectoryListing = {
	var names:Array<String>;
	var kinds:Map<String, Bool>;
}
