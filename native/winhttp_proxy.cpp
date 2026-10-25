// winhttp.dll slot: Transport Fever 3 imports WINHTTP.dll and Windows looks for it in the game folder first. Placed
// there under that name, this module is loaded by the game itself at startup (no injection by the launcher), and
// relays every WinHTTP function to the system's winhttp.dll.
//  * the 14 functions the game imports are implemented here: they load the real library from the system folder
//    (wherever Windows is installed) and call it;
//  * every other function of it is passed on (PASS, at the end).
#include "win.h"

typedef void* HINTERNET;
typedef unsigned short WORD;

static HMODULE g_real = 0;
// The error of a failed load or lookup of the system's winhttp.dll, given back to the caller: without it the game's mod.io read
// whatever error came before (E_UNEXPECTED in issue #83) and the failure could not be told apart. The native module logs it.
static u32 g_realErr = 0;
extern "C" void MpfProxyFailed(const char* what, u32 err);

static void* Real(const char* name)
{
    if (!g_real) {
        wchar_t path[300];
        u32 n = GetSystemDirectoryW(path, 260);
        if (n == 0 || n >= 260) { g_realErr = 3; MpfProxyFailed("GetSystemDirectory", g_realErr); return 0; }
        const wchar_t* tail = L"\\winhttp.dll";
        for (int k = 0; tail[k]; k++) path[n++] = tail[k];
        path[n] = 0;
        g_real = LoadLibraryW(path);
        if (!g_real) { g_realErr = GetLastError(); if (!g_realErr) g_realErr = 126; MpfProxyFailed("LoadLibrary winhttp.dll", g_realErr); return 0; }
    }
    void* f = GetProcAddress(g_real, name);
    if (!f) { g_realErr = GetLastError(); if (!g_realErr) g_realErr = 127; MpfProxyFailed(name, g_realErr); }
    return f;
}

#define RELAY(ret, fail, name, params, args)                                  \
    extern "C" ret WINAPI P_##name params                                     \
    {                                                                         \
        typedef ret (WINAPI* F) params;                                       \
        static F real_ = 0;                                                   \
        if (!real_) real_ = (F)Real(#name);                                   \
        if (real_) return real_ args;                                         \
        SetLastError(g_realErr ? g_realErr : 127);                            \
        return fail;                                                          \
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

// Every other function of the system's winhttp.dll, passed on as it is (WinHTTP has no float parameter or result: up to 12
// integer or pointer arguments are handed over unchanged). Windows' own modules loaded later into the game import some of them
// from "winhttp.dll", and the module of that name already in the game is this one: cryptnet.dll, which fetches what a
// certificate check of an HTTPS connection needs (revocation lists, missing certificates of the chain), found no
// WinHttpCrackUrl here, and every such fetch failed with error 127 (issue #83: the Mod Hub broken, or the game closing as it
// opened, on some PCs only: those that had something to fetch for mod.io's certificate). dnsapi.dll (DNS over HTTPS) and
// wininet.dll (proxy settings) import more of them.
typedef u64 (*AnyFn)(u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64);
#define PASS(name)                                                                                                \
    extern "C" u64 P_##name(u64 a, u64 b, u64 c, u64 d, u64 e, u64 f, u64 g, u64 h, u64 i, u64 j, u64 k, u64 l)   \
    {                                                                                                             \
        static AnyFn real_ = 0;                                                                                   \
        if (!real_) real_ = (AnyFn)Real(#name);                                                                   \
        if (real_) return real_(a, b, c, d, e, f, g, h, i, j, k, l);                                              \
        SetLastError(g_realErr ? g_realErr : 127);                                                                \
        return 0;                                                                                                 \
    }

PASS(WinHttpAddRequestHeadersEx)
PASS(WinHttpAutoProxySvcMain)
PASS(WinHttpCheckPlatform)
PASS(WinHttpConnectionDeletePolicyEntries)
PASS(WinHttpConnectionDeletePolicyEntriesByAppSid)
PASS(WinHttpConnectionDeleteProxyInfo)
PASS(WinHttpConnectionFreeNameList)
PASS(WinHttpConnectionFreeProxyInfo)
PASS(WinHttpConnectionFreeProxyList)
PASS(WinHttpConnectionGetNameList)
PASS(WinHttpConnectionGetProxyInfo)
PASS(WinHttpConnectionGetProxyList)
PASS(WinHttpConnectionOnlyConvert)
PASS(WinHttpConnectionOnlyReceive)
PASS(WinHttpConnectionOnlySend)
PASS(WinHttpConnectionSetPolicyEntries)
PASS(WinHttpConnectionSetProxyInfo)
PASS(WinHttpConnectionUpdateIfIndexTable)
PASS(WinHttpCrackUrl)
PASS(WinHttpCreateProxyList)
PASS(WinHttpCreateProxyManager)
PASS(WinHttpCreateProxyResolver)
PASS(WinHttpCreateProxyResult)
PASS(WinHttpCreateUiCompatibleProxyString)
PASS(WinHttpCreateUrl)
PASS(WinHttpDetectAutoProxyConfigUrl)
PASS(WinHttpFreeProxyResult)
PASS(WinHttpFreeProxyResultEx)
PASS(WinHttpFreeProxySettings)
PASS(WinHttpFreeProxySettingsEx)
PASS(WinHttpFreeQueryConnectionGroupResult)
PASS(WinHttpGetDefaultProxyConfiguration)
PASS(WinHttpGetIEProxyConfigForCurrentUser)
PASS(WinHttpGetProxyForUrl)
PASS(WinHttpGetProxyForUrlEx)
PASS(WinHttpGetProxyForUrlEx2)
PASS(WinHttpGetProxyForUrlHvsi)
PASS(WinHttpGetProxyResult)
PASS(WinHttpGetProxyResultEx)
PASS(WinHttpGetProxySettingsEx)
PASS(WinHttpGetProxySettingsResultEx)
PASS(WinHttpGetProxySettingsVersion)
PASS(WinHttpGetTunnelSocket)
PASS(WinHttpPacJsWorkerMain)
PASS(WinHttpProbeConnectivity)
PASS(WinHttpProtocolCompleteUpgrade)
PASS(WinHttpProtocolReceive)
PASS(WinHttpProtocolSend)
PASS(WinHttpQueryAuthSchemes)
PASS(WinHttpQueryConnectionGroup)
PASS(WinHttpQueryHeadersEx)
PASS(WinHttpQueryOption)
PASS(WinHttpReadDataEx)
PASS(WinHttpReadProxySettings)
PASS(WinHttpReadProxySettingsHvsi)
PASS(WinHttpRefreshProxySettings)
PASS(WinHttpRegisterProxyChangeNotification)
PASS(WinHttpResetAutoProxy)
PASS(WinHttpResolverGetProxyForUrl)
PASS(WinHttpSaveProxyCredentials)
PASS(WinHttpSetCredentials)
PASS(WinHttpSetDefaultProxyConfiguration)
PASS(WinHttpSetProxySettingsPerUser)
PASS(WinHttpSetSecureLegacyServersAppCompat)
PASS(WinHttpTimeFromSystemTime)
PASS(WinHttpTimeToSystemTime)
PASS(WinHttpUnregisterProxyChangeNotification)
PASS(WinHttpWebSocketClose)
PASS(WinHttpWebSocketCompleteUpgrade)
PASS(WinHttpWebSocketQueryCloseStatus)
PASS(WinHttpWebSocketReceive)
PASS(WinHttpWebSocketSend)
PASS(WinHttpWebSocketShutdown)
PASS(WinHttpWriteProxySettings)
