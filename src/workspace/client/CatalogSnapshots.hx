package workspace.client;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import workspace.service.WorkspaceCatalogProtocol;

private typedef Held = {
	var mirror:Null<WorkspaceCatalogMirror>;
	var bytes:Null<haxe.io.Bytes>;
	var checkedAt:Float;
}

/**
	The catalogs idle workspaces had when their services last ran: each service's `catalog-snapshot.bin` in its state
	folder (WorkspaceCatalogProtocol.SNAPSHOT_FILE), read without starting anything. A file is looked at no more than
	once per CHECK_MS, and decoded again only when its bytes changed.
**/
class CatalogSnapshots {
	static inline final CHECK_MS = 2000.0;
	/** A snapshot larger than this is not read: the service writes far less for any catalog it can serve. */
	static inline final MAX_BYTES = 64 * 1024 * 1024;

	final base:Null<String>;
	final clock:Void->Float;
	final held:Map<String, Held> = [];
	/** Changes whenever a snapshot is read or goes. */
	public var revision(default, null):Int = 0;

	/** `base` is the folder holding `workspaces/<id>` (suit.MachineCatalog.agentStateBase()); null reads nothing. */
	public function new(base:Null<String>, clock:Void->Float) {
		this.base = base;
		this.clock = clock;
	}

	/** Workspace `id`'s last catalog, or null when it never ran here or its snapshot cannot be read. */
	public function of(id:String):Null<WorkspaceCatalogMirror> {
		var root = base;
		if (root == null || !validId(id)) return null;
		var now = clock();
		var entry = held.get(id);
		if (entry != null && now - entry.checkedAt < CHECK_MS) return entry.mirror;
		if (entry == null) {
			entry = {mirror: null, bytes: null, checkedAt: now};
			held.set(id, entry);
		}
		entry.checkedAt = now;
		var path = Path.join([root, "workspaces", id, WorkspaceCatalogProtocol.SNAPSHOT_FILE]);
		var bytes:Null<haxe.io.Bytes> = null;
		try {
			if (FileSystem.exists(path)) bytes = File.getBytes(path);
		} catch (_:Dynamic) {}
		if (bytes != null && bytes.length > MAX_BYTES) bytes = null;
		var before = entry.bytes;
		if (bytes == null && before == null || bytes != null && before != null && bytes.compare(before) == 0) return entry.mirror;
		entry.bytes = bytes;
		var mirror:Null<WorkspaceCatalogMirror> = null;
		if (bytes != null)
			try {
				var page = WorkspaceCatalogProtocol.decodeSnapshot(bytes);
				if (page != null && page.reset && !page.more) {
					mirror = new WorkspaceCatalogMirror();
					mirror.apply(page);
				}
			} catch (_:Dynamic) {
				mirror = null;
			}
		entry.mirror = mirror;
		revision++;
		return mirror;
	}

	/** Workspace ids name a folder: only the agent's own spelling (AgentStateIdentity.validWorkspaceId) is read. */
	static function validId(id:String):Bool
		return id.length > 0 && id.length <= 128 && ~/^[a-z0-9_-]+$/.match(id);
}
