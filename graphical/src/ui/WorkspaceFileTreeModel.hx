package ui;

import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol.FileListPage;
import workspace.service.WorkspaceFileProtocol.WorkspaceFileEntry;

private class WorkspaceDirectoryListing {
	public var entries:Array<WorkspaceFileEntry> = [];
	public var unsupportedCount:Int = 0;
	public var cursor:Null<String>;
	public var loading:Bool = false;
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
	final changed:Void->Void;
	final listings:Map<String, WorkspaceDirectoryListing> = [];
	final kinds:Map<String, String> = [];
	final names:Map<String, String> = [];
	final specialPaths:Map<String, String> = [];
	final specialLabels:Map<String, String> = [];
	final initialRootName:String;
	var activeClient:Null<WorkspaceFileClient>;
	var connectionResetPending:Bool = false;
	var revisionValue:Int = 0;
	var rootsRequested:Bool = false;
	var rootsLoaded:Bool = false;
	var rootName:String;
	var rootError:Null<String>;
	var rootsRetryAt:Float = 0.0;

	public function watchesChanges():Bool return false;

	public function new(clientProvider:Void->Null<WorkspaceFileClient>, workspace:String, scope:String,
			fallbackRootName:String, theme:Theme, changed:Void->Void) {
		if (clientProvider == null || workspace == null || workspace.length == 0 || scope == null || theme == null || changed == null)
			throw "Invalid workspace file tree configuration";
		this.clientProvider = clientProvider;
		this.workspace = workspace;
		this.scope = scope;
		this.initialRootName = fallbackRootName == null || fallbackRootName.length == 0 ? "Workspace" : fallbackRootName;
		this.rootName = initialRootName;
		this.theme = theme;
		this.changed = changed;
		kinds.set(rootKey(), "directory");
		names.set(rootKey(), rootName);
	}

	public function rootIdentity():String return workspace + ":" + scope + ":" + rootName;
	public function rootCount():Int return 1;
	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return start > 0 || count <= 0 ? [] : [new TreeRootMetadata(rootKey(), true)];
	public function rootKeyAt(index:Int):String return index == 0 ? rootKey() : "";
	public function initiallyExpanded(key:String):Bool return key == rootKey();
	public function estimatedExtent():Float return 26.0;
	public function extentIsUniform():Bool return true;
	public function extentAt(key:String):Float return 26.0;
	public function revision():Int return revisionValue;

	public function refresh():Void {
		var client = clientProvider();
		if (client == null) {
			if (activeClient != null) {
				activeClient = null;
				connectionResetPending = true;
			}
			return;
		}
		if (client != activeClient) {
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
	}

	public function childCount(parentKey:String):Int {
		var special = specialLabels.get(parentKey);
		if (special != null) return 0;
		if (!isDirectory(parentKey)) return 0;
		if (!rootsLoaded) return 1;
		var path = pathForKey(parentKey);
		var listing = listings.get(path);
		if (listing == null) return 1;
		var count = listing.entries.length;
		if (listing.unsupportedCount > 0) count++;
		if (listing.error != null) return count + 1;
		if (listing.cursor != null) return count + 1;
		if (listing.loading) return count + 1;
		return count;
	}

	public function childKeyAt(parentKey:String, index:Int):String {
		if (index < 0 || !isDirectory(parentKey)) return "";
		if (!rootsLoaded) {
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
		if (listing.error != null && index == syntheticIndex)
			return specialKey(listing.limited ? "limit" : "retry", path,
				listing.limited ? listing.error : "Could not load folder — retry");
		if (listing.cursor != null && index == syntheticIndex)
			return specialKey("more", path, "Load more…");
		if (listing.loading && index == syntheticIndex)
			return specialKey("loading", path, "Loading folder…");
		return "";
	}

	public function buildItem(key:String):View
		return new Text(displayName(key), null, theme.tokens.text, TextStyleOverride.text(14.0));

	public function buildItemWithIcons(key:String, expanded:Bool, atlas:SetiIconAtlas, dark:Bool):View {
		var special = specialLabels.get(key);
		if (special != null)
			return new Text(special, null, theme.tokens.textSecondary, TextStyleOverride.text(13.0));
		var label = displayName(key), directory = isDirectory(key);
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(26.0);
		style.clipHorizontal = true;
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 6.0;
		var icon:View = directory
			? new Icon("folder-icon", expanded ? IconName.FolderOpen : IconName.FolderClosed, 20.0, theme.tokens.textSecondary)
			: new SetiFileIcon(atlas, label, dark);
		return new Row("workspace-file-item", [
			new KeyedView("icon", icon),
			new KeyedView("name", new MiddleEllipsisText("filename", label, false,
				new TextStyleOverride(null, 14.0, null, TextWrap.None, null, null, null, theme.tokens.text)))
		], style);
	}

	public function isDirectoryKey(key:String):Bool return isDirectory(key);
	public function isMoreKey(key:String):Bool return specialKind(key) == "more";
	public function isRetryKey(key:String):Bool return specialKind(key) == "retry" || specialKind(key) == "retry-roots";
	public function activateSpecial(key:String):Void {
		var kind = specialKind(key), path = specialPaths.get(key);
		if (path == null) path = "";
		if (kind == "more") {
			var listing = listings.get(path);
			if (listing != null && listing.cursor != null && !listing.loading) requestPage(path, listing.cursor);
		} else if (kind == "retry") {
			var listing = listings.get(path);
			if (listing != null && !listing.loading) requestPage(path, listing.cursor);
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

	function requestRoots():Void {
		var client = clientProvider();
		if (client == null || rootsRequested || Sys.time() < rootsRetryAt) return;
		rootsRequested = true;
		client.roots(workspace, function(result) {
			if (result == null || result.workspace != workspace || result.roots == null) {
				rootError = "Invalid workspace roots response";
			} else {
				var found = false;
				for (root in result.roots) if (root.id == "root") {
					if (root.capabilities == null || root.capabilities.indexOf("list") < 0 || root.capabilities.indexOf("read") < 0)
						rootError = "Workspace root does not allow browsing and reading files";
					else {
						if (root.name != null && root.name.length > 0) rootName = root.name;
						names.set(rootKey(), rootName);
						found = true;
					}
					break;
				}
				if (!found) rootError = "Workspace has no readable root";
				else rootsLoaded = true;
			}
			if (rootError != null) {
				rootsRequested = false;
				rootsRetryAt = Sys.time() + 1.0;
			}
			revisionValue++;
			changed();
		}, function(error) {
			rootsRequested = false;
			rootError = error == null ? "Could not read workspace roots" : error.message;
			rootsRetryAt = Sys.time() + 1.0;
			revisionValue++;
			changed();
		});
	}

	function requestPage(path:String, cursor:Null<String>):Void {
		if (!rootsLoaded || clientProvider() == null) {
			if (!rootsRequested) requestRoots();
			return;
		}
		var listing = listings.get(path);
		if (listing == null) {
			listing = new WorkspaceDirectoryListing();
			listings.set(path, listing);
			var directoryCount = 0;
			for (_ in listings.keys()) directoryCount++;
			if (directoryCount > MAX_LISTED_DIRECTORIES) {
				listing.error = "Explorer folder limit reached";
				listing.limited = true;
				return;
			}
		}
		if (listing.loading) return;
		listing.loading = true;
		listing.error = null;
		var client = clientProvider();
		if (client == null) { listing.loading = false; return; }
		client.list(workspace, rootId(), path, PAGE_SIZE, cursor, function(page:FileListPage) {
			if (page == null || page.workspace != workspace || page.root != rootId() || page.path != path
				|| page.entries == null || page.entries.length > PAGE_SIZE) {
				listing.loading = false;
				listing.error = "Invalid directory listing response";
			} else {
				if (cursor == null) { listing.entries.resize(0); listing.unsupportedCount = 0; }
				var cached = cachedEntryCount(cursor == null ? listing : null);
				for (entry in page.entries) {
					var supported = entry != null && entry.name != null && !entry.nameUnsupported && entry.name.length > 0;
					var unsupported = entry != null && (entry.name == null || entry.nameUnsupported);
					if (!supported && !unsupported) continue;
					if (cached >= MAX_CACHED_ENTRIES) {
						listing.limited = true;
						listing.error = "Explorer entry limit reached; collapse folders to browse another area";
						listing.cursor = null;
						break;
					}
					if (supported) listing.entries.push(entry);
					else listing.unsupportedCount++;
					cached++;
				}
				if (listing.error == null && page.next != null && (page.entries.length == 0 || page.next == cursor)) {
					listing.error = "Invalid directory cursor";
					listing.cursor = null;
				} else if (listing.error == null) {
					listing.cursor = page.next;
				}
				listing.loading = false;
			}
			revisionValue++;
			changed();
		}, function(error) {
			listing.loading = false;
			if (cursor != null && error != null && error.code == "cursor_expired") {
				listing.error = null;
				listing.cursor = null;
				requestPage(path, null);
				revisionValue++;
				changed();
				return;
			}
			listing.error = error == null ? "Could not list folder" : error.message;
			revisionValue++;
			changed();
		});
	}

	function cachedEntryCount(except:Null<WorkspaceDirectoryListing>):Int {
		var result = 0;
		for (listing in listings) if (listing != except)
			result += listing.entries.length + listing.unsupportedCount;
		return result;
	}

	function resetForConnection():Void {
		rootsRequested = false;
		rootsLoaded = false;
		rootError = null;
		rootsRetryAt = 0.0;
		rootName = initialRootName;
		listings.clear();
		kinds.clear();
		names.clear();
		specialPaths.clear();
		specialLabels.clear();
		kinds.set(rootKey(), "directory");
		names.set(rootKey(), rootName);
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
