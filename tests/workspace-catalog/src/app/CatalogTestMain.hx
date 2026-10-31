package app;

import haxe.Int64;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import workspace.runtime.WorkspaceCatalogService;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

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

	static function main():Void {
		try {
			setup();
			pagedReset();
			resume();
			unknownTokens();
			watching();
			errors();
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

	static function connect():Void {
		var pair = MemoryTransport.pair(1024 * 1024, 128);
		var clock = function() return now;
		client = new RpcConnection(pair.client, clock);
		server = new RpcConnection(pair.server, clock);
		service.bind(server, [WorkspaceCatalogProtocol.CAPABILITY]);
		client.onNotification(WorkspaceCatalogProtocol.CHANGED, WorkspaceCatalogProtocol.decodeChange, function(change) changes.push(change.token));
	}

	static function setup():Void {
		for (index in 0...30) terminals.push(terminal(id(index)));
		var clock = function() return now;
		service = new WorkspaceCatalogService("ws1", "inst1", function() return {name: name, folders: folders.copy(), scratch: null},
			function():Array<WorkspaceGroup> return [{id: "g", name: "G", cwd: null, revision: 1}], function():Array<AgentRecord> return [],
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
			if (pages.length > 10) throw "too many pages";
		}
	}

	static function terminalIds(value:WorkspaceCatalog):String
		return [for (t in value.terminals) t.id].join(",");

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
