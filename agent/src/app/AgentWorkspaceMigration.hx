package app;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.wire.MessagePack;
import sqlitekit.Database;
import sqlitekit.Statement;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import workspace.PathKey;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/** One file of a backup: its path (with `/`) relative to the backup, its size and its SHA-256. */
typedef BackupFile = {
	var path:String;
	var size:Int;
	var sha256:String;
}

/** One folder whose old state a workspace took in: where it was, and its backup. */
typedef MigratedFolder = {
	var root:String;
	var from:String;
	var backup:String;
	/** Set once `restore` has put this folder's backup back; the folder is then no longer part of the workspace. */
	var restored:Bool;
	/** Set before `restore` swaps this folder's backup in, and cleared when it says `restored`: a stop between leaves it. */
	var restoring:Bool;
}

/**
	Moves a workspace's folders' old state (`workspaces/<hash of the folder>`, from before services were keyed by
	workspace id) into the workspace's own state, once per folder (docs/roadmap/19-machine-workspaces.md, Phase 4).

	For each folder with old state: lock it (asking its service to stop first, as suit does), back it up beside itself
	(`<state>.bak-<time>`), move its catalog in, verify that every group, session and terminal arrived, then mark the
	old state as moved (see AgentStateIdentity) and record the folder in `migration.json`. A second run finds the record
	and changes nothing. Anything it does not recognise (a file it does not know, a foreign identity, a catalog over the
	service's limits) makes it refuse and leave that folder's old state in place.

	A workspace's first old catalog becomes its catalog. When it takes in several, each folder's groups, sessions and
	terminals go under a new top-level group named after the folder, and the catalog gets a new epoch, so clients load it
	afresh rather than resume.

	`restore` undoes it: the backups go back where they were, and the workspace's state is set aside.
**/
@:access(app.AgentManager)
class AgentWorkspaceMigration {
	public static inline final RECORD = "migration.json";
	/** The workspace's last start warnings, for whatever starts or shows the workspace (the manager log has them too). */
	public static inline final NOTICES = "start-notices.json";
	static inline final NOTICE_COUNT = 32;
	static inline final NOTICE_LENGTH = 1000;
	static inline final CATALOG = "catalog.sqlite";
	/** Written last into a backup, once every file in it has been checked: a backup without it is incomplete. */
	/** The first catalog is built under this name beside the target, then renamed into place. */
	static inline final STAGING = ".migrating";
	/** A carried directory is copied under this suffix, then renamed. */
	static inline final COPYING = ".copying";
	static inline final MANIFEST = "backup-manifest.json";
	static inline final GROUP_LIMIT = 32;
	static inline final AGENT_LIMIT = 32;
	static inline final TERMINAL_LIMIT = 256;
	/**
		What leaves a folder's old state once its catalog is in the workspace: the catalog, and what belonged to the
		service that ran there. Nothing else is ever removed: other files (rotated `manager.log.*`, relay and agent
		settings, files from builds this one does not know) stay, and are in the backup.
	**/
	static final MOVED:Array<String> = [CATALOG, CATALOG + "-wal", CATALOG + "-shm", CATALOG + "-journal", "endpoint.json", "credential", "stop-request.json"];
	/** What moves into the workspace's state with the first catalog: relay hosting and agent settings. */
	static final CARRIED:Array<String> = ["relay-settings.json", "relay-machine.json", "android-invitation.json", "agentkit"];

	/**
		Test only: called with a step name and the folder (or "") where a crash or failure can be simulated by throwing.
		Nothing in production sets it.
	**/
	public static var hook:Null<String->String->Void> = null;

	/** How long to wait for a folder's running service to stop when asked; tests shorten it. */
	public static var stopWaitSeconds = 20.0;

	static function step(name:String, detail:String = ""):Void {
		var found = hook;
		if (found != null) found(name, detail);
	}

	/**
		Takes in the old state of `identity`'s folders. `directory` is the workspace's state; the caller holds its lock.
		Returns start warnings, one per folder that could not be taken in or whose sessions live in another workspace:
		the workspace starts without that folder's old state, and the next start tries again.
	**/
	public static function run(identity:AgentStateIdentity, directory:String):Array<String> {
		var warnings:Array<String> = [];
		var workspace = identity.workspace;
		if (workspace == null) return warnings;
		var record = load(directory);
		setAsideUnowned(directory, workspace);
		var pending:Array<{folder:String, owner:String, state:String}> = [];
		for (folder in identity.folders) {
			try {
				var recorded = Lambda.find(record, function(entry) return PathKey.same(entry.root, folder));
				if (recorded != null) {
					if (recorded.restored || recorded.restoring) {
						// A restore that did not finish: this folder is back (or going back) where it was and must not be marked again.
						warnings.push('$folder\'s state was restored from its backup and is not part of this workspace');
						continue;
					}
					// Recorded before the old state was marked: a run stopped between the two; finish the marking.
					finishMarking(recorded, workspace);
					continue;
				}
				var state = oldState(folder);
				if (state == null || PathKey.same(state, directory)) continue;
				var old = AgentStateIdentity.read(Path.join([state, "workspace.json"]));
				if (old.migratedTo != null) {
					// Moved into this workspace before its record was written (an older build), or into another workspace.
					if (old.migratedTo != workspace) warnings.push(movedElsewhere(folder, old.migratedTo));
					continue;
				}
				if (old.workspace != null || !PathKey.same(old.key(), folder))
					throw 'Cannot migrate $state: it belongs to ${old.key()}, not $folder';
				pending.push({folder: folder, owner: old.key(), state: state});
			} catch (error:Dynamic) {
				warnings.push(failed(folder, error));
			}
		}
		var nested = pending.length > 1 || FileSystem.exists(Path.join([directory, CATALOG]));
		for (entry in pending) {
			var lock:Null<AgentManagerNative.AgentLockHandle> = null;
			try {
				lock = lockOldState(entry.state, entry.folder);
				var marker = AgentStateIdentity.read(Path.join([entry.state, "workspace.json"]));
				if (marker.migratedTo != null) {
					// Checked again under its lock: another workspace holding the same folder may have just taken it in.
					if (marker.migratedTo != workspace) warnings.push(movedElsewhere(entry.folder, marker.migratedTo));
				} else {
					var backup = backupFor(entry.state, record);
					step("backed-up", entry.folder);
					var fresh = takeIn(workspace, entry.folder, entry.owner, entry.state, directory, nested);
					step("imported", entry.folder);
					// Recorded, with the backup's path, before the old state is marked: a stop between the two leaves the
					// way back in the record, and the next start finishes the marking.
					var added = {root: entry.folder, from: entry.state, backup: backup, restored: false, restoring: false};
					record.push(added);
					try save(directory, workspace, record) catch (error:Dynamic) {
						record.remove(added);
						throw error;
					}
					step("recorded", entry.folder);
					AgentStateIdentity.markMigrated(Path.join([entry.state, "workspace.json"]), entry.folder, workspace);
					step("marked", entry.folder);
					// What moved is no longer needed there; the backup keeps everything. Settings carried only with the
					// first catalog stay with the others'. Files this does not name are never removed.
					for (name in fresh ? MOVED.concat(CARRIED) : MOVED)
						try remove(Path.join([entry.state, name])) catch (_:Dynamic) {}
				}
			} catch (error:Dynamic) {
				warnings.push(failed(entry.folder, error));
			}
			if (lock != null) AgentManagerNative.releaseLock(lock);
		}
		return warnings;
	}

	/** Records the start's warnings in `start-notices.json`, replacing the last start's; writes nothing when there are none and never were. */
	public static function writeNotices(directory:String, notices:Array<String>):Void {
		var path = Path.join([directory, NOTICES]);
		if (notices.length == 0 && !FileSystem.exists(path)) return;
		// One long error must not push the file past what a reader accepts, which would drop every notice.
		var capped = [for (notice in notices.slice(0, NOTICE_COUNT)) notice.length > NOTICE_LENGTH ? notice.substr(0, NOTICE_LENGTH) + "..." : notice];
		var content = Json.stringify({version: 1, notices: capped}) + "\n";
		if (FileSystem.exists(path)) AtomicFile.write(path, content) else AtomicFile.create(path, content);
	}

	/** The warnings the workspace's last start recorded; none when the file is missing or unreadable. */
	public static function readNotices(directory:String):Array<String> {
		var path = Path.join([directory, NOTICES]);
		var result:Array<String> = [];
		if (!FileSystem.exists(path)) return result;
		try {
			var listed:Dynamic = Reflect.field(AgentManager.readPrivateJson(path, 65536), "notices");
			if (Std.isOfType(listed, Array)) for (entry in (listed : Array<Dynamic>)) if (Std.isOfType(entry, String)) result.push(entry);
		} catch (_:Dynamic) {}
		return result;
	}

	static function failed(folder:String, error:Dynamic):String
		return 'The sessions of $folder were not taken into this workspace and are left where they were; the next start tries again: ' + Std.string(error);

	static function movedElsewhere(folder:String, workspace:String):String
		return '$folder\'s sessions are in workspace $workspace';

	/** Marks a recorded folder's old state as moved, when a run stopped after recording it and before marking it. */
	static function finishMarking(entry:MigratedFolder, workspace:String):Void {
		var identityPath = Path.join([entry.from, "workspace.json"]);
		if (!FileSystem.exists(identityPath)) return;
		// Marked and recorded, but a stop came before the moved files were removed: remove what remains.
		if (AgentStateIdentity.read(identityPath).migratedTo == workspace) {
			for (name in MOVED) try remove(Path.join([entry.from, name])) catch (_:Dynamic) {}
			return;
		}
		var unmarked = function():Bool {
			var marker = AgentStateIdentity.read(identityPath);
			return marker.migratedTo == null && marker.workspace == null && PathKey.same(marker.key(), entry.root);
		};
		if (!unmarked()) return;
		var lock = lockOldState(entry.from, entry.root);
		try {
			if (unmarked()) {
				AgentStateIdentity.markMigrated(identityPath, entry.root, workspace);
				for (name in MOVED) try remove(Path.join([entry.from, name])) catch (_:Dynamic) {}
			}
		} catch (error:Dynamic) {
			AgentManagerNative.releaseLock(lock);
			throw error;
		}
		AgentManagerNative.releaseLock(lock);
	}

	/**
		A folder's old state: `workspaces/<hash of the folder>`, or, when the folder is spelled differently from how its
		service spelled it (case, separators), the state whose workspace.json names the same folder. Null when it has none.
	**/
	static function oldState(folder:String):Null<String> {
		var hashed = AgentManager.folderStateDirectory(folder);
		if (FileSystem.exists(Path.join([hashed, "workspace.json"]))) return hashed;
		var workspaces = Path.join([AgentManager.stateBase(), "workspaces"]);
		if (!FileSystem.exists(workspaces)) return null;
		for (name in FileSystem.readDirectory(workspaces)) {
			if (!~/^[0-9a-f]{20}$/.match(name)) continue;
			var state = Path.join([workspaces, name]);
			try {
				var identity = AgentStateIdentity.read(Path.join([state, "workspace.json"]));
				if (identity.workspace == null && identity.migratedTo == null && PathKey.same(identity.key(), folder)) return state;
			} catch (_:Dynamic) {}
		}
		return null;
	}

	/**
		`--restore-migration`: puts each migrated folder's backup back where its state was. The caller holds the
		workspace's lock and then sets the workspace's state aside (`<state>.restored-<time>`).

		Nothing changes until every backup has been checked completely (it has its manifest, and every file's size and hash
		match) and every folder's state has been looked at: it must be marked as moved into this workspace, or already be
		the backup's content. Then each folder is rebuilt in `<state>.restoring`, checked, and swapped in with renames (the
		state it replaces is kept as `<state>.migrated-<time>`). A failure partway leaves every folder either restored or
		as it was, and running it again finishes the rest.

		Folders marked as moved here that the record has no entry for (a stop between marking and recording, in older
		builds) are found by their backups.
	**/
	public static function restore(directory:String, workspace:String):Array<MigratedFolder> {
		var record = load(directory);
		for (entry in unrecorded(workspace, record)) record.push(entry);
		var stamp = timestamp();
		var manifests:Array<Array<BackupFile>> = [];
		for (entry in record) {
			// Put back by an earlier run: what the folder holds now is its own, and no concern of this one.
			if (entry.restored) {
				manifests.push([]);
				continue;
			}
			if (!FileSystem.isDirectory(entry.backup)) throw 'The backup ${entry.backup} is missing; nothing was restored';
			var files = readManifest(entry.backup);
			verifyTree(entry.backup, files);
			manifests.push(files);
			if (FileSystem.exists(entry.from)) {
				var marker = AgentStateIdentity.read(Path.join([entry.from, "workspace.json"]));
				if (marker.migratedTo != null) {
					if (marker.migratedTo != workspace)
						throw '${entry.from} was moved into workspace ${marker.migratedTo}, not this one; nothing was restored';
				} else if (!holds(entry.from, files)) {
					throw '${entry.from} is in use again; nothing was restored';
				}
			}
		}
		for (index in 0...record.length) {
			var entry = record[index], files = manifests[index];
			if (entry.restored) continue;
			// Put back by an earlier, interrupted run that stopped before saying so.
			if (FileSystem.exists(entry.from) && holds(entry.from, files)) {
				entry.restored = true;
				entry.restoring = false;
				save(directory, workspace, record);
				continue;
			}
			step("restore-folder", entry.root);
			var staging = entry.from + ".restoring";
			remove(staging);
			try {
				copyTree(entry.backup, staging, "", []);
				verifyTree(staging, files);
			} catch (error:Dynamic) {
				try remove(staging) catch (_:Dynamic) {}
				throw error;
			}
			// Said in the record before the swap: a stop after the rename and before the next save must not leave a
			// restored folder that a normal start would take for an interrupted migration and mark again.
			entry.restoring = true;
			save(directory, workspace, record);
			var aside:Null<String> = null;
			try {
				step("restore-swap", entry.root);
				if (FileSystem.exists(entry.from)) {
					var moved = freeName(entry.from + ".migrated-" + stamp);
					FileSystem.rename(entry.from, moved);
					aside = moved;
				}
				FileSystem.rename(staging, entry.from);
			} catch (error:Dynamic) {
				// Put the folder back as it was, and leave no half-built copy.
				entry.restoring = false;
				try save(directory, workspace, record) catch (_:Dynamic) {}
				var kept = aside;
				if (kept != null && !FileSystem.exists(entry.from)) try FileSystem.rename(kept, entry.from) catch (_:Dynamic) {}
				try remove(staging) catch (_:Dynamic) {}
				throw error;
			}
			step("restore-swapped", entry.root);
			// Said in the record at once, so that a start before the rest is restored leaves this folder alone.
			entry.restored = true;
			entry.restoring = false;
			save(directory, workspace, record);
		}
		return record;
	}

	/** Whether `directory` is exactly the backup's content. */
	static function holds(directory:String, files:Array<BackupFile>):Bool {
		try {
			verifyTree(directory, files);
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	static function freeName(path:String):String {
		var name = path, suffix = 1;
		while (FileSystem.exists(name)) name = path + "-" + (++suffix);
		return name;
	}

	/** Old folder states marked as moved into `workspace` that `record` has no entry for, with their latest complete backup. */
	static function unrecorded(workspace:String, record:Array<MigratedFolder>):Array<MigratedFolder> {
		var found:Array<MigratedFolder> = [];
		var workspaces = Path.join([AgentManager.stateBase(), "workspaces"]);
		if (!FileSystem.exists(workspaces)) return found;
		for (name in FileSystem.readDirectory(workspaces)) {
			if (!~/^[0-9a-f]{20}$/.match(name)) continue;
			var state = Path.join([workspaces, name]);
			var marker:Null<AgentStateIdentity> = null;
			try marker = AgentStateIdentity.read(Path.join([state, "workspace.json"])) catch (_:Dynamic) {}
			var moved = marker;
			if (moved == null || moved.migratedTo != workspace) continue;
			if (Lambda.exists(record, function(entry) return PathKey.same(entry.from, state))) continue;
			var backups = [for (entry in FileSystem.readDirectory(workspaces)) if (StringTools.startsWith(entry, name + ".bak-")) entry];
			backups.sort(function(left, right) return left < right ? 1 : left > right ? -1 : 0);
			var chosen:Null<String> = null;
			for (entry in backups) {
				var path = Path.join([workspaces, entry]);
				try {
					verifyTree(path, readManifest(path));
					chosen = path;
					break;
				} catch (_:Dynamic) {}
			}
			var backup = chosen;
			if (backup == null) throw '$state says it moved into workspace $workspace, but has no complete backup to restore from; nothing was restored';
			var root = moved.root;
			found.push({root: root == null ? state : root, from: state, backup: backup, restored: false, restoring: false});
		}
		return found;
	}

	static function lockOldState(state:String, folder:String):AgentManagerNative.AgentLockHandle {
		var lockPath = Path.join([state, "agent.lock"]);
		var lock = AgentManagerNative.acquireLock(lockPath);
		if (lock != null) return lock;
		// Its service still runs: ask it to stop, as suit's Stop does, and wait for it.
		try {
			var endpoint = AgentManager.readPrivateJson(Path.join([state, "endpoint.json"]), 16384);
			suit.WorkspaceStopRequest.write(state, AgentManager.stringField(endpoint, "generation"));
		} catch (_:Dynamic) {}
		var deadline = Sys.time() + stopWaitSeconds;
		while (Sys.time() < deadline) {
			Sys.sleep(0.1);
			lock = AgentManagerNative.acquireLock(lockPath);
			if (lock != null) return lock;
		}
		// An older build does not read the request; do not leave it for whatever starts there next.
		try remove(suit.WorkspaceStopRequest.path(state)) catch (_:Dynamic) {}
		throw 'The service of the folder $folder is still running and did not stop when asked (an older build does not '
			+ "know how). Stop it from the Machine view or suit, then open the workspace again";
	}

	/**
		Copies `state` to `<state>.bak-<time>` and returns that path. Every file is published whole and flushed to disk
		(AtomicFile), is private to this user like the original, and is checked against the source's size and SHA-256
		before the manifest that completes the backup is written; nothing is removed from `state` before then.
	**/
	static function backUp(state:String):String {
		var backup = state + ".bak-" + timestamp(), suffix = 1;
		while (FileSystem.exists(backup)) backup = state + ".bak-" + timestamp() + "-" + (++suffix);
		var files:Array<BackupFile> = [];
		try {
			copyTree(state, backup, "", files);
			verifyTree(backup, files);
			AtomicFile.create(Path.join([backup, MANIFEST]), Json.stringify({version: 1, files: files}) + "\n");
		} catch (error:Dynamic) {
			try remove(backup) catch (_:Dynamic) {}
			throw error;
		}
		return backup;
	}

	/**
		The backup to take before moving `state`: the existing one when it is complete and `state` still matches it
		exactly (a folder that fails every start does not pile up copies), else a new one. Other backups of this state
		that no record refers to are removed first, so at most one stays besides those a record keeps. A failure leaves
		the backup in place for the next attempt to reuse.
	**/
	static function backupFor(state:String, record:Array<MigratedFolder>):String {
		var name = Path.withoutDirectory(state) + ".bak-", parent = Path.directory(state);
		var candidates = [for (entry in FileSystem.readDirectory(parent)) if (StringTools.startsWith(entry, name)) Path.join([parent, entry])];
		candidates.sort(function(left, right) return left < right ? 1 : left > right ? -1 : 0);
		var reuse:Null<String> = null;
		for (path in candidates) {
			if (Lambda.exists(record, function(entry) return PathKey.same(entry.backup, path))) continue;
			try {
				var files = readManifest(path);
				verifyTree(path, files);
				verifyTree(state, files, true);
				reuse = path;
				break;
			} catch (_:Dynamic) {}
		}
		// The new backup is taken and checked before any older one is removed.
		var kept = reuse;
		var current = kept != null ? kept : backUp(state);
		for (path in candidates) {
			if (path == current) continue;
			if (Lambda.exists(record, function(entry) return PathKey.same(entry.backup, path))) continue;
			try remove(path) catch (_:Dynamic) {}
		}
		return current;
	}

	static function skipped(name:String):Bool
		return name == "agent.lock" || name == MANIFEST || StringTools.endsWith(name, ".sqlitekit-lock");

	/**
		Copies the files under `source` into `destination`, recording each in `files`. A file is read once: its hash is
		of the bytes written. Directories and files are private to this user: a private directory passes that to what
		is created in it on Windows, and AtomicFile creates files owner-only elsewhere (`privateFile` checks either).
	**/
	static function copyTree(source:String, destination:String, prefix:String, files:Array<BackupFile>):Void {
		if (!AgentManagerNative.prepareDirectory(destination)) throw 'Could not create a private folder: $destination';
		for (name in FileSystem.readDirectory(source)) {
			var from = Path.join([source, name]), to = Path.join([destination, name]);
			var relative = prefix == "" ? name : prefix + "/" + name;
			if (FileSystem.isDirectory(from)) {
				copyTree(from, to, relative, files);
			} else if (!skipped(name)) {
				var bytes = File.getBytes(from);
				AtomicFile.createBytes(to, bytes);
				if (!AgentManagerNative.privateFile(to)) throw 'The copy of $from is not private to this user: $to';
				files.push({path: relative, size: bytes.length, sha256: hashOf(bytes)});
			}
		}
	}

	/** Throws unless the files under `directory` are exactly `files`, with their sizes and hashes. */
	static function verifyTree(directory:String, files:Array<BackupFile>, tolerateSidecars = false):Void {
		var found:Array<String> = [];
		listFiles(directory, "", found);
		if (tolerateSidecars) {
			// Opening a catalog in WAL mode (our own check of it, or the snapshot) leaves an index file and an empty log
			// beside it. They hold no data, so they do not make the state differ from a backup taken before.
			var listed = [for (file in files) file.path];
			found = found.filter(function(path) {
				if (listed.indexOf(path) >= 0) return true;
				if (StringTools.endsWith(path, "-shm")) return false;
				return !(StringTools.endsWith(path, "-wal") && File.getBytes(Path.join([directory, path])).length == 0);
			});
		}
		if (found.length != files.length) throw 'The copy in $directory has ${found.length} files, not ${files.length}';
		for (file in files) {
			var path = Path.join([directory, file.path]);
			if (found.indexOf(file.path) < 0 || !FileSystem.exists(path)) throw 'The copy in $directory lacks ${file.path}';
			var bytes = File.getBytes(path);
			if (bytes.length != file.size || hashOf(bytes) != file.sha256) throw 'The copy of ${file.path} in $directory differs from the original';
		}
	}

	static function listFiles(directory:String, prefix:String, found:Array<String>):Void {
		for (name in FileSystem.readDirectory(directory)) {
			var path = Path.join([directory, name]), relative = prefix == "" ? name : prefix + "/" + name;
			if (FileSystem.isDirectory(path)) listFiles(path, relative, found);
			else if (!skipped(name)) found.push(relative);
		}
	}

	public static function hashOf(bytes:Bytes):String {
		var digits = "0123456789abcdef", out = new StringBuf();
		var digest = Sha256.make(bytes);
		for (index in 0...digest.length) {
			var value = digest.get(index);
			out.add(digits.charAt(value >> 4));
			out.add(digits.charAt(value & 15));
		}
		return out.toString();
	}

	/** A backup's manifest; throws when the backup has none (it was never completed) or it is not one. */
	static function readManifest(backup:String):Array<BackupFile> {
		var path = Path.join([backup, MANIFEST]);
		if (!FileSystem.exists(path)) throw 'The backup $backup is incomplete (no manifest)';
		var value:Dynamic = Json.parse(File.getContent(path));
		var listed:Dynamic = value == null ? null : Reflect.field(value, "files");
		if (AgentManager.intField(value, "version") != 1 || !Std.isOfType(listed, Array)) throw 'Unrecognised $path';
		var files:Array<BackupFile> = [];
		for (entry in (listed : Array<Dynamic>)) {
			var name = AgentManager.stringField(entry, "path"), size = AgentManager.intField(entry, "size");
			var hash = AgentManager.stringField(entry, "sha256");
			if (name == "" || size < 0 || hash == "") throw 'Unrecognised $path';
			files.push({path: name, size: size, sha256: hash});
		}
		return files;
	}

	/**
		Moves one folder's catalog into the workspace's: as it is, or under a group named after the folder. The folder is
		recorded in the catalog's `workspace_migrations` in the same transaction, so a run that failed after committing
		does not take it in twice. Returns whether its catalog became the workspace's.
	**/
	static function takeIn(workspace:String, folder:String, owner:String, state:String, directory:String, nested:Bool):Bool {
		var source = Path.join([state, CATALOG]), target = Path.join([directory, CATALOG]);
		if (!FileSystem.exists(source)) return false;
		upgrade(source, owner);
		var expected = Catalog.read(source);
		if (FileSystem.exists(target) && takenIn(target, folder)) {
			Catalog.read(target).requireAll(expected, false);
			// The first folder's settings are copied after its catalog is in place; a stop in between left them out.
			var first = isFirst(target, folder);
			if (first) carry(state, directory);
			return first;
		}
		var fresh = !FileSystem.exists(target);
		// The first catalog is built beside the target and renamed into place once it is owned, recorded and checked, so
		// a crash or failure leaves no catalog at the target that a rerun could mistake for a finished one.
		var work = fresh ? target + STAGING : target;
		if (fresh) {
			discardCatalog(work);
			Database.snapshot(source, work);
			step("snapshot", folder);
		}
		var database = Database.open(work, 1000);
		try {
			database.begin();
			exec(database, "UPDATE workspace_meta SET root=?1 WHERE id=1", function(row) {
				row.bindText(1, AgentStateIdentity.catalogOwner(workspace));
			});
			database.exec("CREATE TABLE IF NOT EXISTS workspace_migrations (root TEXT PRIMARY KEY)");
			exec(database, "INSERT INTO workspace_migrations(root) VALUES(?1)", function(row) {
				row.bindText(1, PathKey.of(folder));
			});
			if (fresh && !nested) {
				database.commit();
			} else {
				var mapping = fresh ? nestInPlace(database, folder) : merge(database, source, folder);
				// A new epoch: a client holding the old one loads the catalog afresh instead of resuming into it.
				var epoch = AgentManagerNative.randomToken().substr(0, 32);
				exec(database, "UPDATE workspace_meta SET epoch=?1 WHERE id=1", function(row) {
					row.bindText(1, epoch);
				});
				database.exec("DELETE FROM workspace_operations");
				database.exec("DELETE FROM workspace_events");
				database.commit();
				expected = expected.renamed(mapping);
			}
		} catch (error:Dynamic) {
			try database.rollback() catch (_:Dynamic) {}
			database.close();
			if (fresh) discardCatalog(work);
			throw error;
		}
		database.close();
		try {
			Catalog.read(work).requireAll(expected, true);
			if (fresh) {
				for (name in [work + "-wal", work + "-shm", work + "-journal"])
					if (FileSystem.exists(name)) throw 'The new catalog was left with $name';
				step("before-rename", folder);
				FileSystem.rename(work, target);
				step("renamed", folder);
				// Only a catalog that is in place has its folder's settings: a failed first folder leaves none behind.
				carry(state, directory);
			}
		} catch (error:Dynamic) {
			if (fresh) discardCatalog(work);
			throw error;
		}
		return fresh;
	}

	/** Copies the first folder's relay and agent settings into the workspace's state, where it has none. */
	static function carry(state:String, directory:String):Void {
		for (name in CARRIED) {
			var from = Path.join([state, name]), to = Path.join([directory, name]);
			if (FileSystem.exists(from) && !FileSystem.exists(to)) {
				if (FileSystem.isDirectory(from)) {
					// Built under another name and renamed, so a stop mid-copy never leaves a half directory that a later
					// start would take for the whole; a leftover temporary copy is cleared first.
					var temporary = to + COPYING;
					remove(temporary);
					copyTree(from, temporary, "", []);
					step("carry-copied", name);
					FileSystem.rename(temporary, to);
				} else AtomicFile.createBytes(to, File.getBytes(from));
			} else if (!FileSystem.exists(to)) remove(to + COPYING);
		}
	}

	/** Whether `folder` was the first taken into the catalog at `target`: the one whose catalog became the workspace's. */
	static function isFirst(target:String, folder:String):Bool {
		var database = Database.open(target, 1000);
		var first = "";
		try {
			var row = database.prepare("SELECT root FROM workspace_migrations ORDER BY rowid LIMIT 1");
			if (row.step()) first = row.columnText(0);
			row.close();
		} catch (error:Dynamic) {
			database.close();
			throw error;
		}
		database.close();
		return first == PathKey.of(folder);
	}

	static function discardCatalog(path:String):Void {
		for (name in [path, path + "-wal", path + "-shm", path + "-journal"]) remove(name);
	}

	/**
		A catalog at the workspace's target that no migration finished: a copy of a folder's catalog that still names the
		folder as its owner and records no folder taken in (what an older build left when it stopped while snapshotting
		straight into the target). It is not the workspace's, so it is moved aside, not deleted, and the folder is migrated
		as the first one again.
	**/
	static function setAsideUnowned(directory:String, workspace:String):Void {
		var target = Path.join([directory, CATALOG]);
		if (!FileSystem.exists(target)) return;
		var database = Database.open(target, 1000);
		var owner = "", recorded = false;
		try {
			var row = database.prepare("SELECT root FROM workspace_meta WHERE id=1");
			if (row.step()) owner = row.columnText(0);
			row.close();
			recorded = hasTable(database, "workspace_migrations");
		} catch (error:Dynamic) {
			database.close();
			throw error;
		}
		database.close();
		if (owner == AgentStateIdentity.catalogOwner(workspace) || recorded) return;
		var aside = ".unfinished-" + timestamp();
		for (suffix in ["", "-wal", "-shm", "-journal"])
			if (FileSystem.exists(target + suffix)) FileSystem.rename(target + suffix, target + aside + suffix);
	}

	/** Whether the catalog at `target` has already taken in `folder`'s. */
	static function takenIn(target:String, folder:String):Bool {
		var database = Database.open(target, 1000);
		var found = false;
		try {
			if (hasTable(database, "workspace_migrations")) {
				var row = database.prepare("SELECT 1 FROM workspace_migrations WHERE root=?1");
				row.bindText(1, PathKey.of(folder));
				found = row.step();
				row.close();
			}
		} catch (error:Dynamic) {
			database.close();
			throw error;
		}
		database.close();
		return found;
	}

	/**
		Opens a folder's catalog as its service would: checks that it is `owner`'s (the folder as its service spelled it)
		and brings an older schema up to date, so it reads like a current one.
	**/
	static function upgrade(source:String, owner:String):Void {
		var seed = new workspace.service.WorkspaceService("workspace", AgentManagerNative.randomToken().substr(0, 32),
			[{id: "work", name: "Work", cwd: owner, revision: 1}]).snapshot();
		new workspace.storage.WorkspaceSqliteStore(source, "workspace", seed, 32, owner).close();
	}

	/** Puts the catalog's top-level groups and its ungrouped sessions and terminals under a new group named after `folder`. */
	static function nestInPlace(database:Database, folder:String):Map<String, String> {
		var catalog = Catalog.load(database);
		var top = folderGroup(folder, catalog.groups);
		insertGroup(database, top);
		for (group in catalog.groups)
			if (group.parent == null) {
				group.parent = top.id;
				group.revision++;
				writeGroup(database, group, true);
			}
		for (agent in catalog.agents)
			if (agent.group == "") {
					agent.group = top.id;
				writeAgent(database, agent, true);
			}
		for (terminal in catalog.terminals)
			if (terminal.group == "") {
				terminal.group = top.id;
				writeTerminal(database, terminal, true);
			}
		checkLimits(database);
		return ["" => top.id];
	}

	/**
		Copies `source`'s catalog into `database`'s under a new group named after `folder`; returns how group ids changed.

		Every table in the catalog schema (WorkspaceSqliteStore) is either carried or deliberately dropped:
		- `workspace_groups`, `workspace_agents`, `workspace_terminals`: carried (groups renamed where ids collide).
		- `workspace_terminal_history`, `workspace_agent_content`: carried; a row that collides must be identical, or the
		  merge fails (nothing is dropped silently).
		- `workspace_meta`: dropped. Owner, epoch and cursor are the workspace's own (the epoch is renewed).
		- `workspace_operations`, `workspace_events`: dropped. They replay a client's recent edits against the old epoch,
		  which a new epoch invalidates; the target's are cleared too.
		- `workspace_devices`: dropped. A device paired with one folder's service is not paired with the workspace; the
		  first catalog's devices stay (it is the workspace's identity, with its relay-machine.json), later ones re-pair.
		- `workspace_agent_content_meta`: dropped. A schema version row; the target keeps its own.
		- `workspace_migrations`: the target's own record of folders taken in.
	**/
	static function merge(database:Database, source:String, folder:String):Map<String, String> {
		var existing = Catalog.load(database);
		var incoming = Catalog.read(source);
		var top = folderGroup(folder, existing.groups);
		insertGroup(database, top);
		var mapping:Map<String, String> = ["" => top.id];
		var taken = [for (group in existing.groups) group.id => true];
		taken.set(top.id, true);
		for (group in incoming.groups) mapping.set(group.id, taken.exists(group.id) ? freshGroupId() : group.id);
		for (group in incoming.groups) {
			var parent = group.parent;
			group.id = mapping.get(group.id);
			group.parent = parent == null ? top.id : mapping.exists(parent) ? mapping.get(parent) : top.id;
			insertGroup(database, group);
		}
		for (agent in incoming.agents) {
			if (Lambda.exists(existing.agents, function(other) return other.id == agent.id)) throw 'Session ${agent.id} is in two folders\' catalogs';
			agent.group = mapping.exists(agent.group) ? mapping.get(agent.group) : top.id;
			writeAgent(database, agent, false);
		}
		for (terminal in incoming.terminals) {
			if (Lambda.exists(existing.terminals, function(other) return other.id == terminal.id)) throw 'Terminal ${terminal.id} is in two folders\' catalogs';
			terminal.group = mapping.exists(terminal.group) ? mapping.get(terminal.group) : top.id;
			writeTerminal(database, terminal, false);
		}
		var copy = Database.open(source, 1000);
		try {
			var history = copy.prepare("SELECT id,payload FROM workspace_terminal_history");
			while (history.step()) {
				var id = history.columnText(0), payload = history.columnBlob(1);
				exec(database, "INSERT INTO workspace_terminal_history(id,payload) VALUES(?1,?2)", function(row) {
					row.bindText(1, id);
					row.bindBlob(2, payload);
				});
			}
			history.close();
			if (hasTable(copy, "workspace_agent_content")) {
				var content = copy.prepare("SELECT provider,session,turn,item,payload,partial FROM workspace_agent_content ORDER BY seq");
				while (content.step()) {
					var provider = content.columnText(0), session = content.columnText(1), turn = content.columnText(2), item = content.columnText(3);
					var payload = content.columnBlob(4), partial = content.columnInt64(5);
					var key = provider + "/" + session + "/" + turn + "/" + item;
					var held = database.prepare("SELECT payload,partial FROM workspace_agent_content WHERE provider=?1 AND session=?2 AND turn=?3 AND item=?4");
					var present = false, identical = false;
					try {
						held.bindText(1, provider);
						held.bindText(2, session);
						held.bindText(3, turn);
						held.bindText(4, item);
						if (held.step()) {
							present = true;
							identical = hashOf(held.columnBlob(0)) == hashOf(payload) && held.columnInt64(1) == partial;
						}
					} catch (error:Dynamic) {
						held.close();
						throw error;
					}
					held.close();
					// In both catalogs: identical content is already there; different content is a real collision.
					if (present && !identical) throw 'Stored content $key differs between the folders\' catalogs';
					if (!present)
						exec(database, "INSERT INTO workspace_agent_content(provider,session,turn,item,payload,partial) VALUES(?1,?2,?3,?4,?5,?6)",
							function(row) {
								row.bindText(1, provider);
								row.bindText(2, session);
								row.bindText(3, turn);
								row.bindText(4, item);
								row.bindBlob(5, payload);
								row.bindInt64(6, partial);
							});
				}
				content.close();
			}
		} catch (error:Dynamic) {
			copy.close();
			throw error;
		}
		copy.close();
		checkLimits(database);
		return mapping;
	}

	static function checkLimits(database:Database):Void {
		var catalog = Catalog.load(database);
		if (catalog.groups.length > GROUP_LIMIT || catalog.agents.length > AGENT_LIMIT || catalog.terminals.length > TERMINAL_LIMIT)
			throw 'Together the folders have more groups, sessions or terminals than a workspace holds ($GROUP_LIMIT, $AGENT_LIMIT, $TERMINAL_LIMIT)';
	}

	/** A new top-level group for `folder`'s work, last among the existing top-level groups. */
	static function folderGroup(folder:String, groups:Array<WorkspaceGroup>):WorkspaceGroup {
		var order = 0;
		for (group in groups)
			if (group.parent == null && WorkspaceProtocol.order(group.order) >= order) order = WorkspaceProtocol.order(group.order) + 1;
		var name = Path.withoutDirectory(StringTools.replace(folder, "\\", "/"));
		return {id: freshGroupId(), name: name.length == 0 ? folder : name, cwd: folder, revision: 1, parent: null, order: order};
	}

	static function freshGroupId():String
		return "group-" + AgentManagerNative.randomToken().substr(0, 24);

	static function insertGroup(database:Database, group:WorkspaceGroup):Void
		writeGroup(database, group, false);

	static function writeGroup(database:Database, group:WorkspaceGroup, update:Bool):Void {
		var payload = MessagePack.encode(group);
		exec(database, update ? "UPDATE workspace_groups SET revision=?2,payload=?3 WHERE id=?1" : "INSERT INTO workspace_groups VALUES(?1,?2,?3)",
			function(row) {
				row.bindText(1, group.id);
				row.bindInt64(2, haxe.Int64.ofInt(group.revision));
				row.bindBlob(3, payload);
			});
	}

	static function writeAgent(database:Database, agent:AgentRecord, update:Bool):Void {
		var payload = MessagePack.encode(agent);
		exec(database, update ? "UPDATE workspace_agents SET payload=?2 WHERE id=?1" : "INSERT INTO workspace_agents(id,payload) VALUES(?1,?2)", function(row) {
			row.bindText(1, agent.id);
			row.bindBlob(2, payload);
		});
	}

	static function writeTerminal(database:Database, terminal:TerminalRecord, update:Bool):Void {
		var payload = MessagePack.encode(terminal);
		exec(database, update ? "UPDATE workspace_terminals SET payload=?2 WHERE id=?1" : "INSERT INTO workspace_terminals(id,payload) VALUES(?1,?2)", function(row) {
			row.bindText(1, terminal.id);
			row.bindBlob(2, payload);
		});
	}

	static function exec(database:Database, sql:String, bind:Statement->Void):Void {
		var row = database.prepare(sql);
		try {
			bind(row);
			row.step();
		} catch (error:Dynamic) {
			row.close();
			throw error;
		}
		row.close();
	}

	static function hasTable(database:Database, name:String):Bool {
		var row = database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
		row.bindText(1, name);
		var found = row.step();
		row.close();
		return found;
	}

	static function load(directory:String):Array<MigratedFolder> {
		var path = Path.join([directory, RECORD]);
		if (!FileSystem.exists(path)) return [];
		var value = AgentManager.readPrivateJson(path, 65536);
		var entries:Dynamic = Reflect.field(value, "folders");
		if (AgentManager.intField(value, "version") != 1 || !Std.isOfType(entries, Array)) throw 'Unrecognised $path';
		var result:Array<MigratedFolder> = [];
		for (entry in (entries : Array<Dynamic>)) {
			var root = AgentManager.stringField(entry, "root"), from = AgentManager.stringField(entry, "from");
			var backup = AgentManager.stringField(entry, "backup");
			if (root == "" || from == "" || backup == "") throw 'Unrecognised $path';
			result.push({root: root, from: from, backup: backup, restored: Reflect.field(entry, "restored") == true,
				restoring: Reflect.field(entry, "restoring") == true});
		}
		return result;
	}

	static function save(directory:String, workspace:String, record:Array<MigratedFolder>):Void {
		var path = Path.join([directory, RECORD]);
		var content = Json.stringify({version: 1, workspace: workspace, folders: record}) + "\n";
		if (FileSystem.exists(path)) AtomicFile.write(path, content) else AtomicFile.create(path, content);
	}

	static function remove(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path)) remove(Path.join([path, name]));
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}

	/** Now in UTC as `YYYYMMDD-HHMMSS`, for backup and set-aside folder names. Haxeon's Date has no calendar fields. */
	public static function timestamp():String {
		var seconds = Math.floor(Date.now().getTime() / 1000);
		var days = Math.floor(seconds / 86400), rest = seconds - days * 86400;
		// Civil date from days since 1970-01-01 (Howard Hinnant's days_from_civil, inverted).
		var z = days + 719468;
		var era = Math.floor(z / 146097);
		var dayOfEra = z - era * 146097;
		var yearOfEra = Math.floor((dayOfEra - Math.floor(dayOfEra / 1460) + Math.floor(dayOfEra / 36524) - Math.floor(dayOfEra / 146096)) / 365);
		var dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100));
		var monthIndex = Math.floor((5 * dayOfYear + 2) / 153);
		var day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1;
		var month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
		var year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
		var two = function(value:Int):String {
			return StringTools.lpad(Std.string(value), "0", 2);
		};
		return year + two(month) + two(day) + "-" + two(Math.floor(rest / 3600)) + two(Math.floor(rest % 3600 / 60)) + two(rest % 60);
	}
}

/** A catalog's groups, sessions and terminals, read to move them and to check that all of them arrived. */
private class Catalog {
	public final groups:Array<WorkspaceGroup>;
	public final agents:Array<AgentRecord>;
	public final terminals:Array<TerminalRecord>;
	/** Terminal histories as `id#hash`. */
	public final histories:Array<String>;
	/** Stored agent content as `provider/session/turn/item#hash:partial`, so arrived content is checked to equal the original. */
	public final contents:Array<String>;

	function new(groups:Array<WorkspaceGroup>, agents:Array<AgentRecord>, terminals:Array<TerminalRecord>, histories:Array<String>,
		contents:Array<String>) {
		this.groups = groups;
		this.agents = agents;
		this.terminals = terminals;
		this.histories = histories;
		this.contents = contents;
	}

	public static function read(path:String):Catalog {
		var database = Database.open(path, 1000);
		try {
			var catalog = load(database);
			database.close();
			return catalog;
		} catch (error:Dynamic) {
			database.close();
			throw error;
		}
	}

	public static function load(database:Database):Catalog {
		var groups:Array<WorkspaceGroup> = [];
		each(database, "SELECT payload FROM workspace_groups ORDER BY id", function(row) {
			var group:WorkspaceGroup = MessagePack.decode(row.columnBlob(0));
			groups.push(group);
		});
		var agents:Array<AgentRecord> = [];
		each(database, "SELECT payload FROM workspace_agents ORDER BY id", function(row) {
			var agent:AgentRecord = MessagePack.decode(row.columnBlob(0));
			agents.push(agent);
		});
		var terminals:Array<TerminalRecord> = [];
		each(database, "SELECT payload FROM workspace_terminals ORDER BY id", function(row) {
			var terminal:TerminalRecord = MessagePack.decode(row.columnBlob(0));
			terminals.push(terminal);
		});
		var histories:Array<String> = [];
		each(database, "SELECT id,payload FROM workspace_terminal_history ORDER BY id", function(row) {
			histories.push(row.columnText(0) + "#" + AgentWorkspaceMigration.hashOf(row.columnBlob(1)));
		});
		var contents:Array<String> = [];
		each(database, "SELECT name FROM sqlite_master WHERE type='table' AND name='workspace_agent_content'", function(_) {
			contents.push("");
		});
		if (contents.length > 0) {
			contents = [];
			each(database, "SELECT provider,session,turn,item,payload,partial FROM workspace_agent_content", function(row) {
				contents.push(row.columnText(0) + "/" + row.columnText(1) + "/" + row.columnText(2) + "/" + row.columnText(3) + "#"
					+ AgentWorkspaceMigration.hashOf(row.columnBlob(4)) + ":" + row.columnInt64(5));
			});
		}
		return new Catalog(groups, agents, terminals, histories, contents);
	}

	/** This catalog with its group ids renamed as a merge renamed them. */
	public function renamed(mapping:Map<String, String>):Catalog {
		var moved:Array<WorkspaceGroup> = [];
		for (group in groups) {
			var id = mapping.exists(group.id) ? mapping.get(group.id) : group.id;
			moved.push({id: id, name: group.name, cwd: group.cwd, revision: group.revision, parent: group.parent, order: group.order});
		}
		return new Catalog(moved, agents, terminals, histories, contents);
	}

	/**
		Throws unless every session, terminal, terminal history and stored agent content in `expected` is in this
		catalog, and with `withGroups` every group (by id, after any renaming).
	**/
	public function requireAll(expected:Catalog, withGroups:Bool):Void {
		if (withGroups)
			for (group in expected.groups)
				if (!Lambda.exists(groups, function(found) return found.id == group.id)) throw 'Group ${group.name} did not arrive';
		for (agent in expected.agents)
			if (!Lambda.exists(agents, function(found) return found.id == agent.id)) throw 'Session ${agent.name} did not arrive';
		for (terminal in expected.terminals)
			if (!Lambda.exists(terminals, function(found) return found.id == terminal.id)) throw 'Terminal ${terminal.name} did not arrive';
		for (history in expected.histories)
			if (histories.indexOf(history) < 0) throw 'A terminal\'s history did not arrive';
		for (content in expected.contents)
			if (contents.indexOf(content) < 0) throw 'A session\'s stored content did not arrive';
	}

	static function each(database:Database, sql:String, body:Statement->Void):Void {
		var row = database.prepare(sql);
		try {
			while (row.step()) body(row);
		} catch (error:Dynamic) {
			row.close();
			throw error;
		}
		row.close();
	}
}
