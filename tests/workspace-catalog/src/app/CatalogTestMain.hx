package app;

import haxe.Int64;
import app.AgentIdentityWatch;
import app.AgentStateIdentity;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.runtime.WorkspaceCatalogService;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogTerminal;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

private typedef Link = {var client:RpcConnection; var server:RpcConnection;}

private typedef Outcome = {
	var page:Null<WorkspaceCatalog>;
	var error:Null<String>;
}

/**
	The workspace's catalog watch (M19 Phase 6) end to end over an in-process connection pair: a paged reset, resuming
	with diffs and removals, tokens the service does not know, CHANGED while watching, UNWATCH, and the two errors.
**/
class CatalogTestMain {
	static var failures = 0;
	static var now = 0.0;
	static var folders:Array<String> = ["/work/a", "/work/b"];
	static var name = "Demo";
	static var terminals:Array<TerminalRecord> = [];
	static var client:RpcConnection;
	static var server:RpcConnection;
	static var service:WorkspaceCatalogService;
	static var changes:Array<String> = [];
	static var sessions:Array<AgentRecord> = [];
	static var requests:Map<String, Int> = new Map();
	static var cleanup:Void->Void = function() {};

	static function main():Void {
		try {
			setup();
			pagedReset();
			resume();
			unknownTokens();
			watching();
			grants();
			removedAndReadded();
			hostileTokens();
			identityWatch();
			sessionRecords();
			oversized();
			hints();
			ringOverflow();
			planCleanup();
			errors();
			large();
		} catch (error:Dynamic) {
			fail("uncaught: " + Std.string(error));
		}
		Sys.println(failures == 0 ? "PASS workspace catalog" : 'FAIL workspace catalog: $failures');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function terminal(id:String, state:String = "running"):TerminalRecord
		return {
			id: id,
			name: "Terminal " + id,
			group: "g",
			cwd: "/work/a",
			instance: "i",
			state: state,
			exitCode: 0,
			available: true,
			revision: Int64.ofInt(1)
		};

	static function id(index:Int):String
		return "t" + (index < 10 ? "0" : "") + index;

	static var everything = [WorkspaceCatalogProtocol.CAPABILITY, WorkspaceProtocol.READ, WorkspaceAgentProtocol.READ, WorkspaceTerminalProtocol.READ];

	static function connect(?grants:Array<String>):Void {
		var pair = MemoryTransport.pair(1024 * 1024, 128);
		var clock = function() return now;
		client = new RpcConnection(pair.client, clock);
		server = new RpcConnection(pair.server, clock);
		cleanup = service.bind(server, grants == null ? everything : grants);
		client.onNotification(WorkspaceCatalogProtocol.CHANGED, WorkspaceCatalogProtocol.decodeChange, function(change) changes.push(change.token));
	}

	static function setup():Void {
		for (index in 0...30) terminals.push(terminal(id(index)));
		var clock = function() return now;
		service = new WorkspaceCatalogService("ws1", "inst1", function() return {name: name, folders: folders.copy(), scratch: null},
			function():Array<WorkspaceGroup> return [{id: "g", name: "G", cwd: null, revision: 1}], function() return sessions, function() return requests,
			function() return terminals, clock);
		connect();
	}

	static function pump():Void {
		for (i in 0...8) {
			server.poll();
			client.poll();
		}
	}

	static function ref(workspace:String = "ws1"):WorkspaceRef
		return {machine: "m", workspace: workspace};

	static function read(resume:Null<String>, watch = false, workspace:String = "ws1"):Outcome {
		now += 1;
		var outcome:Outcome = {page: null, error: null};
		client.call(WorkspaceCatalogProtocol.CATALOG, {ref: ref(workspace), resume: resume, watch: watch}, 1000, function(page) outcome.page = page,
			function(error:RpcError) outcome.error = error.code);
		pump();
		return outcome;
	}

	/** The page of a read that must have succeeded. */
	static function page(resume:Null<String>, watch = false):WorkspaceCatalog {
		var outcome = read(resume, watch);
		var result = outcome.page;
		if (result == null) throw "no page: " + outcome.error;
		return result;
	}

	/** Reads every page of a read, following `more` like a client would. */
	static function readAll(resume:Null<String>):Array<WorkspaceCatalog> {
		var pages:Array<WorkspaceCatalog> = [];
		var token = resume;
		while (true) {
			var next = page(token);
			pages.push(next);
			token = next.token;
			if (!next.more) return pages;
			if (pages.length > 200) throw "too many pages";
		}
	}

	static function terminalIds(value:WorkspaceCatalog):String
		return [for (t in value.terminals) t.id].join(",");


	static function use(link:Link):Void {
		client = link.client;
		server = link.server;
	}

	/** A connection granted only the catalog sees the workspace's own fields and nothing else. */
	static function grants():Void {
		connect([WorkspaceCatalogProtocol.CAPABILITY]);
		var bare = readAll(null);
		var listed = 0;
		for (value in bare) listed += value.groups.length + value.terminals.length + value.sessions.length;
		check(listed == 0 && bare[0].folders.length == 2 && bare[0].reset, "grants: a catalog-only grant lists no groups, sessions or terminals");
		check(bare[0].attention == 0, "grants: nor does it count their attention");
		connect([WorkspaceCatalogProtocol.CAPABILITY, WorkspaceTerminalProtocol.READ]);
		var some = readAll(null);
		var terminalCount = 0, groupCount = 0;
		for (value in some) {
			terminalCount += value.terminals.length;
			groupCount += value.groups.length;
		}
		check(terminalCount == terminals.length && groupCount == 0, "grants: terminals come with the terminals' read grant only");
		terminals.push(terminal("t200"));
		var narrow = page(some[some.length - 1].token);
		terminals.pop();
		check(terminalIds(narrow) == "t200", "grants: a granted kind still resumes");
		var gone = page(narrow.token);
		check(gone.removedTerminals.join(",") == "t200", "grants: and its removals");
		connect([WorkspaceCatalogProtocol.CAPABILITY, WorkspaceProtocol.READ]);
		var groupsOnly = readAll(null);
		check(groupsOnly[0].groups.length == 1 && groupsOnly[0].terminals.length == 0, "grants: groups come with the workspace read grant only");
		connect();
	}

	/** A key that is removed and comes back is an upsert: a client resuming from before both gets no removal of it. */
	static function removedAndReadded():Void {
		var pages = readAll(null);
		var token = pages[pages.length - 1].token;
		var removed = terminals.splice(3, 1)[0];
		read(null);
		terminals.insert(3, removed);
		var diff = page(token);
		check(terminalIds(diff) == "t03" && diff.removedTerminals.length == 0, "readd: an upsert, no stale removal, got " + terminalIds(diff) + " / "
			+ diff.removedTerminals.join(","));
	}

	/** Tokens come from clients: nothing in one may throw, reach another connection's read, or lose a read to other reads. */
	static function hostileTokens():Void {
		var first = page(null);
		check(first.more, "hostile: the first page of a long read has more");
		check(page(first.token).reset == false, "hostile: the real token continues");
		for (template in ["inst1.0.0.%P.-1", "inst1.0.0.%P.9999", "inst1.5.2.%P.1", "inst1.0.99999.%P.1", "inst1.-1", "inst1.1x",
				"inst1.0.0.p0.0.0", "inst1..", "inst1.99999999999", "inst1.0.0.%P.1x"]) {
			var fresh = page(null);
			var bad = StringTools.replace(template, "%P", fresh.token.split(".")[3]);
			var outcome = read(bad);
			check(outcome.page != null && outcome.page.reset, "hostile: " + bad + " resets, got " + outcome.error);
		}
		// Another connection's plan id is not mine to read.
		var mine = {client: client, server: server};
		var firstAgain = page(null);
		connect();
		var theirs = {client: client, server: server};
		check(page(firstAgain.token).reset, "hostile: another connection's plan id resets");
		use(mine);
		check(!page(firstAgain.token).reset, "hostile: and leaves the plan to its owner");
		// A connection keeps two paged reads; a third first page evicts the oldest only.
		var one = page(null), two = page(null), three = page(null);
		check(!page(three.token).reset && !page(two.token).reset, "plans: the newer two continue");
		check(page(one.token).reset, "plans: the oldest of three paged reads is gone, and the read starts over");
		// Reads on other connections never take this one's plans.
		var held = page(null);
		for (i in 0...20) {
			use(theirs);
			page(null);
			page(null);
			use(mine);
		}
		check(!page(held.token).reset, "plans: other connections' reads do not evict mine");
		// A reset that interrupts a paged read: the pages that follow go on, and the next read resets.
		var begun = page(null);
		name = "Interrupted";
		var rest = page(begun.token);
		check(rest.name == begun.name, "interrupt: the pages that follow carry the identity their read began with");
		check(!rest.reset && rest.terminals.length > 0, "interrupt: the pages that follow continue the read");
		check(!rest.more && page(rest.token).reset && page(rest.token).name == "Interrupted", "interrupt: and the next read is a reset");
		var again = page(null);
		check(again.reset && again.folders.length == 2, "interrupt: a new read is a reset with its folders");
		name = "Demo";
	}

	static function session(id:String, state:String = "idle"):AgentRecord
		return {id: id, name: "Session " + id, group: "g", cwd: "/work/a", thread: "th", state: state, turn: null, workspaceRoot: "/work/a"};

	/** Sessions are listed, and the requests waiting on one count toward its attention and the page's total. */
	static function sessionRecords():Void {
		connect();
		var pages = readAll(null);
		var token = pages[pages.length - 1].token;
		var baseline = pages[0].attention;
		sessions.push(session("s1"));
		sessions.push(session("s2", WorkspaceCatalogProtocol.NEEDS_ATTENTION));
		var diff = page(token);
		check(diff.sessions.length == 2 && diff.sessions[0].attention == 0 && diff.sessions[1].attention == 1, "sessions: listed with their attention");
		check(diff.attention == baseline + 1, "sessions: the page total counts them");
		requests.set("s1", 2);
		var waiting = page(diff.token);
		check(waiting.sessions.length == 1 && waiting.sessions[0].id == "s1" && waiting.sessions[0].attention == 2, "sessions: pending requests change the item");
		check(waiting.attention == baseline + 3, "sessions: and the total, got " + waiting.attention);
		connect([WorkspaceCatalogProtocol.CAPABILITY, WorkspaceProtocol.READ]);
		check(page(null).attention == 0, "sessions: a connection that cannot see sessions does not count them");
		sessions = [];
		requests = new Map();
		connect();
		read(null);
	}

	/** An item too big for a page has its display name shortened (never a path), else it is left out; it never blocks the catalog. */
	static function oversized():Void {
		var huge = StringTools.rpad("", "x", 200000);
		var longName = terminal("t-big");
		longName.name = huge;
		var longPath = terminal("t-path");
		longPath.cwd = huge;
		terminals.push(longName);
		terminals.push(longPath);
		var before = service.omitted;
		connect();
		var pages = readAll(null);
		var name:Null<CatalogTerminal> = null, path:Null<CatalogTerminal> = null;
		for (value in pages) {
			check(WorkspaceCatalogProtocol.fits(value), "oversized: every page fits");
			for (t in value.terminals) {
				if (t.id == "t-big") name = t;
				if (t.id == "t-path") path = t;
			}
		}
		check(name != null && name.name.length == 256 && StringTools.endsWith(name.name, "…") && name.directory == "/work/a",
			"oversized: a long display name is shortened and marked, its directory untouched: " + (name == null ? "missing" : name.name.length + " " + name.directory));
		check(path == null && service.omitted == before + 1, "oversized: a path that cannot fit is left out, never cut, and counted");
		terminals.pop();
		terminals.pop();
		read(null);
	}

	/** Hints reach a watcher only for what its grants let it see, and no faster than ten a second. */
	static function hints():Void {
		var token = readAll(null).pop().token;
		connect([WorkspaceCatalogProtocol.CAPABILITY, WorkspaceProtocol.READ]);
		changes = [];
		page(token, true);
		terminals.push(terminal("t300"));
		now += 1;
		service.poll();
		pump();
		check(changes.length == 0, "hints: a change to terminals does not reach a connection that cannot see terminals");
		name = "Hinted";
		now += 1;
		service.poll();
		pump();
		check(changes.length == 1, "hints: a change to the workspace itself reaches everyone, got " + changes.length);
		connect();
		changes = [];
		page(null, true);
		now += 1;
		service.poll();
		terminals.push(terminal("t301"));
		now += 0.11;
		service.poll();
		terminals.push(terminal("t302"));
		now += 0.11;
		service.poll();
		pump();
		check(changes.length == 2, "hints: one per change after the interval, got " + changes.length);
		terminals.push(terminal("t303"));
		now += 0.11;
		service.poll();
		terminals.push(terminal("t304"));
		now += 0.05;
		service.poll();
		pump();
		check(changes.length == 3, "hints: a second change inside the interval waits, got " + changes.length);
		now += 0.2;
		service.poll();
		pump();
		check(changes.length == 4, "hints: and is sent when it is over, got " + changes.length);
		terminals.splice(terminals.length - 6, 6);
		name = "Demo";
		read(null);
	}

	/** Removals spread over several refreshes outgrow the ring: older tokens reset, newer ones still resume. */
	static function ringOverflow():Void {
		var oldest = readAll(null).pop().token;
		var first = [for (i in 0...600) terminal("r" + i)], second = [for (i in 0...600) terminal("q" + i)];
		for (t in first) terminals.push(t);
		for (t in second) terminals.push(t);
		var both = readAll(null).pop().token;
		terminals.splice(terminals.length - 1200, 600);
		var afterFirst = readAll(null).pop().token;
		terminals.splice(terminals.length - 600, 600);
		var afterSecond = readAll(null).pop().token;
		check(page(oldest).reset, "ring: a token from before every removal resets");
		check(page(both).reset, "ring: so does one whose removals have left the ring");
		var resumed = readAll(afterFirst), removedCount = 0;
		for (value in resumed) removedCount += value.removedTerminals.length;
		check(!resumed[0].reset && removedCount == 600, "ring: a token inside the ring resumes with its removals, got " + removedCount);
		check(!page(afterSecond).reset, "ring: a token after them resumes");
	}

	/** A paged read's plans are dropped with its connection. */
	static function planCleanup():Void {
		connect();
		var others = service.planCount();
		page(null);
		check(service.planCount() > others, "cleanup: a paged read keeps a plan");
		var done = cleanup;
		done();
		check(service.planCount() == others, "cleanup: and the connection's cleanup drops it");
	}

	/** A large catalog reads in linear time. */
	static function large():Void {
		var saved = terminals;
		terminals = [for (i in 0...2000) terminal("L" + i)];
		connect();
		var start = Sys.time();
		var pages = readAll(null);
		var seconds = Sys.time() - start;
		var count = 0;
		for (value in pages) count += value.terminals.length;
		Sys.println("large catalog: " + count + " terminals in " + pages.length + " pages, " + Std.int(seconds * 1000) + " ms");
		check(count == 2000 && seconds < 20, "large: every item arrives, in time");
		terminals = saved;
	}

	/** workspace.json changes while the service runs: a torn file keeps the last good identity and is tried again. */
	static function identityWatch():Void {
		var directory = haxe.io.Path.join([Sys.getEnv("TEMP") != null ? Sys.getEnv("TEMP") : "/tmp", "exosuit-catalog-identity-" + Std.int(Sys.time())]);
		if (!AgentManagerNative.prepareDirectory(directory)) throw "cannot create " + directory;
		var path = haxe.io.Path.join([directory, "workspace.json"]);
		var id = "workspace-" + StringTools.rpad("", "a", 32);
		function write(folder:String):Void
			AgentStateIdentity.forWorkspace(id, [folder], null).write(path);
		function folders(watch:AgentIdentityWatch):String
			return watch.current().folders.join(",");
		write("/aa");
		var later = Sys.time() + 1000;
		var watch = new AgentIdentityWatch(path, function() return AgentStateIdentity.forFolder("/x"), function() return later);
		check(folders(watch) == "/aa", "identity: read at start");
		sys.io.AtomicFile.write(path, "{\"version\":2,\"workspace\":\"" + id + "\",\"fol");
		check(folders(watch) == "/aa", "identity: a torn file keeps the last good identity");
		sys.io.AtomicFile.write(path, "garbage that is not json at all");
		check(folders(watch) == "/aa", "identity: so does garbage");
		write("/bb");
		check(folders(watch) == "/bb", "identity: the next good file is read, the failed one having been tried again");
		// A rewrite of the same size inside the clock's granularity is still seen while the file is young.
		var young = new AgentIdentityWatch(path, function() return AgentStateIdentity.forFolder("/x"), function() return Sys.time());
		check(folders(young) == "/bb", "identity: young file read");
		write("/cc");
		check(folders(young) == "/cc", "identity: a same-size rewrite of a young file is seen");
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteDirectory(directory);
	}
	static function pagedReset():Void {
		var pages = readAll(null);
		var ids:Array<String> = [], seen:Array<String> = [];
		for (value in pages) {
			check(value.groups.length + value.terminals.length + value.sessions.length + value.folders.length <= WorkspaceCatalogProtocol.PAGE_LIMIT,
				"reset: a page holds at most PAGE_LIMIT");
			check(WorkspaceCatalogProtocol.fits(value), "reset: a page fits PAGE_BYTES");
			for (t in value.terminals) ids.push(t.id);
			for (f in value.folders) seen.push(f);
		}
		var last = pages[pages.length - 1];
		check(pages.length == 2, "reset: 2 folders, 1 group and 30 terminals take 2 pages, got " + pages.length);
		check(pages[0].reset && !pages[1].reset, "reset: only the first page resets");
		check(pages[0].more && !last.more, "reset: more on all but the last");
		check(ids.length == 30 && ids[0] == "t00" && ids[29] == "t29", "reset: every terminal once, in order, got " + ids.length);
		check(seen.join(",") == "/work/a,/work/b" && pages[1].folders.length == 0, "reset: folders on the first page only");
		check(pages[0].name == "Demo" && last.status == "running", "reset: name and status");
		check(last.token.split(".").length == 2 && last.token.split(".")[0] == "inst1", "reset: the last page ends in a plain token");
	}

	static function resume():Void {
		var pages = readAll(null);
		var token = pages[pages.length - 1].token;
		var same = page(token);
		check(!same.reset && !same.more && same.terminals.length == 0 && same.removedTerminals.length == 0, "resume: no change is an empty page");
		terminals[5] = terminal("t05", "exited");
		terminals.splice(6, 1);
		terminals.push(terminal("t99"));
		var diff = page(token);
		check(!diff.reset && !diff.more, "resume: a diff is not a reset");
		check(terminalIds(diff) == "t05,t99", "resume: changed and new terminals, got " + terminalIds(diff));
		check(diff.terminals.length > 0 && diff.terminals[0].state == "exited", "resume: the changed state arrives");
		check(diff.removedTerminals.join(",") == "t06", "resume: the removal arrives");
		check(diff.folders.length == 0, "resume: no folders outside a reset");
		check(page(diff.token).terminals.length == 0, "resume: the new token is current");
		// A change to the workspace's own fields makes the next read a reset.
		name = "Renamed";
		var renamed = page(diff.token);
		check(renamed.reset && renamed.name == "Renamed", "resume: a rename resets");
	}

	static function unknownTokens():Void {
		var pages = readAll(null);
		var current = pages[pages.length - 1].token;
		check(page("other." + current.split(".")[1]).reset, "tokens: another instance resets");
		check(page("garbage").reset, "tokens: garbage resets");
		check(page("inst1.9999").reset, "tokens: a revision from the future resets");
		check(page("inst1.1.2.nope.3").reset, "tokens: a plan this service does not hold resets");
		check(!page(current).reset, "tokens: the current token still resumes");
	}

	static function watching():Void {
		var pages = readAll(null);
		var token = pages[pages.length - 1].token;
		changes = [];
		check(page(token, true).watching, "watch: the reply says watching");
		now += 1;
		service.poll();
		pump();
		check(changes.length == 0, "watch: no change, no hint");
		terminals.push(terminal("t100"));
		now += 1;
		service.poll();
		pump();
		check(changes.length == 1, "watch: one hint after a change, got " + changes.length);
		check(terminalIds(page(token)) == "t100", "watch: the hint's change can be read");
		var unwatched:Null<WorkspaceRef> = null;
		client.call(WorkspaceCatalogProtocol.UNWATCH, ref(), 1000, function(r) unwatched = r, function(e) {});
		pump();
		check(unwatched != null && service.watcherCount() == 0, "unwatch: acknowledged and removed");
		terminals.push(terminal("t101"));
		now += 1;
		service.poll();
		pump();
		check(changes.length == 1, "unwatch: no more hints");
		// Disconnecting also stops them.
		page(null, true);
		check(service.watcherCount() == 1, "watch: rewatching");
		client.close();
		server.close();
		now += 1;
		service.poll();
		check(service.watcherCount() == 0, "watch: a closed connection is dropped");
	}

	static function errors():Void {
		connect();
		check(read(null, false, "other").error == "unknown_workspace", "errors: unknown_workspace");
		check(read(null, false, "workspace").page != null, "errors: \"workspace\" names this service");
		check(read("").error == "invalid_request", "errors: an empty token is invalid_request");
		check(read(null, false, "").error == "invalid_request", "errors: an empty workspace is invalid_request");
	}

	static function check(condition:Bool, message:String):Void {
		if (!condition) fail(message);
	}

	static function fail(message:String):Void {
		failures++;
		Sys.println("FAIL: " + message);
	}
}
