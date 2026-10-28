#define PROCESSKIT_BUILDING 1
#include "processkit.h"

#include <stdlib.h>
#include <string.h>

typedef struct processkit_entry {
    int pid;
    int parent;
    double started;
    char *name;
    char *command_line;
    char *environment;
} processkit_entry;

typedef struct processkit_snapshot {
    processkit_entry *entries;
    int count;
    int capacity;
} processkit_snapshot;

static char empty_text[] = "";

static char *copy_text(const char *text, size_t length) {
    char *result = (char *)malloc(length + 1);
    if (!result)
        return NULL;
    memcpy(result, text, length);
    result[length] = '\0';
    return result;
}

static int append_entry(processkit_snapshot *snapshot, const processkit_entry *entry) {
    if (snapshot->count == snapshot->capacity) {
        int capacity = snapshot->capacity ? snapshot->capacity * 2 : 256;
        processkit_entry *grown =
            (processkit_entry *)realloc(snapshot->entries, (size_t)capacity * sizeof(processkit_entry));
        if (!grown)
            return 0;
        snapshot->entries = grown;
        snapshot->capacity = capacity;
    }
    snapshot->entries[snapshot->count++] = *entry;
    return 1;
}

static void free_snapshot(processkit_snapshot *snapshot) {
    if (!snapshot)
        return;
    for (int index = 0; index < snapshot->count; index++) {
        free(snapshot->entries[index].name);
        free(snapshot->entries[index].command_line);
        free(snapshot->entries[index].environment);
    }
    free(snapshot->entries);
    free(snapshot);
}

static int ascii_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

/* True when `name` equals one entry of the ';'-separated `names` list, ignoring ASCII case; "*" lists all. */
static int name_listed(const char *names, const char *name) {
    if (!names || !*names || !name)
        return 0;
    if (strcmp(names, "*") == 0)
        return 1;
    size_t length = strlen(name);
    const char *cursor = names;
    while (*cursor) {
        const char *end = strchr(cursor, ';');
        size_t span = end ? (size_t)(end - cursor) : strlen(cursor);
        if (span == length) {
            size_t index = 0;
            while (index < span && ascii_lower((unsigned char)cursor[index]) == ascii_lower((unsigned char)name[index]))
                index++;
            if (index == span)
                return 1;
        }
        if (!end)
            break;
        cursor = end + 1;
    }
    return 0;
}

/*
 * The one identity rule. Start times are compared exactly: each platform reads
 * them from the same kernel record the same way every time, so a match means
 * the same process and anything else means the pid now names another one. An
 * unknown time (0) never matches anything.
 */
static int identity_status(double expected, double current) {
    if (current == PROCESSKIT_STARTED_DENIED)
        return PROCESSKIT_ACCESS_DENIED;
    if (current < 0)
        return PROCESSKIT_NOT_FOUND;
    if (!(expected > 0) || !(current > 0))
        return PROCESSKIT_UNKNOWN_START;
    return expected == current ? PROCESSKIT_OK : PROCESSKIT_NOT_FOUND;
}

/* Open snapshots, by handle id. A handle is a small id rather than a pointer, so a stale one is rejected. */

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
static SRWLOCK table_mutex = SRWLOCK_INIT;
static void table_lock(void) { AcquireSRWLockExclusive(&table_mutex); }
static void table_unlock(void) { ReleaseSRWLockExclusive(&table_mutex); }
#else
#include <pthread.h>
static pthread_mutex_t table_mutex = PTHREAD_MUTEX_INITIALIZER;
static void table_lock(void) { pthread_mutex_lock(&table_mutex); }
static void table_unlock(void) { pthread_mutex_unlock(&table_mutex); }
#endif

#define PROCESSKIT_MAX_OPEN_LISTS 32

static struct {
    uint32_t id;
    processkit_snapshot *snapshot;
} open_lists[PROCESSKIT_MAX_OPEN_LISTS];
static uint32_t next_list_id = 1;

/* Stores a snapshot and returns its handle id, or 0 when too many are open. */
static uint32_t publish_snapshot(processkit_snapshot *snapshot) {
    uint32_t id = 0;
    table_lock();
    for (int slot = 0; slot < PROCESSKIT_MAX_OPEN_LISTS; slot++) {
        if (open_lists[slot].id != 0)
            continue;
        id = next_list_id++;
        if (next_list_id == 0)
            next_list_id = 1;
        open_lists[slot].id = id;
        open_lists[slot].snapshot = snapshot;
        break;
    }
    table_unlock();
    return id;
}

/* The snapshot behind a handle. It stays valid until that handle is closed, which only its owner does. */
static processkit_snapshot *find_snapshot(processkit_list list) {
    processkit_snapshot *result = NULL;
    if (list.id == 0)
        return NULL;
    table_lock();
    for (int slot = 0; slot < PROCESSKIT_MAX_OPEN_LISTS; slot++)
        if (open_lists[slot].id == list.id) {
            result = open_lists[slot].snapshot;
            break;
        }
    table_unlock();
    return result;
}

void processkit_list_close(processkit_list list) {
    processkit_snapshot *snapshot = NULL;
    if (list.id == 0)
        return;
    table_lock();
    for (int slot = 0; slot < PROCESSKIT_MAX_OPEN_LISTS; slot++)
        if (open_lists[slot].id == list.id) {
            snapshot = open_lists[slot].snapshot;
            open_lists[slot].id = 0;
            open_lists[slot].snapshot = NULL;
            break;
        }
    table_unlock();
    free_snapshot(snapshot);
}

static processkit_snapshot *new_snapshot(void) {
    return (processkit_snapshot *)calloc(1, sizeof(processkit_snapshot));
}

/* Publishes a finished snapshot through `out_list`, or frees it when the table is full. */
static int finish_open(processkit_snapshot *snapshot, processkit_list *out_list) {
    uint32_t id = publish_snapshot(snapshot);
    if (id == 0) {
        free_snapshot(snapshot);
        return PROCESSKIT_FAILED;
    }
    out_list->id = id;
    return PROCESSKIT_OK;
}

static processkit_entry *entry_at(processkit_list list, int index) {
    processkit_snapshot *snapshot = find_snapshot(list);
    if (!snapshot || index < 0 || index >= snapshot->count)
        return NULL;
    return &snapshot->entries[index];
}

int processkit_list_count(processkit_list list) {
    processkit_snapshot *snapshot = find_snapshot(list);
    return snapshot ? snapshot->count : 0;
}

int processkit_list_pid(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->pid : 0;
}

int processkit_list_parent(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->parent : 0;
}

double processkit_list_started(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->started : 0;
}

const char *processkit_list_name(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry && entry->name ? entry->name : empty_text;
}

const char *processkit_list_command_line(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry && entry->command_line ? entry->command_line : empty_text;
}

const char *processkit_list_environment(processkit_list list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry && entry->environment ? entry->environment : empty_text;
}

/*
 * Appends "NAME=value\n" to `out` when NAME is in the ';'-separated `variables`
 * list. Names compare without case on Windows, where the environment does too.
 */
static void keep_variable(const char *variables, const char *pair, size_t length, char **out, size_t *out_length, int fold_case) {
    const char *equals = memchr(pair, '=', length);
    if (!equals || equals == pair)
        return;
    size_t name_length = (size_t)(equals - pair);
    const char *cursor = variables;
    int wanted = 0;
    while (*cursor && !wanted) {
        const char *end = strchr(cursor, ';');
        size_t span = end ? (size_t)(end - cursor) : strlen(cursor);
        if (span == name_length) {
            size_t index = 0;
            while (index < span && (fold_case ? ascii_lower((unsigned char)cursor[index]) == ascii_lower((unsigned char)pair[index])
                                              : cursor[index] == pair[index]))
                index++;
            wanted = index == span;
        }
        if (!end)
            break;
        cursor = end + 1;
    }
    if (!wanted)
        return;
    char *grown = (char *)realloc(*out, *out_length + length + 2);
    if (!grown)
        return;
    memcpy(grown + *out_length, pair, length);
    *out_length += length;
    grown[(*out_length)++] = '\n';
    grown[*out_length] = '\0';
    *out = grown;
}

int processkit_identify(int pid, double started) { return identity_status(started, processkit_started(pid)); }

#if defined(_WIN32)

#include <tlhelp32.h>

typedef LONG(NTAPI *query_information_fn)(HANDLE, ULONG, PVOID, ULONG, PULONG);

typedef struct processkit_unicode_string {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR Buffer;
} processkit_unicode_string;

/* ProcessCommandLineInformation, available since Windows 8.1. */
#define PROCESSKIT_COMMAND_LINE_CLASS 60

static char *utf8_from_wide(const wchar_t *text, int length) {
    int size = WideCharToMultiByte(CP_UTF8, 0, text, length, NULL, 0, NULL, NULL);
    if (size <= 0)
        return copy_text("", 0);
    char *result = (char *)malloc((size_t)size + 1);
    if (!result)
        return NULL;
    WideCharToMultiByte(CP_UTF8, 0, text, length, result, size, NULL, NULL);
    result[size] = '\0';
    return result;
}

static double filetime_ms(FILETIME time) {
    ULARGE_INTEGER value;
    value.LowPart = time.dwLowDateTime;
    value.HighPart = time.dwHighDateTime;
    /* 100 ns ticks since 1601 -> ms since 1970. */
    return (double)((value.QuadPart - 116444736000000000ULL) / 10000ULL);
}

static double handle_started(HANDLE process) {
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user))
        return 0;
    return filetime_ms(created);
}

static int handle_running(HANDLE process) {
    DWORD code = 0;
    return GetExitCodeProcess(process, &code) && code == STILL_ACTIVE;
}

static query_information_fn command_line_query(void) {
    static query_information_fn query = NULL;
    if (!query) {
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (ntdll)
            query = (query_information_fn)(void *)GetProcAddress(ntdll, "NtQueryInformationProcess");
    }
    return query;
}

static char *read_command_line(HANDLE process) {
    query_information_fn query = command_line_query();
    if (!query)
        return NULL;
    ULONG size = 0;
    query(process, PROCESSKIT_COMMAND_LINE_CLASS, NULL, 0, &size);
    if (size < sizeof(processkit_unicode_string) || size > (1u << 20))
        return NULL;
    processkit_unicode_string *text = (processkit_unicode_string *)malloc(size);
    if (!text)
        return NULL;
    char *result = NULL;
    if (query(process, PROCESSKIT_COMMAND_LINE_CLASS, text, size, &size) >= 0 && text->Buffer)
        result = utf8_from_wide(text->Buffer, (int)(text->Length / sizeof(wchar_t)));
    free(text);
    return result;
}

typedef struct processkit_basic_information {
    PVOID reserved1;
    PVOID peb;
    PVOID reserved2[2];
    ULONG_PTR pid;
    PVOID reserved3;
} processkit_basic_information;

/* Offsets in a 64-bit process: PEB.ProcessParameters, then RTL_USER_PROCESS_PARAMETERS.Environment and .EnvironmentSize. */
#define PROCESSKIT_PEB_PROCESS_PARAMETERS 0x20
#define PROCESSKIT_PARAMETERS_ENVIRONMENT 0x80
#define PROCESSKIT_PARAMETERS_ENVIRONMENT_SIZE 0x3F0
/* Read when EnvironmentSize is missing or implausible; larger blocks are never read. */
#define PROCESSKIT_ENVIRONMENT_FALLBACK_BYTES 65536
#define PROCESSKIT_ENVIRONMENT_MAX_BYTES (1u << 20)

/*
 * Reads `size` bytes at `address`: the exact size first, then halving when the end of
 * the block is not mapped, down to one wide character.
 */
static SIZE_T read_remote(HANDLE process, const char *address, char *buffer, SIZE_T size) {
    while (size >= sizeof(wchar_t)) {
        SIZE_T read = 0;
        if (ReadProcessMemory(process, address, buffer, size, &read) && read > 0)
            return read;
        size /= 2;
    }
    return 0;
}

/*
 * The length in characters of a well-formed environment block within `count`
 * characters: pairs ending in a double NUL (a lone NUL for an empty block). Returns
 * 0 when there is none, as when the read caught the block while the process changed it.
 */
static size_t environment_block_length(const wchar_t *text, size_t count) {
    if (count >= 1 && text[0] == L'\0')
        return 1;
    for (size_t index = 1; index < count; index++)
        if (text[index] == L'\0' && text[index - 1] == L'\0')
            return index + 1;
    return 0;
}

/*
 * The requested variables of a 64-bit process's environment block, read from its PEB
 * (see the offsets above). Needs PROCESS_VM_READ. Returns NULL (unreadable) for a block
 * that is not well formed. A 32-bit processkit does not read environments: it cannot
 * follow a 64-bit process's PEB, so every process reads as unreadable there, and suit,
 * which adopts only processes whose environment it read, adopts nothing.
 */
static char *read_environment(HANDLE process, const char *variables) {
#if defined(_WIN64)
    if (!variables || !*variables)
        return NULL;
    query_information_fn query = command_line_query();
    processkit_basic_information basic;
    ULONG size = 0;
    if (!query || query(process, 0, &basic, sizeof(basic), &size) < 0 || !basic.peb)
        return NULL;
    char *parameters = NULL, *block = NULL;
    SIZE_T block_size = 0;
    if (!ReadProcessMemory(process, (char *)basic.peb + PROCESSKIT_PEB_PROCESS_PARAMETERS, &parameters, sizeof(parameters), NULL) ||
        !parameters)
        return NULL;
    if (!ReadProcessMemory(process, parameters + PROCESSKIT_PARAMETERS_ENVIRONMENT, &block, sizeof(block), NULL) || !block)
        return NULL;
    if (!ReadProcessMemory(process, parameters + PROCESSKIT_PARAMETERS_ENVIRONMENT_SIZE, &block_size, sizeof(block_size), NULL) ||
        block_size == 0 || block_size > PROCESSKIT_ENVIRONMENT_MAX_BYTES)
        block_size = PROCESSKIT_ENVIRONMENT_FALLBACK_BYTES;
    wchar_t *text = (wchar_t *)malloc(block_size + 2 * sizeof(wchar_t));
    if (!text)
        return NULL;
    SIZE_T read = read_remote(process, block, (char *)text, block_size);
    size_t count = environment_block_length(text, read / sizeof(wchar_t));
    if (count == 0) {
        free(text);
        return NULL;
    }
    char *result = NULL;
    size_t result_length = 0;
    size_t index = 0;
    while (index < count && text[index] != L'\0') {
        size_t length = wcsnlen(text + index, count - index);
        char *pair = utf8_from_wide(text + index, (int)length);
        if (pair) {
            keep_variable(variables, pair, strlen(pair), &result, &result_length, 1);
            free(pair);
        }
        index += length + 1;
    }
    free(text);
    return result;
#else
    /* 32-bit: environments are not read (see above). */
    (void)process;
    (void)variables;
    return NULL;
#endif
}

int processkit_list_open(const char *names, const char *variables, processkit_list *out_list) {
    if (!out_list)
        return PROCESSKIT_FAILED;
    out_list->id = 0;
    HANDLE system = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (system == INVALID_HANDLE_VALUE)
        return PROCESSKIT_FAILED;
    processkit_snapshot *snapshot = new_snapshot();
    if (!snapshot) {
        CloseHandle(system);
        return PROCESSKIT_FAILED;
    }
    PROCESSENTRY32W process;
    process.dwSize = sizeof(process);
    for (BOOL more = Process32FirstW(system, &process); more; more = Process32NextW(system, &process)) {
        if (process.th32ProcessID == 0)
            continue;
        processkit_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.pid = (int)process.th32ProcessID;
        entry.parent = (int)process.th32ParentProcessID;
        entry.name = utf8_from_wide(process.szExeFile, (int)wcslen(process.szExeFile));
        int listed = name_listed(names, entry.name);
        HANDLE handle = NULL;
        if (listed && variables && *variables)
            handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, FALSE, process.th32ProcessID);
        if (!handle)
            handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process.th32ProcessID);
        if (handle) {
            entry.started = handle_started(handle);
            if (listed) {
                entry.command_line = read_command_line(handle);
                entry.environment = read_environment(handle, variables);
            }
            CloseHandle(handle);
        }
        if (!append_entry(snapshot, &entry)) {
            free(entry.name);
            free(entry.command_line);
            free(entry.environment);
            free_snapshot(snapshot);
            CloseHandle(system);
            return PROCESSKIT_FAILED;
        }
    }
    CloseHandle(system);
    return finish_open(snapshot, out_list);
}

/*
 * Opens `pid` with `access` when processkit's identity rule accepts it. The
 * open handle pins the process, so its pid cannot be reused while it is held.
 */
static int open_identified(int pid, double started, DWORD access, HANDLE *out_handle) {
    *out_handle = NULL;
    if (pid <= 0)
        return PROCESSKIT_NOT_FOUND;
    if (!(started > 0))
        return PROCESSKIT_UNKNOWN_START;
    HANDLE handle = OpenProcess(access | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!handle)
        return GetLastError() == ERROR_ACCESS_DENIED ? PROCESSKIT_ACCESS_DENIED : PROCESSKIT_NOT_FOUND;
    int status = identity_status(started, handle_running(handle) ? handle_started(handle) : -1);
    if (status != PROCESSKIT_OK) {
        CloseHandle(handle);
        return status;
    }
    *out_handle = handle;
    return PROCESSKIT_OK;
}

double processkit_started(int pid) {
    if (pid <= 0)
        return -1;
    HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!handle)
        return GetLastError() == ERROR_ACCESS_DENIED ? PROCESSKIT_STARTED_DENIED : -1;
    double started = handle_running(handle) ? handle_started(handle) : -1;
    CloseHandle(handle);
    return started;
}

int processkit_terminate(int pid, double started) {
    HANDLE handle = NULL;
    int status = open_identified(pid, started, PROCESS_TERMINATE, &handle);
    if (status != PROCESSKIT_OK)
        return status;
    BOOL ended = TerminateProcess(handle, 1);
    CloseHandle(handle);
    return ended ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

typedef struct processkit_close_request {
    DWORD pid;
    int posted;
} processkit_close_request;

static BOOL CALLBACK close_window(HWND window, LPARAM parameter) {
    processkit_close_request *request = (processkit_close_request *)parameter;
    DWORD owner = 0;
    GetWindowThreadProcessId(window, &owner);
    if (owner == request->pid && IsWindowVisible(window) && !GetWindow(window, GW_OWNER)) {
        if (PostMessageW(window, WM_CLOSE, 0, 0))
            request->posted++;
    }
    return TRUE;
}

int processkit_request_close(int pid, double started) {
    HANDLE handle = NULL;
    int status = open_identified(pid, started, 0, &handle);
    if (status != PROCESSKIT_OK)
        return status;
    // The handle is held while posting, so the windows found belong to this process and not a pid reuser.
    processkit_close_request request = {(DWORD)pid, 0};
    EnumWindows(close_window, (LPARAM)&request);
    CloseHandle(handle);
    return request.posted > 0 ? PROCESSKIT_OK : PROCESSKIT_NOT_FOUND;
}

int processkit_current_pid(void) { return (int)GetCurrentProcessId(); }

#elif defined(__linux__)

#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

static double boot_seconds(void) {
    static double cached = -1;
    if (cached >= 0)
        return cached;
    FILE *file = fopen("/proc/stat", "r");
    if (!file)
        return 0;
    char line[512];
    cached = 0;
    while (fgets(line, sizeof(line), file)) {
        if (strncmp(line, "btime ", 6) == 0) {
            cached = atof(line + 6);
            break;
        }
    }
    fclose(file);
    return cached;
}

/* Reads the parent pid and start time from /proc/<pid>/stat. Returns 0 when the process is gone. */
static int read_stat(int pid, int *out_parent, double *out_started) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE *file = fopen(path, "r");
    if (!file)
        return 0;
    char buffer[2048];
    size_t length = fread(buffer, 1, sizeof(buffer) - 1, file);
    fclose(file);
    buffer[length] = '\0';
    /* The command name may contain spaces and parentheses; fields resume after the last ')'. */
    char *cursor = strrchr(buffer, ')');
    if (!cursor)
        return 0;
    cursor += 2;
    char state = 0;
    int parent = 0;
    unsigned long long start_ticks = 0;
    int field = 3;
    char *token = strtok(cursor, " ");
    while (token) {
        if (field == 3)
            state = token[0];
        else if (field == 4)
            parent = atoi(token);
        else if (field == 22) {
            start_ticks = strtoull(token, NULL, 10);
            break;
        }
        field++;
        token = strtok(NULL, " ");
    }
    if (state == 'Z' || state == 'X')
        return 0;
    long ticks = sysconf(_SC_CLK_TCK);
    double boot = boot_seconds();
    if (out_parent)
        *out_parent = parent;
    /* The boot time is cached, so one process computes the same start time on every read. */
    if (out_started)
        *out_started = ticks > 0 && boot > 0 ? (boot + (double)start_ticks / (double)ticks) * 1000.0 : 0;
    return 1;
}

static char *read_file_text(const char *path, int nul_to_space) {
    FILE *file = fopen(path, "r");
    if (!file)
        return NULL;
    size_t capacity = 4096, length = 0;
    char *text = (char *)malloc(capacity);
    while (text) {
        size_t read = fread(text + length, 1, capacity - length - 1, file);
        length += read;
        if (read == 0 || length + 1 < capacity)
            break;
        if (capacity >= (1u << 20))
            break;
        capacity *= 2;
        char *grown = (char *)realloc(text, capacity);
        if (!grown) {
            free(text);
            text = NULL;
        } else
            text = grown;
    }
    fclose(file);
    if (!text)
        return NULL;
    while (length > 0 && (text[length - 1] == '\0' || text[length - 1] == '\n'))
        length--;
    if (nul_to_space)
        for (size_t index = 0; index < length; index++)
            if (text[index] == '\0')
                text[index] = ' ';
    text[length] = '\0';
    return text;
}

/* The requested variables from /proc/<pid>/environ: the environment the process was started with. */
static char *read_environment(int pid, const char *variables) {
    if (!variables || !*variables)
        return NULL;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/environ", pid);
    FILE *file = fopen(path, "r");
    if (!file)
        return NULL;
    /* procfs reports no size, so the block grows in chunks, up to 1 MiB. */
    size_t capacity = 4096, length = 0;
    char *block = (char *)malloc(capacity);
    while (block) {
        length += fread(block + length, 1, capacity - 1 - length, file);
        if (length < capacity - 1 || capacity >= (1u << 20))
            break;
        char *grown = (char *)realloc(block, capacity * 2);
        if (!grown) {
            free(block);
            block = NULL;
            break;
        }
        block = grown;
        capacity *= 2;
    }
    fclose(file);
    if (!block)
        return NULL;
    block[length] = '\0';
    char *result = NULL;
    size_t result_length = 0, index = 0;
    while (index < length) {
        size_t pair = strlen(block + index);
        keep_variable(variables, block + index, pair, &result, &result_length, 0);
        index += pair + 1;
    }
    free(block);
    return result;
}

int processkit_list_open(const char *names, const char *variables, processkit_list *out_list) {
    if (!out_list)
        return PROCESSKIT_FAILED;
    out_list->id = 0;
    DIR *directory = opendir("/proc");
    if (!directory)
        return PROCESSKIT_FAILED;
    processkit_snapshot *snapshot = new_snapshot();
    if (!snapshot) {
        closedir(directory);
        return PROCESSKIT_FAILED;
    }
    struct dirent *item;
    while ((item = readdir(directory))) {
        int pid = atoi(item->d_name);
        if (pid <= 0)
            continue;
        processkit_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.pid = pid;
        if (!read_stat(pid, &entry.parent, &entry.started))
            continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/comm", pid);
        entry.name = read_file_text(path, 0);
        if (name_listed(names, entry.name)) {
            snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
            entry.command_line = read_file_text(path, 1);
            entry.environment = read_environment(pid, variables);
        }
        if (!append_entry(snapshot, &entry)) {
            free(entry.name);
            free(entry.command_line);
            free(entry.environment);
            free_snapshot(snapshot);
            closedir(directory);
            return PROCESSKIT_FAILED;
        }
    }
    closedir(directory);
    return finish_open(snapshot, out_list);
}

double processkit_started(int pid) {
    double started = 0;
    return pid > 0 && read_stat(pid, NULL, &started) ? started : -1;
}

/*
 * Linux has no handle to hold across the check and the signal, so a pid freed
 * and reused in between could still be hit. pids are handed out in sequence
 * and wrap only after pid_max allocations, so that window is very small.
 */
static int signal_identified(int pid, double started, int signal_number) {
    int status = processkit_identify(pid, started);
    if (status != PROCESSKIT_OK)
        return status;
    return kill((pid_t)pid, signal_number) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_terminate(int pid, double started) { return signal_identified(pid, started, SIGKILL); }

int processkit_request_close(int pid, double started) { return signal_identified(pid, started, SIGTERM); }

int processkit_current_pid(void) { return (int)getpid(); }

#elif defined(__APPLE__)

#include <libproc.h>
#include <signal.h>
#include <sys/proc_info.h>
#include <unistd.h>

/* Listing needs proc_listallpids; until it is written only direct pid checks work. */
int processkit_list_open(const char *names, const char *variables, processkit_list *out_list) {
    (void)names;
    (void)variables;
    if (out_list)
        out_list->id = 0;
    return PROCESSKIT_UNSUPPORTED;
}

double processkit_started(int pid) {
    if (pid <= 0)
        return -1;
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, PROC_PIDTBSDINFO_SIZE) != PROC_PIDTBSDINFO_SIZE)
        return kill((pid_t)pid, 0) == 0 ? 0 : -1;
    return (double)info.pbi_start_tvsec * 1000.0 + (double)(info.pbi_start_tvusec / 1000);
}

static int signal_identified(int pid, double started, int signal_number) {
    int status = processkit_identify(pid, started);
    if (status != PROCESSKIT_OK)
        return status;
    return kill((pid_t)pid, signal_number) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_terminate(int pid, double started) { return signal_identified(pid, started, SIGKILL); }

int processkit_request_close(int pid, double started) { return signal_identified(pid, started, SIGTERM); }

int processkit_current_pid(void) { return (int)getpid(); }

#else

#include <signal.h>
#include <unistd.h>

int processkit_list_open(const char *names, const char *variables, processkit_list *out_list) {
    (void)names;
    (void)variables;
    if (out_list)
        out_list->id = 0;
    return PROCESSKIT_UNSUPPORTED;
}

/* Start times are unknown here, so processkit never acts on a process on this platform. */
double processkit_started(int pid) { return pid > 0 && kill((pid_t)pid, 0) == 0 ? 0 : -1; }

int processkit_terminate(int pid, double started) { return processkit_identify(pid, started); }

int processkit_request_close(int pid, double started) { return processkit_identify(pid, started); }

int processkit_current_pid(void) { return (int)getpid(); }

#endif
