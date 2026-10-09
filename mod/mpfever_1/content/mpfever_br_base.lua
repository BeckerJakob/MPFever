-- MPFever bridge: shared requires, game time, state hashing, order of simultaneous actions.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)


okC, C = pcall(ug_require, "mpfever_common.lua")
if not okC then C = ug_require("mpfever_1::/mpfever_common.lua") end
log = C.logger("", "mod.log")
okR, R = pcall(ug_require, "mpfever_refs.lua")
if not okR then R = ug_require("mpfever_1::/mpfever_refs.lua") end
BS, NL, CR, TAB = C.BS, C.NL, C.CR, C.TAB
-- the channels to MPFever.exe, the UI hook and the native module (mpfever_link.lua: files in MPFEVER_DIR)
okL, LINKS = pcall(ug_require, "mpfever_link.lua")
if not okL then LINKS = ug_require("mpfever_1::/mpfever_link.lua") end
LINK = LINKS.files(C)

STEP = 200          -- game time units per simulation step
STAMP_AHEAD = 3     -- steps between an action and its application on every game (barrier slack + 1)

function gameTime()
	local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	return gt.gameTime
end

function gameSpeed()
	local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED)
	return gs and gs.speedup or 0
end

-- order-independent hash of a plain Lua value (game script states): tables are hashed as a sum over their entries,
-- so that the iteration order (which differs between Lua states) does not matter
function valueHash(v, d)
	local t = type(v)
	if t == "number" then
		if v ~= v then return 1 end
		if math.floor(v) == v and math.abs(v) < 1e15 then return C.hashStr(7, C.int(v)) end
		return C.hashStr(7, string.format("%.6g", v))
	elseif t == "string" then
		return C.hashStr(11, v)
	elseif t == "boolean" then
		return v and 3 or 5
	elseif t == "table" then
		if d > 14 then return 13 end
		local acc = 17
		for k, x in pairs(v) do
			-- local counters, not game state: entity revisions (bumped by each game's own component writes) and the
			-- interface clock of the mission script
			if k ~= "revision" and k ~= "guiTimeSeconds" then
				acc = (acc + C.hashStr(valueHash(k, d + 1), tostring(valueHash(x, d + 1)))) % 4294967296
			end
		end
		return acc
	end
	return 19
end

-- game mechanics written as game scripts (their whole state lives in the savegame and must be equal everywhere)
GAME_SCRIPTS = {
	company = "::/game_mechanics/company/company.gs",
	progression = "::game_mechanics/company/company_progression.gs",
	loan = "::/game_mechanics/finance/loan.gs",
	subventions = "::/game_mechanics/subventions/subventions.gs",
	mission = "::mission/mission.gs",
	gametime = "::/game_mechanics/game_time/game_time.gs",
	industries = "::/game_mechanics/industries/industries.gs",
	towns = "::/game_mechanics/towns/town.gs",
	towncargo = "::/game_mechanics/towns/town_cargo.gs",
	celebrations = "::/game_mechanics/celebrations/celebrations.gs",
}

-- multiset of counts (entity ids differ between games: only the amounts are compared)
function countsHash(counts)
	local n, total, acc = 0, 0, 0
	for _, c in ipairs(counts) do
		n = n + 1
		total = total + c
		acc = (acc + C.hashStr(23, C.int(c))) % 4294967296
	end
	return n .. "/" .. total .. "/" .. acc
end

-- diagnostic (MPFEVER_SDUMP set): every value of the game script states, one "path = value" per line, sorted, so
-- that two games' files at the same game time can be compared line by line
SDUMP = os.getenv("MPFEVER_SDUMP")
sdumps = 0
function flatten(v, path, out, d)
	if type(v) == "table" and d < 16 then
		for k, x in pairs(v) do flatten(x, path .. "." .. tostring(k), out, d + 1) end
	else
		out[#out + 1] = path .. " = " .. (type(v) == "number" and string.format("%.10g", v) or tostring(v))
	end
end

function extendedParts(parts)
	local dump = SDUMP and sdumps < 40 and {}
	for name, res in pairs(GAME_SCRIPTS) do
		local ok, v = pcall(function()
			local e = api.engine.system.gameScriptSystem.getEntityForGameScript(res)
			if not e or e < 0 then return "absent" end
			local c = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)
			if not c then return "absent" end
			if dump then flatten(c.state, name, dump, 0) end
			return tostring(valueHash(c.state, 0))
		end)
		if ok and v ~= "absent" then parts["script:" .. name] = v end
	end
	if dump then
		sdumps = sdumps + 1
		table.sort(dump)
		pcall(function()
			local f = C.IO.open(C.DIR .. BS .. "sdump_" .. string.format("%012d", gameTime()) .. ".txt", "wb")
			f:write(table.concat(dump, NL), NL)
			f:close()
		end)
	end
	-- cargo waiting in buildings (industries, warehouses, stations)
	pcall(function()
		local counts = {}
		for _, list in pairs(api.engine.system.simEntityAtStockSystem.getStock2SimEntityMap() or {}) do counts[#counts + 1] = #list end
		parts.stocks = countsHash(counts)
	end)
	-- cargo and passengers on board of vehicles
	pcall(function()
		local counts = {}
		for _, byCargo in pairs(api.engine.system.simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap() or {}) do
			local n = 0
			for _, list in pairs(byCargo) do n = n + #list end
			counts[#counts + 1] = n
		end
		parts.onboard = countsHash(counts)
	end)
	pcall(function()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		parts.timeOfDay = gt.timeOfDaySec
	end)
end

-- values the host imposes on the other games (corrected at every checkpoint)
function authValues()
	local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
	return { balance = acc.balance, loan = acc.loan }
end

-- a client brings its money to the host's value at checkpoint n: the difference measured at the same game time
function correctMoney(own, host, n, sendCommand)
	if not own or type(host.balance) ~= "number" or type(own.balance) ~= "number" then return end
	local delta = host.balance - own.balance
	if delta == 0 then return end
	local entry = api.type.JournalEntry.new()
	entry.amount = math.floor(delta + 0.5)
	entry.time = -1
	entry.category.type = api.type.JournalEntry.Type.OTHER
	sendCommand(api.cmd.makeJournalBookAssetCmd(api.engine.util.getPlayer(), entry))
	log("host authority: money corrected by " .. entry.amount .. " (checkpoint " .. tostring(n) .. ")")
end

hashShown = false
function simHash(terrainSig)
	local parts = R.contentHash(C.hashStr, C.dump)
	-- the terrain edits applied so far (the sum of their cells' checksums, kept in the simulation state)
	parts.terrain = tostring(terrainSig or 0)
	local okx, errx = pcall(extendedParts, parts)
	if not okx then parts.extended = "ERR " .. tostring(errx):sub(1, 80) end
	if not hashShown then
		hashShown = true
		local t = {}
		for k, v in pairs(parts) do t[#t + 1] = k .. "=" .. tostring(v) end
		table.sort(t)
		log("hash parts: " .. table.concat(t, " ; "))
		for k, v in pairs(R.loopErrors) do log("cannot list " .. k .. ": " .. v) end
	end
	local ok, t = pcall(gameTime)
	parts.time = ok and t or "?"
	if R.ncDump then
		pcall(function()
			table.sort(R.ncDump)
			local f = C.IO.open(C.DIR .. BS .. "nc_" .. string.format("%012d", t) .. ".txt", "wb")
			f:write(table.concat(R.ncDump, NL), NL)
			f:close()
		end)
		R.ncDump = nil
	end
	local okm, money = pcall(function()
		local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
		return acc.balance .. "/" .. acc.loan
	end)
	parts.money = okm and money or "?"
	-- debugging (MPFEVER_CONDUMP=1): every construction at each checkpoint, to find the first action that differs
	if os.getenv("MPFEVER_CONDUMP") then
		pcall(function()
			local lines = {}
			for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
				local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
				local pp = c and c.transf and R.matPos(c.transf)
				if pp then lines[#lines + 1] = string.format("%s %.1f,%.1f #%d", tostring(c.fileName):match("[^/]+$"), pp.x, pp.y, e) end
			end
			table.sort(lines)
			local f = C.IO.open(C.DIR .. BS .. "con_" .. tostring(parts.time) .. ".txt", "wb")
			if f then f:write(table.concat(lines, NL) .. NL); f:close() end
		end)
	end
	return parts
end

-- deterministic order of actions applied at the same time
function before(x, y)
	if x.at ~= y.at then return x.at < y.at end
	if (x.origin or "") ~= (y.origin or "") then return (x.origin or "") < (y.origin or "") end
	return (x.oseq or 0) < (y.oseq or 0)
end

SIM = { subscribed = false }

end
