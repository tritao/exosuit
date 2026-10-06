#include <emscripten.h>
#include <stdint.h>
#include <stdlib.h>

EM_JS(int, noisekit_fill_random, (uint8_t *bytes, size_t size), {
    try {
        if (!globalThis.crypto || typeof globalThis.crypto.getRandomValues !== "function")
            return 0;
        const view = HEAPU8.subarray(bytes, bytes + size);
        for (let offset = 0; offset < view.length; offset += 65536)
            globalThis.crypto.getRandomValues(view.subarray(offset, Math.min(offset + 65536, view.length)));
        return 1;
    } catch (_) {
        return 0;
    }
});

void noise_rand_bytes(void *bytes, size_t size)
{
    if (!bytes || !noisekit_fill_random((uint8_t *)bytes, size))
        abort();
}
