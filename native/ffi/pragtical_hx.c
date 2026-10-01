#include "pragtical_hx/native.h"
#include "pragtical_hx/platform.h"
#include <stdio.h>
#include <string.h>

static phx_event current_event;
static phx_dispatch plugin_api_dispatch;
#define PROCESS_STREAM_SLOTS 32
typedef struct process_stream_state {
  int handle;
  unsigned char stdout_carry[4];
  int stdout_carry_length;
  unsigned char stderr_carry[4];
  int stderr_carry_length;
} process_stream_state;
static process_stream_state process_streams[PROCESS_STREAM_SLOTS];

int pragtical_hx_abi_version(void) { return phx_platform_abi_version(); }
phx_bool pragtical_hx_init(phx_bool headless) { return phx_platform_init(headless); }
void pragtical_hx_shutdown(void) {
  plugin_api_dispatch = NULL;
  memset(process_streams, 0, sizeof(process_streams));
  phx_platform_shutdown();
}
const char *pragtical_hx_last_error(void) {
  return phx_platform_last_error();
}
int pragtical_hx_window_create(const char *title, int width, int height) {
  const char *utf8 = title ? title : "";
  return phx_window_create(utf8, width, height);
}
phx_bool pragtical_hx_window_destroy(int window) {
  return phx_window_destroy(window);
}
phx_bool pragtical_hx_window_valid(int window) {
  return phx_window_valid(window);
}
int pragtical_hx_window_width(int window) { return phx_window_width(window); }
int pragtical_hx_window_height(int window) { return phx_window_height(window); }
int pragtical_hx_window_display_scale_milli(int window) { return phx_window_display_scale_milli(window); }
phx_bool pragtical_hx_text_input_area(int window, int x, int y, int width,
                                      int height, int cursor) {
  return phx_text_input_area(window, x, y, width, height, cursor);
}
phx_bool pragtical_hx_event_poll(void) { return phx_event_poll(&current_event); }
int pragtical_hx_event_kind(void) { return current_event.kind; }
int pragtical_hx_event_window(void) { return current_event.window; }
int pragtical_hx_event_a(void) { return current_event.a; }
int pragtical_hx_event_b(void) { return current_event.b; }
int pragtical_hx_event_c(void) { return current_event.c; }
int pragtical_hx_event_d(void) { return current_event.d; }
const char *pragtical_hx_event_text(void) {
	return current_event.text;
}
phx_bool pragtical_hx_event_push_test(int kind, int window, int a, int b) {
  phx_event event = {.kind = kind, .window = window, .a = a, .b = b};
  return phx_event_push_for_test(&event);
}
phx_bool pragtical_hx_event_push_text_test(int kind, int window, int a, int b,
                                           const char *text) {
  phx_event event = {.kind = kind, .window = window, .a = a, .b = b};
  const char *utf8 = text ? text : "";
  snprintf(event.text, sizeof(event.text), "%s", utf8);
  return phx_event_push_for_test(&event);
}
phx_bool pragtical_hx_clipboard_set(const char *text) {
  const char *utf8 = text ? text : "";
  return phx_clipboard_set(utf8);
}
const char *pragtical_hx_clipboard_get(void) {
  return phx_clipboard_get();
}
phx_bool pragtical_hx_frame_begin(int window) { return phx_frame_begin(window); }
phx_bool pragtical_hx_set_clip_rect(int window, int x, int y, int width, int height) {
  return phx_set_clip_rect(window, x, y, width, height);
}
phx_bool pragtical_hx_draw_rect(int window, int x, int y, int width, int height,
                                int rgba) {
  return phx_draw_rect(window, x, y, width, height, rgba);
}
int pragtical_hx_font_create(int window, const char *path, int size) {
  const char *utf8 = path ? path : "";
  return phx_font_create(window, utf8, size);
}
phx_bool pragtical_hx_font_add_fallback(int font, const char *path) {
  const char *utf8 = path ? path : "";
  return phx_font_add_fallback(font, utf8);
}
int pragtical_hx_font_fallback_count(int font) {
  return phx_font_fallback_count(font);
}
phx_bool pragtical_hx_font_destroy(int font) { return phx_font_destroy(font); }
int pragtical_hx_font_height(int font) { return phx_font_height(font); }
int pragtical_hx_font_text_width(int font, const char *text) {
  const char *utf8 = text ? text : "";
  return phx_font_text_width(font, utf8);
}
phx_bool pragtical_hx_draw_text(int window, int font, int x, int y, const char *text,
                                int rgba) {
  const char *utf8 = text ? text : "";
  return phx_draw_text(window, font, x, y, utf8, rgba);
}
phx_bool pragtical_hx_frame_present(int window) {
  return phx_frame_present(window);
}
int pragtical_hx_frame_count(int window) { return phx_frame_count(window); }

int pragtical_hx_process_create(const char *executable, const char *cwd) {
  int handle = phx_process_create(executable ? executable : "",
    cwd ? cwd : "");
  int index = (handle & 255) - 1;
  if (index >= 0 && index < PROCESS_STREAM_SLOTS) {
    memset(&process_streams[index], 0, sizeof(process_streams[index]));
    process_streams[index].handle = handle;
  }
  return handle;
}
phx_bool pragtical_hx_process_add_argument(int process, const char *argument) {
  return phx_process_add_argument(process,
    argument ? argument : "");
}
phx_bool pragtical_hx_process_set_environment(int process, const char *key,
                                               const char *value) {
  return phx_process_set_environment(process,
    key ? key : "", value ? value : "");
}
phx_bool pragtical_hx_process_start(int process) {
  return phx_process_start(process);
}
int pragtical_hx_process_write(int process, const char *data) {
  const char *utf8 = data ? data : "";
  return phx_process_write(process, utf8, (int32_t)strlen(utf8));
}
phx_bool pragtical_hx_process_close_stdin(int process) {
  return phx_process_close_stdin(process);
}
static int complete_utf8_prefix(const unsigned char *data, int length) {
  int offset = 0;
  while (offset < length) {
    unsigned char lead = data[offset];
    int width = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2
      : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
    if (offset + width > length) return offset;
    bool valid = true;
    for (int index = 1; index < width; index++)
      if ((data[offset + index] & 0xC0) != 0x80) valid = false;
    offset += valid ? width : 1;
  }
  return offset;
}

static const char *process_output(int process, bool standard_error) {
  static unsigned char buffer[4100];
  int index = (process & 255) - 1;
  process_stream_state *state = index >= 0 && index < PROCESS_STREAM_SLOTS
    && process_streams[index].handle == process ? &process_streams[index] : NULL;
  int *carry_length = state ? (standard_error ? &state->stderr_carry_length
    : &state->stdout_carry_length) : NULL;
  unsigned char *carry = state ? (standard_error ? state->stderr_carry
    : state->stdout_carry) : NULL;
  int prefix = carry_length ? *carry_length : 0;
  if (prefix > 0) memcpy(buffer, carry, (size_t)prefix);
  int32_t count = phx_process_read(process, standard_error,
    (char *)buffer + prefix, 4096);
  if (count < 0) return "";
  int total = prefix + count;
  int complete = complete_utf8_prefix(buffer, total);
  if (carry_length) {
    *carry_length = total - complete;
    if (*carry_length > 0) memcpy(carry, buffer + complete, (size_t)*carry_length);
  }
  if (complete == 0) return "";
  buffer[complete] = '\0';
  return (const char *)buffer;
}
const char *pragtical_hx_process_stdout(int process) {
  return process_output(process, false);
}
const char *pragtical_hx_process_stderr(int process) {
  return process_output(process, true);
}
int pragtical_hx_process_state(int process) {
  return phx_process_state(process);
}
int pragtical_hx_process_exit_status(int process) {
  return phx_process_exit_status(process);
}
phx_bool pragtical_hx_process_cancel(int process) {
  return phx_process_cancel(process);
}
phx_bool pragtical_hx_process_destroy(int process) {
  bool destroyed = phx_process_destroy(process);
  int index = (process & 255) - 1;
  if (destroyed && index >= 0 && index < PROCESS_STREAM_SLOTS
      && process_streams[index].handle == process)
    memset(&process_streams[index], 0, sizeof(process_streams[index]));
  return destroyed;
}


void pragtical_hx_plugin_api_install(phx_dispatch dispatch) {
  plugin_api_dispatch = dispatch;
}

hxi_utf8 pragtical_hx_plugin_api_call(int32_t operation, hxi_utf8 token,
    hxi_utf8 a, hxi_utf8 b, hxi_utf8 c) {
  if (!plugin_api_dispatch) return "";
  hxi_utf8 result = plugin_api_dispatch(operation, token, a, b, c);
  return result ? result : "";
}
