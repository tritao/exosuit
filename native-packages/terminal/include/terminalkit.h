#ifndef TERMINALKIT_H
#define TERMINALKIT_H
#include <stdint.h>

#if defined(_WIN32)
# if defined(TERMINALKIT_BUILDING)
#  define TERMINALKIT_API __declspec(dllexport)
# else
#  define TERMINALKIT_API __declspec(dllimport)
# endif
#else
# define TERMINALKIT_API __attribute__((visibility("default")))
#endif
#if defined(__clang__)
# define TK_OPAQUE __attribute__((annotate("hxi:opaque")))
# define TK_OUT __attribute__((annotate("hxi:out")))
# define TK_BORROWED __attribute__((annotate("hxi:borrowed")))
# define TK_UTF8 __attribute__((annotate("hxi:utf8")))
# define TK_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
# define TK_OUT_BUFFER(size) __attribute__((annotate("hxi:out_buffer")))
# define TK_INOUT __attribute__((annotate("hxi:inout")))
# define TK_NULLABLE _Nullable
#else
# define TK_OPAQUE
# define TK_OUT
# define TK_BORROWED
# define TK_UTF8
# define TK_RETURNS_BORROWED_UTF8
# define TK_OUT_BUFFER(size)
# define TK_INOUT
# define TK_NULLABLE
#endif

typedef struct terminalkit_handle terminalkit_handle TK_OPAQUE;
typedef struct terminalkit_cell terminalkit_cell TK_OPAQUE;
/* Reply bytes are borrowed for the callback duration and can go to a PTY.
 * Replies queued before installing a callback remain available to drain. */
typedef void (*terminalkit_output_callback)(const char *bytes, int length, void *user_data);

/* The returned handle is owned by the caller. */
TERMINALKIT_API int terminalkit_open(int columns, int rows, int scrollback_limit,
    const char *term TK_UTF8,
    terminalkit_handle * TK_NULLABLE *out_kit TK_OUT TK_BORROWED);
TERMINALKIT_API void terminalkit_close(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_feed(terminalkit_handle *kit, const uint8_t *bytes, uint64_t size);
/* Feed a checked slice of a caller-owned buffer without making a byte copy. */
TERMINALKIT_API int terminalkit_feed_range(terminalkit_handle *kit,
    const uint8_t *bytes, uint64_t buffer_size, uint64_t offset, uint64_t size);
TERMINALKIT_API void terminalkit_resize(terminalkit_handle *kit, int columns, int rows);
TERMINALKIT_API int terminalkit_columns(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_rows(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_cursor(terminalkit_handle *kit, int *column TK_OUT,
    int *row TK_OUT, int *mode TK_OUT);
TERMINALKIT_API int terminalkit_mouse_mode(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_focus_reporting(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_synchronized_output(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_alternate_screen(terminalkit_handle *kit);
TERMINALKIT_API const char *terminalkit_title(terminalkit_handle *kit) TK_RETURNS_BORROWED_UTF8;
TERMINALKIT_API void terminalkit_focus(terminalkit_handle *kit, int focused);
TERMINALKIT_API void terminalkit_set_output_callback(terminalkit_handle *kit,
    terminalkit_output_callback callback, void *user_data);
/** Emits length-delimited paste through the output callback or reply queue.
 * Returns 0 on success, -1 for invalid input, allocation failure or queue limit.
 * Callback bytes are borrowed only for the duration of each invocation. */
TERMINALKIT_API int terminalkit_paste(terminalkit_handle *kit, const uint8_t *bytes, uint64_t size);
TERMINALKIT_API int terminalkit_keyboard(terminalkit_handle *kit,
    const char *key_name TK_UTF8, uint32_t modifiers, uint32_t unicode);
TERMINALKIT_API int terminalkit_mouse(terminalkit_handle *kit, uint32_t x, uint32_t y,
    uint32_t button, uint32_t event, uint8_t modifiers);
/* Viewport selection: 0 reset, 1 start, 2 target, 3 word. Returns 0 or -1.
 * Selection follows native screen/scrollback lines and affects snapshot styles. */
TERMINALKIT_API int terminalkit_selection(terminalkit_handle *kit, uint32_t column,
    uint32_t row, int operation);
/* UTF-8 without a terminator. 0 success, 1 need storage, -2 no selection, -1 failure. */
TERMINALKIT_API int terminalkit_selection_copy(terminalkit_handle *kit,
    uint8_t *buffer TK_OUT_BUFFER(inout_size), uint32_t *inout_size TK_INOUT);
TERMINALKIT_API void terminalkit_scrollback(terminalkit_handle *kit, int position,
    int *current TK_OUT, int *total TK_OUT);

/* Checkpoints use caller storage and can restore into a fresh handle. */
/* Drops the replay log and disables checkpoint export/restore; live VT state remains. */
TERMINALKIT_API void terminalkit_disable_checkpoints(terminalkit_handle *kit);
TERMINALKIT_API uint64_t terminalkit_checkpoint_size(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_checkpoint(terminalkit_handle *kit, void *buffer,
    uint64_t capacity, uint64_t *written TK_OUT);
TERMINALKIT_API int terminalkit_restore(terminalkit_handle *kit, const void *data, uint64_t size);
/* Replaces the active viewport from a bounded, versioned screen snapshot and
 * disables replay-log checkpoints on this emulator. */
TERMINALKIT_API int terminalkit_restore_screen_snapshot(terminalkit_handle *kit,
    const void *data, uint64_t size);
TERMINALKIT_API void terminalkit_modes(terminalkit_handle *kit,
    int *cursor_keys TK_OUT, int *keypad TK_OUT, int *mouse_tracking TK_OUT,
    int *mouse_encoding TK_OUT, int *paste TK_OUT, int *focus TK_OUT);

/* Refresh cached active-screen cells. A zero return means no row changed. */
TERMINALKIT_API int terminalkit_snapshot(terminalkit_handle *kit);
TERMINALKIT_API int terminalkit_row_changed(terminalkit_handle *kit, int row);
TERMINALKIT_API uint64_t terminalkit_row_id(terminalkit_handle *kit, int row);
/* Borrowed until the next feed, resize, restore, snapshot or close. */
TERMINALKIT_API const terminalkit_cell *terminalkit_cells(terminalkit_handle *kit)
    TK_BORROWED;
TERMINALKIT_API const uint8_t *terminalkit_text(terminalkit_handle *kit)
    TK_BORROWED;
TERMINALKIT_API uint64_t terminalkit_text_size(terminalkit_handle *kit);
/* Convenience copy for language bindings; native clients can borrow cells/text. */
TERMINALKIT_API int terminalkit_row_text_copy(terminalkit_handle *kit, int row,
    uint8_t *buffer TK_OUT_BUFFER(inout_size), uint32_t *inout_size TK_INOUT);
/* Packed row: for each column, little-endian u64 style, u32 width,
 * u32 UTF-8 byte length, followed by the cell's UTF-8 bytes. */
TERMINALKIT_API int terminalkit_row_cells_copy(terminalkit_handle *kit, int row,
    uint8_t *buffer TK_OUT_BUFFER(inout_size), uint32_t *inout_size TK_INOUT);
/* Without a direct callback, emulator replies queue up to 1 MiB. A return of
 * -2 means the queue overflowed and at least one reply was lost. */
TERMINALKIT_API int terminalkit_take_replies(terminalkit_handle *kit,
    uint8_t *buffer TK_OUT_BUFFER(inout_size), uint32_t *inout_size TK_INOUT);

#endif
