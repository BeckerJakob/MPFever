-- Drives the real bridge (mpfever_bridge.script.lua) against the mocked engine: one GUI frame (FRAME) and one
-- simulation tick (SIMSTEP: queued GUI commands, then GAME.speed steps, or the steps asked while paused).
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
  local n = GAME.speed
  if n == 0 and GAME.pendingSteps > 0 then n = GAME.pendingSteps end
  GAME.pendingSteps = 0
  for i = 1, n do
    for _, e in ipairs(GAME.deferred or {}) do WORLD[e] = { TRANSPORT_VEHICLE = {} } end
    GAME.deferred = {}
    GAME.time = GAME.time + 200
    GAME.inUpdate = true
    MOD.update(nil, STATE, 0.2)
    GAME.inUpdate = false
  end
  GAME.engine = false
end
