package workspace.client;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogChange;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;
import workspace.transport.RpcCalls;

/**
	A watch on one workspace service's catalog, carried on a connection its owner holds (a WorkspaceLink's client):
	the owner calls `attach` with each connection it establishes and `detach` when that one goes away. On it the watch
	uses only CATALOG, UNWATCH and CHANGED. It reads the catalog in pages, applies resets and deltas to `mirror`, and
	reads again when CHANGED names a token other than its own. After a reconnect it resumes from its last token, and the
	service answers with a reset if it no longer knows it.

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
	/** How long the UNWATCH a disposed watch sends may wait for its answer; nothing waits on it. */
	public static inline final LINGER_MS = 500.0;

	/** The workspace this watch follows. A watch that started on the alias "workspace" adopts the service's real ref from its first page. */
	public var ref(default, null):WorkspaceRef;
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

	final clock:Void->Float;
	final learning:Bool;
	/** The owner's current connection, between `attach` and `detach` (or its closing). */
	var connection:Null<RpcConnection>;
	var staging:Null<WorkspaceCatalogMirror>;
	var reading = false;
	var dirty = false;
	var retryAt:Float = 0;
	var closed = false;
	var pages = 0;

	function new(ref:WorkspaceRef, clock:Void->Float, learning:Bool) {
		this.ref = ref;
		this.clock = clock;
		this.learning = learning;
	}

	/**
		A watch on a connection the owner already holds: the owner opens no second connection for the catalog. With
		`learning`, `ref.workspace` may be the alias "workspace": the first page names the real id and the watch adopts it
		(the machine must match), so the owner can store the workspace by id. The connection must hold the catalog
		capability and the three read grants (WorkspaceCatalogService.bind lists items only to their readers).
	**/
	public static function shared(ref:WorkspaceRef, clock:Void->Float, learning:Bool):WorkspaceCatalogWatch
		return new WorkspaceCatalogWatch(ref, clock, learning);

	/** Starts (or restarts after a reconnect) reading on `established`; resumes from the last token. */
	public function attach(established:RpcConnection):Void {
		if (closed)
			return;
		connection = established;
		ConnectTimeline.mark("watch-connected", ref.workspace);
		reading = false;
		dirty = false;
		staging = null;
		retryAt = 0;
		established.onNotification(WorkspaceCatalogProtocol.CHANGED, WorkspaceCatalogProtocol.decodeChange, function(change) { changed(established, change); });
		read(established, false);
	}

	/** The owner's connection is gone: keep the copy, clear `live`, and wait for the next `attach`. */
	public function detach():Void {
		if (closed)
			return;
		lostConnection();
	}

	function lostConnection():Void {
		connection = null;
		reading = false;
		staging = null;
		if (live) {
			live = false;
			revision++;
		}
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
		RpcCalls.call(source, WorkspaceCatalogProtocol.CATALOG, {ref: ref, resume: resume, watch: true}, CALL_TIMEOUT, function(page) {
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
		if (learning && ref.workspace == "workspace" && page.ref.machine == ref.machine && page.ref.workspace.length > 0)
			ref = page.ref;
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

	/** Notices a closed connection and moves retries along; call every frame. The owner polls the connection itself. */
	public function poll():Void {
		if (closed)
			return;
		var current = connection;
		if (current != null && !current.isOpen()) {
			lostConnection();
			return;
		}
		if (current != null && !reading && retryAt > 0 && clock() >= retryAt) {
			retryAt = 0;
			read(current, false);
		}
	}

	/** True once the watch has ended for good: disposed, or the service answered for another workspace. */
	public function ended():Bool
		return closed;

	function closeNow():Void {
		if (closed)
			return;
		closed = true;
		if (live)
			revision++;
		live = false;
		connection = null;
	}

	/**
		Stops the watch: sends UNWATCH on the owner's connection, which stays open, and returns at once; the answer is not
		waited for. The service also drops the watch when the connection closes.
	**/
	public function dispose():Void {
		if (closed)
			return;
		var current = connection;
		closeNow();
		if (current != null && current.isOpen())
			RpcCalls.call(current, WorkspaceCatalogProtocol.UNWATCH, ref, Std.int(LINGER_MS), function(_) {}, function(_) {});
	}
}
