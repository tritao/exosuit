package ui;

import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol.FileListPage;
import workspace.service.WorkspaceFileProtocol.FileWatchResult;
import workspace.service.WorkspaceFileProtocol.FileChangeEvent;
import workspace.service.WorkspaceFileProtocol.WorkspaceFileEntry;

private class WorkspaceDirectoryListing {
	public var entries:Array<WorkspaceFileEntry> = [];
	public var unsupportedCount:Int = 0;
	public var cursor:Null<String>;
	public var loading:Bool = false;
	public var loaded:Bool = false;
	public var stale:Bool = false;
	public var refreshing:Bool = false;
	public var error:Null<String>;
	public var limited:Bool = false;
}

/** Lazy, paged tree projection over the negotiated workspace.files.read RPC. */
class WorkspaceFileTreeModel implements ExplorerTreeModel {
	static inline final FILE_PREFIX = "workspace-file:";
	static inline final SPECIAL_PREFIX = "workspace-file-special:";
	static inline final PAGE_SIZE = 32;
	static inline final MAX_CACHED_ENTRIES = 32768;
	static inline final MAX_LISTED_DIRECTORIES = 256;

	final clientProvider:Void->Null<WorkspaceFileClient>;
	final workspace:String;
	final scope:String;
	final theme:Theme;
	public var fontSize(default, set):Float = 15.0;

	function set_fontSize(value:Float):Float {
		value = Math.max(6.0, Math.min(96.0, value));
		if (fontSize != value) {
			fontSize = value;
			revisionValue++;
		}
		return fontSize;
	}

	function rowHeight():Float return Math.max(26.0, Math.ceil(fontSize * 1.4 + 4.0));

	final changed:Void->Void;
	final fileChanged:Null<String->Void>;
	final watchListener:FileChangeEvent->Void;
	final listings:Map<String, WorkspaceDirectoryListing> = [];
	final kinds:Map<String, String> = [];
	final names:Map<String, String> = [];
	final specialPaths:Map<String, String> = [];
	final specialLabels:Map<String, String> = [];
	final initialRootName:String;
	var activeClient:Null<WorkspaceFileClient>;
	var connectionResetPending:Bool = false;
	var generation:Int = 0;
	var disposed:Bool = false;
	var revisionValue:Int = 0;
	var rootsRequested:Bool = false;
	var rootsLoaded:Bool = false;
	var rootName:String;
	var rootError:Null<String>;
	var rootsRetryAt:Float = 0.0;
	var rootSupportsWatch:Bool = false;
	var watchRequested:Bool = false;
	var watchingChanges:Bool = false;
	var watchRetryAt:Float = 0.0;
	var watchEpoch:Null<String>;
	var watchCursor:Int = 0;

	public function watchesChanges():Bool return watchingChanges;

	public function new(clientProvider:Void->Null<WorkspaceFileClient>, workspace:String, scope:String,
			fallbackRootName:String, theme:Theme, changed:Void->Void, ?fileChanged:String->Void) {
		if (clientProvider == null || workspace == null || workspace.length == 0 || scope == null || theme == null || changed == null)
			throw "Invalid workspace file tree configuration";
		this.clientProvider = clientProvider;
		this.workspace = workspace;
		this.scope = scope;
		this.initialRootName = fallbackRootName == null || fallbackRootName.length == 0 ? "Workspace" : fallbackRootName;
		this.rootName = initialRootName;
		this.theme = theme;
		this.changed = changed;
		this.fileChanged = fileChanged;
		this.watchListener = function(event) handleFileChange(event);
		kinds.set(rootKey(), "directory");
		names.set(rootKey(), rootName);
	}

	public function rootIdentity():String return workspace + ":" + scope;
	public function rootCount():Int return 1;
	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return start > 0 || count <= 0 ? [] : [new TreeRootMetadata(rootKey(), true)];
	public function rootKeyAt(index:Int):String return index == 0 ? rootKey() : "";
	public function initiallyExpanded(key:String):Bool return key == rootKey();
	public function estimatedExtent():Float return 20.0;
	public function extentIsUniform():Bool return true;
	public function extentAt(key:String):Float return 20.0;
	public function revision():Int return revisionValue;

	public function refresh():Void {
		if (disposed) return;
		var client = clientProvider();
		if (client == null) {
			if (activeClient != null) {
				activeClient.unwatch(workspace, rootId(), watchListener);
				activeClient = null;
				generation++;
				watchRequested = false;
				watchingChanges = false;
				connectionResetPending = true;
			}
			return;
		}
		if (client != activeClient) {
			if (activeClient != null) activeClient.unwatch(workspace, rootId(), watchListener);
			var hadState = rootsRequested || rootsLoaded;
			if (!hadState) for (_ in listings.keys()) { hadState = true; break; }
			activeClient = client;
			if (connectionResetPending || hadState) resetForConnection();
			connectionResetPending = false;
			revisionValue++;
			changed();
		}
		if (!rootsRequested && rootError == null)
			requestRoots();
		if (rootsLoaded && rootSupportsWatch && !watchRequested && !watchingChanges && Sys.time() >= watchRetryAt)
			requestWatch();
		// Bound background work, including changes accumulated while Files was hidden.
		if (rootsLoaded) {
			var pending = 0;
			for (listing in listings) if (listing.loading || listing.refreshing) pending++;
			for (path => listing in listings) {
				if (pending >= 4) break;
				if (listing.stale && listing.error == null && !listing.limited && !listing.loading && !listing.refreshing) {
					requestPage(path, null);
					pending++;
				}
			}
		}
	}

	public function refreshAll():Void {
		if (disposed) return;
		rootError = null;
		invalidateListings();
		refresh();
	}

	public function dispose():Void {
		disposed = true;
		generation++;
		if (activeClient != null) activeClient.unwatch(workspace, rootId(), watchListener);
		activeClient = null;
		watchRequested = false;
		watchingChanges = false;
	}

	public function childCount(parentKey:String):Int {
		var special = specialLabels.get(parentKey);
		if (special != null) return 0;
		if (!isDirectory(parentKey)) return 0;
		var path = pathForKey(parentKey);
		var listing = listings.get(path);
		if (listing == null) return 1;
		var count = listing.entries.length;
		if (listing.unsupportedCount > 0) count++;
		if (parentKey == rootKey() && !rootsLoaded && rootError != null) return count + 1;
		if (listing.error != null) return count + 1;
		if (listing.cursor != null) return count + 1;
		if (listing.loading && !listing.loaded) return count + 1;
		return count;
	}

	public function childKeyAt(parentKey:String, index:Int):String {
		if (index < 0 || !isDirectory(parentKey)) return "";
		if (!rootsLoaded && listings.get(pathForKey(parentKey)) == null) {
			if (rootError != null)
				return index == 0 ? specialKey("retry-roots", "", "Could not connect — retry") : "";
			requestRoots();
			return specialKey("loading-roots", "", "Loading workspace…");
		}
		var path = pathForKey(parentKey);
		var listing = listings.get(path);
		if (listing == null) {
			requestPage(path, null);
			listing = listings.get(path);
			if (listing == null || listing.loading) return specialKey("loading", path, "Loading folder…");
		}
		if (index < listing.entries.length) {
			var entry = listing.entries[index];
			if (entry.name == null || entry.nameUnsupported) return "";
			var childPath = path.length == 0 ? entry.name : path + "/" + entry.name;
			var key = fileKey(childPath);
			kinds.set(key, entry.kind);
			names.set(key, entry.name);
			return key;
		}
		if (listing.unsupportedCount > 0 && index == listing.entries.length)
			return specialKey("unsupported", path,
				listing.unsupportedCount + (listing.unsupportedCount == 1 ? " file name cannot" : " file names cannot") + " be represented here");
		var syntheticIndex = listing.entries.length + (listing.unsupportedCount > 0 ? 1 : 0);
		if (parentKey == rootKey() && !rootsLoaded && rootError != null && index == syntheticIndex)
			return specialKey("retry-roots", "", "Could not connect — retry");
		if (listing.error != null && index == syntheticIndex)
			return specialKey(listing.limited ? "limit" : "retry", path,
				listing.limited ? listing.error : "Could not load folder — retry");
		if (listing.cursor != null && index == syntheticIndex)
			return specialKey("more", path, "Load more…");
		if (listing.loading && !listing.loaded && index == syntheticIndex)
			return specialKey("loading", path, "Loading folder…");
		return "";
	}

	public function buildItem(key:String):View
		return new Text(displayName(key), null, theme.tokens.text, TextStyleOverride.text(fontSize));

	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View {
		var special = specialLabels.get(key);
		if (special != null)
			return new Text(special, null, theme.tokens.textSecondary, TextStyleOverride.text(fontSize));
		var label = displayName(key), directory = isDirectory(key);
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(20.0);
		style.clipHorizontal = true;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 2.0;
		var children:Array<KeyedView> = [];
		if (!directory) children.push(new KeyedView("icon", new SetiFileIcon(atlas, label, dark, true)));
		children.push(new KeyedView("name", new MiddleEllipsisText("filename", label, false,
				new TextStyleOverride(null, fontSize, null, TextWrap.None, null, null, null, theme.tokens.text))
		));
		return new Row("workspace-file-item", children, style);
	}

	public function isDirectoryKey(key:String):Bool return isDirectory(key);
	public function isMoreKey(key:String):Bool return specialKind(key) == "more";
	public function isRetryKey(key:String):Bool return specialKind(key) == "retry" || specialKind(key) == "retry-roots";
	public function activateSpecial(key:String):Void {
		var kind = specialKind(key), path = specialPaths.get(key);
		if (path == null) path = "";
		if (kind == "more") {
			var listing = listings.get(path);
			if (listing != null && listing.cursor != null && !listing.loading && !listing.refreshing && !listing.stale) requestPage(path, listing.cursor);
		} else if (kind == "retry") {
			var listing = listings.get(path);
			if (listing != null && !listing.loading && !listing.refreshing)
				requestPage(path, listing.stale ? null : listing.cursor);
		} else if (kind == "loading-roots") {
			requestRoots();
		} else if (kind == "retry-roots" && Sys.time() >= rootsRetryAt) {
			rootError = null;
			requestRoots();
		}
	}

	public function relativePath(key:String):Null<String>
		return StringTools.startsWith(key, FILE_PREFIX) ? key.substring(FILE_PREFIX.length) : null;

	public function entryForKey(key:String):Null<WorkspaceFileEntry> {
		var path = relativePath(key);
		if (path == null || path.length == 0) return null;
		var slash = path.lastIndexOf("/");
		var parent = slash < 0 ? "" : path.substring(0, slash);
		var leaf = slash < 0 ? path : path.substring(slash + 1);
		var listing = listings.get(parent);
		if (listing == null) return null;
		for (entry in listing.entries) if (entry.name == leaf) return entry;
		return null;
	}

	public function rootId():String return "root";
	public function workspaceId():String return workspace;
	public function scopeId():String return scope;
	public function rootDisplayName():String return rootName;
	public function keyForPath(path:String):String return FILE_PREFIX + (path == null ? "" : path);

	function requestRoots():Void {
		var client = activeClient;
		if (disposed || client == null || rootsRequested || Sys.time() < rootsRetryAt) return;
		rootsRequested = true;
		var requestGeneration = generation;
		client.roots(workspace, function(result) {
			if (!requestCurrent(client, requestGeneration)) return;
			if (result == null || result.workspace != workspace || result.roots == null) {
				rootError = "Invalid workspace roots response";
			} else {
				var found = false;
				for (root in result.roots) if (root.id == "root") {
					if (root.capabilities == null || root.capabilities.indexOf("list") < 0 || root.capabilities.indexOf("read") < 0)
						rootError = "Workspace root does not allow browsing and reading files";
					else {
						rootSupportsWatch = root.capabilities.indexOf("watch") >= 0;
						if (root.name != null && root.name.length > 0) rootName = root.name;
						names.set(rootKey(), rootName);
						found = true;
					}
					break;
				}
				if (!found) rootError = "Workspace has no readable root";
				else {
					rootsLoaded = true;
					if (rootSupportsWatch) requestWatch();
				}
			}
			if (rootError != null) {
				rootsRequested = false;
				rootsRetryAt = Sys.time() + 1.0;
			}
			revisionValue++;
			changed();
		}, function(error) {
			if (!requestCurrent(client, requestGeneration)) return;
			rootsRequested = false;
			rootError = error == null ? "Could not read workspace roots" : error.message;
			rootsRetryAt = Sys.time() + 1.0;
			revisionValue++;
			changed();
		});
	}

	function requestWatch():Void {
		var client = activeClient;
		if (client == null || !rootSupportsWatch || watchRequested || watchingChanges || Sys.time() < watchRetryAt) return;
		watchRequested = true;
		var requestGeneration = generation;
		client.watch(workspace, rootId(), watchEpoch, watchCursor, watchListener,
			function(result:FileWatchResult) {
				if (!requestCurrent(client, requestGeneration)) return;
				watchRequested = false;
				if (result == null || result.workspace != workspace || result.root != rootId()
					|| result.epoch == null || result.epoch.length == 0 || result.cursor < 0) {
					client.unwatch(workspace, rootId(), watchListener);
					watchRetryAt = Sys.time() + 1.0;
					revisionValue++;
					changed();
					return;
				}
				var reset = result.reset || watchEpoch != result.epoch;
				watchCursor = watchEpoch == result.epoch ? Std.int(Math.max(watchCursor, result.cursor)) : result.cursor;
				watchEpoch = result.epoch;
				watchingChanges = true;
				if (reset) noteFilesChanged();
				revisionValue++;
				changed();
			}, function(_) {
				if (!requestCurrent(client, requestGeneration)) return;
				watchRequested = false;
				client.unwatch(workspace, rootId(), watchListener);
				watchRetryAt = Sys.time() + 1.0;
				revisionValue++;
				changed();
			});
	}

	function handleFileChange(event:FileChangeEvent):Void {
		if (disposed || activeClient == null || event == null || event.workspace != workspace || event.root != rootId()
			|| event.epoch == null || event.epoch.length == 0 || event.cursor < 1) return;
		if (watchEpoch == event.epoch && event.cursor <= watchCursor) return;
		watchEpoch = event.epoch;
		watchCursor = event.cursor;
		watchingChanges = true;
		noteFilesChanged();
	}

	function noteFilesChanged():Void {
		invalidateListings();
		if (fileChanged != null) fileChanged(rootId());
	}

	function invalidateListings():Void {
		// Preserve the visible snapshot until all previously loaded pages are replaced.
		var clearedError = false;
		for (listing in listings) {
			if (listing.error != null) clearedError = true;
			listing.stale = true;
			listing.error = null;
			listing.limited = false;
		}
		if (clearedError) { revisionValue++; changed(); }
	}

	function requestCurrent(client:WorkspaceFileClient, requestGeneration:Int):Bool
		return !disposed && generation == requestGeneration && activeClient == client && clientProvider() == client;

	function requestPage(path:String, cursor:Null<String>):Void {
		var client = activeClient;
		if (!rootsLoaded || client == null || disposed) return;
		// Subscribe before the first snapshot so the initial watch reset cannot
		// invalidate a listing that was just fetched. Fall back after watch failure.
		if (watchRequested && watchEpoch == null) return;
		var listing = listings.get(path);
		if (listing == null) {
			var directoryCount = 0;
			for (_ in listings.keys()) directoryCount++;
			listing = new WorkspaceDirectoryListing();
			listings.set(path, listing);
			if (directoryCount >= MAX_LISTED_DIRECTORIES) {
				listing.error = "Explorer folder limit reached";
				listing.limited = true;
				return;
			}
		}
		if (listing.loading || listing.refreshing || listing.limited) return;
		var replacing = cursor == null;
		var snapshot = new WorkspaceDirectoryListing();
		if (!replacing) {
			snapshot.entries = listing.entries.copy();
			snapshot.unsupportedCount = listing.unsupportedCount;
		}
		var targetCount = listing.entries.length + listing.unsupportedCount;
		var hadError = listing.error != null;
		listing.refreshing = replacing && listing.loaded;
		listing.loading = !listing.refreshing;
		listing.stale = false;
		listing.error = null;
		var requestGeneration = generation;
		var seenCursors:Map<String, Bool> = [];
		function current():Bool
			return requestCurrent(client, requestGeneration) && listings.get(path) == listing;
		function superseded():Bool {
			if (!listing.stale) return false;
			// A watch event arrived during this read. Coalesce it into a new read
			// rather than publishing a snapshot taken before the latest change.
			listing.loading = false;
			listing.refreshing = false;
			return true;
		}
		function fail(message:String):Void {
			listing.loading = false;
			listing.refreshing = false;
			// Keep the snapshot and make retry restart an interrupted replacement.
			listing.stale = replacing || listing.stale;
			listing.error = message;
			revisionValue++;
			changed();
		}
		function fetch(pageCursor:Null<String>):Void {
			if (pageCursor != null) seenCursors.set(pageCursor, true);
			client.list(workspace, rootId(), path, PAGE_SIZE, pageCursor, function(page:FileListPage) {
				if (!current() || superseded()) return;
				if (page == null || page.workspace != workspace || page.root != rootId() || page.path != path
					|| page.entries == null || page.entries.length > PAGE_SIZE) {
					fail("Invalid directory listing response");
					return;
				}
				if (page.next != null && (page.entries.length == 0 || seenCursors.exists(page.next))) {
					fail("Invalid directory cursor");
					return;
				}
				var cached = cachedEntryCount(listing) + snapshot.entries.length + snapshot.unsupportedCount;
				for (entry in page.entries) {
					var supported = entry != null && entry.name != null && !entry.nameUnsupported && entry.name.length > 0;
					var unsupported = entry != null && (entry.name == null || entry.nameUnsupported);
					if (!supported && !unsupported) continue;
					if (cached >= MAX_CACHED_ENTRIES) {
						snapshot.limited = true;
						snapshot.error = "Explorer entry limit reached; collapse folders to browse another area";
						break;
					}
					if (supported) snapshot.entries.push(entry);
					else snapshot.unsupportedCount++;
					cached++;
				}
				snapshot.cursor = snapshot.limited ? null : page.next;
				if (replacing && snapshot.cursor != null && snapshot.entries.length + snapshot.unsupportedCount < targetCount) {
					fetch(snapshot.cursor);
					return;
				}
				var visibleChanged = hadError || !listing.loaded || listing.error != snapshot.error || listing.limited != snapshot.limited
					|| listing.unsupportedCount != snapshot.unsupportedCount || (listing.cursor == null) != (snapshot.cursor == null)
					|| listing.entries.length != snapshot.entries.length;
				if (!visibleChanged) for (index in 0...listing.entries.length) {
					var before = listing.entries[index], after = snapshot.entries[index];
					if (before.name != after.name || before.kind != after.kind) { visibleChanged = true; break; }
				}
				if (replacing) {
					var retained:Map<String, String> = [];
					for (entry in snapshot.entries) retained.set(entry.name, entry.kind);
					for (entry in listing.entries) if (retained.get(entry.name) != entry.kind) {
						var removed = path.length == 0 ? entry.name : path + "/" + entry.name;
						kinds.remove(fileKey(removed));
						names.remove(fileKey(removed));
						if (entry.kind == "directory") {
							var discarded = [for (cachedPath in listings.keys())
								if (cachedPath == removed || StringTools.startsWith(cachedPath, removed + "/")) cachedPath];
							for (cachedPath in discarded) listings.remove(cachedPath);
							var discardedKeys = [for (key in kinds.keys())
								if (StringTools.startsWith(key, fileKey(removed + "/"))) key];
							for (key in discardedKeys) { kinds.remove(key); names.remove(key); }
						}
					}
				}
				listing.entries = snapshot.entries;
				listing.unsupportedCount = snapshot.unsupportedCount;
				listing.cursor = snapshot.cursor;
				listing.error = snapshot.error;
				listing.limited = snapshot.limited;
				listing.loaded = true;
				listing.loading = false;
				listing.refreshing = false;
				if (visibleChanged) {
					revisionValue++;
					changed();
				}
			}, function(error) {
				if (!current() || superseded()) return;
				if (!replacing && error != null && error.code == "cursor_expired") {
					listing.loading = false;
					listing.stale = true;
					requestPage(path, null);
					return;
				}
				fail(error == null ? "Could not list folder" : error.message);
			});
		}
		fetch(cursor);
	}

	function cachedEntryCount(except:Null<WorkspaceDirectoryListing>):Int {
		var result = 0;
		for (listing in listings) if (listing != except)
			result += listing.entries.length + listing.unsupportedCount;
		return result;
	}

	function resetForConnection():Void {
		generation++;
		rootsRequested = false;
		rootsLoaded = false;
		rootSupportsWatch = false;
		watchRequested = false;
		watchingChanges = false;
		watchRetryAt = 0.0;
		rootError = null;
		rootsRetryAt = 0.0;
		for (listing in listings) {
			listing.loading = false;
			listing.refreshing = false;
			listing.stale = true;
			listing.error = null;
			listing.limited = false;
		}
	}

	function rootKey():String return FILE_PREFIX;
	function fileKey(path:String):String return FILE_PREFIX + path;
	function pathForKey(key:String):String {
		var path = relativePath(key);
		return path == null ? "" : path;
	}
	function isDirectory(key:String):Bool return kinds.get(key) == "directory";
	function displayName(key:String):String {
		var value = names.get(key);
		if (value != null) return value;
		var path = relativePath(key);
		if (path == null) return key;
		var slash = path.lastIndexOf("/");
		return slash < 0 ? path : path.substring(slash + 1);
	}
	function specialKey(kind:String, path:String, label:String):String {
		var key = SPECIAL_PREFIX + kind + ":" + path;
		specialPaths.set(key, path);
		specialLabels.set(key, label);
		return key;
	}
	function specialKind(key:String):String {
		if (!StringTools.startsWith(key, SPECIAL_PREFIX)) return "";
		var end = key.indexOf(":", SPECIAL_PREFIX.length);
		return end < 0 ? "" : key.substring(SPECIAL_PREFIX.length, end);
	}
}
