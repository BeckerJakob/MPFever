// MPFever native companion for Transport Fever 3 (loaded into the game by MPFever.exe).
//
// v1: diagnostics. Inline hooks on engine functions log who calls them (return addresses found on the stack, as
// RVAs) to <MPFEVER_DIR>\native.log. Everything is keyed to one exact game build: on any other build the DLL
// stays inert. Built freestanding (no Windows SDK / C runtime on the build machine): see win.h.
#include "win.h"

extern "C" int _fltused = 0;

extern "C" void* memcpy(void*, const void*, size_t);
extern "C" void* memset(void*, int, size_t);
extern "C" int memcmp(const void*, const void*, size_t);
#pragma function(memcpy)
#pragma function(memset)
#pragma function(memcmp)
extern "C" void* memcpy(void* d, const void* s, size_t n) { u8* a = (u8*)d; const u8* b = (const u8*)s; while (n--) *a++ = *b++; return d; }
extern "C" void* memset(void* d, int v, size_t n) { u8* a = (u8*)d; while (n--) *a++ = (u8)v; return d; }
extern "C" int memcmp(const void* x, const void* y, size_t n) { const u8* a = (const u8*)x; const u8* b = (const u8*)y; for (; n; n--, a++, b++) if (*a != *b) return *a < *b ? -1 : 1; return 0; }

static const u32 EXPECTED_TIMESTAMP = 0x6ab69fe5;   // TransportFever3.exe build 40408

static uptr g_base = 0, g_textStart = 0, g_textEnd = 0;
static HANDLE g_log = 0;
static volatile long g_logLock = 0;

// ------------------------------------------------------------------ tiny text builder

struct Buf {
    char s[1024];
    int n = 0;
    Buf& str(const char* t) { while (*t && n < 1000) s[n++] = *t++; return *this; }
    Buf& hex(u64 v) { char t[17]; int k = 0; do { int d = (int)(v & 15); t[k++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v >>= 4; } while (v && k < 16); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& dec(i64 v) { if (v < 0) { s[n++] = '-'; v = -v; } char t[21]; int k = 0; do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k && n < 1000) s[n++] = t[--k]; return *this; }
    Buf& dec2(int v) { s[n++] = (char)('0' + v / 10 % 10); s[n++] = (char)('0' + v % 10); return *this; }
};

static void LogLine(Buf& b)
{
    if (!g_log) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    Buf line;
    line.dec2(t.wHour).str(":").dec2(t.wMinute).str(":").dec2(t.wSecond).str(" ");
    for (int i = 0; i < b.n && line.n < 1010; i++) line.s[line.n++] = b.s[i];
    line.s[line.n++] = '\r';
    line.s[line.n++] = '\n';
    while (_InterlockedExchange(&g_logLock, 1)) Sleep(0);
    DWORD w;
    SetFilePointer(g_log, 0, 0, FILE_END);
    WriteFile(g_log, line.s, (DWORD)line.n, &w, 0);
    _InterlockedExchange(&g_logLock, 0);
}

// ------------------------------------------------------------------ inline hooks

struct Hook {
    const char* name;
    u32 rva;
    int steal;                 // whole instructions, no RIP-relative operand (checked offline with capstone)
    const u8* expect;          // first bytes expected at the target (build check)
    int expectLen;
    void* tramp;
    volatile long calls;
};

static void WriteAbsJump(u8* at, uptr to)
{
    at[0] = 0xFF; at[1] = 0x25; at[2] = at[3] = at[4] = at[5] = 0;
    *(uptr*)(at + 6) = to;
}

static bool IsCallBefore(uptr ret)
{
    if (ret < g_textStart + 8 || ret >= g_textEnd) return false;
    const u8* p = (const u8*)ret;
    if (p[-5] == 0xE8) return true;
    if (p[-6] == 0xFF && p[-5] == 0x15) return true;
    if (p[-2] == 0xFF && (p[-1] & 0x38) == 0x10) return true;
    if (p[-3] == 0xFF && (p[-2] & 0x38) == 0x10) return true;
    if (p[-3] == 0x41 && p[-2] == 0xFF && (p[-1] & 0x38) == 0x10) return true;
    if (p[-6] == 0xFF && (p[-5] & 0x38) == 0x10) return true;
    if (p[-7] == 0xFF && (p[-6] & 0x38) == 0x10) return true;
    return false;
}

// called from the relay thunk with the hooked function's stack pointer at entry
extern "C" void OnHookEntry(Hook* h, uptr* entryRsp)
{
    long n = _InterlockedIncrement(&h->calls);
    if (n > 40) return;
    Buf b;
    b.str(h->name).str(" #").dec(n).str(" from");
    int found = 0;
    for (int i = 0; i < 0x400 && found < 12; i++) {
        uptr v = entryRsp[i];
        if (v >= g_textStart && v < g_textEnd && IsCallBefore(v)) {
            b.str(" ").hex(v - g_base);
            found++;
        }
    }
    LogLine(b);
}

// Relay thunk: saves the argument registers, calls OnHookEntry(hook, rsp at entry), restores, jumps to the trampoline.
static void* MakeRelay(Hook* h)
{
    u8* c = (u8*)VirtualAlloc(0, 256, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!c) return 0;
    int i = 0;
    static const u8 pre[] = {
        0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x50, 0x41, 0x52, 0x41, 0x53,   // push rcx rdx r8 r9 rax r10 r11
        0x48, 0x83, 0xEC, 0x60,                                             // sub rsp, 0x60
        0xF3, 0x0F, 0x7F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x7F, 0x4C, 0x24, 0x30, // movdqu [rsp+20],xmm0 / [rsp+30],xmm1
        0xF3, 0x0F, 0x7F, 0x54, 0x24, 0x40, 0xF3, 0x0F, 0x7F, 0x5C, 0x24, 0x50, // movdqu [rsp+40],xmm2 / [rsp+50],xmm3
        0x48, 0x8D, 0x94, 0x24, 0x98, 0x00, 0x00, 0x00,                     // lea rdx, [rsp+0x60+7*8]
    };
    for (u8 x : pre) c[i++] = x;
    c[i++] = 0x48; c[i++] = 0xB9; *(u64*)(c + i) = (u64)h; i += 8;                 // mov rcx, hook
    c[i++] = 0x48; c[i++] = 0xB8; *(u64*)(c + i) = (u64)&OnHookEntry; i += 8;      // mov rax, OnHookEntry
    c[i++] = 0xFF; c[i++] = 0xD0;                                                  // call rax
    static const u8 post[] = {
        0xF3, 0x0F, 0x6F, 0x44, 0x24, 0x20, 0xF3, 0x0F, 0x6F, 0x4C, 0x24, 0x30,
        0xF3, 0x0F, 0x6F, 0x54, 0x24, 0x40, 0xF3, 0x0F, 0x6F, 0x5C, 0x24, 0x50,
        0x48, 0x83, 0xC4, 0x60,                                             // add rsp, 0x60
        0x41, 0x5B, 0x41, 0x5A, 0x58, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59,   // pop r11 r10 rax r9 r8 rdx rcx
    };
    for (u8 x : post) c[i++] = x;
    WriteAbsJump(c + i, (uptr)h->tramp); i += 14;
    FlushInstructionCache(GetCurrentProcess(), c, i);
    return c;
}

static bool Install(Hook* h)
{
    u8* target = (u8*)(g_base + h->rva);
    Buf b;
    if (h->expect && memcmp(target, h->expect, h->expectLen) != 0) {
        b.str("hook ").str(h->name).str(": unexpected bytes, not installed");
        LogLine(b);
        return false;
    }
    u8* tramp = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) return false;
    memcpy(tramp, target, h->steal);
    WriteAbsJump(tramp + h->steal, (uptr)target + h->steal);
    FlushInstructionCache(GetCurrentProcess(), tramp, h->steal + 14);
    h->tramp = tramp;
    void* relay = MakeRelay(h);
    if (!relay) return false;
    DWORD old;
    if (!VirtualProtect(target, h->steal, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[32];
    WriteAbsJump(patch, (uptr)relay);
    for (int k = 14; k < h->steal; k++) patch[k] = 0xCC;
    memcpy(target, patch, h->steal);
    VirtualProtect(target, h->steal, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, h->steal);
    b.str("hook ").str(h->name).str(" installed at ").hex(h->rva);
    LogLine(b);
    return true;
}

// ------------------------------------------------------------------ targets (build 40408)

static const u8 P_5F4920[] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };
static const u8 P_609F50[] = { 0x48, 0x89, 0x5C, 0x24, 0x08 };
static const u8 P_A1C370[] = { 0x48, 0x89, 0x5C, 0x24, 0x10 };
static const u8 P_A1C540[] = { 0x4C, 0x8B, 0xDC };
static const u8 P_A1D2C0[] = { 0x48, 0x8B, 0xC4 };
static const u8 P_A1ED10[] = { 0x48, 0x89, 0x5C, 0x24, 0x20 };
static const u8 P_A3C180[] = { 0x40, 0x55 };

static Hook g_hooks[] = {
    { "notPossible_5f4920", 0x5f4920, 14, P_5F4920, 5 },
    { "notPossible_CheckGraph_609f50", 0x609f50, 14, P_609F50, 5 },
    { "notPossible_a1c370", 0xa1c370, 15, P_A1C370, 5 },
    { "notPossible_a1c540", 0xa1c540, 19, P_A1C540, 3 },
    { "notPossible_ParallelShapes_a1d2c0", 0xa1d2c0, 14, P_A1D2C0, 3 },
    { "notPossible_ConstructionData_a1ed10", 0xa1ed10, 14, P_A1ED10, 5 },
    { "notPossible_a3c180", 0xa3c180, 21, P_A3C180, 2 },
};

// ------------------------------------------------------------------ breakpoint sites
// A one-byte int3 on an instruction; the vectored handler logs the call chain and emulates the instruction.
// Only "lea r64, [rip + disp32]" (7 bytes, REX.W 8D modrm 00 reg 101) is emulated.

struct Site {
    const char* name;
    u32 rva;
    u8 orig;
    volatile long hits;
};

#include "sites_gen.h"
static Site g_sites[] = {
    { "notPossible@5f4c0b", 0x5f4c0b }, { "notPossible@609fe5", 0x609fe5 }, { "notPossible@60a05f", 0x60a05f },
    { "notPossible@60a0de", 0x60a0de }, { "notPossible@a1c427", 0xa1c427 }, { "notPossible@a1c4c8", 0xa1c4c8 },
    { "notPossible@a1c670", 0xa1c670 }, { "notPossible@a1dfee", 0xa1dfee }, { "notPossible@a1f12e", 0xa1f12e },
    { "notPossible@a3ccad", 0xa3ccad },
};

static void LogStack(const char* what, long n, uptr* rsp)
{
    Buf b;
    b.str(what).str(" #").dec(n).str(" stack");
    int found = 0;
    for (int i = 0; i < 0x600 && found < 14; i++) {
        uptr v = rsp[i];
        if (v >= g_textStart && v < g_textEnd && IsCallBefore(v)) {
            b.str(" ").hex(v - g_base);
            found++;
        }
    }
    LogLine(b);
}

static Site g_mapSites[sizeof(MAPGET_SITES) / sizeof(MAPGET_SITES[0])];

static long WINAPI OnException(void* info)
{
    u8* rec = *(u8**)info;              // EXCEPTION_RECORD*
    u8* ctx = *((u8**)info + 1);        // CONTEXT*
    if (*(u32*)rec != 0x80000003u) return 0;
    uptr addr = *(uptr*)(rec + 0x10);
    Site* found = 0;
    for (auto& s : g_sites) if (addr == g_base + s.rva) found = &s;
    if (!found) for (auto& s : g_mapSites) if (s.rva && addr == g_base + s.rva) found = &s;
    if (found) {
        Site& s = *found;
        uptr at = g_base + s.rva;
        long n = _InterlockedIncrement(&s.hits);
        if (n <= 30) { Buf w; w.str("site ").hex(s.rva); LogLine(w); LogStack(s.name, n, *(uptr**)(ctx + 0x98)); }
        // emulate lea r64, [rip + disp32]
        const u8* p = (const u8*)at;
        int reg = ((p[2] >> 3) & 7) | ((s.orig & 4) ? 8 : 0);
        i64 disp = *(const int*)(p + 3);
        uptr value = at + 7 + disp;
        static const int regOff[16] = { 0x78, 0x80, 0x88, 0x90, 0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0 };
        *(uptr*)(ctx + regOff[reg]) = value;
        *(uptr*)(ctx + 0xF8) = at + 7;
        return -1;   // EXCEPTION_CONTINUE_EXECUTION
    }
    return 0;
}


static void ArmSite(Site& s)
{
    u8* at = (u8*)(g_base + s.rva);
    if (!((at[0] == 0x48 || at[0] == 0x4C) && at[1] == 0x8D && (at[2] & 0xC7) == 0x05)) return;
    s.orig = at[0];
    DWORD old;
    VirtualProtect(at, 1, PAGE_EXECUTE_READWRITE, &old);
    at[0] = 0xCC;
    VirtualProtect(at, 1, old, &old);
    FlushInstructionCache(GetCurrentProcess(), at, 1);
}

static void ArmMapSites()
{
    AddVectoredExceptionHandler(1, OnException);
    int n = (int)(sizeof(MAPGET_SITES) / sizeof(MAPGET_SITES[0]));
    for (int i = 0; i < n; i++) {
        g_mapSites[i].name = "mapGetFailed";
        g_mapSites[i].rva = MAPGET_SITES[i];
        ArmSite(g_mapSites[i]);
    }
    Buf b; b.str("map assertion sites armed: ").dec(n); LogLine(b);
}

static void ArmSites()
{
    AddVectoredExceptionHandler(1, OnException);
    for (auto& s : g_sites) {
        u8* at = (u8*)(g_base + s.rva);
        if (!((at[0] == 0x48 || at[0] == 0x4C) && at[1] == 0x8D && (at[2] & 0xC7) == 0x05)) {
            Buf b; b.str("site ").str(s.name).str(": not a lea, skipped"); LogLine(b);
            continue;
        }
        s.orig = at[0];
        DWORD old;
        VirtualProtect(at, 1, PAGE_EXECUTE_READWRITE, &old);
        at[0] = 0xCC;
        VirtualProtect(at, 1, old, &old);
        FlushInstructionCache(GetCurrentProcess(), at, 1);
    }
    Buf b; b.str("breakpoint sites armed"); LogLine(b);
}

// ------------------------------------------------------------------ deferral of native builds (v3)
// A build issued by a UI tool (street, stop, construction, bulldozer...) is held at CommandList::Add instead of being
// queued; the mod announces it to every game and, at the agreed game time, asks for its release: the held command is
// then queued exactly as the tool would have queued it. Control: <dir>\native_ctl.txt ("enable 1", "release <n>"),
// events: <dir>\native_events.log ("deferred <id>").

static const u32 RVA_ADD = 0x9d29c0;             // CommandList::Add(list, out, cmd, done, progress)
static const u32 RVA_CMD_MOVE = 0x9cedb0;        // Command move constructor (dst, src)
static const u32 RVA_CMD_DTOR = 0x9ceff0;        // Command destructor
static const u32 RVA_HANDLE_DTOR = 0x30393d0;    // destructor of Add's out handle
static const u8 P_ADD[] = { 0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8D, 0x6C, 0x24, 0x98 };

// return addresses of the Add calls made by UI tools right after make_cmd BuildProposal (build 40408)
static const u32 UI_ADD_SITES[] = {
    0x4d45af,   // UI::Bulldozer::Apply
    0x51c11c,   // UI::ConstructionBuilder::MousePressed
    0x5290b4,   // tool (unnamed)
    0x538a85, 0x5391e9, 0x53936d,   // UI::LaneModifier::Apply
    0x543b2a,   // UI::ModuleBuilder::MousePressed
    0x549bea,   // tool (unnamed)
    0x589ed4,   // UI::StreetBuilder::UpdateEngine
    0x5954ed,   // UI::StreetTerminalBuilder (stops, signals, waypoints)
    0x5bfcad,   // UI::TrackModifier::Build
    0x289f944, 0x28a0191,   // entity window builtins
};

typedef void* (*AddFn)(void* list, void* out, void* cmd, void* done, void* progress);
static AddFn g_addOrig = 0;

struct Held {
    void* list;
    alignas(16) u8 cmd[0x40];
    alignas(16) u8 done[0x40];
    alignas(16) u8 progress[0x10];
    u32 site;
    int id;
};
static Held* g_held[64];
static int g_heldHead = 0, g_heldTail = 0, g_nextId = 0;
static bool g_enabled = false;
static int g_released = 0;          // releases performed
static int g_releaseTarget = 0;     // releases asked by the mod
static DWORD g_lastCtl = 0;
static char g_dir[300];
static int g_dirLen = 0;
static long g_inRelease = 0;
static int g_deferNextTarget = 0, g_deferNextDone = 0;   // test mode: defer the mod's own next commands

static void PathOf(char* out, const char* name)
{
    int k = 0;
    for (int i = 0; i < g_dirLen; i++) out[k++] = g_dir[i];
    out[k++] = '\\';
    for (int i = 0; name[i]; i++) out[k++] = name[i];
    out[k] = 0;
}

static void AppendEvent(Buf& b)
{
    char path[400];
    PathOf(path, "native_events.log");
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    b.s[b.n++] = '\n';
    DWORD w;
    SetFilePointer(f, 0, 0, FILE_END);
    WriteFile(f, b.s, (DWORD)b.n, &w, 0);
    CloseHandle(f);
}

// reads native_ctl.txt: "enable 0|1" and "release <n>" lines (the last value of each wins)
static void ReadControl()
{
    char path[400];
    PathOf(path, "native_ctl.txt");
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[16384];
    DWORD size = GetFileSize(f, 0), got = 0;
    if (size > sizeof(buf) - 1) { SetFilePointer(f, (long)(size - (sizeof(buf) - 1)), 0, 0); size = sizeof(buf) - 1; }
    ReadFile(f, buf, size, &got, 0);
    CloseHandle(f);
    buf[got] = 0;
    for (DWORD i = 0; i < got; ) {
        DWORD j = i;
        while (j < got && buf[j] != '\n') j++;
        const char* l = buf + i;
        int len = (int)(j - i);
        int v = 0;
        if (len >= 8 && memcmp(l, "enable ", 7) == 0) g_enabled = l[7] == '1';
        else if (len >= 11 && memcmp(l, "defernext ", 10) == 0) {
            for (int k = 10; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_deferNextTarget) g_deferNextTarget = v;
        }
        else if (len >= 9 && memcmp(l, "release ", 8) == 0) {
            for (int k = 8; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
            if (v > g_releaseTarget) g_releaseTarget = v;
        }
        i = j + 1;
    }
}

typedef void* (*MoveF)(void* self, void* where);
typedef void (*DelF)(void* self, bool dealloc);

static void MoveFunction(u8* dst, u8* src)
{
    // MSVC std::function: impl pointer at +0x38; impl vtable: _Copy, _Move, _Do_call, _Target_type, _Delete_this
    u8* impl = *(u8**)(src + 0x38);
    memset(dst, 0, 0x40);
    if (!impl) return;
    if (impl == src) {
        void** vt = *(void***)impl;
        void* moved = ((MoveF)vt[1])(impl, dst);
        *(void**)(dst + 0x38) = moved;
        ((DelF)vt[4])(impl, false);
    } else {
        *(void**)(dst + 0x38) = impl;
    }
    *(void**)(src + 0x38) = 0;
}

static bool IsUiSite(u32 rva)
{
    for (u32 s : UI_ADD_SITES) if (s == rva) return true;
    return false;
}

typedef void (*Dtor)(void*);
typedef void* (*MoveCtor)(void*, void*);

static void ReleaseOne()
{
    if (g_heldHead == g_heldTail) return;
    Held* h = g_held[g_heldHead % 64];
    g_heldHead++;
    alignas(16) u8 out[0x10];
    memset(out, 0, sizeof(out));
    g_addOrig(h->list, out, h->cmd, h->done, h->progress);
    ((Dtor)(g_base + RVA_HANDLE_DTOR))(out);
    ((Dtor)(g_base + RVA_CMD_DTOR))(h->cmd);
    Buf b; b.str("released build ").dec(h->id).str(" (tool site ").hex(h->site).str(")"); LogLine(b);
}

extern "C" void* AddDetour(void* list, void* out, void* cmd, void* done, void* progress)
{
    u32 caller = (u32)((uptr)_ReturnAddress() - g_base);
    if (!g_inRelease) ReadControl();
    bool testDefer = false;
    // (test mode removed: the Lua sendCommand path reads the command back through Add's out handle, which a deferral
    // leaves empty; only the UI tool sites, which merely destroy that handle, can be held)
    if (IsUiSite(caller) || testDefer) {
        if ((g_enabled || testDefer) && g_heldTail - g_heldHead < 60) {
            Held* h = (Held*)HeapAlloc(GetProcessHeap(), 8, sizeof(Held));
            if (h) {
                h->list = list;
                h->site = caller;
                h->id = ++g_nextId;
                ((MoveCtor)(g_base + RVA_CMD_MOVE))(h->cmd, cmd);
                MoveFunction(h->done, (u8*)done);
                memcpy(h->progress, progress, 0x10);
                memset(progress, 0, 0x10);
                memset(out, 0, 0x10);
                g_held[g_heldTail % 64] = h;
                g_heldTail++;
                Buf b; b.str("deferred build ").dec(h->id).str(" from tool site ").hex(caller); LogLine(b);
                Buf e; e.str("deferred ").dec(h->id); AppendEvent(e);
                return out;
            }
        }
        return g_addOrig(list, out, cmd, done, progress);
    }
    // any other command (the mod's own commands included): the moment to release what the mod asked for
    if (g_heldHead != g_heldTail && !g_inRelease) {
        if (g_released < g_releaseTarget) {
            g_inRelease = 1;
            while (g_released < g_releaseTarget && g_heldHead != g_heldTail) { ReleaseOne(); g_released++; }
            g_inRelease = 0;
        }
    }
    return g_addOrig(list, out, cmd, done, progress);
}

static bool InstallDetour(u32 rva, const u8* expect, int steal, void* detour, void** origOut)
{
    u8* target = (u8*)(g_base + rva);
    if (memcmp(target, expect, steal) != 0) {
        Buf b; b.str("detour at ").hex(rva).str(": unexpected bytes, not installed"); LogLine(b);
        return false;
    }
    u8* tramp = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) return false;
    memcpy(tramp, target, steal);
    WriteAbsJump(tramp + steal, (uptr)target + steal);
    FlushInstructionCache(GetCurrentProcess(), tramp, steal + 14);
    *origOut = tramp;
    DWORD old;
    if (!VirtualProtect(target, steal, PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[32];
    WriteAbsJump(patch, (uptr)detour);
    for (int k = 14; k < steal; k++) patch[k] = 0xCC;
    memcpy(target, patch, steal);
    VirtualProtect(target, steal, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, steal);
    Buf b; b.str("detour installed at ").hex(rva); LogLine(b);
    return true;
}

// ---------------------------------------------------------------- serial pool (MPFEVER_SERIAL=rva,rva,...)
// Some simulation systems hand their work to the engine's thread pool, and the result then depends on which worker
// finishes first (the games drift apart). The task submission functions listed in MPFEVER_SERIAL are redirected to a
// pool of the engine's own kind with ONE worker: their tasks run one after the other, in submission order, while every
// other system, the renderer and the loaders keep all the processor's cores.
static const u32 RVA_POOL_CTOR = 0x3055a10;    // ThreadPool::ThreadPool(this, const std::string& name, int threads, bool)
static const u8 P_ENQ[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x18, 0x48, 0x89, 0x7C, 0x24, 0x20 };
static void* volatile g_serialPool = 0;

struct MsvcString { char buf[16]; u64 size; u64 cap; };
typedef void* (*PoolCtor)(void* self, MsvcString* name, int threads, bool flag);

static void* MakeSerialPool()
{
    u8* mem = (u8*)HeapAlloc(GetProcessHeap(), 8 /* HEAP_ZERO_MEMORY */, 0xe0 + 64);
    if (!mem) return 0;
    mem = (u8*)(((uptr)mem + 31) & ~(uptr)31);
    MsvcString name;
    memset(&name, 0, sizeof(name));
    const char* n = "MPFever Serial";
    int k = 0;
    while (n[k]) { name.buf[k] = n[k]; k++; }
    name.size = (u64)k;
    name.cap = 15;
    ((PoolCtor)(g_base + RVA_POOL_CTOR))(mem, &name, 1, true);
    return mem;
}

// the pool is made on the first redirected submission (the engine is running by then)
static volatile long g_poolLock = 0;
extern "C" void* EnsureSerialPool()
{
    if (g_serialPool) return g_serialPool;
    while (_InterlockedExchange(&g_poolLock, 1)) Sleep(0);
    if (!g_serialPool) {
        g_serialPool = MakeSerialPool();
        Buf b; b.str("serial pool created at ").hex((uptr)g_serialPool); LogLine(b);
    }
    _InterlockedExchange(&g_poolLock, 0);
    return g_serialPool;
}

static bool SerializeSite(u32 rva)
{
    u8* target = (u8*)(g_base + rva);
    Buf b;
    if (memcmp(target, P_ENQ, sizeof(P_ENQ)) != 0) { b.str("serial site ").hex(rva).str(": unexpected bytes, skipped"); LogLine(b); return false; }
    u8* c = (u8*)VirtualAlloc(0, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!c) return false;
    int i = 0;
    static const u8 pre[] = { 0x51, 0x52, 0x41, 0x50, 0x41, 0x51, 0x48, 0x83, 0xEC, 0x28 };   // push rcx rdx r8 r9 / sub rsp,28
    for (u8 x : pre) c[i++] = x;
    c[i++] = 0x48; c[i++] = 0xB8; *(u64*)(c + i) = (u64)&EnsureSerialPool; i += 8;           // mov rax, EnsureSerialPool
    c[i++] = 0xFF; c[i++] = 0xD0;                                                             // call rax
    static const u8 post[] = { 0x48, 0x83, 0xC4, 0x28, 0x41, 0x59, 0x41, 0x58, 0x5A, 0x59,   // add rsp,28 / pop r9 r8 rdx rcx
                               0x48, 0x85, 0xC0, 0x74, 0x03, 0x48, 0x89, 0xC1 };             // test rax,rax / jz +3 / mov rcx,rax
    for (u8 x : post) c[i++] = x;
    memcpy(c + i, P_ENQ, sizeof(P_ENQ)); i += sizeof(P_ENQ);                      // the instructions replaced below
    WriteAbsJump(c + i, (uptr)target + sizeof(P_ENQ)); i += 14;
    FlushInstructionCache(GetCurrentProcess(), c, i);
    DWORD old;
    if (!VirtualProtect(target, sizeof(P_ENQ), PAGE_EXECUTE_READWRITE, &old)) return false;
    u8 patch[16];
    WriteAbsJump(patch, (uptr)c);
    patch[14] = 0xCC;
    memcpy(target, patch, sizeof(P_ENQ));
    VirtualProtect(target, sizeof(P_ENQ), old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(P_ENQ));
    b.str("serial site ").hex(rva).str(" redirected");
    LogLine(b);
    return true;
}

static void SetupSerial()
{
    char v[2048] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_SERIAL", v, sizeof(v) - 1);
    if (n == 0 || n >= sizeof(v) - 1) return;
    u32 cur = 0; bool any = false;
    for (DWORD i = 0; i <= n; i++) {
        char ch = v[i];
        int d = (ch >= '0' && ch <= '9') ? ch - '0' : (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 : (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10 : -1;
        if (d >= 0 && !(ch == 'x' || ch == 'X')) { cur = cur * 16 + d; any = true; }
        else if (ch == 'x' || ch == 'X') { cur = 0; any = false; }
        else { if (any) SerializeSite(cur); cur = 0; any = false; }
    }
}

static bool g_scriptPoolPatched = false;
static u32 g_simPoolA = 0, g_simPoolB = 0;
static u32 g_threads = 0;
typedef void (WINAPI* GetSystemInfoF)(void*);
static GetSystemInfoF g_realGetSystemInfo = 0;

// ---------------------------------------------------------------- Steam invitations
// MPFever.exe writes steam_ctl.txt (one command, rewritten each time): "<seq> presence <connect>" makes the player
// joinable from the Steam friends list (rich presence "connect"), "<seq> invite <connect>" opens Steam's invite dialog,
// "<seq> clear" removes the presence. A friend who accepts while the game runs: Steam's GameRichPresenceJoinRequested
// callback (337) writes steam_join.txt for MPFever.exe. A friend whose game is closed: Steam starts the game with the
// connect string on its command line (see ColdJoin).
typedef void* (*SteamIfaceF)();
typedef bool (*SetRichPresenceF)(void* self, const char* key, const char* value);
typedef void (*ClearRichPresenceF)(void* self);
typedef void (*InviteConnectF)(void* self, const char* connect);
typedef void (*RegisterCallbackF)(void* cb, int id);

extern "C" char __ImageBase;

class JoinCallback {
public:
    // same virtual layout as Steam's CCallbackBase (Run overloads, then GetCallbackSizeBytes)
    virtual void Run(void* param);
    virtual void Run(void* param, bool ioFailure, u64 call);
    virtual int GetCallbackSizeBytes();
    u8 flags;
    int id;
};

static void WriteSessionFile(const char* name, const char* text, int len)
{
    char path[400];
    PathOf(path, name);
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, 2 /* CREATE_ALWAYS */, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD w;
    WriteFile(f, text, (DWORD)len, &w, 0);
    CloseHandle(f);
}

void JoinCallback::Run(void* param)
{
    // GameRichPresenceJoinRequested_t { CSteamID friend; char connect[256]; }
    const char* connect = (const char*)param + 8;
    int n = 0;
    while (n < 255 && connect[n]) n++;
    static long seq = 0;
    Buf b;
    b.dec(GetTickCount()).str("-").dec(_InterlockedIncrement(&seq)).str("\t");
    for (int i = 0; i < n; i++) b.s[b.n++] = connect[i];
    b.s[b.n++] = '\n';
    WriteSessionFile("steam_join.txt", b.s, b.n);
    Buf l; l.str("steam: join requested by a friend"); LogLine(l);
}
void JoinCallback::Run(void* param, bool, u64) { Run(param); }
int JoinCallback::GetCallbackSizeBytes() { return 8 + 256; }

static JoinCallback g_joinCb;

static DWORD WINAPI SteamThread(void*)
{
    HMODULE sa = 0;
    void* friends = 0;
    for (int i = 0; i < 600 && !friends; i++) {   // the game initialises Steam during its start
        Sleep(500);
        if (!sa) sa = GetModuleHandleW(L"steam_api64.dll");
        if (!sa) continue;
        auto get = (SteamIfaceF)GetProcAddress(sa, "SteamAPI_SteamFriends_v017");
        if (get) friends = get();
    }
    if (!friends) { Buf b; b.str("steam: friends interface not available, invitations off"); LogLine(b); return 0; }
    auto setRp = (SetRichPresenceF)GetProcAddress(sa, "SteamAPI_ISteamFriends_SetRichPresence");
    auto clearRp = (ClearRichPresenceF)GetProcAddress(sa, "SteamAPI_ISteamFriends_ClearRichPresence");
    auto invite = (InviteConnectF)GetProcAddress(sa, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString");
    auto reg = (RegisterCallbackF)GetProcAddress(sa, "SteamAPI_RegisterCallback");
    if (reg) reg(&g_joinCb, 337);
    { Buf b; b.str("steam: invitations ready").str(reg ? "" : " (no join callback)"); LogLine(b); }
    char last[64] = {};
    static char buf[1024];
    for (;;) {
        Sleep(250);
        char path[400];
        PathOf(path, "steam_ctl.txt");
        HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | 4, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if (f == INVALID_HANDLE_VALUE) continue;
        DWORD got = 0;
        ReadFile(f, buf, sizeof(buf) - 1, &got, 0);
        CloseHandle(f);
        buf[got] = 0;
        while (got && (buf[got - 1] == '\n' || buf[got - 1] == '\r')) buf[--got] = 0;
        // "<seq> <command> [argument]"
        int a = 0;
        while (buf[a] && buf[a] != ' ') a++;
        if (!buf[a] || a >= 63) continue;
        buf[a] = 0;
        if (!memcmp(buf, last, a + 1)) continue;
        memcpy(last, buf, a + 1);
        char* cmd = buf + a + 1;
        int c = 0;
        while (cmd[c] && cmd[c] != ' ') c++;
        char* arg = cmd[c] ? cmd + c + 1 : cmd + c;
        cmd[c] = 0;
        Buf l; l.str("steam: ").str(cmd).str(" ").str(arg); LogLine(l);
        if (!memcmp(cmd, "presence", 9) && setRp) { setRp(friends, "connect", arg); setRp(friends, "status", "MPFever"); }
        else if (!memcmp(cmd, "invite", 7) && invite) invite(friends, arg);
        else if (!memcmp(cmd, "clear", 6) && clearRp) clearRp(friends);
    }
}

// Started by Steam from an invitation ("+mpfever_connect <address>" on the command line) without MPFever: MPFever.exe,
// whose path the launcher wrote next to this module (mpfever_path.txt), is started with --join, and this game quits
// (MPFever starts its own).
static bool ColdJoin()
{
    const wchar_t* cl = GetCommandLineW();
    const wchar_t* key = L"+mpfever_connect";
    const wchar_t* at = 0;
    for (const wchar_t* p = cl; *p && !at; p++) {
        int k = 0;
        while (key[k] && p[k] == key[k]) k++;
        if (!key[k]) at = p + k;
    }
    if (!at) return false;
    while (*at == ' ' || *at == '"') at++;
    wchar_t addr[128];
    int n = 0;
    while (at[n] && at[n] != ' ' && at[n] != '"' && n < 127) { addr[n] = at[n]; n++; }
    addr[n] = 0;
    // MPFever.exe path: mpfever_path.txt next to this module (UTF-16 written by the launcher)
    wchar_t mod[300];
    DWORD ml = GetModuleFileNameW((HMODULE)&__ImageBase, mod, 260);
    while (ml && mod[ml - 1] != '\\') ml--;
    const wchar_t* fname = L"mpfever_path.txt";
    for (int k = 0; fname[k]; k++) mod[ml++] = fname[k];
    mod[ml] = 0;
    char modA[300];
    for (DWORD k = 0; k <= ml; k++) modA[k] = (char)mod[k];   // ASCII-only paths only for CreateFileA
    HANDLE f = CreateFileA(modA, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) return false;
    static wchar_t exe[300];
    DWORD got = 0;
    ReadFile(f, exe, sizeof(exe) - 2, &got, 0);
    CloseHandle(f);
    int el = (int)(got / 2);
    if (el && exe[0] == 0xFEFF) { for (int k = 1; k < el; k++) exe[k - 1] = exe[k]; el--; }
    while (el && (exe[el - 1] == '\n' || exe[el - 1] == '\r')) el--;
    exe[el] = 0;
    if (!el) return false;
    static wchar_t cmd[600];
    int k = 0;
    cmd[k++] = '"';
    for (int i = 0; exe[i]; i++) cmd[k++] = exe[i];
    const wchar_t* mid = L"\" --join ";
    for (int i = 0; mid[i]; i++) cmd[k++] = mid[i];
    for (int i = 0; addr[i]; i++) cmd[k++] = addr[i];
    cmd[k] = 0;
    STARTUPINFOW_ si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION_ pi = {};
    if (!CreateProcessW(0, cmd, 0, 0, 0, 0, 0, 0, &si, &pi)) return false;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    TerminateProcess(GetCurrentProcess(), 0);
    return true;
}

static DWORD WINAPI Init(void*)
{
    g_base = (uptr)GetModuleHandleW(0);
    auto dos = (IMAGE_DOS_HEADER_*)g_base;
    u8* ntp = (u8*)(g_base + dos->e_lfanew);
    auto fh = (IMAGE_FILE_HEADER_*)(ntp + 4);
    auto sec = (IMAGE_SECTION_HEADER_*)(ntp + 4 + sizeof(IMAGE_FILE_HEADER_) + fh->SizeOfOptionalHeader);
    for (int i = 0; i < fh->NumberOfSections; i++) {
        if (sec[i].Name[0] == '.' && sec[i].Name[1] == 't' && sec[i].Name[2] == 'e' && sec[i].Name[3] == 'x') {
            g_textStart = g_base + sec[i].VirtualAddress;
            g_textEnd = g_textStart + sec[i].VirtualSize;
        }
    }
    char dir[300] = {};
    DWORD dl = GetEnvironmentVariableA("MPFEVER_DIR", dir, 260);
    // loaded by every start of the game (winhttp.dll slot): without an MPFever session it does nothing at all, except
    // when Steam started the game from an MPFever invitation
    if (dl == 0 || dl >= 260) { ColdJoin(); return 0; }
    {
        const char* tail = "\\native.log";
        int k = 0;
        while (tail[k]) { dir[dl + k] = tail[k]; k++; }
        dir[dl + k] = 0;
        for (DWORD q = 0; q < dl; q++) g_dir[q] = dir[q];
        g_dirLen = (int)dl;
        g_log = CreateFileA(dir, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (g_log == INVALID_HANDLE_VALUE) g_log = 0;
    }
    Buf b;
    b.str("mpfever_native v3 loaded, base ").hex(g_base).str(", build stamp ").hex(fh->TimeDateStamp);
    LogLine(b);
    { Buf t; t.str(g_scriptPoolPatched ? "game scripts: own pool, one worker" : "game scripts: pool NOT patched"); LogLine(t); }
    if (g_simPoolA || g_simPoolB) { Buf t; t.str("pool sizes forced: ").hex(g_simPoolA).str(",").hex(g_simPoolB); LogLine(t); }
    if (g_threads) { Buf t; t.str("engine told it has ").hex(g_threads).str(" processor(s)").str(g_realGetSystemInfo ? "" : " (GetSystemInfo not patched)"); LogLine(t); }
    if (fh->TimeDateStamp != EXPECTED_TIMESTAMP) {
        Buf w; w.str("unknown game build: inert"); LogLine(w);
        return 0;
    }
    InstallDetour(RVA_ADD, P_ADD, sizeof(P_ADD), (void*)&AddDetour, (void**)&g_addOrig);
    { HANDLE st = CreateThread(0, 0, SteamThread, 0, 0, 0); if (st) CloseHandle(st); }
    SetupSerial();
    // ArmMapSites();   (diagnostic: map lookup failures, see sites_gen.h)
    { char v[4]; if (GetEnvironmentVariableA("MPFEVER_SITES", v, 3) > 0) ArmSites(); }   // diagnostic: which check says "not possible"
    return 0;
}

// ---------------------------------------------------------------- engine thread count (MPFEVER_THREADS=n)
// The engine spreads parts of the simulation (traffic, persons) over a thread pool sized from the processor count;
// the result then depends on thread timing and two games drift apart. With MPFEVER_THREADS set, the game is told it
// has n processors (msvcp140 _Thrd_hardware_concurrency and GetSystemInfo, patched in the game's import table at
// load time, before the engine creates its pool).

extern "C" u32 HardwareConcurrency() { return g_threads; }
extern "C" void WINAPI GetSystemInfoHook(void* si)
{
    g_realGetSystemInfo(si);
    *(DWORD*)((u8*)si + 32) = g_threads;   // SYSTEM_INFO.dwNumberOfProcessors
}

static bool SameNoCase(const char* a, const char* b)
{
    for (; *a && *b; a++, b++) {
        char x = *a, y = *b;
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return false;
    }
    return *a == *b;
}

static void* PatchImport(uptr base, const char* dll, const char* fn, void* repl)
{
    auto dos = (IMAGE_DOS_HEADER_*)base;
    u8* opt = (u8*)(base + dos->e_lfanew) + 4 + sizeof(IMAGE_FILE_HEADER_);
    u32 impRva = *(u32*)(opt + 112 + 8);   // PE32+ DataDirectory[1] (imports)
    if (!impRva) return 0;
    for (u32* d = (u32*)(base + impRva); d[3]; d += 5) {
        if (!SameNoCase((const char*)(base + d[3]), dll)) continue;
        u64* names = (u64*)(base + (d[0] ? d[0] : d[4]));
        u64* iat = (u64*)(base + d[4]);
        for (int i = 0; names[i]; i++) {
            if (names[i] >> 63) continue;   // by ordinal
            if (!SameNoCase((const char*)(base + (u32)names[i] + 2), fn)) continue;
            void* old = (void*)iat[i];
            DWORD prot;
            VirtualProtect(&iat[i], 8, 4 /* PAGE_READWRITE */, &prot);
            iat[i] = (u64)repl;
            VirtualProtect(&iat[i], 8, prot, &prot);
            return old;
        }
    }
    return 0;
}

static void LimitThreads()
{
    char v[16] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_THREADS", v, 15);
    if (n == 0 || n >= 15) return;
    u32 t = 0;
    for (DWORD i = 0; i < n && v[i] >= '0' && v[i] <= '9'; i++) t = t * 10 + (v[i] - '0');
    if (t == 0) return;
    g_threads = t;
    uptr base = (uptr)GetModuleHandleW(0);
    PatchImport(base, "msvcp140.dll", "_Thrd_hardware_concurrency", (void*)&HardwareConcurrency);
    void* real = PatchImport(base, "kernel32.dll", "GetSystemInfo", (void*)&GetSystemInfoHook);
    if (real) g_realGetSystemInfo = (GetSystemInfoF)real;
}

// ---------------------------------------------------------------- simulation pools size (MPFEVER_SIMPOOL=a,b)
// Two of the engine's pools are sized round(0.55 * cores + 0.75) by static initialisers (0x1b3c0 -> [0x4054fa8],
// 0x1b410 -> [0x4054fa4]). MPFEVER_SIMPOOL patches those initialisers (in DllMain, before the game's own static
// initialisation runs) to fixed sizes; the processor count, the main pool and everything else stay untouched.
static void PatchPoolInit(uptr base, u32 fnRva, u32 globalRva, u32 value)
{
    u8* f = (u8*)(base + fnRva);
    if (f[0] != 0x48 || f[1] != 0x83 || f[2] != 0xEC || f[3] != 0x28) return;   // sub rsp, 28h
    u8 code[16];
    int i = 0;
    i32 rel = (i32)((i64)(base + globalRva) - (i64)(base + fnRva + 10));
    code[i++] = 0xC7; code[i++] = 0x05; *(i32*)(code + i) = rel; i += 4; *(u32*)(code + i) = value; i += 4;   // mov dword [rip+rel], value
    code[i++] = 0xC3;                                                                                       // ret
    DWORD prot;
    VirtualProtect(f, 16, PAGE_EXECUTE_READWRITE, &prot);
    memcpy(f, code, i);
    VirtualProtect(f, 16, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), f, 16);
}
static void SetupSimPools()
{
    char v[32] = {};
    DWORD n = GetEnvironmentVariableA("MPFEVER_SIMPOOL", v, 31);
    if (n == 0 || n >= 31) return;
    u32 a = 0, b = 0; DWORD i = 0;
    for (; i < n && v[i] >= '0' && v[i] <= '9'; i++) a = a * 10 + (v[i] - '0');
    if (i < n && v[i] == ',') for (i++; i < n && v[i] >= '0' && v[i] <= '9'; i++) b = b * 10 + (v[i] - '0');
    uptr base = (uptr)GetModuleHandleW(0);
    if (a) { PatchPoolInit(base, 0x1b3c0, 0x4054fa8, a); g_simPoolA = a; }
    if (b) { PatchPoolInit(base, 0x1b410, 0x4054fa4, b); g_simPoolB = b; }
}

// ---------------------------------------------------------------- game scripts run one after the other
// The game scripts (Lua: towns, loans, industries...) are updated on a thread pool. On processors with fewer than 8
// threads the engine gives them their own pool of max(1, threads/2) workers; with 8 threads or more they share the
// general pool and run in parallel, in an order that depends on thread timing, so two games drift apart. Patched here
// (before the pool is made): the dedicated pool always exists, with one worker. Only the scripts' update is serial;
// the simulation systems, the renderer and the loaders keep every core.
static void PatchScriptPool(uptr base)
{
    static const u8 expect[] = { 0x83, 0xF8, 0x08, 0x0F, 0x8D, 0x25, 0x01, 0x00, 0x00,     // cmp eax,8 / jge (shared pool)
                                 0xC7, 0x44, 0x24, 0x20, 0x01, 0x00, 0x00, 0x00,           // mov [rsp+20h],1
                                 0xE8 };                                                   // call hardware_concurrency
    u8* p = (u8*)(base + 0xaaec2c);
    if (memcmp(p, expect, sizeof(expect)) != 0) return;
    DWORD prot;
    VirtualProtect(p, 32, PAGE_EXECUTE_READWRITE, &prot);
    for (int k = 3; k < 9; k++) p[k] = 0x90;                    // never the shared pool
    u8* c = p + 17;                                              // threads/2 -> 0, so max(1, ...) = 1 worker
    c[0] = 0x31; c[1] = 0xC0; c[2] = 0x0F; c[3] = 0x1F; c[4] = 0x00;   // xor eax,eax / nop
    VirtualProtect(p, 32, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), p, 32);
    g_scriptPoolPatched = true;
}

// ---------------------------------------------------------------- multiplayer page in the game's main menu
// The main menu's UI runs in its own Lua state, which no mod file reaches (mods are only mounted in a game). lua_load is
// wrapped: when the engine loads gui/menu/main_menu.tl, one statement is put in front of its source that loads
// mpfever_1::/mpfever_menu.lua, which adds the multiplayer page through the UI's own recipe replacement table.
typedef const char* (*LuaReader)(void* L, void* ud, size_t* size);
typedef int (*LuaLoadF)(void* L, LuaReader reader, void* data, const char* chunkname, const char* mode);
static const u32 RVA_LUA_LOAD = 0x2fbdf70;
static const u8 P_LUA_LOAD[] = { 0x48, 0x89, 0x5C, 0x24, 0x10, 0x56, 0x48, 0x83, 0xEC, 0x50, 0x49, 0x8B, 0xD9, 0x48, 0x8B, 0xF1 };
static LuaLoadF g_luaLoadOrig = 0;
static const char MENU_PREFIX[] = "do local ok, e = pcall(require, \"mpfever_1::/mpfever_menu.lua\") if not ok then print(\"[MPFEVER-MENU] \" .. tostring(e)) end end ";
static volatile long g_menuInjected = 0;

struct MenuReader { LuaReader reader; void* data; int stage; const char* held; size_t heldSize; };

extern "C" const char* MenuReaderFn(void* L, void* ud, size_t* size)
{
    MenuReader* m = (MenuReader*)ud;
    if (m->stage == 0) {
        size_t n = 0;
        const char* blk = m->reader(L, m->data, &n);
        if (!blk || n == 0 || blk[0] == 0x1B) { m->stage = 2; *size = n; return blk; }   // empty or precompiled: untouched
        m->held = blk; m->heldSize = n; m->stage = 1;
        *size = sizeof(MENU_PREFIX) - 1;
        return MENU_PREFIX;
    }
    if (m->stage == 1) { m->stage = 2; *size = m->heldSize; return m->held; }
    return m->reader(L, m->data, size);
}

static bool EndsWith(const char* s, const char* tail)
{
    int a = 0, b = 0;
    while (s[a]) a++;
    while (tail[b]) b++;
    return a >= b && memcmp(s + a - b, tail, b) == 0;
}

extern "C" int LuaLoadDetour(void* L, LuaReader reader, void* data, const char* chunkname, const char* mode)
{
    if (chunkname && EndsWith(chunkname, "gui/menu/main_menu.tl")) {
        MenuReader m = { reader, data, 0, 0, 0 };
        int r = g_luaLoadOrig(L, MenuReaderFn, &m, chunkname, mode);
        if (_InterlockedIncrement(&g_menuInjected) == 1) { Buf b; b.str("main menu: multiplayer page added (").str(chunkname).str(")"); LogLine(b); }
        return r;
    }
    return g_luaLoadOrig(L, reader, data, chunkname, mode);
}

extern "C" BOOL WINAPI DllMain(HMODULE inst, DWORD reason, void*)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        char d[8];
        if (GetEnvironmentVariableA("MPFEVER_DIR", d, 1) > 0) {
            LimitThreads(); SetupSimPools(); PatchScriptPool((uptr)GetModuleHandleW(0));
            g_base = (uptr)GetModuleHandleW(0);
            auto dos = (IMAGE_DOS_HEADER_*)g_base;
            auto fh = (IMAGE_FILE_HEADER_*)((u8*)(g_base + dos->e_lfanew) + 4);
            if (fh->TimeDateStamp == EXPECTED_TIMESTAMP)
                InstallDetour(RVA_LUA_LOAD, P_LUA_LOAD, sizeof(P_LUA_LOAD), (void*)&LuaLoadDetour, (void**)&g_luaLoadOrig);
        }
        HANDLE t = CreateThread(0, 0, Init, 0, 0, 0);
        if (t) CloseHandle(t);
    }
    return 1;
}
