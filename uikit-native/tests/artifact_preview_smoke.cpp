#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <nativekit.h>
#include <nativekit_window.h>
#include <stdio.h>
#include <string>
#include <cstring>
#include <vector>
extern "C" int exosuit_artifact_preview_open(uint32_t parent, const char *source);
extern "C" int exosuit_artifact_preview_test_result();
int main() {
    WSADATA winsock{};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return 4;
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(18941);
    if (listener == INVALID_SOCKET || bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listener, 4) != 0) return 5;
    nk_init_options init{}; init.struct_size = sizeof(init); init.api_version = NK_API_VERSION;
    if (nk_init(&init) != NK_OK) return 1;
    nk_window_options options{}; options.struct_size = sizeof(options); options.width = 600; options.height = 400; options.flags = NK_WINDOW_HIDDEN;
    options.title = "Artifact smoke host";
    nk_window window = NK_INVALID_HANDLE;
    if (nk_window_create(&options, &window) != NK_OK) return 2;
    std::string html = "<style>body{background:#234;color:white;font:28px sans-serif} .box{padding:50px;background:#468}</style><div class=box>Static HTML preview</div><script>document.querySelector('.box').textContent='SCRIPT RAN';fetch('http://127.0.0.1:18941/script')</script>";
    char mode[20]{}; GetEnvironmentVariableA("EXOSUIT_ARTIFACT_SMOKE_CASE", mode, sizeof(mode));
    if (!strcmp(mode, "image")) html += "<img src='http://127.0.0.1:18941/image'>";
    else if (!strcmp(mode, "frame")) html += "<iframe src='http://127.0.0.1:18941/frame'></iframe>";
    else if (!strcmp(mode, "refresh")) html += "<meta http-equiv='refresh' content='1;url=http://127.0.0.1:18941/nav'>";
    else if (!strcmp(mode, "all")) html += "<meta http-equiv='refresh' content='1;url=http://127.0.0.1:18941/nav'><iframe src='http://127.0.0.1:18941/frame'></iframe><img src='http://127.0.0.1:18941/image'><svg><image href='http://127.0.0.1:18941/svg'/></svg><video poster='http://127.0.0.1:18941/poster'></video><div><template shadowrootmode='open'><iframe src='http://127.0.0.1:18941/shadow'></iframe></template></div><link rel='preconnect' href='http://127.0.0.1:18941'><a href='http://127.0.0.1:18941/link' target='_blank'>link</a><form action='http://127.0.0.1:18941/form'><button>send</button></form><style>@import url(http://127.0.0.1:18941/css);.box{background-image:url(http://127.0.0.1:18941/bg)}</style>";
    if (!exosuit_artifact_preview_open(window, html.c_str())) return 3;
    bool closeEarly = !strcmp(mode, "close");
    if (closeEarly) { nk_window_destroy(window); window = NK_INVALID_HANDLE; }
    DWORD start = GetTickCount();
    bool contacted = false;
    while (GetTickCount() - start < 10000) {
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        nk_event event{}; event.struct_size = sizeof(event);
        if (nk_poll_event(&event) == NK_OK) nk_event_release(&event);
        fd_set reads; FD_ZERO(&reads); FD_SET(listener, &reads); timeval timeout{};
        if (select(0, &reads, nullptr, nullptr, &timeout) > 0) {
            contacted = true;
            SOCKET peer = accept(listener, nullptr, nullptr);
            if (peer != INVALID_SOCKET) {
                sockaddr_in remote{}; int remoteLength = sizeof(remote);
                if (getpeername(peer, reinterpret_cast<sockaddr *>(&remote), &remoteLength) == 0) {
                    DWORD length = 0;
                    GetExtendedTcpTable(nullptr, &length, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
                    std::vector<unsigned char> data(length);
                    if (GetExtendedTcpTable(data.data(), &length, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) == NO_ERROR) {
                        auto *table = reinterpret_cast<MIB_TCPTABLE_OWNER_PID *>(data.data());
                        for (DWORD i = 0; i < table->dwNumEntries; ++i) {
                            auto &row = table->table[i];
                            if (row.dwLocalPort == remote.sin_port && row.dwRemotePort == htons(18941)) {
                                fprintf(stderr, "loopback initiator pid=%lu port=%u\n", row.dwOwningPid, ntohs(remote.sin_port));
                                HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, row.dwOwningPid);
                                if (process) { char executable[2048]{}; DWORD size = sizeof(executable); if (QueryFullProcessImageNameA(process, 0, executable, &size)) fprintf(stderr, "loopback executable=%s\n", executable); CloseHandle(process); }
                            }
                        }
                    }
                }
                DWORD receiveTimeout = 1000; setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&receiveTimeout), sizeof(receiveTimeout));
                char request[1024]{}; int count = recv(peer, request, sizeof(request) - 1, 0);
                if (count > 0) fprintf(stderr, "unexpected request: %.*s\n", count, request);
                closesocket(peer);
            }
        }
        Sleep(10);
    }
    if (window != NK_INVALID_HANDLE) nk_window_destroy(window);
    nk_shutdown(); closesocket(listener); WSACleanup();
    int probe = exosuit_artifact_preview_test_result();
    if (contacted) fprintf(stderr, "unexpected loopback connection\n");
    if (closeEarly) return contacted ? 6 : 0;
    if (probe != 1) { fprintf(stderr, "preview DOM probe failed: %d\n", probe); return 7; }
    return contacted ? 6 : 0;
}
