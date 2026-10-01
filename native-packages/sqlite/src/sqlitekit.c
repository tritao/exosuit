#include "sqlitekit.h"
#include "sqlite3.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

struct sqlitekit_db {
    sqlite3 *handle;
    int statement_count;
#if defined(_WIN32)
    HANDLE lock;
    OVERLAPPED overlap;
#else
    int lock_fd;
#endif
};

struct sqlitekit_stmt {
    sqlite3_stmt *handle;
    sqlitekit_db *db;
};

#if defined(_MSC_VER)
static __declspec(thread) char last_error[256];
#else
static _Thread_local char last_error[256];
#endif

static int error_with(int code, const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message ? message : "SQLite error");
    return code;
}

static int record(sqlitekit_db *db, int code) {
    if (code != SQLITE_OK && code != SQLITE_ROW && code != SQLITE_DONE)
        error_with(code, db && db->handle ? sqlite3_errmsg(db->handle) : sqlite3_errstr(code));
    return code;
}

static char *lock_path(const char *path) {
    const size_t length = strlen(path);
    static const char suffix[] = ".sqlitekit-lock";
    if (length > SIZE_MAX - sizeof(suffix))
        return NULL;
    char *result = malloc(length + sizeof(suffix));
    if (!result)
        return NULL;
    memcpy(result, path, length);
    memcpy(result + length, suffix, sizeof(suffix));
    return result;
}

#if defined(_WIN32)
static wchar_t *wide_path(const char *path) {
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!length)
        return NULL;
    wchar_t *wide = malloc((size_t)length * sizeof(wchar_t));
    if (!wide)
        return NULL;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length)) {
        free(wide);
        return NULL;
    }
    return wide;
}
static int acquire_lock(sqlitekit_db *db, const char *path) {
    wchar_t *wide = wide_path(path);
    if (!wide)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "invalid UTF-8 lock path");
    db->lock = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide);
    if (db->lock == INVALID_HANDLE_VALUE)
        return error_with(SQLITE_CANTOPEN, "could not open database lock file");
    memset(&db->overlap, 0, sizeof(db->overlap));
    if (!LockFileEx(db->lock, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                    0, 1, 0, &db->overlap)) {
        CloseHandle(db->lock);
        db->lock = INVALID_HANDLE_VALUE;
        return error_with(SQLITEKIT_LOCKED_BY_PROCESS, "database is open in another process");
    }
    return SQLITEKIT_OK;
}
static void release_lock(sqlitekit_db *db) {
    UnlockFileEx(db->lock, 0, 1, 0, &db->overlap);
    CloseHandle(db->lock);
}
#else
static int acquire_lock(sqlitekit_db *db, const char *path) {
    db->lock_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (db->lock_fd < 0)
        return error_with(SQLITE_CANTOPEN, "could not open database lock file");
    struct stat info;
    if (fstat(db->lock_fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(db->lock_fd);
        db->lock_fd = -1;
        return error_with(SQLITE_CANTOPEN, "database lock is not a regular file");
    }
    if (flock(db->lock_fd, LOCK_EX | LOCK_NB) != 0) {
        close(db->lock_fd);
        db->lock_fd = -1;
        return error_with(SQLITEKIT_LOCKED_BY_PROCESS, "database is open in another process");
    }
    return SQLITEKIT_OK;
}
static void release_lock(sqlitekit_db *db) {
    flock(db->lock_fd, LOCK_UN);
    close(db->lock_fd);
}
#endif

SQLITEKIT_API const char *sqlitekit_last_error(void) { return last_error; }

SQLITEKIT_API int sqlitekit_open(const char *path, int busy_ms, sqlitekit_db **out_db) {
    if (out_db)
        *out_db = NULL;
    if (!path || !*path || !out_db || busy_ms < 0)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "invalid database open arguments");
    char *sidecar = lock_path(path);
    if (!sidecar)
        return error_with(SQLITE_NOMEM, "out of memory for database lock path");
    sqlitekit_db *db = calloc(1, sizeof(*db));
    if (!db) {
        free(sidecar);
        return error_with(SQLITE_NOMEM, "out of memory for database handle");
    }
    int rc = acquire_lock(db, sidecar);
    free(sidecar);
    if (rc != SQLITEKIT_OK) {
        free(db);
        return rc;
    }
    rc = sqlite3_open_v2(path, &db->handle,
                         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                         NULL);
    if (rc == SQLITE_OK)
        rc = sqlite3_busy_timeout(db->handle, busy_ms);
    if (rc != SQLITE_OK) {
        record(db, rc);
        if (db->handle)
            sqlite3_close(db->handle);
        release_lock(db);
        free(db);
        return rc;
    }
    *out_db = db;
    return SQLITEKIT_OK;
}

SQLITEKIT_API int sqlitekit_close(sqlitekit_db *db) {
    if (!db)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "database handle is null");
    if (db->statement_count)
        return error_with(SQLITE_BUSY, "finalize statements before closing database");
    const int rc = sqlite3_close(db->handle);
    if (rc != SQLITE_OK)
        return record(db, rc);
    release_lock(db);
    free(db);
    return SQLITEKIT_OK;
}

SQLITEKIT_API int sqlitekit_exec(sqlitekit_db *db, const char *sql) {
    if (!db || !sql)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "database and SQL are required");
    return record(db, sqlite3_exec(db->handle, sql, NULL, NULL, NULL));
}
SQLITEKIT_API int sqlitekit_begin(sqlitekit_db *db) {
    return sqlitekit_exec(db, "BEGIN IMMEDIATE");
}
SQLITEKIT_API int sqlitekit_commit(sqlitekit_db *db) {
    return sqlitekit_exec(db, "COMMIT");
}
SQLITEKIT_API int sqlitekit_rollback(sqlitekit_db *db) {
    return sqlitekit_exec(db, "ROLLBACK");
}

SQLITEKIT_API int sqlitekit_prepare(sqlitekit_db *db, const char *sql,
                                    sqlitekit_stmt **out_stmt) {
    if (out_stmt)
        *out_stmt = NULL;
    if (!db || !sql || !out_stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "invalid prepare arguments");
    sqlitekit_stmt *stmt = calloc(1, sizeof(*stmt));
    if (!stmt)
        return error_with(SQLITE_NOMEM, "out of memory for statement");
    int rc = sqlite3_prepare_v2(db->handle, sql, -1, &stmt->handle, NULL);
    if (rc != SQLITE_OK || !stmt->handle) {
        if (stmt->handle)
            sqlite3_finalize(stmt->handle);
        free(stmt);
        return rc == SQLITE_OK ? error_with(SQLITEKIT_INVALID_ARGUMENT, "empty SQL statement")
                               : record(db, rc);
    }
    stmt->db = db;
    db->statement_count++;
    *out_stmt = stmt;
    return SQLITEKIT_OK;
}
SQLITEKIT_API int sqlitekit_finalize(sqlitekit_stmt *stmt) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    sqlitekit_db *db = stmt->db;
    const int rc = sqlite3_finalize(stmt->handle);
    db->statement_count--;
    free(stmt);
    return record(db, rc);
}
SQLITEKIT_API int sqlitekit_reset(sqlitekit_stmt *stmt) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_reset(stmt->handle));
}
SQLITEKIT_API int sqlitekit_clear_bindings(sqlitekit_stmt *stmt) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_clear_bindings(stmt->handle));
}
SQLITEKIT_API int sqlitekit_bind_null(sqlitekit_stmt *stmt, int index) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_bind_null(stmt->handle, index));
}
SQLITEKIT_API int sqlitekit_bind_int64(sqlitekit_stmt *stmt, int index, int64_t value) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_bind_int64(stmt->handle, index, value));
}
SQLITEKIT_API int sqlitekit_bind_double(sqlitekit_stmt *stmt, int index, double value) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_bind_double(stmt->handle, index, value));
}
SQLITEKIT_API int sqlitekit_bind_text(sqlitekit_stmt *stmt, int index, const char *value) {
    if (!stmt || !value)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement and text are required");
    const size_t size = strlen(value);
    if (size > INT_MAX)
        return error_with(SQLITE_TOOBIG, "SQLite text exceeds maximum size");
    return record(stmt->db, sqlite3_bind_text(stmt->handle, index, value, (int)size,
                                               SQLITE_TRANSIENT));
}
SQLITEKIT_API int sqlitekit_bind_blob(sqlitekit_stmt *stmt, int index,
                                      const uint8_t *bytes, uint64_t size) {
    if (!stmt || (!bytes && size))
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "invalid blob binding");
    if (size > INT_MAX)
        return error_with(SQLITE_TOOBIG, "SQLite blob exceeds maximum size");
    if (!size)
        return record(stmt->db, sqlite3_bind_zeroblob(stmt->handle, index, 0));
    return record(stmt->db, sqlite3_bind_blob(stmt->handle, index, bytes, (int)size,
                                               SQLITE_TRANSIENT));
}
SQLITEKIT_API int sqlitekit_step(sqlitekit_stmt *stmt) {
    if (!stmt)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "statement handle is null");
    return record(stmt->db, sqlite3_step(stmt->handle));
}
SQLITEKIT_API int sqlitekit_column_count(sqlitekit_stmt *stmt) {
    return stmt ? sqlite3_column_count(stmt->handle) : 0;
}
SQLITEKIT_API int sqlitekit_column_type(sqlitekit_stmt *stmt, int column) {
    return stmt ? sqlite3_column_type(stmt->handle, column) : SQLITE_NULL;
}
SQLITEKIT_API int64_t sqlitekit_column_int64(sqlitekit_stmt *stmt, int column) {
    return stmt ? sqlite3_column_int64(stmt->handle, column) : 0;
}
SQLITEKIT_API double sqlitekit_column_double(sqlitekit_stmt *stmt, int column) {
    return stmt ? sqlite3_column_double(stmt->handle, column) : 0;
}
SQLITEKIT_API const void *sqlitekit_column_blob(sqlitekit_stmt *stmt, int column,
                                                uint64_t *out_size) {
    if (out_size)
        *out_size = stmt ? (uint64_t)sqlite3_column_bytes(stmt->handle, column) : 0;
    return stmt ? sqlite3_column_blob(stmt->handle, column) : NULL;
}
SQLITEKIT_API int sqlitekit_column_blob_copy(sqlitekit_stmt *stmt, int column,
                                              void *buffer, uint32_t *inout_size) {
    if (!stmt || !inout_size)
        return error_with(SQLITEKIT_INVALID_ARGUMENT, "invalid blob copy arguments");
    const int size = sqlite3_column_bytes(stmt->handle, column);
    if (size == 0) {
        *inout_size = 0;
        return SQLITEKIT_OK;
    }
    if (!buffer || *inout_size < (uint64_t)size) {
        *inout_size = (uint64_t)size;
        return SQLITE_TOOBIG;
    }
    const void *bytes = sqlite3_column_blob(stmt->handle, column);
    if (size && bytes)
        memcpy(buffer, bytes, (size_t)size);
    *inout_size = (uint64_t)size;
    return SQLITEKIT_OK;
}
SQLITEKIT_API const char *sqlitekit_column_text(sqlitekit_stmt *stmt, int column,
                                                uint64_t *out_size) {
    const char *text = stmt ? (const char *)sqlite3_column_text(stmt->handle, column) : NULL;
    if (out_size)
        *out_size = stmt ? (uint64_t)sqlite3_column_bytes(stmt->handle, column) : 0;
    return text;
}
SQLITEKIT_API int64_t sqlitekit_changes(sqlitekit_db *db) {
    return db ? sqlite3_changes64(db->handle) : 0;
}
SQLITEKIT_API int64_t sqlitekit_last_insert_rowid(sqlitekit_db *db) {
    return db ? sqlite3_last_insert_rowid(db->handle) : 0;
}
