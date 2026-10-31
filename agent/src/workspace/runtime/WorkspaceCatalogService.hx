package workspace.runtime;

import haxeon.rpc.RpcConnection;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/** What the catalog says about the workspace itself; a change to any of it makes the next read a reset. */
typedef CatalogDescription = {
	var name:String;
	var folders:Array<String>;
	var scratch:Null<String>;
}

private typedef CatalogItem = {
	/** 1 group, 2 terminal, 3 session: the order a page lists them in (folders are not items). */
	var kind:Int;
	var id:String;
	var fingerprint:String;
	var changed:Int;
}

private typedef CatalogWatcher = {
	var connection:RpcConnection;
	var ref:WorkspaceRef;
	var view:CatalogView;
	/** Something this watcher can see changed and its hint has not been sent yet. */
	var dirty:Bool;
	var sentAt:Float;
}

/** Where a read continues from; `since` -1 means a reset. */
private typedef CatalogResume = {
	var since:Int;
	var upto:Int;
	var plan:Null<CatalogPlan>;
	var offset:Int;
}

/** What a connection may see in a catalog, from its grants. */
private typedef CatalogView = {
	var groups:Bool;
	var sessions:Bool;
	var terminals:Bool;
}

/** What the service held at one refresh: the records pages are made from, fetched once. */
private typedef CatalogSnapshot = {
	var describing:CatalogDescription;
	var groups:Map<String, WorkspaceGroup>;
	var terminals:Map<String, TerminalRecord>;
	var sessions:Map<String, AgentRecord>;
	/** Requests waiting on each session. */
	var requests:Map<String, Int>;
	var terminalAttention:Int;
	var sessionAttention:Int;
}

/** The entries of one connection's paged read, fixed when it started, with the records they are read from. */
private typedef CatalogPlan = {
	var connection:RpcConnection;
	var id:String;
	var entries:Array<String>;
	var snapshot:CatalogSnapshot;
}

/**
	The workspace's catalog watch (M19 Phase 6; protocol in docs/roadmap/RPC-VECTORS.md, "Workspace refs and the
	catalog watch"): CATALOG pages of groups, sessions and terminals with no content, resumable by token, and
	CHANGED hints to watching connections. Local connections only for now: remote peers get the capability with the
	mobile adaptation.

	Each item keeps the revision it last changed at, and removals are kept for a while, so a token
	`<instance>.<revision>` reads what changed since. A read that takes more than one page fixes its list of items and
	the records they come from when it starts (a plan), so pages stay consistent while the catalog changes and a
	paged read costs no more per page than the page; a token `<instance>.<since>.<upto>.<plan>.<offset>` continues it.
	A plan lives until its read ends, the connection holds more than PLAN_LIMIT, or the connection closes. A token
	this service does not know, from another instance or for removals it no longer keeps, gives a reset.
**/
class WorkspaceCatalogService {
	static inline final REMOVAL_LIMIT = 1024;
	/** Paged reads a connection may have under way. */
	static inline final PLAN_LIMIT = 2;
	/** A CATALOG call reuses a refresh this young. */
	static inline final READ_REFRESH_SECONDS:Float = 0.02;
	static inline final REFRESH_SECONDS:Float = 0.1;
	/** A connection receives at most one CHANGED hint per this many seconds. */
	static inline final NOTIFY_SECONDS:Float = 0.1;
	/** Display name length kept when an item does not fit a page whole (paths and ids are never cut). */
	static inline final SHRUNK_LENGTH = 256;

	final workspace:String;
	final instance:String;
	final describe:Void->CatalogDescription;
	final groups:Void->Array<WorkspaceGroup>;
	final sessions:Void->Array<AgentRecord>;
	final requests:Void->Map<String, Int>;
	final terminals:Void->Array<TerminalRecord>;
	final clock:Void->Float;
	final items:Map<String, CatalogItem> = [];
	var removals:Array<{key:String, at:Int}> = [];
	/** The keys in `removals`, so a key that comes back is found without a scan. */
	final removed:Map<String, Bool> = [];
	final plans:Array<CatalogPlan> = [];
	final watchers:Array<CatalogWatcher> = [];
	var snapshot:CatalogSnapshot;
	var revision = 0;
	/** Reads resuming from before this revision may have missed removals: they reset. */
	var removalFloor = 0;
	/** The workspace's own fields last changed at this revision: reads resuming from before it reset. */
	var describedAt = 0;
	var description = "";
	var nextPlan = 0;
	/** Items left out of pages because they did not fit even with a shortened name. */
	public var omitted(default, null) = 0;
	var warned = false;
	var refreshedAt = -1.0;

	/**
		`workspace` is the id this service answers to; a client may also name it "workspace" (RPC-VECTORS). `requests`
		counts the requests waiting on each session, by session id.
	**/
	public function new(workspace:String, instance:String, describe:Void->CatalogDescription, groups:Void->Array<WorkspaceGroup>,
			sessions:Void->Array<AgentRecord>, requests:Void->Map<String, Int>, terminals:Void->Array<TerminalRecord>, clock:Void->Float) {
		this.workspace = workspace;
		this.instance = instance;
		this.describe = describe;
		this.groups = groups;
		this.sessions = sessions;
		this.requests = requests;
		this.terminals = terminals;
		this.clock = clock;
		refresh();
	}

	/**
		Registers CATALOG and UNWATCH on a connection granted the capability; returns its cleanup. What a read lists
		follows the connection's other grants: groups need the workspace read grant, sessions the agents' and terminals
		the terminals'.
	**/
	public function bind(connection:RpcConnection, capabilities:Array<String>):Void->Void {
		if (capabilities.indexOf(WorkspaceCatalogProtocol.CAPABILITY) < 0) return function() {};
		var view:CatalogView = {
			groups: capabilities.indexOf(WorkspaceProtocol.READ) >= 0,
			sessions: capabilities.indexOf(WorkspaceAgentProtocol.READ) >= 0,
			terminals: capabilities.indexOf(WorkspaceTerminalProtocol.READ) >= 0
		};
		connection.register(WorkspaceCatalogProtocol.CATALOG, function(query, context) {
			if (!WorkspaceCatalogProtocol.validQuery(query)) {
				context.fail({code: "invalid_request", message: "Invalid catalog query", ambiguous: false});
				return;
			}
			if (query.ref.workspace != workspace && query.ref.workspace != "workspace") {
				context.fail({code: "unknown_workspace", message: "This service does not serve that workspace", ambiguous: false});
				return;
			}
			var ref:WorkspaceRef = {machine: query.ref.machine, workspace: workspace};
			if (query.watch) {
				// A later watch names the ref notifications carry from then on.
				var existing = watchers.filter(function(watcher) return watcher.connection == connection);
				if (existing.length > 0) existing[0].ref = ref;
				else watchers.push({connection: connection, ref: ref, view: view, dirty: false, sentAt: -1000.0});
			}
			context.respond(page(connection, view, ref, query.resume, Lambda.exists(watchers, function(watcher) return watcher.connection == connection)));
		});
		connection.register(WorkspaceCatalogProtocol.UNWATCH, function(ref, context) {
			if (!WorkspaceCatalogProtocol.validRef(ref)) {
				context.fail({code: "invalid_request", message: "Invalid workspace", ambiguous: false});
				return;
			}
			unwatch(connection);
			context.respond({machine: ref.machine, workspace: workspace});
		});
		return function() {
			unwatch(connection);
			forgetPlans(connection);
		};
	}

	/** Called every service tick: notices changes (at most every REFRESH_SECONDS while anyone watches) and hints watchers. */
	public function poll():Void {
		for (watcher in watchers.copy())
			if (!watcher.connection.isOpen()) watchers.remove(watcher);
		if (watchers.length > 0) refresh();
		flush();
	}

	public function watcherCount():Int
		return watchers.length;

	/** Paged reads kept for connections, for tests. */
	public function planCount():Int
		return plans.length;

	function unwatch(connection:RpcConnection):Void {
		for (watcher in watchers.copy())
			if (watcher.connection == connection) watchers.remove(watcher);
	}

	/** Sends each watcher with something new to see its hint, at most NOTIFY_SECONDS apart. */
	function flush():Void {
		var time = clock(), token = instance + "." + revision;
		for (watcher in watchers.copy()) {
			if (!watcher.dirty || time - watcher.sentAt < NOTIFY_SECONDS) continue;
			if (!watcher.connection.isOpen()) {
				watchers.remove(watcher);
				continue;
			}
			watcher.dirty = false;
			watcher.sentAt = time;
			watcher.connection.notify(WorkspaceCatalogProtocol.CHANGED, {ref: watcher.ref, token: token}, WorkspaceCatalogProtocol.encodeChange);
		}
	}

	/**
		Compares the catalog with what it was; anything new, changed or gone moves the revision on once. A watcher is
		marked only for changes it can see.
	**/
	function refresh(minAge:Float = 0.1):Void {
		var time = clock();
		if (refreshedAt >= 0 && time - refreshedAt < minAge) return;
		refreshedAt = time;
		var next = revision + 1, changed = false, groupsChanged = false, sessionsChanged = false, terminalsChanged = false, describedChanged = false;
		var current = new Map<String, Bool>();
		var describing = describe();
		var counts = requests();
		var held:CatalogSnapshot = {
			describing: describing, groups: new Map(), terminals: new Map(), sessions: new Map(), requests: counts, terminalAttention: 0,
			sessionAttention: 0
		};
		var described = describing.name + "|" + describing.folders.join("|") + "|" + (describing.scratch == null ? "-" : "+" + describing.scratch);
		if (described != description) {
			description = described;
			describedAt = next;
			changed = true;
			describedChanged = true;
		}
		function note(kind:Int, id:String, bytes:haxe.io.Bytes):Bool {
			var key = kind + ":" + id, fingerprint = hex(bytes);
			current.set(key, true);
			var item = items.get(key);
			if (item == null) {
				items.set(key, {kind: kind, id: id, fingerprint: fingerprint, changed: next});
				// A key that comes back is an upsert only: a resume from before both changes must not also remove it.
				if (removed.exists(key)) {
					removed.remove(key);
					removals = removals.filter(function(removal) return removal.key != key);
				}
				changed = true;
				return true;
			}
			if (item.fingerprint != fingerprint) {
				item.fingerprint = fingerprint;
				item.changed = next;
				changed = true;
				return true;
			}
			return false;
		}
		for (group in groups()) {
			held.groups.set(group.id, group);
			if (note(1, group.id, MessagePack.encode(group))) groupsChanged = true;
		}
		for (terminal in terminals()) {
			held.terminals.set(terminal.id, terminal);
			var attention = terminalAttention(terminal);
			held.terminalAttention += attention;
			if (note(2, terminal.id, MessagePack.encode(WorkspaceCatalogProtocol.terminal(terminal, attention)))) terminalsChanged = true;
		}
		for (session in sessions()) {
			held.sessions.set(session.id, session);
			var waiting = counts.get(session.id);
			var attention = WorkspaceCatalogProtocol.sessionAttention(session, waiting == null ? 0 : waiting);
			held.sessionAttention += attention;
			if (note(3, session.id, MessagePack.encode(WorkspaceCatalogProtocol.session(session, attention)))) sessionsChanged = true;
		}
		for (key in [for (key in items.keys()) key])
			if (!current.exists(key)) {
				var kind = Std.parseInt(key.substr(0, 1));
				if (kind == 1) groupsChanged = true;
				else if (kind == 2) terminalsChanged = true;
				else sessionsChanged = true;
				items.remove(key);
				removals.push({key: key, at: next});
				removed.set(key, true);
				changed = true;
			}
		while (removals.length > REMOVAL_LIMIT) {
			var dropped = removals.shift();
			removed.remove(dropped.key);
			removalFloor = dropped.at;
		}
		snapshot = held;
		if (!changed) return;
		revision = next;
		for (watcher in watchers) {
			var view = watcher.view;
			if (describedChanged || groupsChanged && view.groups || sessionsChanged && view.sessions || terminalsChanged && view.terminals)
				watcher.dirty = true;
		}
		flush();
	}

	/** Encoded bytes as text: HashLink strings cannot hold the NULs MessagePack writes, and Bytes has no toHex yet. */
	static function hex(bytes:haxe.io.Bytes):String {
		var digits = "0123456789abcdef", out = new StringBuf();
		for (index in 0...bytes.length) {
			var value = bytes.get(index);
			out.add(digits.charAt(value >> 4));
			out.add(digits.charAt(value & 15));
		}
		return out.toString();
	}

	/** A terminal needs attention when it exited with a failure. */
	static function terminalAttention(record:TerminalRecord):Int
		return record.state == "exited" && record.exitCode != 0 ? 1 : 0;

	/** A non-negative decimal, or null: tokens come from clients, so nothing looser is trusted. */
	static function number(text:String):Null<Int> {
		if (text.length == 0 || text.length > 9 || !~/^[0-9]+$/.match(text)) return null;
		return Std.parseInt(text);
	}

	/**
		What a read continues from, or a reset. A token is trusted for nothing: its numbers must be in range and its plan
		must be this connection's own, else the read starts over.
	**/
	function resumeFrom(connection:RpcConnection, resume:Null<String>):CatalogResume {
		var start:CatalogResume = {since: -1, upto: revision, plan: null, offset: 0};
		var parts = resume == null ? [] : resume.split(".");
		if (parts.length < 2 || parts[0] != instance) return start;
		var from = number(parts[1]);
		if (from == null) return start;
		if (parts.length == 2) {
			if (from <= revision && from >= removalFloor && from >= describedAt) start.since = from;
			return start;
		}
		if (parts.length != 5) return start;
		var end = number(parts[2]), at = number(parts[4]);
		var held = plans.filter(function(entry) return entry.connection == connection && entry.id == parts[3]);
		if (end == null || at == null || held.length == 0 || from > end || end > revision || at > held[0].entries.length) return start;
		return {since: from, upto: end, plan: held[0], offset: at};
	}

	function page(connection:RpcConnection, view:CatalogView, ref:WorkspaceRef, resume:Null<String>, watching:Bool):WorkspaceCatalog {
		// A new read refreshes first (a young refresh is reused); a continuation reads the records its plan was made from.
		if (resume == null || resume.split(".").length != 5) refresh(READ_REFRESH_SECONDS);
		var from = resumeFrom(connection, resume);
		var since = from.since, upto = from.upto, offset = from.offset, held = from.plan;
		var reset = since < 0;
		if (reset) since = 0;
		var records:CatalogSnapshot = held == null ? snapshot : held.snapshot;
		var describing = records.describing;
		var plan:Array<String> = held == null ? planFor(view, since, upto, reset, describing) : held.entries;
		var attention = (view.terminals ? records.terminalAttention : 0) + (view.sessions ? records.sessionAttention : 0);
		var result:WorkspaceCatalog = {
			ref: ref, instance: instance, token: "", reset: reset, more: false,
			name: describing.name, folders: [], scratch: describing.scratch, status: "running", attention: attention,
			groups: [], sessions: [], terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: watching
		};
		var index = offset, count = 0;
		while (index < plan.length && count < WorkspaceCatalogProtocol.PAGE_LIMIT) {
			var entry = plan[index];
			var added = addTo(result, entry, records, false);
			if (added && !WorkspaceCatalogProtocol.fits(result)) {
				removeLast(result, entry);
				// Alone on a page and still too big: shorten its display name, and as a last resort leave it out (counted, logged once).
				if (count > 0) break;
				added = addTo(result, entry, records, true);
				if (added && !WorkspaceCatalogProtocol.fits(result)) {
					removeLast(result, entry);
					added = false;
					omitted++;
					if (!warned) {
						warned = true;
						Sys.stderr().writeString("catalog: an item is too large for a page and was left out: " + entry + "
");
					}
				}
			}
			index++;
			if (added) count++;
		}
		if (index < plan.length) {
			var kept = held == null ? keep(connection, plan, records) : held;
			result.more = true;
			result.token = instance + "." + since + "." + upto + "." + kept.id + "." + index;
		} else {
			if (held != null) plans.remove(held);
			result.token = instance + "." + upto;
		}
		return result;
	}

	/**
		The entries a read lists, in page order: on a reset every folder and item, otherwise the items changed after
		`since` and the removals since, up to `upto`. `f:<folder>`, `<kind>:<id>` to upsert, `-<kind>:<id>` removed.
	**/
	function planFor(view:CatalogView, since:Int, upto:Int, reset:Bool, describing:CatalogDescription):Array<String> {
		var plan:Array<String> = [];
		if (reset) for (folder in describing.folders) plan.push("f:" + folder);
		var keys = [for (key => item in items) if (visible(view, item.kind) && (reset || item.changed > since && item.changed <= upto)) key];
		keys.sort(function(a, b) {
			var left:CatalogItem = items.get(a), right:CatalogItem = items.get(b);
			var leftKind:Int = left.kind, rightKind:Int = right.kind;
			return leftKind != rightKind ? leftKind - rightKind : Reflect.compare(left.id, right.id);
		});
		for (key in keys) plan.push(key);
		if (!reset)
			for (removal in removals)
				if (removal.at > since && removal.at <= upto && visible(view, Std.parseInt(removal.key.substr(0, 1)))) plan.push("-" + removal.key);
		return plan;
	}

	/** A display name cut to SHRUNK_LENGTH, ending in an ellipsis so it cannot pass for the real name. Never used on paths or ids. */
	static function shrink(text:String, shrunk:Bool):String
		return shrunk && text.length > SHRUNK_LENGTH ? text.substr(0, SHRUNK_LENGTH - 1) + String.fromCharCode(0x2026) : text;

	/** Adds one planned entry to the page; false when it is gone since (its removal comes in a later read). */
	function addTo(page:WorkspaceCatalog, entry:String, records:CatalogSnapshot, shrunk:Bool):Bool {
		if (StringTools.startsWith(entry, "f:")) {
			page.folders.push(entry.substr(2));
			return true;
		}
		var isRemoval = StringTools.startsWith(entry, "-");
		var key = isRemoval ? entry.substr(1) : entry;
		var kind = Std.parseInt(key.substr(0, 1)), id = key.substr(2);
		if (isRemoval) {
			var removedId = id;
			switch kind {
				case 1: page.removedGroups.push(removedId);
				case 2: page.removedTerminals.push(removedId);
				default: page.removedSessions.push(removedId);
			}
			return true;
		}
		switch kind {
			case 1:
				var group = records.groups.get(id);
				if (group == null) return false;
				var cwd = group.cwd;
				page.groups.push({
					id: group.id, name: shrink(group.name, shrunk), cwd: cwd, revision: group.revision,
					parent: group.parent, order: group.order
				});
			case 2:
				var terminal = records.terminals.get(id);
				if (terminal == null) return false;
				var item = WorkspaceCatalogProtocol.terminal(terminal, terminalAttention(terminal));
				item.name = shrink(item.name, shrunk);
				page.terminals.push(item);
			default:
				var session = records.sessions.get(id);
				if (session == null) return false;
				var waiting = records.requests.get(id);
				var item = WorkspaceCatalogProtocol.session(session, WorkspaceCatalogProtocol.sessionAttention(session, waiting == null ? 0 : waiting));
				item.name = shrink(item.name, shrunk);
				page.sessions.push(item);
		}
		return true;
	}

	static function removeLast(page:WorkspaceCatalog, entry:String):Void {
		if (StringTools.startsWith(entry, "f:")) page.folders.pop();
		else if (StringTools.startsWith(entry, "-1:")) page.removedGroups.pop();
		else if (StringTools.startsWith(entry, "-2:")) page.removedTerminals.pop();
		else if (StringTools.startsWith(entry, "-")) page.removedSessions.pop();
		else if (StringTools.startsWith(entry, "1:")) page.groups.pop();
		else if (StringTools.startsWith(entry, "2:")) page.terminals.pop();
		else page.sessions.pop();
	}

	/** Keeps a plan for the connection's next page; a connection holds at most PLAN_LIMIT, the oldest going first. */
	function keep(connection:RpcConnection, entries:Array<String>, records:CatalogSnapshot):CatalogPlan {
		var plan:CatalogPlan = {connection: connection, id: "p" + (nextPlan++), entries: entries, snapshot: records};
		plans.push(plan);
		var own = plans.filter(function(entry) return entry.connection == connection);
		for (index in 0...own.length - PLAN_LIMIT) plans.remove(own[index]);
		return plan;
	}

	function forgetPlans(connection:RpcConnection):Void {
		for (entry in plans.copy())
			if (entry.connection == connection) plans.remove(entry);
	}

	static function visible(view:CatalogView, kind:Null<Int>):Bool
		return kind == 1 ? view.groups : kind == 2 ? view.terminals : view.sessions;
}
