package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceTerminalProtocol;

private typedef StoredSnapshot = {
	var viewer:RpcConnection;
	var terminal:String;
	var token:Int;
	var data:Bytes;
	var info:TerminalInfo;
	var cursor:Null<Int64>;
	var touched:Float;
}

/**
	Serves terminal screen snapshots in pages that fit any connection's message limit.

	A large grid's snapshot does not fit one RPC message (a 277x65 screen is about 300 KB; local connections carry
	256 KiB and remote ones under 64 KiB). The service keeps the snapshot it took, with the terminal info and replay
	cursor of that moment, and the viewer reads the rest page by page. Several views of one terminal on one
	connection read their own snapshots, so a new snapshot never replaces another. Each connection keeps at most
	PER_VIEWER snapshots, so one viewer asking again and again only pushes out its own oldest; past TOTAL the oldest
	snapshot of the connection holding the most goes, so a connection with few is never pushed out by one with many.
**/
class TerminalSnapshotPages {
	/** A page and the terminal info beside it fit a remote (Noise) message. */
	public static inline final PAGE_BYTES = 32 * 1024;
	static inline final PER_VIEWER = 4;
	static inline final TOTAL = 16;
	static inline final IDLE_SECONDS = 30.0;

	final stored:Array<StoredSnapshot> = [];
	var lastToken = 0;

	public function new() {}

	/** The first page of a snapshot just taken; keeps the rest for `next`. */
	public function start(viewer:RpcConnection, terminal:String, data:Bytes, info:TerminalInfo, cursor:Null<Int64>,
			now:Float):TerminalScreenSnapshot {
		if (data.length <= PAGE_BYTES)
			return page(0, data, info, cursor, 0);
		if (count(viewer) >= PER_VIEWER) evictOldest(viewer);
		else if (stored.length >= TOTAL) evictOldest(largestViewer(viewer));
		lastToken = lastToken >= 0x3fffffff ? 1 : lastToken + 1;
		stored.push({viewer: viewer, terminal: terminal, token: lastToken, data: data, info: info, cursor: cursor, touched: now});
		return page(lastToken, data, info, cursor, 0);
	}

	/** The page at `offset` of a kept snapshot, or null once it was read to the end, evicted or expired. */
	public function next(viewer:RpcConnection, terminal:String, token:Int, offset:Int, now:Float):Null<TerminalScreenSnapshot> {
		for (entry in stored) {
			if (entry.viewer != viewer || entry.terminal != terminal || entry.token != token) continue;
			if (offset <= 0 || offset >= entry.data.length || offset % PAGE_BYTES != 0) return null;
			entry.touched = now;
			if (offset + PAGE_BYTES >= entry.data.length) stored.remove(entry);
			return page(entry.token, entry.data, entry.info, entry.cursor, offset);
		}
		return null;
	}

	/** Drops snapshots of closed connections and of viewers that stopped reading. */
	public function prune(now:Float):Void {
		for (entry in stored.copy())
			if (!entry.viewer.isOpen() || now - entry.touched >= IDLE_SECONDS) stored.remove(entry);
	}

	public function clear():Void stored.resize(0);

	function count(viewer:RpcConnection):Int {
		var n = 0;
		for (entry in stored) if (entry.viewer == viewer) n++;
		return n;
	}

	/** The connection keeping the most snapshots; `viewer` itself when it keeps as many as any other. */
	function largestViewer(viewer:RpcConnection):RpcConnection {
		var largest = viewer, most = count(viewer);
		for (entry in stored) {
			var n = count(entry.viewer);
			if (n > most) { largest = entry.viewer; most = n; }
		}
		return largest;
	}

	function evictOldest(viewer:RpcConnection):Void {
		for (entry in stored)
			if (entry.viewer == viewer) { stored.remove(entry); return; }
	}

	static function page(token:Int, data:Bytes, info:TerminalInfo, cursor:Null<Int64>, offset:Int):TerminalScreenSnapshot {
		var size = data.length - offset < PAGE_BYTES ? data.length - offset : PAGE_BYTES;
		return {terminal: info, data: data.sub(offset, size), cursor: cursor, token: token, offset: offset, total: data.length};
	}
}
