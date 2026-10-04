-- MPFever UI hook (v0.4), runs in the UI Lua state, where the player's tools and windows live.
--
-- doReplace (react-replacement-config, at UI boot): wraps api.cmd so that every command the player issues is held
--   back, marshalled and sent to MPFever.exe (ui.log). The host stamps it and every game applies it at that stamp.
-- MPFeverEntry (react-plugin on the game's ModEntryPointExtension): an invisible component mounted for the whole
--   game; its onStep hook reads results.log and gives each tool the real result of its command (new line id,
--   bought vehicle...), as the native command would have.
-- Construction tools get their callback at once (they only need to know the command was accepted).

local okC, C = pcall(ug_require, "mpfever_common.lua")
if not okC then C = ug_require("mpfever_1::/mpfever_common.lua") end
local log = C.logger("-UI", "ui_mod.log")
local okR, R = pcall(ug_require, "mpfever_refs.lua")
if not okR then R = ug_require("mpfever_1::/mpfever_refs.lua") end

-- immediate answer for these (the tool just waits to be released); every other command waits for its result
local IMMEDIATE = { makeWorldBuildProposalCmd = true }

local U = {
	tags = setmetatable({}, { __mode = "k" }),
	seq = 0, logged = 0, installed = false,
	tok = tostring(os.time()) .. "-" .. tostring(math.floor((os.clock() % 1) * 1000000)) .. "-" .. C.NAME,
	pending = {},       -- id -> { cb, name, t0 }
	resOff = 0, bindOff = 0, rev = {},
	stats = { held = 0, speed = 0, failed = 0, untracked = 0, answered = 0 },
}

local function sendLine(kind, payload)
	if not C.appendFile(C.DIR .. C.BS .. "ui.log", C.line(kind, payload)) then log("cannot write ui.log") end
end

local function isCallable(f)
	if type(f) == "function" then return true end
	local mt = getmetatable(f)
	return mt ~= nil and (type(mt) ~= "table" or mt.__call ~= nil)
end

local function install()
	if U.installed then return end
	U.installed = true
	-- the game script bridge may share this api table: it must keep using the game's own functions, never the
	-- wrapped ones (its speed commands would come back as player requests, its events would be replicated)
	-- (api.cmd is userdata and takes no new member: the originals are kept in package.loaded, shared by the state)
	local orig = C.origCmds()
	if not orig.sendCommand then
		orig.sendCommand, orig.setSpeed, orig.event = api.cmd.sendCommand, api.cmd.makeGameSetSpeedCmd, api.cmd.makeScriptingSendEventCmd
	end
	local O = { sendCommand = orig.sendCommand }
	local wrapped, missing, kinds = 0, {}, {}
	for _, name in ipairs(C.FACTORIES) do
		local fn = nil
		pcall(function() fn = api.cmd[name] end)
		if fn ~= nil and isCallable(fn) then
			kinds[type(fn)] = true
			local okw = pcall(function()
				api.cmd[name] = function(...)
					local cmd = fn(...)
					if cmd ~= nil then U.tags[cmd] = { name = name, args = { n = select("#", ...), ... } } end
					return cmd
				end
			end)
			if okw then wrapped = wrapped + 1 else missing[#missing + 1] = name .. "(read-only)" end
		else
			missing[#missing + 1] = name .. "(" .. type(fn) .. ")"
		end
	end
	api.cmd.sendCommand = function(cmd, cb, progress)
		local tag = cmd ~= nil and U.tags[cmd] or nil
		if tag == nil then
			U.stats.untracked = U.stats.untracked + 1
			if U.logged < 30 then U.logged = U.logged + 1; log("untracked command sent natively: " .. C.dump(cmd):sub(1, 160)) end
			return O.sendCommand(cmd, cb, progress)
		end
		-- notification events (popup sound, dismiss) are sent automatically by each game's own interface: local only
		if tag.name == "makeScriptingSendEventCmd" and tag.args[2] == "Notifications" then
			return O.sendCommand(cmd, cb, progress)
		end
		if tag.name == "makeGameSetSpeedCmd" then
			U.stats.speed = U.stats.speed + 1
			-- the interface repeats its request every frame while the game holds another speed: one per second at most
			local now = os.clock()
			if tag.args[1] ~= U.lastSpeedReq or now - (U.lastSpeedAt or -10) > 1 then
				U.lastSpeedReq, U.lastSpeedAt = tag.args[1], now
				sendLine("speed_req", { speed = tag.args[1] })
			end
			return
		end
		local okm, margs = pcall(function()
			local r = { n = tag.args.n }
			for i = 1, tag.args.n do r[i] = C.marshal(tag.args[i]) end
			return r
		end)
		if not okm then
			U.stats.failed = U.stats.failed + 1
			log("marshal failed for " .. tag.name .. ": " .. tostring(margs) .. " -> executed locally only (desync risk)")
			sendLine("act_fail", { fn = tag.name, stage = "marshal", err = tostring(margs) })
			return O.sendCommand(cmd, cb, progress)
		end
		local okt, errt = pcall(R.translateOut, tag.name, margs, U.rev)
		if not okt then log("reference translation failed for " .. tag.name .. ": " .. tostring(errt)) end
		U.seq = U.seq + 1
		U.stats.held = U.stats.held + 1
		sendLine("act_req", { tok = U.tok, id = U.seq, fn = tag.name, args = margs })
		if U.logged < 80 then
			U.logged = U.logged + 1
			log("held " .. tag.name .. " #" .. U.seq .. " (" .. #C.ser(margs) .. " bytes)")
			if U.logged <= 12 then C.appendFile(C.DIR .. C.BS .. "captured.txt", tag.name .. " #" .. U.seq .. C.NL .. C.ser(margs) .. C.NL) end
		end
		if cb then
			if IMMEDIATE[tag.name] or not U.stepping then
				-- without the per-step component the result could never be delivered: answer now
				local okc, errc = pcall(cb, nil, true, {})
				if not okc then log("tool callback error (ignored): " .. tostring(errc):sub(1, 160)) end
			else
				U.pending[U.seq] = { cb = cb, name = tag.name, t0 = os.clock() }
			end
		end
	end
	local k = {}
	for t, _ in pairs(kinds) do k[#k + 1] = t end
	log("UI interception installed on " .. wrapped .. " factories (types: " .. table.concat(k, ",") .. ")" .. (#missing > 0 and (", missing: " .. table.concat(missing, ",")) or ""))
end

-- results of our own actions, written by the game-script bridge after the simulation applied them
local function pollResults()
	if not C.ACTIVE then return end
	local f = C.IO.open(C.DIR .. C.BS .. "results.log", "rb")
	if not f then return end
	local size = f:seek("end")
	if size > U.resOff then
		f:seek("set", U.resOff)
		local chunk = f:read(size - U.resOff) or ""
		local last, pos = nil, 1
		while true do
			local i = chunk:find(C.NL, pos, true)
			if not i then break end
			last = i
			local line = chunk:sub(pos, i - 1)
			pos = i + 1
			local payload = line:match("^result" .. C.TAB .. "[^" .. C.TAB .. "]*" .. C.TAB .. "(.*)$")
			local r = payload and C.deser(payload)
			if r and r.tok == U.tok and U.pending[r.id] then
				local p = U.pending[r.id]
				U.pending[r.id] = nil
				U.stats.answered = U.stats.answered + 1
				local data = type(r.data) == "table" and C.plain(r.data) or nil
				local entities = type(r.entities) == "table" and C.plain(r.entities) or {}
				local okc, errc = pcall(p.cb, data, r.success == true, entities)
				log("result #" .. tostring(r.id) .. " " .. tostring(p.name) .. " success=" .. tostring(r.success) .. " after " .. string.format("%.2f", os.clock() - p.t0) .. "s" .. (okc and "" or (" (callback error: " .. tostring(errc):sub(1, 160) .. ")")))
			end
		end
		if last then U.resOff = U.resOff + last end
	end
	f:close()
end

local M = {}

M.doReplace = function(replacementApi)
	if not C.ACTIVE then return end
	local ok, err = pcall(install)
	if not ok then log("UI interception FAILED: " .. tostring(err)) end
end

-- MPFever panel, mounted on the game's mod entry point for the whole game. It gives the UI state a periodic hook
-- (results of our own actions and entity bindings).
local function readPending()
	local f = C.IO.open(C.DIR .. C.BS .. "pending_build.txt", "rb")
	if not f then return "" end
	local s = f:read("*a") or ""
	f:close()
	return s
end

local function pollBindings()
	local f = C.IO.open(C.DIR .. C.BS .. "bindings.log", "rb")
	if not f then return end
	local size = f:seek("end")
	if size > U.bindOff then
		f:seek("set", U.bindOff)
		local chunk = f:read(size - U.bindOff) or ""
		local consumed = 0
		for line in chunk:gmatch("([^" .. C.NL .. "]*)" .. C.NL) do
			consumed = consumed + #line + 1
			local key, e = line:match("^(%S+) (%-?%d+)")
			if key == "RESET" then U.rev = {}
			elseif key then U.rev[tonumber(e)] = key end
		end
		U.bindOff = U.bindOff + consumed
	end
	f:close()
end

-- ---------------------------------------------------------------- resynchronisation by the host's savegame
-- The launcher pauses every game, asks the host to save (resync_save), sends the file to the other players and asks
-- them to load it (resync_load). Saving and loading are application functions, available in this UI state.

local function findSave(name)
	local ns = app.SaveGameNamespace.getSavegame()
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == name then
			local id = api.type.SavegameId.new()
			id.path = s.path
			id.saveGameName = s.saveName
			id.saveGameNamespace = ns
			return id
		end
	end
	return nil
end

local function resyncSave(p)
	log("resynchronisation: saving the game as '" .. tostring(p.name) .. "'")
	local ok, err = pcall(app.saveGame, p.name, function()
		log("resynchronisation: game saved")
		sendLine("save_done", { id = p.id, name = p.name, ok = true })
	end, false, true)
	if not ok then
		log("resynchronisation: save failed: " .. tostring(err))
		sendLine("save_done", { id = p.id, name = p.name, ok = false, err = tostring(err) })
	end
end

local function resyncLoad(p)
	local id = findSave(p.name)
	if not id then
		log("resynchronisation: savegame '" .. tostring(p.name) .. "' not found")
		return
	end
	-- the application script starts the loaded game by itself (no "press a key" screen)
	C.appendFile(C.DIR .. C.BS .. "resync_pending.txt", "1")
	log("resynchronisation: loading the host's game '" .. tostring(p.name) .. "'")
	app.loadGame(id, false)
end

local function pollControl()
	local f = C.IO.open(C.DIR .. C.BS .. "in.log", "rb")
	if not f then return end
	local size = f:seek("end")
	if U.ctlOff == nil or size < U.ctlOff then
		-- messages from before this UI started are not for it
		U.ctlOff = size
		f:close()
		return
	end
	if size > U.ctlOff then
		f:seek("set", U.ctlOff)
		local chunk = f:read(size - U.ctlOff) or ""
		local consumed = 0
		for line in chunk:gmatch("([^" .. C.NL .. "]*)" .. C.NL) do
			consumed = consumed + #line + 1
			local kind, payload = line:match("^([^" .. C.TAB .. "]*)" .. C.TAB .. "[^" .. C.TAB .. "]*" .. C.TAB .. "(.*)$")
			if kind == "resync_save" or kind == "resync_load" then
				-- the game script bridge may handle it first (it runs every frame, even paused): wait for its claim
				U.resyncQueue = U.resyncQueue or {}
				U.resyncQueue[#U.resyncQueue + 1] = { kind = kind, p = C.deser(payload) or {}, t = os.clock() }
			end
		end
		U.ctlOff = U.ctlOff + consumed
	end
	f:close()
	local keep = {}
	for _, r in ipairs(U.resyncQueue or {}) do
		if os.clock() - r.t < 1.5 then
			keep[#keep + 1] = r
		else
			local claims = ""
			local cf = C.IO.open(C.DIR .. C.BS .. "resync_claims.txt", "rb")
			if cf then claims = cf:read("*a") or ""; cf:close() end
			if not claims:find(r.kind .. " " .. tostring(r.p.id) .. C.NL, 1, true) then
				C.appendFile(C.DIR .. C.BS .. "resync_claims.txt", r.kind .. " " .. tostring(r.p.id) .. C.NL)
				local ok, err = pcall(r.kind == "resync_save" and resyncSave or resyncLoad, r.p)
				if not ok then log(r.kind .. " failed: " .. tostring(err)) end
			end
		end
	end
	U.resyncQueue = keep
end

local function tick(pendingState)
	pcall(pollBindings)
	local okc, errc = pcall(pollControl)
	if not okc then log("control poll failed: " .. tostring(errc)) end
	if not U.stepping then U.stepping = true; log("periodic UI hook active") end
	local okp, errp = pcall(pollResults)
	if not okp then log("results poll failed: " .. tostring(errp)) end
	local okr, pending = pcall(readPending)
	if okr and pendingState and pending ~= pendingState:old() then pendingState:set(pending) end
end

do
	local okR, react = pcall(ug_require, "::/gui/main/react.lua")
	local okB, builtin = pcall(ug_require, "::/gui/main/builtin.lua")
	local okE, entry = pcall(ug_require, "::/gui/main/mod_entry_point.tl")
	if okR and okB then
		-- hidden entry point (the game keeps it invisible): only used as a periodic hook
		if okE and entry and entry.ModEntryPointExtension then
			local okP, recipe = pcall(react.RegisterPluginRecipe, entry.ModEntryPointExtension, "MPFeverEntry", function(params)
				if C.ACTIVE then
					if not U.installed then pcall(install) end
					react.onStep(function() tick(nil) end)
					pcall(function() react.onStepTimer(function() tick(nil) end, 0.2) end)
				end
				return builtin.BoxLayout { children = {} }
			end)
			if okP then M.MPFeverEntry = recipe else log("entry registration failed: " .. tostring(recipe)) end
		end
	else
		log("UI unavailable: react=" .. tostring(okR) .. " builtin=" .. tostring(okB))
	end
end

function data()
	return M
end
