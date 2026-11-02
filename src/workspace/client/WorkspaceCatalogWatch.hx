package workspace.client;

import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcPeerOptions;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogChange;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;

/**
	A watch on one workspace service's catalog: one connection that carries only CATALOG, UNWATCH and CHANGED, no
	session or terminal content. It reads the catalog in pages, applies resets and deltas to `mirror`, and reads again
	when CHANGED names a token other than its own. The connection reconnects with backoff (RpcClient's fencing); after a
	reconnect it resumes from its last token, and the service answers with a reset if it no longer knows it.

	A read is bounded: at most MAX_PAGES pages and MAX_ITEMS items and folders, and a `more` page must move the token.
	A read that breaks a bound, fails or times out is retried after a delay that doubles from RETRY_MIN_MS to
	RETRY_MAX_MS and starts over after a read succeeds.
**/
class WorkspaceCatalogWatch {
	static inline final CALL_TIMEOUT = 5000;
	public static inline final RETRY_MIN_MS = 1000.0;
	public static inline final RETRY_MAX_MS = 30000.0;
	/** Groups, sessions, terminals and folders one copy may hold. */
	public static inline final MAX_ITEMS = 20000;
	/** Pages one read may take before the service is taken to be looping: enough for MAX_ITEMS at the service's page size, plus slack. */
	public static final MAX_PAGES = Std.int(MAX_ITEMS / WorkspaceCatalogProtocol.PAGE_LIMIT) + 32;
	/** How long a disposed watch waits for the service to answer UNWATCH before it closes anyway. */
	public static inline final LINGER_MS = 500.0;
	/** How long a watch that is not live counts as starting or reconnecting (the window then asks suit more often). */
	public static inline final TRYING_MS = 15000.0;

	public final ref:WorkspaceRef;
	/** The last complete copy; a reset is built aside and replaces it only when its last page arrives. */
	public var mirror(default, null):WorkspaceCatalogMirror = new WorkspaceCatalogMirror();
	/** True while connected with a complete copy. A dropped connection keeps `mirror` and clears this. */
	public var live(default, null):Bool = false;
	/** Why the last read failed or the watch ended; null after a read succeeds. */
	public var error(default, null):Null<String>;
	/** Changes whenever `mirror`, `live` or `error` does. */
	public var revision(default, null):Int = 0;
	/** Pages answered: tests and measurements count them. */
	public var reads(default, null):Int = 0;
	/** CHANGED hints that caused no read because the token was ours. */
	public var skipped(default, null):Int = 0;
	/** The delay a failed read waits now; it doubles per failure. */
	public var retryDelay(default, null):Float = RETRY_MIN_MS;

	final client:RpcClient;
	final clock:Void->Float;
	var connection:Null<RpcConnection>;
	var staging:Null<WorkspaceCatalogMirror>;
	var reading = false;
	var dirty = false;
	var retryAt:Float = 0;
	var closed = false;
	var retiring = false;
	var answered = false;
	var lingerUntil:Float = 0;
	var pages = 0;
	var downSince:Float;

	public function new(ref:WorkspaceRef, connector:RpcConnector, clock:Void->Float, random:Void->Float) {
		this.ref = ref;
		this.clock = clock;
		downSince = clock();
		// The service lists groups, sessions and terminals only to a connection that holds their read grants
		// (WorkspaceCatalogService.bind), so ask for the three reads along with the catalog. Nothing here can write.
		var capabilities = [WorkspaceCatalogProtocol.CAPABILITY, workspace.service.WorkspaceProtocol.READ,
			workspace.service.WorkspaceAgentProtocol.READ, workspace.service.WorkspaceTerminalProtocol.READ];
		client = new RpcClient(connector, clock, random, new RpcPeerOptions("exosuit-editor/1", capabilities, capabilities, 2000, 262144, 8,
			1048576), function(established, _, _) { hello(established); }, 100, 5000, 5000);
	}

	function hello(established:RpcConnection):Void {
		if (closed)
			return;
		if (client.remoteApplication != "exosuit-agent/1") {
			fail("Unexpected workspace service");
			return;
		}
		connection = established;
		ConnectTimeline.mark("watch-connected", ref.workspace);
		reading = false;
		dirty = false;
		staging = null;
		retryAt = 0;
		established.onNotification(WorkspaceCatalogProtocol.CHANGED, WorkspaceCatalogProtocol.decodeChange, function(change) { changed(established, change); });
		read(established, false);
	}

	function changed(source:RpcConnection, change:CatalogChange):Void {
		if (closed || source != connection || !WorkspaceCatalogProtocol.sameRef(change.ref, ref))
			return;
		if (!reading && retryAt == 0 && change.token == mirror.token) {
			skipped++;
			return;
		}
		// A read in flight, or a failed one waiting out its delay, sees the change when it reads next: CHANGED does not skip the backoff.
		if (reading || retryAt > 0)
			dirty = true;
		else
			read(source, false);
	}

	function read(source:RpcConnection, continuing:Bool):Void {
		if (closed || source != connection)
			return;
		if (!continuing) {
			pages = 0;
			// A change that arrives while pages are still coming stays pending until the read ends.
			dirty = false;
		}
		reading = true;
		if (!continuing)
			ConnectTimeline.mark("catalog-read", ref.workspace, mirror.token == null ? "first" : "again");
		var staged = staging;
		var resume = staged != null ? staged.token : mirror.token;
		source.call(WorkspaceCatalogProtocol.CATALOG, {ref: ref, resume: resume, watch: true}, CALL_TIMEOUT, function(page) {
			if (closed || source != connection)
				return;
			receive(source, page, resume);
		}, function(failure) {
			if (closed || source != connection)
				return;
			giveUp(failure.code);
		});
	}

	/** This read failed: keep the copy we have, and read again after a delay that grows until a read succeeds. */
	function giveUp(message:String):Void {
		reading = false;
		dirty = false;
		staging = null;
		error = message;
		revision++;
		retryAt = clock() + retryDelay;
		retryDelay = Math.min(RETRY_MAX_MS, retryDelay * 2);
	}

	function receive(source:RpcConnection, page:WorkspaceCatalog, sent:Null<String>):Void {
		reads++;
		pages++;
		if (!WorkspaceCatalogProtocol.sameRef(page.ref, ref)) {
			fail("Workspace service answered for another workspace");
			return;
		}
		if (page.more && pages >= MAX_PAGES) {
			giveUp("Workspace catalog needs more than " + MAX_PAGES + " pages");
			return;
		}
		if (page.more && page.token == sent) {
			giveUp("Workspace catalog asked for more without moving its token");
			return;
		}
		var target = staging;
		if (page.reset) {
			target = new WorkspaceCatalogMirror();
			staging = target;
		} else if (target == null)
			target = mirror;
		target.apply(page);
		if (target.itemCount() > MAX_ITEMS) {
			if (target == mirror)
				mirror = new WorkspaceCatalogMirror();
			giveUp("Workspace catalog holds more than " + MAX_ITEMS + " items");
			return;
		}
		if (page.more) {
			read(source, true);
			return;
		}
		if (staging != null) {
			mirror = target;
			staging = null;
		}
		reading = false;
		revision++;
		if (!page.watching) {
			// The service did not register this connection for CHANGED, so nothing would tell us of a change: read again later.
			live = false;
			error = "Workspace service is not watching";
			retryAt = clock() + retryDelay;
			retryDelay = Math.min(RETRY_MAX_MS, retryDelay * 2);
			return;
		}
		live = true;
		ConnectTimeline.mark("watch-live", ref.workspace, pages + " pages");
		error = null;
		retryDelay = RETRY_MIN_MS;
		if (dirty)
			read(source, false);
	}

	function fail(message:String):Void {
		error = message;
		revision++;
		closeNow();
	}

	/** Moves reconnects and retries along; call every frame. */
	public function poll():Void {
		if (closed)
			return;
		client.poll();
		if (client.state == Closed) {
			// A terminal handshake error (unauthorized, a missing capability) ends the client for good.
			var last = client.lastError;
			fail(last == null ? "Workspace connection closed" : last.code);
			return;
		}
		var current = connection;
		if (current != null && client.current() != current) {
			connection = null;
			reading = false;
			staging = null;
			if (live) {
				live = false;
				downSince = clock();
				revision++;
			}
			return;
		}
		if (current != null && !reading && retryAt > 0 && clock() >= retryAt) {
			retryAt = 0;
			read(current, false);
		}
	}

	/** Not live yet, or not live any more, and not for long: a service starting, or a connection coming back. */
	public function trying():Bool
		return !closed && !live && clock() - downSince < TRYING_MS;

	/** True once the watch has ended for good: disposed, or the service refused it. */
	public function ended():Bool
		return closed;

	function closeNow(closeClient:Bool = true):Void {
		if (closed)
			return;
		closed = true;
		if (live)
			revision++;
		live = false;
		connection = null;
		if (closeClient)
			client.close();
	}

	/**
		Stops the watch: sends UNWATCH and keeps the connection until the service has answered or LINGER_MS has passed, so the
		request is written before the close. The owner calls `drain` until it returns true. The service also drops the watch
		when the connection closes.
	**/
	public function dispose():Void {
		if (closed)
			return;
		var current = connection;
		closeNow(false);
		if (current != null && current.isOpen() && client.current() == current) {
			retiring = true;
			answered = false;
			lingerUntil = clock() + LINGER_MS;
			current.call(WorkspaceCatalogProtocol.UNWATCH, ref, Std.int(LINGER_MS), function(_) { answered = true; }, function(_) { answered = true; });
			return;
		}
		client.close();
	}

	/** After `dispose`: moves the UNWATCH along and closes the connection once it is answered or late. True when closed. */
	public function drain():Bool {
		if (!retiring)
			return true;
		client.poll();
		if (!answered && clock() < lingerUntil && client.state != Closed)
			return false;
		retiring = false;
		client.close();
		return true;
	}
}
