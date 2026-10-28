/*
 * processkit's contract: snapshot handles, the identity rule, and that it acts
 * only on a process whose pid and start time both match. The only process it
 * kills is a child this test starts (the test executable rerun with --sleep).
 */
#include "processkit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static int failures = 0;

static void require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

#if defined(_WIN32)
typedef HANDLE child_process;

static int start_child(const char *self, child_process *out_child) {
    (void)self;
    char program[MAX_PATH];
    if (!GetModuleFileNameA(NULL, program, MAX_PATH))
        return 0;
    char command[MAX_PATH + 32];
    snprintf(command, sizeof(command), "\"%s\" --sleep", program);
    STARTUPINFOA startup;
    PROCESS_INFORMATION info;
    memset(&startup, 0, sizeof(startup));
    startup.cb = sizeof(startup);
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &info))
        return 0;
    CloseHandle(info.hThread);
    *out_child = info.hProcess;
    return (int)info.dwProcessId;
}

/* True when the child exited within `seconds`. */
static int child_exited(child_process child, int seconds) {
    return WaitForSingleObject(child, (DWORD)seconds * 1000) == WAIT_OBJECT_0;
}

static void reap_child(child_process child) {
    if (WaitForSingleObject(child, 0) != WAIT_OBJECT_0)
        TerminateProcess(child, 1);
    CloseHandle(child);
}

static void pause_briefly(void) { Sleep(50); }
#else
typedef pid_t child_process;

static int start_child(const char *self, child_process *out_child) {
    (void)self;
    pid_t pid = fork();
    if (pid < 0)
        return 0;
    if (pid == 0) {
        sleep(60);
        _exit(0);
    }
    *out_child = pid;
    return (int)pid;
}

static int child_exited(child_process child, int seconds) {
    for (int tick = 0; tick < seconds * 20; tick++) {
        if (waitpid(child, NULL, WNOHANG) == child)
            return 1;
        usleep(50000);
    }
    return 0;
}

static void reap_child(child_process child) {
    if (waitpid(child, NULL, WNOHANG) != child) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
    }
}

static void pause_briefly(void) { usleep(50000); }
#endif

static void test_snapshot(int self) {
    processkit_list list = {0};
    int status = processkit_list_open("*", &list);
    if (status == PROCESSKIT_UNSUPPORTED) {
        printf("SKIP: process listing is not implemented on this platform\n");
        return;
    }
    require(status == PROCESSKIT_OK && list.id != 0, "a snapshot opens");
    int count = processkit_list_count(list), found = -1;
    require(count > 0, "a snapshot lists processes");
    for (int index = 0; index < count; index++)
        if (processkit_list_pid(list, index) == self)
            found = index;
    require(found >= 0, "a snapshot lists this process");
    if (found >= 0) {
        require(processkit_list_started(list, found) == processkit_started(self),
                "listing and processkit_started give the same start time");
        require(strlen(processkit_list_name(list, found)) > 0, "this process has a name");
        require(strstr(processkit_list_command_line(list, found), "processkit_contract") != NULL,
                "\"*\" reads every command line");
    }
    require(processkit_list_count(list) == count, "a snapshot does not change");
    processkit_list_close(list);
    require(processkit_list_count(list) == 0 && processkit_list_pid(list, 0) == 0, "a closed handle reads as empty");
    require(strcmp(processkit_list_name(list, 0), "") == 0, "a closed handle has no names");
    processkit_list_close(list); /* closing twice is harmless */

    require(processkit_list_open("", &list) == PROCESSKIT_OK, "a snapshot without command lines opens");
    for (int index = 0; index < processkit_list_count(list); index++)
        if (processkit_list_pid(list, index) == self)
            require(strcmp(processkit_list_command_line(list, index), "") == 0, "an empty name list reads no command lines");
    processkit_list_close(list);

    /* Handles are a bounded table: opening more than it holds fails cleanly, and closing frees slots. */
    processkit_list lists[40];
    int opened = 0;
    for (int index = 0; index < 40; index++) {
        lists[index].id = 0;
        if (processkit_list_open("", &lists[index]) == PROCESSKIT_OK)
            opened++;
    }
    require(opened > 0 && opened < 40, "the handle table is bounded");
    for (int index = 0; index < 40; index++)
        processkit_list_close(lists[index]);
    require(processkit_list_open("", &list) == PROCESSKIT_OK, "closed handles free their slots");
    processkit_list_close(list);
    require(processkit_list_open("", NULL) == PROCESSKIT_FAILED, "a missing out slot is an error");
}

static void test_identity(int self) {
    double started = processkit_started(self);
    require(started > 0, "this process has a start time");
    require(processkit_identify(self, started) == PROCESSKIT_OK, "the same pid and start time identify a process");
    require(processkit_identify(self, started + 1) == PROCESSKIT_NOT_FOUND, "another start time is another process");
    require(processkit_identify(self, 0) == PROCESSKIT_UNKNOWN_START, "an unknown start time identifies nothing");
    require(processkit_identify(-1, started) == PROCESSKIT_NOT_FOUND, "an invalid pid is not found");
    require(processkit_started(-1) < 0, "an invalid pid has no start time");
    /* Wrong or unknown start times must leave this process alone; reaching the next line proves it. */
    require(processkit_terminate(self, 0) == PROCESSKIT_UNKNOWN_START, "terminate refuses an unknown start time");
    require(processkit_terminate(self, started - 1) == PROCESSKIT_NOT_FOUND, "terminate refuses a reused pid");
    require(processkit_request_close(self, 0) == PROCESSKIT_UNKNOWN_START, "request_close refuses an unknown start time");
}

static void test_terminate(const char *program) {
    child_process child;
    int pid = start_child(program, &child);
    require(pid > 0, "the child starts");
    if (pid <= 0)
        return;
    double started = -1;
    for (int attempt = 0; attempt < 100 && started <= 0; attempt++) {
        started = processkit_started(pid);
        if (started <= 0)
            pause_briefly();
    }
    require(started > 0, "the child has a start time");
    require(processkit_terminate(pid, started + 1) == PROCESSKIT_NOT_FOUND, "a wrong start time leaves the child alone");
    require(!child_exited(child, 0), "the child survives a mismatched terminate");
    require(processkit_terminate(pid, started) == PROCESSKIT_OK, "a matching terminate succeeds");
    require(child_exited(child, 10), "the child exits once terminated");
    reap_child(child);
    require(processkit_identify(pid, started) == PROCESSKIT_NOT_FOUND, "an exited child is not found");
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--sleep") == 0) {
#if defined(_WIN32)
        Sleep(60000);
#else
        sleep(60);
#endif
        return 0;
    }
    int self = processkit_current_pid();
    test_snapshot(self);
    test_identity(self);
    test_terminate(argv[0]);
    if (failures == 0)
        printf("PASS: processkit contract\n");
    return failures == 0 ? 0 : 1;
}
