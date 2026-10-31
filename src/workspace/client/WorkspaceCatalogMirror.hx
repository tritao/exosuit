package workspace.client;

import workspace.service.WorkspaceCatalogProtocol.CatalogSession;
import workspace.service.WorkspaceCatalogProtocol.CatalogTerminal;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/**
	One workspace service's catalog as a window holds it: the workspace's own fields, its groups, and the sessions and
	terminals in them. Pages from CATALOG are applied in order: a reset replaces everything, a delta upserts and removes.
	It holds no content (docs/roadmap/RPC-VECTORS.md, "Workspace refs and the catalog watch").
**/
class WorkspaceCatalogMirror {
	public var name(default, null):String = "";
	public var folders(default, null):Array<String> = [];
	public var scratch(default, null):Null<String>;
	public var status(default, null):String = "";
	/** Sessions and terminals in the whole workspace that need attention. */
	public var attention(default, null):Int = 0;
	/** The service instance the data came from. */
	public var instance(default, null):String = "";
	/** Resumes after the last page applied; null before the first. */
	public var token(default, null):Null<String>;
	public final groups:Map<String, WorkspaceGroup> = [];
	public final sessions:Map<String, CatalogSession> = [];
	public final terminals:Map<String, CatalogTerminal> = [];
	/** True after a reset's first page and before its last (`more`): the copy is not whole yet. */
	public var partial(default, null):Bool = false;
	/** Counts the pages applied: sorted lists and projections built from this copy are valid for one revision. */
	public var revision(default, null):Int = 0;

	/** The longest name kept; a catalog is data from another process, so a label is clipped to what a row can show. */
	public static inline final MAX_LABEL = 256;

	final knownFolders:Map<String, Bool> = [];
	var listed = -1;
	var groupsSorted:Array<WorkspaceGroup> = [];
	var sessionsSorted:Array<CatalogSession> = [];
	var terminalsSorted:Array<CatalogTerminal> = [];

	public function new() {}

	/** Takes one page; a page with `reset` must go to a fresh mirror (see WorkspaceCatalogWatch). */
	public function apply(page:WorkspaceCatalog):Void {
		var resetting = page.reset || partial;
		// A change to the folders makes the next read a reset, so folders only come in resets, split across pages.
		if (resetting)
			for (folder in page.folders)
				if (!knownFolders.exists(folder)) {
					knownFolders.set(folder, true);
					folders.push(folder);
				}
		name = clip(page.name);
		scratch = page.scratch;
		status = page.status;
		attention = page.attention;
		instance = page.instance;
		// Removals first: an id removed and added again in one page survives.
		for (id in page.removedGroups)
			groups.remove(id);
		for (id in page.removedSessions)
			sessions.remove(id);
		for (id in page.removedTerminals)
			terminals.remove(id);
		for (group in page.groups) {
			group.name = clip(group.name);
			groups.set(group.id, group);
		}
		for (session in page.sessions) {
			session.name = clip(session.name);
			sessions.set(session.id, session);
		}
		for (terminal in page.terminals) {
			terminal.name = clip(terminal.name);
			terminals.set(terminal.id, terminal);
		}
		token = page.token;
		partial = resetting && page.more;
		revision++;
	}

	static function clip(text:String):String
		return text.length > MAX_LABEL ? text.substr(0, MAX_LABEL) : text;

	/** Groups, sessions, terminals and folders held: what a staged copy is bounded by. */
	public function itemCount():Int
		return Lambda.count(groups) + Lambda.count(sessions) + Lambda.count(terminals) + folders.length;

	/** The groups sorted by id. The list is cached per revision: do not change it. */
	public function groupList():Array<WorkspaceGroup> {
		sort();
		return groupsSorted;
	}

	public function sessionList():Array<CatalogSession> {
		sort();
		return sessionsSorted;
	}

	public function terminalList():Array<CatalogTerminal> {
		sort();
		return terminalsSorted;
	}

	function sort():Void {
		if (listed == revision)
			return;
		listed = revision;
		groupsSorted = [for (group in groups) group];
		groupsSorted.sort(function(a, b) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
		sessionsSorted = [for (session in sessions) session];
		sessionsSorted.sort(function(a, b) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
		terminalsSorted = [for (terminal in terminals) terminal];
		terminalsSorted.sort(function(a, b) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
	}
}
