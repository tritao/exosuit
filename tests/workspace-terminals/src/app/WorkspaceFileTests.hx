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
		Sys.println("PASS: workspace file root grants, stat, stable pagination, traversal refusal, cursor expiry and revocation");
	}
}
