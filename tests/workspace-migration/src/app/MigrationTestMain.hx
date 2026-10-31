package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.wire.MessagePack;
import sqlitekit.Database;
import sys.FileSystem;
import sys.io.File;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceService;
import workspace.storage.WorkspaceSqliteStore;

/**
	Migrating folders' old state into their workspace's (AgentWorkspaceMigration, M19 Phase 4): one folder, two folders
	merged under folder groups, a second run changing nothing, refusals that leave the old state, and restoring.
**/
class MigrationTestMain {
	static var failures = 0;
	static var base:String;
	/** When set, the session oldState creates has this id. */
	static var fixedAgent:Null<String> = null;

	static function main():Void {
		base = Path.join([Sys.getEnv("TEMP") != null ? Sys.getEnv("TEMP") : "/tmp", "exosuit-migration-" + AgentManagerNative.randomToken().substr(0, 8)]);
		Sys.putEnv("EXOSUIT_AGENT_STATE_HOME", Path.join([base, "state"]));
		try {
			oneFolder();
			twoFolders();
			refusals();
			restore();
			retry();
			crashBeforeRename();
			unownedCatalog();
			crashBetweenRecordAndMark();
			restoreWithoutRecord();
			tamperedBackup();
			restoreFailsPartway();
			collisions();
			movedElsewhere();
			stillRunning();
			persistentFailure();
			restoreThenStart();
			settingsAfterFailedFirst();
			markedNotCleaned();
			cappedNotices();
			processDeath();
			importedNotRecorded();
			restoreCrashWindow();
			carriedDirectory();
			backupReusedAfterSnapshot();
			ids();
		} catch (error:Dynamic) {
			fail("uncaught: " + Std.string(error));
		}
		Sys.println(failures == 0 ? "PASS workspace migration" : 'FAIL workspace migration: $failures');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function oneFolder():Void {
		var root = folder("one");
		var old = oldState(root, ["notes"], 2, 1);
		var state = workspaceState("workspace-one");
		var identity = AgentStateIdentity.forWorkspace("workspace-one", [root], null);
		AgentWorkspaceMigration.run(identity, state);
		var catalog = counts(Path.join([state, "catalog.sqlite"]));
		check(catalog.groups == 2 && catalog.agents == 2 && catalog.terminals == 1 && catalog.histories == 1, "one folder: everything arrived " + catalog);
		check(topLevel(Path.join([state, "catalog.sqlite"])).length == 2, "one folder: groups stay where they were");
		check(owner(Path.join([state, "catalog.sqlite"])) == "workspace:workspace-one", "one folder: the catalog is the workspace's");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-one", "one folder: the old state is marked");
		check(!FileSystem.exists(Path.join([old, "catalog.sqlite"])), "one folder: the old catalog moved");
		check(backups(old).length == 1, "one folder: one backup");
		var backup = Path.join([Path.directory(old), backups(old)[0]]);
		check(FileSystem.exists(Path.join([backup, "backup-manifest.json"])) && FileSystem.exists(Path.join([backup, "catalog.sqlite"])),
			"one folder: the backup is complete, with its manifest");
		var record = File.getContent(Path.join([state, AgentWorkspaceMigration.RECORD]));
		var epoch = meta(Path.join([state, "catalog.sqlite"]));
		AgentWorkspaceMigration.run(identity, state);
		check(File.getContent(Path.join([state, AgentWorkspaceMigration.RECORD])) == record && meta(Path.join([state, "catalog.sqlite"])) == epoch
			&& backups(old).length == 1, "one folder: a second run changes nothing");
	}

	static function twoFolders():Void {
		var first = folder("first"), second = folder("second");
		oldState(first, ["a"], 1, 1);
		oldState(second, ["b", "c"], 1, 2);
		var state = workspaceState("workspace-two");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-two", [first, second], null), state);
		var path = Path.join([state, "catalog.sqlite"]);
		var catalog = counts(path);
		// Each catalog: Work plus its own groups; one group per folder on top.
		check(catalog.groups == 2 + 3 + 2 && catalog.agents == 2 && catalog.terminals == 3 && catalog.histories == 3, "two folders: everything arrived " + catalog);
		var top = topLevel(path);
		check(top.length == 2 && top.indexOf("first") >= 0 && top.indexOf("second") >= 0, "two folders: one top-level group per folder " + top);
		check(nestedWork(path) == 2, "two folders: each folder's Work group kept, under its folder");
		check(ungrouped(path) == 0, "two folders: nothing is left at the root");
	}

	static function refusals():Void {
		// A file the migration does not know, and a rotated log: backed up, never deleted, and no reason to refuse.
		var root = folder("unknown");
		var old = oldState(root, [], 1, 0);
		File.saveContent(Path.join([old, "surprise.bin"]), "?");
		File.saveContent(Path.join([old, "manager.log.1"]), "rotated");
		var state = workspaceState("workspace-unknown");
		var warnings = AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-unknown", [root], null), state);
		check(warnings.length == 0, "unknown file: no warning " + warnings);
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-unknown", "unknown file: the folder is migrated");
		check(File.getContent(Path.join([old, "surprise.bin"])) == "?" && File.getContent(Path.join([old, "manager.log.1"])) == "rotated",
			"unknown file: left in place");
		var backup = Path.join([Path.directory(old), backups(old)[0]]);
		check(FileSystem.exists(Path.join([backup, "surprise.bin"])) && FileSystem.exists(Path.join([backup, "manager.log.1"])), "unknown file: backed up");
		// A corrupt catalog: the workspace still starts; the folder is reported and left in place.
		var corrupt = folder("corrupt");
		var damaged = oldState(corrupt, [], 1, 0);
		File.saveContent(Path.join([damaged, "catalog.sqlite"]), "not a database");
		for (name in ["catalog.sqlite-wal", "catalog.sqlite-shm"]) if (FileSystem.exists(Path.join([damaged, name]))) FileSystem.deleteFile(Path.join([damaged, name]));
		var target = workspaceState("workspace-corrupt");
		var problems = AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-corrupt", [corrupt], null), target);
		check(problems.length == 1 && problems[0].indexOf(corrupt) >= 0, "corrupt catalog: reported " + problems);
		check(AgentStateIdentity.read(Path.join([damaged, "workspace.json"])).migratedTo == null, "corrupt catalog: the old state is left in place");
		check(!FileSystem.exists(Path.join([target, "catalog.sqlite"])), "corrupt catalog: the workspace gets no half catalog");
	}

	static function restore():Void {
		var root = folder("restored");
		var old = oldState(root, ["kept"], 1, 1);
		var before = File.getContent(Path.join([old, "workspace.json"]));
		var state = workspaceState("workspace-restored");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-restored", [root], null), state);
		var restored = AgentWorkspaceMigration.restore(state, "workspace-restored");
		check(restored.length == 1, "restore: one folder");
		check(File.getContent(Path.join([old, "workspace.json"])) == before, "restore: the folder's identity is back");
		var catalog = counts(Path.join([old, "catalog.sqlite"]));
		check(catalog.groups == 2 && catalog.agents == 1 && catalog.terminals == 1, "restore: the folder's catalog is back " + catalog);
	}

	/** A run that failed after committing its import (marker and record not written) is retried without importing twice. */
	static function retry():Void {
		var root = folder("retried");
		var old = oldState(root, ["again"], 1, 1);
		var state = workspaceState("workspace-retried");
		var identity = AgentStateIdentity.forWorkspace("workspace-retried", [root], null);
		AgentWorkspaceMigration.run(identity, state);
		var counted = counts(Path.join([state, "catalog.sqlite"]));
		// Put the old state back as if marking and recording had failed.
		var backup = Path.join([Path.directory(old), backups(old)[0]]);
		FileSystem.deleteFile(Path.join([state, AgentWorkspaceMigration.RECORD]));
		File.saveContent(Path.join([old, "workspace.json"]), haxe.Json.stringify({version: 1, root: root}) + "\n");
		File.saveBytes(Path.join([old, "catalog.sqlite"]), File.getBytes(Path.join([backup, "catalog.sqlite"])));
		AgentWorkspaceMigration.run(identity, state);
		var again = counts(Path.join([state, "catalog.sqlite"]));
		check(again.groups == counted.groups && again.agents == counted.agents && again.terminals == counted.terminals,
			"retry: nothing imported twice " + again + " vs " + counted);
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-retried", "retry: the old state is marked");
	}

	/** A failure after the snapshot is built and before it is renamed into place leaves no catalog, and a rerun is the first import. */
	static function crashBeforeRename():Void {
		var root = folder("crash-rename");
		var old = oldState(root, ["notes"], 2, 1);
		var state = workspaceState("workspace-crash-rename");
		var identity = AgentStateIdentity.forWorkspace("workspace-crash-rename", [root], null);
		var path = Path.join([state, "catalog.sqlite"]);
		failAt("before-rename");
		var warnings = AgentWorkspaceMigration.run(identity, state);
		AgentWorkspaceMigration.hook = null;
		check(warnings.length == 1 && warnings[0].indexOf("simulated") >= 0, "crash before rename: reported " + warnings);
		check(!FileSystem.exists(path), "crash before rename: no catalog at the target");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([old, "catalog.sqlite"])),
			"crash before rename: the old state is untouched");
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "crash before rename: the rerun succeeds");
		var catalog = counts(path);
		check(catalog.groups == 2 && catalog.agents == 2 && catalog.terminals == 1 && topLevel(path).length == 2,
			"crash before rename: the rerun is a plain first import, not a merge " + catalog + " " + topLevel(path));
		check(owner(path) == "workspace:workspace-crash-rename", "crash before rename: owned by the workspace");
	}

	/** A catalog left at the target by an older build, still the folder's own, is set aside and the folder imported as the first. */
	static function unownedCatalog():Void {
		var root = folder("unowned");
		var old = oldState(root, [], 1, 1);
		var state = workspaceState("workspace-unowned");
		var path = Path.join([state, "catalog.sqlite"]);
		Database.snapshot(Path.join([old, "catalog.sqlite"]), path);
		var warnings = AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-unowned", [root], null), state);
		check(warnings.length == 0, "unowned catalog: no warning " + warnings);
		var catalog = counts(path);
		check(catalog.groups == 1 && catalog.agents == 1 && catalog.terminals == 1 && owner(path) == "workspace:workspace-unowned",
			"unowned catalog: imported as the first, not merged into itself " + catalog);
		var aside = [for (name in FileSystem.readDirectory(state)) if (name.indexOf("catalog.sqlite.unfinished-") == 0) name];
		check(aside.length == 1, "unowned catalog: set aside, not deleted " + aside);
	}

	/** A stop after the record is written and before the old state is marked: the way back is recorded, and the next start marks. */
	static function crashBetweenRecordAndMark():Void {
		var root = folder("crash-mark");
		var old = oldState(root, [], 1, 1);
		var state = workspaceState("workspace-crash-mark");
		var identity = AgentStateIdentity.forWorkspace("workspace-crash-mark", [root], null);
		failAt("recorded");
		var warnings = AgentWorkspaceMigration.run(identity, state);
		AgentWorkspaceMigration.hook = null;
		check(warnings.length == 1, "crash before marking: reported " + warnings);
		var record = File.getContent(Path.join([state, AgentWorkspaceMigration.RECORD]));
		check(record.indexOf(".bak-") >= 0, "crash before marking: the record names the backup " + record);
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null, "crash before marking: not marked yet");
		var before = counts(Path.join([state, "catalog.sqlite"]));
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "crash before marking: the next start is clean");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-crash-mark", "crash before marking: the next start marks it");
		var after = counts(Path.join([state, "catalog.sqlite"]));
		check(after.groups == before.groups && after.agents == before.agents && File.getContent(Path.join([state, AgentWorkspaceMigration.RECORD])) == record,
			"crash before marking: nothing imported or recorded twice");
		check(!FileSystem.exists(Path.join([old, "catalog.sqlite"])), "crash before marking: the moved catalog is gone from the old state");
	}

	/** Restore finds a folder that is marked as moved here but has no record entry, through its backups. */
	static function restoreWithoutRecord():Void {
		var root = folder("unrecorded");
		var old = oldState(root, ["kept"], 1, 1);
		var state = workspaceState("workspace-unrecorded");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-unrecorded", [root], null), state);
		FileSystem.deleteFile(Path.join([state, AgentWorkspaceMigration.RECORD]));
		var restored = AgentWorkspaceMigration.restore(state, "workspace-unrecorded");
		check(restored.length == 1, "restore without a record: found the folder " + restored.length);
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([old, "catalog.sqlite"])),
			"restore without a record: the folder's state is back");
	}

	/** A backup that does not match its manifest stops the restore before anything changes. */
	static function tamperedBackup():Void {
		var root = folder("tampered");
		var old = oldState(root, [], 1, 0);
		var state = workspaceState("workspace-tampered");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-tampered", [root], null), state);
		var backup = Path.join([Path.directory(old), backups(old)[0]]);
		File.saveContent(Path.join([backup, "manager.log"]), "changed");
		expectRefusal(function() AgentWorkspaceMigration.restore(state, "workspace-tampered"), "differs");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-tampered", "tampered backup: nothing was restored");
	}

	/** A restore that fails after the first folder leaves each folder restored or as it was, and running it again finishes. */
	static function restoreFailsPartway():Void {
		var first = folder("partway-first"), second = folder("partway-second");
		var firstOld = oldState(first, [], 1, 0), secondOld = oldState(second, [], 2, 0);
		var state = workspaceState("workspace-partway");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-partway", [first, second], null), state);
		var seen = 0;
		AgentWorkspaceMigration.hook = function(name:String, detail:String):Void {
			if (name == "restore-swap" && ++seen == 2) throw "simulated restore failure";
		};
		expectRefusal(function() AgentWorkspaceMigration.restore(state, "workspace-partway"), "simulated");
		AgentWorkspaceMigration.hook = null;
		var restored = [firstOld, secondOld].filter(function(path) return AgentStateIdentity.read(Path.join([path, "workspace.json"])).migratedTo == null);
		check(restored.length == 1 && FileSystem.exists(Path.join([restored[0], "catalog.sqlite"])), "partway restore: exactly one folder restored, whole " + restored);
		check(!FileSystem.exists(firstOld + ".restoring") && !FileSystem.exists(secondOld + ".restoring"), "partway restore: no half-built folder is left");
		var again = AgentWorkspaceMigration.restore(state, "workspace-partway");
		check(again.length == 2, "partway restore: the rerun covers both");
		for (path in [firstOld, secondOld])
			check(AgentStateIdentity.read(Path.join([path, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([path, "catalog.sqlite"])),
				"partway restore: restored after the rerun " + path);
		check(counts(Path.join([secondOld, "catalog.sqlite"])).agents == 2, "partway restore: the folder's catalog is the backup's");
	}

	/** A session id in both folders' catalogs fails that folder (reported); nothing of it is merged or overwritten. */
	static function collisions():Void {
		var a = folder("collide-a"), b = folder("collide-b");
		fixedAgent = "agent-shared";
		var aOld = oldState(a, [], 1, 0), bOld = oldState(b, [], 1, 0);
		fixedAgent = null;
		var state = workspaceState("workspace-collide");
		var path = Path.join([state, "catalog.sqlite"]);
		var warnings = AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-collide", [a, b], null), state);
		check(warnings.length == 1 && warnings[0].indexOf("in two folders") >= 0 && warnings[0].indexOf(b) >= 0, "collision: the second folder is reported " + warnings);
		check(AgentStateIdentity.read(Path.join([bOld, "workspace.json"])).migratedTo == null, "collision: the second folder is left in place");
		var catalog = counts(path);
		check(catalog.agents == 1 && catalog.groups == 2, "collision: nothing of it was merged " + catalog.agents + " " + catalog.groups);
	}

	/** A folder whose sessions another workspace took in is reported, not silently skipped. */
	static function movedElsewhere():Void {
		var root = folder("claimed");
		oldState(root, [], 1, 0);
		var first = workspaceState("workspace-claim-one"), second = workspaceState("workspace-claim-two");
		AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-claim-one", [root], null), first);
		var warnings = AgentWorkspaceMigration.run(AgentStateIdentity.forWorkspace("workspace-claim-two", [root], null), second);
		check(warnings.length == 1 && warnings[0].indexOf("sessions are in workspace workspace-claim-one") >= 0 && warnings[0].indexOf(root) >= 0,
			"claimed folder: reported " + warnings);
		check(!FileSystem.exists(Path.join([second, "catalog.sqlite"])), "claimed folder: nothing was taken from it");
	}

	/** An old service that will not stop leaves its folder in place with a warning; the other folders migrate and the next start retries. */
	static function stillRunning():Void {
		var busy = folder("busy"), free = folder("free");
		var busyOld = oldState(busy, [], 1, 0), freeOld = oldState(free, [], 1, 0);
		var lock = AgentManagerNative.acquireLock(Path.join([busyOld, "agent.lock"]));
		AgentWorkspaceMigration.stopWaitSeconds = 1.0;
		var state = workspaceState("workspace-busy");
		var identity = AgentStateIdentity.forWorkspace("workspace-busy", [busy, free], null);
		var warnings = AgentWorkspaceMigration.run(identity, state);
		if (lock != null) AgentManagerNative.releaseLock(lock);
		AgentWorkspaceMigration.stopWaitSeconds = 20.0;
		check(lock != null, "still running: the test could take the lock");
		check(warnings.length == 1 && warnings[0].indexOf("still running") >= 0 && warnings[0].indexOf(busy) >= 0, "still running: reported " + warnings);
		check(AgentStateIdentity.read(Path.join([busyOld, "workspace.json"])).migratedTo == null, "still running: its folder is left in place");
		check(AgentStateIdentity.read(Path.join([freeOld, "workspace.json"])).migratedTo == "workspace-busy", "still running: the other folder migrated");
		check(!FileSystem.exists(Path.join([busyOld, "stop-request.json"])), "still running: no stop request is left behind");
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "still running: the next start takes the folder in");
		check(AgentStateIdentity.read(Path.join([busyOld, "workspace.json"])).migratedTo == "workspace-busy", "still running: retried");
		check(counts(Path.join([state, "catalog.sqlite"])).agents == 2, "still running: both folders' sessions are in the workspace");
	}

	/** A folder that fails every start keeps one backup, reused, not a new copy per launch. */
	static function persistentFailure():Void {
		var root = folder("persistent");
		var old = oldState(root, [], 1, 0);
		File.saveContent(Path.join([old, "catalog.sqlite"]), "not a database");
		for (name in ["catalog.sqlite-wal", "catalog.sqlite-shm"]) if (FileSystem.exists(Path.join([old, name]))) FileSystem.deleteFile(Path.join([old, name]));
		var state = workspaceState("workspace-persistent");
		var identity = AgentStateIdentity.forWorkspace("workspace-persistent", [root], null);
		check(AgentWorkspaceMigration.run(identity, state).length == 1, "persistent failure: reported the first time");
		var first = backups(old);
		check(AgentWorkspaceMigration.run(identity, state).length == 1, "persistent failure: reported the second time");
		check(first.length == 1 && backups(old).length == 1 && backups(old)[0] == first[0], "persistent failure: one backup, reused " + first + " " + backups(old));
		// A state that changed since is backed up again, and the stale copy goes.
		File.saveContent(Path.join([old, "extra.txt"]), "new");
		AgentWorkspaceMigration.run(identity, state);
		check(backups(old).length == 1 && FileSystem.exists(Path.join([Path.directory(old), backups(old)[0], "extra.txt"])), "persistent failure: a changed state replaces its backup " + backups(old));
	}

	/** A restore that stopped partway, then a normal start, then the restore again, in either order of events. */
	static function restoreThenStart():Void {
		var first = folder("rs-first"), second = folder("rs-second");
		var firstOld = oldState(first, [], 1, 0), secondOld = oldState(second, [], 1, 0);
		var state = workspaceState("workspace-rs");
		var identity = AgentStateIdentity.forWorkspace("workspace-rs", [first, second], null);
		AgentWorkspaceMigration.run(identity, state);
		var seen = 0;
		AgentWorkspaceMigration.hook = function(name:String, detail:String):Void {
			if (name == "restore-swap" && ++seen == 2) throw "simulated restore failure";
		};
		expectRefusal(function() AgentWorkspaceMigration.restore(state, "workspace-rs"), "simulated");
		AgentWorkspaceMigration.hook = null;
		// The workspace is opened before the restore is finished: the restored folder is not marked again.
		var warnings = AgentWorkspaceMigration.run(identity, state);
		check(warnings.length == 1 && warnings[0].indexOf("restored") >= 0, "restore then start: the restored folder is reported " + warnings);
		check(AgentStateIdentity.read(Path.join([firstOld, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([firstOld, "catalog.sqlite"])),
			"restore then start: the restored folder is left alone");
		check(AgentStateIdentity.read(Path.join([secondOld, "workspace.json"])).migratedTo == "workspace-rs", "restore then start: the other is still migrated");
		// Its own service ran since (its state changed); the rest still restores.
		File.saveContent(Path.join([firstOld, "later.txt"]), "service ran");
		var again = AgentWorkspaceMigration.restore(state, "workspace-rs");
		check(again.length == 2, "restore then start: the rerun covers both entries");
		check(AgentStateIdentity.read(Path.join([secondOld, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([secondOld, "catalog.sqlite"])),
			"restore then start: the pending folder is restored");
		check(File.getContent(Path.join([firstOld, "later.txt"])) == "service ran", "restore then start: the restored folder's later changes stay");
	}

	/** A failed first folder leaves none of its settings in the workspace; the next first folder's are the ones carried. */
	static function settingsAfterFailedFirst():Void {
		var a = folder("settings-a"), b = folder("settings-b");
		var aOld = oldState(a, [], 1, 0), bOld = oldState(b, [], 1, 0);
		File.saveContent(Path.join([aOld, "relay-settings.json"]), "settings of a");
		File.saveContent(Path.join([bOld, "relay-settings.json"]), "settings of b");
		var state = workspaceState("workspace-settings");
		var identity = AgentStateIdentity.forWorkspace("workspace-settings", [a, b], null);
		AgentWorkspaceMigration.hook = function(name:String, detail:String):Void {
			if (name == "before-rename" && detail == a) throw "simulated failure";
		};
		var warnings = AgentWorkspaceMigration.run(identity, state);
		AgentWorkspaceMigration.hook = null;
		check(warnings.length == 1 && warnings[0].indexOf(a) >= 0, "settings: the failed folder is reported " + warnings);
		check(File.getContent(Path.join([state, "relay-settings.json"])) == "settings of b", "settings: the workspace has the folder that arrived's settings");
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "settings: the rerun takes the failed folder in");
		check(File.getContent(Path.join([state, "relay-settings.json"])) == "settings of b", "settings: the first folder's settings are not replaced");
	}

	/** Marked and recorded, but still holding moved files: the next start removes them. */
	static function markedNotCleaned():Void {
		var root = folder("leftovers");
		var old = oldState(root, [], 1, 0);
		var state = workspaceState("workspace-leftovers");
		var identity = AgentStateIdentity.forWorkspace("workspace-leftovers", [root], null);
		AgentWorkspaceMigration.run(identity, state);
		var backup = Path.join([Path.directory(old), backups(old)[0]]);
		File.saveBytes(Path.join([old, "catalog.sqlite"]), File.getBytes(Path.join([backup, "catalog.sqlite"])));
		File.saveContent(Path.join([old, "stop-request.json"]), "{}");
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "leftovers: no warning");
		check(!FileSystem.exists(Path.join([old, "catalog.sqlite"])) && !FileSystem.exists(Path.join([old, "stop-request.json"])), "leftovers: removed on the next start");
	}

	static function cappedNotices():Void {
		var state = workspaceState("workspace-notices");
		var long = StringTools.rpad("", "x", 200000);
		AgentWorkspaceMigration.writeNotices(state, [long, "second"]);
		var read = AgentWorkspaceMigration.readNotices(state);
		check(read.length == 2 && read[0].length < 2000 && read[1] == "second", "notices: one long error does not drop the rest " + read.length);
	}

	/** What a process killed mid-way leaves on disk (not an exception passing through cleanup): leftovers are cleared by the next start. */
	static function processDeath():Void {
		var root = folder("death");
		var old = oldState(root, ["g"], 1, 1);
		var state = workspaceState("workspace-death");
		File.saveContent(Path.join([state, "catalog.sqlite.migrating"]), "half written snapshot");
		File.saveContent(Path.join([state, "catalog.sqlite.migrating-wal"]), "half written log");
		var identity = AgentStateIdentity.forWorkspace("workspace-death", [root], null);
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "process death: the start is clean after a dead snapshot");
		var path = Path.join([state, "catalog.sqlite"]);
		check(counts(path).agents == 1 && owner(path) == "workspace:workspace-death" && topLevel(path).length == 2, "process death: a plain first import");
		check(!FileSystem.exists(path + ".migrating") && !FileSystem.exists(path + ".migrating-wal"), "process death: the leftovers are gone");
		// A restore that died while building its copy.
		var staging = old + ".restoring";
		check(AgentManagerNative.prepareDirectory(staging), "process death: made a half-built restore folder");
		File.saveContent(Path.join([staging, "catalog.sqlite"]), "half copied");
		var restored = AgentWorkspaceMigration.restore(state, "workspace-death");
		check(restored.length == 1 && !FileSystem.exists(staging), "process death: restore clears a half-built copy");
		check(counts(Path.join([old, "catalog.sqlite"])).agents == 1, "process death: the folder is the backup's");
	}

	/** Renamed into place but not yet recorded: the rerun does not import again, and ends recorded and marked with one backup. */
	static function importedNotRecorded():Void {
		var root = folder("imported");
		var old = oldState(root, ["g"], 2, 1);
		var state = workspaceState("workspace-imported");
		var identity = AgentStateIdentity.forWorkspace("workspace-imported", [root], null);
		var path = Path.join([state, "catalog.sqlite"]);
		failAt("imported");
		var warnings = AgentWorkspaceMigration.run(identity, state);
		AgentWorkspaceMigration.hook = null;
		check(warnings.length == 1 && warnings[0].indexOf("simulated") >= 0, "imported: reported " + warnings);
		check(FileSystem.exists(path) && !FileSystem.exists(Path.join([state, AgentWorkspaceMigration.RECORD])), "imported: catalog in place, nothing recorded");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null, "imported: not marked");
		var before = counts(path);
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "imported: the rerun is clean");
		var after = counts(path);
		check(after.groups == before.groups && after.agents == before.agents && after.terminals == before.terminals, "imported: nothing imported twice");
		check(File.getContent(Path.join([state, AgentWorkspaceMigration.RECORD])).indexOf(".bak-") >= 0, "imported: recorded");
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == "workspace-imported", "imported: marked");
		check(backups(old).length == 1, "imported: one backup " + backups(old));
	}

	/** A stop between the restore's swap and its record leaves a restored folder that a normal start must not mark again. */
	static function restoreCrashWindow():Void {
		var root = folder("crash-window");
		var old = oldState(root, ["kept"], 1, 1);
		var state = workspaceState("workspace-crash-window");
		var identity = AgentStateIdentity.forWorkspace("workspace-crash-window", [root], null);
		AgentWorkspaceMigration.run(identity, state);
		failAt("restore-swapped");
		expectRefusal(function() AgentWorkspaceMigration.restore(state, "workspace-crash-window"), "simulated");
		AgentWorkspaceMigration.hook = null;
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([old, "catalog.sqlite"])),
			"restore crash window: the folder is swapped back");
		var warnings = AgentWorkspaceMigration.run(identity, state);
		check(warnings.length == 1 && warnings[0].indexOf("restored") >= 0, "restore crash window: the start reports it " + warnings);
		check(AgentStateIdentity.read(Path.join([old, "workspace.json"])).migratedTo == null && FileSystem.exists(Path.join([old, "catalog.sqlite"])),
			"restore crash window: the start does not mark it or remove its catalog");
		check(counts(Path.join([old, "catalog.sqlite"])).agents == 1, "restore crash window: its catalog is whole");
		check(AgentWorkspaceMigration.restore(state, "workspace-crash-window").length == 1, "restore crash window: the restore finishes");
	}

	/** The carried agentkit directory is renamed into place whole; a stop mid-copy leaves none, and the next start copies it. */
	static function carriedDirectory():Void {
		var root = folder("carried");
		var old = oldState(root, [], 1, 0);
		createDirectories(Path.join([old, "agentkit"]));
		File.saveContent(Path.join([old, "agentkit", "settings.json"]), "kit");
		var state = workspaceState("workspace-carried");
		var identity = AgentStateIdentity.forWorkspace("workspace-carried", [root], null);
		// Left by a process that died mid-copy.
		createDirectories(Path.join([state, "agentkit.copying"]));
		File.saveContent(Path.join([state, "agentkit.copying", "partial.json"]), "half");
		failAt("carry-copied");
		var warnings = AgentWorkspaceMigration.run(identity, state);
		AgentWorkspaceMigration.hook = null;
		check(warnings.length == 1, "carried: the stop is reported " + warnings);
		check(!FileSystem.exists(Path.join([state, "agentkit"])), "carried: no half directory in place");
		check(FileSystem.exists(Path.join([old, "agentkit", "settings.json"])), "carried: the original is still in the old state");
		check(AgentWorkspaceMigration.run(identity, state).length == 0, "carried: the next start is clean");
		check(File.getContent(Path.join([state, "agentkit", "settings.json"])) == "kit" && !FileSystem.exists(Path.join([state, "agentkit.copying"])),
			"carried: copied whole, temporary copy gone");
		check(!FileSystem.exists(Path.join([state, "agentkit", "partial.json"])), "carried: the dead copy's file did not come along");
	}

	/** Snapshotting a valid catalog must not change the state enough to defeat backup reuse: two failed starts, one backup. */
	static function backupReusedAfterSnapshot():Void {
		var root = folder("snapshot-reuse");
		var old = oldState(root, ["g"], 2, 1);
		var state = workspaceState("workspace-snapshot-reuse");
		var identity = AgentStateIdentity.forWorkspace("workspace-snapshot-reuse", [root], null);
		failAt("before-rename");
		check(AgentWorkspaceMigration.run(identity, state).length == 1, "snapshot reuse: the first start fails at the rename");
		var first = backups(old);
		check(AgentWorkspaceMigration.run(identity, state).length == 1, "snapshot reuse: the second fails too");
		AgentWorkspaceMigration.hook = null;
		check(first.length == 1 && backups(old).length == 1 && backups(old)[0] == first[0], "snapshot reuse: one backup, the same " + first + " " + backups(old));
	}

	static function ids():Void {
		for (good in ["workspace-0123456789abcdef0123456789abcdef", "a", "w_1"])
			check(AgentStateIdentity.validWorkspaceId(good), "id accepted: " + good);
		for (bad in ["", "nul", "con", "com1", "lpt9", "aux", "prn", "com9", "NUL", "Con", "LPT9", "con.txt", "workspace-ABC", "Workspace-a", "a/b", "..", "a b"])
			check(!AgentStateIdentity.validWorkspaceId(bad), "id refused: " + bad);
	}

	static function failAt(wanted:String):Void {
		AgentWorkspaceMigration.hook = function(name:String, detail:String):Void {
			if (name == wanted) throw "simulated failure at " + name;
		};
	}

	/** A folder's state as a service before M19 Phase 4 left it: `groups` besides Work, sessions, and terminals with history. */
	static function oldState(root:String, groups:Array<String>, agents:Int, terminals:Int):String {
		var state = app.AgentManager.folderStateDirectory(root);
		createDirectories(Path.directory(state));
		if (!AgentManagerNative.prepareDirectory(state)) throw "cannot create " + state;
		File.saveContent(Path.join([state, "workspace.json"]), haxe.Json.stringify({version: 1, root: root}) + "\n");
		File.saveContent(Path.join([state, "manager.log"]), "");
		var seed = new WorkspaceService("workspace", AgentManagerNative.randomToken().substr(0, 32), [{id: "work", name: "Work", cwd: root, revision: 1}]).snapshot();
		var store = new WorkspaceSqliteStore(Path.join([state, "catalog.sqlite"]), "workspace", seed, 32, root);
		for (index in 0...agents)
			store.saveAgent({id: fixedAgent != null ? fixedAgent : "agent-" + AgentManagerNative.randomToken().substr(0, 12), name: "Session " + index, group: index == 0 ? "" : "work",
				cwd: root, thread: "thread", state: "idle", turn: null, workspaceRoot: root});
		for (index in 0...terminals) {
			var id = "terminal-" + AgentManagerNative.randomToken().substr(0, 12);
			store.saveTerminal({id: id, name: "Terminal " + index, group: index == 0 ? "" : "work", cwd: root, instance: "instance", state: "exited",
				exitCode: 0, available: true, revision: Int64.ofInt(1)});
			store.saveTerminalHistory(id, {version: 1, columns: 80, rows: 24, data: Bytes.ofString("history " + index)});
		}
		store.close();
		var database = Database.open(Path.join([state, "catalog.sqlite"]), 1000);
		for (name in groups) {
			var group:WorkspaceGroup = {id: "group-" + name + "-" + AgentManagerNative.randomToken().substr(0, 8), name: name, cwd: root, revision: 1};
			var row = database.prepare("INSERT INTO workspace_groups VALUES(?1,?2,?3)");
			row.bindText(1, group.id);
			row.bindInt64(2, Int64.ofInt(1));
			row.bindBlob(3, MessagePack.encode(group));
			row.step();
			row.close();
		}
		database.close();
		return state;
	}

	static function folder(name:String):String {
		var path = Path.join([base, "folders", name]);
		createDirectories(path);
		return FileSystem.fullPath(path);
	}

	static function workspaceState(id:String):String {
		var state = app.AgentManager.workspaceStateDirectory(id);
		createDirectories(Path.directory(state));
		if (!AgentManagerNative.prepareDirectory(state)) throw "cannot create " + state;
		return state;
	}

	static function createDirectories(path:String):Void {
		if (FileSystem.exists(path)) return;
		createDirectories(Path.directory(path));
		FileSystem.createDirectory(path);
	}

	static function counts(path:String):{groups:Int, agents:Int, terminals:Int, histories:Int} {
		var database = Database.open(path, 1000);
		var count = function(table:String):Int {
			var row = database.prepare("SELECT count(*) FROM " + table);
			row.step();
			var value = Int64.toInt(row.columnInt64(0));
			row.close();
			return value;
		};
		var result = {groups: count("workspace_groups"), agents: count("workspace_agents"), terminals: count("workspace_terminals"),
			histories: count("workspace_terminal_history")};
		database.close();
		return result;
	}

	static function groups(path:String):Array<WorkspaceGroup> {
		var database = Database.open(path, 1000);
		var result:Array<WorkspaceGroup> = [];
		var row = database.prepare("SELECT payload FROM workspace_groups");
		while (row.step()) {
			var group:WorkspaceGroup = MessagePack.decode(row.columnBlob(0));
			result.push(group);
		}
		row.close();
		database.close();
		return result;
	}

	static function topLevel(path:String):Array<String>
		return [for (group in groups(path)) if (group.parent == null) group.name];

	static function nestedWork(path:String):Int
		return [for (group in groups(path)) if (group.name == "Work" && group.parent != null) group].length;

	static function ungrouped(path:String):Int {
		var database = Database.open(path, 1000);
		var count = 0;
		var agents = database.prepare("SELECT payload FROM workspace_agents");
		while (agents.step()) {
			var agent:workspace.service.WorkspaceAgentProtocol.AgentRecord = MessagePack.decode(agents.columnBlob(0));
			if (agent.group == "") count++;
		}
		agents.close();
		var terminals = database.prepare("SELECT payload FROM workspace_terminals");
		while (terminals.step()) {
			var terminal:workspace.service.WorkspaceTerminalProtocol.TerminalRecord = MessagePack.decode(terminals.columnBlob(0));
			if (terminal.group == "") count++;
		}
		terminals.close();
		database.close();
		return count;
	}

	static function owner(path:String):String
		return metaField(path, "root");

	static function meta(path:String):String
		return metaField(path, "epoch");

	static function metaField(path:String, field:String):String {
		var database = Database.open(path, 1000);
		var row = database.prepare("SELECT " + field + " FROM workspace_meta");
		row.step();
		var value = row.columnText(0);
		row.close();
		database.close();
		return value;
	}

	static function backups(state:String):Array<String> {
		var name = Path.withoutDirectory(state);
		return [for (entry in FileSystem.readDirectory(Path.directory(state))) if (StringTools.startsWith(entry, name + ".bak-")) entry];
	}

	static function expectRefusal(action:Void->Void, mention:String):Void {
		try {
			action();
			fail("expected a refusal");
		} catch (error:Dynamic) {
			check(Std.string(error).indexOf(mention) >= 0, "refusal names the problem: " + Std.string(error));
		}
	}

	static function check(condition:Bool, label:String):Void {
		if (condition) return;
		fail(label);
	}

	static function fail(label:String):Void {
		failures++;
		Sys.println("FAIL " + label);
	}
}
