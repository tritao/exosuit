#include <stdint.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincodec.h>
#include <objidl.h>
#include <cstring>
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

#ifdef _WIN32
static int encode_bitmap(HBITMAP bitmap, uint8_t *output, int capacity) {
    BITMAP info = {};
    if (!bitmap || !output || capacity <= 0 || !GetObject(bitmap, sizeof(info), &info) || info.bmWidth <= 0 || info.bmHeight <= 0 ||
        info.bmWidth > 4096 || info.bmHeight > 4096 || (int64_t)info.bmWidth * info.bmHeight > 16777216) return -1;
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IWICImagingFactory *factory = nullptr; IWICBitmap *source = nullptr;
    IWICBitmapEncoder *encoder = nullptr; IWICBitmapFrameEncode *frame = nullptr;
    IStream *stream = nullptr; IPropertyBag2 *properties = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source);
    if (SUCCEEDED(hr)) hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (SUCCEEDED(hr)) hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &properties);
    if (SUCCEEDED(hr)) hr = frame->Initialize(properties);
    if (SUCCEEDED(hr)) hr = frame->SetSize((UINT)info.bmWidth, (UINT)info.bmHeight);
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(source, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    int result = -2;
    if (SUCCEEDED(hr)) {
        STATSTG stat = {}; hr = stream->Stat(&stat, STATFLAG_NONAME);
        if (SUCCEEDED(hr) && stat.cbSize.HighPart == 0 && stat.cbSize.LowPart > 0) {
            ULONG size = stat.cbSize.LowPart;
            if (size > (ULONG)capacity) result = -1;
            else { LARGE_INTEGER zero = {}; ULONG read = 0;
                if (SUCCEEDED(stream->Seek(zero, STREAM_SEEK_SET, nullptr)) && SUCCEEDED(stream->Read(output, size, &read)) && read == size) result = (int)size;
            }
        }
    }
    if (properties) properties->Release(); if (frame) frame->Release(); if (encoder) encoder->Release();
    if (stream) stream->Release(); if (source) source->Release(); if (factory) factory->Release();
    if (SUCCEEDED(init)) CoUninitialize(); return result;
}
#endif

// Returns zero when no image is present (including ordinary text), a positive
// PNG byte count, or a negative value for an image that could not be pasted.
EXPORT int exosuit_clipboard_image(uint8_t *output, int capacity) {
#ifdef _WIN32
    if (!output || capacity <= 0 || !OpenClipboard(nullptr)) return 0;
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) { CloseClipboard(); return 0; }
    UINT png = RegisterClipboardFormatW(L"PNG");
    if (png && IsClipboardFormatAvailable(png)) {
        HGLOBAL data = (HGLOBAL)GetClipboardData(png);
        SIZE_T size = data ? GlobalSize(data) : 0;
        if (!size || size > (SIZE_T)capacity) { CloseClipboard(); return -1; }
        void *p = GlobalLock(data);
        if (!p) { CloseClipboard(); return -2; }
        memcpy(output, p, size); GlobalUnlock(data); CloseClipboard(); return (int)size;
    }
    if (!IsClipboardFormatAvailable(CF_BITMAP)) { CloseClipboard(); return 0; }
    HBITMAP original = (HBITMAP)GetClipboardData(CF_BITMAP);
    BITMAP info = {};
    if (!original || !GetObject(original, sizeof(info), &info) || info.bmWidth <= 0 || info.bmHeight <= 0 ||
        info.bmWidth > 4096 || info.bmHeight > 4096 || (int64_t)info.bmWidth * info.bmHeight > 16777216) {
        CloseClipboard(); return -1;
    }
    HBITMAP bitmap = (HBITMAP)CopyImage(original, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION);
    CloseClipboard();
    if (!bitmap) return -2;
    int result = encode_bitmap(bitmap, output, capacity);
    DeleteObject(bitmap); return result;
#else
    (void)output; (void)capacity; return 0;
#endif
}
