package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import terminalkit.Emulator;
import workspace.service.TerminalSnapshotPages;
import workspace.service.WorkspaceTerminalProtocol;

/** Screen snapshots of real-shaped output: taken, served in pages and restored into a fresh emulator. */
class TerminalSnapshotTests {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static function sameScreen(a:Emulator, b:Emulator):Bool {
		if (a.columns() != b.columns() || a.rows() != b.rows()) return false;
		a.snapshot(); b.snapshot();
		for (row in 0...a.rows()) {
			var ac = a.rowCells(row), bc = b.rowCells(row);
			for (column in 0...ac.length)
				if (ac[column].text != bc[column].text || ac[column].width != bc[column].width || ac[column].style != bc[column].style) {
					Sys.println('cell $row:$column [${ac[column].text}]/[${bc[column].text}] width ${ac[column].width}/${bc[column].width}');
					return false;
				}
		}
		var ac = a.cursor(), bc = b.cursor();
		return ac.column == bc.column && ac.row == bc.row && ac.mode == bc.mode;
	}

	static function int(value:Null<Int>):Int return value == null ? -1 : value;

	public static function run():Void {
		// The user's window: 277 x 65 cells of Claude Code output.
		var source = Emulator.open(277, 65, 1000, "xterm-256color", false);
		source.feedString(ClaudeScreen.history(3));
		source.feedString(ClaudeScreen.frame(277, 65, 1));
		var shot = source.screenSnapshot();
		require(shot.length > 262144 && shot.length <= 3 * 1024 * 1024,
			"Claude Code screen snapshot size " + shot.length + " no longer exceeds one RPC message");
		var copy = Emulator.open(80, 24, 1000, "xterm-256color", false);
		copy.restoreScreenSnapshot(shot);
		require(sameScreen(source, copy), "Restored Claude Code screen differs");
		copy.close();

		// A wide character in the last column leaves the cursor past the grid; the snapshot must still restore.
		for (input in ["\x1b[999C🤖", "\x1b[?7l\x1b[999C\x1b[?1049h日本語"]) {
			var edge = Emulator.open(47, 5, 1000, "xterm-256color", false);
			edge.feedString(input);
			var restored = Emulator.open(10, 3, 8, "xterm-256color", false);
			try restored.restoreScreenSnapshot(edge.screenSnapshot()) catch (failure:Dynamic)
				throw "Snapshot with a wide character in the last column did not restore: " + Std.string(failure);
			restored.snapshot(); edge.snapshot();
			require(restored.rowText(0) == edge.rowText(0), "Last-column wide character was not restored");
			restored.close(); edge.close();
		}

		// Pages reassemble the snapshot exactly; a finished or replaced snapshot cannot be read again.
		var pair = MemoryTransport.pair(), clock = function() return Sys.time() * 1000;
		var viewer = new RpcConnection(pair.server, clock), other = new RpcConnection(MemoryTransport.pair().server, clock);
		var pages = new TerminalSnapshotPages();
		var info:TerminalInfo = {id: "t", cwd: "/", state: "running", exitCode: 0, columns: 277, rows: 65, start: 0, end: 10};
		var first = pages.start(viewer, "t", shot, info, 7, 0);
		require(int(first.token) > 0 && int(first.offset) == 0 && int(first.total) == shot.length && first.cursor == 7
			&& first.data.length == TerminalSnapshotPages.PAGE_BYTES, "First page is wrong");
		require(pages.next(other, "t", int(first.token), first.data.length, 0) == null, "Another viewer read the snapshot");
		require(pages.next(viewer, "t", int(first.token), 1, 0) == null, "Unaligned page offset was served");
		var joined = Bytes.alloc(shot.length);
		joined.blit(0, first.data, 0, first.data.length);
		var offset = first.data.length;
		while (offset < shot.length) {
			var page = pages.next(viewer, "t", int(first.token), offset, 1);
			if (page == null) throw "Page missing at " + offset;
			require(int(page.offset) == offset && page.cursor == 7, "Page wrong at " + offset);
			joined.blit(offset, page.data, 0, page.data.length);
			offset += page.data.length;
		}
		require(joined.compare(shot) == 0, "Pages did not reassemble the snapshot");
		require(pages.next(viewer, "t", int(first.token), TerminalSnapshotPages.PAGE_BYTES, 1) == null, "Finished snapshot kept");
		// Two views of one terminal on one connection read their own snapshots side by side.
		var one = pages.start(viewer, "t", shot, info, 7, 2), two = pages.start(viewer, "t", shot, info, 8, 2);
		require(pages.next(viewer, "t", int(one.token), TerminalSnapshotPages.PAGE_BYTES, 2) != null
			&& pages.next(viewer, "t", int(two.token), TerminalSnapshotPages.PAGE_BYTES, 2) != null, "A second snapshot replaced the first");
		// One connection asking again and again pushes out only its own snapshots, never another connection's.
		var others = pages.start(other, "t", shot, info, 9, 3);
		for (_ in 0...8) pages.start(viewer, "t", shot, info, 9, 3);
		require(pages.next(viewer, "t", int(one.token), 2 * TerminalSnapshotPages.PAGE_BYTES, 3) == null, "Snapshots are unbounded");
		require(pages.next(other, "t", int(others.token), TerminalSnapshotPages.PAGE_BYTES, 3) != null,
			"One connection's snapshots pushed out another's");
		var idle = pages.start(viewer, "t", shot, info, 9, 4);
		pages.prune(100);
		require(pages.next(viewer, "t", int(idle.token), TerminalSnapshotPages.PAGE_BYTES, 100) == null, "Idle snapshot kept");
		var small = pages.start(viewer, "t", Bytes.alloc(100), info, 1, 5);
		require(int(small.token) == 0 && int(small.total) == 100 && small.data.length == 100, "Single-page snapshot was kept");
		viewer.close(); other.close();
		source.close();
		Sys.println("PASS: 277x65 Claude Code screen snapshot (" + shot.length + " bytes) restores exactly and is served in pages");
	}

	/** The service at production message limits: a 277x65 terminal's snapshot only arrives in pages. */
	public static function service(root:String):Void {
		var clock = function() return Sys.time() * 1000;
		var manager = new workspace.runtime.WorkspaceTerminalManager("w", "instance", root, 65536);
		var pair = MemoryTransport.pair();
		var client = new RpcConnection(pair.client, clock, 262144, 32, 1048576);
		var server = new RpcConnection(pair.server, clock, 262144, 32, 1048576);
		manager.bind(server, [WorkspaceTerminalProtocol.READ, WorkspaceTerminalProtocol.CONTROL]);
		var step = function() { client.poll(); server.poll(); manager.poll(); client.poll(); };
		var opened = false;
		client.call(WorkspaceTerminalProtocol.OPEN, {workspace: "w", instance: "instance", id: "wide", create: true,
			columns: 277, rows: 65}, 2000, function(_) opened = true, function(e) throw e.code);
		var deadline = clock() + 5000;
		while (!opened) { require(clock() < deadline, "Wide terminal did not open"); step(); }
		// The whole snapshot in one reply, as older clients ask: more than one message can carry.
		var legacy = "";
		client.call(WorkspaceTerminalProtocol.SNAPSHOT, {workspace: "w", instance: "instance", id: "wide"}, 2000,
			function(_) legacy = "answered", function(e) legacy = e.code);
		while (legacy == "") { require(clock() < deadline, "Legacy snapshot timed out"); step(); }
		require(legacy == "snapshot_unavailable", "A snapshot larger than one message was answered whole: " + legacy);
		var parts:Array<Bytes> = [];
		var token = 0, offset = 0, total = -1, failure = "";
		var next:Void->Void = null;
		next = function() client.call(WorkspaceTerminalProtocol.SNAPSHOT, {workspace: "w", instance: "instance", id: "wide",
			token: token, offset: offset}, 2000, function(page) {
				if (parts.length == 0) { total = int(page.total); token = int(page.token); }
				parts.push(page.data);
				offset += page.data.length;
				if (offset < total) next();
			}, function(e) failure = e.code);
		next();
		while (failure == "" && (total < 0 || offset < total)) { require(clock() < deadline, "Paged snapshot timed out"); step(); }
		require(failure == "" && total > 262144 && token > 0 && offset == total, "Paged snapshot failed: " + failure + " total " + total);
		var data = Bytes.alloc(total), at = 0;
		for (part in parts) { data.blit(at, part, 0, part.length); at += part.length; }
		var restored = Emulator.open(10, 3, 8, "xterm-256color", false);
		restored.restoreScreenSnapshot(data);
		require(restored.columns() == 277 && restored.rows() == 65, "Paged snapshot restored the wrong grid");
		restored.close();
		manager.dispose(); client.close(); server.close();
		Sys.println("PASS: service serves a 277x65 terminal's " + total + "-byte snapshot in pages; one-reply snapshots report it unavailable");
	}
}
