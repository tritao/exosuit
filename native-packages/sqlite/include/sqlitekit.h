#ifndef SQLITEKIT_H
#define SQLITEKIT_H

#include <stdint.h>

#if defined(_WIN32)
#  if defined(SQLITEKIT_BUILDING)
#    define SQLITEKIT_API __declspec(dllexport)
#  else
#    define SQLITEKIT_API __declspec(dllimport)
#  endif
#else
#  define SQLITEKIT_API __attribute__((visibility("default")))
#endif

#if defined(__clang__)
#  define SQLITEKIT_UTF8 __attribute__((annotate("hxi:utf8")))
#  define SQLITEKIT_OUT __attribute__((annotate("hxi:out")))
#  define SQLITEKIT_IN_ARRAY(count) __attribute__((annotate("hxi:in_array")))
#  define SQLITEKIT_OUT_BUFFER(size) __attribute__((annotate("hxi:out_buffer")))
#  define SQLITEKIT_INOUT __attribute__((annotate("hxi:inout")))
#  define SQLITEKIT_BORROWED __attribute__((annotate("hxi:borrowed")))
#  define SQLITEKIT_OPAQUE __attribute__((annotate("hxi:opaque")))
#  define SQLITEKIT_NULLABLE _Nullable
#  define SQLITEKIT_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#else
#  define SQLITEKIT_UTF8
#  define SQLITEKIT_OUT
#  define SQLITEKIT_IN_ARRAY(count)
#  define SQLITEKIT_OUT_BUFFER(size)
#  define SQLITEKIT_INOUT
#  define SQLITEKIT_BORROWED
#  define SQLITEKIT_OPAQUE
#  define SQLITEKIT_NULLABLE
#  define SQLITEKIT_RETURNS_BORROWED_UTF8
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sqlitekit_db sqlitekit_db SQLITEKIT_OPAQUE;
typedef struct sqlitekit_stmt sqlitekit_stmt SQLITEKIT_OPAQUE;

enum {
    SQLITEKIT_OK = 0,
    SQLITEKIT_ROW = 100,
    SQLITEKIT_DONE = 101,
    SQLITEKIT_LOCKED_BY_PROCESS = 1001,
    SQLITEKIT_INVALID_ARGUMENT = 1002
};

/** One writer per database path. The sibling .sqlitekit-lock file remains on disk. */
SQLITEKIT_API int sqlitekit_open(const char *path SQLITEKIT_UTF8, int busy_ms,
                                 sqlitekit_db * SQLITEKIT_NULLABLE *out_db SQLITEKIT_OUT SQLITEKIT_BORROWED);
/** Returns SQLITE_BUSY if statements are still live. */
SQLITEKIT_API int sqlitekit_close(sqlitekit_db *db);
/** Thread-local message from the last failed call on this thread. */
SQLITEKIT_API const char *sqlitekit_last_error(void) SQLITEKIT_RETURNS_BORROWED_UTF8;
SQLITEKIT_API int sqlitekit_exec(sqlitekit_db *db, const char *sql SQLITEKIT_UTF8);
SQLITEKIT_API int sqlitekit_begin(sqlitekit_db *db);
SQLITEKIT_API int sqlitekit_commit(sqlitekit_db *db);
SQLITEKIT_API int sqlitekit_rollback(sqlitekit_db *db);
SQLITEKIT_API int sqlitekit_prepare(sqlitekit_db *db, const char *sql SQLITEKIT_UTF8,
                                    sqlitekit_stmt * SQLITEKIT_NULLABLE *out_stmt SQLITEKIT_OUT SQLITEKIT_BORROWED);
SQLITEKIT_API int sqlitekit_finalize(sqlitekit_stmt *stmt);
SQLITEKIT_API int sqlitekit_reset(sqlitekit_stmt *stmt);
SQLITEKIT_API int sqlitekit_clear_bindings(sqlitekit_stmt *stmt);
SQLITEKIT_API int sqlitekit_bind_null(sqlitekit_stmt *stmt, int index);
SQLITEKIT_API int sqlitekit_bind_int64(sqlitekit_stmt *stmt, int index, int64_t value);
SQLITEKIT_API int sqlitekit_bind_double(sqlitekit_stmt *stmt, int index, double value);
SQLITEKIT_API int sqlitekit_bind_text(sqlitekit_stmt *stmt, int index,
                                      const char *value SQLITEKIT_UTF8);
/** Copies caller bytes on bind, so the buffer may be reused after return. */
SQLITEKIT_API int sqlitekit_bind_blob(sqlitekit_stmt *stmt, int index,
                                      const uint8_t *bytes, uint64_t size);
/** Returns SQLITEKIT_ROW or SQLITEKIT_DONE on success. */
SQLITEKIT_API int sqlitekit_step(sqlitekit_stmt *stmt);
SQLITEKIT_API int sqlitekit_column_count(sqlitekit_stmt *stmt);
SQLITEKIT_API int sqlitekit_column_type(sqlitekit_stmt *stmt, int column);
SQLITEKIT_API int64_t sqlitekit_column_int64(sqlitekit_stmt *stmt, int column);
SQLITEKIT_API double sqlitekit_column_double(sqlitekit_stmt *stmt, int column);
/** Borrowed bytes are valid until the next step, reset, or finalize. */
SQLITEKIT_API const void *sqlitekit_column_blob(sqlitekit_stmt *stmt, int column,
                                                uint64_t *out_size SQLITEKIT_OUT)
    SQLITEKIT_BORROWED;
/** Copies a blob into caller storage; a null/short buffer reports required size. */
SQLITEKIT_API int sqlitekit_column_blob_copy(sqlitekit_stmt *stmt, int column,
    void *buffer SQLITEKIT_OUT_BUFFER(inout_size), uint32_t *inout_size SQLITEKIT_INOUT);
SQLITEKIT_API const char *sqlitekit_column_text(sqlitekit_stmt *stmt, int column,
                                                uint64_t *out_size SQLITEKIT_OUT)
    SQLITEKIT_BORROWED;
SQLITEKIT_API int64_t sqlitekit_changes(sqlitekit_db *db);
SQLITEKIT_API int64_t sqlitekit_last_insert_rowid(sqlitekit_db *db);

#ifdef __cplusplus
}
#endif
#endif
