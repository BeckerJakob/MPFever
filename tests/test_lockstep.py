"""Offline lockstep test: two complete mocked games (UI state + game script GUI half + simulation half) and a mocked
host relay, all running the real MPFever Lua files through lupa (Lua 5.2).

The mocked engine reproduces the trap seen in the game: entity ids allocated during the session DIFFER between the
two games (game B allocates 1000 higher). Checks:
  - actions captured on either game are applied by both simulations at the same game time;
  - entity references (depot of a purchase, vehicle of a line assignment, nodes of a road) resolve to each game's
    own local entity; a reference that cannot be resolved is skipped instead of crashing;
  - native tools: preview vetoed, CONSTRUIRE confirms, both games build at the same time;
  - pause at the same step on both games, action during the pause applied at the pause time on both;
  - the originator's tool receives the real result.
Run: python MPFever/tests/test_lockstep.py
"""
import os, sys, tempfile, shutil
import lupa.lua52 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
TAB = chr(9)
STEP = 200

MOCK = r'''
-- world: entities from the save have the same ids everywhere; new ones start at GAME.nextEntity (differs per game)
GAME = { time = 18600, speed = 0, applied = {}, guiQueue = {}, engine = false, inUpdate = false, nextEntity = 50000 }
WORLD = {
  [7] = { PLAYER = {} },
  [54] = { CONSTRUCTION = { fileName = "depot.con", transf = { [13] = 100, [14] = 200, [15] = 5 }, depots = { 55 }, stations = {} } },
  [55] = { VEHICLE_DEPOT = {} },
  [60] = { BASE_NODE = { position = { x = 10, y = 10, z = 0 } } },
  [100] = { TOWN = { sizeFactors = { 1 } } },
}
local function newEntity(comps) GAME.nextEntity = GAME.nextEntity + 1; WORLD[GAME.nextEntity] = comps; return GAME.nextEntity end
local function mk(name) return function(...) return { __cmd = name, args = { ... } } end end
local function execute(cmd, cb)
  local name = cmd.__cmd
  if name == "makeGameSetSpeedCmd" then GAME.speed = cmd.args[1]; if cb then cb({}, true, {}) end return end
  if name == "makeScriptingSendEventCmd" then
    if cmd.args[1] == "mpfever" then SIM_EVENT(cmd.args[3], cmd.args[4]) end
    if cb then cb({}, true, {}) end
    return
  end
  local created = nil
  local rec = { name = name, time = GAME.time, args = cmd.args }
  if name == "makeVehicleBuyCmd" then
    assert(WORLD[cmd.args[2]] and WORLD[cmd.args[2]].VEHICLE_DEPOT, "buy in a depot that does not exist")
    -- like the real engine seems to: the vehicle entity appears at the next step (engine path)
    if GAME.inUpdate then
      GAME.nextEntity = GAME.nextEntity + 1
      created = GAME.nextEntity
      GAME.deferred = GAME.deferred or {}
      GAME.deferred[#GAME.deferred + 1] = created
    else
      created = newEntity({ TRANSPORT_VEHICLE = {} })
    end
  elseif name == "makeLineCreateCmd" then
    created = newEntity({ LINE = {} })
  elseif name == "makeVehicleSetLineCmd" then
    assert(WORLD[cmd.args[1]] and WORLD[cmd.args[1]].TRANSPORT_VEHICLE, "vehicle does not exist")
    assert(WORLD[cmd.args[2]] and WORLD[cmd.args[2]].LINE, "line does not exist")
  elseif name == "makeWorldBuildProposalCmd" or name == "native_build" then
    -- the engine announces every build to the game scripts before and after applying it
    local proposal = cmd.args[1]
    if BUILD_EVENT then BUILD_EVENT("onPreBuildProposal", proposal, cmd.args[4] ~= false, {}) end
    local empty = name == "native_build" and #(proposal.toAdd or {}) == 0 and #((proposal.proposal or {}).addedSegments or {}) == 0
    rec.name = "build"
    if empty then
      rec = nil
    else
      created = newEntity({ CONSTRUCTION = { fileName = "built.con", transf = { [13] = 1, [14] = 2, [15] = 3 }, depots = {}, stations = {} } })
    end
    if BUILD_EVENT then BUILD_EVENT("onPostBuildProposal", proposal, cmd.args[4] ~= false, created and { created } or {}) end
    if rec == nil then return end
  end
  rec.entity = created
  GAME.applied[#GAME.applied + 1] = rec
  if cb then cb({ resultVehicleEntity = created }, true, { { created, 1 } }) end
end
GAME_EXECUTE = execute
SIM_EVENT = function() end
local CTN = { GAME_TIME = 1, ACCOUNT = 2, TOWN = 3, CONSTRUCTION = 4, GAME_SPEED = 5, VEHICLE_DEPOT = 6, BASE_NODE = 7,
  BASE_EDGE = 8, TRANSPORT_VEHICLE = 9, LINE = 10, STATION = 11, STATION_GROUP = 12, MOVE_PATH = 13, TOWN_BUILDING = 14, SIM_PERSON = 15 }
local NAMEOF = {}
for k, v in pairs(CTN) do NAMEOF[v] = k end
api = {
  cmd = {
    sendCommand = function(cmd, cb, progress)
      if GAME.engine then
        if cb and GAME.inUpdate then error("Callbacks are currently disallowed") end
        execute(cmd, cb)
      else GAME.guiQueue[#GAME.guiQueue + 1] = { cmd, cb } end
    end,
    debug = { makeGamePerformSimulationStepsCmd = mk("steps") },
  },
  type = {
    ComponentType = CTN,
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
    Vec4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end },
    Mat4f = { new = function(a, b, c, d) return { a, b, c, d } end },
    Context = { new = function() return {} end },
    SimpleProposal = { new = function() return { streetProposal = { nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {} }, constructionsToAdd = {} } end,
      ConstructionEntity = { new = function() return {} end } },
    NodeAndEntity = { new = function() return {} end },
    SegmentAndEntity = { new = function() return {} end },
    BaseNode = { new = function() return {} end },
    BaseEdge = { new = function() return {} end },
    BaseEdgeStreet = { new = function() return {} end },
    TransportVehicleConfig = { new = function() return {} end },
    TransportVehiclePart = { new = function() return {} end },
    VehiclePart = { new = function() return {} end },
    LoadConfig = { new = function() return {} end },
    Line = { new = function() return { stops = {} } end, Stop = { new = function() return {} end }, StopConfig = { new = function() return {} end } },
    StationTerminal = { new = function() return {} end },
  },
  engine = {
    getComponent = function(e, t)
      if t == 1 then return { gameTime = GAME.time } end
      if t == 5 then return { speedup = GAME.speed } end
      if t == 2 then return { balance = 1000, loan = 0 } end
      local w = WORLD[e]
      return w and w[NAMEOF[t]] or nil
    end,
    entityExists = function(e) return WORLD[e] ~= nil end,
    util = { getWorld = function() return 1 end, getPlayer = function() return 7 end },
    forEachEntityWithComponent = function(fn, t)
      local ids = {}
      for e, w in pairs(WORLD) do if w[NAMEOF[t]] then ids[#ids + 1] = e end end
      table.sort(ids)
      for _, e in ipairs(ids) do fn(e) end
    end,
    getEntitiesWithComponent = function(t)
      local ids = {}
      for e, w in pairs(WORLD) do if w[NAMEOF[t]] then ids[#ids + 1] = e end end
      table.sort(ids)
      return ids
    end,
    system = {
      streetConnectorSystem = {
        getConstructionEntityForDepot = function(d) for e, w in pairs(WORLD) do if w.CONSTRUCTION then for _, x in ipairs(w.CONSTRUCTION.depots) do if x == d then return e end end end end return -1 end,
        getConstructionEntityForStation = function(s) return -1 end,
      },
      stationGroupSystem = { getStationGroup = function(s) return -1 end },
      lineSystem = { getLines = function() local r = {} for e, w in pairs(WORLD) do if w.LINE then r[#r + 1] = e end end table.sort(r) return r end },
      streetSystem = { getEdgeForEdgeObject = function(o) return -1 end },
    },
  },
}
for _, n in ipairs({ "makeGameSetSpeedCmd", "makeScriptingSendEventCmd", "makeWorldBuildProposalCmd", "makeVehicleBuyCmd",
                     "makeLineCreateCmd", "makeVehicleSetLineCmd" }) do
  api.cmd[n] = mk(n)
end
debugPrint = function(s) end
toString = function(v) return tostring(v) end
getBuildVersion = function() return "test" end
'''

BRIDGE_HARNESS = r'''
MOD = data()
STATE_DATA = nil
STATE = { get = function() return STATE_DATA end, set = function(self, v) STATE_DATA = v end, subscribeToAllEvents = function() end }
GSTATE = { subscribeToAllEvents = function() end }
SIM_EVENT = function(name, param) MOD.handleEvent(nil, STATE, "mpfever", "mpfever", name, param) end
BUILD_EVENT = function(name, proposal, playerInitiated, result) MOD.handleEvent(nil, STATE, "", "apply_command", name, { proposal, {}, result, playerInitiated }) end
function FRAME() MOD.guiUpdate(nil, STATE, GSTATE) end
function SIMSTEP()
  local q = GAME.guiQueue; GAME.guiQueue = {}
  GAME.engine = true
  for _, c in ipairs(q) do GAME_EXECUTE(c[1], c[2]) end
  for i = 1, GAME.speed do
    for _, e in ipairs(GAME.deferred or {}) do WORLD[e] = { TRANSPORT_VEHICLE = {} } end
    GAME.deferred = {}
    GAME.time = GAME.time + 200
    GAME.inUpdate = true
    MOD.update(nil, STATE, 0.2)
    GAME.inUpdate = false
  end
  GAME.engine = false
end
'''

REQUIRE = '''ug_require = function(p)
  if p == "mpfever_common.lua" then if not COMMON then COMMON = load(COMMON_SRC)() end return COMMON end
  if p == "mpfever_refs.lua" then if not REFS then REFS = load(REFS_SRC)() end return REFS end
  error("no " .. p)
end'''


class Game:
    def __init__(self, name, role, tmp, first_entity):
        self.name, self.dir = name, os.path.join(tmp, name)
        os.makedirs(self.dir)
        open(os.path.join(self.dir, "in.log"), "w").close()
        os.environ.update(MPFEVER_DIR=self.dir, MPFEVER_NAME=name, MPFEVER_ROLE=role)
        common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read()
        refs = open(os.path.join(CONTENT, "mpfever_refs.lua"), encoding="utf-8").read()
        ui_src = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read()
        ui_src = ui_src.replace("local M = {}", "local M = {}; U.stepping = true", 1)
        ui_src = ui_src.replace("function data()", "POLL = function() pollBindings(); return pollResults() end" + chr(10) + "function data()", 1)
        # UI state and game script state share one mocked world per game (they are views of the same engine)
        self.L = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(MOCK)
        self.L.execute("GAME.nextEntity = %d" % first_entity)
        self.L.globals().COMMON_SRC = common
        self.L.globals().REFS_SRC = refs
        self.L.execute(REQUIRE)
        self.L.execute(open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read())
        self.L.execute(BRIDGE_HARNESS)
        self.L.execute("BRIDGE_DATA = data")
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

    def read(self, f):
        p = os.path.join(self.dir, f)
        return open(p, encoding="utf-8").read().splitlines() if os.path.exists(p) else []

    def write(self, line):
        with open(os.path.join(self.dir, "in.log"), "a", encoding="utf-8", newline="\n") as f:
            f.write(line + "\n")

    def time(self): return self.L.eval("GAME.time")

    def applied(self):
        s = self.L.eval("(function() local r = {} for i, a in ipairs(GAME.applied) do r[i] = a.name .. '@' .. a.time end return table.concat(r, ',') end)()")
        return s.split(",") if s else []


class Host:
    """Minimal stand-in for MPFever.exe: relays actions and clocks, owns the session (speed, pause, hash)."""
    def __init__(self, games):
        self.games, self.offsets, self.clock = games, {}, {}
        self.started, self.speed, self.pauseAt = False, 0, None

    def broadcast(self, kind, payload, exclude=None):
        for g in self.games:
            if g is not exclude:
                g.write(kind + TAB + "Hote" + TAB + payload)

    def session(self):
        p = '{["started"]=%s,["speed"]=%d%s}' % ("true" if self.started else "false", self.speed,
            (',["pauseAt"]=%d' % self.pauseAt) if self.pauseAt is not None else "")
        self.broadcast("session", p)

    def stamp(self):
        return ((max(self.clock.values()) + 8 * STEP + STEP - 1) // STEP) * STEP

    def pump(self):
        for g in self.games:
            lines = g.read("out.log")
            off = self.offsets.get(g.name, 0)
            for line in lines[off:]:
                kind, frm, payload = line.split(TAB, 2)
                if kind == "clock":
                    t = int(payload.split('["t"]=')[1].split(",")[0].split("}")[0])
                    ah = int(payload.split('["ah"]=')[1].split(",")[0].split("}")[0]) if '["ah"]=' in payload else 3
                    self.clock[g.name] = t
                    self.broadcast("peerclock", '{["name"]="%s",["t"]=%d,["ah"]=%d}' % (g.name, t, ah), exclude=g)
                elif kind == "act":
                    for o in self.games:
                        if o is not g:
                            o.write("act" + TAB + g.name + TAB + payload)
            self.offsets[g.name] = len(lines)


def run():
    tmp = tempfile.mkdtemp()
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("OK   " if cond else "FAIL ") + msg)
        ok = ok and bool(cond)

    A, B = Game("Hote", "host", tmp, 50000), Game("Client", "client", tmp, 51000)
    host = Host([A, B])

    def tick(n=1, lagB=False):
        for i in range(n):
            for _ in range(5):
                for g in (A, B):
                    g.L.execute("FRAME()")
                    g.L.execute("UI.POLL()")
                host.pump()
            A.L.execute("SIMSTEP()")
            if not (lagB and i % 3 == 0):
                B.L.execute("SIMSTEP()")

    A.write("welcome" + TAB + "Hote" + TAB + '{["you"]="Hote",["role"]="host"}')
    B.write("welcome" + TAB + "Hote" + TAB + '{["you"]="Client",["role"]="client"}')
    tick(20)
    check(A.time() == B.time() == 18600, "both games held at the save time before start")
    host.started, host.speed = True, 1
    host.session()
    tick(60, lagB=True)
    check(A.time() > 18600 and B.time() > 18600, "session running (A=%d B=%d)" % (A.time(), B.time()))
    gaps = []
    for _ in range(10):
        tick(3, lagB=True)
        gaps.append((A.time() - B.time()) // STEP)
    check(max(gaps) <= 3 and min(gaps) >= -3, "barrier: neither game runs ahead of the other (gaps in steps: %s)" % gaps)

    # the client buys a vehicle in the save's depot 55 (same id everywhere); the vehicle gets different ids
    B.L.execute('''
      local api = UI.api
      api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 55, { vehicles = {} }), function(d, s, e) BUY_CB = { s, d and d.resultVehicleEntity } end)
    ''')
    check(B.L.eval("BUY_CB == nil"), "purchase callback waits for the real result")
    tick(40, lagB=True)
    a, b = A.applied(), B.applied()
    check(len(a) == 1 and a == b, "purchase applied at the same time on both: %s / %s" % (a, b))
    va, vb = A.L.eval("GAME.applied[1].entity"), B.L.eval("GAME.applied[1].entity")
    check(va != vb, "the bought vehicle has different ids in the two games (%s vs %s), as in the real game" % (va, vb))
    tick(5)
    check(B.L.eval("BUY_CB ~= nil and BUY_CB[1] == true and BUY_CB[2] == %d" % vb), "client's depot window got ITS local vehicle id %s" % vb)

    # the client creates a line, then assigns its vehicle to it: ids must be translated on the host
    B.L.execute('''
      local api = UI.api
      api.cmd.sendCommand(api.cmd.makeLineCreateCmd("Ligne 1", { x = 1, y = 0, z = 0 }, 7, { stops = {} }), function(d, s, e) LINE_CB = { s, e and e[1] and e[1][1] } end)
    ''')
    tick(40, lagB=True)
    tick(5)
    line_b = B.L.eval("LINE_CB and LINE_CB[2]")
    B.L.execute('''
      local api = UI.api
      api.cmd.sendCommand(api.cmd.makeVehicleSetLineCmd(%d, %d, 0), function() end)
    ''' % (vb, line_b))
    tick(40, lagB=True)
    sa = A.L.eval("(function() for _, a in ipairs(GAME.applied) do if a.name == 'makeVehicleSetLineCmd' then return a.args[1] .. ',' .. a.args[2] end end end)()")
    sb = B.L.eval("(function() for _, a in ipairs(GAME.applied) do if a.name == 'makeVehicleSetLineCmd' then return a.args[1] .. ',' .. a.args[2] end end end)()")
    la = A.L.eval("GAME.applied[2].entity")
    check(sa == "%s,%s" % (va, la) and sb == "%s,%s" % (vb, line_b), "line assignment used each game's own vehicle and line ids (host %s, client %s)" % (sa, sb))
    check(A.applied() == B.applied(), "same actions at the same times on both games")

    # a reference that cannot be resolved is skipped, not executed with a bad id
    B.L.execute("WORLD[9999] = { VEHICLE_DEPOT = {} }")   # a depot that only exists in the client game
    B.L.execute("local api = UI.api; api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 9999, { vehicles = {} }), function() end)")
    tick(40, lagB=True)
    na = len([x for x in A.applied() if x.startswith("makeVehicleBuyCmd")])
    check(na == 1, "a purchase in a depot unknown to the host is skipped on the host (no crash)")

    # the host player builds a road natively (no veto, no button): applied at once on the host, captured by the
    # engine event, rebuilt by the client at the same game time; the client's replay is not shipped back
    A.L.execute('''
      local proposal = { toAdd = {}, toRemove = {}, proposal = {
        addedNodes = { { entity = -1, comp = { position = { x = 50, y = 50, z = 0 } } } },
        addedSegments = { { entity = -2, comp = { node0 = 60, node1 = -1 } } } } }
      GAME.guiQueue[#GAME.guiQueue + 1] = { { __cmd = "native_build", args = { proposal, nil, false, true } } }
    ''')
    before_a, before_b = len(A.applied()), len(B.applied())
    tick(40, lagB=True)
    a, b = A.applied(), B.applied()
    check(len(a) == before_a + 1 and len(b) == before_b + 1 and a[-1] == b[-1], "native road built on both at the same game time: %s / %s" % (a[-1:], b[-1:]))
    n0 = B.L.eval("(function() for i = #GAME.applied, 1, -1 do local x = GAME.applied[i] if x.name == 'build' and x.args[1].streetProposal then return x.args[1].streetProposal.edgesToAdd[1].comp.node0 end end end)()")
    check(n0 == 60, "existing node reference resolved on the client (node0=%s)" % n0)
    shipped_b = len([l for l in B.read("out.log") if l.startswith("act")])
    check(shipped_b == 4, "the client did not ship its replay back (client shipped %d actions, its own 4)" % shipped_b)

    # pause / action during the pause
    host.pauseAt = host.stamp()
    host.session()
    tick(60, lagB=True)
    check(A.time() == B.time() == host.pauseAt, "both games paused exactly at %d (A=%d B=%d)" % (host.pauseAt, A.time(), B.time()))
    A.L.execute("local api = UI.api; api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(7, 55, { vehicles = {} }), function() end)")
    tick(10)
    a, b = A.applied(), B.applied()
    check(a[-1] == b[-1] == "makeVehicleBuyCmd@%d" % host.pauseAt, "purchase during the pause applied at the pause time on both: %s / %s" % (a[-1:], b[-1:]))
    host.pauseAt, host.speed = None, 2
    host.session()
    tick(30)
    t0 = A.time()
    tick(30)
    check(A.L.eval("GAME.speed") == 2 and A.time() - t0 >= 30 * STEP * 1.5, "resumed at x2 (%d steps in 30 frames)" % ((A.time() - t0) // STEP))
    logs = chr(10).join(A.read("mod.log") + B.read("mod.log") + A.read("ui_mod.log") + B.read("ui_mod.log"))
    bad = [l for l in logs.splitlines() if ("FAILED" in l or "LATE" in l)]
    check(not bad, "no failure / late action in logs %s" % bad[:3])
    if not ok or os.environ.get("MPF_VERBOSE"):
        print(chr(10).join(l for l in logs.splitlines() if "session:" not in l)[-(400000 if os.environ.get("MPF_VERBOSE") else 4000):])
    shutil.rmtree(tmp, ignore_errors=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(run())
