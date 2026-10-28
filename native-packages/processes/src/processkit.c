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
} processkit_entry;

struct processkit_list {
    processkit_entry *entries;
    int count;
    int capacity;
};

static char empty_text[] = "";

static char *copy_text(const char *text, size_t length) {
    char *result = (char *)malloc(length + 1);
    if (!result)
        return NULL;
    memcpy(result, text, length);
    result[length] = '\0';
    return result;
}

static int append_entry(processkit_list *list, const processkit_entry *entry) {
    if (list->count == list->capacity) {
        int capacity = list->capacity ? list->capacity * 2 : 256;
        processkit_entry *grown =
            (processkit_entry *)realloc(list->entries, (size_t)capacity * sizeof(processkit_entry));
        if (!grown)
            return 0;
        list->entries = grown;
        list->capacity = capacity;
    }
    list->entries[list->count++] = *entry;
    return 1;
}

static int ascii_lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

/* True when `name` equals one entry of the ';'-separated `names` list, ignoring ASCII case. */
static int name_listed(const char *names, const char *name) {
    if (!names || !*names)
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

static processkit_entry *entry_at(processkit_list *list, int index) {
    if (!list || index < 0 || index >= list->count)
        return NULL;
    return &list->entries[index];
}

int processkit_list_count(processkit_list *list) { return list ? list->count : 0; }

int processkit_list_pid(processkit_list *list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->pid : 0;
}

int processkit_list_parent(processkit_list *list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->parent : 0;
}

double processkit_list_started(processkit_list *list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry ? entry->started : 0;
}

const char *processkit_list_name(processkit_list *list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry && entry->name ? entry->name : empty_text;
}

const char *processkit_list_command_line(processkit_list *list, int index) {
    processkit_entry *entry = entry_at(list, index);
    return entry && entry->command_line ? entry->command_line : empty_text;
}

void processkit_list_close(processkit_list *list) {
    if (!list)
        return;
    for (int index = 0; index < list->count; index++) {
        free(list->entries[index].name);
        free(list->entries[index].command_line);
    }
    free(list->entries);
    free(list);
}

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
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

static char *read_command_line(HANDLE process) {
    static query_information_fn query = NULL;
    if (!query) {
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (ntdll)
            query = (query_information_fn)(void *)GetProcAddress(ntdll, "NtQueryInformationProcess");
        if (!query)
            return NULL;
    }
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

int processkit_list_open(const char *names, processkit_list **out_list) {
    if (!out_list)
        return PROCESSKIT_FAILED;
    *out_list = NULL;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE)
        return PROCESSKIT_FAILED;
    processkit_list *list = (processkit_list *)calloc(1, sizeof(processkit_list));
    if (!list) {
        CloseHandle(snapshot);
        return PROCESSKIT_FAILED;
    }
    PROCESSENTRY32W process;
    process.dwSize = sizeof(process);
    for (BOOL more = Process32FirstW(snapshot, &process); more; more = Process32NextW(snapshot, &process)) {
        if (process.th32ProcessID == 0)
            continue;
        processkit_entry entry;
        memset(&entry, 0, sizeof(entry));
        entry.pid = (int)process.th32ProcessID;
        entry.parent = (int)process.th32ParentProcessID;
        entry.name = utf8_from_wide(process.szExeFile, (int)wcslen(process.szExeFile));
        HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process.th32ProcessID);
        if (handle) {
            entry.started = handle_started(handle);
            if (entry.name && name_listed(names, entry.name))
                entry.command_line = read_command_line(handle);
            CloseHandle(handle);
        }
        if (!append_entry(list, &entry)) {
            free(entry.name);
            free(entry.command_line);
            processkit_list_close(list);
            CloseHandle(snapshot);
            return PROCESSKIT_FAILED;
        }
    }
    CloseHandle(snapshot);
    *out_list = list;
    return PROCESSKIT_OK;
}

static HANDLE open_matching(int pid, double started, DWORD access) {
    if (pid <= 0)
        return NULL;
    HANDLE handle = OpenProcess(access | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!handle)
        return NULL;
    if (!handle_running(handle) || (started > 0 && handle_started(handle) != started)) {
        CloseHandle(handle);
        return NULL;
    }
    return handle;
}

double processkit_started(int pid) {
    HANDLE handle = open_matching(pid, 0, 0);
    if (!handle)
        return -1;
    double started = handle_started(handle);
    CloseHandle(handle);
    return started;
}

int processkit_terminate(int pid, double started) {
    HANDLE handle = open_matching(pid, started, PROCESS_TERMINATE);
    if (!handle) {
        if (GetLastError() == ERROR_ACCESS_DENIED)
            return PROCESSKIT_ACCESS_DENIED;
        return PROCESSKIT_NOT_FOUND;
    }
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
    HANDLE handle = open_matching(pid, started, 0);
    if (!handle)
        return PROCESSKIT_NOT_FOUND;
    CloseHandle(handle);
    processkit_close_request request = {(DWORD)pid, 0};
    EnumWindows(close_window, (LPARAM)&request);
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
    if (out_parent)
        *out_parent = parent;
    if (out_started)
        *out_started = ticks > 0 ? (boot_seconds() + (double)start_ticks / (double)ticks) * 1000.0 : 0;
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

int processkit_list_open(const char *names, processkit_list **out_list) {
    if (!out_list)
        return PROCESSKIT_FAILED;
    *out_list = NULL;
    DIR *directory = opendir("/proc");
    if (!directory)
        return PROCESSKIT_FAILED;
    processkit_list *list = (processkit_list *)calloc(1, sizeof(processkit_list));
    if (!list) {
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
        if (entry.name && name_listed(names, entry.name)) {
            snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
            entry.command_line = read_file_text(path, 1);
        }
        if (!append_entry(list, &entry)) {
            free(entry.name);
            free(entry.command_line);
            processkit_list_close(list);
            closedir(directory);
            return PROCESSKIT_FAILED;
        }
    }
    closedir(directory);
    *out_list = list;
    return PROCESSKIT_OK;
}

static int matches(int pid, double started) {
    double current = 0;
    if (pid <= 0 || !read_stat(pid, NULL, &current))
        return 0;
    /* /proc start times have clock-tick resolution; allow for rounding. */
    return started <= 0 || (current - started < 20 && started - current < 20);
}

double processkit_started(int pid) {
    double started = 0;
    return pid > 0 && read_stat(pid, NULL, &started) ? started : -1;
}

int processkit_terminate(int pid, double started) {
    if (!matches(pid, started))
        return PROCESSKIT_NOT_FOUND;
    return kill((pid_t)pid, SIGKILL) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_request_close(int pid, double started) {
    if (!matches(pid, started))
        return PROCESSKIT_NOT_FOUND;
    return kill((pid_t)pid, SIGTERM) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_current_pid(void) { return (int)getpid(); }

#else

#include <signal.h>
#include <unistd.h>

/* Listing needs libproc on macOS; until then only direct pid checks work. */
int processkit_list_open(const char *names, processkit_list **out_list) {
    (void)names;
    if (out_list)
        *out_list = NULL;
    return PROCESSKIT_UNSUPPORTED;
}

double processkit_started(int pid) { return pid > 0 && kill((pid_t)pid, 0) == 0 ? 0 : -1; }

int processkit_terminate(int pid, double started) {
    (void)started;
    if (processkit_started(pid) < 0)
        return PROCESSKIT_NOT_FOUND;
    return kill((pid_t)pid, SIGKILL) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_request_close(int pid, double started) {
    (void)started;
    if (processkit_started(pid) < 0)
        return PROCESSKIT_NOT_FOUND;
    return kill((pid_t)pid, SIGTERM) == 0 ? PROCESSKIT_OK : PROCESSKIT_ACCESS_DENIED;
}

int processkit_current_pid(void) { return (int)getpid(); }

#endif
