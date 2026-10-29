// Windows-only inert artifact preview. This file is not connected to the UI
// until the platform boundary probes have verified every policy below.
#if defined(_WIN32) && defined(EXOSUIT_WEBVIEW2)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wrl.h>
#include <WebView2.h>
#include <memory>
#include <string>
#ifdef EXOSUIT_PREVIEW_TESTING
#include <cstdio>
#endif
#include <nativekit_window.h>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
#ifdef EXOSUIT_PREVIEW_TESTING
static int preview_test_result = 0;
extern "C" __declspec(dllexport) int exosuit_artifact_preview_test_result() { return preview_test_result; }
#endif

namespace {
struct Preview {
    HWND window = nullptr;
    bool closed = false;
    bool initial_navigation = true;
    bool initial_frame = true;
    bool com_initialized = false;
    std::wstring document;
    std::wstring initial_uri;
    std::wstring source_base64;
    ComPtr<ICoreWebView2Environment> environment;
    ComPtr<ICoreWebView2Controller> controller;
};
using PreviewPtr = std::shared_ptr<Preview>;

void fail(const PreviewPtr &p) {
    if (p->closed) return;
    MessageBoxW(p->window, L"The isolated artifact preview could not be started. Source remains available in the conversation.", L"Artifact preview unavailable", MB_OK | MB_ICONWARNING);
    DestroyWindow(p->window);
}

LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
    auto *owner = reinterpret_cast<PreviewPtr *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        owner = static_cast<PreviewPtr *>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(owner));
    }
    if (owner && message == WM_SIZE && (*owner)->controller) {
        RECT bounds{}; GetClientRect(hwnd, &bounds); (*owner)->controller->put_Bounds(bounds);
    }
    if (owner && message == WM_DESTROY) {
        (*owner)->closed = true;
        if ((*owner)->controller) (*owner)->controller->Close();
        (*owner)->controller.Reset();
        (*owner)->environment.Reset();
        if ((*owner)->com_initialized) { (*owner)->com_initialized = false; CoUninitialize(); }
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        delete owner;
    }
    return DefWindowProcW(hwnd, message, w, l);
}

bool protect(const PreviewPtr &p, ICoreWebView2 *web) {
    ComPtr<ICoreWebView2Settings> settings;
    ComPtr<ICoreWebView2_4> web4;
    EventRegistrationToken token{};
    if (FAILED(web->get_Settings(&settings)) || !settings || FAILED(web->QueryInterface(IID_PPV_ARGS(&web4))) || !web4)
        return false;
    if (FAILED(settings->put_IsScriptEnabled(FALSE)) || FAILED(settings->put_IsWebMessageEnabled(FALSE)) ||
        FAILED(settings->put_AreDevToolsEnabled(FALSE)) || FAILED(settings->put_AreDefaultContextMenusEnabled(FALSE))) return false;
    auto navigation = Callback<ICoreWebView2NavigationStartingEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
            LPWSTR uri = nullptr; HRESULT hr = args->get_Uri(&uri);
            bool allow = SUCCEEDED(hr) && p->initial_navigation && uri && p->initial_uri == uri;
            CoTaskMemFree(uri); p->initial_navigation = false;
            if (FAILED(args->put_Cancel(allow ? FALSE : TRUE))) { if (p->controller) p->controller->Close(); }
            return S_OK;
        });
    auto frame = Callback<ICoreWebView2NavigationStartingEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
            LPWSTR uri = nullptr; HRESULT hr = args->get_Uri(&uri);
            bool allow = SUCCEEDED(hr) && p->initial_frame && uri && wcscmp(uri, L"about:srcdoc") == 0;
            CoTaskMemFree(uri); p->initial_frame = false;
            if (FAILED(args->put_Cancel(allow ? FALSE : TRUE))) { if (p->controller) p->controller->Close(); }
            return S_OK;
        });
    auto popup = Callback<ICoreWebView2NewWindowRequestedEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT { if (FAILED(args->put_Handled(TRUE)) && p->controller) p->controller->Close(); return S_OK; });
    auto permission = Callback<ICoreWebView2PermissionRequestedEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *args) -> HRESULT { if (FAILED(args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY)) && p->controller) p->controller->Close(); return S_OK; });
    auto download = Callback<ICoreWebView2DownloadStartingEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *args) -> HRESULT { if (FAILED(args->put_Cancel(TRUE)) && p->controller) p->controller->Close(); return S_OK; });
    auto resource = Callback<ICoreWebView2WebResourceRequestedEventHandler>(
        [p](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) -> HRESULT {
            if (p->closed || !p->environment) { if (p->controller) p->controller->Close(); return S_OK; }
            ComPtr<ICoreWebView2WebResourceResponse> response;
            HRESULT hr = p->environment->CreateWebResourceResponse(nullptr, 403, L"Forbidden", L"", &response);
            if (FAILED(hr) || !response || FAILED(args->put_Response(response.Get()))) {
                if (p->controller) p->controller->Close();
            }
            return S_OK;
        });
    auto shellLoaded = Callback<ICoreWebView2NavigationCompletedEventHandler>(
        [p](ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
            if (p->closed) return S_OK;
            BOOL success = FALSE;
            if (FAILED(args->get_IsSuccess(&success)) || !success) return S_OK;
            if (p->source_base64.empty()) return S_OK;
            // The script is trusted and the only interpolation is a base64 alphabet.
            // A detached browser parser strips active/navigation elements before
            // the resulting markup is assigned to the sandboxed frame.
            std::wstring script = LR"JS((()=>{const b=atob(')JS" + p->source_base64 + LR"JS(');const a=Uint8Array.from(b,c=>c.charCodeAt(0));const s=new TextDecoder('utf-8',{fatal:true}).decode(a);const h=document.createElement('html');h.innerHTML=s;h.querySelectorAll('iframe,frame,frameset,script,base,object,embed,link,template').forEach(e=>e.remove());h.querySelectorAll('meta').forEach(e=>{if((e.getAttribute('http-equiv')||'').trim().toLowerCase()==='refresh')e.remove()});h.querySelectorAll('*').forEach(e=>{for(const a of Array.from(e.attributes)){const n=a.name.toLowerCase();if((n==='href'||n==='xlink:href')&&!(a.value.trim().startsWith('#')&&!/[\x00-\x1f\x7f]/.test(a.value)))e.removeAttribute(a.name);else if(n==='action'||n==='formaction'||n==='srcset'||n==='ping'||n==='poster'||n.startsWith('on'))e.removeAttribute(a.name);else if(n==='src'&&!a.value.trim().toLowerCase().startsWith('data:'))e.removeAttribute(a.name)}});const f=document.createElement('iframe');f.setAttribute('sandbox','');f.srcdoc='<!doctype html>'+h.outerHTML;document.body.append(f);return true})())JS";
            p->source_base64.clear();
            auto completed = Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                [p](HRESULT result, LPCWSTR value) -> HRESULT {
                    if (!p->closed && (FAILED(result) || !value || wcscmp(value, L"true") != 0)) fail(p);
                    return S_OK;
                });
            if (FAILED(sender->ExecuteScript(script.c_str(), completed.Get()))) fail(p);
            return S_OK;
        });
#ifdef EXOSUIT_PREVIEW_TESTING
    ComPtr<ICoreWebView2> inspectedWeb = web;
    auto created = Callback<ICoreWebView2FrameCreatedEventHandler>(
        [inspectedWeb](ICoreWebView2 *, ICoreWebView2FrameCreatedEventArgs *args) -> HRESULT {
            ComPtr<ICoreWebView2Frame> frame;
            ComPtr<ICoreWebView2Frame2> frame2;
            if (FAILED(args->get_Frame(&frame)) || !frame || FAILED(frame.As(&frame2)) || !frame2) { preview_test_result = -1; return S_OK; }
            auto loaded = Callback<ICoreWebView2FrameDOMContentLoadedEventHandler>(
            [inspectedWeb](ICoreWebView2Frame *, ICoreWebView2DOMContentLoadedEventArgs *) -> HRESULT {
            auto result = Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
                [](HRESULT hr, LPCWSTR result) -> HRESULT {
                    preview_test_result = SUCCEEDED(hr) && result && wcsstr(result, L"\"nodeValue\":\"Static HTML preview\"") && !wcsstr(result, L"\"nodeValue\":\"SCRIPT RAN\"") ? 1 : -2;
                    return S_OK;
                });
            HRESULT hr = inspectedWeb->CallDevToolsProtocolMethod(L"DOM.getDocument", L"{\"depth\":-1,\"pierce\":true}", result.Get());
            if (FAILED(hr)) preview_test_result = -3;
            return S_OK;
        });
            EventRegistrationToken frameToken{};
            if (FAILED(frame2->add_DOMContentLoaded(loaded.Get(), &frameToken))) preview_test_result = -4;
            return S_OK;
        });
    if (FAILED(web4->add_FrameCreated(created.Get(), &token))) return false;
#endif
    return SUCCEEDED(web->add_NavigationStarting(navigation.Get(), &token)) &&
        SUCCEEDED(web->add_NavigationCompleted(shellLoaded.Get(), &token)) &&
        SUCCEEDED(web->add_FrameNavigationStarting(frame.Get(), &token)) &&
        SUCCEEDED(web->add_NewWindowRequested(popup.Get(), &token)) &&
        SUCCEEDED(web->add_PermissionRequested(permission.Get(), &token)) &&
        SUCCEEDED(web4->add_DownloadStarting(download.Get(), &token)) &&
        SUCCEEDED(web->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)) &&
        SUCCEEDED(web->add_WebResourceRequested(resource.Get(), &token));
}

void start_offline(const PreviewPtr &p, ComPtr<ICoreWebView2> web) {
    using Handler = ICoreWebView2CallDevToolsProtocolMethodCompletedHandler;
    auto enabled = Callback<Handler>([p, web](HRESULT status, LPCWSTR) -> HRESULT {
        if (p->closed) return S_OK;
        if (FAILED(status)) { fail(p); return S_OK; }
        auto bypassed = Callback<Handler>([p, web](HRESULT status, LPCWSTR) -> HRESULT {
            if (p->closed) return S_OK;
            if (FAILED(status)) { fail(p); return S_OK; }
            auto offline = Callback<Handler>([p, web](HRESULT status, LPCWSTR) -> HRESULT {
                if (p->closed) return S_OK;
                if (FAILED(status) || FAILED(web->NavigateToString(p->document.c_str()))) { fail(p); return S_OK; }
                p->document.clear();
                return S_OK;
            });
            if (FAILED(web->CallDevToolsProtocolMethod(L"Network.emulateNetworkConditions",
                L"{\"offline\":true,\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}", offline.Get()))) fail(p);
            return S_OK;
        });
        if (FAILED(web->CallDevToolsProtocolMethod(L"Network.setBypassServiceWorker", L"{\"bypass\":true}", bypassed.Get()))) fail(p);
        return S_OK;
    });
    if (FAILED(web->CallDevToolsProtocolMethod(L"Network.enable", L"{}", enabled.Get()))) fail(p);
}
}

extern "C" __declspec(dllexport) int exosuit_artifact_preview_available() {
    static int cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    static HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) return cached;
    using GetVersion = HRESULT(STDAPICALLTYPE *)(PCWSTR, LPWSTR *);
    auto getVersion = reinterpret_cast<GetVersion>(GetProcAddress(loader, "GetAvailableCoreWebView2BrowserVersionString"));
    LPWSTR version = nullptr;
    if (getVersion && SUCCEEDED(getVersion(nullptr, &version)) && version && *version) cached = 1;
    CoTaskMemFree(version);
    return cached;
}

extern "C" __declspec(dllexport) int exosuit_artifact_preview_open(uint32_t parent, const char *source) {
    if (!source) return 0;
    size_t length = strnlen_s(source, 512 * 1024 + 1);
    if (length == 0 || length > 512 * 1024) return 0;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, static_cast<int>(length), nullptr, 0);
    if (count <= 0) return 0;
    nk_native_window native{}; native.struct_size = sizeof(native);
    if (nk_window_get_native(parent, &native) != NK_OK || native.kind != NK_NATIVE_WINDOW_WIN32 || !native.window) return 0;
    static HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) return 0;
    using CreateEnvironment = HRESULT(STDAPICALLTYPE *)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
    auto create = reinterpret_cast<CreateEnvironment>(GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions"));
    if (!create) return 0;
    auto p = std::make_shared<Preview>();
    HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(com)) return 0;
    p->com_initialized = true;
    p->document = L"<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; script-src 'none'; frame-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"><style>html,body,iframe{margin:0;width:100%;height:100%;border:0}iframe{background:white}</style><body></body>";
    int utf8size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p->document.data(), static_cast<int>(p->document.size()), nullptr, 0, nullptr, nullptr);
    if (utf8size <= 0) { CoUninitialize(); return 0; }
    std::string utf8(static_cast<size_t>(utf8size), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, p->document.data(), static_cast<int>(p->document.size()), &utf8[0], utf8size, nullptr, nullptr)) { CoUninitialize(); return 0; }
    static const wchar_t alphabet[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < length; i += 3) {
        unsigned a = static_cast<unsigned char>(source[i]);
        unsigned b = i + 1 < length ? static_cast<unsigned char>(source[i + 1]) : 0;
        unsigned c = i + 2 < length ? static_cast<unsigned char>(source[i + 2]) : 0;
        p->source_base64 += alphabet[a >> 2]; p->source_base64 += alphabet[((a & 3) << 4) | (b >> 4)];
        p->source_base64 += i + 1 < length ? alphabet[((b & 15) << 2) | (c >> 6)] : L'=';
        p->source_base64 += i + 2 < length ? alphabet[c & 63] : L'=';
    }
    p->initial_uri = L"data:text/html;charset=utf-8;base64,";
    for (size_t i = 0; i < utf8.size(); i += 3) {
        unsigned a = static_cast<unsigned char>(utf8[i]);
        unsigned b = i + 1 < utf8.size() ? static_cast<unsigned char>(utf8[i + 1]) : 0;
        unsigned c = i + 2 < utf8.size() ? static_cast<unsigned char>(utf8[i + 2]) : 0;
        p->initial_uri += alphabet[a >> 2]; p->initial_uri += alphabet[((a & 3) << 4) | (b >> 4)];
        p->initial_uri += i + 1 < utf8.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : L'=';
        p->initial_uri += i + 2 < utf8.size() ? alphabet[c & 63] : L'=';
    }
    WNDCLASSW wc{}; wc.lpfnWndProc = window_proc; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"ExosuitInertArtifactPreview";
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) { CoUninitialize(); return 0; }
    auto *holder = new PreviewPtr(p);
    p->window = CreateWindowExW(0, wc.lpszClassName, L"Static artifact preview (scripts and external resources disabled)", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 900, 700, reinterpret_cast<HWND>(native.window), nullptr, wc.hInstance, holder);
    if (!p->window) { delete holder; CoUninitialize(); return 0; }
    ShowWindow(p->window, SW_SHOW);
    auto environment = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [p](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
            if (p->closed) return S_OK;
            if (FAILED(result) || !env) { fail(p); return S_OK; }
            p->environment = env;
            ComPtr<ICoreWebView2Environment10> env10;
            ComPtr<ICoreWebView2ControllerOptions> options;
            if (FAILED(env->QueryInterface(IID_PPV_ARGS(&env10))) || !env10 ||
                FAILED(env10->CreateCoreWebView2ControllerOptions(&options)) || !options ||
                FAILED(options->put_IsInPrivateModeEnabled(TRUE))) { fail(p); return S_OK; }
            auto controller = Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [p](HRESULT result, ICoreWebView2Controller *control) -> HRESULT {
                    if (p->closed) { if (control) control->Close(); return S_OK; }
                    if (FAILED(result) || !control) { fail(p); return S_OK; }
                    p->controller = control;
                    ComPtr<ICoreWebView2> web;
                    if (FAILED(control->get_CoreWebView2(&web)) || !web || !protect(p, web.Get())) { fail(p); return S_OK; }
                    RECT bounds{}; GetClientRect(p->window, &bounds);
                    if (FAILED(control->put_Bounds(bounds)) || FAILED(control->put_IsVisible(TRUE))) { fail(p); return S_OK; }
                    start_offline(p, web);
                    return S_OK;
                });
            if (FAILED(env10->CreateCoreWebView2ControllerWithOptions(p->window, options.Get(), controller.Get()))) fail(p);
            return S_OK;
        });
    if (FAILED(create(nullptr, nullptr, nullptr, environment.Get()))) { DestroyWindow(p->window); return 0; }
    return 1;
}
#else
#include <stdint.h>
#if defined(_WIN32)
#define EXOSUIT_EXPORT __declspec(dllexport)
#else
#define EXOSUIT_EXPORT __attribute__((visibility("default")))
#endif
extern "C" EXOSUIT_EXPORT int exosuit_artifact_preview_open(uint32_t, const char *) { return 0; }
extern "C" EXOSUIT_EXPORT int exosuit_artifact_preview_available() { return 0; }
#endif
