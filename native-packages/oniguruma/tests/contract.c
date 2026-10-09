#include "textmate_regex.h"

#include <stdio.h>
#include <string.h>

static int require(int condition, const char *message) {
    if (condition) return 0;
    fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

int main(void) {
    int failures = 0;
    textmate_regex_scanner *scanner = NULL;
    failures += require(textmate_regex_scanner_create(&scanner) == 0, "scanner creation");
    if (scanner == NULL) return 1;

    static const uint8_t identifier[] = "(?<=\\b)([A-Z]\\w*)(?=\\s*\\()";
    static const uint8_t comment[] = "//.*";
    failures += require(textmate_regex_scanner_add(scanner, identifier, sizeof(identifier) - 1) == 0,
        "Oniguruma lookaround and Unicode word class compile");
    failures += require(textmate_regex_scanner_add(scanner, comment, sizeof(comment) - 1) == 0,
        "second ordered pattern compiles");

    static const uint8_t source[] = "λ🙂 Widget(\"x\") // call";
    int match = textmate_regex_scanner_search(scanner, source, sizeof(source) - 1, 0);
    failures += require(match == 0, "earliest match wins across ordered patterns");
    failures += require(textmate_regex_scanner_match_start(scanner) == 7,
        "match start is reported in UTF-8 bytes");
    failures += require(textmate_regex_scanner_match_end(scanner) == 13,
        "match end includes the call lookahead span");
    failures += require(textmate_regex_scanner_capture_count(scanner, 0) == 2,
        "capture count includes group zero");
    failures += require(textmate_regex_scanner_capture_start(scanner, 0, 1) == 7 &&
        textmate_regex_scanner_capture_end(scanner, 0, 1) == 13,
        "capture byte boundaries are preserved");

    match = textmate_regex_scanner_search(scanner, source, sizeof(source) - 1, 13);
    failures += require(match == 1, "later comment pattern is selected");
    failures += require(textmate_regex_scanner_match_start(scanner) == 19,
        "later match offset is correct");
    failures += require(textmate_regex_scanner_match_end(scanner) == (int)sizeof(source) - 1,
        "match reaches the line end");

    textmate_regex_scanner_free(scanner);
    puts(failures == 0 ? "PASS: TextMate Oniguruma contract" : "FAIL: TextMate Oniguruma contract");
    return failures == 0 ? 0 : 1;
}
