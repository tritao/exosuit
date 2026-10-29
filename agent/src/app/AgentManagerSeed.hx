package app;

import haxe.io.Path;
import sqlitekit.Database;
import sys.FileSystem;

/**
	`--seed-from`: a new manager state that starts from a copy of another manager's catalog, its groups, terminals and
	sessions, while that manager keeps running. The two diverge from then on.
**/
@:access(app.AgentManager)
class AgentManagerSeed {
	/** Copies `source`'s catalog into `directory`, whose manager lock the caller holds. A source with no catalog yet copies nothing. */
	public static function copyCatalog(source:String, directory:String, root:String):Void {
		if (source == directory) throw "A workspace state cannot start from itself";
		if (!FileSystem.exists(source) || !AgentManagerNative.privateDirectory(source))
			throw "The state to copy must be private and owned by this user";
		var identity = AgentManager.readPrivateJson(Path.join([source, "workspace.json"]), 16384);
		if (AgentManager.intField(identity, "version") != 1 || AgentManager.stringField(identity, "root") != root)
			throw "The state to copy belongs to another workspace";
		var catalog = Path.join([source, "catalog.sqlite"]);
		if (!FileSystem.exists(catalog)) return;
		var database = Path.join([directory, "catalog.sqlite"]), staging = database + ".seed";
		removeStaging(staging);
		Database.snapshot(catalog, staging);
		try {
			var copy = Database.open(staging, 1000);
			try {
				// A new epoch, so no client takes this catalog for a continuation of the source's.
				copy.exec("UPDATE workspace_meta SET epoch='" + AgentManagerNative.randomToken().substr(0, 32) + "'");
				copy.exec("DELETE FROM workspace_events");
				// Paired devices trust the source's relay identity, which this state does not share.
				if (hasTable(copy, "workspace_devices")) copy.exec("DELETE FROM workspace_devices");
			} catch (error:Dynamic) {
				copy.close();
				throw error;
			}
			copy.close();
			FileSystem.rename(staging, database);
		} catch (error:Dynamic) {
			removeStaging(staging);
			throw "Could not copy the workspace catalog: " + Std.string(error);
		}
		removeStaging(staging);
	}

	static function hasTable(database:Database, name:String):Bool {
		var statement = database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
		try {
			statement.bindText(1, name);
			var found = statement.step();
			statement.close();
			return found;
		} catch (error:Dynamic) {
			statement.close();
			throw error;
		}
	}

	static function removeStaging(staging:String):Void {
		for (path in [staging, staging + "-journal", staging + "-wal", staging + "-shm", staging + ".sqlitekit-lock"])
			if (FileSystem.exists(path)) FileSystem.deleteFile(path);
	}
}
