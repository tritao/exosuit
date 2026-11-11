package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.RpcConnection;
import workspace.service.TerminalSnapshotPages;
import workspace.service.WorkspaceTerminalProtocol;

/**
	The SNAPSHOT method of the fake terminal servers in this suite.

	It serves a real empty-screen snapshot through the service's own TerminalSnapshotPages, so the paging, tokens and
	`snapshot_expired` answers match the daemon's. A client that falls back to a snapshot (after `replay_gap`, or from an
	older daemon) therefore gets an answer instead of `unknown_method`. A snapshot over one page is served in pages; the
	screen here is small, so `padding` appends ignorable bytes to make it span several (the client only checks sizes).
**/
class FakeTerminalSnapshots {
	/** Serves snapshots of `info()`'s terminal on `server`. */
	public static function register(server:RpcConnection, info:() -> TerminalInfo, padding:Int = 0):TerminalSnapshotPages {
		var pages = new TerminalSnapshotPages();
		server.register(WorkspaceTerminalProtocol.SNAPSHOT, function(q, ctx) {
			var now = Sys.time();
			pages.prune(now);
			var token = q.token == null ? 0 : q.token;
			if (token == 0) {
				var emulator = terminalkit.Emulator.open(80, 24);
				var screen = emulator.screenSnapshot();
				emulator.close();
				var data = padding > 0 ? Bytes.alloc(screen.length + padding) : screen;
				if (padding > 0) data.blit(0, screen, 0, screen.length);
				ctx.respond(pages.start(server, q.id, data, info(), Int64.ofInt(0), now));
				return;
			}
			var next = pages.next(server, q.id, token, q.offset == null ? 0 : q.offset, now);
			if (next == null) ctx.fail({code: "snapshot_expired", message: "The snapshot was dropped before it was read", ambiguous: false});
			else ctx.respond(next);
		});
		return pages;
	}
}
