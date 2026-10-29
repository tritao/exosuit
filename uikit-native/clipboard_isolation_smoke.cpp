// Clipboard ownership is per window station. This fixture proves station and desktop
// identity before any clipboard operation and never touches the interactive station.
// https://learn.microsoft.com/en-us/windows/win32/winstation/about-window-stations-and-desktops
// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocesswindowstation
#include "clipboard.cpp"
#include <cstdio>
#include <vector>
#include <cwchar>
extern "C" int exosuit_image_thumbnail(const uint8_t *, int, uint8_t *, int);

static HBITMAP makeBitmap() {
    BITMAPINFO bi = {}; bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth=3;
    bi.bmiHeader.biHeight=-2; bi.bmiHeader.biPlanes=1; bi.bmiHeader.biBitCount=32; bi.bmiHeader.biCompression=BI_RGB;
    void *bits=nullptr; HBITMAP bmp=CreateDIBSection(nullptr,&bi,DIB_RGB_COLORS,&bits,nullptr,0);
    if (!bmp || !bits) return nullptr;
    auto *p=(uint8_t*)bits;
    for (int i=0;i<6;i++) { p[i*4]=10+i; p[i*4+1]=20+i; p[i*4+2]=30+i; p[i*4+3]=255; }
    return bmp;
}
static bool sameName(HANDLE object, const wchar_t *expected) {
    wchar_t name[128] = {}; DWORD required=0;
    return GetUserObjectInformationW(object, UOI_NAME, name, sizeof(name), &required) && wcscmp(name,expected)==0;
}
static bool putBitmap(HWND owner) {
    if (!OpenClipboard(owner)) return false;
    bool ok=EmptyClipboard()!=0; HBITMAP bmp=makeBitmap();
    if (!bmp) ok=false;
    if (bmp && !SetClipboardData(CF_BITMAP,bmp)) { DeleteObject(bmp); ok=false; }
    CloseClipboard(); return ok;
}
static bool putPng(HWND owner, const uint8_t *bytes, int size) {
    if (!OpenClipboard(owner)) return false;
    bool ok=EmptyClipboard()!=0; HGLOBAL data=GlobalAlloc(GMEM_MOVEABLE, size);
    void *p=data ? GlobalLock(data) : nullptr;
    if (!p) ok=false; else { memcpy(p,bytes,size); GlobalUnlock(data); }
    UINT png=RegisterClipboardFormatW(L"PNG");
    if (!ok || !png || !SetClipboardData(png,data)) { if(data) GlobalFree(data); ok=false; }
    CloseClipboard(); return ok;
}
static bool putText(HWND owner) {
    if (!OpenClipboard(owner)) return false;
    bool ok=EmptyClipboard()!=0; HGLOBAL data=GlobalAlloc(GMEM_MOVEABLE, 12);
    void *p=data ? GlobalLock(data) : nullptr;
    if (!p) ok=false; else { memcpy(p,L"hello",12); GlobalUnlock(data); }
    if (!ok || !SetClipboardData(CF_UNICODETEXT,data)) { if(data) GlobalFree(data); ok=false; }
    HBITMAP bmp=makeBitmap(); if (!bmp || !SetClipboardData(CF_BITMAP,bmp)) { if(bmp) DeleteObject(bmp); ok=false; }
    CloseClipboard(); return ok;
}
int main() {
    HWINSTA oldStation=GetProcessWindowStation(); HDESK oldDesktop=GetThreadDesktop(GetCurrentThreadId());
    wchar_t name[80]; swprintf_s(name,L"ExosuitClipboardSmoke-%lu",GetCurrentProcessId());
    HWINSTA station=CreateWindowStationW(name,0,WINSTA_ALL_ACCESS,nullptr);
    if (!station) { std::printf("SKIP: CreateWindowStation failed (%lu)\n", GetLastError()); return 0; }
    if (!SetProcessWindowStation(station)) { DWORD error=GetLastError(); CloseWindowStation(station); std::printf("SKIP: SetProcessWindowStation failed (%lu)\n", error); return 0; }
    HDESK desktop=CreateDesktopW(L"ExosuitClipboardTest",nullptr,nullptr,0,GENERIC_ALL,nullptr);
    bool isolated=desktop && SetThreadDesktop(desktop) && GetProcessWindowStation()==station
        && sameName(GetProcessWindowStation(),name) && sameName(GetThreadDesktop(GetCurrentThreadId()),L"ExosuitClipboardTest");
    if (!isolated) { SetThreadDesktop(oldDesktop); SetProcessWindowStation(oldStation); if(desktop) CloseDesktop(desktop); CloseWindowStation(station); std::puts("SKIP: private desktop isolation unavailable"); return 0; }
    HWND owner=CreateWindowExW(0,L"STATIC",L"",0,0,0,1,1,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    bool ok=owner != nullptr;
    std::vector<uint8_t> result(2*1024*1024), thumbnail(96*96*4);
    HBITMAP bmp=makeBitmap(); int pngSize=bmp ? encode_bitmap(bmp,result.data(),(int)result.size()) : 0; if(bmp) DeleteObject(bmp);
    std::vector<uint8_t> png(result.begin(),result.begin()+(pngSize>0?pngSize:0));
    if(ok) ok=pngSize>0 && putPng(owner,png.data(),pngSize);
    int read=ok ? exosuit_clipboard_image(result.data(),(int)result.size()) : 0;
    ok=ok && read==pngSize && memcmp(result.data(),png.data(),pngSize)==0;
    if(ok) ok=putBitmap(owner);
    read=ok ? exosuit_clipboard_image(result.data(),(int)result.size()) : 0;
    int dimensions=read>0 ? exosuit_image_thumbnail(result.data(),read,thumbnail.data(),(int)thumbnail.size()) : 0;
    ok=ok && dimensions==((3<<16)|2) && thumbnail[0]==30 && thumbnail[1]==20 && thumbnail[2]==10;
    if(ok) ok=putText(owner) && exosuit_clipboard_image(result.data(),(int)result.size())==0;
    // The isolation checks above precede every clipboard operation in this process.
    if(owner) { if(OpenClipboard(owner)) { EmptyClipboard(); CloseClipboard(); } DestroyWindow(owner); }
    SetThreadDesktop(oldDesktop); SetProcessWindowStation(oldStation); CloseDesktop(desktop); CloseWindowStation(station);
    if(!ok) { std::fprintf(stderr,"FAIL: isolated clipboard PNG, bitmap, or text routing\n"); return 1; }
    std::puts("PASS: private clipboard PNG, bitmap conversion, and text precedence"); return 0;
}
