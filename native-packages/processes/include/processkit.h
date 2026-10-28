#ifndef PROCESSKIT_H
#define PROCESSKIT_H

#include <stdint.h>

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
#  define PROCESSKIT_OWNED __attribute__((annotate("hxi:owned")))
#  define PROCESSKIT_HANDLE __attribute__((annotate("hxi:handle")))
#  define PROCESSKIT_HANDLE_DESTROY(symbol) __attribute__((annotate("hxi:handle_destroy")))
#  define PROCESSKIT_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#else
#  define PROCESSKIT_UTF8
#  define PROCESSKIT_OUT
#  define PROCESSKIT_OWNED
#  define PROCESSKIT_HANDLE
#  define PROCESSKIT_HANDLE_DESTROY(symbol)
#  define PROCESSKIT_RETURNS_BORROWED_UTF8
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Same-user process inspection for the suit daemon. A process is identified by
 * its pid plus its start time (milliseconds since the Unix epoch), so a reused
 * pid is never mistaken for the process that used to own it. Calls that act on
 * a process take that pair and do nothing unless the start time matches. A
 * process whose start time is unknown is never acted on.
 *
 * Start times match exactly: every one comes from processkit_list_open or
 * processkit_started, which compute it the same way on each call.
 */

/** A process snapshot. The caller owns it and releases it with processkit_list_close. */
typedef struct processkit_list { uint32_t id; } processkit_list
    PROCESSKIT_HANDLE PROCESSKIT_HANDLE_DESTROY(processkit_list_close);

enum {
    PROCESSKIT_OK = 0,
    PROCESSKIT_NOT_FOUND = 1, /* not running, or the pid now belongs to a newer process */
    PROCESSKIT_ACCESS_DENIED = 2,
    PROCESSKIT_UNSUPPORTED = 3,
    PROCESSKIT_FAILED = 4,
    PROCESSKIT_UNKNOWN_START = 5 /* no start time to check the pid against, so it is left alone */
};

/** What processkit_started returns for a running process this user may not open. */
#define PROCESSKIT_STARTED_DENIED (-2.0)

/**
 * Snapshots running processes. Command lines are read only for processes whose
 * executable base name is in `names`, a ';'-separated, case-insensitive list
 * (for example "hl.exe;exosuit.exe"). An empty list reads none; "*" reads all.
 * For the same processes, the environment variables named in the ';'-separated
 * `variables` list are read (none when it is empty).
 */
PROCESSKIT_API int processkit_list_open(const char *names PROCESSKIT_UTF8, const char *variables PROCESSKIT_UTF8,
                                        processkit_list *out_list PROCESSKIT_OUT PROCESSKIT_OWNED);
PROCESSKIT_API int processkit_list_count(processkit_list list);
PROCESSKIT_API int processkit_list_pid(processkit_list list, int index);
PROCESSKIT_API int processkit_list_parent(processkit_list list, int index);
/** Start time in milliseconds since the Unix epoch; 0 when it could not be read. */
PROCESSKIT_API double processkit_list_started(processkit_list list, int index);
/** Executable base name. Borrowed until processkit_list_close. */
PROCESSKIT_API const char *processkit_list_name(processkit_list list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
/** Command line, or empty when it was not or could not be read. Borrowed until processkit_list_close. */
PROCESSKIT_API const char *processkit_list_command_line(processkit_list list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
/**
 * Full executable path as the OS reports it (not the command line), read for the same
 * processes as command lines; empty when not read. Borrowed until processkit_list_close.
 */
PROCESSKIT_API const char *processkit_list_path(processkit_list list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
/**
 * The requested environment variables the process has, as "NAME=value" lines
 * joined by '\n'; empty when none was set or the environment could not be read.
 * Borrowed until processkit_list_close.
 */
PROCESSKIT_API const char *processkit_list_environment(processkit_list list, int index) PROCESSKIT_RETURNS_BORROWED_UTF8;
PROCESSKIT_API void processkit_list_close(processkit_list list);

/**
 * Start time of a running process in milliseconds since the Unix epoch, 0 when
 * unknown, -1 when it is not running, or PROCESSKIT_STARTED_DENIED (-2) when it
 * runs but this user may not open it.
 */
PROCESSKIT_API double processkit_started(int pid);
/**
 * PROCESSKIT_OK when `pid` is running and is the process that started at
 * `started`; PROCESSKIT_NOT_FOUND when it is gone or the pid was reused;
 * PROCESSKIT_ACCESS_DENIED when it runs but may not be opened;
 * PROCESSKIT_UNKNOWN_START when either start time is unknown.
 */
PROCESSKIT_API int processkit_identify(int pid, double started);
/** Forcibly ends one process (not its children) if processkit_identify accepts it. */
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
