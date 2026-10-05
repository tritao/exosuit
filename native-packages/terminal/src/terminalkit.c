#include "terminalkit_cells.h"
#include "terminal_emulator.h"
#include <limits.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define TERMINALKIT_REPLY_LIMIT (1024u * 1024u)

struct terminalkit_handle {
    terminal_emulator_t *emulator;
    int columns, rows, snapshot_valid, snapshot_failed, dirty;
    terminalkit_cell *cells;
    uint64_t *row_ids;
    uint64_t *row_hashes;
    uint8_t *changed;
    uint8_t *text;
    size_t text_size, text_capacity;
    terminalkit_output_callback output_callback;
    void *output_user_data;
    uint8_t *replies;
    uint32_t reply_size, reply_capacity;
    int reply_overflow;
};

static void emit_reply(const char *bytes, int length, void *user_data) {
    terminalkit_handle *kit = user_data;
    if (!kit || !bytes || length <= 0) return;
    if (kit->output_callback) {
        kit->output_callback(bytes, length, kit->output_user_data);
        return;
    }
    if ((uint32_t)length > TERMINALKIT_REPLY_LIMIT - kit->reply_size) {
        kit->reply_overflow = 1;
        return;
    }
    uint32_t needed = kit->reply_size + (uint32_t)length;
    if (needed > kit->reply_capacity) {
        uint32_t capacity = kit->reply_capacity ? kit->reply_capacity : 256;
        while (capacity < needed)
            capacity = capacity > TERMINALKIT_REPLY_LIMIT / 2
                ? TERMINALKIT_REPLY_LIMIT : capacity * 2;
        uint8_t *grown = realloc(kit->replies, capacity);
        if (!grown) { kit->reply_overflow = 1; return; }
        kit->replies = grown; kit->reply_capacity = capacity;
    }
    memcpy(kit->replies + kit->reply_size, bytes, (size_t)length);
    kit->reply_size = needed;
}

static int allocate_grid(terminalkit_handle *kit, int columns, int rows) {
    if (columns < 1 || rows < 1 || (size_t)columns > SIZE_MAX / (size_t)rows ||
        (size_t)columns * (size_t)rows > SIZE_MAX / sizeof(terminalkit_cell))
        return 0;
    terminalkit_cell *cells = calloc((size_t)columns * (size_t)rows, sizeof(*cells));
    uint64_t *ids = calloc((size_t)rows, sizeof(*ids));
    uint64_t *hashes = calloc((size_t)rows, sizeof(*hashes));
    uint8_t *changed = calloc((size_t)rows, 1);
    if (!cells || !ids || !hashes || !changed) {
        free(cells); free(ids); free(hashes); free(changed);
        return 0;
    }
    free(kit->cells); free(kit->row_ids); free(kit->row_hashes); free(kit->changed);
    kit->cells = cells; kit->row_ids = ids; kit->row_hashes = hashes; kit->changed = changed;
    kit->columns = columns; kit->rows = rows; kit->snapshot_valid = 0; kit->dirty = 1;
    return 1;
}

int terminalkit_open(int columns, int rows, int scrollback_limit,
    const char *term, terminalkit_handle **out_kit) {
    if (!out_kit || columns < 1 || rows < 1 || scrollback_limit < 0) return 0;
    *out_kit = NULL;
    terminalkit_handle *kit = calloc(1, sizeof(*kit));
    if (!kit) return 0;
    if (!allocate_grid(kit, columns, rows)) { free(kit); return 0; }
    kit->emulator = terminal_emulator_new(columns, rows, scrollback_limit,
        term ? term : "xterm-256color");
    if (!kit->emulator) { terminalkit_close(kit); return 0; }
    terminal_emulator_set_input_callback(kit->emulator, emit_reply, kit);
    *out_kit = kit;
    return 1;
}

void terminalkit_close(terminalkit_handle *kit) {
    if (!kit) return;
    terminal_emulator_free(kit->emulator);
    free(kit->cells); free(kit->row_ids); free(kit->row_hashes);
    free(kit->changed); free(kit->text); free(kit->replies);
    free(kit);
}
int terminalkit_feed(terminalkit_handle *kit, const uint8_t *bytes, uint64_t size) {
    if (!kit || (!bytes && size) || size > SIZE_MAX) return -1;
    if (size) kit->dirty = 1;
    return terminal_emulator_feed(kit->emulator, (const char *)bytes, (size_t)size);
}
int terminalkit_feed_range(terminalkit_handle *kit, const uint8_t *bytes,
    uint64_t buffer_size, uint64_t offset, uint64_t size) {
    if (!kit || (!bytes && buffer_size) || offset > buffer_size ||
        size > buffer_size - offset || offset > SIZE_MAX || size > SIZE_MAX)
        return -1;
    return terminalkit_feed(kit, bytes ? bytes + (size_t)offset : NULL, size);
}
void terminalkit_resize(terminalkit_handle *kit, int columns, int rows) {
    if (!kit || columns < 1 || rows < 1 || !allocate_grid(kit, columns, rows)) return;
    terminal_emulator_resize(kit->emulator, columns, rows);
}
int terminalkit_columns(terminalkit_handle *kit) { return kit ? kit->columns : 0; }
int terminalkit_rows(terminalkit_handle *kit) { return kit ? kit->rows : 0; }
int terminalkit_cursor(terminalkit_handle *kit, int *column, int *row, int *mode) {
    return kit && terminal_emulator_cursor(kit->emulator, column, row, mode);
}
int terminalkit_mouse_mode(terminalkit_handle *kit) {
    int mode = 0;
    if (kit) terminal_emulator_modes(kit->emulator, NULL, NULL, &mode, NULL, NULL, NULL);
    return mode;
}
int terminalkit_focus_reporting(terminalkit_handle *kit) {
    int mode = 0;
    if (kit) terminal_emulator_modes(kit->emulator, NULL, NULL, NULL, NULL, NULL, &mode);
    return mode;
}
int terminalkit_synchronized_output(terminalkit_handle *kit) {
    return kit && terminal_emulator_synchronized_output(kit->emulator);
}
int terminalkit_alternate_screen(terminalkit_handle *kit) {
    return kit && terminal_emulator_alternate_screen(kit->emulator);
}
const char *terminalkit_title(terminalkit_handle *kit) {
    return kit ? terminal_emulator_name(kit->emulator) : NULL;
}
void terminalkit_focus(terminalkit_handle *kit, int focused) {
    if (kit) terminal_emulator_focus(kit->emulator, focused);
}
void terminalkit_set_output_callback(terminalkit_handle *kit,
    terminalkit_output_callback callback, void *user_data) {
    if (!kit) return;
    kit->output_callback = callback;
    kit->output_user_data = user_data;
}
int terminalkit_paste(terminalkit_handle *kit, const uint8_t *bytes, uint64_t size) {
    if (!kit || (!bytes && size) || size > TERMINALKIT_REPLY_LIMIT) return -1;
    if (!size) return 0;
    int mode = 0;
    terminal_emulator_modes(kit->emulator, NULL, NULL, NULL, NULL, &mode, NULL);
    uint32_t needed = (uint32_t)size + (mode ? 12u : 0u);
    if (!kit->output_callback) {
        if (kit->reply_overflow || needed > TERMINALKIT_REPLY_LIMIT - kit->reply_size)
            return -1;
        needed += kit->reply_size;
        if (needed > kit->reply_capacity) {
            uint8_t *grown = realloc(kit->replies, needed);
            if (!grown) return -1;
            kit->replies = grown;
            kit->reply_capacity = needed;
        }
    }
    if (mode) emit_reply("\033[200~", 6, kit);
    emit_reply((const char *)bytes, (int)size, kit);
    if (mode) emit_reply("\033[201~", 6, kit);
    return 0;
}
int terminalkit_keyboard(terminalkit_handle *kit, const char *key_name,
    uint32_t modifiers, uint32_t unicode) {
    return kit && terminal_emulator_keyboard(kit->emulator, key_name, modifiers, unicode);
}
int terminalkit_mouse(terminalkit_handle *kit, uint32_t x, uint32_t y,
    uint32_t button, uint32_t event, uint8_t modifiers) {
    return kit && terminal_emulator_mouse(kit->emulator, x, y, button, event, modifiers);
}
int terminalkit_selection(terminalkit_handle *kit, uint32_t column, uint32_t row, int operation) {
    if (!kit) return -1;
    int status = terminal_emulator_selection(kit->emulator, column, row, operation);
    if (!status) kit->dirty = 1;
    return status;
}
int terminalkit_selection_copy(terminalkit_handle *kit, uint8_t *buffer, uint32_t *inout_size) {
    if (!kit || !inout_size) return -1;
    size_t written = 0;
    int status = terminal_emulator_selection_copy(kit->emulator, (char *)buffer, *inout_size, &written);
    if (written > UINT32_MAX) return -1;
    *inout_size = (uint32_t)written;
    if (status == -ENOENT) return -2;
    return status < 0 ? -1 : status;
}
void terminalkit_scrollback(terminalkit_handle *kit, int position, int *current, int *total) {
    if (!kit) return;
    int before = 0;
    terminal_emulator_scrollback(kit->emulator, -1, &before, NULL);
    terminal_emulator_scrollback(kit->emulator, position, current, total);
    if (position >= 0 && current && *current != before) kit->dirty = 1;
}
void terminalkit_disable_checkpoints(terminalkit_handle *kit) {
    if (kit) terminal_emulator_disable_checkpoints(kit->emulator);
}
uint64_t terminalkit_checkpoint_size(terminalkit_handle *kit) {
    return kit ? (uint64_t)terminal_emulator_checkpoint_size(kit->emulator) : 0;
}
int terminalkit_checkpoint(terminalkit_handle *kit, void *buffer,
    uint64_t capacity, uint64_t *written) {
    size_t size = 0;
    if (!kit || capacity > SIZE_MAX || !written) return 0;
    int ok = terminal_emulator_checkpoint(kit->emulator, buffer, (size_t)capacity, &size);
    *written = (uint64_t)size;
    return ok;
}
int terminalkit_restore(terminalkit_handle *kit, const void *data, uint64_t size) {
    if (!kit || !data || size > SIZE_MAX ||
        !terminal_emulator_restore_checkpoint(kit->emulator, data, (size_t)size)) return 0;
    int columns = 0, rows = 0;
    terminal_emulator_dimensions(kit->emulator, &columns, &rows);
    return allocate_grid(kit, columns, rows);
}

static void collect_cell(int row, int column, int width, uint64_t style,
    const char *text, int length, void *user_data) {
    terminalkit_handle *kit = user_data;
    if (row < 0 || row >= kit->rows || column < 0 || column >= kit->columns || length < 0)
        return;
    if ((size_t)length > SIZE_MAX - kit->text_size) { kit->snapshot_failed = 1; return; }
    size_t needed = kit->text_size + (size_t)length;
    if (needed > UINT32_MAX) { kit->snapshot_failed = 1; return; }
    if (needed > kit->text_capacity) {
        size_t capacity = kit->text_capacity ? kit->text_capacity : 1024;
        while (capacity < needed) capacity = capacity > SIZE_MAX / 2 ? needed : capacity * 2;
        uint8_t *grown = realloc(kit->text, capacity);
        if (!grown) { kit->snapshot_failed = 1; return; }
        kit->text = grown; kit->text_capacity = capacity;
    }
    terminalkit_cell *cell = &kit->cells[(size_t)row * kit->columns + column];
    cell->text_offset = (uint32_t)kit->text_size;
    cell->text_length = (uint32_t)length;
    cell->width = (uint32_t)width;
    cell->style = style;
    if (length) memcpy(kit->text + kit->text_size, text, (size_t)length);
    kit->text_size = needed;
}

static uint64_t hash_bytes(uint64_t hash, const void *data, size_t size) {
    const uint8_t *bytes = data;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

int terminalkit_snapshot(terminalkit_handle *kit) {
    if (!kit) return -1;
    if (kit->snapshot_valid && !kit->dirty) {
        memset(kit->changed, 0, (size_t)kit->rows);
        return 0;
    }
    kit->text_size = 0; kit->snapshot_failed = 0;
    memset(kit->cells, 0, (size_t)kit->columns * kit->rows * sizeof(*kit->cells));
    if (!terminal_emulator_for_each_cell(kit->emulator, collect_cell, kit) || kit->snapshot_failed) {
        kit->snapshot_valid = 0;
        return -1;
    }
    int count = 0;
    for (int row = 0; row < kit->rows; ++row) {
        uint64_t hash = UINT64_C(14695981039346656037);
        for (int col = 0; col < kit->columns; ++col) {
            const terminalkit_cell *cell = &kit->cells[(size_t)row * kit->columns + col];
            hash = hash_bytes(hash, &cell->width, sizeof(cell->width));
            hash = hash_bytes(hash, &cell->style, sizeof(cell->style));
            hash = hash_bytes(hash, &cell->text_length, sizeof(cell->text_length));
            if (cell->text_length)
                hash = hash_bytes(hash, kit->text + cell->text_offset, cell->text_length);
        }
        kit->changed[row] = !kit->snapshot_valid || kit->row_hashes[row] != hash;
        if (kit->changed[row]) ++count;
        kit->row_hashes[row] = hash;
        kit->row_ids[row] = terminal_emulator_row_id(kit->emulator, row);
    }
    kit->snapshot_valid = 1;
    kit->dirty = 0;
    return count;
}
int terminalkit_row_changed(terminalkit_handle *kit, int row) {
    return kit && row >= 0 && row < kit->rows && kit->changed[row];
}
uint64_t terminalkit_row_id(terminalkit_handle *kit, int row) {
    return kit && row >= 0 && row < kit->rows ? kit->row_ids[row] : 0;
}
const terminalkit_cell *terminalkit_cells(terminalkit_handle *kit) { return kit ? kit->cells : NULL; }
const uint8_t *terminalkit_text(terminalkit_handle *kit) { return kit ? kit->text : NULL; }
uint64_t terminalkit_text_size(terminalkit_handle *kit) { return kit ? kit->text_size : 0; }
int terminalkit_row_text_copy(terminalkit_handle *kit, int row,
    uint8_t *buffer, uint32_t *inout_size) {
    if (!kit || !inout_size || row < 0 || row >= kit->rows || !kit->snapshot_valid)
        return -1;
    uint64_t needed = 0;
    for (int col = 0; col < kit->columns; ++col) {
        const terminalkit_cell *cell = &kit->cells[(size_t)row * kit->columns + col];
        if (!cell->width) continue;
        needed += cell->text_length ? cell->text_length : 1;
    }
    if (needed > UINT32_MAX) return -1;
    uint32_t available = *inout_size;
    *inout_size = (uint32_t)needed;
    if (!buffer || available < needed) return 1;
    uint32_t offset = 0;
    for (int col = 0; col < kit->columns; ++col) {
        const terminalkit_cell *cell = &kit->cells[(size_t)row * kit->columns + col];
        if (!cell->width) continue;
        if (cell->text_length) {
            memcpy(buffer + offset, kit->text + cell->text_offset, cell->text_length);
            offset += cell->text_length;
        } else buffer[offset++] = ' ';
    }
    return 0;
}

static void write_u32(uint8_t *buffer, uint32_t value) {
    for (int i = 0; i < 4; ++i) buffer[i] = (uint8_t)(value >> (8 * i));
}
static void write_u64(uint8_t *buffer, uint64_t value) {
    for (int i = 0; i < 8; ++i) buffer[i] = (uint8_t)(value >> (8 * i));
}
int terminalkit_row_cells_copy(terminalkit_handle *kit, int row,
    uint8_t *buffer, uint32_t *inout_size) {
    if (!kit || !inout_size || row < 0 || row >= kit->rows || !kit->snapshot_valid)
        return -1;
    uint64_t needed = (uint64_t)kit->columns * 16;
    for (int col = 0; col < kit->columns; ++col)
        needed += kit->cells[(size_t)row * kit->columns + col].text_length;
    if (needed > UINT32_MAX) return -1;
    uint32_t available = *inout_size;
    *inout_size = (uint32_t)needed;
    if (!buffer || available < needed) return 1;
    uint32_t offset = 0;
    for (int col = 0; col < kit->columns; ++col) {
        const terminalkit_cell *cell = &kit->cells[(size_t)row * kit->columns + col];
        write_u64(buffer + offset, cell->style);
        write_u32(buffer + offset + 8, cell->width);
        write_u32(buffer + offset + 12, cell->text_length);
        offset += 16;
        if (cell->text_length) {
            memcpy(buffer + offset, kit->text + cell->text_offset, cell->text_length);
            offset += cell->text_length;
        }
    }
    return 0;
}
int terminalkit_take_replies(terminalkit_handle *kit,
    uint8_t *buffer, uint32_t *inout_size) {
    if (!kit || !inout_size) return -1;
    if (kit->reply_overflow) {
        kit->reply_overflow = 0;
        kit->reply_size = 0;
        *inout_size = 0;
        return -2;
    }
    uint32_t available = *inout_size;
    *inout_size = kit->reply_size;
    if (kit->reply_size == 0) return 0;
    if (!buffer || available < kit->reply_size) return 1;
    memcpy(buffer, kit->replies, kit->reply_size);
    kit->reply_size = 0;
    return 0;
}
