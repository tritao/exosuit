#define SDL_MAIN_USE_CALLBACKS
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <hl.h>
#include <hlmodule.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pragtical_hx/host.h"
#include "pragtical_hx/platform.h"
#include "platform_sdl.h"

typedef struct phx_host {
  hl_code *code;
  hl_module *module;
  char *module_path;
  bool haxeon_started;
  bool haxeon_stopped;
} phx_host;

static hl_code *load_code(const char *path) {
  FILE *file = fopen(path, "rb");
  char *error = NULL;
  unsigned char *bytes;
  long size;
  hl_code *code;
  if (!file) return NULL;
  if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
      fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  bytes = malloc((size_t)size);
  if (!bytes || fread(bytes, 1, (size_t)size, file) != (size_t)size) {
    free(bytes);
    fclose(file);
    return NULL;
  }
  fclose(file);
  code = hl_code_read(bytes, (int)size, &error);
  free(bytes);
  if (!code && error) fprintf(stderr, "%s\n", error);
  return code;
}

static bool start_haxeon(phx_host *host, int argc, char **argv) {
  const char *base_path;
  static const char module_name[] = "pragtical-haxeon.hl";
  vclosure entry;
  vdynamic *result;
  bool raised = false;
  base_path = SDL_GetBasePath();
  if (!base_path) return false;
  host->module_path = malloc(strlen(base_path) + sizeof(module_name));
  if (!host->module_path) return false;
  snprintf(host->module_path, strlen(base_path) + sizeof(module_name), "%s%s",
           base_path, module_name);
  hl_setup.file_path = host->module_path;
  hl_setup.sys_args = (pchar **)(argv + 1);
  hl_setup.sys_nargs = argc - 1;
  hl_sys_init();
  host->code = load_code(hl_setup.file_path);
  if (!host->code) return false;
  host->module = hl_module_alloc(host->code);
  if (!host->module || !hl_module_init(host->module, HL_MODULE_PATCHABLE))
    return false;
  hl_code_free_function_data(host->code);
  entry.t = host->code->functions[
    host->module->functions_indexes[host->module->code->entrypoint]].type;
  entry.fun = host->module->functions_ptrs[host->module->code->entrypoint];
  entry.hasValue = 0;
  result = hl_dyn_call_safe(&entry, NULL, 0, &raised);
  if (raised) {
    hl_print_uncaught_exception(result);
    return false;
  }
  host->haxeon_started = true;
  return phx_haxeon_callbacks_ready();
}

SDL_AppResult SDL_AppInit(void **appstate, int argc, char **argv) {
  phx_host *host = calloc(1, sizeof(*host));
  void *stack_top = host;
  if (!host) return SDL_APP_FAILURE;
  *appstate = host;
  hl_global_init();
  hl_register_thread(&stack_top);
  SDL_SetAppMetadata("Pragtical Haxeon", NULL, "dev.pragtical.haxeon");
  if (!phx_platform_init(false)) {
    fprintf(stderr, "Platform initialization failed: %s\n", phx_platform_last_error());
    return SDL_APP_FAILURE;
  }
  if (!start_haxeon(host, argc, argv)) {
    fprintf(stderr, "Haxeon initialization failed\n");
    return SDL_APP_FAILURE;
  }
  return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event) {
  (void)appstate;
  if (phx_event_push_sdl(event) && !phx_haxeon_event()) return SDL_APP_FAILURE;
  return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void *appstate) {
  bool keep_running = false;
  (void)appstate;
  if (!phx_haxeon_iterate(&keep_running)) return SDL_APP_FAILURE;
  if (keep_running) SDL_Delay(16);
  return keep_running ? SDL_APP_CONTINUE : SDL_APP_SUCCESS;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result) {
  phx_host *host = appstate;
  (void)result;
  if (host && host->haxeon_started && !host->haxeon_stopped) {
    phx_haxeon_quit();
    host->haxeon_stopped = true;
  }
  phx_platform_shutdown();
  if (host) {
    if (host->module) hl_module_free_shutdown(host->module);
    hl_code_destroy(host->code);
    free(host->module_path);
    free(host);
  }
  hl_global_free();
}
