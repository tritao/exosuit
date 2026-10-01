#ifndef PRAGTICAL_HX_NATIVE_H
#define PRAGTICAL_HX_NATIVE_H
#include <stdbool.h>
#include <stdint.h>
#if defined(__clang__)
#define PHX_BOOL32 __attribute__((annotate("hxi:bool32")))
#define PHX_BORROWED __attribute__((annotate("hxi:returns_borrowed_utf8")))
#define PHX_NULLABLE _Nullable
#define PHX_RETAINED __attribute__((annotate("hxi:retained")))
#else
#define PHX_BOOL32
#define PHX_BORROWED
#define PHX_NULLABLE
#define PHX_RETAINED
#endif
typedef uint32_t phx_bool PHX_BOOL32;
typedef const char *hxi_utf8;
/* Returned callback text remains valid until its next invocation or closure. */
typedef hxi_utf8 (*phx_dispatch)(int32_t operation, hxi_utf8 token, hxi_utf8 a, hxi_utf8 b, hxi_utf8 c);
void pragtical_hx_plugin_api_install(PHX_RETAINED phx_dispatch PHX_NULLABLE dispatch);
int32_t pragtical_hx_abi_version(void);
phx_bool pragtical_hx_init(phx_bool headless);
void pragtical_hx_shutdown(void);
hxi_utf8 pragtical_hx_last_error(void) PHX_BORROWED;
int32_t pragtical_hx_window_create(hxi_utf8 title, int32_t width, int32_t height);
phx_bool pragtical_hx_window_destroy(int32_t window);
phx_bool pragtical_hx_window_valid(int32_t window);
int32_t pragtical_hx_window_width(int32_t window);
int32_t pragtical_hx_window_height(int32_t window);
int32_t pragtical_hx_window_display_scale_milli(int32_t window);
phx_bool pragtical_hx_text_input_area(int32_t window, int32_t x, int32_t y, int32_t width, int32_t height, int32_t cursor);
phx_bool pragtical_hx_event_poll(void);
int32_t pragtical_hx_event_kind(void);
int32_t pragtical_hx_event_window(void);
int32_t pragtical_hx_event_a(void);
int32_t pragtical_hx_event_b(void);
int32_t pragtical_hx_event_c(void);
int32_t pragtical_hx_event_d(void);
hxi_utf8 pragtical_hx_event_text(void) PHX_BORROWED;
phx_bool pragtical_hx_event_push_test(int32_t kind, int32_t window, int32_t a, int32_t b);
phx_bool pragtical_hx_event_push_text_test(int32_t kind, int32_t window, int32_t a, int32_t b, hxi_utf8 text);
phx_bool pragtical_hx_clipboard_set(hxi_utf8 text);
hxi_utf8 pragtical_hx_clipboard_get(void) PHX_BORROWED;
phx_bool pragtical_hx_frame_begin(int32_t window);
phx_bool pragtical_hx_set_clip_rect(int32_t window, int32_t x, int32_t y, int32_t width, int32_t height);
phx_bool pragtical_hx_draw_rect(int32_t window, int32_t x, int32_t y, int32_t width, int32_t height, int32_t rgba);
int32_t pragtical_hx_font_create(int32_t window, hxi_utf8 path, int32_t size);
phx_bool pragtical_hx_font_add_fallback(int32_t font, hxi_utf8 path);
int32_t pragtical_hx_font_fallback_count(int32_t font);
phx_bool pragtical_hx_font_destroy(int32_t font);
int32_t pragtical_hx_font_height(int32_t font);
int32_t pragtical_hx_font_text_width(int32_t font, hxi_utf8 text);
phx_bool pragtical_hx_draw_text(int32_t window, int32_t font, int32_t x, int32_t y, hxi_utf8 text, int32_t rgba);
phx_bool pragtical_hx_frame_present(int32_t window);
int32_t pragtical_hx_frame_count(int32_t window);
int32_t pragtical_hx_process_create(hxi_utf8 executable, hxi_utf8 cwd);
phx_bool pragtical_hx_process_add_argument(int32_t process, hxi_utf8 argument);
phx_bool pragtical_hx_process_set_environment(int32_t process, hxi_utf8 key, hxi_utf8 value);
phx_bool pragtical_hx_process_start(int32_t process);
int32_t pragtical_hx_process_write(int32_t process, hxi_utf8 data);
phx_bool pragtical_hx_process_close_stdin(int32_t process);
hxi_utf8 pragtical_hx_process_stdout(int32_t process) PHX_BORROWED;
hxi_utf8 pragtical_hx_process_stderr(int32_t process) PHX_BORROWED;
int32_t pragtical_hx_process_state(int32_t process);
int32_t pragtical_hx_process_exit_status(int32_t process);
phx_bool pragtical_hx_process_cancel(int32_t process);
phx_bool pragtical_hx_process_destroy(int32_t process);
hxi_utf8 pragtical_hx_plugin_api_call(int32_t operation, hxi_utf8 token, hxi_utf8 a, hxi_utf8 b, hxi_utf8 c) PHX_BORROWED;

#endif
