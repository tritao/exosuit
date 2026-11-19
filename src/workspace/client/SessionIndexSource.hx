package workspace.client;

import workspace.client.WorkspaceCatalogMirror;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.sessions.SessionIndex;
import workspace.sessions.SessionIndex.SessionEntry;
import workspace.sessions.SessionIndex.SessionKind;
import workspace.sessions.SessionIndex.SessionState;

/**
	Builds a SessionIndex from workspace catalogs a client already holds (WorkspaceCatalogMirror: a link's watch, or the
	snapshot an idle service left), so the desktop and a paired phone use one path. `refresh` rebuilds the index only when
	a mirror changed, and then bumps its `revision`. exohost's `sessions` op uses `entriesOf` too.

	The catalog holds no timestamps, so `lastActive` is the time this source first saw a row or last saw its state change
	(milliseconds), and `last` is empty.
**/
class SessionIndexSource {
	static inline final MAX_PATH = 32;

	public final index:SessionIndex = new SessionIndex();
	/** When each row (workspace + id) was last seen to change, in milliseconds. */
	final changed:Map<String, {key:String, at:Float}> = [];
	var signature:Null<String>;

	public function new() {}

	/**
		Makes `index` current for these workspaces (id and name each); `mirrorOf` gives a workspace's catalog, or null when
		none is held. Returns the index.
	**/
	public function refresh(machineId:String, workspaces:Array<{id:String, name:String}>, mirrorOf:String->Null<WorkspaceCatalogMirror>):SessionIndex {
		var parts:Array<String> = [machineId];
		var mirrors:Array<Null<WorkspaceCatalogMirror>> = [];
		for (workspace in workspaces) {
			var mirror = mirrorOf(workspace.id);
			mirrors.push(mirror);
			parts.push(workspace.id + "|" + workspace.name + "|" + (mirror == null ? "-" : mirror.instance + ":" + mirror.token + ":" + mirror.revision));
		}
		var current = parts.join("\n");
		if (current == signature)
			return index;
		signature = current;
		var entries:Array<SessionEntry> = [];
		for (position in 0...workspaces.length) {
			var mirror = mirrors[position];
			if (mirror != null && !mirror.partial)
				entries = entries.concat(entriesOf(machineId, workspaces[position].id, workspaces[position].name, mirror));
		}
		index.replace(entries);
		return index;
	}

	/** The sessions and terminals of one workspace's catalog as entries. */
	public function entriesOf(machineId:String, workspaceId:String, workspaceName:String, mirror:WorkspaceCatalogMirror):Array<SessionEntry> {
		var result:Array<SessionEntry> = [];
		for (session in mirror.sessionList()) {
			var kind = switch session.provider {
				case null, "codex": SessionKind.Codex;
				case "claude": SessionKind.Claude;
				default: SessionKind.Other;
			};
			result.push(entry(machineId, workspaceId, workspaceName, mirror, session.id, session.name, session.group, kind,
				stateOf(session.state, session.attention)));
		}
		for (terminal in mirror.terminalList()) {
			var kind = switch terminal.agentProvider {
				case null, "": SessionKind.Terminal;
				case "codex": SessionKind.Codex;
				case "claude": SessionKind.Claude;
				default: SessionKind.Other;
			};
			result.push(entry(machineId, workspaceId, workspaceName, mirror, terminal.id, terminal.name, terminal.group, kind,
				stateOf(terminal.state, terminal.attention)));
		}
		return result;
	}

	function entry(machineId:String, workspaceId:String, workspaceName:String, mirror:WorkspaceCatalogMirror, id:String, name:String, group:String,
			kind:SessionKind, state:SessionState):SessionEntry {
		var path:Array<String> = [], names:Array<String> = [];
		var current = group;
		while (current != null && current.length > 0 && path.length < MAX_PATH) {
			var found = mirror.groups.get(current);
			if (found == null)
				break;
			path.unshift(found.id);
			names.unshift(found.name);
			current = found.parent;
		}
		return {
			id: id,
			name: name,
			machineId: machineId,
			workspaceId: workspaceId,
			workspaceName: workspaceName,
			groupPath: path,
			groupNames: names,
			kind: kind,
			state: state,
			lastActive: lastActive(workspaceId + "/" + id, (state : String)),
			last: ""
		};
	}

	function lastActive(row:String, key:String):Float {
		var now = Sys.time() * 1000;
		var known = changed.get(row);
		if (known == null || known.key != key) {
			changed.set(row, {key: key, at: now});
			return now;
		}
		return known.at;
	}

	/** Catalog states to the phone's four: needs-attention (or pending requests) attention, running/working working, exited exited, else idle. */
	public static function stateOf(state:String, attention:Int):SessionState {
		if (state == WorkspaceCatalogProtocol.NEEDS_ATTENTION || attention > 0)
			return SessionState.Attention;
		return switch state {
			case "working", "running", "starting", "creating", "reconnecting", "uncertain": SessionState.Working;
			case "exited": SessionState.Exited;
			default: SessionState.Idle;
		}
	}
}
