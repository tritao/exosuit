package controller;

import workspace.client.WorkspaceAttachment;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol.FileSearchHandle;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;
import workspace.service.WorkspaceFileProtocol.FileSearchPageResult;

/** Owns the cancellable, paged RPC lifecycle for a connected workspace search. */
class WorkspaceFileSearchController {
	static inline final SEARCH_ROOT = "root";
	static inline final PAGE_SIZE = 100;
	static inline final DEBOUNCE_SECONDS = 0.15;

	final attachmentProvider:Void->Null<WorkspaceAttachment>;
	final changed:Void->Void;
	public var active(default, null):Bool = false;
	public var mode(default, null):String = "content";
	public var query(default, null):String = "";
	public var generation(default, null):Int = 0;
	public var results(default, null):Array<FileSearchMatch> = [];
	public var complete(default, null):Bool = true;
	public var truncated(default, null):Bool = false;
	public var scannedEntries(default, null):Int = 0;
	public var skippedEntries(default, null):Int = 0;
	public var error(default, null):Null<String>;
	public var waiting(get, never):Bool;

	var caseSensitive:Bool = false;
	var pendingSearch:Bool = false;
	var pendingAt:Float = 0.0;
	var pendingGeneration:Int = 0;
	var activeAttachment:Null<WorkspaceAttachment>;
	var activeClient:Null<WorkspaceFileClient>;
	var activeWorkspace:String = "";
	var activeRoot:String = SEARCH_ROOT;
	var searchId:Null<String>;

	public function new(attachmentProvider:Void->Null<WorkspaceAttachment>, changed:Void->Void) {
		if (attachmentProvider == null || changed == null) throw "Invalid workspace file search controller";
		this.attachmentProvider = attachmentProvider;
		this.changed = changed;
	}

	/** Returns true when the query is handled by the connected workspace RPC service. */
	public function search(value:String, nextMode:String, caseSensitive:Bool):Bool {
		query = value == null ? "" : value;
		mode = nextMode == "name" ? "name" : "content";
		this.caseSensitive = caseSensitive;
		var attachment = attachmentProvider();
		var client = attachment == null ? null : attachment.fileClient();
		stopActiveSearch();
		generation++;
		results = [];
		truncated = false;
		scannedEntries = 0;
		skippedEntries = 0;
		error = null;
		// A disconnected remote workspace still owns this query. Falling back to
		// local search would search a different filesystem and steal sidebar focus.
		if (attachment != null && !attachment.hasLocalFileAccess() && client == null) {
			active = true;
			complete = true;
			error = "Workspace disconnected. Search resumes after reconnect.";
			changed();
			return true;
		}
		if (attachment == null || attachment.hasLocalFileAccess() || client == null || attachment.fileWorkspace() == null
			|| attachment.fileWorkspace().length == 0) {
			active = false;
			complete = true;
			changed();
			return false;
		}
		active = true;
		complete = query.length == 0;
		activeAttachment = attachment;
		activeClient = client;
		activeWorkspace = attachment.fileWorkspace();
		activeRoot = SEARCH_ROOT;
		if (query.length > 0) {
			complete = false;
			pendingSearch = true;
			pendingAt = Sys.time() + DEBOUNCE_SECONDS;
			pendingGeneration = generation;
		}
		changed();
		return true;
	}

	public function toggleMode():Void mode = mode == "content" ? "name" : "content";

	/** Called by the application poll loop; starts work after input has settled. */
	public function update(now:Float):Void {
		if (!pendingSearch || now < pendingAt) return;
		var token = pendingGeneration;
		var attachment = activeAttachment;
		var client = activeClient;
		pendingSearch = false;
		if (token != generation || attachment == null || client == null) return;
		if (attachmentProvider() != attachment || attachment.fileClient() != client) {
			search(query, mode, caseSensitive);
			return;
		}
		client.searchStart(activeWorkspace, activeRoot, mode, query, caseSensitive, function(handle:FileSearchHandle) {
			if (!isCurrent(token, attachment, client)) {
				cancelHandle(client, handle);
				return;
			}
			if (handle == null || handle.workspace != activeWorkspace || handle.root != activeRoot
				|| handle.searchId == null || handle.searchId.length == 0) {
				fail(token, "Workspace returned an invalid search handle");
				return;
			}
			searchId = handle.searchId;
			requestPage(token, attachment, client, handle.searchId);
		}, function(rpcError) {
			if (!isCurrent(token, attachment, client)) return;
			fail(token, rpcError == null ? "Workspace search could not start" : rpcError.message);
		});
	}

	public function cancel():Void {
		stopActiveSearch();
		generation++;
		active = false;
		results = [];
		complete = true;
		truncated = false;
		error = null;
		changed();
	}

	function get_waiting():Bool return pendingSearch;

	function requestPage(token:Int, attachment:WorkspaceAttachment, client:WorkspaceFileClient, id:String):Void {
		if (!isCurrent(token, attachment, client)) return;
		var workspace = activeWorkspace, root = activeRoot;
		client.searchPage(workspace, root, id, PAGE_SIZE, function(page:FileSearchPageResult) {
			if (!isCurrent(token, attachment, client)) return;
			if (page == null || page.workspace != workspace || page.root != root || page.searchId != id
				|| page.matches == null) {
				fail(token, "Workspace returned an invalid search page");
				return;
			}
			for (match in page.matches) {
				if (match == null || match.path == null || match.path.length == 0
					|| match.kind != "file" && match.kind != "directory") continue;
				results.push(match);
			}
			complete = page.complete;
			truncated = page.truncated;
			scannedEntries = page.scannedEntries;
			skippedEntries = page.skippedEntries;
			if (page.complete) searchId = null;
			changed();
			if (!page.complete) requestPage(token, attachment, client, id);
		}, function(rpcError) {
			if (!isCurrent(token, attachment, client)) return;
			fail(token, rpcError == null ? "Workspace search failed" : rpcError.message);
		});
	}

	function fail(token:Int, message:String):Void {
		if (token != generation) return;
		stopActiveSearch();
		complete = true;
		error = message;
		changed();
	}

	function isCurrent(token:Int, attachment:WorkspaceAttachment, client:WorkspaceFileClient):Bool {
		return active && token == generation && activeAttachment == attachment && activeClient == client
			&& attachmentProvider() == attachment && attachment.fileClient() == client;
	}

	function stopActiveSearch():Void {
		var client = activeClient, workspace = activeWorkspace, root = activeRoot, id = searchId;
		pendingSearch = false;
		searchId = null;
		activeClient = null;
		activeAttachment = null;
		if (client != null && id != null && id.length > 0)
			client.searchCancel(workspace, root, id, function(_) {}, function(_) {});
	}

	static function cancelHandle(client:WorkspaceFileClient, handle:FileSearchHandle):Void {
		if (handle != null && handle.workspace != null && handle.root != null && handle.searchId != null
			&& handle.searchId.length > 0)
			client.searchCancel(handle.workspace, handle.root, handle.searchId, function(_) {}, function(_) {});
	}
}
