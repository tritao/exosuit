package workspace.runtime;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import workspace.service.WorkspaceCatalogProtocol;
import workspace.service.WorkspaceCatalogProtocol.WorkspaceRef;

/**
	Keeps the service's `catalog-snapshot.bin` (WorkspaceCatalogProtocol.SNAPSHOT_FILE) in its state folder: the whole
	catalog, written once it has stopped changing for a check (at most every CHECK_SECONDS, so a burst writes once) or
	MAX_DELAY_SECONDS after the first change of a stream that does not stop, and always on exit. Editors draw an idle
	workspace's rows from it without starting anything.
**/
class CatalogSnapshotFile {
	static inline final CHECK_SECONDS = 1.0;
	static inline final MAX_DELAY_SECONDS = 5.0;

	final path:String;
	final catalog:WorkspaceCatalogService;
	final ref:WorkspaceRef;
	final clock:Void->Float;
	var written = -1;
	var seen = -1;
	var checkedAt = -1000.0;
	var changedAt = -1.0;

	/** `clock` in seconds. */
	public function new(stateDirectory:String, workspace:String, catalog:WorkspaceCatalogService, clock:Void->Float) {
		path = Path.join([stateDirectory, WorkspaceCatalogProtocol.SNAPSHOT_FILE]);
		this.catalog = catalog;
		this.ref = {machine: "", workspace: workspace};
		this.clock = clock;
	}

	/** Call from the service's loop. */
	public function poll():Void {
		var now = clock();
		if (now - checkedAt < CHECK_SECONDS) return;
		checkedAt = now;
		var revision = catalog.notice();
		if (revision == written) {
			changedAt = -1;
			seen = revision;
			return;
		}
		if (changedAt < 0) changedAt = now;
		if (revision == seen || now - changedAt >= MAX_DELAY_SECONDS) write();
		seen = revision;
	}

	/** Writes the catalog as it is now; the service's exit calls it. A failure is logged, never thrown. */
	public function write():Void {
		try {
			var page = catalog.whole(ref);
			var bytes = WorkspaceCatalogProtocol.encodeSnapshot(page);
			if (FileSystem.exists(path)) AtomicFile.writeBytes(path, bytes) else AtomicFile.createBytes(path, bytes);
			written = catalog.notice();
			changedAt = -1;
		} catch (error:Dynamic) {
			ServiceLog.note("catalog snapshot not written: " + Std.string(error));
		}
	}
}
