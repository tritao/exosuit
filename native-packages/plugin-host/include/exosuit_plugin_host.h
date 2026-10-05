#ifndef EXOSUIT_PLUGIN_HOST_H
#define EXOSUIT_PLUGIN_HOST_H
#include <stdint.h>
#if defined(__clang__)
#define EPH_BORROWED __attribute__((annotate("hxi:returns_borrowed_utf8")))
#define EPH_NULLABLE _Nullable
#define EPH_RETAINED __attribute__((annotate("hxi:retained")))
#else
#define EPH_BORROWED
#define EPH_NULLABLE
#define EPH_RETAINED
#endif
typedef const char *hxi_utf8;
/* Returned text stays valid until the next invocation or callback closure.
   Install/call/uninstall belong to the editor thread. No platform initialization is required. */
typedef hxi_utf8 (*eph_dispatch)(int32_t operation, hxi_utf8 token, hxi_utf8 a, hxi_utf8 b, hxi_utf8 c);
void exosuit_plugin_host_install(EPH_RETAINED eph_dispatch EPH_NULLABLE dispatch);
hxi_utf8 exosuit_plugin_host_call(int32_t operation, hxi_utf8 token, hxi_utf8 a, hxi_utf8 b, hxi_utf8 c) EPH_BORROWED;
#endif
