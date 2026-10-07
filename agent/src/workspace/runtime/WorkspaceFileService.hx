package workspace.runtime;

import haxe.Int64;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxeon.filesystem.FileSystemRoot;
import haxeon.filesystem.FileSystemDirectory;
import haxeon.filesystem.FileSystemDirectory.FileSystemDirectoryEntry;
import haxeon.filesystem.FileSystemFile;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import haxeon.platform.NativeKitEventValue;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntry;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.rpc.RpcError;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceFileProtocol.FileListRequest;
import workspace.service.WorkspaceFileProtocol.FileListPage;
import workspace.service.WorkspaceFileProtocol.FileRootsResult;
import workspace.service.WorkspaceFileProtocol.FileReadOpenRequest;
import workspace.service.WorkspaceFileProtocol.FileReadOpenResult;
import workspace.service.WorkspaceFileProtocol.FileReadChunkRequest;
import workspace.service.WorkspaceFileProtocol.FileReadChunkResult;
import workspace.service.WorkspaceFileProtocol.FileReadCloseRequest;
import workspace.service.WorkspaceFileProtocol.FileReadCloseResult;
import workspace.service.WorkspaceFileProtocol.FileStatRequest;
import workspace.service.WorkspaceFileProtocol.FileStatResult;
import workspace.service.WorkspaceFileProtocol.FileWatchRequest;
import workspace.service.WorkspaceFileProtocol.FileWatchResult;
import workspace.service.WorkspaceFileProtocol.FileUnwatchRequest;
import workspace.service.WorkspaceFileProtocol.FileUnwatchResult;
import workspace.service.WorkspaceFileProtocol.FileChangeEvent;
import workspace.service.WorkspaceFileProtocol.WorkspaceFileEntry;
import workspace.service.WorkspaceFileProtocol.FileSearchStartRequest;
import workspace.service.WorkspaceFileProtocol.FileSearchHandle;
import workspace.service.WorkspaceFileProtocol.FileSearchPageRequest;
import workspace.service.WorkspaceFileProtocol.FileSearchPageResult;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;
import workspace.service.WorkspaceFileProtocol.FileSearchCancelResult;
import workspace.service.WorkspaceProtocol.WorkspaceQuery;
import search.LiteralSearch;

private typedef FileListSnapshot = {
	var id:String;
	var root:String;
	var path:String;
	var revision:String;
	var entries:Array<WorkspaceFileEntry>;
	var lastUsed:Float;
}

private typedef FileSearchState = {
	var id:String;
	var root:String;
	var mode:String;
	var query:String;
	var caseSensitive:Bool;
	var pendingDirectories:Array<String>;
	var currentPath:Null<String>;
	var currentDirectory:Null<FileSystemDirectory>;
	var pendingMatches:Array<FileSearchMatch>;
	var pendingMatchIndex:Int;
	var scannedFiles:Int;
	var scannedBytes:Int;
	var skippedEntries:Int;
	var foundMatches:Int;
	var directoriesVisited:Int;
	var entriesVisited:Int;
	var scanComplete:Bool;
	var truncated:Bool;
	var lastUsed:Float;
}

/** Per-connection cursor state; no listing handle is shared across clients. */
private class WorkspaceFileBinding {
	static inline final MAX_ACTIVE_SEARCHES = 2;
	static inline final MAX_SEARCH_QUERY_BYTES = 256;
	static inline final MAX_SEARCH_PAGE_SIZE = 100;
	static inline final MAX_SEARCH_RESULTS = 1000;
	static inline final MAX_SEARCH_FILE_BYTES = 4 * 1024 * 1024;
	static inline final MAX_SEARCH_BYTES = 64 * 1024 * 1024;
	static inline final MAX_SEARCH_FILES = 20000;
	static inline final MAX_SEARCH_DIRECTORIES = 4096;
	static inline final MAX_SEARCH_ENTRIES = 100000;
	static inline final MAX_SEARCH_ENTRIES_PER_PAGE = 64;
	static inline final SEARCH_IDLE_MS = 30000.0;
	static inline final SEARCH_CHUNK_BYTES = 262144;
	static inline final SEARCH_PREVIEW_MAX_CHARS = 512;
	static inline final SEARCH_PREVIEW_CONTEXT_CHARS = 96;

	final service:WorkspaceFileService;
	final connection:RpcConnection;
	final granted:Bool;
	var active = true;
	var counter = 0;
	final snapshots:Map<String, FileListSnapshot> = [];
	final cursors:Map<String, FileListCursor> = [];
	final readHandles:Map<String, FileReadHandle> = [];
	final searches:Map<String, FileSearchState> = [];
	final watchedRoots:Map<String, Bool> = [];

	public function new(service:WorkspaceFileService, connection:RpcConnection, capabilities:Array<String>) {
		this.service = service;
		this.connection = connection;
		this.granted = capabilities != null && capabilities.indexOf(WorkspaceFileProtocol.READ) >= 0;
	}

	public function start():Void->Void {
		connection.register(WorkspaceFileProtocol.ROOTS, function(request, context) onRoots(request, context));
		connection.register(WorkspaceFileProtocol.STAT, function(request, context) onStat(request, context));
		connection.register(WorkspaceFileProtocol.LIST, function(request, context) onList(request, context));
		connection.register(WorkspaceFileProtocol.READ_OPEN, function(request, context) onReadOpen(request, context));
		connection.register(WorkspaceFileProtocol.READ_CHUNK, function(request, context) onReadChunk(request, context));
		connection.register(WorkspaceFileProtocol.READ_CLOSE, function(request, context) onReadClose(request, context));
		connection.register(WorkspaceFileProtocol.WATCH, function(request, context) onWatch(request, context));
		connection.register(WorkspaceFileProtocol.UNWATCH, function(request, context) onUnwatch(request, context));
		connection.register(WorkspaceFileProtocol.SEARCH_START, function(request, context) onSearchStart(request, context));
		connection.register(WorkspaceFileProtocol.SEARCH_PAGE, function(request, context) onSearchPage(request, context));
		connection.register(WorkspaceFileProtocol.SEARCH_CANCEL, function(request, context) onSearchCancel(request, context));
		return revoke;
	}

	function authorized<T>(context:RpcContext<T>):Bool {
		if (active && granted && !service.disposed)
			return true;
		context.fail({code: "unauthorized", message: "Workspace file access denied", ambiguous: false});
		return false;
	}

	function onRoots(request:WorkspaceQuery, context:RpcContext<FileRootsResult>):Void {
		if (!authorized(context)) return;
		if (request == null || request.workspace != service.workspace) {
			context.fail({code: "unknown_workspace", message: "Unknown workspace", ambiguous: false});
			return;
		}
		context.respond({workspace: service.workspace, roots: [for (root in service.roots) {
			id: root.id,
			name: root.name,
			capabilities: service.watchAvailable() ? ["stat", "list", "read", "watch", "search"] : ["stat", "list", "read", "search"]
		}]});
	}

	function onStat(request:FileStatRequest, context:RpcContext<FileStatResult>):Void {
		if (!authorized(context))
			return;
		if (request == null || !service.validRef(request.workspace, request.root)) {
			context.fail({code: "invalid_request", message: "Invalid workspace file reference", ambiguous: false});
			return;
		}
		if (!service.validPath(request.path)) {
			context.fail({code: "invalid_path", message: "Workspace paths must be canonical and root-relative", ambiguous: false});
			return;
		}
		try {
			var nativeEntry = service.rootHandle(request.root).stat(request.path);
			context.respond({workspace: service.workspace, root: request.root, path: request.path,
				entry: WorkspaceFileService.metadata(service.workspace, request.root, null, nativeEntry)});
		} catch (error:Dynamic) {
			var result = WorkspaceFileService.nativeResult(error);
			context.fail(result == null ? {code: "file_unavailable", message: "Workspace file metadata is unavailable", ambiguous: false}
				: WorkspaceFileService.fileErrorResult(result));
		}
	}

	function onList(request:FileListRequest, context:RpcContext<FileListPage>):Void {
		if (!authorized(context)) return;
		if (request == null || !service.validRef(request.workspace, request.root)
			|| request.limit < 1 || request.limit > WorkspaceFileService.PAGE_LIMIT) {
			context.fail({code: "invalid_request", message: "Invalid workspace directory request", ambiguous: false});
			return;
		}
		if (!service.validPath(request.path)) {
			context.fail({code: "invalid_path", message: "Workspace paths must be canonical and root-relative", ambiguous: false});
			return;
		}
		prune();
		if (request.cursor == null) {
			startList(request, context);
			return;
		}
		continueList(request, context);
	}

	function onReadOpen(request:FileReadOpenRequest, context:RpcContext<FileReadOpenResult>):Void {
		if (!authorized(context)) return;
		if (request == null || !service.validRef(request.workspace, request.root)) {
			context.fail({code: "invalid_request", message: "Invalid workspace file reference", ambiguous: false});
			return;
		}
		if (!service.validPath(request.path)) {
			context.fail({code: "invalid_path", message: "Workspace paths must be canonical and root-relative", ambiguous: false});
			return;
		}
		if (request.expectedRevision != null && request.expectedRevision.length > 128) {
			context.fail({code: "invalid_request", message: "Invalid file revision", ambiguous: false});
			return;
		}
		if (request.initialBytesLimit != null && (request.initialBytesLimit < 0 || request.initialBytesLimit > WorkspaceFileService.READ_CHUNK_BYTES)) {
			context.fail({code: "invalid_range", message: "Invalid initial file byte limit", ambiguous: false});
			return;
		}
		pruneReadHandles();
		if (readHandleCount() >= WorkspaceFileService.MAX_READ_HANDLES_PER_CLIENT) {
			context.fail({code: "resource_limit", message: "Too many open workspace file reads", ambiguous: false});
			return;
		}
		var file:Null<FileSystemFile> = null;
		try {
			file = service.rootHandle(request.root).openFile(request.path);
			var entry = file.info();
			var revision = WorkspaceFileService.fileRevision(service.workspace, request.root, entry);
			if (request.expectedRevision != null && request.expectedRevision != revision) {
				file.close();
				file = null;
				context.fail({code: "revision_changed", message: "File changed since it was listed", ambiguous: false});
				return;
			}
			var size = entry.get_size();
			var initialBytes:Null<Bytes> = null;
			if (request.initialBytesLimit != null && request.initialBytesLimit > 0 &&
				Int64.compare(size, Int64.ofInt(request.initialBytesLimit)) <= 0) {
				var length = Int64.toInt(size);
				var bytes = length == 0 ? Bytes.alloc(0) : file.read(Int64.ofInt(0), length);
				initialBytes = bytes;
				if (bytes.length != length || WorkspaceFileService.fileRevision(service.workspace, request.root, file.info()) != revision) {
					file.close();
					file = null;
					context.fail({code: "revision_changed", message: "File changed during the read", ambiguous: false});
					return;
				}
			}
			var handle = makeReadToken(request.root, request.path);
			readHandles.set(handle, {root: request.root, path: request.path, file: file,
				revision: revision, size: entry.get_size(), lastUsed: service.clock()});
			context.respond({workspace: service.workspace, root: request.root, path: request.path,
				handle: handle, revision: revision, size: entry.get_size(), initialBytes: initialBytes});
			file = null;
		} catch (error:Dynamic) {
			if (file != null)
				try file.close() catch (_:Dynamic) {}
			var result = WorkspaceFileService.nativeResult(error);
			context.fail(result == null ? {code: "file_unavailable", message: "Workspace file could not be opened", ambiguous: false}
				: result == Result.ErrorInvalidArgument
					? {code: "unsupported_type", message: "Only regular files can be read", ambiguous: false}
					: WorkspaceFileService.fileErrorResult(result));
		}
	}

	function onReadChunk(request:FileReadChunkRequest, context:RpcContext<FileReadChunkResult>):Void {
		if (!authorized(context)) return;
		if (request == null || request.workspace != service.workspace || request.handle == null
			|| request.handle.length == 0 || request.handle.length > 128 || request.offset == null
			|| Int64.compare(request.offset, Int64.ofInt(0)) < 0 || request.length < 1
			|| request.length > WorkspaceFileService.READ_CHUNK_BYTES) {
			context.fail({code: "invalid_range", message: "Invalid workspace file byte range", ambiguous: false});
			return;
		}
		pruneReadHandles();
		var state = readHandles.get(request.handle);
		if (state == null) {
			context.fail({code: "invalid_handle", message: "Workspace file handle is unavailable", ambiguous: false});
			return;
		}
		if (Int64.compare(request.offset, state.size) > 0) {
			context.fail({code: "invalid_range", message: "File offset is beyond end of file", ambiguous: false});
			return;
		}
		try {
			var before = state.file.info();
			if (WorkspaceFileService.fileRevision(service.workspace, state.root, before) != state.revision) {
				closeReadHandle(request.handle);
				context.fail({code: "revision_changed", message: "File changed during the read", ambiguous: false});
				return;
			}
			var remaining = Int64.sub(state.size, request.offset);
			var length = Int64.compare(remaining, Int64.ofInt(request.length)) < 0
				? Int64.toInt(remaining) : request.length;
			var bytes = length == 0 ? Bytes.alloc(0) : state.file.read(request.offset, length);
			var after = state.file.info();
			if (WorkspaceFileService.fileRevision(service.workspace, state.root, after) != state.revision
				|| bytes.length != length) {
				closeReadHandle(request.handle);
				context.fail({code: "revision_changed", message: "File changed during the read", ambiguous: false});
				return;
			}
			state.lastUsed = service.clock();
			context.respond({handle: request.handle, revision: state.revision, offset: request.offset,
				bytes: bytes, eof: Int64.compare(Int64.add(request.offset, Int64.ofInt(bytes.length)), state.size) >= 0});
		} catch (error:Dynamic) {
			var result = WorkspaceFileService.nativeResult(error);
			closeReadHandle(request.handle);
			if (result != null && result == Result.ErrorInvalidRequest) {
				context.fail({code: "revision_changed", message: "File handle was invalidated", ambiguous: false});
			} else {
				context.fail(result == null ? {code: "file_unavailable", message: "Workspace file read failed", ambiguous: false}
					: WorkspaceFileService.fileErrorResult(result));
			}
		}
	}

	function onReadClose(request:FileReadCloseRequest, context:RpcContext<FileReadCloseResult>):Void {
		if (!authorized(context)) return;
		if (request == null || request.workspace != service.workspace || request.handle == null
			|| request.handle.length == 0 || request.handle.length > 128) {
			context.fail({code: "invalid_request", message: "Invalid workspace file handle", ambiguous: false});
			return;
		}
		context.respond({closed: closeReadHandle(request.handle)});
	}

	function onWatch(request:FileWatchRequest, context:RpcContext<FileWatchResult>):Void {
		if (!authorized(context)) return;
		if (request == null || !service.validRef(request.workspace, request.root) || request.cursor < 0
			|| request.epoch != null && request.epoch.length > 128) {
			context.fail({code: "invalid_request", message: "Invalid workspace file watch", ambiguous: false});
			return;
		}
		if (!service.watchAvailable()) {
			context.fail({code: "unsupported", message: "Workspace file watching is unavailable", ambiguous: false});
			return;
		}
		watchedRoots.set(request.root, true);
		context.respond(service.subscribe(request.root, this, request.epoch, request.cursor));
	}

	function onUnwatch(request:FileUnwatchRequest, context:RpcContext<FileUnwatchResult>):Void {
		if (!authorized(context)) return;
		if (request == null || !service.validRef(request.workspace, request.root)) {
			context.fail({code: "invalid_request", message: "Invalid workspace file watch", ambiguous: false});
			return;
		}
		if (watchedRoots.exists(request.root)) {
			watchedRoots.remove(request.root);
			service.unsubscribe(request.root, this);
		}
		context.respond({unwatched: true});
	}

	function onSearchStart(request:FileSearchStartRequest, context:RpcContext<FileSearchHandle>):Void {
		if (!authorized(context)) return;
		if (request == null || !service.validRef(request.workspace, request.root)
			|| request.mode != "name" && request.mode != "content" || request.query == null
			|| request.query.length == 0 || Bytes.ofString(request.query).length > MAX_SEARCH_QUERY_BYTES
			|| hasNul(request.query) || request.query.indexOf("\n") >= 0) {
			context.fail({code: "unsupported_query", message: "Invalid workspace file search query", ambiguous: false});
			return;
		}
		pruneSearches();
		if (searchCount() >= MAX_ACTIVE_SEARCHES) {
			context.fail({code: "resource_limit", message: "Too many active workspace searches", ambiguous: false});
			return;
		}
		counter++;
		var id = makeReadToken(request.root, "search:" + counter);
		var state:FileSearchState = {
			id: id,
			root: request.root,
			mode: request.mode,
			query: request.query,
			caseSensitive: request.caseSensitive,
			pendingDirectories: [""],
			currentPath: null,
			currentDirectory: null,
			pendingMatches: [],
			pendingMatchIndex: 0,
			scannedFiles: 0,
			scannedBytes: 0,
			skippedEntries: 0,
			foundMatches: 0,
			directoriesVisited: 0,
			entriesVisited: 0,
			scanComplete: false,
			truncated: false,
			lastUsed: service.clock()
		};
		searches.set(id, state);
		context.respond({workspace: service.workspace, root: request.root, searchId: id});
	}

	function onSearchPage(request:FileSearchPageRequest, context:RpcContext<FileSearchPageResult>):Void {
		if (!authorized(context)) return;
		if (request == null || request.workspace != service.workspace || request.searchId == null
			|| request.searchId.length == 0 || request.searchId.length > 128 || request.limit < 1
			|| request.limit > MAX_SEARCH_PAGE_SIZE || !service.validRef(request.workspace, request.root)) {
			context.fail({code: "invalid_request", message: "Invalid workspace search page", ambiguous: false});
			return;
		}
		pruneSearches();
		var state = searches.get(request.searchId);
		if (state == null || state.root != request.root) {
			context.fail({code: "invalid_handle", message: "Workspace search is unavailable", ambiguous: false});
			return;
		}
		state.lastUsed = service.clock();
		var matches = runSearchPage(state, request.limit);
		var complete = searchComplete(state), result:FileSearchPageResult = {workspace: service.workspace, root: state.root,
			searchId: state.id, matches: matches, complete: complete, truncated: state.truncated,
			scannedFiles: state.scannedFiles, scannedBytes: state.scannedBytes,
			skippedEntries: state.skippedEntries, scannedEntries: state.entriesVisited};
		if (complete) {
			searches.remove(state.id);
			closeSearch(state);
		}
		context.respond(result);
	}

	function onSearchCancel(request:FileSearchHandle, context:RpcContext<FileSearchCancelResult>):Void {
		if (!authorized(context)) return;
		if (request == null || request.workspace != service.workspace || request.searchId == null
			|| request.searchId.length == 0 || request.searchId.length > 128
			|| !service.validRef(request.workspace, request.root)) {
			context.fail({code: "invalid_request", message: "Invalid workspace search cancellation", ambiguous: false});
			return;
		}
		var state = searches.get(request.searchId);
		if (state == null || state.root != request.root) {
			context.respond({cancelled: false});
			return;
		}
		closeSearch(state);
		searches.remove(state.id);
		context.respond({cancelled: true});
	}

	function runSearchPage(state:FileSearchState, limit:Int):Array<FileSearchMatch> {
		var matches:Array<FileSearchMatch> = [], processed = 0, startedAt = service.clock();
		while (matches.length < limit && processed < MAX_SEARCH_ENTRIES_PER_PAGE
			&& service.clock() - startedAt < 25.0 && !searchComplete(state)) {
			if (state.pendingMatchIndex < state.pendingMatches.length) {
				matches.push(state.pendingMatches[state.pendingMatchIndex++]);
				continue;
			}
			state.pendingMatches = [];
			state.pendingMatchIndex = 0;
			if (state.scanComplete) break;
			if (state.currentDirectory == null) {
				if (state.pendingDirectories.length == 0) {
					state.scanComplete = true;
					break;
				}
				if (state.directoriesVisited >= MAX_SEARCH_DIRECTORIES) {
					state.truncated = true;
					state.scanComplete = true;
					break;
				}
				state.currentPath = state.pendingDirectories.pop();
				state.directoriesVisited++;
				try {
					state.currentDirectory = service.rootHandle(state.root).openDirectory(state.currentPath);
				} catch (_:Dynamic) {
					state.skippedEntries++;
					state.currentPath = null;
					continue;
				}
			}
			var item:Null<FileSystemDirectoryEntry> = null;
			try {
				item = state.currentDirectory.next();
			} catch (_:Dynamic) {
				state.skippedEntries++;
				closeCurrentDirectory(state);
				continue;
			}
			if (item == null) {
				closeCurrentDirectory(state);
				continue;
			}
			if (state.entriesVisited >= MAX_SEARCH_ENTRIES) {
				state.truncated = true;
				state.scanComplete = true;
				closeCurrentDirectory(state);
				break;
			}
			processed++;
			state.entriesVisited++;
			if (item.name == null || item.name.length == 0) {
				state.skippedEntries++;
				continue;
			}
			var parent = state.currentPath == null ? "" : state.currentPath,
				path = parent.length == 0 ? item.name : parent + "/" + item.name,
				entry = WorkspaceFileService.metadata(service.workspace, state.root, item.name, item.metadata);
			if (state.mode == "name") {
				if (entry.kind == "file") {
					if (state.scannedFiles >= MAX_SEARCH_FILES) {
						state.truncated = true;
						state.scanComplete = true;
						closeCurrentDirectory(state);
						break;
					}
					state.scannedFiles++;
				}
			} else if (entry.kind == "directory") {
				state.pendingDirectories.push(path);
			} else if (entry.kind == "file") {
				scanSearchFile(state, path, entry.revision, entry.size);
			}
			if (state.mode == "name") {
				var nameColumn = literalIndex(path, state.query, state.caseSensitive);
				if (nameColumn >= 0)
					queueSearchMatch(state, {path: path, kind: entry.kind, revision: entry.revision,
						line: -1, column: -1, length: -1,
						preview: boundedSearchPreview(path, nameColumn, state.query.length)});
			}
		}
		return matches;
	}

	function scanSearchFile(state:FileSearchState, path:String, expectedRevision:String, listedSize:Int64):Void {
		if (state.scannedFiles >= MAX_SEARCH_FILES) {
			state.truncated = true;
			state.scanComplete = true;
			closeCurrentDirectory(state);
			return;
		}
		state.scannedFiles++;
		if (Int64.compare(listedSize, Int64.ofInt(MAX_SEARCH_FILE_BYTES)) > 0) {
			state.skippedEntries++;
			return;
		}
		if (state.scannedBytes + Int64.toInt(listedSize) > MAX_SEARCH_BYTES) {
			state.truncated = true;
			state.scanComplete = true;
			closeCurrentDirectory(state);
			return;
		}
		var file:Null<FileSystemFile> = null;
		try {
			file = service.rootHandle(state.root).openFile(path);
		} catch (_:Dynamic) {
			state.skippedEntries++;
			return;
		}
		if (file == null) return;
		try {
			scanSearchFileContents(state, path, expectedRevision, file);
		} catch (_:Dynamic) {
			state.skippedEntries++;
		}
		try {
			file.close();
		} catch (_:Dynamic) {}
	}

	function scanSearchFileContents(state:FileSearchState, path:String, expectedRevision:String, file:FileSystemFile):Void {
		var before = file.info(), beforeRevision = WorkspaceFileService.fileRevision(service.workspace, state.root, before);
		if (beforeRevision != expectedRevision || Int64.compare(before.get_size(), Int64.ofInt(MAX_SEARCH_FILE_BYTES)) > 0) {
			state.skippedEntries++;
			return;
		}
		var size = Int64.toInt(before.get_size()), buffer = new BytesBuffer(), offset = 0;
		if (state.scannedBytes + size > MAX_SEARCH_BYTES) {
			state.truncated = true;
			state.scanComplete = true;
			closeCurrentDirectory(state);
			return;
		}
		while (offset < size) {
			var length = Std.int(Math.min(SEARCH_CHUNK_BYTES, size - offset));
			var bytes = file.read(Int64.ofInt(offset), length);
			if (bytes.length != length) {
				state.skippedEntries++;
				return;
			}
			buffer.add(bytes);
			state.scannedBytes += bytes.length;
			offset += bytes.length;
		}
		var after = file.info();
		if (WorkspaceFileService.fileRevision(service.workspace, state.root, after) != beforeRevision) {
			state.skippedEntries++;
			return;
		}
		var content = buffer.getBytes();
		if (!isSearchText(content)) {
			state.skippedEntries++;
			return;
		}
		var text = content.toString();
		var found = LiteralSearch.findTextLimited(text, state.query, state.caseSensitive,
			MAX_SEARCH_RESULTS - state.foundMatches + 1);
		var previousLine = -1, byteColumn = 0, byteCursor = 0;
		for (match in found) {
			if (state.foundMatches >= MAX_SEARCH_RESULTS) {
				state.truncated = true;
				state.scanComplete = true;
				closeCurrentDirectory(state);
				break;
			}
			var line = match.lineText;
			if (previousLine != match.line) {
				previousLine = match.line;
				byteColumn = 0;
				byteCursor = 0;
			}
			byteColumn += Bytes.ofString(line.substring(byteCursor, match.column)).length;
			var column = byteColumn, matchedText = line.substring(match.column, match.column + match.length),
				length = Bytes.ofString(matchedText).length;
			byteColumn += length;
			byteCursor = match.column + match.length;
			queueSearchMatch(state, {path: path, kind: "file", revision: beforeRevision,
				line: match.line, column: column, length: length,
				preview: boundedSearchPreview(line, match.column, match.length)});
		}
	}

	static function boundedSearchPreview(line:String, column:Int, length:Int):String {
		var start = Std.int(Math.max(0, Math.min(column - SEARCH_PREVIEW_CONTEXT_CHARS,
			column + length - SEARCH_PREVIEW_MAX_CHARS)));
		if (start > 0) {
			var first = line.charCodeAt(start);
			if (first >= 0xdc00 && first <= 0xdfff) start--;
		}
		var end = Std.int(Math.min(line.length, start + SEARCH_PREVIEW_MAX_CHARS));
		if (end < line.length && end > 0) {
			var previous = line.charCodeAt(end - 1), next = line.charCodeAt(end);
			if (previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end--;
		}
		var preview = line.substring(start, end);
		if (start > 0) preview = "…" + preview;
		if (end < line.length) preview += "…";
		return preview;
	}

	function queueSearchMatch(state:FileSearchState, match:FileSearchMatch):Bool {
		if (state.foundMatches >= MAX_SEARCH_RESULTS) {
			state.truncated = true;
			state.scanComplete = true;
			closeCurrentDirectory(state);
			return false;
		}
		state.pendingMatches.push(match);
		state.foundMatches++;
		return true;
	}

	function closeCurrentDirectory(state:FileSearchState):Void {
		if (state.currentDirectory != null) {
			try {
				state.currentDirectory.close();
			} catch (_:Dynamic) {}
		}
		state.currentDirectory = null;
		state.currentPath = null;
	}

	function searchComplete(state:FileSearchState):Bool
		return state.scanComplete && state.pendingMatchIndex >= state.pendingMatches.length;

	function literalIndex(value:String, query:String, caseSensitive:Bool):Int
		return (caseSensitive ? value : value.toLowerCase()).indexOf(caseSensitive ? query : query.toLowerCase());

	function searchCount():Int {
		var count = 0;
		for (_ in searches.keys()) count++;
		return count;
	}

	function pruneSearches():Void {
		var now = service.clock(), expired:Array<String> = [];
		for (id => state in searches)
			if (now - state.lastUsed > SEARCH_IDLE_MS) expired.push(id);
		for (id in expired) {
			var state = searches.get(id);
			if (state != null) closeSearch(state);
			searches.remove(id);
		}
	}

	function closeSearch(state:FileSearchState):Void {
		closeCurrentDirectory(state);
		state.pendingDirectories.resize(0);
		state.pendingMatches.resize(0);
		state.scanComplete = true;
	}

	static function isSearchText(bytes:Bytes):Bool {
		var index = 0;
		while (index < bytes.length) {
			var first = bytes.get(index);
			if (first == 0) return false;
			if (first <= 0x7f) { index++; continue; }
			if (first >= 0xc2 && first <= 0xdf) {
				if (!continuation(bytes, index + 1)) return false;
				index += 2;
				continue;
			}
			if (first >= 0xe0 && first <= 0xef) {
				if (index + 2 >= bytes.length) return false;
				var second = bytes.get(index + 1), third = bytes.get(index + 2);
				if (third < 0x80 || third > 0xbf || first == 0xe0 && (second < 0xa0 || second > 0xbf)
					|| first == 0xed && (second < 0x80 || second > 0x9f)
					|| first != 0xe0 && first != 0xed && (second < 0x80 || second > 0xbf)) return false;
				index += 3;
				continue;
			}
			if (first >= 0xf0 && first <= 0xf4) {
				if (index + 3 >= bytes.length) return false;
				var second = bytes.get(index + 1);
				if (!continuation(bytes, index + 2) || !continuation(bytes, index + 3)
					|| first == 0xf0 && (second < 0x90 || second > 0xbf)
					|| first == 0xf4 && (second < 0x80 || second > 0x8f)
					|| first != 0xf0 && first != 0xf4 && (second < 0x80 || second > 0xbf)) return false;
				index += 4;
				continue;
			}
			return false;
		}
		return true;
	}

	static function continuation(bytes:Bytes, index:Int):Bool
		return index < bytes.length && bytes.get(index) >= 0x80 && bytes.get(index) <= 0xbf;

	static function hasNul(value:String):Bool {
		var bytes = Bytes.ofString(value);
		for (index in 0...bytes.length) if (bytes.get(index) == 0) return true;
		return false;
	}

	public function notifyFileChanged(event:FileChangeEvent):Void {
		if (active && watchedRoots.exists(event.root) && connection.isOpen())
			connection.notify(WorkspaceFileProtocol.CHANGED, event, WorkspaceFileProtocol.encodeChange);
	}

	function makeReadToken(root:String, path:String):String {
		counter++;
		return Sha256.encode(service.workspace + ":" + root + ":" + path + ":" + counter + ":" + service.clock() + ":" + Math.random()).substr(0, 48);
	}

	function closeReadHandle(handle:String):Bool {
		var state = readHandles.get(handle);
		if (state == null)
			return false;
		readHandles.remove(handle);
		try state.file.close() catch (_:Dynamic) {}
		return true;
	}

	function pruneReadHandles():Void {
		var now = service.clock();
		var expired:Array<String> = [];
		for (handle => state in readHandles)
			if (now - state.lastUsed > WorkspaceFileService.CURSOR_IDLE_MS)
				expired.push(handle);
		for (handle in expired)
			closeReadHandle(handle);
	}

	function readHandleCount():Int {
		var count = 0;
		for (_ in readHandles.keys()) count++;
		return count;
	}

	function startList(request:FileListRequest, context:RpcContext<FileListPage>):Void {
		try {
			var snapshot = service.readSnapshot(request.root, request.path);
			if (snapshotCount() >= WorkspaceFileService.MAX_SNAPSHOTS_PER_CLIENT)
				dropSnapshot(oldestSnapshot());
			snapshots.set(snapshot.id, snapshot);
			var response = service.page(snapshot, 0, request.limit,
				function(value, offset) return makeCursor(value, offset));
			if (response.next == null)
				dropSnapshot(snapshot.id);
			context.respond(response);
		} catch (error:Dynamic) {
			if (Std.string(error) == "workspace_list_limit")
				context.fail({code: "resource_limit", message: "Workspace directory listing exceeds the bounded snapshot limit", ambiguous: false});
			else {
				var result = WorkspaceFileService.nativeResult(error);
				context.fail(result == null ? {code: "file_unavailable", message: "Workspace directory listing is unavailable", ambiguous: false}
					: WorkspaceFileService.fileErrorResult(result));
			}
		}
	}

	function continueList(request:FileListRequest, context:RpcContext<FileListPage>):Void {
		var token = request.cursor;
		if (token == null || token.length == 0 || token.length > 128) {
			context.fail({code: "invalid_request", message: "Invalid directory cursor", ambiguous: false});
			return;
		}
		var state = cursors.get(token);
		if (state == null || state.snapshot.root != request.root || state.snapshot.path != request.path) {
			context.fail({code: "cursor_expired", message: "Directory listing expired; list again", ambiguous: false});
			return;
		}
		state.snapshot.lastUsed = service.clock();
		context.respond(service.page(state.snapshot, state.offset, request.limit, function(snapshot, offset) {
			if (state.next == null)
				state.next = makeCursor(snapshot, offset);
			return state.next;
		}));
	}

	function makeCursor(snapshot:FileListSnapshot, offset:Int):String {
		counter++;
		var token = Sha256.encode(service.workspace + ":" + snapshot.id + ":" + counter + ":" + service.clock()).substr(0, 32);
		cursors.set(token, {snapshot: snapshot, offset: offset, next: null});
		return token;
	}

	function prune():Void {
		var now = service.clock();
		var expired:Array<String> = [];
		for (id => snapshot in snapshots)
			if (now - snapshot.lastUsed > WorkspaceFileService.CURSOR_IDLE_MS)
				expired.push(id);
		for (id in expired)
			dropSnapshot(id);
		pruneReadHandles();
		pruneSearches();
	}

	function dropSnapshot(id:String):Void {
		snapshots.remove(id);
		var expired:Array<String> = [];
		for (token => state in cursors)
			if (state.snapshot.id == id)
				expired.push(token);
		for (token in expired)
			cursors.remove(token);
	}

	function snapshotCount():Int {
		var count = 0;
		for (_ in snapshots.keys()) count++;
		return count;
	}

	function oldestSnapshot():String {
		var id:Null<String> = null, oldest = Math.POSITIVE_INFINITY;
		for (key => snapshot in snapshots)
			if (snapshot.lastUsed < oldest) { id = key; oldest = snapshot.lastUsed; }
		return id;
	}

	function revoke():Void {
		active = false;
		for (root in watchedRoots.keys()) service.unsubscribe(root, this);
		watchedRoots.clear();
		cursors.clear();
		snapshots.clear();
		var handles = [for (handle in readHandles.keys()) handle];
		for (handle in handles)
			closeReadHandle(handle);
		var searchStates = [for (state in searches) state];
		for (state in searchStates) closeSearch(state);
		searches.clear();
	}
}

private typedef FileListCursor = {
	var snapshot:FileListSnapshot;
	var offset:Int;
	var next:Null<String>;
}

private typedef FileReadHandle = {
	var root:String;
	var path:String;
	var file:FileSystemFile;
	var revision:String;
	var size:Int64;
	var lastUsed:Float;
}

private typedef FileWatchState = {
	var epoch:String;
	var cursor:Int;
	var listeners:Array<WorkspaceFileBinding>;
}

private typedef WorkspaceFileRoot = {
	var id:String;
	var name:String;
	var path:String;
	var handle:FileSystemRoot;
}

/** Root-scoped, read-only file metadata service for one workspace daemon. */
@:allow(workspace.runtime.WorkspaceFileBinding)
class WorkspaceFileService {
	public static inline final ROOT_ID = "root";
	static inline final MAX_ROOTS = 16;
	static inline final PAGE_LIMIT = 32;
	static inline final MAX_SNAPSHOT_ENTRIES = 8192;
	static inline final MAX_SNAPSHOT_NAME_BYTES = 1048576;
	static inline final MAX_SNAPSHOTS_PER_CLIENT = 4;
	static inline final MAX_READ_HANDLES_PER_CLIENT = 8;
	static inline final READ_CHUNK_BYTES = 262144;
	static inline final CURSOR_IDLE_MS = 30000.0;

	final workspace:String;
	final roots:Array<WorkspaceFileRoot> = [];
	final rootsById:Map<String, WorkspaceFileRoot> = [];
	final watchStates:Map<String, FileWatchState> = [];
	final dirtyRoots:Map<String, Bool> = [];
	final clock:Void->Float;
	var fileWatch:Null<OwnedFileWatch>;
	var eventSubscription:Null<NativeKitEventSubscription>;
	var nextWatchFlush:Float = 0.0;
	var disposed:Bool = false;

	public function new(workspace:String, rootPaths:Array<String>, clock:Void->Float, ?events:NativeKitEvents) {
		if (workspace == null || workspace.length == 0 || workspace.length > 128 || clock == null
			|| rootPaths == null || rootPaths.length == 0 || rootPaths.length > MAX_ROOTS)
			throw "Invalid workspace filesystem identity";
		this.workspace = workspace;
		this.clock = clock;
		try {
			for (index in 0...rootPaths.length) {
				var path = rootPaths[index];
				if (path == null || path.length == 0)
					throw "Invalid workspace filesystem root";
				var root:WorkspaceFileRoot = {
					id: index == 0 ? ROOT_ID : ROOT_ID + "-" + index,
					name: displayName(path),
					path: path,
					handle: new FileSystemRoot(path)
				};
				roots.push(root);
				rootsById.set(root.id, root);
				watchStates.set(root.id, {
					epoch: Sha256.encode(workspace + ":" + clock() + ":" + Math.random() + ":" + root.id),
					cursor: 0,
					listeners: []
				});
			}
		} catch (error:Dynamic) {
			for (root in roots)
				try root.handle.close() catch (_:Dynamic) {}
			throw error;
		}
		startWatcher(events);
	}

	public function watchAvailable():Bool return fileWatch != null;

	public function subscribe(rootId:String, listener:WorkspaceFileBinding, epoch:Null<String>, cursor:Int):FileWatchResult {
		var state = watchStates.get(rootId);
		if (state == null || listener == null || !watchAvailable())
			throw "Workspace file watcher is unavailable";
		if (state.listeners.indexOf(listener) < 0) state.listeners.push(listener);
		return {workspace: workspace, root: rootId, epoch: state.epoch, cursor: state.cursor,
			reset: epoch != state.epoch || cursor != state.cursor};
	}

	public function unsubscribe(rootId:String, listener:WorkspaceFileBinding):Void {
		var state = watchStates.get(rootId);
		if (state != null) state.listeners.remove(listener);
	}

	/** Coalesces native events per root before notifying subscribed RPC peers. */
	public function poll():Void {
		var dirty = [for (root in dirtyRoots.keys()) root];
		if (!watchAvailable() || dirty.length == 0) return;
		var now = clock();
		if (now < nextWatchFlush) return;
		nextWatchFlush = now + 100.0;
		dirtyRoots.clear();
		for (root in dirty) {
			var state = watchStates.get(root);
			if (state == null) continue;
			if (state.cursor == 0x7fffffff) {
				state.epoch = newWatchEpoch(root);
				state.cursor = 0;
			}
			state.cursor++;
			var event:FileChangeEvent = {workspace: workspace, root: root, epoch: state.epoch, cursor: state.cursor};
			for (listener in state.listeners.copy()) listener.notifyFileChanged(event);
		}
	}

	function startWatcher(events:Null<NativeKitEvents>):Void {
		if (events == null || events.isDisposed()) return;
		try {
			var options = new FileWatchOptions();
			options.set_struct_size(24);
			var created = NativeKit.nk_file_watch_create(options);
			if (created.status != Result.Ok) return;
			fileWatch = created.out_watch;
			for (root in roots) if (NativeKit.nk_file_watch_add_directory(fileWatch.borrow(), root.path, true) != Result.Ok) {
				stopWatcher();
				return;
			}
			eventSubscription = events.listen(onNativeEvent);
		} catch (_:Dynamic) {
			stopWatcher();
		}
	}

	function onNativeEvent(event:NativeKitEventValue):Void {
		try switch event {
			case Raw(kind, source, _, _, _, _, data) if (fileWatch != null
				&& source.rawValue() == fileWatch.borrow().rawValue()):
				if (kind == EventKind.FileWatchOverflow) markAllRootsChanged();
				else if (kind == EventKind.FileChanged) {
					if (data == null || data.length < 28) { markAllRootsChanged(); return; }
					var flags = readU32(data, 8), offset = readU32(data, 12), length = readU32(data, 16);
					if (flags != 0) { markAllRootsChanged(); return; }
					var path = eventPath(data, offset, length);
					if (path == null) markAllRootsChanged(); else markPathChanged(path);
				}
			case _:
		} catch (_:Dynamic) markAllRootsChanged();
	}

	function markPathChanged(path:String):Void {
		for (root in roots) {
			var prefix = root.path == "/" ? "/" : root.path + "/";
			if (path == root.path || StringTools.startsWith(path, prefix)) dirtyRoots.set(root.id, true);
		}
	}

	function markAllRootsChanged():Void
		for (root in roots) dirtyRoots.set(root.id, true);

	function newWatchEpoch(rootId:String):String
		return Sha256.encode(workspace + ":" + clock() + ":" + Math.random() + ":" + rootId);

	static function readU32(bytes:Bytes, offset:Int):Int
		return bytes.get(offset) | bytes.get(offset + 1) << 8 | bytes.get(offset + 2) << 16 | bytes.get(offset + 3) << 24;

	static function eventPath(bytes:Bytes, offset:Int, length:Int):Null<String> {
		if (offset < 28 || length < 0 || offset > bytes.length || length >= bytes.length - offset
			|| bytes.get(offset + length) != 0) return null;
		return bytes.getString(offset, length);
	}

	function stopWatcher():Void {
		if (eventSubscription != null) eventSubscription.dispose();
		eventSubscription = null;
		if (fileWatch != null) fileWatch.close();
		fileWatch = null;
	}

	public function bind(connection:RpcConnection, capabilities:Array<String>):Void->Void {
		return new WorkspaceFileBinding(this, connection, capabilities).start();
	}

	function readSnapshot(rootId:String, path:String):FileListSnapshot {
		var directory = rootHandle(rootId).openDirectory(path);
		var entries:Array<WorkspaceFileEntry> = [];
		var nameBytes = 0;
		try {
			while (true) {
				var item = directory.next();
				if (item == null)
					break;
				if (entries.length >= MAX_SNAPSHOT_ENTRIES)
					throw "workspace_list_limit";
				if (item.name != null)
					nameBytes += Bytes.ofString(item.name).length;
				if (nameBytes > MAX_SNAPSHOT_NAME_BYTES)
					throw "workspace_list_limit";
				entries.push(metadata(workspace, rootId, item.name, item.metadata));
			}
		} catch (error:Dynamic) {
			directory.close();
			throw error;
		}
		directory.close();
		entries.sort(compareEntries);
		var revisionMaterial = new StringBuf();
		addHashField(revisionMaterial, workspace);
		addHashField(revisionMaterial, rootId);
		addHashField(revisionMaterial, path);
		for (entry in entries) {
			addHashField(revisionMaterial, entry.name == null ? "" : entry.name);
			addHashField(revisionMaterial, entry.kind);
			addHashField(revisionMaterial, Int64.toStr(entry.size));
			addHashField(revisionMaterial, Int64.toStr(entry.modifiedUnixNs));
			addHashField(revisionMaterial, Int64.toStr(entry.fileIdHigh));
			addHashField(revisionMaterial, Int64.toStr(entry.fileIdLow));
			addHashField(revisionMaterial, entry.revision);
			addHashField(revisionMaterial, entry.nameUnsupported ? "1" : "0");
		}
		var now = clock();
		var id = Sha256.encode(revisionMaterial.toString() + ":" + now + ":" + Math.random());
		return {id: id, root: rootId, path: path, revision: Sha256.encode(revisionMaterial.toString()), entries: entries, lastUsed: now};
	}

	static function addHashField(output:StringBuf, value:String):Void {
		output.add(Bytes.ofString(value).length);
		output.add(":");
		output.add(value);
	}

	function page(snapshot:FileListSnapshot, offset:Int, limit:Int,
		makeCursor:FileListSnapshot->Int->String):FileListPage {
		var end = Std.int(Math.min(snapshot.entries.length, offset + limit));
		var next:Null<String> = end < snapshot.entries.length ? makeCursor(snapshot, end) : null;
		return {
			workspace: workspace,
			root: snapshot.root,
			path: snapshot.path,
			directoryRevision: snapshot.revision,
			entries: snapshot.entries.slice(offset, end),
			next: next
		};
	}

	static function metadata(workspace:String, root:String, name:Null<String>, entry:FileSystemEntry):WorkspaceFileEntry {
		var kind = switch entry.get_kind() {
			case 1: "file";
			case 2: "directory";
			case 3: "symlink";
			case _: "other";
		};
		return {
			name: name,
			kind: kind,
			size: entry.get_size(),
			modifiedUnixNs: entry.get_modified_unix_ns(),
			fileIdHigh: entry.get_file_id_high(),
			fileIdLow: entry.get_file_id_low(),
			nameUnsupported: entry.get_name_unsupported() != 0,
			revision: fileRevision(workspace, root, entry)
		};
	}

	static function fileRevision(workspace:String, root:String, entry:FileSystemEntry):String {
		var revision = new StringBuf();
		addHashField(revision, workspace);
		addHashField(revision, root);
		addHashField(revision, Std.string(entry.get_kind()));
		addHashField(revision, Int64.toStr(entry.get_size()));
		addHashField(revision, Int64.toStr(entry.get_modified_unix_ns()));
		addHashField(revision, Int64.toStr(entry.get_changed_unix_ns()));
		addHashField(revision, Int64.toStr(entry.get_file_id_high()));
		addHashField(revision, Int64.toStr(entry.get_file_id_low()));
		return Sha256.encode(revision.toString());
	}

	function validRef(requestWorkspace:Null<String>, requestRoot:Null<String>):Bool
		return requestWorkspace == null || requestRoot == null ? false
			: requestWorkspace.length > 0 && requestWorkspace.length <= 128 && requestWorkspace == workspace
				&& rootsById.exists(requestRoot);

	function rootHandle(rootId:String):FileSystemRoot {
		var root = rootsById.get(rootId);
		if (root == null)
			throw "Unknown workspace filesystem root";
		return root.handle;
	}

	function validPath(path:Null<String>):Bool {
		if (path == null)
			return false;
		var bytes = Bytes.ofString(path);
		if (bytes.length > 32768)
			return false;
		for (index in 0...bytes.length)
			if (bytes.get(index) == 0)
				return false;
		if (path.length == 0)
			return true;
		var first = path.charCodeAt(0);
		if (path.length >= 2 && path.charAt(1) == ":"
			&& (first >= 65 && first <= 90 || first >= 97 && first <= 122))
			return false;
		if (path.charAt(0) == "/" || path.charAt(path.length - 1) == "/" || path.indexOf("\\") >= 0)
			return false;
		for (component in path.split("/"))
			if (component.length == 0 || component == "." || component == "..")
				return false;
		return true;
	}

	static function nativeResult(error:Dynamic):Null<Result> {
		try {
			var value:Dynamic = Reflect.field(error, "result");
			return value == null ? null : cast value;
		} catch (_:Dynamic)
			return null;
	}

	static function fileErrorResult(result:Result):RpcError {
		var code = switch result {
			case Result.ErrorNotFound: "not_found";
			case Result.ErrorPermissionDenied: "permission_denied";
			case Result.ErrorInvalidArgument: "invalid_path";
			case Result.ErrorUnsupported: "unsupported";
			case _: "file_unavailable";
		};
		return {code: code, message: "Workspace file operation failed", ambiguous: false};
	}

	static function compareEntries(a:WorkspaceFileEntry, b:WorkspaceFileEntry):Int {
		var aDirectory = a.kind == "directory", bDirectory = b.kind == "directory";
		if (aDirectory != bDirectory)
			return aDirectory ? -1 : 1;
		if (a.name == null && b.name != null)
			return 1;
		if (a.name != null && b.name == null)
			return -1;
		if (a.name != null && b.name != null) {
			var byName = compareUtf8(a.name, b.name);
			if (byName != 0)
				return byName;
		}
		var byDevice = Reflect.compare(Int64.toStr(a.fileIdHigh), Int64.toStr(b.fileIdHigh));
		return byDevice != 0 ? byDevice : Reflect.compare(Int64.toStr(a.fileIdLow), Int64.toStr(b.fileIdLow));
	}

	static function compareUtf8(a:String, b:String):Int {
		var aBytes = Bytes.ofString(a);
		var bBytes = Bytes.ofString(b);
		var count = Std.int(Math.min(aBytes.length, bBytes.length));
		for (index in 0...count) {
			var difference = aBytes.get(index) - bBytes.get(index);
			if (difference != 0)
				return difference;
		}
		return aBytes.length - bBytes.length;
	}

	static function displayName(path:String):String {
		if (path == null || path.length == 0)
			return "Workspace";
		var normalized = StringTools.replace(path, "\\", "/").split("/");
		var index = normalized.length;
		while (index > 0) {
			index--;
			if (normalized[index].length > 0)
				return normalized[index];
		}
		return "Workspace";
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		stopWatcher();
		for (root in roots)
			root.handle.close();
	}
}
