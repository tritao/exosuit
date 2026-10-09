#ifndef TEXTMATE_REGEX_H
#define TEXTMATE_REGEX_H

#include <stdint.h>

#if defined(_WIN32)
# if defined(TEXTMATE_REGEX_BUILDING)
#  define TEXTMATE_REGEX_API __declspec(dllexport)
# else
#  define TEXTMATE_REGEX_API __declspec(dllimport)
# endif
#else
# define TEXTMATE_REGEX_API __attribute__((visibility("default")))
#endif

#if defined(__clang__)
# define TEXTMATE_REGEX_OPAQUE __attribute__((annotate("hxi:opaque")))
# define TEXTMATE_REGEX_OUT __attribute__((annotate("hxi:out")))
# define TEXTMATE_REGEX_IN_ARRAY(count) __attribute__((annotate("hxi:in_array")))
# define TEXTMATE_REGEX_BORROWED __attribute__((annotate("hxi:borrowed")))
# define TEXTMATE_REGEX_NULLABLE _Nullable
# define TEXTMATE_REGEX_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#else
# define TEXTMATE_REGEX_OPAQUE
# define TEXTMATE_REGEX_OUT
# define TEXTMATE_REGEX_IN_ARRAY(count)
# define TEXTMATE_REGEX_BORROWED
# define TEXTMATE_REGEX_NULLABLE
# define TEXTMATE_REGEX_RETURNS_BORROWED_UTF8
#endif

typedef struct textmate_regex_scanner textmate_regex_scanner TEXTMATE_REGEX_OPAQUE;

/* A scanner searches an ordered set of Oniguruma expressions in one UTF-8 line. */
TEXTMATE_REGEX_API int textmate_regex_scanner_create(
    textmate_regex_scanner * TEXTMATE_REGEX_NULLABLE *out_scanner TEXTMATE_REGEX_OUT TEXTMATE_REGEX_BORROWED);
TEXTMATE_REGEX_API int textmate_regex_scanner_add(textmate_regex_scanner *scanner,
    const uint8_t *pattern TEXTMATE_REGEX_IN_ARRAY(pattern_size), uint32_t pattern_size);
TEXTMATE_REGEX_API int textmate_regex_scanner_search(textmate_regex_scanner *scanner,
    const uint8_t *text TEXTMATE_REGEX_IN_ARRAY(text_size), uint32_t text_size,
    uint32_t start_byte);
TEXTMATE_REGEX_API int textmate_regex_scanner_match_start(const textmate_regex_scanner *scanner);
TEXTMATE_REGEX_API int textmate_regex_scanner_match_end(const textmate_regex_scanner *scanner);
TEXTMATE_REGEX_API int textmate_regex_scanner_capture_count(
    const textmate_regex_scanner *scanner, uint32_t pattern_index);
TEXTMATE_REGEX_API int textmate_regex_scanner_capture_start(
    const textmate_regex_scanner *scanner, uint32_t pattern_index, uint32_t capture_index);
TEXTMATE_REGEX_API int textmate_regex_scanner_capture_end(
    const textmate_regex_scanner *scanner, uint32_t pattern_index, uint32_t capture_index);
TEXTMATE_REGEX_API const char *textmate_regex_last_error(void) TEXTMATE_REGEX_RETURNS_BORROWED_UTF8;
TEXTMATE_REGEX_API void textmate_regex_scanner_free(textmate_regex_scanner *scanner);

#endif
