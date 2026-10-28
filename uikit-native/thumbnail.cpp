#include <stdint.h>
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_MAX_DIMENSIONS 4096
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#ifdef _WIN32
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif
// Outputs tightly packed RGBA, returning width and height packed into an int.
// Input and both decoded and output dimensions are bounded before allocation.
EXPORT int exosuit_image_thumbnail(const uint8_t *input, int length, uint8_t *output, int capacity) {
    if (!input || !output || length <= 0 || length > 2*1024*1024 || capacity < 96*96*4) return 0;
    int w=0,h=0,channels=0;
    if (!stbi_info_from_memory(input,length,&w,&h,&channels) || w <= 0 || h <= 0 || w > 4096 || h > 4096 || (int64_t)w*h > 16777216) return 0;
    int actualW=0,actualH=0;
    unsigned char *pixels = stbi_load_from_memory(input,length,&actualW,&actualH,&channels,4);
    if (!pixels) return 0;
    if (actualW != w || actualH != h) { stbi_image_free(pixels); return 0; }
    int maxSide = w > h ? w : h;
    int tw = w <= 96 && h <= 96 ? w : (w*96 + maxSide/2)/maxSide;
    int th = w <= 96 && h <= 96 ? h : (h*96 + maxSide/2)/maxSide;
    if (tw < 1) tw=1; if (th < 1) th=1;
    for (int y=0;y<th;y++) for (int x=0;x<tw;x++) {
        int sx=(int)((int64_t)x*w/tw), sy=(int)((int64_t)y*h/th);
        int src=(sy*w+sx)*4, dst=(y*tw+x)*4;
        for (int c=0;c<4;c++) output[dst+c]=pixels[src+c];
    }
    stbi_image_free(pixels); return (tw<<16)|th;
}
