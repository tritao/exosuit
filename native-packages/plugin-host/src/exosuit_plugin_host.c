#include "exosuit_plugin_host.h"
#include <stddef.h>

static eph_dispatch host_dispatch;

void exosuit_plugin_host_install(eph_dispatch dispatch) {
  host_dispatch = dispatch;
}

hxi_utf8 exosuit_plugin_host_call(int32_t operation, hxi_utf8 token,
    hxi_utf8 a, hxi_utf8 b, hxi_utf8 c) {
  if (!host_dispatch) return "";
  hxi_utf8 result = host_dispatch(operation, token, a, b, c);
  return result ? result : "";
}
