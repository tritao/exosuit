#include "terminalkit_cells.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(expr) do { if (!(expr)) { \
    fprintf(stderr, "terminal contract failed at line %d: %s\n", __LINE__, #expr); \
    return 1; \
} } while (0)

static char replies[128];
static size_t reply_size;
static void collect_reply(const char *bytes, int length, void *user_data) {
    (void)user_data;
    if (length < 0 || (size_t)length >= sizeof(replies) - reply_size) return;
    memcpy(replies + reply_size, bytes, (size_t)length);
    reply_size += (size_t)length;
    replies[reply_size] = 0;
}
static void clear_replies(void) { reply_size = 0; replies[0] = 0; }

static int feed(terminalkit_handle *kit, const char *text) {
    return terminalkit_feed(kit, (const uint8_t *)text, strlen(text));
}
static int same_screen(terminalkit_handle *a, terminalkit_handle *b) {
    if (terminalkit_columns(a) != terminalkit_columns(b) ||
        terminalkit_rows(a) != terminalkit_rows(b)) return 0;
    if (terminalkit_snapshot(a) < 0 || terminalkit_snapshot(b) < 0) return 0;
    const terminalkit_cell *ac = terminalkit_cells(a), *bc = terminalkit_cells(b);
    const uint8_t *at = terminalkit_text(a), *bt = terminalkit_text(b);
    int count = terminalkit_columns(a) * terminalkit_rows(a);
    for (int i = 0; i < count; ++i) {
        if (ac[i].width != bc[i].width || ac[i].style != bc[i].style ||
            ac[i].text_length != bc[i].text_length ||
            memcmp(at + ac[i].text_offset, bt + bc[i].text_offset, ac[i].text_length)) {
            fprintf(stderr, "cell %d: width %u/%u style %llu/%llu text %.*s/%.*s\n", i,
                ac[i].width, bc[i].width, (unsigned long long)ac[i].style,
                (unsigned long long)bc[i].style, (int)ac[i].text_length,
                at + ac[i].text_offset, (int)bc[i].text_length, bt + bc[i].text_offset);
            return 0;
        }
    }
    return 1;
}
int main(void) {
    terminalkit_handle *kit = NULL, *restored = NULL;
    REQUIRE(terminalkit_open(20, 4, 8, "xterm-256color", &kit));
    REQUIRE(terminalkit_snapshot(kit) == 4);
    REQUIRE(terminalkit_snapshot(kit) == 0);
    REQUIRE(feed(kit, "hello\r\n") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0);
    REQUIRE(terminalkit_row_changed(kit, 0));
    const terminalkit_cell *cells = terminalkit_cells(kit);
    const uint8_t *text = terminalkit_text(kit);
    REQUIRE(cells[0].text_length == 1 && text[cells[0].text_offset] == 'h');
    int col = -1, row = -1, mode = -1;
    REQUIRE(terminalkit_cursor(kit, &col, &row, &mode) && col == 0 && row == 1);
    REQUIRE(feed(kit, "\x1b[31mX\x1b[0m") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0);
    cells = terminalkit_cells(kit);
    REQUIRE(cells[20].style != cells[0].style);
    REQUIRE(feed(kit, "\x1b[?1006h\x1b[?1004h\x1b[?2026h") >= 0);
    REQUIRE(terminalkit_focus_reporting(kit));
    REQUIRE(terminalkit_synchronized_output(kit));
    REQUIRE(feed(kit, "\x1b[?2026l") >= 0);
    REQUIRE(!terminalkit_synchronized_output(kit));
    REQUIRE(feed(kit, "\x1b]0;checkpoint-title\a") >= 0);
    REQUIRE(terminalkit_title(kit) && !strcmp(terminalkit_title(kit), "checkpoint-title"));
    REQUIRE(feed(kit, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n") >= 0);
    int current = 0, total = 0;
    terminalkit_scrollback(kit, 1, &current, &total);
    REQUIRE(current == 1 && total > 0);
    uint64_t size = terminalkit_checkpoint_size(kit), written = 0;
    REQUIRE(size > 0);
    void *checkpoint = malloc((size_t)size);
    REQUIRE(checkpoint && terminalkit_checkpoint(kit, checkpoint, size, &written) && written == size);
    REQUIRE(terminalkit_open(5, 2, 2, "xterm", &restored));
    REQUIRE(terminalkit_restore(restored, checkpoint, size));
    REQUIRE(same_screen(kit, restored));
    REQUIRE(!terminalkit_restore(restored, checkpoint, size - 1));
    REQUIRE(same_screen(kit, restored));
    REQUIRE(terminalkit_columns(restored) == 20 && terminalkit_rows(restored) == 4);
    REQUIRE(terminalkit_title(restored) && !strcmp(terminalkit_title(restored), "checkpoint-title"));
    terminalkit_scrollback(restored, -1, &current, &total);
    REQUIRE(current == 1 && total > 0);
    terminalkit_handle *protocol = NULL;
    REQUIRE(terminalkit_open(20, 4, 8, "xterm-256color", &protocol));
    terminalkit_set_output_callback(protocol, collect_reply, NULL);
    REQUIRE(feed(protocol, "\x1b[?u") >= 0);
    REQUIRE(!strcmp(replies, "\x1b[?0u"));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?1004h") >= 0);
    terminalkit_focus(protocol, 1);
    terminalkit_focus(protocol, 0);
    REQUIRE(!strcmp(replies, "\x1b[I\x1b[O"));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?1049h\x1b[?1007h") >= 0);
    REQUIRE(terminalkit_alternate_screen(protocol));
    REQUIRE(terminalkit_mouse(protocol, 0, 0, 64, 1, 0));
    REQUIRE(!strcmp(replies, "\x1b[A"));
    REQUIRE(feed(protocol, "\x1b[>7u") >= 0);
    clear_replies();
    REQUIRE(terminalkit_keyboard(protocol, "c", 4, UINT32_MAX));
    REQUIRE(!strcmp(replies, "\x1b[99;5:1u"));
    REQUIRE(feed(protocol, "\x1b[?1049l") >= 0);
    REQUIRE(!terminalkit_alternate_screen(protocol));
    terminalkit_close(protocol);
    terminalkit_handle *unicode = NULL;
    REQUIRE(terminalkit_open(20, 2, 0, "xterm-256color", &unicode));
    uint8_t combining[65];
    combining[0] = 'A';
    for (int i = 0; i < 32; ++i) {
        combining[1 + i * 2] = 0xCC;
        combining[2 + i * 2] = 0x81;
    }
    REQUIRE(terminalkit_feed(unicode, combining, sizeof(combining)) >= 0);
    REQUIRE(terminalkit_snapshot(unicode) > 0);
    /* This pinned libtsm stores at most ten code points per cell. */
    REQUIRE(terminalkit_cells(unicode)[0].text_length == 19);
    terminalkit_close(unicode);
    terminalkit_close(restored);
    terminalkit_close(kit);
    free(checkpoint);
    return 0;
}
