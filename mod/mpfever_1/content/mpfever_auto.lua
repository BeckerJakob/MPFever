-- MPFever application script, started with: TransportFever3.exe --script mpfever_1::/mpfever_auto.lua
-- * autotest: loads the savegame named by MPFEVER_SAVE from the main menu, so that a test session needs nobody at the
--   keyboard;
-- * resynchronisation: when the mod loads the host's savegame (flag file resync_pending.txt), starts the loaded game
--   as soon as it is ready, without the "press a key" screen.
-- No backslash characters on purpose.

local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
local SAVE = os.getenv("MPFEVER_SAVE")
local BS = string.char(92)

local function log(msg)
	pcall(print, "[MPFEVER-AUTO] " .. msg)
	if DIR and IO then
		local f = IO.open(DIR .. BS .. "auto.log", "ab")
		if f then
			f:write(os.date("%H:%M:%S") .. " " .. msg .. string.char(10))
			f:close()
		end
	end
end

local S = { requested = false, frames = 0, readyStarted = false }

local function loadSave()
	local ns = app.SaveGameNamespace.getSavegame()
	local found = nil
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == SAVE then found = s end
	end
	if not found then
		log("savegame '" .. SAVE .. "' not found")
		return
	end
	local id = api.type.SavegameId.new()
	id.path = found.path
	id.saveGameName = found.saveName
	id.saveGameNamespace = ns
	log("loading savegame '" .. SAVE .. "' (" .. tostring(found.path) .. ")")
	app.loadGame(id, false)
end

-- a resynchronisation load is pending (written by the mod just before it loads the host's savegame)
local function resyncPending()
	if not (DIR and IO) then return false end
	local f = IO.open(DIR .. BS .. "resync_pending.txt", "rb")
	if not f then return false end
	local s = f:read("*a") or ""
	f:close()
	return s:find("1", 1, true) ~= nil
end

local function clearResync()
	local f = IO.open(DIR .. BS .. "resync_pending.txt", "wb")
	if f then f:close() end
end

-- the loaded game waits for a key press: start it once loading is complete
local function startWhenReady()
	local ok, waiting = pcall(app.isWaitForStartReadyGame)
	if ok and waiting then
		local okp, progress = pcall(function() return app.getProgressMonitor():getProgress() end)
		if okp and progress and progress >= 1 then
			pcall(app.startReadyGame)
			return true
		end
	end
	return false
end

function data()
	return {
		handleEvent = function(id, name, param)
			if name == "mainMenuReady" and SAVE and not S.requested then
				S.requested = true
				local ok, err = pcall(loadSave)
				if not ok then log("load failed: " .. tostring(err)) end
			end
		end,
		update = function()
			S.frames = S.frames + 1
			if S.frames % 30 ~= 0 then return end
			if S.requested and not S.readyStarted and startWhenReady() then
				S.readyStarted = true
				log("game loaded, starting it")
			end
			if resyncPending() and startWhenReady() then
				clearResync()
				log("host's game loaded (resynchronisation), starting it")
			end
		end,
	}
end
