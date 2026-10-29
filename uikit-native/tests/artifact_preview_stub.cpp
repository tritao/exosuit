#include <stdint.h>
extern "C" int exosuit_artifact_preview_available();
extern "C" int exosuit_artifact_preview_open(uint32_t, const char *);
int main() {
    return exosuit_artifact_preview_available() == 0 && exosuit_artifact_preview_open(0, "<p>test</p>") == 0 ? 0 : 1;
}
