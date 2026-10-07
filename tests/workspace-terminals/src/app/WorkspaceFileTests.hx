package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.filesystem.FileSystemRoot;
import sys.FileSystem;
import sys.io.File;
import workspace.runtime.WorkspaceFileService;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol;
import workspace.service.WorkspaceFileProtocol.FileListPage;
import workspace.service.WorkspaceFileProtocol.FileRootsResult;
import workspace.service.WorkspaceFileProtocol.FileStatResult;
import workspace.service.WorkspaceFileProtocol.FileReadOpenResult;
import workspace.service.WorkspaceFileProtocol.FileReadChunkResult;
import workspace.service.WorkspaceFileProtocol.FileReadCloseResult;
import workspace.service.WorkspaceFileProtocol.FileSearchPageResult;
import workspace.service.WorkspaceFileProtocol.FileSearchHandle;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;

class WorkspaceFileTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function poll(client:RpcConnection, server:RpcConnection):Void {
		try client.poll() catch (error:Dynamic) throw "Client RPC poll failed: " + Std.string(error);
		try server.poll() catch (error:Dynamic) throw "Server RPC poll failed: " + Std.string(error);
		try client.poll() catch (error:Dynamic) throw "Client RPC response poll failed: " + Std.string(error);
	}

	public static function run(parent:String):Void {
		var rootPath = parent + "/file-service-contract";
		var secondRootPath = parent + "/second-file-service-contract";
		FileSystem.createDirectory(rootPath);
		FileSystem.createDirectory(secondRootPath);
		FileSystem.createDirectory(rootPath + "/folder");
		FileSystem.createDirectory(secondRootPath + "/unicode-order");
		File.saveContent(rootPath + "/a.txt", "saved bytes");
		File.saveContent(rootPath + "/β.txt", "unicode name");
		var longLine = new StringBuf();
		for (_ in 0...1600) longLine.add("x");
		longLine.add("needle");
		File.saveContent(secondRootPath + "/search-utf8.txt", "Olá needle\nneedle twice needle\n");
		File.saveContent(secondRootPath + "/search-long-line.txt", longLine.toString());
		var denseLine = new StringBuf();
		for (_ in 0...1100) denseLine.add("z");
		File.saveContent(secondRootPath + "/search-dense.txt", denseLine.toString());
		var rawContent = Bytes.alloc(7);
		rawContent.set(0, 0x41);
		rawContent.set(1, 0x00);
		rawContent.set(2, 0xff);
		rawContent.set(3, 0xce);
		rawContent.set(4, 0xb2);
		rawContent.set(5, 0x0a);
		rawContent.set(6, 0x5a);
		File.saveBytes(secondRootPath + "/read.raw", rawContent);
		File.saveContent(rootPath + "/folder/Case.txt", "upper");
		File.saveContent(rootPath + "/folder/case.txt", "lower");
		File.saveContent(secondRootPath + "/unicode-order/\uE000.txt", "bmp");
		File.saveContent(secondRootPath + "/unicode-order/😀.txt", "supplementary");
		File.saveContent(secondRootPath + "/other.txt", "another root");
		var directRoot = new FileSystemRoot(rootPath), caughtNativeError = false;
		try
			directRoot.stat("missing-direct.txt")
		catch (_:Dynamic)
			caughtNativeError = true;
		directRoot.close();
		require(caughtNativeError, "Native filesystem errors were not catchable at the Haxe boundary");

		var now = 1000.0;
		var clock = function() return now;
		var service = new WorkspaceFileService("workspace", [rootPath, secondRootPath], clock);
		var pair = MemoryTransport.pair();
		var client = new RpcConnection(pair.client, clock);
		var server = new RpcConnection(pair.server, clock);
		var files = new WorkspaceFileClient(client);
		var revoke = service.bind(server, [WorkspaceFileProtocol.READ]);

		var roots:Null<FileRootsResult> = null;
		files.roots("workspace", function(value) roots = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (roots == null)
			throw "Workspace root discovery failed";
		var discovered = roots;
		require(discovered.workspace == "workspace" && discovered.roots.length == 2, "Workspace root discovery returned an invalid descriptor");
		require(discovered.roots[0].id == WorkspaceFileService.ROOT_ID && discovered.roots[0].name == "file-service-contract"
			&& discovered.roots[0].capabilities.indexOf("stat") >= 0 && discovered.roots[0].capabilities.indexOf("list") >= 0,
			"Root descriptor did not expose its scoped metadata operations");
		require(discovered.roots[1].id == WorkspaceFileService.ROOT_ID + "-1"
			&& discovered.roots[1].name == "second-file-service-contract", "Additional root identity was not service-assigned");
		require(discovered.roots[0].capabilities.indexOf("search") >= 0,
			"Workspace root did not advertise its bounded search operation");

		var emptySearch = "";
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "content", "", true,
			function(_) throw "Empty workspace search query was accepted", function(error) emptySearch = error.code, 1000);
		poll(client, server);
		require(emptySearch == "unsupported_query", "Invalid workspace search query returned an unexpected error");
		var multilineSearch = "";
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "content", "first\nsecond", true,
			function(_) throw "Multiline workspace search query was accepted", function(error) multilineSearch = error.code, 1000);
		poll(client, server);
		require(multilineSearch == "unsupported_query", "Unsupported multiline query returned an unexpected error");

		var searchHandle:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID + "-1", "content", "needle", true,
			function(value) searchHandle = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (searchHandle == null) throw "Workspace content search did not start";
		var contentSearch = searchHandle;
		var contentMatches:Array<FileSearchMatch> = [];
		var searchComplete = false, searchScannedFiles = 0, searchScannedBytes = 0, searchSkipped = 0, searchScannedEntries = 0;
		while (!searchComplete) {
			var page:Null<FileSearchPageResult> = null;
			files.searchPage("workspace", contentSearch.root, contentSearch.searchId, 1,
				function(value) page = value, function(error) throw error.code, 1000);
			poll(client, server);
			if (page == null) throw "Workspace content search page was missing";
			for (match in page.matches) contentMatches.push(match);
			searchComplete = page.complete;
			searchScannedFiles = page.scannedFiles;
			searchScannedBytes = page.scannedBytes;
			searchSkipped = page.skippedEntries;
			searchScannedEntries = page.scannedEntries;
		}
		var longLineMatch = false;
		var utf8Matches:Array<FileSearchMatch> = [];
		for (match in contentMatches) if (match.path == "search-long-line.txt")
			longLineMatch = match.column == 1600 && match.preview.length <= 514 && match.preview.indexOf("needle") >= 0;
		for (match in contentMatches) if (match.path == "search-utf8.txt") utf8Matches.push(match);
		require(contentMatches.length == 4 && longLineMatch && utf8Matches.length == 3
			&& utf8Matches[0].line == 0 && utf8Matches[0].column == 5
			&& utf8Matches[1].line == 1 && utf8Matches[1].column == 0
			&& utf8Matches[2].line == 1 && utf8Matches[2].column == 13
			&& utf8Matches[0].length == 6 && utf8Matches[0].revision.length > 0,
			"Workspace content search lost ordered matches or UTF-8 byte ranges");
		require(searchScannedFiles > 0 && searchScannedBytes > 0 && searchSkipped > 0 && searchScannedEntries > 0,
			"Workspace content search did not report bounded scan and binary-file skip progress");

		var insensitiveHandle:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID + "-1", "content", "NEEDLE", false,
			function(value) insensitiveHandle = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (insensitiveHandle == null) throw "Case-insensitive workspace search did not start";
		var insensitiveSearch = insensitiveHandle, insensitivePage:Null<FileSearchPageResult> = null;
		files.searchPage("workspace", insensitiveSearch.root, insensitiveSearch.searchId, 10,
			function(value) insensitivePage = value, function(error) throw error.code, 1000);
		poll(client, server);
		require(insensitivePage != null && insensitivePage.complete && insensitivePage.matches.length == 4,
			"Case-insensitive workspace content search returned the wrong matches");

		var nameHandle:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID + "-1", "name", "search-utf8", true,
			function(value) nameHandle = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (nameHandle == null) throw "Workspace name search did not start";
		var nameSearch = nameHandle, nameFound = false, nameSearchComplete = false;
		while (!nameSearchComplete) {
			var page:Null<FileSearchPageResult> = null;
			files.searchPage("workspace", nameSearch.root, nameSearch.searchId, 8,
				function(value) page = value, function(error) throw error.code, 1000);
			poll(client, server);
			if (page == null) throw "Workspace name search page was missing";
			for (match in page.matches) if (match.path == "search-utf8.txt" && match.kind == "file") nameFound = true;
			nameSearchComplete = page.complete;
		}
		require(nameFound, "Workspace name search did not return a root-relative matching path");

		var denseHandle:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID + "-1", "content", "z", true,
			function(value) denseHandle = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (denseHandle == null) throw "Dense workspace search did not start";
		var denseSearch = denseHandle, denseCount = 0, denseComplete = false, denseTruncated = false;
		while (!denseComplete) {
			var page:Null<FileSearchPageResult> = null;
			files.searchPage("workspace", denseSearch.root, denseSearch.searchId, 100,
				function(value) page = value, function(error) throw error.code, 1000);
			poll(client, server);
			if (page == null) throw "Dense workspace search page was missing";
			denseCount += page.matches.length;
			denseComplete = page.complete;
			denseTruncated = page.truncated;
		}
		require(denseCount == 1000 && denseTruncated,
			"Dense workspace search exceeded its result bound or did not report truncation");

		var cancelledHandle:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "never-match", true,
			function(value) cancelledHandle = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (cancelledHandle == null) throw "Cancellable workspace search did not start";
		var cancelledResult:Null<workspace.service.WorkspaceFileProtocol.FileSearchCancelResult> = null;
		files.searchCancel("workspace", cancelledHandle.root, cancelledHandle.searchId,
			function(value) cancelledResult = value, function(error) throw error.code, 1000);
		poll(client, server);
		require(cancelledResult != null && cancelledResult.cancelled, "Workspace search cancellation did not release its cursor");
		var cancelledPageError = "";
		files.searchPage("workspace", cancelledHandle.root, cancelledHandle.searchId, 1,
			function(_) throw "Cancelled workspace search remained available", function(error) cancelledPageError = error.code, 1000);
		poll(client, server);
		require(cancelledPageError == "invalid_handle", "Cancelled workspace search returned an unexpected handle result");

		var firstActive:Null<FileSearchHandle> = null, secondActive:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "first", true,
			function(value) firstActive = value, function(error) throw error.code, 1000);
		poll(client, server);
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "second", true,
			function(value) secondActive = value, function(error) throw error.code, 1000);
		poll(client, server);
		var thirdSearchError = "";
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "third", true,
			function(_) throw "Workspace service exceeded its active search bound", function(error) thirdSearchError = error.code, 1000);
		poll(client, server);
		require(firstActive != null && secondActive != null && thirdSearchError == "resource_limit",
			"Workspace service did not enforce its per-connection active search limit");
		if (firstActive == null || secondActive == null) throw "Bounded workspace searches were not created";
		var activeOne = firstActive, activeTwo = secondActive;
		files.searchCancel("workspace", activeOne.root, activeOne.searchId, function(_) {}, function(error) throw error.code, 1000);
		poll(client, server);
		var afterCancel:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "after-cancel", true,
			function(value) afterCancel = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (afterCancel == null) throw "Cancelling a search did not free a bounded search slot";
		var freedSlot = afterCancel;
		files.searchCancel("workspace", activeTwo.root, activeTwo.searchId, function(_) {}, function(error) throw error.code, 1000);
		poll(client, server);
		files.searchCancel("workspace", freedSlot.root, freedSlot.searchId, function(_) {}, function(error) throw error.code, 1000);
		poll(client, server);

		var stat:Null<FileStatResult> = null;
		var statError = "";
		files.stat("workspace", WorkspaceFileService.ROOT_ID, "a.txt",
			function(value) stat = value, function(error) statError = error.code + ":" + error.message, 1000);
		poll(client, server);
		if (stat == null)
			throw 'Root-relative stat failed: $statError';
		require(stat != null && stat.entry.kind == "file" && stat.entry.size == 11, "Root-relative stat returned incorrect file metadata");

		var rawStat:Null<FileStatResult> = null;
		client.call(WorkspaceFileProtocol.STAT,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID + "-1", path: "read.raw"}, 1000,
			function(value) rawStat = value, function(error) throw error.code);
		poll(client, server);
		if (rawStat == null)
			throw "Binary file stat failed";
		var opened:Null<FileReadOpenResult> = null;
		files.openRead("workspace", WorkspaceFileService.ROOT_ID + "-1", "read.raw", rawStat.entry.revision,
			function(value) opened = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (opened == null)
			throw "Revision-checked file open failed";
		var readHandle = opened;
		require(readHandle.size == Int64.ofInt(rawContent.length) && readHandle.revision == rawStat.entry.revision,
			"File open did not preserve the listed identity and byte size");
		var rawFirst:Null<FileReadChunkResult> = null;
		files.readChunk("workspace", readHandle.handle, Int64.ofInt(0), 3,
			function(value) rawFirst = value, function(error) throw error.code, 1000);
		poll(client, server);
		require(rawFirst != null && rawFirst.bytes.length == 3 && !rawFirst.eof
			&& rawFirst.bytes.get(0) == 0x41 && rawFirst.bytes.get(1) == 0x00 && rawFirst.bytes.get(2) == 0xff,
			"First byte chunk changed binary data or offsets");
		var rawLast:Null<FileReadChunkResult> = null;
		files.readChunk("workspace", readHandle.handle, Int64.ofInt(3), 4,
			function(value) rawLast = value, function(error) throw error.code, 1000);
		poll(client, server);
		require(rawLast != null && rawLast.bytes.length == 4 && rawLast.eof
			&& rawLast.bytes.get(0) == 0xce && rawLast.bytes.get(1) == 0xb2
			&& rawLast.bytes.get(2) == 0x0a && rawLast.bytes.get(3) == 0x5a,
			"Second byte chunk did not preserve raw UTF-8 and EOF");
		for (offsetAndLength in [{offset: Int64.ofInt(-1), length: 1},
			{offset: Int64.ofInt(0), length: 262145}, {offset: Int64.ofInt(8), length: 1}]) {
			var invalidRange = "";
			client.call(WorkspaceFileProtocol.READ_CHUNK,
				{workspace: "workspace", handle: readHandle.handle, offset: offsetAndLength.offset, length: offsetAndLength.length}, 1000,
				function(_) throw "Invalid byte range was accepted", function(error) invalidRange = error.code);
			poll(client, server);
			require(invalidRange == "invalid_range", "Invalid read range returned an unexpected error");
		}
		var closed:Null<FileReadCloseResult> = null;
		files.closeRead("workspace", readHandle.handle,
			function(value) closed = value, function(error) throw error.code, 1000);
		poll(client, server);
		require(closed != null && closed.closed, "File read handle did not close");
		var closedAgain:Null<FileReadCloseResult> = null;
		client.call(WorkspaceFileProtocol.READ_CLOSE,
			{workspace: "workspace", handle: readHandle.handle}, 1000,
			function(value) closedAgain = value, function(error) throw error.code);
		poll(client, server);
		require(closedAgain != null && !closedAgain.closed, "Closing an unknown handle disclosed or recreated its state");

		var foreignPair = MemoryTransport.pair();
		var foreignClient = new RpcConnection(foreignPair.client, clock);
		var foreignServer = new RpcConnection(foreignPair.server, clock);
		var revokeForeign = service.bind(foreignServer, [WorkspaceFileProtocol.READ]);
		var foreignHandle = "";
		foreignClient.call(WorkspaceFileProtocol.READ_CHUNK,
			{workspace: "workspace", handle: readHandle.handle, offset: Int64.ofInt(0), length: 1}, 1000,
			function(_) throw "Another connection reused a file read handle", function(error) foreignHandle = error.code);
		poll(foreignClient, foreignServer);
		require(foreignHandle == "invalid_handle", "Read handle ownership was not bound to its connection");
		var privateSearch:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "private-search", true,
			function(value) privateSearch = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (privateSearch == null) throw "Connection-scoped workspace search did not start";
		var ownedSearch = privateSearch, foreignSearchError = "";
		foreignClient.call(WorkspaceFileProtocol.SEARCH_PAGE,
			{workspace: "workspace", root: ownedSearch.root, searchId: ownedSearch.searchId, limit: 1}, 1000,
			function(_) throw "Another connection reused a workspace search handle", function(error) foreignSearchError = error.code);
		poll(foreignClient, foreignServer);
		require(foreignSearchError == "invalid_handle", "Workspace search handle ownership was not bound to its connection");
		files.searchCancel("workspace", ownedSearch.root, ownedSearch.searchId, function(_) {}, function(error) throw error.code, 1000);
		poll(client, server);
		revokeForeign();
		foreignClient.close();
		foreignServer.close();

		var secondRootStat:Null<FileStatResult> = null;
		client.call(WorkspaceFileProtocol.STAT,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID + "-1", path: "other.txt"}, 1000,
			function(value) secondRootStat = value, function(error) throw error.code);
		poll(client, server);
		require(secondRootStat != null && secondRootStat.root == WorkspaceFileService.ROOT_ID + "-1"
			&& secondRootStat.entry.size == 12, "Stat did not stay within the selected authorized root");

		var cases:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "folder", limit: 2, cursor: null}, 1000,
			function(value) cases = value, function(error) throw error.code);
		poll(client, server);
		require(cases != null && cases.entries.length == 2 && cases.entries[0].name == "Case.txt"
			&& cases.entries[1].name == "case.txt" && cases.next == null,
			"Directory listing changed filename case or failed exact ordering");

		var unicodeOrder:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID + "-1", path: "unicode-order", limit: 2, cursor: null}, 1000,
			function(value) unicodeOrder = value, function(error) throw error.code);
		poll(client, server);
		require(unicodeOrder != null && unicodeOrder.entries.length == 2
			&& unicodeOrder.entries[0].name == "\uE000.txt" && unicodeOrder.entries[1].name == "😀.txt",
			"Directory entries were not ordered by their exact UTF-8 names");

		var first:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: null}, 1000,
			function(value) first = value, function(error) throw error.code);
		poll(client, server);
		if (first == null)
			throw "Initial directory page was missing";
		var pageOne = first;
		require(pageOne.entries.length == 1 && pageOne.entries[0].name == "folder" && pageOne.next != null,
			"Directory listing did not page directories first");
		if (pageOne.next == null)
			throw "Initial directory cursor was missing";
		var cursorOne = pageOne.next;
		File.saveContent(rootPath + "/new-after-snapshot.txt", "new entry");
		var wrongRootCursor = "";
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID + "-1", path: "", limit: 1, cursor: cursorOne}, 1000,
			function(_) throw "A cursor crossed between authorized roots", function(error) wrongRootCursor = error.code);
		poll(client, server);
		require(wrongRootCursor == "cursor_expired", "Directory cursor was not bound to its root");

		var second:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: pageOne.next}, 1000,
			function(value) second = value, function(error) throw error.code);
		poll(client, server);
		if (second == null)
			throw "Second directory page was missing";
		var pageTwo = second;
		require(pageTwo.entries[0].name == "a.txt" && pageTwo.directoryRevision == pageOne.directoryRevision,
			"Directory cursor did not retain one ordered listing revision");
		if (pageTwo.next == null)
			throw "Second directory cursor was missing";
		var cursorTwo = pageTwo.next;

		var repeated:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: cursorOne}, 1000,
			function(value) repeated = value, function(error) throw error.code);
		poll(client, server);
		require(repeated != null && repeated.entries[0].name == pageTwo.entries[0].name && repeated.next == pageTwo.next,
			"Retrying a page cursor changed its response");

		var third:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: cursorTwo}, 1000,
			function(value) third = value, function(error) throw error.code);
		poll(client, server);
		require(third != null && third.entries[0].name == "β.txt" && third.next == null,
			"UTF-8 filename was lost from the paginated listing");

		var refreshed:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 32, cursor: null}, 1000,
			function(value) refreshed = value, function(error) throw error.code);
		poll(client, server);
		require(refreshed != null && refreshed.directoryRevision != pageOne.directoryRevision
			&& Lambda.exists(refreshed.entries, function(entry) return entry.name == "new-after-snapshot.txt"),
			"Fresh listing did not reflect a directory change after the immutable snapshot");

		for (path in ["../outside", "/etc/passwd", "C:/outside", "nested//file", "nested/."]) {
			var invalidPath = "";
			client.call(WorkspaceFileProtocol.STAT,
				{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: path}, 1000,
				function(_) throw 'Workspace file service accepted invalid path "$path"', function(error) invalidPath = error.code);
			poll(client, server);
			require(invalidPath == "invalid_path", 'Invalid path "$path" returned unexpected error code "$invalidPath"');
		}

		var missing = "";
		client.call(WorkspaceFileProtocol.STAT,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "missing.txt"}, 1000,
			function(_) throw "Workspace file service reported a missing file as present", function(error) missing = error.code);
		poll(client, server);
		require(missing == "not_found", 'Missing file returned unexpected error code "$missing"');

		File.saveContent(rootPath + "/changing.txt", "before");
		var changingStat:Null<FileStatResult> = null;
		client.call(WorkspaceFileProtocol.STAT,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "changing.txt"}, 1000,
			function(value) changingStat = value, function(error) throw error.code);
		poll(client, server);
		if (changingStat == null)
			throw "Changing file stat failed";
		var changingOpen:Null<FileReadOpenResult> = null;
		client.call(WorkspaceFileProtocol.READ_OPEN,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "changing.txt",
				expectedRevision: changingStat.entry.revision}, 1000,
			function(value) changingOpen = value, function(error) throw error.code);
		poll(client, server);
		if (changingOpen == null)
			throw "Changing file open failed";
		Sys.sleep(0.01);
		File.saveContent(rootPath + "/changing.txt", "after!");
		var changedDuringRead = "";
		client.call(WorkspaceFileProtocol.READ_CHUNK,
			{workspace: "workspace", handle: changingOpen.handle, offset: Int64.ofInt(0), length: 4}, 1000,
			function(_) throw "Read handle mixed bytes after its file revision changed",
			function(error) changedDuringRead = error.code);
		poll(client, server);
		require(changedDuringRead == "revision_changed", "Concurrent same-size write was not reported as revision_changed");
		var staleOpen = "";
		client.call(WorkspaceFileProtocol.READ_OPEN,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "changing.txt",
				expectedRevision: changingStat.entry.revision}, 1000,
			function(_) throw "Read open accepted a stale expected revision", function(error) staleOpen = error.code);
		poll(client, server);
		require(staleOpen == "revision_changed", "Stale expected revision was not rejected");

		var expiring:Null<FileListPage> = null;
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: null}, 1000,
			function(value) expiring = value, function(error) throw error.code);
		poll(client, server);
		if (expiring == null || expiring.next == null)
			throw "Expiring directory cursor was missing";
		var expiringCursor = expiring.next;
		var expiringRead:Null<FileReadOpenResult> = null;
		client.call(WorkspaceFileProtocol.READ_OPEN,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "a.txt", expectedRevision: null}, 1000,
			function(value) expiringRead = value, function(error) throw error.code);
		poll(client, server);
		if (expiringRead == null)
			throw "Expiring file read handle was missing";
		var expiringSearch:Null<FileSearchHandle> = null;
		files.searchStart("workspace", WorkspaceFileService.ROOT_ID, "name", "expiry-search", true,
			function(value) expiringSearch = value, function(error) throw error.code, 1000);
		poll(client, server);
		if (expiringSearch == null) throw "Expiring workspace search was missing";
		var idleSearch = expiringSearch;
		now += 31000;
		var expiredRead = "";
		client.call(WorkspaceFileProtocol.READ_CHUNK,
			{workspace: "workspace", handle: expiringRead.handle, offset: Int64.ofInt(0), length: 1}, 1000,
			function(_) throw "Expired file read handle was accepted", function(error) expiredRead = error.code);
		poll(client, server);
		require(expiredRead == "invalid_handle", "Idle file read handle expiry was not explicit");
		var expired = "";
		client.call(WorkspaceFileProtocol.LIST,
			{workspace: "workspace", root: WorkspaceFileService.ROOT_ID, path: "", limit: 1, cursor: expiringCursor}, 1000,
			function(_) throw "Expired workspace cursor was accepted", function(error) expired = error.code);
		poll(client, server);
		require(expired == "cursor_expired", "Idle cursor expiry was not explicit");
		var expiredSearch = "";
		files.searchPage("workspace", idleSearch.root, idleSearch.searchId, 1,
			function(_) throw "Expired workspace search was accepted", function(error) expiredSearch = error.code, 1000);
		poll(client, server);
		require(expiredSearch == "invalid_handle", "Idle workspace search expiry was not explicit");

		var deniedPair = MemoryTransport.pair();
		var deniedClient = new RpcConnection(deniedPair.client, clock);
		var deniedServer = new RpcConnection(deniedPair.server, clock);
		var revokeDenied = service.bind(deniedServer, []);
		var denied = "";
		deniedClient.call(WorkspaceFileProtocol.ROOTS, {workspace: "workspace"}, 1000,
			function(_) throw "Peer without a file grant discovered roots", function(error) denied = error.code);
		poll(deniedClient, deniedServer);
		require(denied == "unauthorized", "File read capability was not enforced");

		revoke();
		var revoked = "";
		client.call(WorkspaceFileProtocol.ROOTS, {workspace: "workspace"}, 1000,
			function(_) throw "Revoked peer retained file access", function(error) revoked = error.code);
		poll(client, server);
		require(revoked == "unauthorized", "Per-connection file grant revocation failed");
		revokeDenied();
		client.close();
		server.close();
		deniedClient.close();
		deniedServer.close();
		service.dispose();
		Sys.println("PASS: workspace file/search grants, stable paging, UTF-8 locations, search limits/cancellation, expiry and revocation");
	}
}
