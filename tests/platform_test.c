#include "pragtical_hx/platform.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  assert(phx_platform_abi_version() == PHX_PLATFORM_ABI_VERSION);
  assert(phx_platform_init(true));
  phx_handle first = phx_window_create("test", 800, 600);
  assert(first != 0 && phx_window_valid(first));
	assert(phx_window_width(first) == 800 && phx_window_height(first) == 600);
	assert(phx_window_display_scale_milli(first) == 1000);
	assert(phx_text_input_area(first, 40, 50, 2, 15, 0));
	assert(!phx_text_input_area(first, 0, 0, -1, 15, 0));
  phx_handle font = phx_font_create(first, "ignored-headlessly.ttf", 15);
  assert(font != 0);
	assert(phx_font_add_fallback(font, "fallback-headlessly.ttf"));
	assert(phx_font_fallback_count(font) == 2);
  assert(phx_font_height(font) == 15);
  assert(phx_font_text_width(font, "hello") > 0);
  assert(phx_frame_begin(first));
  assert(phx_set_clip_rect(first, 0, 0, 800, 600));
  assert(phx_draw_rect(first, 0, 0, 10, 10, 0xffffffff));
  assert(phx_draw_text(first, font, 2, 2, "hello", 0xffffffff));
  assert(phx_frame_present(first));
  assert(phx_frame_count(first) == 1);
  assert(phx_clipboard_set("first\nOlá 😀"));
  assert(strcmp(phx_clipboard_get(), "first\nOlá 😀") == 0);

  phx_event resize = {
    .kind = PHX_EVENT_WINDOW_RESIZED,
    .window = first,
    .a = 1024,
    .b = 768
  };
  phx_event result = {0};
  assert(phx_event_push_for_test(&resize));
  assert(phx_event_poll(&result));
  assert(result.kind == PHX_EVENT_WINDOW_RESIZED);
  assert(result.window == first && result.a == 1024 && result.b == 768);

  phx_event mouse = {.kind = PHX_EVENT_MOUSE_MOVED, .window = first,
                     .a = 30, .b = 40, .c = 2, .d = -1};
  assert(phx_event_push_for_test(&mouse));
  assert(phx_event_poll(&result));
	assert(result.kind == PHX_EVENT_MOUSE_MOVED && result.a == 30 && result.b == 40);
	assert(result.c == 2 && result.d == -1);

	phx_event scale = {.kind = PHX_EVENT_DISPLAY_SCALE_CHANGED, .window = first,
	                   .a = 1750};
	assert(phx_event_push_for_test(&scale));
	assert(phx_event_poll(&result));
	assert(result.kind == PHX_EVENT_DISPLAY_SCALE_CHANGED && result.window == first);
	assert(result.a == 1750);

	phx_event editing = {.kind = PHX_EVENT_TEXT_EDITING, .window = first,
	                     .a = 1, .b = 2};
	snprintf(editing.text, sizeof(editing.text), "%s", "にほん");
	assert(phx_event_push_for_test(&editing));
	assert(phx_event_poll(&result));
	assert(result.kind == PHX_EVENT_TEXT_EDITING && result.window == first);
	assert(result.a == 1 && result.b == 2 && strcmp(result.text, "にほん") == 0);

	phx_event dropped = {.kind = PHX_EVENT_FILE_DROPPED, .window = first};
	snprintf(dropped.text, sizeof(dropped.text), "%s", "/tmp/dropped file.txt");
	assert(phx_event_push_for_test(&dropped));
	assert(phx_event_poll(&result));
	assert(result.kind == PHX_EVENT_FILE_DROPPED && result.window == first);
	assert(strcmp(result.text, "/tmp/dropped file.txt") == 0);

  assert(phx_font_destroy(font));
  assert(phx_window_destroy(first));
  assert(!phx_window_valid(first));
  phx_handle second = phx_window_create("replacement", 1, 1);
  assert(second != 0 && second != first);
  assert(!phx_window_valid(first));
  assert(!phx_window_destroy(first));
  assert(phx_window_destroy(second));
  phx_platform_shutdown();
  puts("PASS: platform ABI, event queue, frames, and stale handles");
  return 0;
}
