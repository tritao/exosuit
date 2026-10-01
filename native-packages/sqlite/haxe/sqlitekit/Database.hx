package sqlitekit;

import sqlitekit.ffi.SqliteKit;
import sqlitekit.ffi.SqliteKitTypes;

/** A single-writer SQLite connection. Close prepared statements before closing it. */
class Database {
    final handle:DatabaseHandle;
    var closed:Bool = false;

    private function new(handle:DatabaseHandle) {
        this.handle = handle;
    }

    public static function open(path:String, busyMs:Int = 5000):Database {
        var opened = SqliteKit.sqlitekit_open(path, busyMs);
        if (opened.status != 0 || opened.out_db == null)
            throw 'SQLite open failed (${opened.status}): ${SqliteKit.sqlitekit_last_error()}';
        return new Database(opened.out_db);
    }

    public function exec(sql:String):Void {
        check(SqliteKit.sqlitekit_exec(live(), sql), "exec");
    }

    public function begin():Void check(SqliteKit.sqlitekit_begin(live()), "begin");
    public function commit():Void check(SqliteKit.sqlitekit_commit(live()), "commit");
    public function rollback():Void check(SqliteKit.sqlitekit_rollback(live()), "rollback");

    public function changes():haxe.Int64 return SqliteKit.sqlitekit_changes(live());
    public function lastInsertRowid():haxe.Int64 return SqliteKit.sqlitekit_last_insert_rowid(live());

    public function prepare(sql:String):Statement {
        var prepared = SqliteKit.sqlitekit_prepare(live(), sql);
        if (prepared.status != 0 || prepared.out_stmt == null)
            throw 'SQLite prepare failed (${prepared.status}): ${SqliteKit.sqlitekit_last_error()}';
        return new Statement(prepared.out_stmt);
    }

    public function close():Void {
        if (closed)
            return;
        check(SqliteKit.sqlitekit_close(handle), "close");
        closed = true;
    }

    private function live():DatabaseHandle {
        if (closed)
            throw "SQLite database is closed";
        return handle;
    }

    public static function check(status:Int, operation:String):Void {
        if (status != 0)
            throw 'SQLite ${operation} failed (${status}): ${SqliteKit.sqlitekit_last_error()}';
    }
}
