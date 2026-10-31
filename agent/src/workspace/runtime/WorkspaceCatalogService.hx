package workspace.runtime;

import haxeon.rpc.RpcConnection;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/** What the catalog says about the workspace itself; a change to any of it makes the next read a reset. */
typedef CatalogDescription = {
	var name:String;
	var folders:Array<String>;
	var scratch:Null<String>;
}

private typedef CatalogItem = {
	/** 0 folder, 1 group, 2 terminal, 3 session: the order a page lists them in. */
	var kind:Int;
	var id:String;
	var fingerprint:String;
	var changed:Int;
}

private typedef CatalogWatcher = {
	var connection:RpcConnection;
	var ref:WorkspaceRef;
}

/**
	The workspace's catalog watch (M19 Phase 6; protocol in docs/roadmap/RPC-VECTORS.md, "Workspace refs and the
	catalog watch"): CATALOG pages of groups, sessions and terminals with no content, resumable by token, and
	CHANGED hints to watching connections.

	Each item keeps the revision it last changed at, and removals are kept for a while, so a token
	`<instance>.<revision>` reads what changed since. A read that takes more than one page fixes its list of items
	when it starts (a plan, kept by id for a short while), so pages stay consistent while the catalog changes; a token
	`<instance>.<since>.<upto>.<plan>.<offset>` continues it. A token this service does not know, from another instance
	or for removals it no longer keeps, gives a reset.
**/
class WorkspaceCatalogService {
	static inline final REMOVAL_LIMIT = 1024;
	static inline final PLAN_LIMIT = 16;
	static inline final REFRESH_SECONDS = 0.1;

	final workspace:String;
	final instance:String;
	final describe:Void->CatalogDescription;
	final groups:Void->Array<WorkspaceGroup>;
	final sessions:Void->Array<AgentRecord>;
	final terminals:Void->Array<TerminalRecord>;
	final clock:Void->Float;
	final items:Map<String, CatalogItem> = [];
	final removals:Array<{key:String, at:Int}> = [];
	final plans:Map<String, Array<String>> = [];
	final planOrder:Array<String> = [];
	final watchers:Array<CatalogWatcher> = [];
	var revision = 0;
	/** Reads resuming from before this revision may have missed removals: they reset. */
	var removalFloor = 0;
	/** The workspace's own fields last changed at this revision: reads resuming from before it reset. */
	var describedAt = 0;
	var description = "";
	var nextPlan = 0;
	var refreshedAt = -1.0;

	/** `workspace` is the id this service answers to; a client may also name it "workspace" (RPC-VECTORS). */
	public function new(workspace:String, instance:String, describe:Void->CatalogDescription, groups:Void->Array<WorkspaceGroup>,
			sessions:Void->Array<AgentRecord>, terminals:Void->Array<TerminalRecord>, clock:Void->Float) {
		this.workspace = workspace;
		this.instance = instance;
		this.describe = describe;
		this.groups = groups;
		this.sessions = sessions;
		this.terminals = terminals;
		this.clock = clock;
		refresh();
	}

	/** Registers CATALOG and UNWATCH on a connection granted the capability; returns its cleanup. */
	public function bind(connection:RpcConnection, capabilities:Array<String>):Void->Void {
		if (capabilities.indexOf(WorkspaceCatalogProtocol.CAPABILITY) < 0) return function() {};
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
			if (query.watch && !Lambda.exists(watchers, function(watcher) return watcher.connection == connection))
				watchers.push({connection: connection, ref: ref});
			refresh(true);
			context.respond(page(ref, query.resume, Lambda.exists(watchers, function(watcher) return watcher.connection == connection)));
		});
		connection.register(WorkspaceCatalogProtocol.UNWATCH, function(ref, context) {
			if (!WorkspaceCatalogProtocol.validRef(ref)) {
				context.fail({code: "invalid_request", message: "Invalid workspace", ambiguous: false});
				return;
			}
			unwatch(connection);
			context.respond({machine: ref.machine, workspace: workspace});
		});
		return function() unwatch(connection);
	}

	/** Called every service tick: notices changes (at most every REFRESH_SECONDS while anyone watches) and hints watchers. */
	public function poll():Void {
		for (watcher in watchers.copy())
			if (!watcher.connection.isOpen()) watchers.remove(watcher);
		if (watchers.length > 0) refresh();
	}

	public function watcherCount():Int
		return watchers.length;

	function unwatch(connection:RpcConnection):Void {
		for (watcher in watchers.copy())
			if (watcher.connection == connection) watchers.remove(watcher);
	}

	/** Compares the catalog with what it was; anything new, changed or gone moves the revision on once. */
	function refresh(now = false):Void {
		var time = clock();
		if (!now && refreshedAt >= 0 && time - refreshedAt < REFRESH_SECONDS) return;
		refreshedAt = time;
		var next = revision + 1, changed = false;
		var current = new Map<String, Bool>();
		var describing = describe();
		var described = describing.name + "|" + describing.folders.join("|") + "|" + (describing.scratch == null ? "-" : "+" + describing.scratch);
		if (described != description) {
			description = described;
			describedAt = next;
			changed = true;
		}
		function note(kind:Int, id:String, bytes:haxe.io.Bytes):Void {
			var key = kind + ":" + id, fingerprint = hex(bytes);
			current.set(key, true);
			var item = items.get(key);
			if (item == null) {
				items.set(key, {kind: kind, id: id, fingerprint: fingerprint, changed: next});
				changed = true;
			} else if (item.fingerprint != fingerprint) {
				item.fingerprint = fingerprint;
				item.changed = next;
				changed = true;
			}
		}
		for (group in groups()) note(1, group.id, MessagePack.encode(group));
		for (terminal in terminals()) {
			var entry = WorkspaceCatalogProtocol.terminal(terminal, terminalAttention(terminal));
			note(2, terminal.id, MessagePack.encode(entry));
		}
		for (session in sessions()) {
			var entry = WorkspaceCatalogProtocol.session(session, WorkspaceCatalogProtocol.sessionAttention(session, 0));
			note(3, session.id, MessagePack.encode(entry));
		}
		for (key in [for (key in items.keys()) key])
			if (!current.exists(key)) {
				items.remove(key);
				removals.push({key: key, at: next});
				changed = true;
			}
		while (removals.length > REMOVAL_LIMIT) removalFloor = removals.shift().at;
		if (!changed) return;
		revision = next;
		var token = instance + "." + revision;
		for (watcher in watchers.copy()) {
			if (!watcher.connection.isOpen()) {
				watchers.remove(watcher);
				continue;
			}
			watcher.connection.notify(WorkspaceCatalogProtocol.CHANGED, {ref: watcher.ref, token: token}, WorkspaceCatalogProtocol.encodeChange);
		}
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

	function page(ref:WorkspaceRef, resume:Null<String>, watching:Bool):WorkspaceCatalog {
		var since = -1, upto = revision, planId:Null<String> = null, offset = 0;
		var parts = resume == null ? [] : resume.split(".");
		if (parts.length >= 2 && parts[0] == instance) {
			var from = Std.parseInt(parts[1]);
			if (parts.length == 2 && from != null && from <= revision && from >= removalFloor && from >= describedAt) since = from;
			if (parts.length == 5 && from != null && plans.exists(parts[3])) {
				var end = Std.parseInt(parts[2]), at = Std.parseInt(parts[4]);
				if (end != null && at != null) {
					since = from;
					upto = end;
					planId = parts[3];
					offset = at;
				}
			}
		}
		var reset = since < 0;
		if (reset) since = 0;
		var describing = describe();
		var plan:Array<String>;
		var planned = planId;
		if (planned == null) {
			plan = planFor(since, upto, reset, describing);
		} else {
			plan = plans.get(planned);
		}
		var attention = 0;
		for (terminal in terminals()) attention += terminalAttention(terminal);
		for (session in sessions()) attention += WorkspaceCatalogProtocol.sessionAttention(session, 0);
		var result:WorkspaceCatalog = {
			ref: ref, instance: instance, token: "", reset: reset, more: false,
			name: describing.name, folders: [], scratch: describing.scratch, status: "running", attention: attention,
			groups: [], sessions: [], terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: watching
		};
		var groupsById = [for (group in groups()) group.id => group];
		var terminalsById = [for (terminal in terminals()) terminal.id => terminal];
		var sessionsById = [for (session in sessions()) session.id => session];
		var index = offset, count = 0;
		while (index < plan.length && count < WorkspaceCatalogProtocol.PAGE_LIMIT) {
			var entry = plan[index];
			var added = addTo(result, entry, describing, groupsById, terminalsById, sessionsById);
			if (added && !WorkspaceCatalogProtocol.fits(result)) {
				if (count == 0) throw "A catalog item does not fit a page";
				removeLast(result, entry);
				break;
			}
			index++;
			if (added) count++;
		}
		if (index < plan.length) {
			if (planned == null) planned = keep(plan);
			result.more = true;
			result.token = instance + "." + since + "." + upto + "." + planned + "." + index;
		} else {
			if (planned != null) forget(planned);
			result.token = instance + "." + upto;
		}
		return result;
	}

	/**
		The entries a read lists, in page order: on a reset every folder and item, otherwise the items changed after
		`since` and the removals since, up to `upto`. `f:<folder>`, `<kind>:<id>` to upsert, `-<kind>:<id>` removed.
	**/
	function planFor(since:Int, upto:Int, reset:Bool, describing:CatalogDescription):Array<String> {
		var plan:Array<String> = [];
		if (reset) for (folder in describing.folders) plan.push("f:" + folder);
		var keys = [for (key => item in items) if (reset || item.changed > since && item.changed <= upto) key];
		keys.sort(function(a, b) {
			var left:CatalogItem = items.get(a), right:CatalogItem = items.get(b);
			var leftKind:Int = left.kind, rightKind:Int = right.kind;
			return leftKind != rightKind ? leftKind - rightKind : Reflect.compare(left.id, right.id);
		});
		for (key in keys) plan.push(key);
		if (!reset) for (removal in removals) if (removal.at > since && removal.at <= upto) plan.push("-" + removal.key);
		return plan;
	}

	/** Adds one planned entry to the page; false when it is gone since (its removal comes in a later read). */
	function addTo(page:WorkspaceCatalog, entry:String, describing:CatalogDescription, groupsById:Map<String, WorkspaceGroup>,
			terminalsById:Map<String, TerminalRecord>, sessionsById:Map<String, AgentRecord>):Bool {
		if (StringTools.startsWith(entry, "f:")) {
			page.folders.push(entry.substr(2));
			return true;
		}
		var removed = StringTools.startsWith(entry, "-");
		var key = removed ? entry.substr(1) : entry;
		var kind = Std.parseInt(key.substr(0, 1)), id = key.substr(2);
		if (removed) {
			switch kind {
				case 1: page.removedGroups.push(id);
				case 2: page.removedTerminals.push(id);
				default: page.removedSessions.push(id);
			}
			return true;
		}
		switch kind {
			case 1:
				var group = groupsById.get(id);
				if (group == null) return false;
				page.groups.push(group);
			case 2:
				var terminal = terminalsById.get(id);
				if (terminal == null) return false;
				page.terminals.push(WorkspaceCatalogProtocol.terminal(terminal, terminalAttention(terminal)));
			default:
				var session = sessionsById.get(id);
				if (session == null) return false;
				page.sessions.push(WorkspaceCatalogProtocol.session(session, WorkspaceCatalogProtocol.sessionAttention(session, 0)));
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

	function keep(plan:Array<String>):String {
		var id = "p" + (nextPlan++);
		plans.set(id, plan);
		planOrder.push(id);
		while (planOrder.length > PLAN_LIMIT) plans.remove(planOrder.shift());
		return id;
	}

	function forget(id:String):Void {
		plans.remove(id);
		planOrder.remove(id);
	}
}
