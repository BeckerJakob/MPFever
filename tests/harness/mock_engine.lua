-- Mocked Transport Fever 3 engine for the offline tests (taken over from tests/test_lockstep.py, 0.1.0).
--
-- world: entities from the save have the same ids everywhere; new ones start at GAME.nextEntity (differs per game,
-- as in the real game where the UI allocates entities the other games never see)
--
-- Changes against the 0.1.0 mock (Phase 0):
--  * api.cmd.debug.makeGamePerformSimulationStepsCmd ("steps") performs simulation steps while the game is paused,
--    like the engine does. The bridge uses it since 0.1.x to stop exactly at a stop point; the old mock recorded it
--    as an applied action instead, which made five checks of the old test fail.
--  * streetSystem.getNode2SegmentMap (used by mpfever_refs.lua to list nodes and edges).
GAME = { time = 18600, speed = 0, applied = {}, guiQueue = {}, engine = false, inUpdate = false, nextEntity = 50000,
  pendingSteps = 0 }
WORLD = {
  [7] = { PLAYER = {} },
  [54] = { CONSTRUCTION = { fileName = "depot.con", transf = { [13] = 100, [14] = 200, [15] = 5 }, depots = { 55 }, stations = {} } },
  [55] = { VEHICLE_DEPOT = {} },
  [60] = { BASE_NODE = { position = { x = 10, y = 10, z = 0 } } },
  [100] = { TOWN = { sizeFactors = { 1 } } },
}
function NEW_ENTITY(comps) GAME.nextEntity = GAME.nextEntity + 1; WORLD[GAME.nextEntity] = comps; return GAME.nextEntity end
local newEntity = NEW_ENTITY
local function mk(name) return function(...) return { __cmd = name, args = { ... } } end end
local function execute(cmd, cb)
  local name = cmd.__cmd
  if name == "makeGameSetSpeedCmd" then GAME.speed = cmd.args[1]; if cb then cb({}, true, {}) end return end
  if name == "steps" then
    GAME.pendingSteps = GAME.pendingSteps + (cmd.args[1] or 0)
    if cb then cb({}, true, {}) end
    return
  end
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

-- Mocked native module (winhttp.dll, "deferral of native builds v3"): a build issued by a UI tool is held at
-- CommandList::Add when the mod enabled it, announced in native_events.log ("deferred <id>"), and released in order,
-- just before the next command that enters the command list, once native_ctl.txt asks for it ("release <n>": n builds
-- released in total). MOCK_DLL.dir = nil: no native module (unknown game build), tool builds go to the engine at once.
MOCK_DLL = { dir = nil, enabled = false, held = {}, nextId = 0, released = 0, target = 0, ctlOff = 0 }
local function dllPollCtl()
  local d = MOCK_DLL
  if not d.dir then return end
  local f = io.open(d.dir .. string.char(92) .. "native_ctl.txt", "rb")
  if not f then return end
  local s = f:read("*a") or ""
  f:close()
  local chunk = s:sub(d.ctlOff + 1)
  local last = 0
  for line, e in chunk:gmatch("([^\n]*)\n()") do
    last = e - 1
    local en = line:match("^enable (%d)")
    if en then d.enabled = en == "1" end
    local r = tonumber(line:match("^release (%d+)"))
    if r then d.target = r end
  end
  d.ctlOff = d.ctlOff + last
end
local function dllRelease()
  local d = MOCK_DLL
  dllPollCtl()
  while d.released < d.target and #d.held > 0 do
    local h = table.remove(d.held, 1)
    d.released = d.released + 1
    GAME.guiQueue[#GAME.guiQueue + 1] = { h.cmd }
  end
end
-- a UI tool (street builder, bulldozer...) sends its build: CommandList::Add
function TOOL_BUILD(cmd)
  local d = MOCK_DLL
  dllPollCtl()
  if d.dir and d.enabled then
    d.nextId = d.nextId + 1
    d.held[#d.held + 1] = { id = d.nextId, cmd = cmd }
    local f = io.open(d.dir .. string.char(92) .. "native_events.log", "ab")
    f:write("deferred " .. d.nextId .. "\n")
    f:close()
  else
    dllRelease()
    GAME.guiQueue[#GAME.guiQueue + 1] = { cmd }
  end
end
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
      else
        dllRelease()
        GAME.guiQueue[#GAME.guiQueue + 1] = { cmd, cb }
      end
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
        getConstructionEntityForStation = function(s) for e, w in pairs(WORLD) do if w.CONSTRUCTION then for _, x in ipairs(w.CONSTRUCTION.stations) do if x == s then return e end end end end return -1 end,
      },
      stationGroupSystem = { getStationGroup = function(s) return -1 end },
      lineSystem = { getLines = function() local r = {} for e, w in pairs(WORLD) do if w.LINE then r[#r + 1] = e end end table.sort(r) return r end },
      streetSystem = {
        getEdgeForEdgeObject = function(o) return -1 end,
        -- node -> list of the edges ending at it
        getNode2SegmentMap = function()
          local m = {}
          for e, w in pairs(WORLD) do if w.BASE_NODE then m[e] = {} end end
          for e, w in pairs(WORLD) do
            local be = w.BASE_EDGE
            if be then
              for _, n in ipairs({ be.node0, be.node1 }) do
                if m[n] then m[n][#m[n] + 1] = e end
              end
            end
          end
          return m
        end,
      },
    },
  },
}
for _, n in ipairs({ "makeGameSetSpeedCmd", "makeScriptingSendEventCmd", "makeWorldBuildProposalCmd", "makeVehicleBuyCmd",
                     "makeLineCreateCmd", "makeVehicleSetLineCmd" }) do
  api.cmd[n] = mk(n)
end
-- the interface: where the mouse points on the ground (MOUSE, nil: not over the ground), the camera (CAMERA), and the
-- zones drawn on the map (ZONES: id -> { x, y, r, colour })
MOUSE, CAMERA, ZONES, ZONE_CALLS = nil, { x = 0, y = 0 }, {}, 0
api.gui = {
  mouse = {
    hasTerrainPosition = function() return MOUSE ~= nil end,
    getTerrainPosition = function() return { x = MOUSE.x, y = MOUSE.y, z = 0 } end,
  },
  camera = {
    getCameraData = function() return { CAMERA.x, CAMERA.y, 800, 0, 0.6 } end,
    setCameraData = function(d) CAMERA = { x = d[1], y = d[2] } end,
  },
  mission = {
    setZoneCircle = function(id, pos, r, filled, colour)
      ZONE_CALLS = ZONE_CALLS + 1
      ZONES[id] = { x = pos.x, y = pos.y, r = r, colour = colour }
    end,
    removeZone = function(id) ZONES[id] = nil end,
  },
}
debugPrint = function(s) end
-- the game's toString dumps a value deterministically (tostring of a table would give its address, different in
-- every run: the state hashes of the mock depended on it)
toString = function(v)
  local function dump(x, d)
    if type(x) ~= "table" then return tostring(x) end
    if d > 10 then return "{...}" end
    local keys = {}
    for k in pairs(x) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. dump(x[k], d + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return dump(v, 0)
end
getBuildVersion = function() return "test" end
