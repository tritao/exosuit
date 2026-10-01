#define _POSIX_C_SOURCE 200809L
#include "pragtical_hx/platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef PHX_WITH_SDL
#include <SDL3/SDL.h>
#include "platform_sdl.h"
#include "renderer/cache.h"
#include "renderer/renderer.h"
#include "renderer/window.h"
#endif

#define PHX_INDEX_BITS 8
#define PHX_INDEX_MASK ((1 << PHX_INDEX_BITS) - 1)

typedef struct phx_window_slot {
  uint32_t generation;
  bool occupied;
  int32_t width;
  int32_t height;
  int32_t frames;
  char title[128];
#ifdef PHX_WITH_SDL
  SDL_Window *window;
  RenWindow *renderer;
#endif
} phx_window_slot;

typedef struct phx_font_slot {
  uint32_t generation;
  bool occupied;
  int32_t height;
  int32_t advance;
  int32_t size;
  int32_t fallback_count;
#ifdef PHX_WITH_SDL
  RenFont *group[PHX_MAX_FONT_FALLBACKS];
#endif
} phx_font_slot;

typedef struct phx_process_slot {
  uint32_t generation;
  bool occupied;
  bool started;
  bool running;
  int32_t exit_status;
  pid_t pid;
  int stdin_fd;
  int stdout_fd;
  int stderr_fd;
  char *executable;
  char *cwd;
  char *arguments[PHX_MAX_PROCESS_ARGS];
  int32_t argument_count;
  char *environment_keys[PHX_MAX_PROCESS_ENV];
  char *environment_values[PHX_MAX_PROCESS_ENV];
  int32_t environment_count;
} phx_process_slot;

static bool initialized;
static bool is_headless;
static phx_window_slot windows[PHX_MAX_WINDOWS];
static phx_font_slot fonts[PHX_MAX_FONTS];
static phx_process_slot processes[PHX_MAX_PROCESSES];
static phx_event events[PHX_EVENT_CAPACITY];
static uint32_t event_read;
static uint32_t event_count;
static char last_error[256];
static char *clipboard_text;
static struct sigaction previous_sigpipe;
static bool sigpipe_ignored;

#ifdef PHX_WITH_SDL
static int32_t normalize_key(SDL_Keycode key) {
  switch (key) {
    case SDLK_BACKSPACE: return PHX_KEY_BACKSPACE;
    case SDLK_TAB: return PHX_KEY_TAB;
    case SDLK_RETURN: return PHX_KEY_ENTER;
    case SDLK_ESCAPE: return PHX_KEY_ESCAPE;
    case SDLK_DELETE: return PHX_KEY_DELETE;
    case SDLK_LEFT: return PHX_KEY_LEFT;
    case SDLK_RIGHT: return PHX_KEY_RIGHT;
    case SDLK_UP: return PHX_KEY_UP;
    case SDLK_DOWN: return PHX_KEY_DOWN;
    case SDLK_HOME: return PHX_KEY_HOME;
    case SDLK_END: return PHX_KEY_END;
    case SDLK_A: return PHX_KEY_A;
    case SDLK_S: return PHX_KEY_S;
    case SDLK_Y: return PHX_KEY_Y;
    case SDLK_Z: return PHX_KEY_Z;
    case SDLK_W: return PHX_KEY_W;
    case SDLK_P: return PHX_KEY_P;
    case SDLK_F: return PHX_KEY_F;
    case SDLK_H: return PHX_KEY_H;
    case SDLK_C: return PHX_KEY_C;
    case SDLK_V: return PHX_KEY_V;
    case SDLK_X: return PHX_KEY_X;
    case SDLK_PAGEUP: return PHX_KEY_PAGE_UP;
    case SDLK_PAGEDOWN: return PHX_KEY_PAGE_DOWN;
    case SDLK_K: return PHX_KEY_K;
    case SDLK_J: return PHX_KEY_J;
    case SDLK_SLASH: return PHX_KEY_SLASH;
    case SDLK_D: return PHX_KEY_D;
    case SDLK_G: return PHX_KEY_G;
    case SDLK_B: return PHX_KEY_B;
    case SDLK_SPACE: return PHX_KEY_SPACE;
    default: return PHX_KEY_UNKNOWN;
  }
}

static int32_t normalize_modifiers(SDL_Keymod modifiers) {
  int32_t result = 0;
  if (modifiers & SDL_KMOD_SHIFT) result |= PHX_MOD_SHIFT;
  if (modifiers & SDL_KMOD_CTRL) result |= PHX_MOD_CTRL;
  if (modifiers & SDL_KMOD_ALT) result |= PHX_MOD_ALT;
  return result;
}
#endif

static bool fail(const char *message) {
  snprintf(last_error, sizeof(last_error), "%s", message);
  /* Keep a bounded diagnostic from ending inside a UTF-8 scalar. */
  size_t length = strlen(last_error);
  if (length > 0) {
    size_t start = length - 1;
    while (start > 0 && ((unsigned char)last_error[start] & 0xC0) == 0x80) start--;
    unsigned char lead = (unsigned char)last_error[start];
    size_t width = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2
      : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
    if (length - start < width) last_error[start] = '\0';
  }
  return false;
}

static bool store_clipboard(const char *text) {
  const char *value = text ? text : "";
  size_t size = strlen(value) + 1;
  char *replacement = (char *)realloc(clipboard_text, size);
  if (!replacement) return fail("could not allocate clipboard text");
  memcpy(replacement, value, size);
  clipboard_text = replacement;
  return true;
}

#ifdef PHX_WITH_SDL
static void store_event_text(char *target, size_t capacity, const char *text) {
  const unsigned char *source = (const unsigned char *)(text ? text : "");
  size_t length = strlen((const char *)source);
  if (length >= capacity) {
    length = capacity - 1;
    while (length > 0 && (source[length] & 0xc0) == 0x80) length--;
  }
  memcpy(target, source, length);
  target[length] = '\0';
}
#endif

static phx_handle make_handle(uint32_t index, uint32_t generation) {
  return (phx_handle)((generation << PHX_INDEX_BITS) | (index + 1));
}

static phx_window_slot *resolve_window(phx_handle handle) {
  if (handle <= 0) return NULL;
  uint32_t encoded_index = (uint32_t)handle & PHX_INDEX_MASK;
  uint32_t generation = (uint32_t)handle >> PHX_INDEX_BITS;
  if (encoded_index == 0 || encoded_index > PHX_MAX_WINDOWS) return NULL;
  phx_window_slot *slot = &windows[encoded_index - 1];
  if (!slot->occupied || slot->generation != generation) return NULL;
  return slot;
}

#ifdef PHX_WITH_SDL
static phx_handle window_handle_from_id(SDL_WindowID id) {
  for (uint32_t index = 0; index < PHX_MAX_WINDOWS; index++) {
    if (windows[index].occupied && windows[index].window &&
        SDL_GetWindowID(windows[index].window) == id)
      return make_handle(index, windows[index].generation);
  }
  return 0;
}
#endif

static phx_font_slot *resolve_font(phx_handle handle) {
  if (handle <= 0) return NULL;
  uint32_t encoded_index = (uint32_t)handle & PHX_INDEX_MASK;
  uint32_t generation = (uint32_t)handle >> PHX_INDEX_BITS;
  if (encoded_index == 0 || encoded_index > PHX_MAX_FONTS) return NULL;
  phx_font_slot *slot = &fonts[encoded_index - 1];
  if (!slot->occupied || slot->generation != generation) return NULL;
  return slot;
}

static phx_process_slot *resolve_process(phx_handle handle) {
  if (handle <= 0) return NULL;
  uint32_t encoded_index = (uint32_t)handle & PHX_INDEX_MASK;
  uint32_t generation = (uint32_t)handle >> PHX_INDEX_BITS;
  if (encoded_index == 0 || encoded_index > PHX_MAX_PROCESSES) return NULL;
  phx_process_slot *slot = &processes[encoded_index - 1];
  if (!slot->occupied || slot->generation != generation) return NULL;
  return slot;
}

static void free_process_configuration(phx_process_slot *slot) {
  free(slot->executable);
  free(slot->cwd);
  slot->executable = NULL;
  slot->cwd = NULL;
  for (int32_t index = 0; index < slot->argument_count; index++) {
    free(slot->arguments[index]);
    slot->arguments[index] = NULL;
  }
  for (int32_t index = 0; index < slot->environment_count; index++) {
    free(slot->environment_keys[index]);
    free(slot->environment_values[index]);
    slot->environment_keys[index] = NULL;
    slot->environment_values[index] = NULL;
  }
  slot->argument_count = 0;
  slot->environment_count = 0;
}

static void reap_process(phx_process_slot *slot) {
  if (!slot->started || !slot->running) return;
  int status = 0;
  pid_t result = waitpid(slot->pid, &status, WNOHANG);
  if (result != slot->pid) return;
  slot->running = false;
  slot->exit_status = WIFEXITED(status) ? WEXITSTATUS(status)
    : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
}

static void close_process_pipes(phx_process_slot *slot) {
  if (slot->stdin_fd >= 0) close(slot->stdin_fd);
  if (slot->stdout_fd >= 0) close(slot->stdout_fd);
  if (slot->stderr_fd >= 0) close(slot->stderr_fd);
  slot->stdin_fd = -1;
  slot->stdout_fd = -1;
  slot->stderr_fd = -1;
}

static void terminate_process(phx_process_slot *slot) {
  reap_process(slot);
  if (slot->running) {
    int status = 0;
    kill(slot->pid, SIGTERM);
    pid_t result = waitpid(slot->pid, &status, WNOHANG);
    if (result == 0) {
      kill(slot->pid, SIGKILL);
      result = waitpid(slot->pid, &status, 0);
    }
    slot->running = false;
    slot->exit_status = result == slot->pid && WIFEXITED(status) ? WEXITSTATUS(status)
      : result == slot->pid && WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
  }
}

static bool process_pipe(int descriptors[2]) {
  if (pipe(descriptors) != 0) return false;
  if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) < 0) {
    int saved_errno = errno;
    close(descriptors[0]);
    close(descriptors[1]);
    errno = saved_errno;
    return false;
  }
  return true;
}

static bool ignore_sigpipe(void) {
  struct sigaction ignored = {0};
  ignored.sa_handler = SIG_IGN;
  sigemptyset(&ignored.sa_mask);
  if (sigaction(SIGPIPE, &ignored, &previous_sigpipe) != 0) return false;
  sigpipe_ignored = true;
  return true;
}

static void restore_sigpipe(void) {
  if (sigpipe_ignored) sigaction(SIGPIPE, &previous_sigpipe, NULL);
  sigpipe_ignored = false;
}

#ifdef PHX_WITH_SDL
static RenColor renderer_color(int32_t rgba) {
  return (RenColor){.r = (rgba >> 24) & 255, .g = (rgba >> 16) & 255,
                    .b = (rgba >> 8) & 255, .a = rgba & 255};
}
#endif

int32_t phx_platform_abi_version(void) { return PHX_PLATFORM_ABI_VERSION; }

bool phx_platform_init(bool headless) {
  if (initialized) return fail("platform is already initialized");
  if (!ignore_sigpipe()) return fail(strerror(errno));
#ifndef PHX_WITH_SDL
  if (!headless) {
    restore_sigpipe();
    return fail("graphical backend is not compiled in");
  }
#else
  if (!headless) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
      restore_sigpipe();
      return fail(SDL_GetError());
    }
    if (ren_init() != 0) {
      SDL_Quit();
      restore_sigpipe();
      return fail(SDL_GetError());
    }
  }
#endif
  memset(windows, 0, sizeof(windows));
  memset(fonts, 0, sizeof(fonts));
  memset(processes, 0, sizeof(processes));
  for (uint32_t index = 0; index < PHX_MAX_PROCESSES; index++) {
    processes[index].stdin_fd = -1;
    processes[index].stdout_fd = -1;
    processes[index].stderr_fd = -1;
  }
  memset(events, 0, sizeof(events));
  event_read = 0;
  event_count = 0;
  last_error[0] = '\0';
  initialized = true;
  is_headless = headless;
  if (!store_clipboard("")) {
    initialized = false;
    restore_sigpipe();
    return false;
  }
  return true;
}

void phx_platform_shutdown(void) {
  for (uint32_t index = 0; index < PHX_MAX_PROCESSES; index++) {
    phx_process_slot *slot = &processes[index];
    if (!slot->occupied) continue;
    terminate_process(slot);
    close_process_pipes(slot);
    free_process_configuration(slot);
    slot->occupied = false;
  }
  if (!initialized) return;
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    for (uint32_t index = 0; index < PHX_MAX_FONTS; index++) {
      for (int font = 0; font < fonts[index].fallback_count; font++)
        if (fonts[index].group[font]) ren_font_free(fonts[index].group[font]);
    }
    for (uint32_t index = 0; index < PHX_MAX_WINDOWS; index++) {
      if (windows[index].renderer) ren_destroy(windows[index].renderer);
      else if (windows[index].window) SDL_DestroyWindow(windows[index].window);
    }
    ren_free();
    SDL_Quit();
  }
#endif
  initialized = false;
  memset(windows, 0, sizeof(windows));
  memset(fonts, 0, sizeof(fonts));
  memset(processes, 0, sizeof(processes));
  event_read = 0;
  event_count = 0;
  free(clipboard_text);
  clipboard_text = NULL;
  restore_sigpipe();
}

const char *phx_platform_last_error(void) { return last_error; }

phx_handle phx_window_create(const char *title, int32_t width, int32_t height) {
  if (!initialized) {
    fail("platform is not initialized");
    return 0;
  }
  if (width <= 0 || height <= 0) {
    fail("window dimensions must be positive");
    return 0;
  }
  for (uint32_t index = 0; index < PHX_MAX_WINDOWS; index++) {
    phx_window_slot *slot = &windows[index];
    if (slot->occupied) continue;
    slot->generation++;
    if (slot->generation == 0) slot->generation = 1;
    slot->occupied = true;
    slot->width = width;
    slot->height = height;
    slot->frames = 0;
    snprintf(slot->title, sizeof(slot->title), "%s", title ? title : "");
#ifdef PHX_WITH_SDL
    if (!is_headless) {
      slot->window = SDL_CreateWindow(slot->title, width, height, SDL_WINDOW_RESIZABLE);
      if (!slot->window) {
        slot->occupied = false;
        fail(SDL_GetError());
        return 0;
      }
      slot->renderer = ren_create(slot->window);
      if (!slot->renderer) {
        SDL_DestroyWindow(slot->window);
        slot->window = NULL;
        slot->occupied = false;
        fail(SDL_GetError());
        return 0;
      }
      if (!SDL_StartTextInput(slot->window)) {
        ren_destroy(slot->renderer);
        slot->renderer = NULL;
        slot->window = NULL;
        slot->occupied = false;
        fail(SDL_GetError());
        return 0;
      }
    }
#endif
    return make_handle(index, slot->generation);
  }
  fail("window table is full");
  return 0;
}

bool phx_window_destroy(phx_handle handle) {
  phx_window_slot *slot = resolve_window(handle);
  if (!slot) return fail("invalid or stale window handle");
#ifdef PHX_WITH_SDL
  if (slot->window) SDL_StopTextInput(slot->window);
  if (slot->renderer) ren_destroy(slot->renderer);
  else if (slot->window) SDL_DestroyWindow(slot->window);
  slot->renderer = NULL;
  slot->window = NULL;
#endif
  slot->occupied = false;
  return true;
}

bool phx_window_valid(phx_handle handle) { return resolve_window(handle) != NULL; }

int32_t phx_window_width(phx_handle handle) {
  phx_window_slot *slot = resolve_window(handle);
  if (!slot) { fail("invalid or stale window handle"); return -1; }
  return slot->width;
}

int32_t phx_window_height(phx_handle handle) {
  phx_window_slot *slot = resolve_window(handle);
  if (!slot) { fail("invalid or stale window handle"); return -1; }
  return slot->height;
}

int32_t phx_window_display_scale_milli(phx_handle handle) {
  phx_window_slot *slot = resolve_window(handle);
  if (!slot) { fail("invalid or stale window handle"); return -1; }
#ifdef PHX_WITH_SDL
  if (!is_headless) return (int32_t)(SDL_GetWindowDisplayScale(slot->window) * 1000.0f + 0.5f);
#endif
  return 1000;
}

bool phx_text_input_area(phx_handle handle, int32_t x, int32_t y,
                         int32_t width, int32_t height, int32_t cursor) {
  phx_window_slot *slot = resolve_window(handle);
  if (!slot) return fail("invalid or stale window handle");
  if (width < 0 || height < 0 || cursor < 0)
    return fail("invalid text input area");
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    SDL_Rect area = {x, y, width, height};
    if (!SDL_SetTextInputArea(slot->window, &area, cursor))
      return fail(SDL_GetError());
  }
#else
  (void)x; (void)y;
#endif
  return true;
}

bool phx_event_poll(phx_event *event) {
  if (!event) return false;
  if (event_count > 0) {
    *event = events[event_read];
    event_read = (event_read + 1) % PHX_EVENT_CAPACITY;
    event_count--;
    return true;
  }
  /* The graphical executable feeds this queue from SDL_AppEvent. */
  return false;
}

#ifdef PHX_WITH_SDL
bool phx_event_push_sdl(const SDL_Event *input) {
  if (!initialized || is_headless || !input) return false;
  phx_event event;
  memset(&event, 0, sizeof(event));
  switch (input->type) {
        case SDL_EVENT_QUIT: event.kind = PHX_EVENT_QUIT; break;
        case SDL_EVENT_WINDOW_RESIZED:
          event.kind = PHX_EVENT_WINDOW_RESIZED;
          event.a = input->window.data1;
          event.b = input->window.data2;
          for (uint32_t index = 0; index < PHX_MAX_WINDOWS; index++) {
            if (windows[index].occupied && windows[index].window &&
                SDL_GetWindowID(windows[index].window) == input->window.windowID) {
              windows[index].width = event.a;
              windows[index].height = event.b;
              event.window = make_handle(index, windows[index].generation);
              ren_resize_window(windows[index].renderer);
              break;
            }
          }
          break;
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
          event.kind = PHX_EVENT_DISPLAY_SCALE_CHANGED;
          event.window = window_handle_from_id(input->window.windowID);
          for (uint32_t index = 0; index < PHX_MAX_WINDOWS; index++) {
            if (windows[index].occupied && windows[index].window &&
                SDL_GetWindowID(windows[index].window) == input->window.windowID) {
              ren_resize_window(windows[index].renderer);
              event.a = phx_window_display_scale_milli(
                make_handle(index, windows[index].generation));
              break;
            }
          }
          break;
        case SDL_EVENT_KEY_DOWN:
          event.kind = PHX_EVENT_KEY_DOWN;
          event.window = window_handle_from_id(input->key.windowID);
          event.a = normalize_key(input->key.key);
          event.b = normalize_modifiers(input->key.mod);
          break;
        case SDL_EVENT_KEY_UP:
          event.kind = PHX_EVENT_KEY_UP;
          event.window = window_handle_from_id(input->key.windowID);
          event.a = normalize_key(input->key.key);
          event.b = normalize_modifiers(input->key.mod);
          break;
        case SDL_EVENT_TEXT_INPUT:
          event.kind = PHX_EVENT_TEXT_INPUT;
          event.window = window_handle_from_id(input->text.windowID);
          store_event_text(event.text, sizeof(event.text), input->text.text);
          break;
        case SDL_EVENT_TEXT_EDITING:
          event.kind = PHX_EVENT_TEXT_EDITING;
          event.window = window_handle_from_id(input->edit.windowID);
          event.a = input->edit.start;
          event.b = input->edit.length;
          store_event_text(event.text, sizeof(event.text), input->edit.text);
          break;
        case SDL_EVENT_MOUSE_MOTION:
          event.kind = PHX_EVENT_MOUSE_MOVED;
          event.window = window_handle_from_id(input->motion.windowID);
          event.a = (int32_t)input->motion.x;
          event.b = (int32_t)input->motion.y;
          event.c = (int32_t)input->motion.xrel;
          event.d = (int32_t)input->motion.yrel;
          break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
          event.kind = input->type == SDL_EVENT_MOUSE_BUTTON_DOWN
            ? PHX_EVENT_MOUSE_BUTTON_DOWN : PHX_EVENT_MOUSE_BUTTON_UP;
          event.window = window_handle_from_id(input->button.windowID);
          event.a = input->button.button;
          event.b = (int32_t)input->button.x;
          event.c = (int32_t)input->button.y;
          event.d = input->button.clicks;
          break;
        case SDL_EVENT_MOUSE_WHEEL:
          event.kind = PHX_EVENT_MOUSE_WHEEL;
          event.window = window_handle_from_id(input->wheel.windowID);
          event.a = (int32_t)(input->wheel.y * 100.0f);
          event.b = (int32_t)(-input->wheel.x * 100.0f);
          break;
        case SDL_EVENT_DROP_FILE:
          if (!input->drop.data || strlen(input->drop.data) >= sizeof(event.text))
            return false;
          event.kind = PHX_EVENT_FILE_DROPPED;
          event.window = window_handle_from_id(input->drop.windowID);
          store_event_text(event.text, sizeof(event.text), input->drop.data);
          break;
        default: return false;
  }
  return phx_event_push_for_test(&event);
}
#endif

bool phx_event_push_for_test(const phx_event *event) {
  if (!initialized) return fail("platform is not initialized");
  if (!event) return fail("event is null");
  if (event_count == PHX_EVENT_CAPACITY) return fail("event queue is full");
  uint32_t write = (event_read + event_count) % PHX_EVENT_CAPACITY;
  events[write] = *event;
  event_count++;
  return true;
}

bool phx_clipboard_set(const char *text) {
  if (!initialized) return fail("platform is not initialized");
#ifdef PHX_WITH_SDL
  if (!is_headless && !SDL_SetClipboardText(text ? text : ""))
    return fail(SDL_GetError());
#endif
  return store_clipboard(text);
}

const char *phx_clipboard_get(void) {
  if (!initialized) {
    fail("platform is not initialized");
    return NULL;
  }
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    char *text = SDL_GetClipboardText();
    if (!text) {
      fail(SDL_GetError());
      return NULL;
    }
    bool stored = store_clipboard(text);
    SDL_free(text);
    if (!stored) return NULL;
  }
#endif
  return clipboard_text ? clipboard_text : "";
}

bool phx_frame_begin(phx_handle window) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) return fail("invalid or stale window handle");
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    rencache_begin_frame(&slot->renderer->cache);
  }
#endif
  return true;
}

bool phx_set_clip_rect(phx_handle window, int32_t x, int32_t y, int32_t width,
                       int32_t height) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) return fail("invalid or stale window handle");
  if (width < 0 || height < 0) return fail("clip dimensions are negative");
#ifdef PHX_WITH_SDL
  if (!is_headless)
    rencache_set_clip_rect(&slot->renderer->cache, (RenRect){x, y, width, height});
#else
  (void)x; (void)y;
#endif
  return true;
}

bool phx_draw_rect(phx_handle window, int32_t x, int32_t y, int32_t width,
                   int32_t height, int32_t rgba) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) return fail("invalid or stale window handle");
  if (width < 0 || height < 0) return fail("rectangle dimensions are negative");
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    rencache_draw_rect(&slot->renderer->cache,
                       (RenRect){x, y, width, height}, renderer_color(rgba), true);
  }
#else
  (void)x; (void)y; (void)rgba;
#endif
  return true;
}

phx_handle phx_font_create(phx_handle window, const char *path, int32_t size) {
  if (!resolve_window(window)) { fail("invalid or stale window handle"); return 0; }
  if (size <= 0) { fail("font size must be positive"); return 0; }
#ifndef PHX_WITH_SDL
  (void)path;
#endif
  for (uint32_t index = 0; index < PHX_MAX_FONTS; index++) {
    phx_font_slot *slot = &fonts[index];
    if (slot->occupied) continue;
    slot->generation++;
    if (slot->generation == 0) slot->generation = 1;
    slot->occupied = true;
    slot->height = size;
    slot->advance = (size * 3 + 2) / 5;
    slot->size = size;
    slot->fallback_count = 1;
#ifdef PHX_WITH_SDL
    if (!is_headless) {
      slot->group[0] = ren_font_load(path, (float)size, FONT_ANTIALIASING_GRAYSCALE,
                                 FONT_HINTING_SLIGHT, 0, true);
      if (!slot->group[0]) { slot->occupied = false; fail(SDL_GetError()); return 0; }
      slot->height = ren_font_group_get_height(slot->group);
      slot->advance = (int)ren_font_group_get_width(slot->group, "M", 1, (RenTab){0}, NULL);
    }
#endif
    return make_handle(index, slot->generation);
  }
  fail("font table is full");
  return 0;
}

bool phx_font_add_fallback(phx_handle font, const char *path) {
  phx_font_slot *slot = resolve_font(font);
  if (!slot) return fail("invalid or stale font handle");
  if (!path || !path[0]) return fail("fallback font path is empty");
  if (slot->fallback_count >= PHX_MAX_FONT_FALLBACKS)
    return fail("font fallback group is full");
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    RenFont *fallback = ren_font_load(path, (float)slot->size,
      FONT_ANTIALIASING_GRAYSCALE, FONT_HINTING_SLIGHT, 0, true);
    if (!fallback) return fail(SDL_GetError());
    slot->group[slot->fallback_count] = fallback;
  }
#endif
  slot->fallback_count++;
  return true;
}

int32_t phx_font_fallback_count(phx_handle font) {
  phx_font_slot *slot = resolve_font(font);
  if (!slot) { fail("invalid or stale font handle"); return -1; }
  return slot->fallback_count;
}

bool phx_font_destroy(phx_handle font) {
  phx_font_slot *slot = resolve_font(font);
  if (!slot) return fail("invalid or stale font handle");
#ifdef PHX_WITH_SDL
  for (int index = 0; index < slot->fallback_count; index++) {
    if (slot->group[index]) ren_font_free(slot->group[index]);
    slot->group[index] = NULL;
  }
#endif
	slot->fallback_count = 0;
  slot->occupied = false;
  return true;
}

int32_t phx_font_height(phx_handle font) {
  phx_font_slot *slot = resolve_font(font);
  if (!slot) { fail("invalid or stale font handle"); return -1; }
  return slot->height;
}

int32_t phx_font_text_width(phx_handle font, const char *text) {
  phx_font_slot *slot = resolve_font(font);
  if (!slot) { fail("invalid or stale font handle"); return -1; }
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    return (int)ren_font_group_get_width(slot->group, text ? text : "",
      text ? strlen(text) : 0, (RenTab){0}, NULL);
  }
#endif
  return (int32_t)strlen(text ? text : "") * slot->advance;
}

bool phx_draw_text(phx_handle window, phx_handle font, int32_t x, int32_t y,
                   const char *text, int32_t rgba) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) return fail("invalid or stale window handle");
  phx_font_slot *font_slot = resolve_font(font);
  if (!font_slot) return fail("invalid or stale font handle");
#ifdef PHX_WITH_SDL
  if (!is_headless) {
    rencache_draw_text(&slot->renderer->cache, font_slot->group, text ? text : "",
      text ? strlen(text) : 0, x, y, renderer_color(rgba), (RenTab){0});
  }
#else
  (void)x; (void)y; (void)text; (void)rgba;
#endif
  return true;
}

bool phx_frame_present(phx_handle window) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) return fail("invalid or stale window handle");
#ifdef PHX_WITH_SDL
  if (!is_headless) rencache_end_frame(&slot->renderer->cache);
#endif
  slot->frames++;
  return true;
}

int32_t phx_frame_count(phx_handle window) {
  phx_window_slot *slot = resolve_window(window);
  if (!slot) {
    fail("invalid or stale window handle");
    return -1;
  }
  return slot->frames;
}

phx_handle phx_process_create(const char *executable, const char *cwd) {
  if (!initialized) { fail("platform is not initialized"); return 0; }
  if (!executable || executable[0] == '\0') { fail("process executable is empty"); return 0; }
  for (uint32_t index = 0; index < PHX_MAX_PROCESSES; index++) {
    phx_process_slot *slot = &processes[index];
    if (slot->occupied) continue;
    uint32_t generation = slot->generation + 1;
    if (generation == 0) generation = 1;
    memset(slot, 0, sizeof(*slot));
    slot->generation = generation;
    slot->stdin_fd = -1;
    slot->stdout_fd = -1;
    slot->stderr_fd = -1;
    slot->exit_status = -1;
    slot->executable = strdup(executable);
    slot->cwd = cwd && cwd[0] != '\0' ? strdup(cwd) : NULL;
    if (!slot->executable || (cwd && cwd[0] != '\0' && !slot->cwd)) {
      free_process_configuration(slot);
      fail("could not allocate process configuration");
      return 0;
    }
    slot->occupied = true;
    return make_handle(index, generation);
  }
  fail("process table is full");
  return 0;
}

bool phx_process_add_argument(phx_handle process, const char *argument) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot) return fail("invalid or stale process handle");
  if (slot->started) return fail("process already started");
  if (slot->argument_count >= PHX_MAX_PROCESS_ARGS)
    return fail("process argument limit exceeded");
  char *copy = strdup(argument ? argument : "");
  if (!copy) return fail("could not allocate process argument");
  slot->arguments[slot->argument_count++] = copy;
  return true;
}

bool phx_process_set_environment(phx_handle process, const char *key,
                                 const char *value) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot) return fail("invalid or stale process handle");
  if (slot->started) return fail("process already started");
  if (!key || key[0] == '\0' || strchr(key, '=')) {
    char message[512];
    snprintf(message, sizeof(message), "invalid process environment key: %s", key ? key : "");
    return fail(message);
  }
  for (int32_t index = 0; index < slot->environment_count; index++) {
    if (strcmp(slot->environment_keys[index], key) != 0) continue;
    char *replacement = strdup(value ? value : "");
    if (!replacement) return fail("could not allocate process environment value");
    free(slot->environment_values[index]);
    slot->environment_values[index] = replacement;
    return true;
  }
  if (slot->environment_count >= PHX_MAX_PROCESS_ENV)
    return fail("process environment limit exceeded");
  char *key_copy = strdup(key);
  char *value_copy = strdup(value ? value : "");
  if (!key_copy || !value_copy) {
    free(key_copy);
    free(value_copy);
    return fail("could not allocate process environment entry");
  }
  int32_t index = slot->environment_count++;
  slot->environment_keys[index] = key_copy;
  slot->environment_values[index] = value_copy;
  return true;
}

bool phx_process_start(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot) return fail("invalid or stale process handle");
  if (slot->started) return fail("process already started");
  int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
  if (!process_pipe(stdin_pipe)) return fail(strerror(errno));
  if (!process_pipe(stdout_pipe)) {
    close(stdin_pipe[0]);
    close(stdin_pipe[1]);
    return fail(strerror(errno));
  }
  if (!process_pipe(stderr_pipe)) {
    close(stdin_pipe[0]);
    close(stdin_pipe[1]);
    close(stdout_pipe[0]);
    close(stdout_pipe[1]);
    return fail(strerror(errno));
  }
  char *arguments[PHX_MAX_PROCESS_ARGS + 2];
  arguments[0] = slot->executable;
  for (int32_t index = 0; index < slot->argument_count; index++)
    arguments[index + 1] = slot->arguments[index];
  arguments[slot->argument_count + 1] = NULL;
  pid_t pid = fork();
  if (pid == 0) {
    close(stdin_pipe[1]);
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    if (dup2(stdin_pipe[0], STDIN_FILENO) < 0 ||
        dup2(stdout_pipe[1], STDOUT_FILENO) < 0 ||
        dup2(stderr_pipe[1], STDERR_FILENO) < 0) _exit(127);
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    if (slot->cwd && chdir(slot->cwd) != 0) {
      dprintf(STDERR_FILENO, "could not change process cwd: %s\n", strerror(errno));
      _exit(127);
    }
    for (int32_t index = 0; index < slot->environment_count; index++)
      if (setenv(slot->environment_keys[index], slot->environment_values[index], 1) != 0)
        _exit(127);
    execvp(slot->executable, arguments);
    dprintf(STDERR_FILENO, "could not execute %s: %s\n", slot->executable, strerror(errno));
    _exit(127);
  }
  close(stdin_pipe[0]);
  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  if (pid < 0) {
    close(stdin_pipe[1]);
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    return fail(strerror(errno));
  }
  if (fcntl(stdin_pipe[1], F_SETFL, fcntl(stdin_pipe[1], F_GETFL) | O_NONBLOCK) < 0 ||
      fcntl(stdout_pipe[0], F_SETFL, fcntl(stdout_pipe[0], F_GETFL) | O_NONBLOCK) < 0 ||
      fcntl(stderr_pipe[0], F_SETFL, fcntl(stderr_pipe[0], F_GETFL) | O_NONBLOCK) < 0) {
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    close(stdin_pipe[1]);
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    return fail(strerror(errno));
  }
  slot->pid = pid;
  slot->stdin_fd = stdin_pipe[1];
  slot->stdout_fd = stdout_pipe[0];
  slot->stderr_fd = stderr_pipe[0];
  slot->started = true;
  slot->running = true;
  return true;
}

int32_t phx_process_write(phx_handle process, const char *data, int32_t length) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot || !slot->started) { fail("invalid or unstarted process handle"); return -1; }
  if (slot->stdin_fd < 0) { fail("process stdin is closed"); return -1; }
  if (!data || length <= 0) return 0;
  long atomic_limit = fpathconf(slot->stdin_fd, _PC_PIPE_BUF);
  if (atomic_limit < 1 || length > atomic_limit) {
    fail("process stdin write exceeds atomic pipe limit");
    return -1;
  }
  ssize_t count = write(slot->stdin_fd, data, (size_t)length);
  if (count >= 0) return (int32_t)count;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
  fail(strerror(errno));
  return -1;
}

bool phx_process_close_stdin(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot || !slot->started) return fail("invalid or unstarted process handle");
  if (slot->stdin_fd >= 0) close(slot->stdin_fd);
  slot->stdin_fd = -1;
  return true;
}

int32_t phx_process_read(phx_handle process, bool standard_error,
                         char *buffer, int32_t capacity) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot) { fail("invalid or stale process handle"); return -1; }
  if (!slot->started || !buffer || capacity <= 0) return 0;
  int fd = standard_error ? slot->stderr_fd : slot->stdout_fd;
  if (fd < 0) return 0;
  ssize_t count = read(fd, buffer, (size_t)capacity);
  if (count > 0) return (int32_t)count;
  if (count == 0) {
    close(fd);
    if (standard_error) slot->stderr_fd = -1; else slot->stdout_fd = -1;
    return 0;
  }
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
  fail(strerror(errno));
  return -1;
}

int32_t phx_process_state(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot || !slot->started) return 0;
  reap_process(slot);
  return slot->running ? 1 : 2;
}

int32_t phx_process_exit_status(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot || !slot->started) { fail("invalid or unstarted process handle"); return -1; }
  reap_process(slot);
  return slot->running ? -1 : slot->exit_status;
}

bool phx_process_cancel(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot || !slot->started) return fail("invalid or unstarted process handle");
  reap_process(slot);
  if (!slot->running) return true;
  return kill(slot->pid, SIGTERM) == 0 || errno == ESRCH;
}

bool phx_process_destroy(phx_handle process) {
  phx_process_slot *slot = resolve_process(process);
  if (!slot) return fail("invalid or stale process handle");
  terminate_process(slot);
  close_process_pipes(slot);
  free_process_configuration(slot);
  slot->occupied = false;
  return true;
}
