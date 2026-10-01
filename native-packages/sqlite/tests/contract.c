#include "sqlitekit.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

static void ok(int result) {
    if (result != SQLITEKIT_OK) {
        fprintf(stderr, "sqlite result %d: %s\n", result, sqlitekit_last_error());
        abort();
    }
}

int main(void) {
    char path[512];
#if defined(_WIN32)
    char base[MAX_PATH];
    assert(GetTempPathA(MAX_PATH, base));
    snprintf(path, sizeof(path), "%ssqlitekit-%lu.db", base,
             (unsigned long)GetCurrentProcessId());
#else
    char folder[] = "/tmp/sqlitekit-XXXXXX";
    assert(mkdtemp(folder));
    snprintf(path, sizeof(path), "%s/test.db", folder);
#endif

    sqlitekit_db *db = NULL;
    ok(sqlitekit_open(path, 100, &db));
    assert(db);
    sqlitekit_db *other = NULL;
    assert(sqlitekit_open(path, 100, &other) == SQLITEKIT_LOCKED_BY_PROCESS);
    assert(!other);
#if !defined(_WIN32)
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        sqlitekit_db *cross_process = NULL;
        _exit(sqlitekit_open(path, 100, &cross_process) == SQLITEKIT_LOCKED_BY_PROCESS ? 0 : 1);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
#endif

    ok(sqlitekit_exec(db, "CREATE TABLE item (id INTEGER PRIMARY KEY, rev INTEGER NOT NULL, payload BLOB)"));
    ok(sqlitekit_begin(db));
    ok(sqlitekit_exec(db, "INSERT INTO item(id, rev) VALUES (1, 0)"));
    ok(sqlitekit_rollback(db));
    sqlitekit_stmt *stmt = NULL;
    ok(sqlitekit_prepare(db, "SELECT count(*) FROM item", &stmt));
    assert(sqlitekit_step(stmt) == SQLITEKIT_ROW);
    assert(sqlitekit_column_int64(stmt, 0) == 0);
    assert(sqlitekit_step(stmt) == SQLITEKIT_DONE);
    ok(sqlitekit_finalize(stmt));

    const uint8_t bytes[] = {0, 0xff, 0x11, 0, 0x7f};
    ok(sqlitekit_prepare(db, "INSERT INTO item(id, rev, payload) VALUES (1, 1, ?1)", &stmt));
    ok(sqlitekit_bind_blob(stmt, 1, bytes, sizeof(bytes)));
    assert(sqlitekit_step(stmt) == SQLITEKIT_DONE);
    ok(sqlitekit_finalize(stmt));
    ok(sqlitekit_prepare(db, "SELECT payload FROM item WHERE id = 1", &stmt));
    assert(sqlitekit_step(stmt) == SQLITEKIT_ROW);
    uint64_t size = 0;
    const void *borrowed = sqlitekit_column_blob(stmt, 0, &size);
    assert(size == sizeof(bytes) && borrowed && memcmp(borrowed, bytes, sizeof(bytes)) == 0);
    ok(sqlitekit_finalize(stmt));

    // Workbench-style compare-and-swap revision update.
    ok(sqlitekit_prepare(db, "UPDATE item SET rev = rev + 1 WHERE id = 1 AND rev = ?1", &stmt));
    ok(sqlitekit_bind_int64(stmt, 1, 1));
    assert(sqlitekit_step(stmt) == SQLITEKIT_DONE);
    assert(sqlitekit_changes(db) == 1);
    ok(sqlitekit_reset(stmt));
    ok(sqlitekit_clear_bindings(stmt));
    ok(sqlitekit_bind_int64(stmt, 1, 1));
    assert(sqlitekit_step(stmt) == SQLITEKIT_DONE);
    assert(sqlitekit_changes(db) == 0);
    ok(sqlitekit_finalize(stmt));

    ok(sqlitekit_prepare(db, "SELECT 1", &stmt));
    assert(sqlitekit_close(db) == 5); // SQLITE_BUSY keeps lock and db live.
    ok(sqlitekit_finalize(stmt));
    ok(sqlitekit_close(db));
    ok(sqlitekit_open(path, 100, &other));
    ok(sqlitekit_close(other));

    remove(path);
    char sidecar[sizeof(path) + 32];
    snprintf(sidecar, sizeof(sidecar), "%s.sqlitekit-lock", path);
    remove(sidecar);
#if !defined(_WIN32)
    rmdir(folder);
#endif
    return 0;
}
