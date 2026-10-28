#ifndef PROCESSKIT_H
#define PROCESSKIT_H

#if defined(_WIN32)
#  if defined(PROCESSKIT_BUILDING)
#    define PROCESSKIT_API __declspec(dllexport)
#  else
#    define PROCESSKIT_API __declspec(dllimport)
#  endif
#else
#  define PROCESSKIT_API __attribute__((visibility("default")))
#endif

#if defined(__clang__)
#  define PROCESSKIT_UTF8 __attribute__((annotate("hxi:utf8")))
#  define PROCESSKIT_OUT __attribute__((annotate("hxi:out")))
#  define PROCESSKIT_BORROWED __attribute__((annotate("hxi:borrowed")))
#  define PROCESSKIT_OPAQUE __attribute__((annotate("hxi:opaque")))
#  define PROCESSKIT_NULLABLE _Nullable
#  define PROCESSKIT_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#else
#  define PROCESSKIT_UTF8
#  define PROCESSKIT_OUT
#  define PROCESSKIT_BORROWED
#  define PROCESSKIT_OPAQUE
#  define PROCESSKIT_NULLABLE
#  define PROCESSKIT_RETURNS_BORROWED_UTF8
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Same-user process inspection for the suit daemon. A process is identified by
 * its pid plus its start time (milliseconds since the Unix epoch), so a reused
 * pid is never mistaken for the process that used to own it. Calls that act on
 * a process take that pair and do nothing when the start time does not match.
 */
typedef struct processkit_list processkit_list PROCESSKIT_OPAQUE;

enum {
    PROCESSKIT_OK = 0,
    PROCESSKIT_NOT_FOUND = 1, /* not running, or the pid now belongs to a newer process */
    PROCESSKIT_ACCESS_DENIED = 2,
    PROCESSKIT_UNSUPPORTED = 3,
    PROCESSKIT_FAILED = 4
};

/**
 * Snapshots running processes. `names` is a ';'-separated, case-insensitive list
 * of executable base names (for example "hl.exe;exosuit.exe"); empty lists all.
 * Command lines are read only for listed processes.
 */
PROCESSKIT_API int processkit_list_open(const char *names PROCESSKIT_UTF8,
                                        processkit_list * PROCESSKIT_NULLABLE *out_list PROCESSKIT_OUT PROCESSKIT_BORROWED);
PROCESSKIT_API int processkit_list_count(processkit_list *list);
PROCESSKIT_API int processkit_list_pid(processkit_list *list, int index);
PROCESSKIT_API int processkit_list_parent(processkit_list *list, int index);
/** Start time in milliseconds since the Unix epoch; 0 when it could not be read. */
PROCESSKIT_API double processkit_list_started(processkit_list *list, int index);
/** Executable base name. Borrowed until processkit_list_close. */
PROCESSKIT_API const char *processkit_list_name(processkit_list *list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
/** Command line, or empty when it could not be read. Borrowed until processkit_list_close. */
PROCESSKIT_API const char *processkit_list_command_line(processkit_list *list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
PROCESSKIT_API void processkit_list_close(processkit_list *list);

/** Start time of a running process in milliseconds since the Unix epoch, or -1 when it is not running. */
PROCESSKIT_API double processkit_started(int pid);
/** Forcibly ends one process (not its children) if its start time still matches. */
PROCESSKIT_API int processkit_terminate(int pid, double started);
/**
 * Asks a process to close gracefully: on Windows, posts WM_CLOSE to its visible
 * top-level windows; elsewhere, sends SIGTERM. Returns PROCESSKIT_NOT_FOUND when
 * nothing could be asked (no such process, or no window to close).
 */
PROCESSKIT_API int processkit_request_close(int pid, double started);
PROCESSKIT_API int processkit_current_pid(void);

#ifdef __cplusplus
}
#endif

#endif
