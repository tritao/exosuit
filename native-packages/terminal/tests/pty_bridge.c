#include "terminalkit.h"
#include <errno.h>
#include <poll.h>
#if defined(__APPLE__)
# include <util.h>
#else
# include <pty.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int contains_row(terminalkit_handle *kit, int row, const char *needle) {
    uint32_t size = 0;
    if (terminalkit_row_text_copy(kit, row, NULL, &size) != 1 || !size)
        return 0;
    char *text = malloc((size_t)size + 1);
    if (!text) return 0;
    uint32_t capacity = size;
    int found = terminalkit_row_text_copy(kit, row, (uint8_t *)text, &capacity) == 0;
    text[size] = 0;
    found = found && strstr(text, needle) != NULL;
    free(text);
    return found;
}

int main(void) {
    struct winsize size = { .ws_row = 4, .ws_col = 20 };
    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) return 1;
    if (child == 0) {
        execl("/bin/sh", "sh", "-c",
            "stty -echo; printf '\\033[31mREADY\\033[0m\\r\\n'; "
            "IFS= read -r line; printf 'GOT:%s\\r\\n' \"$line\"",
            (char *)NULL);
        _exit(127);
    }
    terminalkit_handle *kit = NULL;
    if (!terminalkit_open(20, 4, 8, "xterm-256color", &kit)) {
        kill(child, SIGKILL); waitpid(child, NULL, 0); close(master);
        return 2;
    }
    int sent = 0, received = 0, status = 0;
    for (int attempt = 0; attempt < 100 && !received; ++attempt) {
        struct pollfd fd = { .fd = master, .events = POLLIN };
        if (poll(&fd, 1, 50) <= 0) continue;
        uint8_t bytes[4096];
        ssize_t count = read(master, bytes, sizeof(bytes));
        if (count <= 0) break;
        terminalkit_feed(kit, bytes, (uint64_t)count);
        if (terminalkit_snapshot(kit) < 0) break;
        if (!sent && contains_row(kit, 0, "READY")) {
            const char input[] = "typed\n";
            if (write(master, input, sizeof(input) - 1) != sizeof(input) - 1)
                break;
            sent = 1;
        }
        if (sent && contains_row(kit, 1, "GOT:typed"))
            received = 1;
    }
    if (!received) kill(child, SIGKILL);
    waitpid(child, &status, 0);
    close(master);
    int ok = received && WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
        contains_row(kit, 0, "READY") && contains_row(kit, 1, "GOT:typed");
    terminalkit_close(kit);
    if (!ok) fprintf(stderr, "PTY-to-emulator stream smoke failed\n");
    return ok ? 0 : 3;
}
