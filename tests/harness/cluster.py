"""Several complete mocked games (UI state + game script GUI half + simulation half, running the real MPFever Lua files)
and a mocked relay standing in for MPFever.exe, with an optional network emulator.

Taken over from tests/test_lockstep.py (0.1.0) and generalised to N games (T0.9) and network emulation (T0.10).
Time model: one *round* = one GUI frame of every game followed by one relay pump; a *tick* = 5 rounds + one
simulation tick of every game (SIMSTEP). Network delays are counted in rounds.
"""
import heapq
import os
import random

from . import lua

TAB = chr(9)
STEP = 200
ROUND_SECONDS = 0.04      # one GUI frame; 5 rounds = one simulation tick = one step at x1 (200 ms of game time)

VIRTUAL_TIME = """
VCLOCK = 0
local realTime = os.time
os.clock = function() return VCLOCK end
os.time = function(t) if t then return realTime(t) end return 1760000000 + math.floor(VCLOCK) end
"""


class Tail:
    """Reads the lines appended to a file since the last call. Opens the file only when it grew: opening a file costs
    about 2 ms on Windows (virus scanner), which made the old test take 17 s."""

    def __init__(self, path):
        self.path, self.off, self.rest = path, 0, b""

    def new_lines(self):
        try:
            size = os.stat(self.path).st_size
        except FileNotFoundError:
            return []
        if size <= self.off:
            return []
        with open(self.path, "rb") as f:
            f.seek(self.off)
            data = self.rest + f.read(size - self.off)
        self.off = size
        *lines, self.rest = data.split(b"\n")
        return [l.decode("utf-8").rstrip("\r") for l in lines if l.strip()]


class MockGame:
    def __init__(self, name, role, tmp, first_entity, dll=True):
        self.name, self.role, self.dir = name, role, os.path.join(tmp, name)
        os.makedirs(self.dir)
        open(os.path.join(self.dir, "in.log"), "w").close()
        self.L = lua.new_runtime({"MPFEVER_DIR": self.dir, "MPFEVER_NAME": name, "MPFEVER_ROLE": role})
        # virtual time: os.clock() is the CPU time of the whole test process in Lua and os.time() the wall clock; the
        # mod uses both for timeouts, which made runs differ. The cluster advances VCLOCK by ROUND_SECONDS per round.
        self.L.execute(VIRTUAL_TIME)
        self.L.execute("GAME.nextEntity = %d" % first_entity)
        if dll:
            self.L.globals().MOCK_DLL.dir = self.dir     # the native module is there (known game build)
        self.T = lua.load_bridge(self.L, expose=True)
        self.L.execute(lua.harness_source("bridge_harness.lua"))
        ui_src = lua.source("mpfever_ui.script.lua")
        ui_src = ui_src.replace("local M = {}", "local M = {}; U.stepping = true", 1)
        ui_src = ui_src.replace("function data()", "POLL = function() pollBindings(); return pollResults() end" + chr(10) + "function data()", 1)
        # the UI script in its own environment (separate module state) but the same mocked engine
        self.L.globals().UI_SRC = ui_src
        self.L.execute('''
          local env = setmetatable({}, { __index = _G })
          env.data = nil
          -- the UI state has its own api.cmd table (wrapping it must not affect the game script state)
          local cmdCopy = {}
          for k, v in pairs(api.cmd) do cmdCopy[k] = v end
          env.api = setmetatable({ cmd = cmdCopy }, { __index = api })
          local chunk = load(UI_SRC, "ui", "t", env)
          chunk()
          UI = env
          UI_MOD = env.data()
          UI_MOD.doReplace(nil)
        ''')
        self.out = Tail(os.path.join(self.dir, "out.log"))
        self.lag = None          # function(tick index) -> True when this game skips its simulation tick

    def read(self, f):
        p = os.path.join(self.dir, f)
        if not os.path.exists(p):
            return []
        with open(p, encoding="utf-8") as fh:
            return fh.read().splitlines()

    def write(self, line):
        with open(os.path.join(self.dir, "in.log"), "a", encoding="utf-8", newline="\n") as f:
            f.write(line + "\n")

    def tool_build(self, lua_proposal):
        """A player's construction tool sends a build (held by the native module when it is there)."""
        self.L.execute("TOOL_BUILD({ __cmd = 'native_build', args = { %s, nil, false, true } })" % lua_proposal)

    def time(self):
        return self.L.eval("GAME.time")

    def applied(self):
        s = self.L.eval("(function() local r = {} for i, a in ipairs(GAME.applied) do r[i] = a.name .. '@' .. a.time end return table.concat(r, ',') end)()")
        return s.split(",") if s else []

    def ui(self, code):
        """Runs code in the UI state, with `api` bound to the UI's (wrapped) api table."""
        self.L.execute("local api = UI.api\n" + code)


class NetEm:
    """Network emulation between the games and the relay. Every game has a link to the relay (the host's game is on
    the relay's PC: no delay). A message from game a to game b waits link(a) + link(b) rounds, each drawn as
    latency + uniform(0, jitter). Delivery keeps the order per pair (the real transport is TCP)."""

    def __init__(self, latency=0, jitter=0, seed=1):
        self.latency, self.jitter, self.rng = latency, jitter, random.Random(seed)

    def link(self, game_role):
        if game_role == "host" or (self.latency == 0 and self.jitter == 0):
            return 0
        return self.latency + self.rng.randint(0, self.jitter)

    def __repr__(self):
        return "NetEm(latency=%d, jitter=%d)" % (self.latency, self.jitter)


# messages MPFever.exe handles itself on the host (MainForm.OnHostMessage) instead of relaying them
HOST_ONLY = {"hello", "replay_failed", "save_done", "act_fail", "act_refused", "speed_req", "sync_hash", "det_hash"}


class MockRelay:
    """Stand-in for MPFever.exe on the host: turns clocks into peer clocks, relays every other message like
    MainForm.OnHostMessage (except HOST_ONLY, counted in .consumed), owns the session (speed, pause)."""

    def __init__(self, games, netem=None):
        self.games, self.netem = games, netem or NetEm()
        self.clock, self.round, self.queue, self.seq, self.last_due = {}, 0, [], 0, {}
        self.started, self.speed, self.pauseAt = False, 0, None
        self.delivered, self.consumed = 0, {}

    def _send(self, src_role, dst, line):
        due = self.round + self.netem.link(src_role) + self.netem.link(dst.role)
        key = (src_role, dst.name)
        due = max(due, self.last_due.get(key, 0))
        self.last_due[key] = due
        self.seq += 1
        heapq.heappush(self.queue, (due, self.seq, dst.name, line))

    def broadcast(self, kind, payload, exclude=None):
        """A message from the relay itself (session, welcome...)."""
        for g in self.games:
            if g is not exclude:
                self._send("host", g, kind + TAB + "Hote" + TAB + payload)

    def session(self):
        p = '{["started"]=%s,["speed"]=%d%s}' % ("true" if self.started else "false", self.speed,
            (',["pauseAt"]=%d' % self.pauseAt) if self.pauseAt is not None else "")
        self.broadcast("session", p)

    def stamp(self):
        return ((max(self.clock.values()) + 8 * STEP + STEP - 1) // STEP) * STEP

    def pump(self):
        self.round += 1
        for g in self.games:
            for line in g.out.new_lines():
                kind, frm, payload = line.split(TAB, 2)
                if kind == "clock":
                    t = int(payload.split('["t"]=')[1].split(",")[0].split("}")[0])
                    ah = int(payload.split('["ah"]=')[1].split(",")[0].split("}")[0]) if '["ah"]=' in payload else 3
                    self.clock[g.name] = t
                    for o in self.games:
                        if o is not g:
                            self._send(g.role, o, "peerclock" + TAB + "Hote" + TAB + '{["name"]="%s",["t"]=%d,["ah"]=%d}' % (g.name, t, ah))
                elif kind in HOST_ONLY:
                    self.consumed[kind] = self.consumed.get(kind, 0) + 1
                else:
                    # like MainForm.OnHostMessage: act, nat_pending, nat_cancel, chat... go to every other game
                    for o in self.games:
                        if o is not g:
                            self._send(g.role, o, kind + TAB + g.name + TAB + payload)
        byname = {g.name: g for g in self.games}
        while self.queue and self.queue[0][0] <= self.round:
            _, _, dst, line = heapq.heappop(self.queue)
            byname[dst].write(line)
            self.delivered += 1


class Cluster:
    """N mocked games: games[0] is the host, the others are clients. Client i skips its simulation tick on the ticks
    where tick % (i + 2) == 0 when `lag` is on (slower PCs), like the old test's lagging client."""

    def __init__(self, tmp, n=2, netem=None, dll=True):
        names = ["Hote", "Client", "Client2", "Client3", "Client4", "Client5", "Client6", "Client7"]
        self.games = [MockGame(names[i], "host" if i == 0 else "client", tmp, 50000 + 1000 * i, dll) for i in range(n)]
        for i, g in enumerate(self.games[1:], 1):
            g.lag = (lambda k, m=i + 2: k % m == 0)
        self.relay = MockRelay(self.games, netem)
        self.ticks, self.clock = 0, 0.0
        # the welcome is already there when the game starts (connection set up before the savegame is loaded)
        for g in self.games:
            g.write("welcome" + TAB + "Hote" + TAB + '{["you"]="%s",["role"]="%s"}' % (g.name, g.role))

    @property
    def host(self):
        return self.games[0]

    def tick(self, n=1, lag=False):
        for _ in range(n):
            self.ticks += 1
            for _ in range(5):
                self.clock += ROUND_SECONDS
                for g in self.games:
                    g.L.globals().VCLOCK = self.clock
                    g.L.execute("FRAME()")
                    g.L.execute("UI.POLL()")
                self.relay.pump()
            for g in self.games:
                if not (lag and g.lag and g.lag(self.ticks)):
                    g.L.execute("SIMSTEP()")

    def tick_until(self, cond, max_ticks, lag=False):
        """Ticks until cond() holds (checked after every tick); returns the number of ticks used, or None."""
        for i in range(1, max_ticks + 1):
            self.tick(1, lag)
            if cond():
                return i
        return None

    def logs(self):
        lines = []
        for g in self.games:
            lines += g.read("mod.log") + g.read("ui_mod.log")
        return lines


class Checks:
    """Collects named checks of a scenario; the test fails at the end with every failed check listed."""

    def __init__(self):
        self.results = []

    def check(self, cond, msg):
        self.results.append((bool(cond), msg))
        return bool(cond)

    @property
    def failed(self):
        return [m for ok, m in self.results if not ok]

    def summary(self):
        return "\n".join(("OK   " if ok else "FAIL ") + m for ok, m in self.results)
