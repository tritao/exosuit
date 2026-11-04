/*
 * JNI side of com.exosuit.mobile.HaxeonRuntime: loads the Haxe module (ui.hl) into the HashLink runtime and forwards
 * the Activity's commands to UiBridge.commandJSON. It also creates the NativeKit GLES surface for the Activity's view.
 * One module, one runtime; every entry point runs on the Activity's UI thread.
 */
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>
#include <hl.h>
#include <hlmodule.h>
#include <nativekit.h>
#include <nativekit_graphics.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define TAG "ExosuitJNI"
#define COMMAND_LIMIT 65536
#define ASSET_LIMIT (64 * 1024 * 1024)
#define ENTRY_INIT 0
#define ENTRY_COMMAND 1
#define ENTRY_REQUEST 2
#define ENTRY_COUNT 3
/* Optional live-patch hooks (UiBridge.liveRelease / liveRebuild), lines 4 and 5 of ui.entries; -1 when absent. */
#define HOOK_RELEASE 0
#define HOOK_REBUILD 1
#define REQUEST_CAPACITY (256 * 1024)

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static hl_runtime_module *module;
static int entries[ENTRY_COUNT];
static int hooks[2] = {-1, -1};
static int runtime_ready;
static vbyte *request_buffer;

static int read_asset(AAssetManager *manager, const char *name, int limit, unsigned char **out, int *length) {
    AAsset *asset = AAssetManager_open(manager, name, AASSET_MODE_BUFFER);
    if (!asset) return 0;
    off_t size = AAsset_getLength(asset);
    if (size <= 0 || size > limit) { AAsset_close(asset); return 0; }
    unsigned char *data = malloc((size_t)size + 1);
    if (!data) { AAsset_close(asset); return 0; }
    off_t total = 0;
    while (total < size) {
        int count = AAsset_read(asset, data + total, (size_t)(size - total));
        if (count <= 0) { free(data); AAsset_close(asset); return 0; }
        total += count;
    }
    AAsset_close(asset);
    data[size] = 0;
    *out = data;
    *length = (int)size;
    return 1;
}

/* Debug builds only: the Activity passes <files>/dev when the app is debuggable; a file there replaces the APK asset
 * (scripts/dev.ps1 pushes a fresh ui.hl without rebuilding the APK). Release builds pass NULL. */
static int read_file(const char *directory, const char *name, int limit, unsigned char **out, int *length) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/%s", directory, name) >= (int)sizeof path) return 0;
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return 0; }
    long size = ftell(file);
    if (size <= 0 || size > limit || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return 0; }
    unsigned char *data = malloc((size_t)size + 1);
    if (!data) { fclose(file); return 0; }
    if (fread(data, 1, (size_t)size, file) != (size_t)size) { free(data); fclose(file); return 0; }
    fclose(file);
    data[size] = 0;
    *out = data;
    *length = (int)size;
    __android_log_print(ANDROID_LOG_INFO, TAG, "%s loaded from %s", name, directory);
    return 1;
}

static int read_source(AAssetManager *manager, const char *directory, const char *name, int limit, unsigned char **out, int *length) {
    if (directory && read_file(directory, name, limit, out, length)) return 1;
    return read_asset(manager, name, limit, out, length);
}

/* ui.entries holds one decimal entry id per line, in the order of the ENTRY_ constants, then optionally the two live hooks. */
static int parse_entries(const unsigned char *text, int length, int *out, int *hook_out) {
    int at = 0;
    hook_out[0] = hook_out[1] = -1;
    for (int k = 0; k < ENTRY_COUNT + 2; k++) {
        if (k >= ENTRY_COUNT && at == length) break;
        unsigned value = 0;
        int digits = 0;
        while (at < length && text[at] >= '0' && text[at] <= '9') {
            unsigned digit = text[at++] - '0';
            if (value > ((unsigned)INT_MAX - digit) / 10) return 0;
            value = value * 10 + digit;
            digits++;
        }
        if (!digits || at >= length || text[at++] != '\n') return 0;
        if (k < ENTRY_COUNT) out[k] = (int)value; else hook_out[k - ENTRY_COUNT] = (int)value;
    }
    return at == length;
}

/* Registers the calling thread with HashLink if it is not yet known; returns 1 when the caller must unregister it. */
static int register_thread(int *marker) {
    if (hl_get_thread()) return 0;
    hl_register_thread(marker);
    return 1;
}

JNIEXPORT jint JNICALL Java_com_exosuit_mobile_HaxeonRuntime_load(JNIEnv *env, jobject self, jobject asset_manager, jstring override_directory) {
    (void)self;
    AAssetManager *assets = asset_manager ? AAssetManager_fromJava(env, asset_manager) : NULL;
    const char *override_path = override_directory ? (*env)->GetStringUTFChars(env, override_directory, NULL) : NULL;
    unsigned char *code = NULL, *identity = NULL, *entry_text = NULL;
    int code_size = 0, identity_size = 0, entry_size = 0, parsed[ENTRY_COUNT], parsed_hooks[2], marker = 0, registered = 0;
    jint answer = -1;
    if (!assets || !read_source(assets, override_path, "ui.hl", ASSET_LIMIT, &code, &code_size) ||
        !read_source(assets, override_path, "ui.hli", ASSET_LIMIT, &identity, &identity_size) ||
        !read_source(assets, override_path, "ui.entries", 1024, &entry_text, &entry_size) || !parse_entries(entry_text, entry_size, parsed, parsed_hooks)) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "ui.hl, ui.hli or ui.entries is missing or malformed");
        goto cleanup;
    }
    pthread_mutex_lock(&lock);
    if (module) goto unlock;
    if (!runtime_ready) {
        hl_global_init();
        hl_setup.file_path = (pchar *)"ui.hl";
        hl_setup.sys_args = NULL;
        hl_setup.sys_nargs = 0;
        hl_sys_init();
        runtime_ready = 1;
    }
    registered = register_thread(&marker);
    hl_runtime_status status = hl_runtime_module_load(code, code_size, identity, identity_size, &module);
    if (status != HL_RUNTIME_OK || !module) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "module load failed (status %d)", (int)status);
        module = NULL;
    } else {
        vdynamic *exception = NULL;
        status = hl_runtime_module_call_void(module, parsed[ENTRY_INIT], &exception);
        if (status == HL_RUNTIME_OK) {
            memcpy(entries, parsed, sizeof(entries));
            memcpy(hooks, parsed_hooks, sizeof(hooks));
            answer = 0;
        } else {
            __android_log_print(ANDROID_LOG_ERROR, TAG, "module init failed (status %d)", (int)status);
            if (hl_runtime_module_release(module) == HL_RUNTIME_OK) module = NULL;
        }
    }
    if (registered) hl_unregister_thread();
unlock:
    pthread_mutex_unlock(&lock);
cleanup:
    if (override_path) (*env)->ReleaseStringUTFChars(env, override_directory, override_path);
    free(code);
    free(identity);
    free(entry_text);
    return answer;
}

/* Sends one JSON command (UiBridge.commandJSON); returns its result, or -1 if the runtime rejected the call. */
JNIEXPORT jint JNICALL Java_com_exosuit_mobile_HaxeonRuntime_command(JNIEnv *env, jobject self, jbyteArray json) {
    (void)self;
    if (!json) return -1;
    jsize n = (*env)->GetArrayLength(env, json);
    if (n < 0 || n > COMMAND_LIMIT) return -1;
    pthread_mutex_lock(&lock);
    jint answer = -1;
    if (module) {
        int marker = 0, registered = register_thread(&marker);
        /* hl.Bytes argument: 4-byte big-endian length, then the JSON text. */
        vbyte *bytes = hl_alloc_bytes(n + 4);
        hl_add_root(&bytes);
        bytes[0] = (vbyte)(n >> 24); bytes[1] = (vbyte)(n >> 16); bytes[2] = (vbyte)(n >> 8); bytes[3] = (vbyte)n;
        if (n) (*env)->GetByteArrayRegion(env, json, 0, n, (jbyte *)(bytes + 4));
        vdynamic *box = hl_alloc_dynamic(&hlt_bytes);
        hl_add_root(&box);
        box->v.bytes = bytes;
        vdynamic *exception = NULL;
        int code = 0;
        hl_runtime_status status = hl_runtime_module_call_i32_object(module, entries[ENTRY_COMMAND], box, &code, &exception);
        answer = status == HL_RUNTIME_OK ? code : -1;
        hl_remove_root(&box);
        hl_remove_root(&bytes);
        if (registered) hl_unregister_thread();
    }
    pthread_mutex_unlock(&lock);
    return answer;
}

/*
 * The next request the Haxe module has for the host (UiBridge.takeHostRequest), or null. The buffer is allocated once and
 * wiped after each copy: requests can carry credentials.
 */
JNIEXPORT jbyteArray JNICALL Java_com_exosuit_mobile_HaxeonRuntime_takeRequest(JNIEnv *env, jobject self) {
    (void)self;
    jbyteArray out = NULL;
    pthread_mutex_lock(&lock);
    if (module) {
        int marker = 0, registered = register_thread(&marker);
        if (!request_buffer) {
            request_buffer = hl_alloc_bytes(REQUEST_CAPACITY);
            hl_add_root(&request_buffer);
        }
        request_buffer[0] = (vbyte)(REQUEST_CAPACITY >> 24); request_buffer[1] = (vbyte)(REQUEST_CAPACITY >> 16);
        request_buffer[2] = (vbyte)(REQUEST_CAPACITY >> 8); request_buffer[3] = (vbyte)REQUEST_CAPACITY;
        vdynamic *box = hl_alloc_dynamic(&hlt_bytes);
        hl_add_root(&box);
        box->v.bytes = request_buffer;
        vdynamic *exception = NULL;
        int length = 0;
        hl_runtime_status status = hl_runtime_module_call_i32_object(module, entries[ENTRY_REQUEST], box, &length, &exception);
        if (status == HL_RUNTIME_OK && length > 0 && length <= REQUEST_CAPACITY - 4) {
            out = (*env)->NewByteArray(env, length);
            if (out) (*env)->SetByteArrayRegion(env, out, 0, length, (jbyte *)(request_buffer + 4));
            memset(request_buffer + 4, 0, (size_t)length);
        }
        hl_remove_root(&box);
        if (registered) hl_unregister_thread();
    }
    pthread_mutex_unlock(&lock);
    return out;
}

/*
 * Debug builds: applies one live patch (HLP bytes made by the desktop's `haxeon build --live`) to the running module
 * without restarting. liveRelease runs first (lets go of what the UI holds), liveRebuild after (draws from the new code),
 * as haxeon's LiveHost does. Returns the runtime status (0 = applied), -1 when there is no module; `message` (may be NULL)
 * is filled with the runtime's reason in the log only.
 */
JNIEXPORT jint JNICALL Java_com_exosuit_mobile_HaxeonRuntime_patch(JNIEnv *env, jobject self, jbyteArray hlp) {
    (void)self;
    if (!hlp) return -1;
    jsize n = (*env)->GetArrayLength(env, hlp);
    if (n <= 0 || n > ASSET_LIMIT) return -1;
    unsigned char *bytes = malloc((size_t)n);
    if (!bytes) return -1;
    (*env)->GetByteArrayRegion(env, hlp, 0, n, (jbyte *)bytes);
    pthread_mutex_lock(&lock);
    jint answer = -1;
    if (module) {
        int marker = 0, registered = register_thread(&marker);
        vdynamic *exception = NULL;
        if (hooks[HOOK_RELEASE] >= 0) hl_runtime_module_call_void(module, hooks[HOOK_RELEASE], &exception);
        hl_runtime_status status = hl_runtime_module_apply_hlp(module, bytes, (int)n);
        if (hooks[HOOK_REBUILD] >= 0) hl_runtime_module_call_void(module, hooks[HOOK_REBUILD], &exception);
        if (status != HL_RUNTIME_OK) {
            const uchar *message = hl_runtime_module_patch_message(module);
            char text[256] = {0};
            for (int i = 0; message && message[i] && i < 255; i++) text[i] = (char)(message[i] < 128 ? message[i] : '?');
            __android_log_print(ANDROID_LOG_ERROR, TAG, "patch rejected (status %d): %s", (int)status, text);
        }
        answer = (jint)status;
        if (registered) hl_unregister_thread();
    }
    pthread_mutex_unlock(&lock);
    free(bytes);
    return answer;
}

/* The runtime stays initialised after dispose: repeated hl_global_init/free across threads is not safe. */
JNIEXPORT jint JNICALL Java_com_exosuit_mobile_HaxeonRuntime_dispose(JNIEnv *env, jobject self) {
    (void)env; (void)self;
    pthread_mutex_lock(&lock);
    jint answer = 0;
    if (module) {
        int marker = 0, registered = register_thread(&marker);
        if (hl_runtime_module_release(module) == HL_RUNTIME_OK) module = NULL; else answer = -1;
        if (registered) hl_unregister_thread();
    }
    pthread_mutex_unlock(&lock);
    return answer;
}

/* A GLES 3 surface on the NativeKit host (NativeKitHost.handle()). Returns the surface id, or 0. */
JNIEXPORT jlong JNICALL Java_com_exosuit_mobile_HaxeonRuntime_createSurface(JNIEnv *env, jobject self, jlong host, jint width, jint height) {
    (void)env; (void)self;
    if (host <= 0 || (uint64_t)host > UINT32_MAX || width <= 0 || height <= 0) return 0;
    nk_surface_options options = {0};
    nk_surface surface = NK_INVALID_HANDLE;
    options.struct_size = sizeof(options);
    options.api = NK_GRAPHICS_OPENGL_ES;
    options.major_version = 3;
    options.flags = NK_SURFACE_STENCIL;
    options.width = width;
    options.height = height;
    return nk_surface_create((nk_handle)host, &options, &surface) == NK_OK ? (jlong)surface : 0;
}

JNIEXPORT jint JNICALL Java_com_exosuit_mobile_HaxeonRuntime_resizeSurface(JNIEnv *env, jobject self, jlong surface, jint width, jint height) {
    (void)env; (void)self;
    if (surface <= 0 || (uint64_t)surface > UINT32_MAX || width <= 0 || height <= 0) return -1;
    return (jint)nk_surface_set_bounds((nk_surface)surface, 0, 0, width, height);
}
