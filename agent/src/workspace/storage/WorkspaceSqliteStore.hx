package workspace.storage;

import haxe.Int64;
import sqlitekit.Database;
import sqlitekit.Statement;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspacePersistence;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceTerminalPersistence;
import workspace.service.WorkspaceTerminalProtocol;

/** Agent-owned schema; small typed rows, not a copied full-catalog checkpoint.
 * The manager owns the exclusive process lock. SQL cursor/revision CAS fences stale writers. */
class WorkspaceSqliteStore implements WorkspacePersistence implements WorkspaceTerminalPersistence implements workspace.service.WorkspaceAgentPersistence {
	final db:Database;
	final workspace:String;
	final historyLimit:Int;

	public function new(path:String, workspace:String, seed:WorkspaceSnapshot, historyLimit:Int = 32, ?root:String) {
		if (seed == null || seed.cursor != 0 || historyLimit < 1 || historyLimit > 32)
			throw "Invalid workspace storage seed or history limit";
		if (root != null && (root.length == 0 || root.length > 1024)) throw "Invalid authorized workspace root";
		var expectedRoot = root == null ? "" : root;
		// Validate domain identities before creating any schema or rows.
		new WorkspaceService(workspace, seed.epoch, seed.groups, historyLimit);
		this.workspace = workspace;
		this.historyLimit = historyLimit;
		db = Database.open(path, 1000);
		try {
			var version = 0;
			statement("PRAGMA user_version", function(row) {
				if (!row.step())
					throw "Missing SQLite schema version";
				version = integer(row.columnInt64(0));
			});
			if (version != 0 && version != 1 && version != 2 && version != 3 && version != 4)
				throw "Unsupported workspace schema version";
			if (version == 0) {
				var count = 0;
				statement("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", function(row) {
					row.step();
					count = integer(row.columnInt64(0));
				});
				if (count != 0)
					throw "Unversioned nonempty workspace database";
			}
			db.exec("PRAGMA journal_mode=WAL");
			db.exec("PRAGMA synchronous=FULL");
			if (version == 0)
				initialize(seed);
            if (version < 2) transaction(function() {
                db.exec("CREATE TABLE workspace_terminals (id TEXT PRIMARY KEY, payload BLOB NOT NULL)");
                db.exec("PRAGMA user_version=2");
            });
			if (version < 3 || expectedRoot.length > 0) transaction(function() {
				if (version < 3) {
					db.exec("ALTER TABLE workspace_meta ADD COLUMN root TEXT");
					db.exec("PRAGMA user_version=3");
				}
				if (expectedRoot.length == 0) return;
				var missing = false;
				statement("SELECT workspace,root IS NULL,length(CAST(root AS BLOB)),root FROM workspace_meta WHERE id=1", function(row) {
					if (!row.step() || row.columnText(0) != workspace) throw "Workspace database identity mismatch";
					missing = integer(row.columnInt64(1)) == 1;
					if (!missing && (integer(row.columnInt64(2)) > 4096 || row.columnText(3) != expectedRoot)) throw "Workspace database root mismatch";
				});
				if (missing) {
					if (version >= 3) throw "Unscoped workspace database";
					// Older managed schemas represented this identity with their single initial group.
					// Check that migration evidence once; subsequent identity is independent of group edits.
					if (version != 0) statement("SELECT payload,length(payload) FROM workspace_groups ORDER BY id LIMIT 2", function(row) {
						if (!row.step()) throw "Missing legacy workspace root";
						var legacy:WorkspaceGroup = MessagePack.decode(blob(row, 0, integer(row.columnInt64(1))));
						if (legacy.cwd != expectedRoot || row.step()) throw "Legacy workspace root mismatch";
					});
					statement("UPDATE workspace_meta SET root=?1 WHERE id=1 AND root IS NULL", function(row) {
						row.bindText(1, expectedRoot); row.step();
					});
				}
			});
   if(version<4) transaction(function() {
    db.exec("CREATE TABLE workspace_agents (id TEXT PRIMARY KEY, payload BLOB NOT NULL)");
    db.exec("PRAGMA user_version=4");
   });

		} catch (error:Dynamic) {
			db.close();
			throw error;
		}
	}

	static function integer(value:Int64):Int {
		if (Int64.compare(value, Int64.ofInt(0)) < 0 || Int64.compare(value, Int64.ofInt(0x7fffffff)) > 0)
			throw "Persisted integer outside protocol range";
		return Int64.toInt(value);
	}

	function statement(sql:String, body:Statement->Void):Void {
		var row = db.prepare(sql);
		try
			body(row)
		catch (error:Dynamic) {
			try
				row.close()
			catch (_:Dynamic) {}
			throw error;
		}
		row.close();
	}

	function transaction(body:Void->Void):Void {
		db.begin();
		try {
			body();
			db.commit();
		} catch (error:Dynamic) {
			try
				db.rollback()
			catch (_:Dynamic) {}
			throw error;
		}
	}

	function initialize(seed:WorkspaceSnapshot):Void {
		transaction(function() {
			db.exec("CREATE TABLE workspace_meta (id INTEGER PRIMARY KEY CHECK(id=1), workspace TEXT NOT NULL, epoch TEXT NOT NULL, cursor INTEGER NOT NULL CHECK(cursor>=0))");
			db.exec("CREATE TABLE workspace_groups (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload BLOB NOT NULL)");
			db.exec("CREATE TABLE workspace_operations (id TEXT PRIMARY KEY, sequence INTEGER UNIQUE NOT NULL, request BLOB NOT NULL, outcome BLOB NOT NULL)");
			db.exec("CREATE TABLE workspace_events (sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL)");
			statement("INSERT INTO workspace_meta VALUES(1,?1,?2,0)", function(row) {
				row.bindText(1, workspace);
				row.bindText(2, seed.epoch);
				row.step();
			});
			for (group in seed.groups)
				statement("INSERT INTO workspace_groups VALUES(?1,?2,?3)", function(row) {
					row.bindText(1, group.id);
					row.bindInt64(2, Int64.ofInt(group.revision));
					row.bindBlob(3, MessagePack.encode(group));
					row.step();
				});
			db.exec("PRAGMA user_version=1");
		});
	}

	function blob(row:Statement, column:Int, size:Int, limit:Int = 8192):haxe.io.Bytes {
		if (size < 1 || size > limit)
			throw "Persisted workspace blob exceeds limit";
		return row.columnBlob(column);
	}

	public function load():WorkspaceStoredState {
		var epoch = "", cursor = 0;
		var groups:Array<WorkspaceGroup> = [],
			operations:Array<WorkspaceStoredOperation> = [],
			events:Array<WorkspaceEvent> = [];
		transaction(function() {
			statement("SELECT workspace,epoch,cursor,length(CAST(workspace AS BLOB)),length(CAST(epoch AS BLOB)) FROM workspace_meta", function(row) {
				if (!row.step() || integer(row.columnInt64(3)) > 512 || integer(row.columnInt64(4)) > 512)
					throw "Invalid workspace metadata";
				if (row.columnText(0) != workspace)
					throw "Workspace database identity mismatch";
				epoch = row.columnText(1);
				cursor = integer(row.columnInt64(2));
				if (row.step())
					throw "Duplicate workspace metadata";
			});
			statement("SELECT id,revision,payload,length(payload),length(CAST(id AS BLOB)) FROM workspace_groups ORDER BY id LIMIT 33", function(row) {
				while (row.step()) {
					if (integer(row.columnInt64(4)) > 512)
						throw "Oversized group identity";
					var group:WorkspaceGroup = MessagePack.decode(blob(row, 2, integer(row.columnInt64(3))));
					if (group.id != row.columnText(0) || group.revision != integer(row.columnInt64(1)))
						throw "Workspace group metadata mismatch";
					groups.push(group);
				}
			});
			statement("SELECT id,sequence,request,outcome,length(request),length(outcome),length(CAST(id AS BLOB)) FROM workspace_operations ORDER BY sequence LIMIT 257",
				function(row) {
					while (row.step()) {
						if (integer(row.columnInt64(6)) > 512)
							throw "Oversized operation identity";
						var request = WorkspaceProtocol.RENAME.decodeRequest(blob(row, 2, integer(row.columnInt64(4))));
						var outcome = WorkspaceProtocol.RENAME.decodeResponse(blob(row, 3, integer(row.columnInt64(5))));
						if (request.operation != row.columnText(0) || outcome.sequence != integer(row.columnInt64(1)))
							throw "Operation metadata mismatch";
						operations.push({request: request, outcome: outcome});
					}
				});
			statement("SELECT sequence,payload,length(payload) FROM workspace_events ORDER BY sequence LIMIT 33", function(row) {
				while (row.step()) {
					var event = WorkspaceProtocol.decodeEvent(blob(row, 1, integer(row.columnInt64(2))));
					if (event.sequence != integer(row.columnInt64(0)))
						throw "Event metadata mismatch";
					events.push(event);
				}
			});
		});
		return {snapshot: {epoch: epoch, cursor: cursor, groups: groups}, operations: operations, events: events};
	}

	public function commit(request:RenameGroup, outcome:RenameResult, event:WorkspaceEvent):Void {
		transaction(function() {
			statement("UPDATE workspace_meta SET cursor=?1 WHERE id=1 AND workspace=?2 AND epoch=?3 AND cursor=?4", function(row) {
				row.bindInt64(1, Int64.ofInt(outcome.sequence));
				row.bindText(2, workspace);
				row.bindText(3, outcome.epoch);
				row.bindInt64(4, Int64.ofInt(outcome.sequence - 1));
				row.step();
			});
			if (db.changes() != Int64.ofInt(1))
				throw "Stale workspace writer";
			if (request.action == "create") statement("INSERT INTO workspace_groups VALUES(?1,?2,?3)", function(row) {
				row.bindText(1, outcome.group.id);
				row.bindInt64(2, Int64.ofInt(outcome.group.revision));
				row.bindBlob(3, MessagePack.encode(outcome.group)); row.step();
			});
			else statement("UPDATE workspace_groups SET revision=?1,payload=?2 WHERE id=?3 AND revision=?4", function(row) {
				row.bindInt64(1, Int64.ofInt(outcome.group.revision));
				row.bindBlob(2, MessagePack.encode(outcome.group));
				row.bindText(3, outcome.group.id);
				row.bindInt64(4, Int64.ofInt(request.expectedRevision));
				row.step();
			});
			if (db.changes() != Int64.ofInt(1))
				throw "Stale group writer";
			statement("INSERT INTO workspace_operations VALUES(?1,?2,?3,?4)", function(row) {
				row.bindText(1, request.operation);
				row.bindInt64(2, Int64.ofInt(outcome.sequence));
				row.bindBlob(3, WorkspaceProtocol.RENAME.encodeRequest(request));
				row.bindBlob(4, WorkspaceProtocol.RENAME.encodeResponse(outcome));
				row.step();
			});
			statement("INSERT INTO workspace_events VALUES(?1,?2)", function(row) {
				row.bindInt64(1, Int64.ofInt(event.sequence));
				row.bindBlob(2, WorkspaceProtocol.encodeEvent(event));
				row.step();
			});
			statement("DELETE FROM workspace_events WHERE sequence<=?1", function(row) {
				row.bindInt64(1, Int64.ofInt(outcome.sequence > historyLimit ? outcome.sequence - historyLimit : 0));
				row.step();
			});
		});
	}

 public function loadTerminals():Array<TerminalRecord> {
  var result:Array<TerminalRecord> =[];
  statement("SELECT id,payload,length(payload),length(CAST(id AS BLOB)) FROM workspace_terminals ORDER BY id LIMIT 257",function(row) {
   while(row.step()) {
    if(integer(row.columnInt64(3))>512) throw "Oversized terminal identity";
    var record:TerminalRecord=haxeon.wire.MessagePack.decode(blob(row,1,integer(row.columnInt64(2)),16384));
    if(record.id!=row.columnText(0)) throw "Terminal identity mismatch";
    result.push(record);
   }
  });
  if(result.length>256) throw "Terminal catalog exceeds limit";
  return result;
 }
 public function saveTerminal(record:TerminalRecord):Void {
  var payload = MessagePack.encode(record);
  if (payload.length > 16384) throw "Terminal metadata exceeds storage budget";
  transaction(function() {
   statement("INSERT INTO workspace_terminals(id,payload) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",function(row) {
    row.bindText(1,record.id);row.bindBlob(2,payload);row.step();
   });
  });
 }
 public function removeTerminal(id:String):Void {
  transaction(function() {
   statement("DELETE FROM workspace_terminals WHERE id=?1",function(row) {row.bindText(1,id);row.step();});
  });
 }

 public function loadAgents():Array<workspace.service.WorkspaceAgentProtocol.AgentRecord> {
  var records:Array<workspace.service.WorkspaceAgentProtocol.AgentRecord> = [];
  statement("SELECT id,payload,length(payload) FROM workspace_agents ORDER BY id LIMIT 33",function(row) {
   while(row.step()) {
    var r:workspace.service.WorkspaceAgentProtocol.AgentRecord=MessagePack.decode(blob(row,1,integer(row.columnInt64(2)),16384));
    if(r.id!=row.columnText(0)) throw "Agent identity mismatch";
    records.push(r);
   }
  });
  if(records.length>32) throw "Agent catalog exceeds limit";
  return records;
 }
 public function saveAgent(record:workspace.service.WorkspaceAgentProtocol.AgentRecord):Void {
  var bytes=MessagePack.encode(record);if(bytes.length>16384) throw "Agent record exceeds bound";
  transaction(function() {
   statement("INSERT INTO workspace_agents(id,payload) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",function(row) {
    row.bindText(1,record.id);row.bindBlob(2,bytes);row.step();
   });
  });
 }

	public function close():Void
		db.close();
}
