#include "terminalkit_cells.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(expr) do { if (!(expr)) { \
    fprintf(stderr, "terminal contract failed at line %d: %s\n", __LINE__, #expr); \
    return 1; \
} } while (0)

static char replies[512];
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
static int row_fingerprints(void) {
    terminalkit_handle *kit = NULL;
    REQUIRE(terminalkit_open(20, 4, 16, "xterm-256color", &kit));
    REQUIRE(terminalkit_row_hash(kit, 0) == 0);
    REQUIRE(feed(kit, "\x1b[?25lfirst\r\nsecond\r\nthird\r\nfourth") >= 0);
    REQUIRE(terminalkit_snapshot(kit) >= 0);
    uint64_t id = terminalkit_row_id(kit, 1), hash = terminalkit_row_hash(kit, 1);
    REQUIRE(id != 0 && hash != 0);
    REQUIRE(feed(kit, "\r\nfifth") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0);
    REQUIRE(terminalkit_row_id(kit, 0) == id && terminalkit_row_hash(kit, 0) == hash);
    REQUIRE(feed(kit, "\x1b[H\x1b[31msecond") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0);
    REQUIRE(terminalkit_row_id(kit, 0) == id && terminalkit_row_hash(kit, 0) != hash);
    REQUIRE(feed(kit, "\x1b[H\x1b[0msecond") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0 && terminalkit_row_hash(kit, 0) == hash);
    REQUIRE(terminalkit_selection(kit, 0, 0, 1) == 0);
    REQUIRE(terminalkit_selection(kit, 4, 0, 2) == 0);
    REQUIRE(terminalkit_snapshot(kit) > 0 && terminalkit_row_hash(kit, 0) != hash);
    REQUIRE(terminalkit_selection(kit, 0, 0, 0) == 0);
    REQUIRE(terminalkit_snapshot(kit) > 0 && terminalkit_row_hash(kit, 0) == hash);
    REQUIRE(terminalkit_snapshot(kit) == 0 && terminalkit_row_hash(kit, 0) == hash);
    terminalkit_resize(kit, 24, 4);
    REQUIRE(terminalkit_snapshot(kit) > 0 && terminalkit_row_hash(kit, 0) != hash);
    REQUIRE(terminalkit_row_hash(kit, -1) == 0 && terminalkit_row_hash(kit, 4) == 0);
    terminalkit_close(kit);
    return 0;
}



static int default_colors_contract(void) {
    terminalkit_handle *kit = NULL;
    REQUIRE(terminalkit_open(32, 4, 1000, "xterm-256color", &kit));
    terminalkit_set_output_callback(kit, collect_reply, NULL);
    REQUIRE(feed(kit, "\033[1;31mKEEP\033[?2004h\033[?1000h") >= 0);
    REQUIRE(terminalkit_snapshot(kit) > 0);
    uint64_t style = terminalkit_cells(kit)[0].style;
    terminalkit_set_default_colors(kit, 0x202a36, 0xffffff);
    clear_replies();
    REQUIRE(feed(kit, "\033]10;?\033\\\033]11;?\007") >= 0);
    REQUIRE(!strcmp(replies, "\033]10;rgb:2020/2a2a/3636\033\\\033]11;rgb:ffff/ffff/ffff\007"));
    REQUIRE(terminalkit_snapshot(kit) >= 0);
    REQUIRE(terminalkit_cells(kit)[0].style == style);
    uint32_t size = 32; uint8_t text[32];
    REQUIRE(terminalkit_row_text_copy(kit, 0, text, &size) == 0 && !memcmp(text, "KEEP", 4));
    int keys, keypad, mouse, encoding, paste, focus;
    terminalkit_modes(kit, &keys, &keypad, &mouse, &encoding, &paste, &focus);
    REQUIRE(mouse != 0 && paste != 0);
    /* Host theme changes preserve application palette overrides and SGR state. */
    REQUIRE(feed(kit, "\033]4;1;rgb:12/34/56\007") >= 0);
    terminalkit_set_default_colors(kit, 0xdce3ec, 0x171c23);
    clear_replies();
    REQUIRE(feed(kit, "\033]10;?\007\033]11;?\033\\\033]4;1;?\007") >= 0);
    REQUIRE(!strcmp(replies, "\033]10;rgb:dcdc/e3e3/ecec\007\033]11;rgb:1717/1c1c/2323\033\\\033]4;1;rgb:1212/3434/5656\007"));
    REQUIRE(feed(kit, "X") >= 0);
    REQUIRE(terminalkit_snapshot(kit) >= 0);
    REQUIRE((terminalkit_cells(kit)[4].style & 8) != 0);
    REQUIRE(feed(kit, "\033c") >= 0);
    clear_replies();
    REQUIRE(feed(kit, "\033]11;?\007") >= 0);
    REQUIRE(!strcmp(replies, "\033]11;rgb:1717/1c1c/2323\007"));
    terminalkit_close(kit);
    clear_replies();
    return 0;
}

static int theme_notifications_contract(void) {
    terminalkit_handle *kit = NULL;
    REQUIRE(terminalkit_open(32, 4, 1000, "xterm-256color", &kit));
    terminalkit_set_output_callback(kit, collect_reply, NULL);
    terminalkit_set_default_colors(kit, 0x202a36, 0xffffff);
    clear_replies();
    REQUIRE(feed(kit, "\033[?996n\033[?2031$p") >= 0);
    REQUIRE(!strcmp(replies, "\033[?997;2n\033[?2031;2$y"));
    clear_replies();
    terminalkit_set_default_colors(kit, 0xdce3ec, 0x171c23);
    REQUIRE(reply_size == 0); /* Opt-in only; shells must not receive notifications. */
    REQUIRE(feed(kit, "\033[?2031h\033[?2031$p") >= 0);
    REQUIRE(!strcmp(replies, "\033[?2031;1$y"));
    clear_replies();
    terminalkit_set_default_colors(kit, 0x202a36, 0xffffff);
    REQUIRE(!strcmp(replies, "\033[?997;2n"));
    clear_replies();
    terminalkit_set_default_colors(kit, 0x202a36, 0xffffff);
    REQUIRE(reply_size == 0);
    terminalkit_set_default_colors(kit, 0xdce3ec, 0x171c23);
    REQUIRE(!strcmp(replies, "\033[?997;1n"));
    clear_replies();
    REQUIRE(feed(kit, "\033]11;?\007") >= 0);
    REQUIRE(!strcmp(replies, "\033]11;rgb:1717/1c1c/2323\007"));
    REQUIRE(feed(kit, "\033[?2031l") >= 0);
    clear_replies();
    terminalkit_set_default_colors(kit, 0x202a36, 0xffffff);
    REQUIRE(reply_size == 0);
    REQUIRE(feed(kit, "\033[?2031h\033c") >= 0);
    clear_replies();
    terminalkit_set_default_colors(kit, 0xdce3ec, 0x171c23);
    REQUIRE(reply_size == 0); /* Reset clears the subscription. */
    terminalkit_close(kit);
    return 0;
}

static int history_contract(void) {
    terminalkit_handle *source = NULL, *restored = NULL;
    REQUIRE(terminalkit_open(32, 4, 1000, "xterm-256color", &source));
    REQUIRE(terminalkit_open(32, 4, 1000, "xterm-256color", &restored));
    terminalkit_disable_checkpoints(source);
    for (int i = 0; i < 80; ++i) {
        char line[128];
        snprintf(line, sizeof(line), "\033[1;38;2;12;34;56mline-%03d 界 é\033[0m\r\n", i);
        REQUIRE(feed(source, line) >= 0);
    }
    /* Transient cursor and input modes must not become saved content. */
    REQUIRE(feed(source, "\033[?2004h\033[?1000h") >= 0);
    terminalkit_scrollback(source, 12, NULL, NULL);
    uint32_t length = 0;
    REQUIRE(terminalkit_history_copy(source, NULL, &length) == 1);
    REQUIRE(length > 0 && length <= 4u * 1024u * 1024u);
    uint8_t *history = malloc(length);
    REQUIRE(history && terminalkit_history_copy(source, history, &length) == 0);
    REQUIRE(terminalkit_feed(restored, history, length) >= 0);
    int current = 0, total = 0, saved_total = 0;
    terminalkit_scrollback(source, -1, &current, &total);
    REQUIRE(current == 12);
    terminalkit_scrollback(restored, -1, &current, &saved_total);
    REQUIRE(saved_total == total);
    int cursor_keys, keypad, mouse, encoding, paste, focus;
    terminalkit_modes(restored, &cursor_keys, &keypad, &mouse, &encoding, &paste, &focus);
    REQUIRE(mouse == 0 && paste == 0);
    terminalkit_scrollback(source, 0, NULL, NULL);
    REQUIRE(same_screen(source, restored));
    terminalkit_scrollback(source, total, NULL, NULL);
    terminalkit_scrollback(restored, total, NULL, NULL);
    REQUIRE(same_screen(source, restored));
    /* Re-exporting never accumulates cursor inversion or extra blank history. */
    uint32_t second_length = 0;
    REQUIRE(terminalkit_history_copy(restored, NULL, &second_length) == 1);
    uint8_t *second = malloc(second_length);
    REQUIRE(second && terminalkit_history_copy(restored, second, &second_length) == 0);
    REQUIRE(second_length == length && !memcmp(history, second, length));
    free(second); free(history);
    terminalkit_close(source); terminalkit_close(restored);
    /* A long, densely styled session must retain complete newest rows within
       the byte budget, even when raw output and the screen outgrow that budget. */
    REQUIRE(terminalkit_open(512, 4, 1000, "xterm-256color", &source));
    char dense[18000]; size_t used = 0;
    for (int column = 0; column < 512; ++column)
        used += (size_t)sprintf(dense + used, "\033[38;2;%d;34;56mX", column % 2 ? 12 : 13);
    used += (size_t)sprintf(dense + used, "\r\n");
    for (int row = 0; row < 900; ++row) REQUIRE(feed(source, dense) >= 0);
    REQUIRE(feed(source, "\033[0mNEWEST_RETAINED") >= 0);
    length = 0;
    REQUIRE(terminalkit_history_copy(source, NULL, &length) == 1);
    REQUIRE(length < 4u * 1024u * 1024u && length > 3u * 1024u * 1024u);
    history = malloc((size_t)length + 16);
    memset(history + length, 0x5a, 16);
    REQUIRE(terminalkit_history_copy(source, history, &length) == 0);
    for (int i = 0; i < 16; ++i) REQUIRE(history[length + i] == 0x5a);
    REQUIRE(terminalkit_open(512, 4, 1000, "xterm-256color", &restored));
    REQUIRE(terminalkit_feed(restored, history, length) >= 0);
    REQUIRE(same_screen(source, restored));
    free(history); terminalkit_close(source); terminalkit_close(restored);
    return 0;
}

int main(void) {
    REQUIRE(default_colors_contract() == 0);
    REQUIRE(theme_notifications_contract() == 0);
    terminalkit_handle *sync = NULL;
    REQUIRE(terminalkit_open(20, 4, 16, "xterm-256color", &sync));
    int generation = terminalkit_synchronized_output_generation(sync);
    REQUIRE(feed(sync, "\033[?2026h") >= 0);
    REQUIRE(terminalkit_synchronized_output(sync));
    REQUIRE(terminalkit_synchronized_output_generation(sync) != generation);
    generation = terminalkit_synchronized_output_generation(sync);
    REQUIRE(feed(sync, "\033[?2026l\033[?2026h") >= 0);
    REQUIRE(terminalkit_synchronized_output(sync));
    REQUIRE(terminalkit_synchronized_output_generation(sync) != generation);
    terminalkit_close(sync);
    REQUIRE(history_contract() == 0);
    REQUIRE(row_fingerprints() == 0);
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
    REQUIRE(terminalkit_snapshot(kit) > 0);
    REQUIRE(terminalkit_snapshot(kit) == 0);
    terminalkit_scrollback(kit, 0, &current, &total);
    REQUIRE(current == 0 && terminalkit_snapshot(kit) > 0);
    terminalkit_scrollback(kit, 1, &current, &total);
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
    REQUIRE(terminalkit_feed_range(protocol, (const uint8_t *)"xYz", 3, 1, 1) >= 0);
    REQUIRE(terminalkit_feed_range(protocol, (const uint8_t *)"xYz", 3, 2, 2) < 0);
    REQUIRE(terminalkit_snapshot(protocol) > 0);
    REQUIRE(terminalkit_text(protocol)[terminalkit_cells(protocol)[0].text_offset] == 'Y');
    terminalkit_set_output_callback(protocol, collect_reply, NULL);
    const uint8_t pasted[] = {'a', '\n', 0, 'b'};
    REQUIRE(terminalkit_paste(protocol, pasted, sizeof(pasted)) == 0);
    REQUIRE(reply_size == sizeof(pasted) && !memcmp(replies, pasted, sizeof(pasted)));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?2004h") >= 0);
    REQUIRE(terminalkit_paste(protocol, pasted, sizeof(pasted)) == 0);
    REQUIRE(reply_size == sizeof(pasted) + 12);
    REQUIRE(!memcmp(replies, "\x1b[200~", 6));
    REQUIRE(!memcmp(replies + 6, pasted, sizeof(pasted)));
    REQUIRE(!memcmp(replies + 6 + sizeof(pasted), "\x1b[201~", 6));
    clear_replies();
    REQUIRE(terminalkit_paste(protocol, NULL, 1) == -1 && reply_size == 0);
    REQUIRE(terminalkit_paste(protocol, pasted, 1024u * 1024u + 1) == -1 && reply_size == 0);
    REQUIRE(terminalkit_paste(protocol, NULL, 0) == 0 && reply_size == 0);
    REQUIRE(feed(protocol, "\x1b[?2004l") >= 0);
    REQUIRE(feed(protocol, "\x1b[?1006h") >= 0);
    REQUIRE(terminalkit_mouse_mode(protocol) == 0);
    REQUIRE(!terminalkit_mouse(protocol, 0, 0, 0, 1, 0) && reply_size == 0);
    REQUIRE(feed(protocol, "\x1b[?1000h") >= 0);
    REQUIRE(terminalkit_mouse_mode(protocol) == 2);
    REQUIRE(terminalkit_mouse(protocol, 0, 0, 0, 1, 0));
    REQUIRE(!strcmp(replies, "\x1b[<0;1;1M"));
    clear_replies();
    REQUIRE(!terminalkit_mouse(protocol, 1, 1, 32, 4, 0) && reply_size == 0);
    REQUIRE(feed(protocol, "\x1b[?1000l") >= 0);
    REQUIRE(terminalkit_mouse_mode(protocol) == 0);
    REQUIRE(!terminalkit_mouse(protocol, 0, 0, 0, 2, 0) && reply_size == 0);
    REQUIRE(feed(protocol, "\x1b[?u") >= 0);
    REQUIRE(!strcmp(replies, "\x1b[?0u"));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?1004h") >= 0);
    terminalkit_focus(protocol, 1);
    terminalkit_focus(protocol, 0);
    REQUIRE(!strcmp(replies, "\x1b[I\x1b[O"));
    clear_replies();
    /* Typed text is UTF-8 until the application (the Windows pseudoconsole)
     * requests win32-input-mode; then non-ASCII characters travel as key events,
     * astral ones as two UTF-16 units, and ASCII and malformed bytes stay raw. */
    const char typed[] = "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xff\r";
    REQUIRE(!terminalkit_win32_input_mode(protocol));
    REQUIRE(terminalkit_input_text(protocol, (const uint8_t *)typed, strlen(typed)) == 0);
    REQUIRE(!strcmp(replies, typed));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?9001h") >= 0);
    REQUIRE(terminalkit_win32_input_mode(protocol));
    REQUIRE(terminalkit_input_text(protocol, (const uint8_t *)typed, strlen(typed)) == 0);
    REQUIRE(!strcmp(replies, "a"
        "\x1b[0;0;233;1;0;1_\x1b[0;0;233;0;0;1_"
        "\x1b[0;0;8364;1;0;1_\x1b[0;0;8364;0;0;1_"
        "\x1b[0;0;55357;1;0;1_\x1b[0;0;55357;0;0;1_"
        "\x1b[0;0;56832;1;0;1_\x1b[0;0;56832;0;0;1_"
        "\xff\r"));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?2004h") >= 0);
    REQUIRE(terminalkit_paste(protocol, (const uint8_t *)"x\xc3\xa9", 3) == 0);
    REQUIRE(!strcmp(replies, "\x1b[200~x\x1b[0;0;233;1;0;1_\x1b[0;0;233;0;0;1_\x1b[201~"));
    clear_replies();
    REQUIRE(feed(protocol, "\x1b[?2004l\x1b[?9001l") >= 0);
    REQUIRE(!terminalkit_win32_input_mode(protocol));
    REQUIRE(terminalkit_input_text(protocol, (const uint8_t *)"\xc3\xa9", 2) == 0);
    REQUIRE(!strcmp(replies, "\xc3\xa9"));
    REQUIRE(terminalkit_input_text(protocol, NULL, 1) == -1);
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
    terminalkit_set_output_callback(protocol, NULL, NULL);
    REQUIRE(feed(protocol, "\x1b[?2004h") >= 0);
    uint8_t *large_paste = calloc(1024u * 1024u, 1);
    REQUIRE(large_paste);
    REQUIRE(terminalkit_paste(protocol, large_paste, 1024u * 1024u) == -1);
    uint32_t pending_size = 0;
    REQUIRE(terminalkit_take_replies(protocol, NULL, &pending_size) == 0 && pending_size == 0);
    REQUIRE(terminalkit_paste(protocol, pasted, sizeof(pasted)) == 0);
    uint8_t queued[32];
    pending_size = sizeof(queued);
    REQUIRE(terminalkit_take_replies(protocol, queued, &pending_size) == 0);
    REQUIRE(pending_size == sizeof(pasted) + 12);
    REQUIRE(!memcmp(queued, "\x1b[200~", 6) && !memcmp(queued + 6, pasted, sizeof(pasted)));
    free(large_paste);
    terminalkit_close(protocol);
    terminalkit_handle *selected = NULL;
    REQUIRE(terminalkit_open(12, 2, 8, "xterm", &selected));
    REQUIRE(feed(selected, "alpha\r\n日本語!") >= 0);
    REQUIRE(terminalkit_snapshot(selected) > 0);
    uint32_t selection_size = 0;
    REQUIRE(terminalkit_selection_copy(selected, NULL, &selection_size) == -2);
    REQUIRE(terminalkit_selection(selected, 0, 0, 1) == 0);
    REQUIRE(terminalkit_selection(selected, 4, 0, 2) == 0);
    REQUIRE(terminalkit_snapshot(selected) > 0 && terminalkit_row_changed(selected, 0));
    REQUIRE(terminalkit_selection_copy(selected, NULL, &selection_size) == 1 && selection_size == 5);
    uint8_t selection_text[32];
    memset(selection_text, '!', sizeof(selection_text));
    selection_size = 4;
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 1);
    REQUIRE(selection_text[0] == '!' && selection_size == 5);
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 0);
    REQUIRE(!memcmp(selection_text, "alpha", 5) && selection_text[5] == '!');
    REQUIRE(terminalkit_selection(selected, 4, 0, 1) == 0);
    REQUIRE(terminalkit_selection(selected, 0, 0, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 5 && !memcmp(selection_text, "alpha", 5));
    REQUIRE(terminalkit_selection(selected, 5, 1, 1) == 0);
    REQUIRE(terminalkit_selection(selected, 5, 1, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == strlen("語") && !memcmp(selection_text, "語", selection_size));
    REQUIRE(terminalkit_selection(selected, 0, 0, 1) == 0);
    REQUIRE(terminalkit_selection(selected, 5, 1, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == strlen("alpha\n日本語") && !memcmp(selection_text, "alpha\n日本語", selection_size));
    REQUIRE(terminalkit_selection(selected, 0, 0, 1) == 0);
    REQUIRE(terminalkit_selection(selected, 4, 0, 2) == 0);
    REQUIRE(feed(selected, "\r\nnext\r\nlast") >= 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(selected, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 5 && !memcmp(selection_text, "alpha", 5));
    REQUIRE(terminalkit_selection(selected, 0, 0, 0) == 0);
    REQUIRE(terminalkit_selection_copy(selected, NULL, &selection_size) == -2);
    REQUIRE(terminalkit_selection(selected, 12, 0, 1) == -1);
    terminalkit_close(selected);
    /* Semantic selection retains its initial unit when dragging in either direction. */
    terminalkit_handle *units = NULL;
    REQUIRE(terminalkit_open(20, 4, 8, "xterm", &units));
    REQUIRE(feed(units, "alpha beta_gamma!\r\n日本語 test\r\nthird") >= 0);
    REQUIRE(terminalkit_selection(units, 2, 0, 3) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 5 && !memcmp(selection_text, "alpha", 5));
    REQUIRE(terminalkit_snapshot(units) > 0);
    REQUIRE((terminalkit_cells(units)[0].style & 64) != 0);
    REQUIRE((terminalkit_cells(units)[0].style & 3) == 0); /* Selection is metadata, not inverse video. */
    REQUIRE(terminalkit_selection(units, 10, 0, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 16 && !memcmp(selection_text, "alpha beta_gamma", 16));
    REQUIRE(terminalkit_selection(units, 10, 0, 3) == 0);
    REQUIRE(terminalkit_selection(units, 2, 0, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 16 && !memcmp(selection_text, "alpha beta_gamma", 16));
    REQUIRE(terminalkit_selection(units, 5, 1, 3) == 0); /* Wide continuation resolves to its glyph. */
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == strlen("日本語") && !memcmp(selection_text, "日本語", selection_size));
    REQUIRE(terminalkit_selection(units, 3, 1, 4) == 0);
    REQUIRE(terminalkit_selection(units, 1, 2, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == strlen("日本語 test\nthird") && !memcmp(selection_text, "日本語 test\nthird", selection_size));
    REQUIRE(terminalkit_selection(units, 2, 0, 3) == 0);
    REQUIRE(terminalkit_selection(units, 8, 0, 5) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(units, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 9 && !memcmp(selection_text, "alpha bet", 9));
    terminalkit_close(units);
    terminalkit_handle *wrapped = NULL;
    REQUIRE(terminalkit_open(8, 4, 8, "xterm", &wrapped));
    REQUIRE(feed(wrapped, "abcdefghijk\r\nXYZ") >= 0);
    REQUIRE(terminalkit_selection(wrapped, 0, 0, 1) == 0);
    REQUIRE(terminalkit_selection(wrapped, 2, 1, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(wrapped, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 11 && !memcmp(selection_text, "abcdefghijk", 11));
    REQUIRE(terminalkit_selection(wrapped, 2, 2, 2) == 0);
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(wrapped, selection_text, &selection_size) == 0);
    REQUIRE(selection_size == 15 && !memcmp(selection_text, "abcdefghijk\nXYZ", 15));
    REQUIRE(feed(wrapped, "\r\n1\r\n2\r\n3\r\n4") >= 0);
    terminalkit_resize(wrapped, 20, 4);
    terminalkit_scrollback(wrapped, 3, NULL, NULL);
    REQUIRE(terminalkit_selection(wrapped, 18, 0, 3) == 0); /* Old history rows may be narrower. */
    selection_size = sizeof(selection_text);
    REQUIRE(terminalkit_selection_copy(wrapped, selection_text, &selection_size) == 0);
    terminalkit_close(wrapped);
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
    terminalkit_disable_checkpoints(restored);
    REQUIRE(terminalkit_checkpoint_size(restored) == 0);
    REQUIRE(!terminalkit_checkpoint(restored, checkpoint, size, &written));
    REQUIRE(!terminalkit_restore(restored, checkpoint, size));
    REQUIRE(feed(restored, "\x1b[Hlive") >= 0);
    terminalkit_snapshot(restored);
    REQUIRE(strstr((const char*)terminalkit_text(restored), "live") != NULL);
    terminalkit_close(restored);
    terminalkit_close(kit);
    free(checkpoint);
    return 0;
}
