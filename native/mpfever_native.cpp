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

static u32 g_threads = 0;
typedef void (WINAPI* GetSystemInfoF)(void*);
static GetSystemInfoF g_realGetSystemInfo = 0;

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
    // loaded by every start of the game (winhttp.dll slot): without an MPFever session it does nothing at all
    if (dl == 0 || dl >= 260) return 0;
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
    if (g_threads) { Buf t; t.str("engine told it has ").hex(g_threads).str(" processor(s)").str(g_realGetSystemInfo ? "" : " (GetSystemInfo not patched)"); LogLine(t); }
    if (fh->TimeDateStamp != EXPECTED_TIMESTAMP) {
        Buf w; w.str("unknown game build: inert"); LogLine(w);
        return 0;
    }
    InstallDetour(RVA_ADD, P_ADD, sizeof(P_ADD), (void*)&AddDetour, (void**)&g_addOrig);
    // ArmMapSites();   (diagnostic: map lookup failures, see sites_gen.h)
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

extern "C" BOOL WINAPI DllMain(HMODULE inst, DWORD reason, void*)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        char d[8];
        if (GetEnvironmentVariableA("MPFEVER_DIR", d, 1) > 0) LimitThreads();
        HANDLE t = CreateThread(0, 0, Init, 0, 0, 0);
        if (t) CloseHandle(t);
    }
    return 1;
}
