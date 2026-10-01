package app;

import sqlitekit.Database;

class Main {
    static function main():Void {
        var path = Sys.args()[0];
        var db = Database.open(path, 100);
        db.exec("CREATE TABLE IF NOT EXISTS item (value INTEGER, payload BLOB)");
        db.exec("DELETE FROM item");
        db.begin();
        db.exec("INSERT INTO item(value) VALUES (7)");
        db.rollback();
        var stmt = db.prepare("SELECT count(*) FROM item");
        if (!stmt.step() || stmt.columnInt64(0) != 0)
            throw "rollback failed";
        stmt.close();
        var insert = db.prepare("INSERT INTO item(value, payload) VALUES (7, ?1)");
        var blob = haxe.io.Bytes.alloc(4);
        blob.set(0, 0);
        blob.set(1, 255);
        blob.set(2, 17);
        blob.set(3, 0);
        insert.bindBlob(1, blob);
        if (insert.step())
            throw "unexpected insert row";
        insert.close();
        var select = db.prepare("SELECT payload FROM item WHERE value = 7");
        if (!select.step())
            throw "missing blob row";
        var got = select.columnBlob(0);
        if (got.length != 4 || got.get(0) != 0 || got.get(1) != 255 || got.get(2) != 17 || got.get(3) != 0)
            throw "blob round trip failed";
        select.close();
        var emptyInsert = db.prepare("INSERT INTO item(value, payload) VALUES (8, ?1)");
        emptyInsert.bindBlob(1, haxe.io.Bytes.alloc(0));
        if (emptyInsert.step())
            throw "unexpected empty blob insert row";
        emptyInsert.close();
        var emptySelect = db.prepare("SELECT payload FROM item WHERE value = 8");
        if (!emptySelect.step() || emptySelect.columnBlob(0).length != 0)
            throw "empty blob round trip failed";
        emptySelect.close();
        db.close();
    }
}
