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

-- notifications kept across reloads (see N.record and N.tick, before tick)
local N = {}

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
			U.notifLogged = (U.notifLogged or 0) + 1
			if U.notifLogged <= 40 then log("local notification event " .. tostring(tag.args[1]) .. "/" .. tostring(tag.args[3]) .. " " .. C.ser(C.marshal(tag.args[4])):sub(1, 200)) end
			local okr, errr = pcall(N.record, tag.args[3], tag.args[4])
			if not okr then log("notifications: not kept: " .. tostring(errr)) end
			if os.getenv("MPFEVER_NONOTIF") then return end
			return O.sendCommand(cmd, cb, progress)
		end
		-- town development at a position: the engine seeds it from the C library's rand(), seeded with the clock, so every
		-- game would develop the town differently (found by TPF3-MP, investigation/TPF3_RNG_2026-09-29.md). No stock script
		-- sends it; a mod's is refused in a session
		if tag.name == "makeTownDevelopAtCmd" then
			U.townDevRefused = (U.townDevRefused or 0) + 1
			if U.townDevRefused <= 5 then log("makeTownDevelopAtCmd refused in a session (its random numbers differ on every game)") end
			return
		end
		if tag.name == "makeGameSetSpeedCmd" then
			U.stats.speed = U.stats.speed + 1
			-- the interface repeats its request every frame while the game holds another speed: one per second at most
			local now = os.clock()
			if tag.args[1] ~= U.lastSpeedReq or now - (U.lastSpeedAt or -10) > 1 then
				U.lastSpeedReq, U.lastSpeedAt = tag.args[1], now
				sendLine("speed_req", { speed = tag.args[1] })
			end
			-- (the speed buttons wait for this answer before they follow the game's speed again, issue #24)
			if cb then pcall(cb, nil, true, {}) end
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
	-- the game's speed buttons (GameSpeedHelper in gui/main/game.tl) show the engine's speed, which the lockstep holds at 0
	-- between steps: they are shown the session's speed instead (mp_status.txt), or for 2 s the speed this player asked for
	local okSp, errSp = pcall(function()
		local origGet = api.engine.getComponent
		local speedType = api.type.ComponentType.GAME_SPEED
		api.engine.getComponent = function(e, ct, ...)
			local c = origGet(e, ct, ...)
			if ct == speedType and c ~= nil then
				local sp = U.shownSpeed()
				-- (mpfRealSpeedup: the engine's own speed, which the lockstep reads, see gameSpeed in the bridge)
				if sp ~= nil and U.shownLogged ~= sp then
					U.shownLogged = sp
					log("speed buttons: session speed " .. tostring(sp) .. " shown (engine " .. tostring(c.speedup) .. ")")
				end
				if sp ~= nil then return setmetatable({ speedup = sp, mpfRealSpeedup = c.speedup }, { __index = function(_, key) return c[key] end }) end
			end
			return c
		end
	end)
	if not okSp then log("speed buttons: not redirected: " .. tostring(errSp)) end
	local k = {}
	for t, _ in pairs(kinds) do k[#k + 1] = t end
	log("UI interception installed on " .. wrapped .. " factories (types: " .. table.concat(k, ",") .. ")" .. (#missing > 0 and (", missing: " .. table.concat(missing, ",")) or ""))
end

-- companies mode: the company numbers of the player entities (companies.txt, written by the game-script bridge); a command that
-- names a company's player (vehicle purchase, line creation...) then travels with the company number, not the entity id
R.coIdOf = function(e) return U.coMap and U.coMap[e] or nil end
-- the game's company modules, adjusted for the companies mode in this state too (see mpfever_co.lua)
local function patchGameModules()
	local okO, CO = pcall(ug_require, "mpfever_co.lua")
	if not okO then okO, CO = pcall(ug_require, "mpfever_1::/mpfever_co.lua") end
	if not (okO and type(CO) == "table" and CO.patchPermits) then log("companies: mpfever_co.lua is not reachable from the interface") return end
	local function req(name)
		for _, path in ipairs({ "/game_mechanics/company/" .. name, "::/game_mechanics/company/" .. name }) do
			local ok, m = pcall(ug_require, path)
			if ok and type(m) == "table" then return m end
		end
		return nil
	end
	CO.patchProgression(req, function(entity)
		if U.coMap and U.coMap[entity] and U.canon then return U.canon end
		return nil
	end, log, function(entity)
		-- (each company's own rank, written by the bridge into companies.txt when there is more than one company)
		local id = U.coMap and U.coMap[entity]
		return id and U.ranks and U.ranks[id] or nil
	end)
	CO.patchPermits(req, log)
end
local function pollCompanies()
	local f = C.IO.open(C.DIR .. C.BS .. "companies.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.coTxt then return end
	U.coTxt = txt
	local map, names, ranks, nRanks = {}, {}, {}, 0
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local rid, rx, rl, rp = line:match("^rank" .. C.TAB .. "(%d+)" .. C.TAB .. "([%d%.%-]+)" .. C.TAB .. "(%d+)" .. C.TAB .. "(%d+)")
		if rid then ranks[tonumber(rid)] = { experience = tonumber(rx), level = tonumber(rl), potentialLevel = tonumber(rp) }; nRanks = nRanks + 1 end
		local a, b, n = line:match("^(%d+)" .. C.TAB .. "(%d+)" .. C.TAB .. "?([^" .. C.TAB .. "]*)")
		if a then map[tonumber(b)] = tonumber(a); names[tonumber(b)] = n end
		local me = line:match("^me" .. C.TAB .. "(%d+)")
		if me then U.myCo = tonumber(me) end
	end
	U.coMap = map
	U.coNames = names
	U.ranks = nRanks > 1 and ranks or nil
	for e, id in pairs(map) do if id == 1 then U.canon = e end end
	if U.canon and not U.coPatched then
		U.coPatched = true
		local okp, errp = pcall(patchGameModules)
		if not okp then log("companies: patching the game modules failed: " .. tostring(errp)) end
	end
	log("companies known to the interface: " .. txt:gsub(C.NL, " "))
end

-- The loans of a company other than the savegame's: the game's loan window reads the loan script's state, which holds the
-- savegame company's loans only. The loans of this player's company (loanview.txt, written by the game-script bridge) are given to
-- it instead, when it asks for that script's state.
local function pollLoanView()
	local f = C.IO.open(C.DIR .. C.BS .. "loanview.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.loanTxt then return end
	U.loanTxt = txt
	U.loanView = (txt ~= "") and C.deser(txt) or nil
	if U.loanView and not U.getCompWrapped then
		U.getCompWrapped = true
		local orig = api.engine.getComponent
		api.engine.getComponent = function(e, ct, ...)
			if U.loanView and ct == api.type.ComponentType.GAME_SCRIPT then
				if U.loanEntity == nil then
					local ok, ent = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, "::/game_mechanics/finance/loan.gs")
					U.loanEntity = ok and ent or false
				end
				if U.loanEntity and e == U.loanEntity then return { state = U.loanView } end
			end
			return orig(e, ct, ...)
		end
		log("companies: the loan window shows this company's loans")
	end
end

-- ---------------------------------------------------------------- owner of what the player clicks (companies mode)
-- Every entity window (station, depot, vehicle, line, building...) shows on its first line which company it belongs to. The game's
-- window maker is wrapped: its result is put under a line of text (no button, nothing else changes).
local T = C.T

local function ownerOf(e)
	if type(e) ~= "number" or e < 0 then return nil end
	local function po(x)
		local ok, c = pcall(api.engine.getComponent, x, api.type.ComponentType.PLAYER_OWNED)
		return (ok and c and type(c.player) == "number" and c.player >= 0) and c.player or nil
	end
	local p = po(e)
	if p then return p end
	local okg, sg = pcall(api.engine.getComponent, e, api.type.ComponentType.STATION_GROUP)
	if okg and sg then
		local okf, first = pcall(function() return sg.stations[1] end)
		if okf and type(first) == "number" then
			p = po(first)
			if p then return p end
			e = first
		end
	end
	local okc, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction, e)
	if okc and type(con) == "number" and con >= 0 then return po(con) end
	return nil
end

local function companyName(ent)
	local name = nil
	pcall(function()
		local n = api.engine.getComponent(ent, api.type.ComponentType.NAME)
		if n and type(n.name) == "string" and n.name ~= "" then name = n.name end
	end)
	if not name and U.coNames and U.coNames[ent] and U.coNames[ent] ~= "" then name = U.coNames[ent] end
	if not name then name = C.Tf("Entreprise %s", "Company %s", U.coMap and U.coMap[ent] or "?") end
	return name
end

-- the stations shared by their company (shares.txt, written by the game-script bridge): station key -> fee per stop
local function pollShares()
	local f = C.IO.open(C.DIR .. C.BS .. "shares.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.shareTxt then return end
	U.shareTxt = txt
	local t = {}
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local k, fee = line:match("^(.-)" .. C.TAB .. "(%d+)$")
		if k then t[k] = tonumber(fee) end
	end
	U.shares = t
	U.shareVersion = (U.shareVersion or 0) + 1
end

local SHARE_FEES = { 0, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000 }

local function money(n)
	local ok, s = pcall(api.util.formatMoney, n)
	return ok and tostring(s) or tostring(n)
end

-- what the share line of a station window says, for the fee in force (nil or 0: not shared)
local function shareText(mine, fee)
	if fee == 0 then fee = nil end
	if mine then
		return fee and (T("Partagée avec les autres entreprises : ", "Shared with the other companies: ") .. money(fee) .. T(" par arrêt", " per stop"))
			or T("Non partagée (les autres entreprises ne peuvent pas s'y arrêter)", "Not shared (the other companies cannot stop here)")
	end
	return fee and (T("Partagée : ", "Shared: ") .. money(fee) .. T(" par arrêt de vos véhicules", " per stop of your vehicles"))
		or T("Non partagée : vos lignes ne peuvent pas s'y arrêter", "Not shared: your lines cannot stop here")
end

-- the share line of a station window: what it costs the other companies to stop there (nil when not a station)
local function shareInfo(e, owner)
	local okg, sg = pcall(R.stationGroupOf, e)
	if not (okg and sg) then return nil end
	local okk, key = pcall(R.sgKey, sg)
	if not okk then return nil end
	local fee = C.shareFee(U.shares, key)
	if fee <= 0 then fee = nil end
	local mine = U.myCo ~= nil and U.coMap and U.coMap[owner] == U.myCo
	return { key = key, fee = fee or 0, text = shareText(mine, fee), canEdit = mine }
end

-- the choices of the share list: not shared, then the usual fees (and the fee in force, when it is another one)
local function shareChoices(current)
	local fees, listed = {}, false
	for _, f in ipairs(SHARE_FEES) do
		fees[#fees + 1] = f
		if f == current then listed = true end
	end
	if not listed and type(current) == "number" and current > 0 then fees[#fees + 1] = current; table.sort(fees) end
	return fees
end

-- the station group of what the line tool points at (a station, its construction, its group, or the street of a street stop)
local function sharedGroupOf(e)
	local okg, sg = pcall(R.stationGroupOf, e)
	if okg and sg then return sg end
	local found = nil
	pcall(function()
		local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		for _, o in ipairs(edge and edge.objects or {}) do
			local oe = o[1] or o.entity
			if type(oe) == "number" and api.engine.getComponent(oe, api.type.ComponentType.STATION) then
				found = R.stationGroupOf(oe)
				if found then return end
			end
		end
	end)
	return found
end

-- the fee another company's station costs this machine's company per stop: nil when the station is not another company's,
-- 0 when it is not shared
local function foreignFee(sg)
	if not (U.coMap and type(sg) == "number") then return nil end
	local owner = ownerOf(sg)
	if not (owner and U.coMap[owner]) or U.coMap[owner] == U.myCo then return nil end
	local okk, key = pcall(R.sgKey, sg)
	if not okk then return nil end
	return C.shareFee(U.shares, key)
end

-- The line windows and tooltips name the stations: another company's station shows what a stop there costs
local function installStopFees()
	if U.stopFeesInstalled then return end
	U.stopFeesInstalled = true
	local function decorate(orig)
		return function(e, ...)
			local name = orig(e, ...)
			if type(name) ~= "string" or type(e) ~= "number" then return name end
			local okc, isSg = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.STATION_GROUP) ~= nil end)
			if not (okc and isSg) then return name end
			local okf, fee = pcall(foreignFee, e)
			if not okf or fee == nil then return name end
			if fee > 0 then return name .. T("  [partagée : ", "  [shared: ") .. money(fee) .. T(" par arrêt]", " per stop]") end
			return name .. T("  [non partagée]", "  [not shared]")
		end
	end
	local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
	if okE and type(eu) == "table" and type(eu.getEntityName) == "function" and not eu.__mpfFees then
		eu.__mpfFees = true
		eu.getEntityName = decorate(eu.getEntityName)
	end
	local util = api.engine.util
	if type(util.getEntityName) == "function" and not U.engineNameWrapped then
		U.engineNameWrapped = true
		util.getEntityName = decorate(util.getEntityName)
	end
	log("companies: the line windows show the fee of the other companies' stations")
end

-- The terrain tools apply their edit at once on this game (the native module cannot hold them, see the bridge): while one is in
-- the player's hand, the other games stay a few steps behind this one, so that an edit always reaches them before its time. The
-- construction menu makes the tool's action with construction_react_util.getActionParams: a terrain tool there means one is in
-- hand (said at most once a second; the bridge keeps the lead a while after the last word or edit).
local function installTerrainWatch()
	if U.terrainWatch then return end
	U.terrainWatch = true
	local ok, cu = pcall(ug_require, "/gui/construction/construction_react_util.tl")
	if not (ok and type(cu) == "table" and type(cu.getActionParams) == "function") then
		log("terrain tools: not watched (" .. tostring(cu):sub(1, 120) .. ")")
		return
	end
	if cu.__mpfTerrain then return end
	cu.__mpfTerrain = true
	local orig = cu.getActionParams
	cu.getActionParams = function(definition, ...)
		pcall(function()
			local a = definition and definition.action
			if type(a) == "string" and a:find("ACTION_TERRAIN_MODIFIER_", 1, true) == 1 then
				local now = os.clock()
				if not U.terrainSaidAt or now - U.terrainSaidAt > 1 then
					U.terrainSaidAt = now
					sendLine("terrain_tool", { tool = a })
				end
			end
		end)
		return orig(definition, ...)
	end
	log("terrain tools: watched (the other games stay behind this one while a terrain tool is in hand)")
end

-- The line tool lets a company pick only its own stations (entity_util.isOwnedByPlayerOrNotOwned): a station another company
-- shares (every player's station is shared at the smallest fee unless its company stops sharing it) can be picked too. The fee
-- is booked by the game-script bridge at every stop.
local function installShareSelect()
	if U.shareSelectInstalled then return end
	local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
	if not (okE and type(eu) == "table" and type(eu.isOwnedByPlayerOrNotOwned) == "function") then
		U.shareSelectInstalled = true
		log("companies: shared stations cannot be picked by the line tool (" .. tostring(eu):sub(1, 120) .. ")")
		return
	end
	U.shareSelectInstalled = true
	if eu.__mpfShare then return end
	eu.__mpfShare = true
	local orig = eu.isOwnedByPlayerOrNotOwned
	local cache, cacheAt = {}, -1
	eu.isOwnedByPlayerOrNotOwned = function(entity, ...)
		if orig(entity, ...) then return true end
		if not U.coMap or type(entity) ~= "number" then return false end
		local now = os.clock()
		if now - cacheAt > 1 then cache = {}; cacheAt = now end
		local v = cache[entity]
		if v == nil then
			v = false
			local sg = sharedGroupOf(entity)
			if sg then
				local fee = foreignFee(sg)
				v = fee ~= nil and fee > 0
			end
			-- a street the tool points at: a shared stop by that street (its key starts with the street's ends)
			if not v then
				pcall(function()
					local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
					if not edge then return end
					local function r(x) return string.format("%.0f", x or 0) end
					local function np(n) local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE); return c and c.position end
					local p0, p1 = np(edge.node0), np(edge.node1)
					if not (p0 and p1) then return end
					local a, b = r(p0.x) .. "," .. r(p0.y), r(p1.x) .. "," .. r(p1.y)
					if a > b then a, b = b, a end
					local prefix = "e:" .. a .. "-" .. b .. ":"
					for k, fee in pairs(U.shares or {}) do
						if fee > 0 and k:sub(1, #prefix) == prefix then v = true end
					end
				end)
			end
			cache[entity] = v
		end
		return v
	end
	log("companies: the line tool can pick the stations shared by the other companies")
end

local function sendShare(key, fee)
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("mpfever", "mpfever", "share", { key = key, fee = fee }))
	end)
	if not ok then log("companies: share request failed: " .. tostring(err)) end
end

local function ownerText(e)
	if not U.coMap then return nil end
	local n = 0
	for _ in pairs(U.coMap) do n = n + 1 end
	if n < 2 then return nil end
	local owner = ownerOf(e)
	if not owner or not U.coMap[owner] then return nil end
	local mine = U.myCo ~= nil and U.coMap[owner] == U.myCo
	return T("Propriétaire : ", "Owner: ") .. companyName(owner) .. (mine and T(" (vous)", " (you)") or ""), owner
end

local function installOwnerLine(react, builtin)
	if U.ownerInstalled then return end
	U.ownerInstalled = true
	local okM, mew = pcall(ug_require, "/gui/entity_window/make_entity_window.tl")
	if not (okM and type(mew) == "table" and type(mew.makeEntityWindowContent) == "function") then
		log("companies: the entity windows cannot show their owner (" .. tostring(mew):sub(1, 120) .. ")")
		return
	end
	local Wrap = react.RegisterRecipe("MPFeverOwnerLine", function(p)
		-- the fee changes while the window is open (this player's choice, or the owner's): read again from shares.txt
		local ver = react.useState(U.shareVersion or 0)
		local pending = react.useState(nil)   -- the fee just chosen, until every game has applied it: { fee, at }
		react.onStepTimer(function()
			local v = U.shareVersion or 0
			if ver:old() ~= v then ver:set(v) end
			local pd = pending:old()
			if pd and ((U.shares and U.shares[p.shareKey] or 0) == pd.fee or os.clock() - pd.at > 10) then pending:set(nil) end
		end, 0.5)
		local inner = nil
		if p.innerRecipe then inner = p.innerRecipe(p.innerParam)
		elseif p.innerBuiltin then inner = p.innerBuiltin({ entity = p.innerParam and p.innerParam.keyEntity }) end
		local children = { builtin.TextView { meta = { class = "font-scale-body" }, text = p.ownerText } }
		if p.shareKey then
			local fee = U.shares and U.shares[p.shareKey] or 0
			if p.shareEdit then
				-- the owner chooses the fee per stop of the other companies' vehicles (0: not shared)
				local pd = pending:old()
				local shown = pd and pd.fee or fee
				local items = {}
				for _, f in ipairs(shareChoices(shown)) do
					items[#items + 1] = builtin.ComboBoxItem {
						value = f,
						content = builtin.TextView { meta = { class = "font-scale-body" },
							text = f == 0 and T("Non partagée", "Not shared") or (money(f) .. T(" par arrêt", " per stop")) },
					}
				end
				local key = p.shareKey
				children[#children + 1] = builtin.BoxLayout { orientation = builtin.type.Orientation.Horizontal, children = {
					builtin.TextView { meta = { class = "font-scale-body" }, text = T("Partage avec les autres entreprises :  ", "Sharing with the other companies:  ") },
					builtin.ComboBox {
						value = shown,
						items = items,
						onValueChange = function(v)
							v = tonumber(v)
							if v == nil or v == shown then return end
							sendShare(key, v)
							pending:set({ fee = v, at = os.clock() })
						end,
					},
				} }
				local note
				if pd then note = T("Modification en cours pour tous les joueurs…", "Applying for every player…")
				elseif shown > 0 then note = T("Leurs véhicules paient ce montant à chaque arrêt ici ; vos lignes s'y arrêtent gratuitement.", "Their vehicles pay this at every stop here; your own lines stop for free.")
				else note = T("Les autres entreprises ne peuvent pas s'arrêter ici.", "The other companies cannot stop here.") end
				children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" .. (pd and ", info" or "") }, text = note }
			else
				children[#children + 1] = builtin.TextView { meta = { class = "font-scale-body" }, text = shareText(false, fee) }
			end
		end
		children[#children + 1] = inner
		return builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = children }
	end)
	local orig = mew.makeEntityWindowContent
	mew.makeEntityWindowContent = function(entity, gameCtx, isMapEditor, isSandboxMode, skipConstruction, ...)
		local r = orig(entity, gameCtx, isMapEditor, isSandboxMode, skipConstruction, ...)
		if skipConstruction or type(r) ~= "table" or not (r.recipe or r.builtin) then return r end
		local target = r.replacedEntity or (type(r.param) == "table" and r.param.keyEntity) or entity
		local okt, txt, owner = pcall(ownerText, target)
		if not (okt and txt) then return r end
		local oks, share = pcall(shareInfo, target, owner)
		if not oks then share = nil end
		local w = {}
		for k, v in pairs(r) do w[k] = v end
		w.recipe = Wrap
		w.builtin = nil
		w.param = { innerRecipe = r.recipe, innerBuiltin = r.builtin, innerParam = r.param, ownerText = txt,
			shareText = share and share.text or nil, shareKey = share and share.key or nil, shareFee = share and share.fee or nil,
			shareEdit = share and share.canEdit or nil,
			keyEntity = type(r.param) == "table" and r.param.keyEntity or nil, meta = type(r.param) == "table" and r.param.meta or nil }
		return w
	end
	log("companies: the entity windows show their owner")
end

-- ---------------------------------------------------------------- the session: players, their link, the sync state
-- MPFever.exe writes mp_status.txt every second (the host's view, relayed to every player): "key=value" lines and one
-- "p=id TAB name TAB state TAB lag TAB role" line per player. It is shown in MPFever's own window, opened from a card that
-- MPFever puts in the game's pause menu (no button in the game's HUD).

local function pollStatus()
	local now = os.clock()
	if U.statusAt and now - U.statusAt < 0.5 then return end
	U.statusAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "mp_status.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.statusTxt then return end
	U.statusTxt = txt
	local st = { players = {} }
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		line = line:gsub(C.CR, "")
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k == "p" then
			local f1, f2, f3, f4, f5 = v:match("^([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "?(.*)$")
			if f1 then st.players[#st.players + 1] = { id = f1, name = f2, state = f3, lag = tonumber(f4) or 0, role = f5 } end
		elseif k then
			st[k] = v
		end
	end
	U.status = st
	U.statusVersion = (U.statusVersion or 0) + 1
end

-- the speed the game's speed buttons show during a session (nil: the engine's own): the speed this player just asked
-- for, else the session's (0 while paused)
U.shownSpeed = function()
	local st = U.status
	local t = st and tonumber(st.t)
	if not st or st.started ~= "1" or t == nil or os.time() - t > 6 then return nil end
	if U.lastSpeedReq ~= nil and os.clock() - (U.lastSpeedAt or -10) < 2 then return U.lastSpeedReq end
	return tonumber(st.speed)
end

-- the status is older than a few seconds: MPFever.exe no longer writes it
local function statusStale(st)
	local t = st and tonumber(st.t)
	return t ~= nil and os.time() - t > 6
end

-- the sync line: text and colour class
local function syncLine(st)
	local sync = st and st.sync or "none"
	local parts = (st and st.parts and st.parts ~= "") and (" (" .. st.parts .. ")") or ""
	if sync == "ok" then
		local age = tonumber(st.age) or -1
		return T("Synchrone", "In sync") .. (age >= 0 and ("  ·  " .. C.Tf("vérifiée il y a %s s", "checked %s s ago", age)) or ""), "success"
	elseif sync == "drift" then
		return T("Légère dérive", "Slight drift") .. parts .. "  ·  " .. T("corrigée si elle dure", "corrected if it lasts"), "warning"
	elseif sync == "desync" then
		return T("Désynchronisé", "Out of sync") .. parts .. "  ·  " .. T("la partie de l'hôte est rechargée si l'écart persiste", "the host's game is reloaded if it persists"), "error"
	elseif sync == "resync" then
		return T("Resynchro…", "Resyncing…") .. "  ·  " .. T("rechargement de la partie de l'hôte", "reloading the host's game"), "info"
	end
	return T("pas encore vérifiée", "not checked yet"), nil
end

local PLAYER_STATES = {
	ok = function() return T("connecté", "connected"), nil end,
	slow = function(pl) return C.Tf("%s pas de retard", "%s steps behind", pl.lag), "warning" end,
	noresp = function() return T("ne répond plus", "not responding"), "error" end,
	loading = function() return T("charge la partie de l'hôte…", "loading the host's game…"), "info" end,
	joining = function() return T("se connecte…", "connecting…"), "info" end,
	left = function() return T("a quitté la partie", "left the game"), "negative" end,
}

-- a player's line: name, (you), host, its state; and the colour class (a dedicated server is not one of the players: it
-- is named above them)
local function playerLine(pl, me)
	local text = pl.name
	if pl.id == me then text = text .. T(" (vous)", " (you)") end
	if pl.role == "host" then text = text .. "  –  " .. T("hôte", "host") end
	local state, cls = (PLAYER_STATES[pl.state] or PLAYER_STATES.ok)(pl)
	return text .. "  ·  " .. state, cls
end

-- the players still in the session (those who left are listed too, for a while; a dedicated server is not counted)
local function playerCount(st)
	local n = 0
	for _, pl in ipairs(st and st.players or {}) do if pl.state ~= "left" and pl.role ~= "server" then n = n + 1 end end
	return n
end

-- this game's own link to the host, when it is not fine (nil otherwise)
local function linkLine(st)
	if not st then return T("En attente de MPFever.exe…", "Waiting for MPFever.exe…"), "info" end
	local attempt = tonumber(st.attempt) or 0
	if st.conn == "lost" then
		if attempt > 0 then return C.Tf("Connexion à l'hôte perdue : reconnexion (essai %s)…", "Connection to the host lost: reconnecting (attempt %s)…", attempt), "error" end
		return T("Connexion à l'hôte perdue…", "Connection to the host lost…"), "error"
	elseif st.conn == "gone" then
		return T("Connexion à l'hôte perdue (reconnexion impossible).", "Connection to the host lost (could not reconnect)."), "error"
	elseif st.conn == "denied" then
		-- (the host refused this player: why, in this player's language, written by MPFever.exe)
		return (st.denied and st.denied ~= "") and st.denied or T("Connexion refusée par l'hôte.", "Connection refused by the host."), "error"
	elseif statusStale(st) then
		return T("Pas de nouvelles de MPFever.exe depuis quelques secondes.", "No news from MPFever.exe for a few seconds."), "warning"
	end
	return nil
end

-- the host asks MPFever.exe to send Steam invitations (as the main menu's MPFever window does)
local function requestInvite()
	U.reqSeq = (U.reqSeq or 0) + 1
	local f = C.IO.open(C.DIR .. C.BS .. "menu_req.txt", "wb")
	if not f then log("session: cannot write menu_req.txt") return end
	f:write(tostring(os.time()) .. ".ui" .. U.reqSeq .. C.TAB .. "invite" .. C.TAB .. C.TAB .. (C.NAME or "") .. C.TAB .. C.NL)
	f:close()
end

-- "Report a problem": MPFever.exe puts the logs into a zip and opens a new GitHub issue (see Reporter.cs); it says where
-- the zip is in report.txt, shown under the button
local function requestReport()
	U.reqSeq = (U.reqSeq or 0) + 1
	local f = C.IO.open(C.DIR .. C.BS .. "menu_req.txt", "wb")
	if not f then log("session: cannot write menu_req.txt") return end
	f:write(tostring(os.time()) .. ".ui" .. U.reqSeq .. C.TAB .. "report" .. C.TAB .. C.TAB .. (C.NAME or "") .. C.TAB .. C.NL)
	f:close()
	U.reportAsked = os.time()
	U.reportMsg = T("Rapport en préparation…", "Preparing the report…")
	U.statusVersion = (U.statusVersion or 0) + 1
end

-- the answer of MPFever.exe to the last report asked (report.txt: "<ticks> TAB <text>")
local function pollReport()
	if not U.reportAsked or os.time() - U.reportAsked > 120 then return end
	local f = C.IO.open(C.DIR .. C.BS .. "report.txt", "rb")
	if not f then return end
	local line = f:read("*l")
	f:close()
	local text = line and line:match("^%d+\t(.*)$")
	if text and text ~= U.reportMsg then
		U.reportMsg = text
		U.statusVersion = (U.statusVersion or 0) + 1
	end
end

-- re-renders its recipe when the status changes, and once more when it gets old
local function useStatus(react)
	local key = function() return tostring(U.statusVersion or 0) .. (statusStale(U.status) and "s" or "") end
	local ver = react.useState(key())
	react.onStepTimer(function()
		pcall(pollReport)
		local k = key()
		if ver:old() ~= k then ver:set(k) end
	end, 0.5)
	return U.status
end

-- ---------------------------------------------------------------- in-game chat
-- MPFever.exe writes every line of the session's chat to chat.txt ("id TAB time TAB kind TAB player TAB text"; kind:
-- msg, join, left, unsent); this game's messages go to chat_out.txt ("seq TAB text"), which MPFever.exe sends to the host

-- one UTF-8 character (the mod's files have no backslash: the bytes are made with string.char)
local UTF8_CHAR = "[" .. string.char(1) .. "-" .. string.char(127) .. string.char(194) .. "-" .. string.char(244) .. "][" .. string.char(128) .. "-" .. string.char(191) .. "]*"

local function ulen(t)
	local n = 0
	for _ in t:gmatch(UTF8_CHAR) do n = n + 1 end
	return n
end

local function usub(t, maxChars)
	local out, n = {}, 0
	for ch in t:gmatch(UTF8_CHAR) do
		n = n + 1
		if n > maxChars then break end
		out[#out + 1] = ch
	end
	return table.concat(out)
end

-- a text in lines of at most w characters (the first one: firstW), cut between words when it can
local function wrap(t, firstW, w)
	local lines, cur, curLen = {}, "", 0
	local function limit() return #lines == 0 and firstW or w end
	local function push() lines[#lines + 1] = cur; cur, curLen = "", 0 end
	for word in t:gmatch("[^ ]+") do
		local wl = ulen(word)
		if curLen > 0 and curLen + 1 + wl > limit() then push() end
		while wl > limit() do
			local lim = limit() - curLen - (curLen > 0 and 1 or 0)
			if lim <= 0 then push() lim = limit() end
			local head = usub(word, lim)
			cur = cur .. (curLen > 0 and " " or "") .. head
			push()
			word = word:sub(#head + 1)
			wl = ulen(word)
		end
		if wl > 0 then
			cur = cur .. (curLen > 0 and " " or "") .. word
			curLen = curLen + (curLen > 0 and 1 or 0) + wl
		end
	end
	if curLen > 0 or #lines == 0 then push() end
	return lines
end

-- this player's name as the chat shows it (the host's status: "me", without the connection number)
local function myChatName()
	local me = U.status and U.status.me
	if me and me ~= "" then return me:match("^(.-)#%d+$") or me end
	return C.NAME
end

local CHAT_LINE = "^([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "(.*)$"

local function pollChat()
	local now = os.clock()
	if U.chatAt and now - U.chatAt < 0.4 then return end
	U.chatAt = now
	local f = C.IO.open(C.DIR .. C.BS .. "chat.txt", "rb")
	if not f then return end
	local size = f:seek("end") or 0
	U.chatOff = U.chatOff or 0
	if size < U.chatOff then U.chatOff = 0 end
	if size == U.chatOff then f:close() return end
	f:seek("set", U.chatOff)
	local data = f:read(size - U.chatOff) or ""
	f:close()
	local pos, fresh = 1, {}
	while true do
		local e = data:find(C.NL, pos, true)
		if not e then break end   -- a line still being written: read next time
		local line = data:sub(pos, e - 1):gsub(C.CR, "")
		pos = e + 1
		local id, t, kind, name, txt = line:match(CHAT_LINE)
		if id then fresh[#fresh + 1] = { id = tonumber(id) or 0, t = tonumber(t) or 0, kind = kind, name = name, text = txt } end
	end
	U.chatOff = U.chatOff + pos - 1
	if #fresh == 0 then return end
	U.chat = U.chat or {}
	for _, m in ipairs(fresh) do U.chat[#U.chat + 1] = m end
	while #U.chat > 100 do table.remove(U.chat, 1) end
	U.chatVersion = (U.chatVersion or 0) + 1
	-- the lines already there when this game loaded (a resynchronisation reloads it) are not new
	if not U.chatSeen then U.chatSeen = true return end
	local me = myChatName()
	local news = {}
	for _, m in ipairs(fresh) do
		if m.kind == "msg" and m.name ~= me then news[#news + 1] = m end
	end
	if #news > 0 and not U.chatOpen then
		U.chatUnread = (U.chatUnread or 0) + #news
		if U.onChatNews then pcall(U.onChatNews, news) end
	end
end

-- this player's message, for MPFever.exe (which sends it to the host)
local function sendChat(t)
	-- (control bytes listed, not %c: under a code page locale %c may take a byte of a UTF-8 character, issue #30)
	t = tostring(t or ""):gsub("[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. "]", " "):gsub("^ +", ""):gsub(" +$", "")
	if t == "" then return false end
	if ulen(t) > 300 then t = usub(t, 300) end
	U.chatSeq = (U.chatSeq or 0) + 1
	local f = C.IO.open(C.DIR .. C.BS .. "chat_out.txt", "ab")
	if not f then log("chat: cannot write chat_out.txt") return false end
	f:write(tostring(os.time()) .. "." .. U.chatSeq .. C.TAB .. t .. C.NL)
	f:close()
	return true
end

-- re-renders its recipe when a chat line arrives
local function useChat(react)
	local ver = react.useState(U.chatVersion or 0)
	react.onStepTimer(function()
		local v = U.chatVersion or 0
		if ver:old() ~= v then ver:set(v) end
	end, 0.3)
	return U.chat or {}
end

-- the game's own window container (to open a window without the pause menu); loaded only in game, when game.tl
-- has long been loaded by the game itself
local function defaultWindowApi()
	local ok, wapi = pcall(function()
		local g = ug_require("/gui/main/game.tl")
		local wc = g.game_react_globals.getDefaultWindowContainer()
		if wc == nil or wc:hasExpired() then return nil end
		return wc:get():getApi()
	end)
	if ok then return wapi end
	return nil
end

local function installSession(react, builtin)
	if U.sessionInstalled then return end
	U.sessionInstalled = true
	local V, H = builtin.type.Orientation.Vertical, builtin.type.Orientation.Horizontal
	local function text(t, class, cls)
		return builtin.TextView { meta = { class = (class or "font-scale-body") .. (cls and (", " .. cls) or "") }, text = t }
	end

	-- the game's own colours (default_colors.gres), with fallbacks when they cannot be read
	local FALLBACK = {
		Ok = { 0.42, 0.82, 0.45, 1 }, Warning = { 1, 0.76, 0.25, 1 }, Error = { 1, 0.38, 0.33, 1 }, Info = { 0.45, 0.72, 1, 1 },
		Negative = { 1, 0.38, 0.33, 1 }, NeutralLight = { 0.72, 0.74, 0.77, 1 }, NeutralLightest = { 1, 1, 1, 1 },
		BaseDarkMedium = { 0.16, 0.18, 0.21, 1 }, AccentVeryDark = { 0.07, 0.24, 0.33, 1 },
	}
	local CLASS_COLOR = { success = "Ok", warning = "Warning", error = "Error", info = "Info", negative = "Negative" }
	-- (the .gres colours are plain tables { r, g, b, a }: a style wants a Vec4f; alpha replaces the colour's own)
	local colorCache = {}
	local function color(name, alpha)
		local key = name .. "/" .. tostring(alpha)
		if colorCache[key] ~= nil then return colorCache[key] or nil end
		local okR, raw = pcall(function()
			local d = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
			return d[name]
		end)
		if not (okR and type(raw) == "table" and tonumber(raw[1])) then raw = FALLBACK[name] end
		local c = nil
		if raw then
			local ok, v = pcall(function() return api.type.Vec4f.new(raw[1], raw[2], raw[3], alpha or raw[4] or 1) end)
			if ok then c = v end
		end
		colorCache[key] = c or false
		return c
	end
	local function classColor(cls) return color(CLASS_COLOR[cls or ""] or "NeutralLightest") end
	-- an inline style (meta.styleSheet, as the game's own windows use it); nil when the API refuses
	local function style(t)
		local ok, st = pcall(function()
			local st = api.gui.StyleSheet.new()
			if t.color then st.color = t.color end
			if t.bg then st.backgroundColor1 = t.bg end
			if t.size then st.size = api.type.Vec2f.new(t.size[1], t.size[2]) end
			if t.image then
				local n = api.gui.NinePatch.new()
				n.fileName = t.image
				if t.nine then n.horizontal = t.nine; n.vertical = t.nine end
				st.backgroundImage1 = n
			end
			return st
		end)
		return ok and st or nil
	end
	-- a small round dot in a status colour (the game's line colour dot)
	local function dot(cls)
		return builtin.Component { meta = { styleSheet = style { size = { 14, 14 }, image = "::/gui/line_vehicle_mgmt/icons/line_surface.tga", bg = classColor(cls) } } }
	end
	local function icon(path, size)
		return builtin.ImageView { path = path, meta = { styleSheet = style { size = { size, size } } } }
	end
	local ICON_PLAYERS = "::/gui/statistics/icons/symbol_person_multiple.tga"
	local ICON_SYNC = "::/gui/menu/icons/symbol_arrows_refresh.tga"
	local ICON_PERSON = "::/gui/entity_window/icons/symbol_person.tga"
	-- the game has no chat icon: MPFever brings its own (48 x 48 grey levels, like the game's icons)
	local ICON_CHAT = "mpfever_1::/mpfever_chat.tga"
	local function row(children) return builtin.BoxLayout { orientation = H, children = children } end
	local function section(path, title) return row { icon(path, 26), text("  " .. title, "font-scale-title-4") } end
	local function muted(t) return builtin.TextView { meta = { class = "font-scale-body", styleSheet = style { color = color("NeutralLight") } }, text = t } end

	-- MPFever's window: stays open while playing, can be moved and closed
	U.SessionWindow = react.RegisterWrapperRecipe("MPFeverSessionWindow", builtin.Window, function(wp)
		local st = useStatus(react)
		-- reduced to one small card (issue #68): the sync, the players and the chat, kept for the session
		local small = react.useState(U.sessionSmall == true)
		-- its width, adjustable by steps (the game's windows cannot be resized with the mouse), kept for the session
		-- (every state before the reduced card's early return: the same hooks on every render)
		local width = react.useState(U.sessionWidth or 540)
		local function toggle()
			U.sessionSmall = not small:old()
			small:set(U.sessionSmall)
		end
		if small:old() then
			local sync, syncCls = syncLine(st)
			local link, linkCls = linkLine(st)
			local mini = {}
			if link and linkCls ~= "success" then mini[#mini + 1] = row { dot(linkCls), text("  " .. link, nil, linkCls) } end
			mini[#mini + 1] = row { dot(syncCls), text("  " .. sync, nil, syncCls) }
			mini[#mini + 1] = row { icon(ICON_PLAYERS, 22), text("  " .. T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")") }
			mini[#mini + 1] = row {
				builtin.Button { meta = { class = "secondary" }, content = icon(ICON_CHAT, 22), onClick = function() if U.openChat then U.openChat() end end },
				text("  "),
				builtin.Button { meta = { class = "secondary" }, content = text(T("Agrandir", "Expand")), onClick = toggle },
			}
			return builtin.Window {
				title = "MPFever",
				id = "window.mpfever.session",
				initialX = 0.98,
				initialY = 0.12,
				movable = true,
				closable = true,
				onClose = wp.onClose,
				content = builtin.Component { meta = { styleSheet = style { size = { 280, -1 } } }, layout = builtin.BoxLayout { orientation = V, children = mini } },
			}
		end
		local rows = {}
		local function widen(d)
			local w = math.max(400, math.min(900, width:old() + d))
			U.sessionWidth = w
			width:set(w)
		end
		rows[#rows + 1] = row {
			builtin.Button { meta = { class = "secondary" }, content = text(T("Réduire", "Reduce")), onClick = toggle },
			text("  "),
			builtin.Button { meta = { class = "secondary", tooltip = T("Plus étroite", "Narrower") }, content = text("  -  "), onClick = function() widen(-80) end },
			text(" "),
			builtin.Button { meta = { class = "secondary", tooltip = T("Plus large", "Wider") }, content = text("  +  "), onClick = function() widen(80) end },
		}
		if st and st.host then
			-- (a dedicated server: its name as its settings write it)
			local hostText = st.server == "1" and C.Tf("Serveur dédié : %s", "Dedicated server: %s", (st.title and st.title ~= "") and st.title or st.host)
				or C.Tf("Hôte : %s", "Host: %s", st.host)
			rows[#rows + 1] = muted(hostText .. "  ·  "
				.. (st.mode == "separate" and T("Une entreprise par joueur", "One company per player") or T("Une entreprise pour tous", "One company for everybody")))
		end
		local link, linkCls = linkLine(st)
		if link then rows[#rows + 1] = row { dot(linkCls), text("  " .. link, nil, linkCls) } end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = section(ICON_SYNC, T("Synchronisation", "Sync"))
		local sync, syncCls = syncLine(st)
		rows[#rows + 1] = row { dot(syncCls), text("  " .. sync, nil, syncCls) }
		local desyncs = tonumber(st and st.desyncs) or 0
		if desyncs > 0 then rows[#rows + 1] = muted(C.Tf("%s désynchronisation(s) depuis le début", "%s desync(s) since the start", desyncs)) end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = section(ICON_PLAYERS, T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")")
		for _, pl in ipairs(st and st.players or {}) do
			if pl.role ~= "server" then
				local line, cls = playerLine(pl, st.me)
				rows[#rows + 1] = row { icon(ICON_PERSON, 22), text("  " .. line, nil, cls) }
			end
		end
		if st and st.invite == "1" and st.me and st.players then
			local host = false
			for _, pl in ipairs(st.players) do if pl.id == st.me and pl.role == "host" then host = true end end
			if host then
				rows[#rows + 1] = text(" ")
				rows[#rows + 1] = builtin.Button { meta = { class = "primary" }, content = text(T("Inviter des amis Steam", "Invite Steam friends")), onClick = requestInvite }
			end
		end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = builtin.Button { meta = { class = "secondary" }, content = row { icon(ICON_CHAT, 22), text("  " .. T("Ouvrir la discussion", "Open the chat")) },
			onClick = function() if U.openChat then U.openChat() end end }
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = builtin.Button { meta = { class = "secondary" }, content = text(T("Signaler un problème (journaux)", "Report a problem (logs)")), onClick = requestReport }
		if U.reportMsg and U.reportAsked and os.time() - U.reportAsked <= 120 then rows[#rows + 1] = muted(U.reportMsg) end
		return builtin.Window {
			title = "MPFever – " .. T("Multijoueur", "Multiplayer"),
			id = "window.mpfever.session",
			initialX = 0.85,
			initialY = 0.3,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			-- wide enough for the title and the longest lines (the window takes its content's size)
			pinnable = true,
			content = builtin.Component { meta = { styleSheet = style { size = { width:old(), -1 } } }, layout = builtin.BoxLayout { orientation = V, children = rows } },
		}
	end)

	-- ------------------------------------------------ the chat window and the short notice of new messages
	local function hhmm(t)
		local ok, s = pcall(os.date, "%H:%M", t)
		return ok and s or ""
	end
	local function nameColor(name)
		return color(name == myChatName() and "Ok" or "Info")
	end
	local function coloredText(t, c, class)
		return builtin.TextView { meta = { class = class or "font-scale-body", styleSheet = style { color = c } }, text = t }
	end

	-- one chat line: time, player, text (long texts on several lines)
	local function chatRows(m, out, width)
		local time = hhmm(m.t)
		if m.kind == "join" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s a rejoint la partie", "%s joined the game", m.name))
		elseif m.kind == "left" then
			out[#out + 1] = muted(time .. "   " .. C.Tf("%s a quitté la partie", "%s left the game", m.name))
		elseif m.kind == "unsent" then
			out[#out + 1] = row { muted(time .. "   "), text(T("Non envoyé (pas de connexion à l'hôte) : ", "Not sent (no connection to the host): ") .. m.text, nil, "error") }
		else
			local head = m.name .. ":  "
			local lines = wrap(m.text, math.max(10, width - ulen(head)), width)
			out[#out + 1] = row { muted(time .. "   "), coloredText(head, nameColor(m.name)), text(lines[1]) }
			for i = 2, #lines do out[#out + 1] = row { muted("              "), text(lines[i]) } end
		end
	end

	U.ChatWindow = react.RegisterWrapperRecipe("MPFeverChatWindow", builtin.Window, function(wp)
		local chat = useChat(react)
		local draft = react.useState("")
		local gen = react.useState(0)   -- a new input field after each message (an empty one)
		local rows = {}
		local first = math.max(1, #chat - 13)
		if #chat == 0 then rows[#rows + 1] = muted(T("Aucun message pour l'instant.", "No messages yet.")) end
		for i = first, #chat do chatRows(chat[i], rows, 52) end
		rows[#rows + 1] = text(" ")
		local function send(v)
			if sendChat(v) then
				draft:set("")
				gen:set(gen:old() + 1)
			end
		end
		rows[#rows + 1] = row {
			builtin.TextInputField {
				meta = { class = "font-scale-body", localKey = "mpfever-chat-input-" .. tostring(gen:old()), styleSheet = style { size = { 420, -1 } } },
				value = "",
				placeholderText = T("Écrire un message…", "Write a message…"),
				maxLength = 300,
				acceptOnFocusLoss = false,
				onTyping = function(v) draft:set(v or "") end,
				onValueChange = function(v) send(v) end,
			},
			text("  "),
			builtin.Button { meta = { class = "primary" }, content = text(T("Envoyer", "Send")), onClick = function() send(draft:old()) end },
		}
		return builtin.Window {
			title = "MPFever – " .. T("Discussion", "Chat"),
			id = "window.mpfever.chat",
			initialX = 0.02,
			initialY = 0.45,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			content = builtin.Component { meta = { styleSheet = style { size = { 560, -1 } } }, layout = builtin.BoxLayout { orientation = V, children = rows } },
		}
	end)

	-- the notice: the new messages for a few seconds at the left of the screen (no button: it closes by itself)
	U.ChatToast = react.RegisterWrapperRecipe("MPFeverChatToast", builtin.Window, function(wp)
		local ver = react.useState(U.toastVersion or 0)
		react.onStepTimer(function()
			local v = U.toastVersion or 0
			if ver:old() ~= v then ver:set(v) end
			if U.toastShown and (U.chatOpen or os.time() >= (U.toastUntil or 0)) then
				U.toastShown = false
				pcall(function() wp.windowApi.removeAllWindows(U.ChatToast) end)
			end
		end, 0.5)
		local rows = {
			row { icon(ICON_CHAT, 22), coloredText("  MPFever – " .. T("Discussion", "Chat"), color("NeutralLight")) },
		}
		for _, m in ipairs(U.toastItems or {}) do
			local t = m.text
			if ulen(t) > 70 then t = usub(t, 68) .. "…" end
			rows[#rows + 1] = row { coloredText(m.name .. ":  ", nameColor(m.name)), text(t) }
		end
		rows[#rows + 1] = muted(T("Répondre : Échap  ›  Discussion", "Reply: Esc  ›  Chat"))
		return builtin.Window {
			title = "",
			id = "window.mpfever.chattoast",
			initialX = 0.005,
			initialY = 0.1,
			movable = false,
			closable = false,
			pinnable = false,
			compact = true,
			autoFocusOnBecomingVisible = false,
			onClose = function() end,
			content = builtin.Component {
				mouseTransparent = true,
				meta = { styleSheet = style { size = { 520, -1 } } },
				layout = builtin.BoxLayout { orientation = V, children = rows },
			},
		}
	end)

	U.onChatNews = function(news)
		local items = U.toastItems or {}
		if not U.toastShown then items = {} end
		for _, m in ipairs(news) do items[#items + 1] = m end
		while #items > 3 do table.remove(items, 1) end
		U.toastItems = items
		U.toastUntil = os.time() + 8
		U.toastVersion = (U.toastVersion or 0) + 1
		if U.toastShown then return end
		local wapi = defaultWindowApi()
		if not wapi then return end
		local ok, err = pcall(function() wapi.addSingletonWindow(U.ChatToast, { windowApi = wapi }) end)
		if ok then U.toastShown = true else log("chat: notice not shown: " .. tostring(err)) end
	end

	-- the chat window, from the pause menu (its window container) or from MPFever's window (the game's own)
	local function openChat(wapi)
		wapi = wapi or defaultWindowApi()
		if not wapi then log("chat: no window container") return false end
		local ok, err = pcall(function()
			wapi.addSingletonWindow(U.ChatWindow, {
				onClose = function()
					U.chatOpen = false
					pcall(function() wapi.removeAllWindows(U.ChatWindow) end)
				end,
			})
		end)
		if not ok then log("chat window not opened: " .. tostring(err)) return false end
		U.chatOpen = true
		U.chatUnread = 0
		if U.toastShown then
			U.toastShown = false
			pcall(function() wapi.removeAllWindows(U.ChatToast) end)
		end
		return true
	end
	U.openChat = openChat

	local function openSession(commonParams)
		local ok, err = pcall(function()
			local wc = commonParams.windowContainer:get():getApi()
			wc.addSingletonWindow(U.SessionWindow, {
				onClose = function() commonParams.windowContainer:get():getApi().removeAllWindows(U.SessionWindow) end,
			})
		end)
		if not ok then log("session window not opened: " .. tostring(err)) return end
		pcall(commonParams.onClose)   -- back to the game: the window stays open
	end

	-- the card in the pause menu: drawn as the menu's own cards (classes of the pause page: dark card, shadow,
	-- accent on hover), with an icon, a summary, and a click opens the window
	local CARD_NINE = { 0, 16, 48, 64 }   -- main_menu_sizes.ninePatchHorizontal/Vertical
	local Card = react.RegisterRecipe("MPFeverPauseCard", function(p)
		local st = useStatus(react)
		local hover = react.useState(false)
		local sync, syncCls = syncLine(st)
		local link, linkCls = linkLine(st)
		local status, cls = link or sync, link and linkCls or syncCls
		local info = builtin.BoxLayout { orientation = V, children = {
			text("MPFever  –  " .. T("Multijoueur", "Multiplayer"), "font-scale-title-4"),
			row { dot(cls), builtin.TextView { meta = { class = "font-scale-body" .. (cls and (", " .. cls) or ""), styleSheet = style { color = classColor(cls) } }, text = "  " .. status } },
			muted(C.Tf("%s joueur(s) dans la partie", "%s player(s) in the game", playerCount(st)) .. "   ·   " .. T("Afficher pendant la partie  ›", "Show while playing  ›")),
		} }
		-- a recipe's result must be a layout (the game refuses a bare button here)
		return builtin.BoxLayout { children = {
			builtin.Button {
				-- the menu card's look, set here: the pause page's CSS does not reach the card (background,
				-- colour 90 % opaque as the game's cards, accent colour under the mouse)
				meta = {
					class = "burger-menu, top-right, ani-pulse",
					styleSheet = style { size = { 600, 112 }, image = "::/gui/menu/design/main_menu_card_top_right_content_mask.tga", nine = CARD_NINE,
						bg = color(hover:old() and "AccentVeryDark" or "BaseDarkMedium", 0.9) },
					onMouseOver = function(h) if hover:old() ~= (h and true or false) then hover:set(h and true or false) end end,
				},
				content = builtin.Component { layout = builtin.BoxLayout { orientation = H, children = {
					builtin.Component { meta = { styleSheet = style { size = { 84, -1 } } }, layout = builtin.BoxLayout { children = { builtin.ImageView { path = ICON_PLAYERS } } } },
					builtin.Component { layout = info },
				} } },
				onClick = function() openSession(p.commonParams) end,
			},
		} }
	end)

	-- the chat's card, under MPFever's card: the new messages, and a click opens the chat
	local ChatCard = react.RegisterRecipe("MPFeverChatCard", function(p)
		useChat(react)
		local hover = react.useState(false)
		local unread = U.chatUnread or 0
		local info = builtin.BoxLayout { orientation = V, children = {
			text(T("Discussion", "Chat"), "font-scale-title-4"),
			unread > 0 and coloredText(C.Tf("%s nouveau(x) message(s)  ›", "%s new message(s)  ›", unread), color("Info"))
				or muted(T("Écrire aux autres joueurs  ›", "Write to the other players  ›")),
		} }
		return builtin.BoxLayout { children = {
			builtin.Button {
				meta = {
					class = "burger-menu, bottom-left, ani-pulse",
					styleSheet = style { size = { 600, 88 }, image = "::/gui/menu/design/main_menu_card_bottom_left_content_mask.tga", nine = CARD_NINE,
						bg = color(hover:old() and "AccentVeryDark" or "BaseDarkMedium", 0.9) },
					onMouseOver = function(h) if hover:old() ~= (h and true or false) then hover:set(h and true or false) end end,
				},
				content = builtin.Component { layout = builtin.BoxLayout { orientation = H, children = {
					builtin.Component { meta = { styleSheet = style { size = { 84, -1 } } }, layout = builtin.BoxLayout { children = { builtin.ImageView { path = ICON_CHAT } } } },
					builtin.Component { layout = info },
				} } },
				onClick = function()
					local cp = p.commonParams
					local wapi = nil
					pcall(function() wapi = cp.windowContainer:get():getApi() end)
					if openChat(wapi) then pcall(cp.onClose) end
				end,
			},
		} }
	end)

	-- the pause menu's main page is wrapped: drawn as usual, with the card floating at its right
	-- (the game's UI state has no rawget, and maybe no debug library: every step is guarded)
	local okR, rr = pcall(function() return _react end)
	if not (okR and type(rr) == "table" and type(rr.recipeReplace) == "table" and type(rr.originalRecipeFn) == "table") then
		log("session: the pause menu cannot be extended (no _react)")
		return
	end
	local id, how = nil, nil
	-- 0. the id caught while the page registered (mpfever_pause.lua, loaded by the native module in front of pause_menu.tl)
	local okP, pid = pcall(function() return package.loaded["mpfever_pause_id"] end)
	if okP and pid ~= nil and rr.originalRecipeFn[pid] then id, how = pid, "native hook" end
	-- 1. the recipe's id from react.lua's own table of names (the only upvalue of GetRecipeName): no side effect
	local okD, dbg = pcall(function() return debug end)
	if id then
		-- found
	elseif okD and type(dbg) == "table" and type(dbg.getupvalue) == "function" and type(react.GetRecipeName) == "function" then
		for i = 1, 8 do
			local okU, name, names = pcall(dbg.getupvalue, react.GetRecipeName, i)
			if not okU or name == nil then break end
			if type(names) == "table" then
				for fn, n in pairs(names) do
					if n == "PauseMainPage" then
						local okI, rid = pcall(react.GetRecipeId, fn)
						if okI and rid ~= nil and rr.originalRecipeFn[rid] then id, how = rid, "names table" end
					end
				end
			end
			if id then break end
		end
	else
		log("session: no debug library in the UI state")
	end
	-- 2. the id the engine gives the name, only when it is the id of an existing recipe (ids given per name)
	if not id then
		local okM, rid = pcall(function() return api.gui.react.detail.makeRecipeId("PauseMainPage") end)
		if okM and rid ~= nil and rr.originalRecipeFn[rid] then id, how = rid, "recipe name" end
	end
	if not id then
		log("session: the pause menu's page was not found: MPFever's window cannot be opened in game")
		return
	end
	local original = rr.originalRecipeFn[id]
	rr.recipeReplace[id] = function(params, ...)
		if not C.ACTIVE then return original(params, ...) end
		return builtin.FloatingLayout {
			children = {
				builtin.FloatingLayoutChild { h = -1, v = -1, item = builtin.Component { mouseTransparent = true, layout = builtin.BoxLayout { children = { original(params, ...) } } } },
				builtin.FloatingLayoutChild { h = 0.97, v = 0.5, item = builtin.BoxLayout { orientation = builtin.type.Orientation.Vertical, children = {
					Card { commonParams = params and params.commonParams },
					builtin.Component { meta = { styleSheet = style { size = { 600, 12 } } } },
					ChatCard { commonParams = params and params.commonParams },
				} } },
			},
		}
	end
	log("session: MPFever's card added to the pause menu (page found by " .. tostring(how) .. ")")
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
			if key == "RESET" then U.rev = {}; U.byKey = {}
			elseif key then
				-- (a key bound again: the entity it named before loses it, issue #53)
				local n = tonumber(e)
				U.byKey = U.byKey or {}
				local old = U.byKey[key]
				if old and old ~= n and U.rev[old] == key then U.rev[old] = nil end
				U.byKey[key] = n
				U.rev[n] = key
			end
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
			elseif kind == "notiftest" then
				local okt, errt = pcall(N.test, C.deser(payload) or {})
				if not okt then log("NOTIFTEST failed: " .. tostring(errt)) end
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

-- ---------------------------------------------------------------- notifications kept across reloads
-- At every resynchronisation each game loads the host's savegame, and with it the host's notification list (the game script
-- notifications.gs): the notifications this player dismissed since the last load come back, again and again. Dismissing is a
-- local event (see the hook: each game's own interface), so this player's choices are kept here instead, in the session
-- folder (notif_dismissed.txt, never in a savegame nor in a message), and made again after every load with the same local
-- event a right-click sends. A notification is known by its content, not by its id (each game numbers its own entries):
-- a one-shot one (a new industry, a town's wish...) also by its time, within two game minutes (the host's copy of an entry the
-- interface created has the host's time), a persistent one (warnings, contract cards) by what it stands for, without time.
-- The filter of the notification log (updateIgnoredTypes) is kept the same way. notifications.gs is not among the parts the
-- games compare, and nothing in the simulation reads it: none of this can make the games differ.
-- Also logged, to find why a client sometimes misses an "Industry Founded" notification (made by each game's own interface,
-- not by the simulation): every new notification (type, time, whether it came in dismissed) and every new industry.
N.file = "notif_dismissed.txt"
N.TOLERANCE = 120000                -- (game time units: two game minutes)
N.done, N.seen, N.ind = {}, {}, nil   -- this load: ids dismissed again or by the player, ids looked at, industries known

-- the notification game script's state, as the game's own windows read it
function N.native()
	if N.util == nil then
		local okU, nu = pcall(ug_require, "/game_mechanics/notifications/notification_util.tl")
		N.util = (okU and type(nu) == "table") and nu or false
	end
	if not N.util then return nil end
	local okS, native = pcall(N.util.externalGetNotificationsStateNative)
	if okS then return native end
	return nil
end

function N.entry(native, id)
	local okE, e = pcall(N.util.getNotificationEntryFromNative, native, id)
	if okE and type(e) == "table" then return e end
	return nil
end

-- the same text for the same content on every game: keys sorted, an entity with its revision as the game compares it
-- (entityChanged0: the first number only), whole numbers with C.int (string.format "%d" fails from 2^31 in Lua 5.2 on
-- Windows: a contract card's uid is an entity times 10000), control bytes escaped (listed, not %c, see C.ser)
N.CONTROL = "[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. '"\\]'
function N.canon(v, depth)
	local t = type(v)
	if t == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then return C.int(v) end
		return string.format("%.6g", v)
	elseif t == "string" then
		return '"' .. v:gsub(N.CONTROL, function(c) return string.format("\\%03d", c:byte()) end) .. '"'
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if (depth or 0) > 8 then return "{...}" end
		if v.entity ~= nil and type(v.revision) == "table" and type(v.revision.num) == "table" then
			return "E" .. N.canon(v.entity) .. "@" .. N.canon(v.revision.num[1])
		end
		local ks = {}
		for k in pairs(v) do ks[#ks + 1] = k end
		table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(ks) do parts[#parts + 1] = tostring(k) .. "=" .. N.canon(v[k], (depth or 0) + 1) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return t
end

-- key of an entry, and whether it is a one-shot one (matched with its time)
function N.key(entry)
	local n = entry and entry.notification
	if type(n) ~= "table" or type(n.type) ~= "string" then return nil end
	local body = n.type .. "|" .. N.canon(n.params)
	if type(entry.persisting) == "table" and next(entry.persisting) ~= nil then return "P|" .. N.canon(entry.persisting) .. "|" .. body, false end
	return "O|" .. body, true
end

-- what this player chose in this session (read once per load)
function N.load()
	if N.keys then return end
	N.keys = {}
	local f = C.IO.open(C.DIR .. C.BS .. N.file, "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local op, a, b = line:match("^(.)" .. C.TAB .. "([^" .. C.TAB .. "]*)" .. C.TAB .. "?(.*)$")
		if op == "+" then
			N.keys[a] = N.keys[a] or {}
			table.insert(N.keys[a], tonumber(b) or 0)
		elseif op == "-" then
			N.keys[a] = nil
		elseif op == "F" then
			N.filter = a
		end
	end
end

-- this player dismissed or brought back a notification, or changed the log's filter (the hook's local events; read before
-- the event changes the entry)
function N.record(ev, p)
	if ev ~= "dismiss" and ev ~= "enlist" and ev ~= "updateIgnoredTypes" then return end
	N.load()
	if ev == "updateIgnoredTypes" then
		local okS, s = pcall(function() return C.ser(C.marshal(p)) end)
		if okS and type(s) == "string" and not s:find("[" .. C.NL .. C.TAB .. "]") then
			N.filter = s
			C.appendFile(C.DIR .. C.BS .. N.file, "F" .. C.TAB .. s .. C.NL)
			log("notifications: the log's filter kept for the next loads")
		end
		return
	end
	local id = type(p) == "table" and tonumber(p.id) or nil
	local native = id and N.native()
	local entry = native and N.entry(native, id)
	local key, oneShot = N.key(entry)
	if not key or key:find("[" .. C.TAB .. C.NL .. "]") then return end
	if ev == "dismiss" then
		local t0 = oneShot and (tonumber(entry.timestamp) or 0) or 0
		N.keys[key] = N.keys[key] or {}
		table.insert(N.keys[key], t0)
		C.appendFile(C.DIR .. C.BS .. N.file, "+" .. C.TAB .. key .. C.TAB .. t0 .. C.NL)
	else
		N.keys[key] = nil
		C.appendFile(C.DIR .. C.BS .. N.file, "-" .. C.TAB .. key .. C.NL)
	end
	N.done[id] = true
	log("notifications: " .. ev .. " of " .. id .. " kept for the next loads (" .. key:sub(1, 160) .. ")")
end

-- is this entry one this player dismissed?
function N.dismissedBefore(entry)
	local key, oneShot = N.key(entry)
	local list = key and N.keys[key]
	if not list then return false end
	if not oneShot then return true end
	local t = tonumber(entry.timestamp) or 0
	for _, t0 in ipairs(list) do
		if math.abs(t - t0) <= N.TOLERANCE then return true end
	end
	return false
end

-- periodic (tick): after a load, dismiss again what this player had dismissed and set the log's filter again; log new
-- notifications and new industries (the first look after a load only counts them)
function N.tick()
	local now = os.clock()
	if N.primed and N.at and now - N.at < 1 then return end
	N.at = now
	N.load()
	local native = N.native()
	if not native then return end
	local okH, history = pcall(N.util.getHistoryFromNative, native)
	if not okH or type(history) ~= "table" then return end
	local orig = C.origCmds()
	if not (orig.sendCommand and orig.event) then return end
	if N.filter and not N.filterDone then
		N.filterDone = true
		local f = C.deser(N.filter)
		if type(f) == "table" then
			pcall(function() orig.sendCommand(orig.event("", "Notifications", "updateIgnoredTypes", f)) end)
			log("notifications: the log's filter set again after the load")
		end
	end
	local again, fresh = 0, 0
	for _, id in ipairs(history) do
		if not N.seen[id] then
			local entry = N.entry(native, id)
			if entry then
				N.seen[id] = true
				fresh = fresh + 1
				if N.primed and (N.logs or 0) < 300 then
					N.logs = (N.logs or 0) + 1
					local n = entry.notification or {}
					log("notification new " .. id .. ": " .. tostring(n.type) .. " t=" .. tostring(entry.timestamp)
						.. (entry.dismissed and " (came in dismissed: filtered)" or "") .. " " .. N.canon(n.params):sub(1, 160))
				end
				if not entry.dismissed and not N.done[id] and N.dismissedBefore(entry) then
					N.done[id] = true
					pcall(function() orig.sendCommand(orig.event("", "Notifications", "dismiss", { id = id })) end)
					again = again + 1
				end
			end
		end
	end
	if not N.primed then
		N.primed = true
		log("notifications: " .. fresh .. " in the list after the load")
	end
	if again > 0 then log("notifications: " .. again .. " dismissed again as this player had dismissed them before the load") end
	-- new industries, every 5 s (the game's interface scans them every 5 s of game time for "Industry Founded")
	if N.indAt == nil or now - N.indAt >= 5 then
		N.indAt = now
		local list = {}
		pcall(function() api.engine.forEachEntityWithComponent(function(e) list[#list + 1] = e end, api.type.ComponentType.INDUSTRY) end)
		local first = N.ind == nil
		N.ind = N.ind or {}
		local t = nil
		pcall(function() t = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime end)
		for _, e in ipairs(list) do
			if not N.ind[e] then
				N.ind[e] = true
				if not first and (N.logs or 0) < 300 then
					N.logs = (N.logs or 0) + 1
					local con, built = nil, nil
					pcall(function()
						con = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY).construction
						built = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION).timeBuilt
					end)
					log("new industry " .. e .. ": construction " .. tostring(con) .. ", built at t=" .. tostring(built) .. ", seen at t=" .. tostring(t))
				end
			end
		end
		if first then log("industries: " .. #list .. " after the load") end
	end
end

-- autotest (MPFEVER_SCENARIO=notiftest,resync,notiftest,resync,notiftest): 1st message, host: three test notifications of
-- type industry_spawn (a local Notifications/add, as the interface sends it); 2nd, client (it has them from the host's savegame): dismissed the way
-- a right-click does; 3rd, both: how many of them are dismissed (client: all, again after the load; host: none)
function N.test(p)
	if type(p) ~= "table" or p.role ~= C.ROLE then return end
	local f = C.IO.open(C.DIR .. C.BS .. "notiftest_step.txt", "rb")
	local step = 1
	if f then step = (tonumber(f:read("*a")) or 0) + 1; f:close() end
	local fw = C.IO.open(C.DIR .. C.BS .. "notiftest_step.txt", "wb")
	if fw then fw:write(tostring(step)); fw:close() end
	local native = N.native()
	local orig = C.origCmds()
	local function tests()
		local list = {}
		local okH, history = pcall(N.util.getHistoryFromNative, native)
		for _, id in ipairs(okH and history or {}) do
			local e = N.entry(native, id)
			if e and type(e.notification) == "table" and type(e.notification.params) == "table" and e.notification.params.mpfTest then list[#list + 1] = { id = id, e = e } end
		end
		return list
	end
	if not native then log("NOTIFTEST step " .. step .. ": no notification state") return end
	if step == 1 and C.ROLE == "host" then
		local okE, eu = pcall(ug_require, "/scripts/entity_util.tl")
		local inds = {}
		pcall(function() api.engine.forEachEntityWithComponent(function(e) inds[#inds + 1] = e end, api.type.ComponentType.INDUSTRY) end)
		local made = 0
		for i = 1, math.min(3, #inds) do
			local er = okE and eu.makeEntityAndRevision(inds[i]) or nil
			if er then
				pcall(orig.sendCommand, orig.event("", "Notifications", "add", { type = "game_mechanics/notifications/types/industry_spawn.script",
					params = { entity = er, mpfTest = 1 }, autoDismissDuration = 3600000 }))
				made = made + 1
			end
		end
		log("NOTIFTEST step 1 (host): " .. made .. " test notifications added")
	elseif step == 2 and C.ROLE == "client" then
		local list = tests()
		for _, t in ipairs(list) do
			if not t.e.dismissed then
				-- (through the hooked function, as the notification window's right-click)
				api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", "Notifications", "dismiss", { id = t.id }))
			end
		end
		log("NOTIFTEST step 2 (client): " .. #list .. " test notifications dismissed")
	else
		local list = tests()
		local d = 0
		for _, t in ipairs(list) do if t.e.dismissed then d = d + 1 end end
		log("NOTIFTEST step " .. step .. " (" .. C.ROLE .. "): " .. #list .. " test notifications, " .. d .. " dismissed")
	end
end

local function tick(pendingState)
	-- which company the interface acts as (logged when it changes, and how often it read another one in between)
	pcall(function()
		local p = api.engine.util.getPlayer()
		U.uiReads = (U.uiReads or 0) + 1
		if p ~= U.uiPlayer then
			log("the interface plays " .. tostring(p) .. " (was " .. tostring(U.uiPlayer) .. ", " .. tostring(U.uiReads) .. " reads)")
			U.uiPlayer = p
			U.uiReads = 0
		end
	end)
	pcall(pollBindings)
	pcall(pollCompanies)
	if not U.terrainWatch then
		local okt, errt = pcall(installTerrainWatch)
		if not okt then U.terrainWatch = true; log("terrain tools: not watched: " .. tostring(errt)) end
	end
	pcall(pollShares)
	if U.coMap and not U.shareSelectInstalled then
		local oks, errs = pcall(installShareSelect)
		if not oks then U.shareSelectInstalled = true; log("companies: share pick not installed: " .. tostring(errs)) end
	end
	if U.coMap and not U.stopFeesInstalled then
		local okf, errf = pcall(installStopFees)
		if not okf then U.stopFeesInstalled = true; log("companies: stop fees not shown: " .. tostring(errf)) end
	end
	if U.coMap and not U.ownerInstalled and U.react and U.builtin then
		local oko, erro = pcall(installOwnerLine, U.react, U.builtin)
		if not oko then log("companies: owner line not installed: " .. tostring(erro)) end
	end
	-- (autotest) the window maker asked for an entity: what the owner line would show
	if U.ownerInstalled and (U.selfTestAt == nil or os.clock() - U.selfTestAt > 1) then
		U.selfTestAt = os.clock()
		local f = C.IO.open(C.DIR .. C.BS .. "ui_selftest.txt", "rb")
		if f then
			local e = tonumber((f:read("*a") or ""):match("%d+"))
			f:close()
			if e then
			local fw = C.IO.open(C.DIR .. C.BS .. "ui_selftest.txt", "wb")
			if fw then fw:close() end
			local okm, mew = pcall(ug_require, "/gui/entity_window/make_entity_window.tl")
			local okw, r = pcall(function()
				return mew.makeEntityWindowContent(e, nil, false, false, nil, { function() end, "static" }, nil, { function() end, "static" })
			end)
			if okw and type(r) == "table" then
				local p = r.param or {}
				local oke, eu = pcall(ug_require, "/scripts/entity_util.tl")
				local pick = oke and type(eu) == "table" and eu.isOwnedByPlayerOrNotOwned(e)
				-- (the line tool points at the station, its construction or its street too)
				pcall(function()
					local g = api.engine.getComponent(e, api.type.ComponentType.STATION_GROUP)
					for _, st in ipairs(g and g.stations or {}) do
						pick = tostring(pick) .. " station " .. st .. ":" .. tostring(eu.isOwnedByPlayerOrNotOwned(st))
						local okc, con = pcall(function() return api.engine.system.streetConnectorSystem and nil end)
						local ce = nil
						pcall(function() ce = api.engine.system.streetConstructionSystem.getConstructionEntityForStation(st) end)
						if type(ce) == "number" and ce >= 0 then pick = pick .. " con " .. ce .. ":" .. tostring(eu.isOwnedByPlayerOrNotOwned(ce)) end
					end
				end)
				log("selftest window of " .. tostring(e) .. ": recipe " .. tostring(r.recipe) .. ", owner '" .. tostring(p.ownerText) .. "', share '" .. tostring(p.shareText) .. "' edit " .. tostring(p.shareEdit) .. " key " .. tostring(p.shareKey) .. " pickable " .. tostring(pick)
					.. " name '" .. tostring(oke and type(eu) == "table" and eu.getEntityName(e)) .. "'")
			else
				log("selftest window of " .. tostring(e) .. ": " .. tostring(r):sub(1, 200))
			end
			end
		end
	end
	pcall(pollLoanView)
	local okn, errn = pcall(N.tick)
	if not okn and not N.failed then N.failed = true; log("notifications: " .. tostring(errn)) end
	pcall(pollStatus)
	local okch, errch = pcall(pollChat)
	if not okch then log("chat poll failed: " .. tostring(errch)) end
	if not U.sessionInstalled and U.react and U.builtin then
		local oks, errs = pcall(installSession, U.react, U.builtin)
		if not oks then log("session: not installed: " .. tostring(errs)) end
	end
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
		U.react, U.builtin = react, builtin
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
