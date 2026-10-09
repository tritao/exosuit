#include "textmate_regex.h"

#include <oniguruma.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TM_REGEX_MAX_PATTERNS 512
#define TM_REGEX_MAX_PATTERN_BYTES 4096
#define TM_REGEX_MAX_LINE_BYTES (1024 * 1024)

struct textmate_regex_scanner {
    OnigRegex *patterns;
    uint32_t count;
    uint32_t capacity;
    OnigRegSet *set;
    int match_index;
    int match_start;
};

static int initialized;
static _Thread_local char last_error[256];

static void set_error(const char *message) {
    if (message == NULL) message = "unknown Oniguruma error";
    snprintf(last_error, sizeof(last_error), "%s", message);
}

static int initialize(void) {
    if (initialized) return 0;
    OnigEncoding encoding = ONIG_ENCODING_UTF8;
    int status = onig_initialize(&encoding, 1);
    if (status != ONIG_NORMAL) {
        set_error("could not initialize Oniguruma UTF-8 support");
        return status;
    }
    /* Bound work for malformed or hostile grammars, including in browser builds. */
    onig_set_match_stack_limit_size(8192);
    onig_set_retry_limit_in_match(200000);
    onig_set_retry_limit_in_search(500000);
    onig_set_parse_depth_limit(256);
    onig_set_time_limit(10);
    initialized = 1;
    return 0;
}

int textmate_regex_scanner_create(textmate_regex_scanner **out_scanner) {
    if (out_scanner == NULL) {
        set_error("missing output for TextMate regex scanner");
        return -1;
    }
    *out_scanner = NULL;
    int status = initialize();
    if (status != 0) return status;
    textmate_regex_scanner *scanner = calloc(1, sizeof(*scanner));
    if (scanner == NULL) {
        set_error("out of memory creating TextMate regex scanner");
        return -1;
    }
    scanner->match_index = -1;
    scanner->match_start = -1;
    *out_scanner = scanner;
    return 0;
}

int textmate_regex_scanner_add(textmate_regex_scanner *scanner,
    const uint8_t *pattern, uint32_t pattern_size) {
    if (scanner == NULL || (pattern == NULL && pattern_size != 0) ||
        pattern_size > TM_REGEX_MAX_PATTERN_BYTES || scanner->count >= TM_REGEX_MAX_PATTERNS) {
        set_error("invalid or oversized TextMate regular expression");
        return -1;
    }
    OnigRegex compiled = NULL;
    OnigErrorInfo info;
    static const OnigUChar empty[] = "";
    const OnigUChar *start = pattern == NULL ? empty : (const OnigUChar *)pattern;
    int status = onig_new(&compiled, start, start + pattern_size, ONIG_OPTION_NONE,
        ONIG_ENCODING_UTF8, ONIG_SYNTAX_ONIGURUMA, &info);
    if (status != ONIG_NORMAL) {
        OnigUChar message[sizeof(last_error)];
        onig_error_code_to_str(message, status, &info);
        set_error((const char *)message);
        return status;
    }
    if (scanner->count == scanner->capacity) {
        uint32_t capacity = scanner->capacity == 0 ? 8 : scanner->capacity * 2;
        OnigRegex *patterns = realloc(scanner->patterns, capacity * sizeof(*patterns));
        if (patterns == NULL) {
            onig_free(compiled);
            set_error("out of memory adding TextMate regular expression");
            return -1;
        }
        scanner->patterns = patterns;
        scanner->capacity = capacity;
    }
    status = scanner->set == NULL
        ? onig_regset_new(&scanner->set, 1, &compiled)
        : onig_regset_add(scanner->set, compiled);
    if (status != ONIG_NORMAL) {
        onig_free(compiled);
        set_error("could not add pattern to Oniguruma scanner set");
        return status;
    }
    scanner->patterns[scanner->count++] = compiled;
    return 0;
}

int textmate_regex_scanner_search(textmate_regex_scanner *scanner,
    const uint8_t *text, uint32_t text_size, uint32_t start_byte) {
    if (scanner == NULL || (text == NULL && text_size != 0) || text_size > TM_REGEX_MAX_LINE_BYTES ||
        start_byte > text_size) {
        set_error("invalid or oversized TextMate input line");
        return -2;
    }
    scanner->match_index = -1;
    scanner->match_start = -1;
    if (scanner->count == 0) return -1;
    static const OnigUChar empty[] = "";
    const OnigUChar *line = text == NULL ? empty : (const OnigUChar *)text;
    const OnigUChar *end = line + text_size;
    int match_start = -1;
    int result = onig_regset_search(scanner->set, line, end, line + start_byte, end,
        ONIG_REGSET_POSITION_LEAD, ONIG_OPTION_NONE, &match_start);
    if (result >= 0) {
        scanner->match_index = result;
        scanner->match_start = match_start;
        return result;
    }
    if (result != ONIG_MISMATCH) {
        set_error("Oniguruma matching limit or runtime error");
        return result;
    }
    return -1;
}

int textmate_regex_scanner_match_start(const textmate_regex_scanner *scanner) {
    if (scanner == NULL || scanner->match_index < 0) return -1;
    OnigRegion *region = onig_regset_get_region(scanner->set, scanner->match_index);
    return region == NULL || region->num_regs == 0 ? scanner->match_start : region->beg[0];
}

int textmate_regex_scanner_match_end(const textmate_regex_scanner *scanner) {
    if (scanner == NULL || scanner->match_index < 0) return -1;
    OnigRegion *region = onig_regset_get_region(scanner->set, scanner->match_index);
    return region == NULL || region->num_regs == 0 ? -1 : region->end[0];
}

int textmate_regex_scanner_capture_count(const textmate_regex_scanner *scanner, uint32_t pattern_index) {
    if (scanner == NULL || pattern_index >= scanner->count) return -1;
    return onig_number_of_captures(scanner->patterns[pattern_index]) + 1;
}

static int capture_offset(const textmate_regex_scanner *scanner, uint32_t pattern_index,
    uint32_t capture_index, int end) {
    if (scanner == NULL || scanner->match_index != (int)pattern_index) return -1;
    OnigRegion *region = onig_regset_get_region(scanner->set, pattern_index);
    if (region == NULL || capture_index >= (uint32_t)region->num_regs) return -1;
    return end ? region->end[capture_index] : region->beg[capture_index];
}

int textmate_regex_scanner_capture_start(const textmate_regex_scanner *scanner,
    uint32_t pattern_index, uint32_t capture_index) {
    return capture_offset(scanner, pattern_index, capture_index, 0);
}

int textmate_regex_scanner_capture_end(const textmate_regex_scanner *scanner,
    uint32_t pattern_index, uint32_t capture_index) {
    return capture_offset(scanner, pattern_index, capture_index, 1);
}

const char *textmate_regex_last_error(void) {
    return last_error;
}

void textmate_regex_scanner_free(textmate_regex_scanner *scanner) {
    if (scanner == NULL) return;
    /* OnigRegSet owns and frees every registered OnigRegex. */
    if (scanner->set != NULL) onig_regset_free(scanner->set);
    free(scanner->patterns);
    free(scanner);
}
