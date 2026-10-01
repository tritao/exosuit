package sqlitekit;

import sqlitekit.ffi.SqliteKit;
import sqlitekit.ffi.SqliteKitTypes;

/** Prepared statement; column views remain valid only until step/reset/close. */
class Statement {
    final handle:StatementHandle;
    var closed:Bool = false;

    @:allow(sqlitekit.Database)
    private function new(handle:StatementHandle) {
        this.handle = handle;
    }

    public function bindInt64(index:Int, value:haxe.Int64):Void
        Database.check(SqliteKit.sqlitekit_bind_int64(live(), index, value), "bind int64");

    public function bindText(index:Int, value:String):Void
        Database.check(SqliteKit.sqlitekit_bind_text(live(), index, value), "bind text");

    public function bindNull(index:Int):Void
        Database.check(SqliteKit.sqlitekit_bind_null(live(), index), "bind null");

    public function bindDouble(index:Int, value:Float):Void
        Database.check(SqliteKit.sqlitekit_bind_double(live(), index, value), "bind double");

    public function bindBlob(index:Int, bytes:haxe.io.Bytes):Void
        Database.check(SqliteKit.sqlitekit_bind_blob(live(), index, bytes, bytes.length), "bind blob");

    /** True for a row, false after the final row. */
    public function step():Bool {
        var status = SqliteKit.sqlitekit_step(live());
        if (status == 100)
            return true;
        if (status == 101)
            return false;
        Database.check(status, "step");
        return false;
    }

    public function columnInt64(index:Int):haxe.Int64
        return SqliteKit.sqlitekit_column_int64(live(), index);

    public function columnDouble(index:Int):Float
        return SqliteKit.sqlitekit_column_double(live(), index);

    public function columnType(index:Int):Int
        return SqliteKit.sqlitekit_column_type(live(), index);

    /** Returns a safe copy of the SQLite-owned column bytes. */
    public function columnBlob(index:Int):haxe.io.Bytes {
        var copied = SqliteKit.sqlitekit_column_blob_copy(live(), index);
        Database.check(copied.status, "column blob");
        return copied.buffer;
    }

    public function columnText(index:Int):String
        return columnBlob(index).toString();

    public function reset():Void {
        Database.check(SqliteKit.sqlitekit_reset(live()), "reset");
        Database.check(SqliteKit.sqlitekit_clear_bindings(live()), "clear bindings");
    }

    public function close():Void {
        if (closed)
            return;
        var status = SqliteKit.sqlitekit_finalize(handle);
        closed = true;
        Database.check(status, "finalize");
    }

    private function live():StatementHandle {
        if (closed)
            throw "SQLite statement is closed";
        return handle;
    }
}
