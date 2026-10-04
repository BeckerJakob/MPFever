// winhttp.dll slot: Transport Fever 3 imports WINHTTP.dll and Windows looks for it in the game folder first. Placed
// there under that name, this module is loaded by the game itself at startup (no injection by the launcher), and
// relays every WinHTTP function to the system's winhttp.dll.
//  * the 14 functions the game imports are implemented here: they load the real library from the system folder
//    (wherever Windows is installed) and call it;
//  * the other exports are forwarders (winhttp.def), only there for completeness.
#include "win.h"

typedef void* HINTERNET;
typedef unsigned short WORD;

static HMODULE g_real = 0;

static void* Real(const char* name)
{
    if (!g_real) {
        wchar_t path[300];
        u32 n = GetSystemDirectoryW(path, 260);
        if (n == 0 || n >= 260) return 0;
        const wchar_t* tail = L"\\winhttp.dll";
        for (int k = 0; tail[k]; k++) path[n++] = tail[k];
        path[n] = 0;
        g_real = LoadLibraryW(path);
        if (!g_real) return 0;
    }
    return GetProcAddress(g_real, name);
}

#define RELAY(ret, fail, name, params, args)                                  \
    extern "C" ret WINAPI P_##name params                                     \
    {                                                                         \
        typedef ret (WINAPI* F) params;                                       \
        static F real_ = 0;                                                   \
        if (!real_) real_ = (F)Real(#name);                                   \
        return real_ ? real_ args : fail;                                     \
    }

RELAY(HINTERNET, 0, WinHttpOpen, (const wchar_t* a, DWORD b, const wchar_t* c, const wchar_t* d, DWORD e), (a, b, c, d, e))
RELAY(HINTERNET, 0, WinHttpConnect, (HINTERNET a, const wchar_t* b, WORD c, DWORD d), (a, b, c, d))
RELAY(HINTERNET, 0, WinHttpOpenRequest, (HINTERNET a, const wchar_t* b, const wchar_t* c, const wchar_t* d, const wchar_t* e, const wchar_t** f, DWORD g), (a, b, c, d, e, f, g))
RELAY(BOOL, 0, WinHttpSetOption, (HINTERNET a, DWORD b, void* c, DWORD d), (a, b, c, d))
RELAY(BOOL, 0, WinHttpReadData, (HINTERNET a, void* b, DWORD c, DWORD* d), (a, b, c, d))
RELAY(void*, (void*)(i64)-1, WinHttpSetStatusCallback, (HINTERNET a, void* b, DWORD c, uptr d), (a, b, c, d))
RELAY(BOOL, 0, WinHttpCloseHandle, (HINTERNET a), (a))
RELAY(BOOL, 0, WinHttpWriteData, (HINTERNET a, const void* b, DWORD c, DWORD* d), (a, b, c, d))
RELAY(BOOL, 0, WinHttpQueryDataAvailable, (HINTERNET a, DWORD* b), (a, b))
RELAY(BOOL, 0, WinHttpSetTimeouts, (HINTERNET a, int b, int c, int d, int e), (a, b, c, d, e))
RELAY(BOOL, 0, WinHttpQueryHeaders, (HINTERNET a, DWORD b, const wchar_t* c, void* d, DWORD* e, DWORD* f), (a, b, c, d, e, f))
RELAY(BOOL, 0, WinHttpAddRequestHeaders, (HINTERNET a, const wchar_t* b, DWORD c, DWORD d), (a, b, c, d))
RELAY(BOOL, 0, WinHttpSendRequest, (HINTERNET a, const wchar_t* b, DWORD c, void* d, DWORD e, DWORD f, uptr g), (a, b, c, d, e, f, g))
RELAY(BOOL, 0, WinHttpReceiveResponse, (HINTERNET a, void* b), (a, b))
