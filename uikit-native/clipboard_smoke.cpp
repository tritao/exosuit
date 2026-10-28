// Tests the same encoder used by clipboard paste without reading or writing the OS clipboard.
#include "clipboard.cpp"
#include <vector>
#include <cstdio>
extern "C" int exosuit_image_thumbnail(const uint8_t *, int, uint8_t *, int);

static bool check(int width, int height, bool topdown) {
    BITMAPINFO bi = {}; bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = width; bi.bmiHeader.biHeight = topdown ? -height : height;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    void *raw = nullptr; HBITMAP bitmap = CreateDIBSection(nullptr, &bi, DIB_RGB_COLORS, &raw, nullptr, 0);
    if (!bitmap || !raw) return false;
    auto *pixels = (uint8_t*)raw;
    for (int y=0; y<height; ++y) for (int x=0; x<width; ++x) {
        int row = topdown ? y : height-1-y, offset = (row*width+x)*4;
        pixels[offset] = (uint8_t)(20+x); pixels[offset+1] = (uint8_t)(40+y);
        pixels[offset+2] = (uint8_t)(80+x+y); pixels[offset+3] = 255;
    }
    std::vector<uint8_t> data(2*1024*1024);
    int size = encode_bitmap(bitmap, data.data(), (int)data.size());
    uint8_t tiny[2] = {0x44, 0x55};
    bool ok = size > 0 && encode_bitmap(bitmap, tiny, 1) == -1 && tiny[1] == 0x55;
    DeleteObject(bitmap);
    std::vector<uint8_t> thumbnail(96*96*4);
    int packed = exosuit_image_thumbnail(data.data(), size, thumbnail.data(), (int)thumbnail.size());
    int maxSide = width > height ? width : height;
    int tw = maxSide <= 96 ? width : (width*96 + maxSide/2)/maxSide;
    int th = maxSide <= 96 ? height : (height*96 + maxSide/2)/maxSide;
    if (tw < 1) tw=1; if (th < 1) th=1;
    ok = ok && (packed >> 16) == tw && (packed & 65535) == th;
    for (int y=0; ok && y<th; ++y) for (int x=0; x<tw; ++x) {
        int sx=x*width/tw, sy=y*height/th, i=(y*tw+x)*4;
        if (thumbnail[i] != (uint8_t)(80+sx+sy) || thumbnail[i+1] != (uint8_t)(40+sy) || thumbnail[i+2] != (uint8_t)(20+sx) || thumbnail[i+3] != 255) ok = false;
    }
    if (!ok) return false;
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IWICImagingFactory *factory = nullptr; IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr; IWICFormatConverter *converter = nullptr; IStream *stream = nullptr;
    HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream); ULONG written = 0;
    if (SUCCEEDED(hr)) hr = stream->Write(data.data(), size, &written);
    LARGE_INTEGER zero = {}; if (SUCCEEDED(hr)) hr = stream->Seek(zero, STREAM_SEEK_SET, nullptr);
    if (SUCCEEDED(hr)) hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    UINT w=0,h=0; if (SUCCEEDED(hr)) hr = frame->GetSize(&w,&h);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr = converter->Initialize(frame, GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    std::vector<uint8_t> decoded(width*height*3);
    if (SUCCEEDED(hr)) hr = converter->CopyPixels(nullptr, width*3, (UINT)decoded.size(), decoded.data());
    ok = SUCCEEDED(hr) && written == (ULONG)size && w == (UINT)width && h == (UINT)height;
    for (int y=0; ok && y<height; ++y) for (int x=0; x<width; ++x) {
        int i = (y*width+x)*3;
        if (decoded[i] != (uint8_t)(20+x) || decoded[i+1] != (uint8_t)(40+y) || decoded[i+2] != (uint8_t)(80+x+y)) ok = false;
    }
    if (converter) converter->Release(); if (frame) frame->Release(); if (decoder) decoder->Release();
    if (factory) factory->Release(); if (stream) stream->Release(); if (SUCCEEDED(init)) CoUninitialize();
    return ok;
}
int main() {
    BITMAPINFO bi = {}; bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth=4097;
    bi.bmiHeader.biHeight=1; bi.bmiHeader.biPlanes=1; bi.bmiHeader.biBitCount=32; bi.bmiHeader.biCompression=BI_RGB;
    void *pixels=nullptr; HBITMAP tooWide=CreateDIBSection(nullptr,&bi,DIB_RGB_COLORS,&pixels,nullptr,0);
    uint8_t output[32] = {}; bool bounded = tooWide && encode_bitmap(tooWide,output,sizeof(output)) == -1;
    if (tooWide) DeleteObject(tooWide);
    uint8_t invalid[16] = {};
    uint8_t thumb[96*96*4] = {};
    bounded = bounded && exosuit_image_thumbnail(invalid, sizeof(invalid), thumb, sizeof(thumb)) == 0
        && exosuit_image_thumbnail(invalid, 2*1024*1024+1, thumb, sizeof(thumb)) == 0
        && exosuit_image_thumbnail(invalid, sizeof(invalid), thumb, 1) == 0;
    if (!bounded || !check(2,2,false) || !check(3,2,false) || !check(3,2,true) || !check(200,100,true)) {
        std::fprintf(stderr,"FAIL: clipboard bitmap PNG codec\n"); return 1;
    }
    std::puts("PASS: clipboard PNG and thumbnail codec pixels, scaling, orientation and bounds"); return 0;
}

