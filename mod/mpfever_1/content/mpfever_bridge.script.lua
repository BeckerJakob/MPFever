-- MPFever bridge (v0.8), game script.
--
-- Lockstep "with a barrier": every game runs its own simulation at the session speed, but never runs past the clock
-- of the slowest other player. So when a player acts at game time T, no other game has passed T yet, and each of them
-- applies the action exactly at T, in its simulation script (update is called once per simulation step).
--
-- Player actions:
--  * native construction tools (roads, tracks, stops, stations, depots, bulldozer...): they apply natively, as in solo.
--    The simulation half sees them in the engine event onPreBuildProposal, at the exact step, and ships the proposal;
--    the other games rebuild it at that same game time;
--  * commands issued from Lua windows (vehicle purchase, lines...): held by the UI hook (ui.log), stamped here two
--    steps ahead and applied by every game at that stamp, the originator included.
-- Entity ids are never shipped raw (they differ between games): see mpfever_refs.lua.
-- Without MPFEVER_DIR (game not started by MPFever.exe) the mod does nothing.
--
-- The bridge is split into parts (mpfever_br_*.lua, in this order; Phase 1). Every part is a function that receives
-- the bridge's ONE environment table: a name a part defines at its top level is visible to every other part, as in the
-- single file it was before. The autotest scenarios (mpfever_dev_autotest*.lua) are loaded only for MPFever.exe
-- --autotest / --dev (MPFEVER_AUTOTEST=1, or MPFEVER_SAVE set by the autotest).

local ENV = setmetatable({}, { __index = _ENV })

local function part(name)
	local ok, f = pcall(ug_require, name)
	if not ok then f = ug_require("mpfever_1::/" .. name) end
	f(ENV)
end

local PARTS = { "base", "exec", "sim", "gui", "replay", "native", "resync" }
for _, p in ipairs(PARTS) do part("mpfever_br_" .. p .. ".lua") end
local DEV = os.getenv("MPFEVER_AUTOTEST") == "1" or (os.getenv("MPFEVER_SAVE") or "") ~= ""
if DEV then
	for i = 1, 3 do part("mpfever_dev_autotest" .. i .. ".lua") end
end
part("mpfever_br_frame.lua")

function data()
	return {
		update = ENV.update,
		handleEvent = ENV.handleEvent,
		guiUpdate = ENV.guiUpdate,
		guiHandleEvent = ENV.guiHandleEvent,
	}
end
