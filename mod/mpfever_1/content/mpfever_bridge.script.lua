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

local okC, C = pcall(ug_require, "mpfever_common.lua")
if not okC then C = ug_require("mpfever_1::/mpfever_common.lua") end
local log = C.logger("", "mod.log")
local okR, R = pcall(ug_require, "mpfever_refs.lua")
if not okR then R = ug_require("mpfever_1::/mpfever_refs.lua") end
local BS, NL, CR, TAB = C.BS, C.NL, C.CR, C.TAB

local STEP = 200          -- game time units per simulation step
local STAMP_AHEAD = 3     -- steps between an action and its application on every game (barrier slack + 1)

local function gameTime()
	local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	return gt.gameTime
end

local function gameSpeed()
	local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED)
	return gs and gs.speedup or 0
end

-- order-independent hash of a plain Lua value (game script states): tables are hashed as a sum over their entries,
-- so that the iteration order (which differs between Lua states) does not matter
local function valueHash(v, d)
	local t = type(v)
	if t == "number" then
		if v ~= v then return 1 end
		if math.floor(v) == v and math.abs(v) < 1e15 then return C.hashStr(7, string.format("%d", v)) end
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
local GAME_SCRIPTS = {
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
local function countsHash(counts)
	local n, total, acc = 0, 0, 0
	for _, c in ipairs(counts) do
		n = n + 1
		total = total + c
		acc = (acc + C.hashStr(23, string.format("%d", c))) % 4294967296
	end
	return n .. "/" .. total .. "/" .. acc
end

-- diagnostic (MPFEVER_SDUMP set): every value of the game script states, one "path = value" per line, sorted, so
-- that two games' files at the same game time can be compared line by line
local SDUMP = os.getenv("MPFEVER_SDUMP")
local sdumps = 0
local function flatten(v, path, out, d)
	if type(v) == "table" and d < 16 then
		for k, x in pairs(v) do flatten(x, path .. "." .. tostring(k), out, d + 1) end
	else
		out[#out + 1] = path .. " = " .. (type(v) == "number" and string.format("%.10g", v) or tostring(v))
	end
end

local function extendedParts(parts)
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
local function authValues()
	local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
	return { balance = acc.balance, loan = acc.loan }
end

-- a client brings its money to the host's value at checkpoint n: the difference measured at the same game time
local function correctMoney(own, host, n, sendCommand)
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

local hashShown = false
local function simHash()
	local parts = R.contentHash(C.hashStr, C.dump)
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
	local okm, money = pcall(function()
		local acc = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
		return acc.balance .. "/" .. acc.loan
	end)
	parts.money = okm and money or "?"
	return parts
end

-- deterministic order of actions applied at the same time
local function before(x, y)
	if x.at ~= y.at then return x.at < y.at end
	if (x.origin or "") ~= (y.origin or "") then return (x.origin or "") < (y.origin or "") end
	return (x.oseq or 0) < (y.oseq or 0)
end

local SIM = { subscribed = false }

-- ================================================================== action execution

local ENTITY_ARGS = {
	makeVehicleBuyCmd = { 1, 2 }, makeVehicleSellCmd = { 1 }, makeVehicleSetLineCmd = { 1, 2 }, makeVehicleSendToDepotCmd = { 1 },
	makeVehicleReverseCmd = { 1 }, makeVehicleReplaceCmd = { 1 }, makeVehicleSetStoppedByUserCmd = { 1 },
	makeLineUpdateCmd = { 1 }, makeLineDestroyCmd = { 1 }, makeLineCreateCmd = { 3 }, makeEntitySetNameCmd = { 1 }, makeEntitySetColorCmd = { 1 },
}

local function missingEntities(fn, margs)
	local missing = {}
	local function check(e, what)
		if type(e) == "number" and e >= 0 then
			local ok, exists = pcall(function() return api.engine.entityExists(e) end)
			if ok and exists == false then missing[#missing + 1] = what .. "=" .. e end
		end
	end
	for _, i in ipairs(ENTITY_ARGS[fn] or {}) do check(margs[i], "arg" .. i) end
	if fn == "makeLineCreateCmd" or fn == "makeLineUpdateCmd" then
		local line = margs[fn == "makeLineCreateCmd" and 4 or 2]
		if type(line) == "table" then
			for k, stop in ipairs(line.stops or {}) do
				if type(stop) == "table" then check(stop.stationGroup, "stop" .. k .. ".stationGroup") end
			end
		end
	end
	return missing
end

-- Ways to rebuild a captured build, tried in this order; a factory failure has no side effect, so the same sequence
-- gives the same outcome on every machine. ie/pi: the ignoreErrors and playerInitiated flags given to the factory
-- (the game's own scripts pass true/false; the native tools true... as captured).
local BUILD_TRIES = {
	{ v = "full" }, { v = "minimal" }, { v = "minimalNoOwner" }, { v = "bare" },
	{ v = "full", ie = true, pi = false }, { v = "minimal", ie = true, pi = false },
	{ v = "minimalNoOwner", ie = true, pi = false }, { v = "bare", ie = true, pi = false },
	{ v = "full", raw = true }, { v = "minimal", raw = true, ie = true, pi = false },
}

local function shortErr(e)
	local m = tostring(e)
	m = m:match("^[^" .. NL .. "]*") or m
	m = m:gsub("^.*%.lua" .. string.char(34) .. "%]:%d+: ", "")
	return m:sub(1, 90)
end

local function tryLabel(t)
	return t.v .. (t.raw and "/raw" or "") .. (t.ie ~= nil and "/ie" or "")
end

-- returns the command (or nil), the label of the combination that worked, the failures
local function buildCommand(fn, srcArgs, tries)
	local errs = {}
	for _, t in ipairs(tries) do
		local margs = C.deser(srcArgs)
		if t.ie ~= nil then margs[3] = t.ie; margs[4] = t.pi end
		local okr, args, n = pcall(C.rebuildArgs, fn, margs, { seed = 7919, variant = t.v, raw = t.raw })
		if not okr then
			errs[#errs + 1] = tryLabel(t) .. ": rebuild " .. shortErr(args)
		else
			local okc, c = pcall(function() return api.cmd[fn](table.unpack(args, 1, n)) end)
			if okc and c then return c, tryLabel(t), errs end
			errs[#errs + 1] = tryLabel(t) .. ": " .. shortErr(c)
		end
	end
	return nil, nil, errs
end

-- Executes one replicated action. Returns a result record (for the originator's UI and the bindings).
-- done (optional, with useCallback): called with the result once the engine has answered (or at once on failure)
local function executeAction(a, sendCommand, useCallback, bind, done)
	local result = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = false }
	local okt, unresolved = pcall(R.translateIn, a.args or {}, bind or {})
	if not okt then
		result.err = "references: " .. tostring(unresolved)
		log("action " .. tostring(a.uid) .. " reference resolution failed: " .. tostring(unresolved))
		return result
	end
	if #unresolved > 0 then
		result.err = "DESYNC unresolved: " .. table.concat(unresolved, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	local okm, missing = pcall(missingEntities, a.fn, a.args or {})
	if okm and #missing > 0 then
		result.err = "DESYNC missing entities: " .. table.concat(missing, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	local isBuild = a.fn == "makeWorldBuildProposalCmd"
	local cmd, label, errs = buildCommand(a.fn, C.ser(a.args or {}), isBuild and BUILD_TRIES or { { v = "full" } })
	if not cmd then
		result.err = table.concat(errs, " | ")
		log("BUILD NOT REPLAYABLE " .. tostring(a.uid) .. " " .. tostring(a.fn) .. ": " .. result.err)
		return result
	end
	if isBuild then
		pcall(function()
			local src = a.args[1].proposal or {}
			local seg = (src.addedSegments or {})[1]
			local shipped = seg and seg.comp and seg.comp.roadTemplate
			local margs = C.deser(C.ser(a.args))
			local args = C.rebuildArgs(a.fn, margs, { seed = 7919, variant = label:match("^[^/]+"), raw = label:find("/raw") ~= nil })
			local ssp = args[1].streetProposal
			local e = ssp.edgesToAdd[1]
			log("  debug: shipped segments=" .. #(src.addedSegments or {}) .. " removed=" .. #(src.removedSegments or {}) .. " template=" .. tostring(shipped)
				.. " | rebuilt add=" .. #ssp.edgesToAdd .. " remove=" .. #ssp.edgesToRemove .. " nodes=" .. #ssp.nodesToAdd
				.. (e and (" e.id=" .. tostring(e.entity) .. " n0=" .. tostring(e.comp.node0) .. " n1=" .. tostring(e.comp.node1) .. " tmpl=" .. tostring(e.comp.roadTemplate) .. " lanes=" .. tostring(#e.comp.laneConfigs)) or "")
				.. " removeIds=" .. C.ser(ssp.edgesToRemove))
		end)
		log("action " .. tostring(a.uid) .. " rebuilt as '" .. label .. "'" .. (#errs > 0 and (" after " .. #errs .. " refused form(s)") or ""))
		if #C.errors > 0 then log("  notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
	end
	local createdKey = (a.fn == "makeLineCreateCmd" and "L" or ((a.fn == "makeVehicleBuyCmd" or a.fn == "makeVehicleReplaceCmd") and "V" or nil))
	local oks, errs
	if useCallback then
		oks, errs = pcall(sendCommand, cmd, function(data, ok, resultEntities)
			result.success = ok
			if isBuild then
				local why = ""
				if not ok then pcall(function() why = " " .. C.ser(C.marshal(data.resultProposalData.errorState.messages)) end) end
				log("action " .. tostring(a.uid) .. " applied by the engine: " .. (ok and "BUILT" or ("REFUSED" .. why)))
			end
			result.data = C.marshal(data)
			result.entities = C.marshal(resultEntities)
			local first = nil
			pcall(function() first = resultEntities[1][1] end)
			if ok and createdKey and type(first) == "number" then result.created = { key = createdKey .. a.uid, e = first } end
			result.answered = true
			if done and result.returned then done(result) end
		end)
	else
		-- simulation state: no callbacks; the command runs at once; created entities are found by difference
		local watch = createdKey == "L" and "LINE" or (createdKey == "V" and "TRANSPORT_VEHICLE" or nil)
		local function list()
			local r = {}
			if watch == "LINE" then
				for _, e in ipairs(api.engine.system.lineSystem.getLines()) do r[e] = true end
			else
				for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do r[e] = true end
			end
			return r
		end
		local beforeSet = nil
		if watch then
			local okl, l = pcall(list)
			if okl then beforeSet = l else log("creation watch failed: " .. tostring(l)) end
		end
		oks, errs = pcall(sendCommand, cmd)
		if oks then
			result.success = true
			local data = {}
			if beforeSet then
				local created = nil
				local okl, after = pcall(list)
				if okl then
					for e, _ in pairs(after) do
						if not beforeSet[e] and (created == nil or e > created) then created = e end
					end
				end
				if created then
					if watch == "TRANSPORT_VEHICLE" then data.resultVehicleEntity = created else data.resultEntity = created end
					result.entities = { { created, 0 } }
					result.created = { key = createdKey .. a.uid, e = created }
				else
					-- the engine may create it during the next step: watch for it
					local seen = {}
					for e, _ in pairs(beforeSet) do seen[#seen + 1] = e end
					result.watch = { kind = watch, key = createdKey .. a.uid, before = seen, steps = 0 }
				end
			end
			result.data = data
		end
	end
	if not oks then
		result.err = "send: " .. tostring(errs)
		log("SEND FAILED " .. tostring(a.uid) .. ": " .. tostring(errs))
		if done then done(result) end
		return result
	end
	if useCallback and done then
		-- the verdict comes in the callback (logged and reported there)
		result.returned = true
		if result.answered then done(result) end
		return result
	end
	log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " at t=" .. tostring(gameTime()) .. " -> " .. (result.success and "OK" or "REFUSED"))
	return result
end

local function reverseOf(bind)
	local rev = {}
	for k, e in pairs(bind or {}) do rev[e] = k end
	return rev
end

-- ================================================================== simulation half (engine state)


local function simApplyDue(state)
	local st = state:get() or {}
	local now = gameTime()
	local changed = false
	local q = st.q or {}
	if #q > 0 then
		table.sort(q, before)
		local keep, bought = {}, false
		st.results = st.results or {}
		st.bind = st.bind or {}
		for _, a in ipairs(q) do
			if a.at <= now and not (a.fn == "makeVehicleBuyCmd" and bought) then
				changed = true
				if a.kind == "hash" then
					local c0 = os.clock()
					local okA, auth = pcall(authValues)
					st.hash = { n = a.n, parts = simHash(), cost = os.clock() - c0, auth = okA and auth or nil }
					st.authOwn = st.authOwn or {}
					st.authOwn[#st.authOwn + 1] = { n = a.n, auth = okA and auth or nil }
					while #st.authOwn > 10 do table.remove(st.authOwn, 1) end
				else
					if a.at < now then log("LATE action " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)") end
					if a.fn == "makeVehicleBuyCmd" then bought = true end
					-- mark the replay so that onPreBuildProposal does not ship it again
					st.replay = { at = now, n = ((st.replay and st.replay.at == now) and st.replay.n or 0) + 1 }
					state:set(st)
					local r = executeAction(a, api.cmd.sendCommand, false, st.bind)
					st = state:get() or st
					r.at = now
					if r.created then st.bind = st.bind or {}; st.bind[r.created.key] = r.created.e end
					if r.watch then
						st.watches = st.watches or {}
						st.watches[#st.watches + 1] = r
					else
						st.results = st.results or {}
						st.results[#st.results + 1] = r
						while #st.results > 40 do table.remove(st.results, 1) end
					end
				end
			else
				keep[#keep + 1] = a
			end
		end
		st.q = keep
	end
	-- entities created one or more steps after their command (vehicle purchases)
	if st.watches and #st.watches > 0 then
		local keepW = {}
		for _, r in ipairs(st.watches) do
			local w = r.watch
			w.steps = w.steps + 1
			local seen = {}
			for _, e in ipairs(w.before) do seen[e] = true end
			local created = nil
			pcall(function()
				local function consider(e) if not seen[e] and (created == nil or e > created) then created = e end end
				if w.kind == "LINE" then
					for _, e in ipairs(api.engine.system.lineSystem.getLines()) do consider(e) end
				else
					for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do consider(e) end
				end
			end)
			if created or w.steps >= 10 then
				r.watch = nil
				if created then
					r.created = { key = w.key, e = created }
					r.entities = { { created, 0 } }
					r.data = (w.kind == "LINE") and { resultEntity = created } or { resultVehicleEntity = created }
					st.bind = st.bind or {}
					st.bind[w.key] = created
				else
					r.success = false
					r.err = "created entity not found"
				end
				log("action " .. tostring(r.uid) .. " result after " .. w.steps .. " step(s): " .. (created and ("entity " .. created) or "nothing created"))
				st.results = st.results or {}
				st.results[#st.results + 1] = r
			else
				keepW[#keepW + 1] = r
			end
		end
		st.watches = keepW
		changed = true
	end
	if st.pauseAt and now >= st.pauseAt and not st.pausedAt then
		st.pausedAt = now
		api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(0))
		changed = true
	end
	if changed then state:set(st) end
end

-- Deterministic math.random for the game mechanics: the n-th draw of a simulation step depends only on the game time
-- and n, whatever happened before (another script drawing first, the generator state of the process...).
local detRandom
local function installRandom()
	if detRandom and math.random == detRandom then return end
	local lastT, n = -1, 0
	detRandom = function(m, k)
		local okT, t = pcall(gameTime)
		t = okT and t or 0
		if t ~= lastT then lastT, n = t, 0 end
		n = n + 1
		local h = (t % 4294967296 + n * 2654435769) % 4294967296
		for _ = 1, 3 do
			-- 32-bit multiply in doubles (exact: each partial product stays below 2^53), then fold the high bits down
			local hi, lo = math.floor(h / 65536), h % 65536
			h = ((hi * 2246822519) % 65536 * 65536 + lo * 2246822519) % 4294967296
			h = (h + math.floor(h / 8192)) % 4294967296
		end
		local x = h / 4294967296
		if m == nil then return x end
		if k == nil then m, k = 1, m end
		return m + math.floor(x * (k - m + 1))
	end
	math.random = detRandom
	log("deterministic math.random installed")
end

local function update(userParams, state, dt)
	if not C.ACTIVE then return end
	-- The game mechanics scripts (contracts, loans, weather, industries, towns...) draw random numbers from the Lua
	-- generator, which is not part of the savegame and differs between games: reseeded from the game time at every
	-- simulation step, every game draws the same numbers.
	pcall(function() math.randomseed(gameTime()) end)
	installRandom()
	if not SIM.subscribed then
		SIM.subscribed = true
		pcall(function() state:subscribeToAllEvents() end)
	end
	local ok, err = pcall(simApplyDue, state)
	if not ok then log("simulation apply failed: " .. tostring(err)) end
end

-- A native build by this machine's player, announced by the engine just BEFORE it is applied (onPreBuildProposal).
-- The proposal is captured and stamped STAMP_AHEAD steps later, then emptied so that the engine applies nothing now
-- (strict mode: every game, this one included, builds it at the stamp). onPostBuildProposal tells whether emptying
-- worked; if the engine applied it anyway, this game keeps its native build and only the others replay it.
-- Street proposal experiments: which part of a script street proposal does the factory reject? Factories only (no
-- command is sent). Run once per game on the first captured road, before the native apply.
local function streetExperiments(compact, proposal)
	local st = compact.proposal or {}
	local seg = nil
	for _, sg in ipairs(st.addedSegments or {}) do
		if type(sg) == "table" and type(sg.comp) == "table" and sg.comp.roadTemplate then seg = sg; break end
	end
	if not seg then return end
	local c = seg.comp
	local function V(m) return api.type.Vec3f.new(m.x, m.y, m.z) end
	local p0, p1 = c.position0, c.position1
	if not (p0 and p1 and c.tangent0 and c.tangent1) then return end
	local existingEdge = nil
	for _, r in ipairs(st.removedSegments or {}) do
		if type(r) == "table" and type(r.entity) == "number" and r.entity >= 0 then existingEdge = r.entity; break end
	end
	local out = {}
	local function try(name, fn)
		local ok, res = pcall(fn)
		out[#out + 1] = name .. "=" .. (ok and (res and "OK" or "nil") or shortErr(res))
	end
	local factory = api.cmd.makeWorldBuildProposalCmd
	local function nodes(sp, how)
		local n0 = api.type.NodeAndEntity.new()
		n0.entity = -1
		n0.comp.position = V(p0)
		local n1 = api.type.NodeAndEntity.new()
		n1.entity = -2
		n1.comp.position = V(p1)
		if how == "table" then
			sp.streetProposal.nodesToAdd = { n0, n1 }
		else
			sp.streetProposal.nodesToAdd[1] = n0
			sp.streetProposal.nodesToAdd[2] = n1
		end
	end
	local function edge(opts)
		local e = api.type.SegmentAndEntity.new()
		e.entity = opts.eid or -1
		e.comp.node0 = -1
		e.comp.node1 = -2
		e.comp.tangent0 = V(c.tangent0)
		e.comp.tangent1 = V(c.tangent1)
		e.comp.type = 0
		e.comp.typeIndex = -1
		e.type = 0
		if opts.street then e.streetEdge = api.type.BaseEdgeStreet.new() end
		if opts.template then
			e.comp.roadTemplate = c.roadTemplate
			e.comp.roadStyle = c.roadStyle
		end
		if opts.roadType then e.comp.roadType = c.roadType end
		if opts.owner then
			local po = C.newOf("PlayerOwned")
			po.player = api.engine.util.getPlayer()
			e.playerOwned = po
		end
		return e
	end
	local function simple(opts)
		local sp = api.type.SimpleProposal.new()
		nodes(sp, opts.how)
		if opts.edge ~= false then
			local e = edge(opts)
			if opts.how == "table" then sp.streetProposal.edgesToAdd = { e } else sp.streetProposal.edgesToAdd[1] = e end
		end
		return factory(sp, nil, true, false)
	end
	try("empty", function() return factory(api.type.SimpleProposal.new(), nil, true, false) end)
	try("nodesOnly", function() return simple({ edge = false }) end)
	try("nodesOnlyTable", function() return simple({ edge = false, how = "table" }) end)
	try("edgeBare", function() return simple({}) end)
	try("edgeBareId3", function() return simple({ eid = -3 }) end)
	try("edgeStreet", function() return simple({ street = true }) end)
	try("edgeTemplate", function() return simple({ template = true }) end)
	try("edgeStreetTemplate", function() return simple({ street = true, template = true }) end)
	try("edgeStreetTemplateType", function() return simple({ street = true, template = true, roadType = true }) end)
	try("edgeAllOwner", function() return simple({ street = true, template = true, roadType = true, owner = true }) end)
	try("edgeAllTable", function() return simple({ street = true, template = true, roadType = true, how = "table" }) end)
	try("edgeAllIgnoreFalse", function()
		local sp = api.type.SimpleProposal.new()
		nodes(sp)
		sp.streetProposal.edgesToAdd[1] = edge({ street = true, template = true, roadType = true })
		return factory(sp, nil, false, true)
	end)
	if existingEdge then
		try("removeOnly", function()
			local sp = api.type.SimpleProposal.new()
			sp.streetProposal.edgesToRemove[1] = existingEdge
			return factory(sp, nil, true, false)
		end)
		try("replaceSegment", function()
			local P = api.engine.util.proposal.replaceSegment(existingEdge)
			if P == nil then return nil end
			C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== replaceSegment(" .. existingEdge .. ")" .. NL .. C.dump(P):sub(1, 20000) .. NL)
			return factory(P, nil, true, false)
		end)
		try("replaceSegmentWritable", function()
			local P = api.engine.util.proposal.replaceSegment(existingEdge)
			local sg = P.proposal.addedSegments[1]
			sg.comp.tangent0 = V(c.tangent0)
			return factory(P, nil, true, false)
		end)
	end
	try("proposalNew", function() return factory(api.type.Proposal.new(), nil, true, false) end)
	try("segmentsRemoveProposal", function()
		if not existingEdge then return nil end
		return factory(api.engine.util.proposal.makeSegmentsRemoveProposal({ existingEdge }), nil, true, false)
	end)
	log("street experiments: " .. table.concat(out, " ; "))
end

local function captureNativeBuild(state, param)
	local st = state:get() or {}
	local now = gameTime()
	if st.replay and st.replay.at == now and st.replay.n > 0 then
		st.replay.n = st.replay.n - 1     -- our own replay of a shipped action
		state:set(st)
		return
	end
	local proposal, playerInitiated = nil, nil
	pcall(function() proposal, playerInitiated = param[1], param[4] end)
	if proposal == nil or playerInitiated == false then return end
	local c0 = os.clock()
	log("capture: start t=" .. now)
	local okc, compact = pcall(C.compactProposal, proposal)
	log("capture: compact " .. string.format("%.3f", os.clock() - c0) .. " s, " .. #C.ser(compact or {}) .. " bytes")
	if not okc then
		log("native build capture failed at t=" .. now .. ": " .. tostring(compact) .. " (desync)")
		return
	end
	st.rawLogged = (st.rawLogged or 0) + 1
	if st.rawLogged <= 6 then
		C.appendFile(C.DIR .. BS .. "raw_builds.txt", "==== t=" .. now .. NL .. C.dump(proposal):sub(1, 60000) .. NL
			.. "---- compact" .. NL .. C.ser(compact) .. NL)
	end
	local args = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
	local okt, errt = pcall(R.translateOut, "makeWorldBuildProposalCmd", args, reverseOf(st.bind))
	if not okt then log("reference translation failed: " .. tostring(errt)) end
	if false and not st.experimented and #((compact.proposal or {}).addedSegments or {}) > 0 then
		st.experimented = true
		local oke, erre = pcall(streetExperiments, compact, proposal)
		if not oke then log("street experiments failed: " .. tostring(erre)) end
	end
	log("capture: translated " .. string.format("%.3f", os.clock() - c0) .. " s")
	-- self-check: can this build be rebuilt from what is shipped? (factories only, nothing is applied)
	st.selfChecks = (st.selfChecks or 0) + 1
	if false and st.selfChecks <= 12 then
		local oks, errs = pcall(function()
			local margs = C.deser(C.ser(args))
			local missing = R.translateIn(margs, st.bind or {})
			local cmd, label, fails = buildCommand("makeWorldBuildProposalCmd", C.ser(margs), BUILD_TRIES)
			local nObj = #((compact.proposal or {}).edgeObjectsToAdd or {})
			log("self-check build t=" .. now .. " (" .. #(compact.toAdd or {}) .. " construction(s), "
				.. #((compact.proposal or {}).addedSegments or {}) .. " segment(s), " .. nObj .. " stop(s)): "
				.. (cmd and ("replayable as '" .. label .. "'") or "NOT replayable")
				.. (#missing > 0 and (" ; unresolved here: " .. table.concat(missing, ",")) or ""))
			if #fails > 0 then log("  refused: " .. table.concat(fails, " | "):sub(1, 1500)) end
			if #C.errors > 0 then log("  notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
		end)
		if not oks then log("self-check failed: " .. tostring(errs)) end
		if st.selfChecks <= 3 then
			local okn, errn = pcall(function()
				local c2 = api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false)
				log("  probe: the captured native proposal itself " .. (c2 and "OK" or "nil"))
			end)
			if not okn then log("  probe failed: " .. shortErr(errn)) end
		end
	end
	st.out = st.out or {}
	st.outSeq = (st.outSeq or 0) + 1
	-- applied natively here at "now": the other games apply it at the same game time
	log("capture: checked " .. string.format("%.3f", os.clock() - c0) .. " s")
	local hasObjects = #((compact.proposal or {}).edgeObjectsToAdd or {}) > 0
	st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
		fn = "makeWorldBuildProposalCmd", args = args, captured = now, ready = not hasObjects }
	st.lastCapture = hasObjects and { n = st.outSeq, at = now } or nil
	while #st.out > 50 do table.remove(st.out, 1) end
	state:set(st)
end

-- After the native apply of a captured build with stops: read what the engine created (model, position on the edge)
local function enrichAfterBuild(state, param)
	local st = state:get() or {}
	local lc = st.lastCapture
	if not lc or lc.at ~= gameTime() then return end
	st.lastCapture = nil
	local o = nil
	for _, x in ipairs(st.out or {}) do if x.n == lc.n then o = x end end
	if not o then state:set(st); return end
	o.ready = true
	local compact = o.args and o.args[1]
	local list = compact and compact.proposal and compact.proposal.edgeObjectsToAdd or {}
	local EO = api.type.ComponentType.EDGE_OBJECT
	local function edgeObject(e)
		if type(e) ~= "number" or e < 0 then return nil end
		local ok, c = pcall(function() return api.engine.getComponent(e, EO) end)
		return ok and c or nil
	end
	-- candidates: the proposal's own result entities, then every result entity that is an edge object
	local fromProposal, results = {}, {}
	pcall(function()
		local eo = param[1].proposal.edgeObjectsToAdd
		for i = 1, #eo do fromProposal[i] = eo[i].resultEntity end
	end)
	pcall(function()
		local res = param[3]
		for i = 1, #res do
			local e = res[i]
			if type(e) ~= "number" then pcall(function() e = e[1] end) end
			if edgeObject(e) then results[#results + 1] = e end
		end
	end)
	local found = 0
	for i, entry in ipairs(list) do
		local e = edgeObject(fromProposal[i]) and fromProposal[i] or results[i]
		local c = edgeObject(e)
		if c then
			entry.model = c.edgeObjectConstruction
			entry.param = c.param
			entry.params = C.marshal(c.params)
			found = found + 1
			log("stop captured: model=" .. tostring(entry.model) .. " param=" .. tostring(entry.param) .. " left=" .. tostring(entry.left))
		end
	end
	if found < #list then
		log("stop details: " .. found .. "/" .. #list .. " found (proposal ids " .. C.ser(fromProposal) .. ", result edge objects " .. C.ser(results) .. ")")
	end
	state:set(st)
end

local function handleEvent(userParams, state, src, id, name, param)
	if not C.ACTIVE then return end
	if id == "apply_command" and name == "onPostBuildProposal" then
		log("engine: post build t=" .. tostring(gameTime()))
		local ok, err = pcall(enrichAfterBuild, state, param)
		if not ok then log("onPostBuildProposal failed: " .. tostring(err)) end
		return
	end
	if id == "apply_command" and name == "onPreBuildProposal" then
		local ok, err = pcall(captureNativeBuild, state, param)
		if not ok then log("onPreBuildProposal capture failed: " .. tostring(err)) end
		return
	end

	if id ~= "mpfever" then return end
	local ok, err = pcall(function()
		local st = state:get() or {}
		if name == "queue" then
			st.q = st.q or {}
			st.q[#st.q + 1] = param
		elseif name == "pause_at" then
			st.pauseAt = param.at
			st.pausedAt = nil
		elseif name == "resume" then
			st.pauseAt = nil
			st.pausedAt = nil
		elseif name == "bind" then
			st.bind = st.bind or {}
			st.bind[param.key] = param.e
		elseif name == "replaying" then
			st.replay = { at = gameTime(), n = ((st.replay and st.replay.at == gameTime()) and st.replay.n or 0) + 1 }
		elseif name == "auth" then
			for _, o in ipairs(st.authOwn or {}) do
				if o.n == param.n then correctMoney(o.auth, param, param.n, api.cmd.sendCommand) end
			end
		end
		state:set(st)
	end)
	if not ok then log("simulation event " .. tostring(name) .. " failed: " .. tostring(err)) end
end

-- ================================================================== GUI half (persistent, every frame)

local O = {}
local G = {
	inOff = 0, uiOff = 0, frames = 0, started = false, me = C.NAME, connected = false,
	session = { speed = 0, pauseAt = nil, started = false },
	peers = {},                -- other players' clocks (barrier)
	oseq = 0, outSent = 0, lastClock = -1,
	hashSent = -1, resultsSeen = {}, lastSet = -1,
	waits = {}, pendingPaused = {}, holdAt = nil, bind = {}, rev = {},
	ahead = 3, stampFloor = 0,    -- steps ahead of this game's stamps; no stamp below what others were allowed
}

local function send(kind, payload)
	if not C.appendFile(C.DIR .. BS .. "out.log", C.line(kind, payload)) then log("cannot write out.log") end
end

local function readLines(fileName, offKey)
	local f = C.IO.open(C.DIR .. BS .. fileName, "rb")
	if not f then return {} end
	local size = f:seek("end")
	local lines = {}
	if size < G[offKey] then G[offKey] = 0 end
	if size > G[offKey] then
		f:seek("set", G[offKey])
		local chunk = f:read(size - G[offKey]) or ""
		local last, pos = nil, 1
		while true do
			local i = chunk:find(NL, pos, true)
			if not i then break end
			last = i
			local line = chunk:sub(pos, i - 1)
			if line:sub(-1) == CR then line = line:sub(1, -2) end
			if #line > 0 then lines[#lines + 1] = line end
			pos = i + 1
		end
		if last then G[offKey] = G[offKey] + last end
	end
	f:close()
	return lines
end

local function parseLine(line)
	local kind, from, payload = line:match("^([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(.*)$")
	return kind, from, payload
end

local function toSim(name, param)
	O.sendCommand(O.event("mpfever", "mpfever", name, param))
end

local function setSpeed(sp)
	if sp ~= G.lastSet then
		G.lastSet = sp
		O.sendCommand(O.setSpeed(sp))
	end
end

-- queue an action on this game: simulation queue, or applied between steps while the session is paused
-- the game time at which an action issued now is applied everywhere
local function stampFor(t)
	return math.max(t + G.ahead * STEP, G.stampFloor)
end

-- stamp of an action issued while the session is paused: the games may have stopped a batch apart (a speed change
-- takes a frame), so the stamp is the latest of their times; the others catch up to it (pacing) before applying it
local function pausedStamp(now)
	local t = now
	for _, pc in pairs(G.peers) do if type(pc.t) == "number" and pc.t > t then t = pc.t end end
	return t
end

local function queueLocal(a)
	if a.paused then
		G.pendingPaused[#G.pendingPaused + 1] = a
	else
		toSim("queue", a)
	end
end

-- the speed this game may run at: session speed, never past the slowest other player (barrier), stop points
G.pstat = { frames = 0, barrier = 0, hold = 0 }
local function pacing()
	local now = gameTime()
	local s = G.session
	if not s.started then return 0 end
	local stopAt = s.pauseAt
	-- paused, but an action stamped later (another game stopped further): catch up to it, one step at a time
	local catchUp = s.pauseAt ~= nil and G.holdAt ~= nil and G.holdAt > s.pauseAt and now < G.holdAt
	if catchUp then stopAt = G.holdAt
	elseif G.holdAt and (stopAt == nil or G.holdAt < stopAt) then stopAt = G.holdAt end
	local barrier = nil
	for _, pc in pairs(G.peers) do
		-- window (see G.ahead): a game that overshoots this limit by its reserve is still before the time stamped on
		-- the peer's next action
		local limit = pc.t + (G.window or 3) * STEP
		if barrier == nil or limit < barrier then barrier = limit end
	end
	if barrier and (stopAt == nil or barrier < stopAt) then stopAt = barrier end
	local want = s.speed
	if s.pauseAt == nil and G.holdAt then want = math.max(1, want) end
	if catchUp then want = 1 end
	-- statistics (logged with "gui alive"): frames slowed down by the other players' clocks, or by held actions
	local ps = G.pstat
	ps.frames = ps.frames + 1
	local function slowed(r)
		if r < want and s.pauseAt == nil then
			if stopAt == barrier then ps.barrier = ps.barrier + 1 else ps.hold = ps.hold + 1 end
		end
		return r
	end
	G.wantSteps = nil
	if stopAt then
		if now >= stopAt then return slowed(0) end
		-- near a stop point, running at a speed would overshoot it (N steps per frame, a speed change takes a frame):
		-- the game pauses and the engine performs exactly the steps left
		-- (only for real stop points: the barrier keeps a reserve for the overshoot and moves all the time)
		if O.steps and stopAt ~= barrier and stopAt - now <= 2 * math.max(1, want) * STEP then
			G.wantSteps = math.floor((stopAt - now) / STEP)
			return slowed(0)
		end
		if want > 1 and stopAt - now < want * STEP then return slowed(1) end   -- do not overshoot a stop point inside a batch
	end
	return want
end

local H = {}

H.welcome = function(from, p)
	if p.you then G.me = p.you end
	G.connected = true
	log("connected to session as " .. tostring(G.me) .. " (" .. tostring(p.role) .. ")")
end

H.chat = function(from, p) log("chat " .. tostring(from) .. ": " .. tostring(p.text)) end

H.session = function(from, p)
	G.session.started = p.started == true
	G.session.speed = p.speed or 0
	if p.pauseAt ~= G.session.pauseAt then
		G.session.pauseAt = p.pauseAt
		if p.pauseAt then toSim("pause_at", { at = p.pauseAt }) else toSim("resume", {}) end
	end
end

H.peerclock = function(from, p)
	if p.name and p.name ~= G.me then G.peers[p.name] = { t = p.t, ah = p.ah } end
end

H.peerleft = function(from, p)
	if p.name then G.peers[p.name] = nil end
end

-- native builds of other players: replayed here (callbacks give the engine's verdict), as soon as this game has
-- reached their time
G.nativeQueue = {}
local nativeReceived
H.act = function(from, p)
	if p.native then
		G.nativeQueue[#G.nativeQueue + 1] = p
		if nativeReceived then pcall(nativeReceived, p) end
	else
		queueLocal(p)
	end
end

-- Replays of other players' builds: the engine applies a command a frame later (verdict in the callback). Until it
-- has, this game stays where it is (nativeHoldAt): resuming at once would let it run steps before the build lands.
local function replaySend(cmd, cb)
	G.replayOut = (G.replayOut or 0) + 1
	G.replaySince = G.frames
	O.sendCommand(cmd, function(...)
		G.replayOut = math.max(0, (G.replayOut or 1) - 1)
		G.replayQuiet = G.frames + 3   -- room for a follow-up command (next segment, next form)
		if cb then return cb(...) end
	end)
end

-- engine verdicts arrive in callbacks: a refused native replay is retried with the next form, in a fixed order
local REPLAY_FORMS = {
	-- the tool's proposal is already cleaned up: cleaning it again can split a curved segment (one more segment here)
	{ v = "minimal", raw = true, ctx = "terrainNoCleanup" },
	{ v = "minimal", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "plain" },
	{ v = "minimalNoOwner", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "nil" },
	{ v = "minimal", ctx = "terrain" }, { v = "full", raw = true, ctx = "terrain" },
}
if os.getenv("MPFEVER_FORM1") then REPLAY_FORMS[1].ctx = os.getenv("MPFEVER_FORM1") end

-- A pure upgrade (every added segment replaces a removed one between the same nodes, nothing else): the engine's
-- replaceSegment builds it exactly as the upgrade tool does.
local function upgradePlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.removedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- a stop removed with the bulldozer looks like an upgrade, but replaceSegment would keep the stop
	if #(st.edgeObjectsToRemove or {}) > 0 then return nil end
	-- constructions: only town buildings the engine moved for the new street (nobody's, -1); every game's own
	-- replaceSegment moves them the same way (a rebuilt proposal could not make them town buildings again)
	local tAdd, tRem = margs[1].toAdd or {}, margs[1].toRemove or {}
	if #tAdd ~= #tRem then return nil end
	for _, ce in ipairs(tAdd) do
		if ce.playerEntity ~= -1 then return nil end
	end
	local added, removed = st.addedSegments or {}, st.removedSegments or {}
	if #added == 0 or #added ~= #removed then return nil end
	local plan = {}
	for _, ad in ipairs(added) do
		local c = ad.comp or {}
		local match = nil
		for _, rm in ipairs(removed) do
			local rc = rm.comp or {}
			if (rc.node0 == c.node0 and rc.node1 == c.node1) or (rc.node0 == c.node1 and rc.node1 == c.node0) then match = rm.entity end
		end
		if type(match) ~= "number" or match < 0 then return nil end
		plan[#plan + 1] = { edge = match, template = c.roadTemplate }
	end
	return plan
end

local function replayUpgrade(a, plan, i)
	local step = plan[i]
	if not step then return end
	local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(step.edge, step.template) end)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": no proposal " .. tostring(P))
		return replayUpgrade(a, plan, i + 1)
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	toSim("replaying", {})
	replaySend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of segment " .. step.edge .. " to " .. tostring(step.template) .. ": " .. (success and "BUILT" or ("refused " .. why)))
		G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayUpgrade(a, plan, i + 1) end }
	end)
end

-- A pure removal (bulldozer): the engine's own removal proposal
local function removalPlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- buildings demolished with the road (toRemove) are recomputed by every game's own removal proposal
	if #(margs[1].toAdd or {}) > 0 then return nil end
	-- segments the engine merged after the removal are re-added between surviving nodes: the bulldozed segments are
	-- the removed ones touching none of those ends (every game's engine redoes the same merge)
	local ends = {}
	for _, ad in ipairs(st.addedSegments or {}) do
		local c = ad.comp or {}
		if type(c.node0) ~= "number" or c.node0 < 0 or type(c.node1) ~= "number" or c.node1 < 0 then return nil end
		ends[c.node0] = true
		ends[c.node1] = true
	end
	local list = {}
	for _, rm in ipairs(st.removedSegments or {}) do
		if type(rm.entity) ~= "number" or rm.entity < 0 then return nil end
		local c = rm.comp or {}
		if not (ends[c.node0] or ends[c.node1]) then list[#list + 1] = rm.entity end
	end
	if #list == 0 then return nil end
	return list
end

local function engineReplay(a, what, makeP)
	local okp, P = pcall(makeP)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": no proposal " .. tostring(P))
		return
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = true
	ctx.cleanupStreetGraph = true
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	toSim("replaying", {})
	replaySend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " " .. what .. ": " .. (success and "BUILT" or ("refused " .. why)))
	end)
end

-- A stop placed on an existing street (the stop tool): rebuilt as the street tool would, from this game's segment
local function sVec(q) return api.type.Vec3f.new(q.x, q.y, q.z) end
local function sNodePos(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and { x = c.position.x, y = c.position.y, z = c.position.z } or nil
end
local function sContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = true
	c.gatherBuildings = false
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

local function stopPlan(margs)
	local st = margs[1].proposal
	if #(st.addedNodes or {}) > 0 or #(st.addedSegments or {}) ~= 1 or #(st.removedSegments or {}) ~= 1 then
		return nil, "not a single segment replacement"
	end
	local ad, rm = st.addedSegments[1], st.removedSegments[1]
	local E = rm.entity
	if type(E) ~= "number" or E < 0 then return nil, "segment unresolved" end
	local objs = {}
	for i, o in ipairs(st.edgeObjectsToAdd or {}) do
		if type(o.model) ~= "string" then return nil, "stop " .. i .. " without model" end
		objs[#objs + 1] = o
	end
	-- removed stops (bulldozer): their ids differ between games, their rank on the segment does not
	local gone, removeIdx = {}, {}
	for _, id in ipairs(st.edgeObjectsToRemove or {}) do gone[id] = true end
	for k, o in ipairs((rm.comp or {}).objects or {}) do
		if type(o) == "table" and gone[o[1]] then removeIdx[k] = true end
	end
	return { E = E, seg = ad, objs = objs, removeIdx = removeIdx, nodeConfigs = st.nodeConfigsToAdd or {} }
end

local function replayStop(a, plan)
	local c = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
	if not c then log("NATIVE REPLAY " .. tostring(a.uid) .. ": stop segment missing"); return end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = 0
	local cc = e.comp
	local sc = plan.seg.comp or {}
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = sVec(c.tangent0); cc.tangent1 = sVec(c.tangent1)
	cc.position0 = sVec(sNodePos(c.node0)); cc.position1 = sVec(sNodePos(c.node1))
	cc.type = 0; cc.typeIndex = -1
	cc.roadTemplate = sc.roadTemplate or c.roadTemplate
	cc.roadStyle = sc.roadStyle or c.roadStyle
	cc.roadType = c.roadType
	-- lanes as the stop tool computed them: on a street without sidewalks it adds the platform lanes, without which
	-- the engine accepts the build but silently drops the stop
	local capLanes = sc.laneConfigs
	if type(capLanes) == "table" and #capLanes > 0 then
		cc.laneConfigs = C.rebuildLanes(capLanes)
	else
		cc.laneConfigs = c.laneConfigs
	end
	-- objects: the stops already on this segment, then the new ones (placeholders, side)
	local list, removeIds = {}, {}
	for i = 1, #c.objects do
		if plan.removeIdx and plan.removeIdx[i] then removeIds[#removeIds + 1] = c.objects[i][1]
		else list[#list + 1] = { c.objects[i][1], c.objects[i][2] } end
	end
	for k, o in ipairs(plan.objs) do list[#list + 1] = { -400000000 - (k - 1), o.left and 0 or 1 } end
	cc.objects = list
	e.comp = cc
	local se = e.streetEdge
	se.precedenceNode0 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode0) or 2
	se.precedenceNode1 = (plan.seg.streetEdge and plan.seg.streetEdge.precedenceNode1) or 2
	e.streetEdge = se
	local eos = {}
	for k, o in ipairs(plan.objs) do
		local eo = api.type.SimpleStreetProposal.EdgeObject.new()
		eo.edgeEntity = -1
		eo.param = o.param or 0.5
		eo.oneWay = o.oneWay == true
		eo.left = o.left == true
		eo.model = (o.model:gsub("^::/", ""))
		eo.playerEntity = api.engine.util.getPlayer()
		pcall(function() eo.name = o.name or "" end)
		eos[k] = eo
	end
	local ncr = {}
	for _, n in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = n end
	end
	ssp.edgesToRemove = { plan.E }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = eos
	if #removeIds > 0 then ssp.edgeObjectsToRemove = removeIds end
	if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
	sp.streetProposal = ssp
	local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, sContext(), false, true) end)
	if not okf or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: factory " .. shortErr(cmd))
		return
	end
	local function stopCount()
		local n = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
		return n
	end
	local before = stopCount()
	toSim("replaying", {})
	replaySend(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop on segment " .. plan.E .. ": " .. (success and "BUILT" or ("refused " .. why)))
		if success then
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local after = stopCount()
				local expected = before + #plan.objs - #removeIds
			log("NATIVE REPLAY " .. tostring(a.uid) .. " stops on the map " .. before .. " -> " .. after .. ((after == expected) and "" or (" (EXPECTED " .. expected .. ")")))
			end }
		end
	end)
end

local function replayNative(a, formIndex)
	if formIndex == 1 then
		pcall(function()
			local m = a.args[1]
			local st = m.proposal or {}
			log("NATIVE REPLAY " .. tostring(a.uid) .. " shape: +nodes " .. #(st.addedNodes or {}) .. " -nodes " .. #(st.removedNodes or {})
				.. " +segments " .. #(st.addedSegments or {}) .. " -segments " .. #(st.removedSegments or {}) .. " stops " .. #(st.edgeObjectsToAdd or {})
				.. " +constructions " .. #(m.toAdd or {}) .. " -constructions " .. #(m.toRemove or {}))
		end)
		local probe = C.deser(C.ser(a.args))
		local missing = R.translateIn(probe, G.bind)
		local plan = (#missing == 0) and upgradePlan(probe) or nil
		if plan then return replayUpgrade(a, plan, 1) end
		-- stops: the stop tool replaces one existing segment between the same nodes and adds edge objects
		local stp = probe[1] and probe[1].proposal
		if stp and (#(stp.edgeObjectsToAdd or {}) > 0 or #(stp.edgeObjectsToRemove or {}) > 0) then
			if #missing > 0 then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " (stop) SKIPPED, unresolved: " .. table.concat(missing, ","))
				return
			end
			local okp, plan = pcall(function() return stopPlan(probe) end)
			if okp and plan then return replayStop(a, plan) end
			log("NATIVE REPLAY " .. tostring(a.uid) .. ": stop not replicable (" .. tostring(plan) .. ")")
			return
		end
		local removal = (#missing == 0) and removalPlan(probe) or nil
		if removal then
			return engineReplay(a, "removal of " .. table.concat(removal, ","), function()
				return api.engine.util.proposal.makeSegmentsRemoveProposal(removal)
			end)
		end
	end
	local form = REPLAY_FORMS[formIndex]
	if not form then
		log("NATIVE REPLAY " .. tostring(a.uid) .. ": every form refused (desync)")
		return
	end
	local margs = C.deser(C.ser(a.args))
	local missing = R.translateIn(margs, G.bind)
	if #missing > 0 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " SKIPPED, unresolved: " .. table.concat(missing, ","))
		return
	end
	if form.ie ~= nil then margs[3] = form.ie end
	if form.pi ~= nil then margs[4] = form.pi end
	local okr, args, n = pcall(C.rebuildArgs, a.fn, margs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw })
	local label = form.v .. (form.raw and "/raw" or "") .. "/" .. form.ctx .. (form.ie and "/ie" or "") .. (form.pi == false and "/pi0" or "")
	if not okr then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": rebuild " .. shortErr(args))
		return replayNative(a, formIndex + 1)
	end
	local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
	if not okc or not cmd then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": factory " .. shortErr(cmd))
		return replayNative(a, formIndex + 1)
	end
	toSim("replaying", {})
	local expected = nil
	pcall(function()
		local st = a.args[1].proposal
		expected = #(st.addedSegments or {}) - #(st.removedSegments or {})
	end)
	local edgesBefore = #R.allEdges()
	replaySend(cmd, function(res, success)
		if success then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " BUILT with form " .. label)
			pcall(function()
				local st = res.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes
					.. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments)
				if expected and #st.addedSegments - #st.removedSegments ~= expected then
					local d = {}
					for i = 1, #st.addedNodes do
						local q = st.addedNodes[i].comp.position
						d[#d + 1] = "node " .. st.addedNodes[i].entity .. string.format(" (%.1f %.1f %.1f)", q.x, q.y, q.z)
					end
					for i = 1, #st.addedSegments do
						local s = st.addedSegments[i]
						d[#d + 1] = "seg " .. s.entity .. " " .. s.comp.node0 .. "-" .. s.comp.node1 .. " " .. tostring(s.comp.roadTemplate):match("[^/]+$")
					end
					for i = 1, #st.removedSegments do d[#d + 1] = "rm " .. st.removedSegments[i].entity end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " engine detail: " .. table.concat(d, "; "))
					local o = {}
					local ost = a.args[1].proposal
					for _, n in ipairs(ost.addedNodes or {}) do
						local q = n.comp and n.comp.position or {}
						o[#o + 1] = "node " .. tostring(n.entity) .. string.format(" (%.1f %.1f %.1f)", q.x or 0, q.y or 0, q.z or 0)
					end
					for _, s in ipairs(ost.addedSegments or {}) do
						o[#o + 1] = "seg " .. tostring(s.entity) .. " " .. C.ser(s.comp.node0) .. "-" .. C.ser(s.comp.node1)
					end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " originator detail: " .. table.concat(o, "; "))
				end
			end)
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function()
				local got = #R.allEdges() - edgesBefore
				if expected and got ~= expected then
					log("NATIVE REPLAY " .. tostring(a.uid) .. " SEGMENT COUNT DIFFERS: originator " .. expected .. ", here " .. got)
				end
			end }
		else
			local why = ""
			pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
			log("NATIVE REPLAY " .. tostring(a.uid) .. " form " .. label .. ": refused " .. why)
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayNative(a, formIndex + 1) end }
		end
	end)
end

-- ================================================================== native deferral (with mpfever_native.dll)
-- The DLL holds a build issued by a UI tool and reports it in native_events.log. This game announces it to the others
-- (nat_pending: "a build of mine happens at T"), every game holds at T, this game releases the held command at T (its
-- simulation applies it then, the capture ships it), the others apply it while held at T: same step everywhere.
G.natOff = 0
G.natRelease = {}       -- this game's held builds: { id, at }
G.natWait = {}          -- builds announced by others: { origin, at, since }
G.natReleased = 0
G.natEnabled = false

local function nativeCtl(line)
	C.appendFile(C.DIR .. BS .. "native_ctl.txt", line .. NL)
end

local function nativeHoldAt()
	local m = nil
	for _, r in ipairs(G.natRelease) do if m == nil or r.at < m then m = r.at end end
	for _, w in ipairs(G.natWait) do if m == nil or w.at < m then m = w.at end end
	-- other players' builds already received: this game must stop exactly at their time
	local now = gameTime()
	if (G.replayOut or 0) > 0 and G.frames - (G.replaySince or 0) > 600 then
		log("replay without engine answer for 600 frames: hold released")
		G.replayOut = 0
	end
	if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) then return now end
	for _, a in ipairs(G.nativeQueue or {}) do if a.at > now and (m == nil or a.at < m) then m = a.at end end
	return m
end

H.nat_pending = function(from, p)
	if p.origin == G.me then return end
	G.natWait[#G.natWait + 1] = { origin = p.origin, id = p.id, at = p.at, since = G.frames }
	log("native build of " .. tostring(p.origin) .. " announced for t=" .. tostring(p.at) .. ": holding there")
end

local function pollNativeEvents()
	for _, line in ipairs(readLines("native_events.log", "natOff")) do
		local id = tonumber(line:match("^deferred (%d+)"))
		if id then
			local now = gameTime()
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt
			local at = paused and pausedStamp(now) or (stampFor(now) + STEP)
			G.natRelease[#G.natRelease + 1] = { id = id, at = at }
			send("nat_pending", { origin = G.me, at = at, id = id })
			log("native build " .. id .. " held by the DLL, released at t=" .. at .. " (now " .. now .. ")")
		end
	end
end

-- autotest: a scripted build follows the tools' path (announced, every game holds at its time, then it is sent)
G.autoBuildSeq = 0
local function deferredSend(cmd, cb)
	local now = gameTime()
	G.autoBuildSeq = G.autoBuildSeq + 1
	local id = 100000 + G.autoBuildSeq
	local at = stampFor(now) + STEP
	G.natRelease[#G.natRelease + 1] = { id = id, at = at, fn = function() O.sendCommand(cmd, cb) end }
	send("nat_pending", { origin = G.me, at = at, id = id })
end

local function runNativeRelease()
	if #G.natRelease == 0 then return end
	local now = gameTime()
	local keep = {}
	for _, r in ipairs(G.natRelease) do
		if now >= r.at and gameSpeed() == 0 then
			G.natReleased = G.natReleased + 1
			G.natShipIds = G.natShipIds or {}
			G.natShipIds[#G.natShipIds + 1] = r.id
			if r.fn then
				-- a scripted build (autotest) deferred like the tools' ones: sent now, at its announced time
				G.natReleased = G.natReleased - 1
				pcall(r.fn)
			else
				nativeCtl("release " .. G.natReleased)
				-- any command reaching CommandList::Add lets the DLL release the held build just before it
				O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
			end
			log("native build " .. r.id .. " released at t=" .. now .. (now > r.at and (" (" .. ((now - r.at) / STEP) .. " step(s) late)") or ""))
		else
			keep[#keep + 1] = r
		end
	end
	G.natRelease = keep
end

local function expireNativeWaits()
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if not w.arrived and G.frames - w.since > 1800 then
			log("NATIVE build of " .. tostring(w.origin) .. " for t=" .. tostring(w.at) .. " never arrived: no longer holding (desync risk)")
		else
			keep[#keep + 1] = w
		end
	end
	G.natWait = keep
end

local function matchesWait(w, a)
	if w.origin ~= a.origin then return false end
	if a.natId ~= nil and w.id ~= nil then return w.id == a.natId end
	return w.at == a.at
end

-- the data of an announced build is here: hold at its real time (the capture may come a step after the announce)
nativeReceived = function(a)
	for _, w in ipairs(G.natWait) do
		if matchesWait(w, a) then w.at = a.at; w.arrived = true end
	end
end

local function nativeArrived(a)
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if not matchesWait(w, a) then keep[#keep + 1] = w end
	end
	G.natWait = keep
end

local function runNativeReplays()
	if #G.nativeQueue == 0 then return end
	local now = gameTime()
	table.sort(G.nativeQueue, before)
	local keep = {}
	for _, a in ipairs(G.nativeQueue) do
		if a.at <= now then
			if a.at < now then log("LATE native build " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)") end
			nativeArrived(a)
			local okr, errr = pcall(replayNative, a, 1)
			if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " failed: " .. tostring(errr)) end
		else
			keep[#keep + 1] = a
		end
	end
	G.nativeQueue = keep
end

H.hash = function(from, p)
	if p.paused then
		G.pendingPaused[#G.pendingPaused + 1] = { kind = "hash", n = p.n, at = p.at, origin = "", oseq = -1 }
	else
		toSim("queue", { kind = "hash", n = p.n, at = p.at, origin = "", oseq = -1 })
	end
end

-- host authority: the host's values at checkpoint n (only the other games correct themselves)
H.auth = function(from, p)
	if C.ROLE == "host" or type(p.n) ~= "number" then return end
	local own = G.authOwn and G.authOwn[p.n]
	if own then
		-- checkpoint taken while paused, here in the GUI half
		local ok, err = pcall(correctMoney, own, p, p.n, O.sendCommand)
		if not ok then log("money correction failed: " .. tostring(err)) end
	else
		toSim("auth", p)
	end
end

-- ---------------------------------------------------------------- resynchronisation by the host's savegame
-- resync_save (host): save the paused game; resync_load (others): load the host's savegame received by the launcher.
-- Handled here when the application functions are reachable from this state, otherwise by the UI hook (which waits
-- for a claim in resync_claims.txt before acting, so that only one of them does it).
local function claimResync(kind, id)
	if type(app) ~= "table" or not app.saveGame then return false end
	local f = C.IO.open(C.DIR .. BS .. "resync_claims.txt", "rb")
	local claims = f and (f:read("*a") or "") or ""
	if f then f:close() end
	local key = kind .. " " .. tostring(id) .. NL
	if claims:find(key, 1, true) then return false end
	C.appendFile(C.DIR .. BS .. "resync_claims.txt", key)
	return true
end

H.resync_save = function(from, p)
	if not claimResync("resync_save", p.id) then return end
	log("resynchronisation: saving the game as '" .. tostring(p.name) .. "' at t=" .. tostring(gameTime()))
	local ok, err = pcall(app.saveGame, p.name, function()
		log("resynchronisation: game saved")
		send("save_done", { id = p.id, name = p.name, ok = true, t = gameTime() })
	end, false, true)
	if not ok then
		log("resynchronisation: save failed: " .. tostring(err))
		send("save_done", { id = p.id, name = p.name, ok = false, err = tostring(err) })
	end
end

H.resync_load = function(from, p)
	if not claimResync("resync_load", p.id) then return end
	local ns = app.SaveGameNamespace.getSavegame()
	local id = nil
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == p.name then
			id = api.type.SavegameId.new()
			id.path = s.path
			id.saveGameName = s.saveName
			id.saveGameNamespace = ns
		end
	end
	if not id then log("resynchronisation: savegame '" .. tostring(p.name) .. "' not found"); return end
	C.appendFile(C.DIR .. BS .. "resync_pending.txt", "1")
	log("resynchronisation: loading the host's game '" .. tostring(p.name) .. "'")
	app.loadGame(id, false)
end

H.det_run = function(from, p)
	local round, steps = p.round, p.steps or 0
	setSpeed(0)
	local target = gameTime() + steps * STEP
	if steps > 0 and O.steps then O.sendCommand(O.steps(steps)) end
	local stable, deadline = 0, G.frames + 60 * 300
	local function poll()
		local t = gameTime()
		if t >= target then stable = stable + 1 else stable = 0 end
		if stable >= 5 or G.frames > deadline then
			local parts = simHash()
			parts.reached = (t >= target)
			send("det_hash", { round = round, steps = steps, parts = parts })
		else
			G.waits[#G.waits + 1] = { at = G.frames + 1, fn = poll }
		end
	end
	G.waits[#G.waits + 1] = { at = G.frames + 10, fn = poll }
end

-- commands held by the UI hook: stamp them (two steps ahead, or at the pause point) and ship them
local function stampHeld()
	for _, line in ipairs(readLines("ui.log", "uiOff")) do
		local kind, _, payload = parseLine(line)
		local p = payload and C.deser(payload)
		if p and kind == "act_req" then
			local now = gameTime()
			G.oseq = G.oseq + 1
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt and gameSpeed() == 0
			local a = { tok = p.tok, id = p.id, fn = p.fn, args = p.args, origin = G.me, oseq = G.oseq,
				uid = G.me .. ":" .. G.oseq, at = paused and pausedStamp(now) or stampFor(now), paused = paused or nil }
			send("act", a)
			queueLocal(a)
		elseif p and (kind == "speed_req" or kind == "act_fail" or kind == "save_done") then
			send(kind, p)
		end
	end
end

-- native builds captured by the simulation half: ship them with their exact time
local function enrichEdgeObjects(compact)
	local st = compact and compact.proposal
	if type(st) ~= "table" or #(st.edgeObjectsToAdd or {}) == 0 then return end
	for _, seg in ipairs(st.addedSegments or {}) do
		local c = seg.comp or {}
		local objs = c.objects or {}
		if #objs > 0 and c.position0 and c.position1 then
			local edge = R.resolve({ k = "edge", id = -1, p0 = { x = c.position0.x, y = c.position0.y, z = c.position0.z },
				p1 = { x = c.position1.x, y = c.position1.y, z = c.position1.z } }, {})
			local be = edge and api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
			if be then
				for _, pair in ipairs(objs) do
					local placeholder, side = pair[1], pair[2]
					local idx = -(placeholder + 400000000) + 1
					local entry = st.edgeObjectsToAdd[idx]
					if entry then
						for i = 1, #be.objects do
							if be.objects[i][2] == side then
								local eo = api.engine.getComponent(be.objects[i][1], api.type.ComponentType.EDGE_OBJECT)
								if eo then
									entry.param = eo.param
									entry.model = eo.edgeObjectConstruction
									entry.params = C.marshal(eo.params)
								end
							end
						end
					end
				end
			else
				log("edge object enrichment: new edge not found")
			end
		end
	end
end

local function needsEnrich(compact)
	for _, e in ipairs(((compact or {}).proposal or {}).edgeObjectsToAdd or {}) do
		if type(e) == "table" and e.model == nil then return true end
	end
	return false
end

local function shipNativeBuilds(st)
	G.outFirstSeen = G.outFirstSeen or {}
	for _, o in ipairs(st.out or {}) do
		if o.n > G.outSent then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			if o.ready == false and G.frames - G.outFirstSeen[o.n] < 30 then return end
			G.outSent = o.n
			G.oseq = G.oseq + 1
			if needsEnrich(o.args and o.args[1]) then
				local oke, erre = pcall(enrichEdgeObjects, o.args and o.args[1])
				if not oke then log("edge object enrichment failed: " .. tostring(erre)) end
			end
			local a = { fn = o.fn, args = o.args, at = o.at, origin = G.me, oseq = G.oseq, uid = G.me .. ":" .. G.oseq,
				native = true, paused = o.paused }
			if G.natShipIds and #G.natShipIds > 0 then a.natId = table.remove(G.natShipIds, 1) end
			send("act", a)
			log("native build shipped " .. a.uid .. " (built here at t=" .. o.at .. ", the other games build it at the same time)")
		end
	end
end

local function runPausedActions()
	local natAt = nativeHoldAt()
	if #G.pendingPaused == 0 and natAt == nil then
		if G.holdAt then
			G.holdAt = nil
			if not G.session.pauseAt then toSim("resume", {}) end
		end
		return
	end
	local now = gameTime()
	local minAt = natAt
	for _, a in ipairs(G.pendingPaused) do
		if a.at > now and (minAt == nil or a.at < minAt) then minAt = a.at end
	end
	if minAt and G.holdAt ~= minAt then
		G.holdAt = minAt
		toSim("pause_at", { at = minAt })
	end
	if gameSpeed() ~= 0 then return end
	local keep = {}
	table.sort(G.pendingPaused, before)
	for _, a in ipairs(G.pendingPaused) do
		if a.at <= now then
			if a.at < now then log("paused action " .. tostring(a.uid) .. " for t=" .. tostring(a.at) .. " applied at " .. now .. " (desync risk)") end
			if a.kind == "hash" then
				local okA, auth = pcall(authValues)
				G.authOwn = G.authOwn or {}
				G.authOwn[a.n] = okA and auth or nil
				send("sync_hash", { n = a.n, parts = simHash(), cost = 0, auth = okA and auth or nil })
			else
				toSim("replaying", {})
				-- paused: the engine answers in a callback, a frame later; the result is reported then
				executeAction(a, O.sendCommand, true, G.bind, function(r)
					r.at = now
					r.answered, r.returned = nil, nil
					log("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t=" .. tostring(now) .. " -> " .. (r.success and "OK" or "REFUSED"))
					if r.created then G.bind[r.created.key] = r.created.e; G.rev[r.created.e] = r.created.key; toSim("bind", r.created) end
					G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true
					C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
					if r.created then C.appendFile(C.DIR .. BS .. "bindings.log", r.created.key .. " " .. tostring(r.created.e) .. NL) end
					if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
				end)
			end
		else
			keep[#keep + 1] = a
		end
	end
	G.pendingPaused = keep
end

-- ================================================================== autotest scenario (MPFever.exe --autotest)
-- Builds like a player would (playerInitiated commands, the path the native tools take): a road from a dead end, a
-- second road from the new node, a bus stop on the second road. The other games must replicate everything.

local AUTO = { running = false, results = {}, points = {} }
local STOP_MODEL = "stations/street/small_stops/small_old.con"

local function vec(p) return api.type.Vec3f.new(p.x, p.y, p.z) end
local function pos3(v) return { x = v.x, y = v.y, z = v.z } end

local function groundZ(x, y, fallback)
	local z = nil
	pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(x, y)) end)
	if type(z) ~= "number" then pcall(function() z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end) end
	return type(z) == "number" and z or fallback
end

-- dead ends of the street network, in a deterministic order (same save = same ids for these)
local function deadEnds()
	local list, edgeOf = {}, {}
	for n, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap() or {}) do
		local k = 0
		pcall(function() k = #segs end)
		if k == 1 then
			local e = segs[1]
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c and c.type == 0 and c.roadTemplate and c.roadTemplate ~= "" then
				list[#list + 1] = n
				edgeOf[n] = { e = e, other = (c.node0 == n) and c.node1 or c.node0, c = c }
			end
		end
	end
	table.sort(list)
	return list, edgeOf
end

local function nodePosition(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and pos3(c.position) or nil
end

local function roadProposal(fromNode, fromPos, toPos, tmpl)
	local sp = api.type.SimpleProposal.new()
	local n = api.type.NodeAndEntity.new()
	n.entity = -1
	n.comp.position = vec(toPos)
	sp.streetProposal.nodesToAdd[1] = n
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.comp.node0 = fromNode
	e.comp.node1 = -1
	local t = { x = toPos.x - fromPos.x, y = toPos.y - fromPos.y, z = toPos.z - fromPos.z }
	e.comp.tangent0 = vec(t)
	e.comp.tangent1 = vec(t)
	e.comp.type = 0
	e.comp.typeIndex = -1
	e.type = 0
	e.streetEdge = api.type.BaseEdgeStreet.new()
	e.comp.roadTemplate = tmpl.roadTemplate
	e.comp.roadStyle = tmpl.roadStyle
	e.comp.roadType = tmpl.roadType
	local po = C.newOf("PlayerOwned")
	po.player = api.engine.util.getPlayer()
	e.playerOwned = po
	sp.streetProposal.edgesToAdd[1] = e
	return sp
end

local function stopProposal(edge)
	local c = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	sp.streetProposal.edgesToRemove[1] = edge
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.comp.node0 = c.node0
	e.comp.node1 = c.node1
	e.comp.tangent0 = vec(c.tangent0)
	e.comp.tangent1 = vec(c.tangent1)
	e.comp.type = 0
	e.comp.typeIndex = -1
	e.type = 0
	e.streetEdge = api.type.BaseEdgeStreet.new()
	e.comp.roadTemplate = c.roadTemplate
	e.comp.roadStyle = c.roadStyle
	e.comp.roadType = c.roadType
	local po = C.newOf("PlayerOwned")
	po.player = api.engine.util.getPlayer()
	e.playerOwned = po
	sp.streetProposal.edgesToAdd[1] = e
	local eo = api.type.SimpleStreetProposal.EdgeObject.new()
	eo.edgeEntity = -1
	eo.param = 0.5
	eo.oneWay = false
	eo.left = true
	eo.model = STOP_MODEL
	eo.playerEntity = api.engine.util.getPlayer()
	eo.name = "MPF " .. C.ROLE
	sp.streetProposal.edgeObjectsToAdd[1] = eo
	return sp
end

local function autoStep(name, makeProposal, after)
	local okp, sp = pcall(makeProposal)
	if not okp or not sp then
		AUTO.results[#AUTO.results + 1] = name .. ": proposal error " .. tostring(sp)
		log("AUTOTEST " .. name .. ": proposal error " .. tostring(sp))
		return after(false)
	end
	local okc, err = pcall(function()
		deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, nil, false, true), function(res, success)
			AUTO.results[#AUTO.results + 1] = name .. ": " .. (success and "built" or "refused by the engine")
			log("AUTOTEST " .. name .. ": " .. (success and "built" or "refused by the engine"))
			G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function() after(success) end }
		end)
	end)
	if not okc then
		AUTO.results[#AUTO.results + 1] = name .. ": command error " .. tostring(err)
		log("AUTOTEST " .. name .. ": command error " .. tostring(err))
		after(false)
	end
end

local function autoFinish()
	AUTO.running = false
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(AUTO.points) do G.autoPoints[#G.autoPoints + 1] = q end
	send("autotest_done", { role = C.ROLE, results = AUTO.results, points = AUTO.points })
end

local function runScenario(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ends, edgeOf = deadEnds()
	log("AUTOTEST start (" .. C.ROLE .. "): " .. #ends .. " dead ends")
	local candidate = (p.offset or 0)
	local function tryCandidate(attempt)
		if attempt > 12 then
			AUTO.results[#AUTO.results + 1] = "no free place for a road"
			return autoFinish()
		end
		candidate = candidate + 1
		local n = ends[(candidate * 37) % #ends + 1]
		local info = edgeOf[n]
		local pn, po = nodePosition(n), nodePosition(info.other)
		local dx, dy = pn.x - po.x, pn.y - po.y
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 1 then return tryCandidate(attempt + 1) end
		dx, dy = dx / len, dy / len
		local a = { x = pn.x + dx * 60, y = pn.y + dy * 60 }
		a.z = groundZ(a.x, a.y, pn.z)
		local b = { x = a.x + dx * 60, y = a.y + dy * 60 }
		b.z = groundZ(b.x, b.y, a.z)
		local tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType }
		autoStep("road 1 from dead end " .. n, function() return roadProposal(n, pn, a, tmpl) end, function(ok)
			if not ok then return tryCandidate(attempt + 1) end
			AUTO.points[#AUTO.points + 1] = pn
			local na = R.resolve({ k = "node", id = -1, p = a }, {})
			if not na then
				AUTO.results[#AUTO.results + 1] = "new node A not found"
				return autoFinish()
			end
			local pa = nodePosition(na)
			autoStep("road 2 from the new node", function() return roadProposal(na, pa, b, tmpl) end, function(ok2)
				if not ok2 then return autoFinish() end
				local edge = R.resolve({ k = "edge", id = -1, p0 = pa, p1 = b }, {})
				if not edge then
					AUTO.results[#AUTO.results + 1] = "new edge A-B not found"
					return autoFinish()
				end
				autoStep("bus stop on road 2", function() return stopProposal(edge) end, function() autoFinish() end)
			end)
		end)
	end
	tryCandidate(1)
end

-- Street proposal matrix: every sub-object is read, changed and written back (properties return COPIES), the result is
-- read back to check what the proposal really holds, the factory is tried, and the first accepted form is really built
-- to see whether a road appears.
local function edgeCount() return #R.allEdges() end

local function buildMatrixProposal(o, n, pn, a)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local nodeId = -1
	local edgeId = o.sharedIds and -2 or -1
	local ne = api.type.NodeAndEntity.new()
	ne.entity = nodeId
	local bn = ne.comp
	bn.position = vec(a)
	ne.comp = bn
	local list = {}
	if not o.noEdge then
		local e = api.type.SegmentAndEntity.new()
		e.entity = edgeId
		e.type = 0
		local c = e.comp
		if o.tlanes then
			local lanes = C.templateLanes(o.tmpl.roadTemplate)
			if not lanes then error("no template lanes for " .. tostring(o.tmpl.roadTemplate)) end
			c.laneConfigs = lanes
		elseif o.lanesWire then
			local src = api.engine.getComponent(o.cloneOf, api.type.ComponentType.BASE_EDGE)
			local wire = C.deser(C.ser(C.marshal(src.laneConfigs)))
			c.laneConfigs = C.rebuildLanes(wire)
		elseif o.lanes then
			local src = api.engine.getComponent(o.cloneOf, api.type.ComponentType.BASE_EDGE)
			c.laneConfigs = src.laneConfigs
			if o.decor then c.edgeDecorations = src.edgeDecorations end
			if o.dist then c.distance = src.distance end
		end
		c.node0 = n
		c.node1 = nodeId
		local t = { x = a.x - pn.x, y = a.y - pn.y, z = a.z - pn.z }
		c.tangent0 = vec(t)
		c.tangent1 = vec(t)
		c.type = 0
		c.typeIndex = -1
		if o.positions then
			c.position0 = vec(pn)
			c.position1 = vec(a)
		end
		if o.template then
			c.roadTemplate = o.tmpl.roadTemplate
			c.roadStyle = o.tmpl.roadStyle
		end
		if o.roadType then c.roadType = o.tmpl.roadType end
		e.comp = c
		if o.street then
			local se = e.streetEdge
			se.precedenceNode0 = 2
			se.precedenceNode1 = 2
			e.streetEdge = se
		end
		if o.owner then
			local po = e.playerOwned
			if po == nil then po = C.newOf("PlayerOwned") end
			po.player = api.engine.util.getPlayer()
			e.playerOwned = po
		end
		list[1] = e
	end
	if o.stop and #list > 0 then
		local sc = list[1].comp
		sc.objects = { { -400000000, o.stopLeft and 0 or 1 } }
		list[1].comp = sc
	end
	ssp.nodesToAdd = { ne }
	if #list > 0 then ssp.edgesToAdd = list end
	if o.stop then
		local so = api.type.SimpleStreetProposal.EdgeObject.new()
		so.edgeEntity = o.stopEdge
		so.param = 0.5
		so.oneWay = false
		so.left = false
		so.model = o.stop
		if o.stopNoOwner then so.playerEntity = -1 else so.playerEntity = api.engine.util.getPlayer() end
		if o.stopLeft then so.left = true end
		so.name = "MPF stop"
		ssp.edgeObjectsToAdd = { so }
	end
	sp.streetProposal = ssp
	return sp
end

local function readBack(sp)
	local out = {}
	pcall(function()
		local ssp = sp.streetProposal
		out[#out + 1] = "nodes=" .. #ssp.nodesToAdd .. " edges=" .. #ssp.edgesToAdd
		if #ssp.edgesToAdd > 0 then
			local e = ssp.edgesToAdd[1]
			out[#out + 1] = "edge id=" .. tostring(e.entity) .. " n0=" .. tostring(e.comp.node0) .. " n1=" .. tostring(e.comp.node1)
				.. " tmpl=" .. tostring(e.comp.roadTemplate) .. " type=" .. tostring(e.type)
		end
	end)
	return table.concat(out, " ")
end

local MATRIX = {
	{ name = "tlShared", tlanes = true, template = true, roadType = true, street = true, owner = true, sharedIds = true },
	{ name = "tlPosShared", tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true },
}

local function matrixPlace(k)
	local ends, edgeOf = deadEnds()
	local n = ends[(k * 37) % #ends + 1]
	local info = edgeOf[n]
	local pn, po = nodePosition(n), nodePosition(info.other)
	local dx, dy = pn.x - po.x, pn.y - po.y
	local len = math.sqrt(dx * dx + dy * dy)
	dx, dy = dx / len, dy / len
	local a = { x = pn.x + dx * 40, y = pn.y + dy * 40 }
	a.z = groundZ(a.x, a.y, pn.z)
	return n, info, pn, a
end

local function runMatrix(done)
	local n, info, pn, a = matrixPlace(3)
	local tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType }
	local accepted = {}
	pcall(function()
		local forms = {
			zeroBased = function() local t = {}; for j = 0, 15 do t[j] = (j == 1 or j == 2) end; return t end,
			oneBased = function() local t = {}; for j = 1, 16 do t[j] = (j == 2 or j == 3) end; return t end,
		}
		for name, mk in pairs(forms) do
			local lc = api.type.LaneConfig.new()
			local okA, errA = pcall(function() lc.transportModes = mk() end)
			local okE = pcall(function() local tm = lc.transportModes; tm[1] = true; tm[2] = true; lc.transportModes = tm end)
			log("MATRIX transportModes " .. name .. ": assign=" .. tostring(okA) .. " readback=" .. C.ser(C.marshal(lc.transportModes)) .. " " .. tostring(errA))
		end
		local lc = api.type.LaneConfig.new()
		log("MATRIX fresh LaneConfig transportModes=" .. C.ser(C.marshal(lc.transportModes)) .. " raw type=" .. type(lc.transportModes))
	end)
	pcall(function()
		local src = api.engine.getComponent(info.e, api.type.ComponentType.BASE_EDGE)
		log("MATRIX source edge: lanes=" .. tostring(#src.laneConfigs) .. " wire=" .. C.ser(C.marshal(src.laneConfigs)):sub(1, 300))
	end)
	for _, o in ipairs(MATRIX) do
		o.tmpl = tmpl
		o.cloneOf = info.e
		local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
		if not okb then
			log("MATRIX " .. o.name .. ": build error " .. shortErr(sp))
		else
			local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, nil, true, true) end)
			log("MATRIX " .. o.name .. ": " .. readBack(sp):gsub("edge id=.*tmpl=[^ ]* ", "") .. " -> factory " .. (okf and (cmd and "OK" or "nil") or shortErr(cmd)))
			if okf and cmd and not o.noEdge then accepted[#accepted + 1] = o end
		end
	end
	-- real builds
	local trials = {}
	for i, o in ipairs(accepted) do
		trials[#trials + 1] = { o = o, ie = false, pi = true }
	end
	local k = 10
	local function nextTrial(i)
		if i > #trials then return done() end
		local tr = trials[i]
		k = k + 1
		local n2, info2, pn2, a2 = matrixPlace(k)
		local o = tr.o
		o.tmpl = { roadTemplate = info2.c.roadTemplate, roadStyle = info2.c.roadStyle, roadType = info2.c.roadType }
		o.cloneOf = info2.e
		local okb, sp = pcall(buildMatrixProposal, o, n2, pn2, a2)
		if not okb then return nextTrial(i + 1) end
		local before = edgeCount()
		local answered = false
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			if not answered then
				answered = true
				log("MATRIX real build '" .. o.name .. "': no answer from the engine")
				nextTrial(i + 1)
			end
		end }
		local okc, errc = pcall(function()
			local ctx = nil
			if tr.ctx then
				ctx = api.type.Context.new()
				ctx.checkTerrainAlignment = true
				ctx.cleanupStreetGraph = true
				ctx.gatherBuildings = true
				ctx.gatherFields = true
				ctx.player = api.engine.util.getPlayer()
			end
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, tr.ie, tr.pi), function(res, success)
				if answered then return end
				answered = true
				local info = ""
				pcall(function()
					local m = C.marshal(res)
					C.appendFile(C.DIR .. BS .. "build_results.txt", "==== " .. o.name .. " ie=" .. tostring(tr.ie) .. " pi=" .. tostring(tr.pi) .. NL .. C.dump(res):sub(1, 20000) .. NL)
					local keys = {}
					for kk, _ in pairs(m or {}) do keys[#keys + 1] = tostring(kk) end
					info = "keys " .. table.concat(keys, ",")
					local rpd = m and (m.resultProposalData or m.proposalData)
					if rpd then info = info .. " errorState=" .. C.ser(rpd.errorState):sub(1, 600) end
				end)
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local after = edgeCount()
					local line = "real build '" .. o.name .. "' ctx=" .. tostring(tr.ctx) .. " pi=" .. tostring(tr.pi) .. ": success=" .. tostring(success) .. " edges " .. before .. " -> " .. after
					log("MATRIX " .. line .. " data=" .. info)
					AUTO.results[#AUTO.results + 1] = line
					if after > before then AUTO.points[#AUTO.points + 1] = pn2 end
					nextTrial(i + 1)
				end }
			end)
		end)
		if not okc then log("MATRIX send failed " .. shortErr(errc)); nextTrial(i + 1) end
	end
	nextTrial(1)
end

H.matrix = function(from, p)
	if p.role ~= C.ROLE then return end
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(runMatrix, function() send("autotest_done", { role = C.ROLE .. "_matrix", results = AUTO.results, points = AUTO.points }) end)
	if not ok then
		log("MATRIX failed: " .. tostring(err))
		send("autotest_done", { role = C.ROLE .. "_matrix", results = { "error " .. tostring(err) } })
	end
end

-- Upgrade scenario: the ENGINE makes the proposal (replaceSegment = the street upgrade tool), the originator applies it
-- as a player build; the other games must rebuild it from what is shipped.
local function playerContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = true
	c.gatherBuildings = false
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

local function runUpgrade(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local edges = R.allEdges()
	local templates, list = {}, {}
	for _, e in ipairs(edges) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate ~= "" and #c.objects == 0 then
			templates[c.roadTemplate] = true
			list[#list + 1] = { e = e, c = c }
		end
	end
	local names = {}
	for t, _ in pairs(templates) do names[#names + 1] = t end
	table.sort(names)
	log("AUTOTEST upgrade (" .. C.ROLE .. "): " .. #list .. " street segments, templates: " .. table.concat(names, ", "))
	local tries = 0
	local function attempt(i)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local pick = list[((p.offset or 0) * 53 + i * 97) % #list + 1]
		local target = nil
		for _, t in ipairs(names) do
			if t ~= pick.c.roadTemplate and t:find("town", 1, true) and not t:find("entrance", 1, true) then target = t; break end
		end
		local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(pick.e, target) end)
		if not okp or not P then
			log("AUTOTEST replaceSegment(" .. pick.e .. ") failed: " .. tostring(P))
			return attempt(i + 1)
		end
		local a = nodePosition(pick.c.node0)
		if false and p.ab and not AUTO.bisectDone then
			AUTO.bisectDone = true
			local compact = C.compactProposal(P)
			local ctx = playerContext()
			local function f(name, fn)
				local ok, res = pcall(function()
					local P2 = fn()
					return api.cmd.makeWorldBuildProposalCmd(P2, ctx, false, true)
				end)
				log("BISECT " .. name .. ": " .. (ok and (res and "OK" or "nil") or shortErr(res)))
			end
			local nat = P.proposal
			local natAdd, natRem = nat.addedSegments[1], nat.removedSegments[1]
			f("original", function() return P end)
			f("emptyNew", function() return api.type.Proposal.new() end)
			f("engineObjects", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				sp.addedSegments = { natAdd }; sp.removedSegments = { natRem }; P2.proposal = sp; return P2
			end)
			f("engineObjectsMaps", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				sp.addedSegments = { natAdd }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourAdded", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = C.templateLanes(compact.proposal.addedSegments[1].comp.roadTemplate); e.comp = c
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourAddedNatLanes", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = natAdd.comp.laneConfigs; e.comp = c
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourRemoved", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local r = C.rebuild("SegmentAndEntity", compact.proposal.removedSegments[1], "r")
				local c = r.comp; c.laneConfigs = natRem.comp.laneConfigs; r.comp = c
				sp.addedSegments = { natAdd }; sp.removedSegments = { r }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("ourBoth", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = C.rebuild("SegmentAndEntity", compact.proposal.addedSegments[1], "a")
				local c = e.comp; c.laneConfigs = natAdd.comp.laneConfigs; e.comp = c
				local r = C.rebuild("SegmentAndEntity", compact.proposal.removedSegments[1], "r")
				local c2 = r.comp; c2.laneConfigs = natRem.comp.laneConfigs; r.comp = c2
				sp.addedSegments = { e }; sp.removedSegments = { r }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("copyNewSegment", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = api.type.SegmentAndEntity.new()
				e.entity = natAdd.entity; e.type = natAdd.type; e.comp = natAdd.comp; e.streetEdge = natAdd.streetEdge
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			f("copyNewSegmentNoStreet", function()
				local P2 = api.type.Proposal.new(); local sp = P2.proposal
				local e = api.type.SegmentAndEntity.new()
				e.entity = natAdd.entity; e.type = natAdd.type; e.comp = natAdd.comp
				sp.addedSegments = { e }; sp.removedSegments = { natRem }
				sp.new2oldSegments = nat.new2oldSegments; sp.old2newSegments = nat.old2newSegments
				P2.proposal = sp; return P2
			end)
			local members = {}
			pcall(function() for _, k in ipairs(C.members(natAdd) or {}) do members[#members + 1] = k end end)
			log("BISECT SegmentAndEntity members: " .. table.concat(members, ","))
			local cm = {}
			pcall(function() for _, k in ipairs(C.members(natAdd.comp) or {}) do cm[#cm + 1] = k end end)
			log("BISECT BaseEdge members: " .. table.concat(cm, ","))
		end
		-- A/B: our rebuild of this very proposal first (same world, same game), engine answers dumped for comparison
		if false and p.ab and not AUTO.abDone then
			AUTO.abDone = true
			local okr, errr = pcall(function()
				local compact = C.compactProposal(P)
				local margs = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
				R.translateOut("makeWorldBuildProposalCmd", margs, {})
				margs = C.deser(C.ser(margs))
				R.translateIn(margs, {})
				local args, n = C.rebuildArgs("makeWorldBuildProposalCmd", margs, { seed = 7919, variant = "native" })
				C.appendFile(C.DIR .. BS .. "ab_simple_in.txt", C.dump(args[1]):sub(1, 60000) .. NL)
				C.appendFile(C.DIR .. BS .. "ab_native_in.txt", C.dump(P):sub(1, 60000) .. NL)
				deferredSend(api.cmd.makeWorldBuildProposalCmd(table.unpack(args, 1, n)), function(res, success)
					C.appendFile(C.DIR .. BS .. "ab_simple.txt", "success=" .. tostring(success) .. NL .. C.dump(res):sub(1, 60000) .. NL)
					log("AUTOTEST A/B rebuilt proposal on the originator: " .. tostring(success))
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() attempt(i) end }
				end)
			end)
			if not okr then log("AUTOTEST A/B failed: " .. tostring(errr)) else return end
		end
		local before = C.ser(C.marshal(api.engine.getComponent(pick.e, api.type.ComponentType.BASE_EDGE).roadTemplate))
		log("AUTOTEST sending the engine's upgrade proposal")
		local okc, errc = pcall(function()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)

				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				local line = "upgrade of segment " .. pick.e .. " to " .. tostring(target) .. ": " .. (success and "built" or ("refused " .. why))
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then
					AUTO.points[#AUTO.points + 1] = a
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
				else
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() attempt(i + 1) end }
				end
			end)
		end)
		if not okc then
			log("AUTOTEST upgrade command failed: " .. shortErr(errc))
			attempt(i + 1)
		end
	end
	attempt(1)
end

-- New road scenario: a road from a dead end, in the form the engine accepted (shared numbering, positions, lanes)
local function runNewRoad(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local tries = 0
	local function attempt(k)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local n, info, pn, a = matrixPlace(k)
		local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
			tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
		if p.stop then
			o.stop = "stations/street/small_stops/small_old.con"
			o.stopEdge = (C.ROLE == "host") and -2 or -1   -- host: the segment's entity id; client: its index
			o.stopLeft = false
			o.tmpl = { roadTemplate = "::/infrastructure/street/town/town_old_small.street_template",
				roadStyle = "::/infrastructure/street/town/town_old_small.street", roadType = info.c.roadType }
			log("AUTOTEST new road with a stop, edgeEntity " .. o.stopEdge)
		end
		local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
		if not okb then log("AUTOTEST new road proposal error " .. shortErr(sp)); return attempt(k + 1) end
		local before = edgeCount()
		log("AUTOTEST new road from node " .. n)
		local okc, errc = pcall(function()
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = true
			ctx.cleanupStreetGraph = true
			ctx.gatherBuildings = true
			ctx.gatherFields = true
			ctx.player = api.engine.util.getPlayer()
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local stops = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do stops = stops + 1 end end)
					local line = "new road from node " .. n .. ": " .. (success and "built" or ("refused " .. why)) .. ", edges " .. before .. " -> " .. edgeCount() .. ", edge objects " .. stops
					log("AUTOTEST " .. line)
					AUTO.results[#AUTO.results + 1] = line
					if success then
						AUTO.points[#AUTO.points + 1] = pn
						G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
					else
						attempt(k + 1)
					end
				end }
			end)
		end)
		if not okc then log("AUTOTEST new road command failed: " .. shortErr(errc)); attempt(k + 1) end
	end
	attempt((p.offset or 0) + 20)
end

H.deferroad = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.deferCount = (AUTO.deferCount or 0) + 1
	nativeCtl("defernext " .. AUTO.deferCount)
	log("AUTOTEST next road command held by the DLL (test mode)")
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST deferred road failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "error " .. tostring(err)
		autoFinish()
	end
end

H.newroadstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.stop = true
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST new road with stop failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "error " .. tostring(err)
		autoFinish()
	end
end

H.newroad = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runNewRoad, p)
	if not ok then
		log("AUTOTEST new road failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "new road error " .. tostring(err)
		autoFinish()
	end
end

-- Stop scenario: which proposal form can put a bus stop on an existing street segment?
local function stopForms(E)
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local function eo(edgeEntity)
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		o.edgeEntity = edgeEntity
		o.param = 0.5
		o.oneWay = false
		o.left = true
		o.model = STOP_MODEL
		o.playerEntity = api.engine.util.getPlayer()
		o.name = "MPF stop"
		return o
	end
	local function copySeg(id, withPos)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
		if withPos then cc.position0 = vec(c.position0); cc.position1 = vec(c.position1) end
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = c.laneConfigs   -- the segment's own lanes (engine objects)
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		return e
	end
	pcall(function()
		local function tm(l) local t = {} for i = 1, #l do t[#t + 1] = C.ser(C.marshal(l[i].transportModes)) end return table.concat(t, " ") end
		log("STOPS lanes segment: " .. tm(c.laneConfigs))
		log("STOPS lanes template: " .. tm(C.templateLanes(c.roadTemplate)))
	end)
	local function cfgNodes()
		local list = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then list[#list + 1] = n end
		end
		return list
	end
	return {
		{ name = "replacePosCfgObj", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			local sg = copySeg(-1, true)
			local sc = sg.comp; sc.objects = { { -400000000, 0 } }; sg.comp = sc
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { sg }; ssp.edgeObjectsToAdd = { eo(-1) }
			ssp.nodeConfigsToRemove = cfgNodes()
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceNoPosCfg", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			ssp.nodeConfigsToRemove = cfgNodes()
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGather", gather = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGatherNoCleanup", gather = true, nocleanup = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceGatherIgnore", gather = true, ie = true, make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "objectOnExisting", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgeObjectsToAdd = { eo(E) }; sp.streetProposal = ssp; return sp end },
		{ name = "replaceNoPos", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, false) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replacePos", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-1, true) }; ssp.edgeObjectsToAdd = { eo(-1) }
			sp.streetProposal = ssp; return sp end },
		{ name = "replaceId2", make = function()
			local sp = api.type.SimpleProposal.new(); local ssp = sp.streetProposal
			ssp.edgesToRemove = { E }; ssp.edgesToAdd = { copySeg(-2, false) }; ssp.edgeObjectsToAdd = { eo(-2) }
			sp.streetProposal = ssp; return sp end },
	}
end

local c0node = nil
local function runStopMatrix(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local forms = nil
	local i = 0
	local function nextForm()
		i = i + 1
		if forms and i > #forms then return autoFinish() end
		local E = list[((p.offset or 0) * 31 + i * 67) % #list + 1]
		c0node = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).node0
		forms = forms or stopForms(E)
		local f = stopForms(E)[i]
		local okb, sp = pcall(f.make)
		if not okb then log("STOPS " .. f.name .. ": build error " .. shortErr(sp)); return nextForm() end
		local ctx = playerContext()
		if f.gather then ctx.gatherBuildings = true; ctx.checkTerrainAlignment = true end
		if f.nocleanup then ctx.cleanupStreetGraph = false end
		local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, f.ie == true, true) end)
		if not okf or not cmd then log("STOPS " .. f.name .. ": factory " .. shortErr(cmd)); return nextForm() end
		O.sendCommand(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local n = 0
			pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
			local line = "stop form " .. f.name .. " on segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
			log("STOPS " .. line)
			AUTO.results[#AUTO.results + 1] = line
			if success then
				AUTO.points[#AUTO.points + 1] = nodePosition(c0node or 0) or { x = 0, y = 0, z = 0 }
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = autoFinish }
			else
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextForm }
			end
		end)
	end
	nextForm()
end

H.stops = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStopMatrix, p)
	if not ok then
		log("STOPS failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops error " .. tostring(err)
		autoFinish()
	end
end

-- Stop on a street without sidewalks (what the stop tool does there: it adds two platform lanes to the segment)
local function runTramStop(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function hasPersonLane(c)
		for i = 1, #c.laneConfigs do if c.laneConfigs[i].transportModes[0] then return true end end
		return false
	end
	local list = {}
	local function scan()
		list = {}
		for _, e in ipairs(R.allEdges()) do
			local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
			if c and c.type == 0 and #c.objects == 0 and #c.laneConfigs > 0 and not hasPersonLane(c) then list[#list + 1] = e end
		end
		log("TRAMSTOP " .. #list .. " street segments without sidewalks")
	end
	scan()
	if #list == 0 and not p.built then
		-- none in the save: build a tram road (no sidewalks) from a dead end first, then retry
		local tries = 0
		local function build(k)
			tries = tries + 1
			if tries > 6 then
				AUTO.results[#AUTO.results + 1] = "could not build a tram road"
				return autoFinish()
			end
			local n, info, pn, a = matrixPlace(k)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = "::/infrastructure/street/tram/tram_old.street_template",
					roadStyle = "::/infrastructure/street/tram/tram_old.street", roadType = info.c.roadType } }
			local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
			if not okb then log("TRAMSTOP road proposal error " .. shortErr(sp)); return build(k + 1) end
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				log("TRAMSTOP tram road from node " .. n .. ": " .. tostring(success))
				if success then
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
						AUTO.running = false
						p.built = true
						local ok, err = pcall(runTramStop, p)
						if not ok then log("TRAMSTOP failed: " .. tostring(err)); autoFinish() end
					end }
				else
					G.waits[#G.waits + 1] = { at = G.frames + 5, fn = function() build(k + 1) end }
				end
			end)
		end
		return build((p.offset or 0) * 5 + 20)
	end
	if #list == 0 then
		AUTO.results[#AUTO.results + 1] = "no street segment without sidewalks"
		return autoFinish()
	end
	local function stopCount()
		local n = 0
		pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
		return n
	end
	local variants = { "platformLanes" }
	log("TRAMSTOP transportModes write shift " .. tostring(C.transportModesWriteShift()))
	local i = 0
	local convertedEO = nil
	local function platformLanes(c)
		local platform = { speed = 10, width = 5, height = 0.1, forward = true, offset = 0, transportModes = { [0] = true } }
		local m = { platform }
		for _, l in ipairs(C.marshal(c.laneConfigs)) do m[#m + 1] = l end
		m[#m + 1] = platform
		return C.rebuildLanes(m)
	end
	local nextVariant
	-- the engine's own replacement of the segment, with the stop grafted (as the stop tool builds it)
	local function nativeVariant(v, E, c)
		local P = api.engine.util.proposal.replaceSegment(E, c.roadTemplate)
		local st = P.proposal
		local segs = st.addedSegments
		local seg = segs[1]
		local sc = seg.comp
		sc.objects = { { -400000000, 0 } }
		sc.laneConfigs = platformLanes(c)
		seg.comp = sc
		segs[1] = seg
		st.addedSegments = segs
		local eo
		if v == "nativeConverted" then
			eo = convertedEO
		else
			eo = api.type.StreetProposal.EdgeObject.new()
			eo.resultEntity = -1; eo.category = 0; eo.oneWay = false; eo.left = true
			eo.name = "MPF stop"; eo.playerEntity = api.engine.util.getPlayer()
		end
		eo.segmentEntity = seg.entity
		st.edgeObjectsToAdd = { eo }
		P.proposal = st
		log("TRAMSTOP " .. v .. ": segment id " .. tostring(seg.entity) .. ", node configs +" .. #st.nodeConfigsToAdd .. " -" .. #st.nodeConfigsToRemove)
		return P
	end
	nextVariant = function()
		i = i + 1
		local v = variants[i]
		if not v then return autoFinish() end
		scan()
		if #list == 0 then return autoFinish() end
		local E = list[((p.offset or 0) * 7 + i * 13) % #list + 1]
		local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		if v == "nativeConverted" and not convertedEO then
			-- get the engine's converted stop object: a stop on a town street in the form the engine refuses (parcels)
			local T = nil
			for _, e in ipairs(R.allEdges()) do
				local tc = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if tc and tc.type == 0 and tc.roadTemplate and tc.roadTemplate:find("town", 1, true) and #tc.objects == 0 then T = e; break end
			end
			local tc = api.engine.getComponent(T, api.type.ComponentType.BASE_EDGE)
			local sp = api.type.SimpleProposal.new()
			local ssp = sp.streetProposal
			local e = api.type.SegmentAndEntity.new()
			e.entity = -1; e.type = 0
			local cc = e.comp
			cc.node0 = tc.node0; cc.node1 = tc.node1
			cc.tangent0 = vec(tc.tangent0); cc.tangent1 = vec(tc.tangent1)
			cc.type = 0; cc.typeIndex = -1
			cc.roadTemplate = tc.roadTemplate; cc.roadStyle = tc.roadStyle; cc.roadType = tc.roadType
			cc.laneConfigs = C.templateLanes(tc.roadTemplate)
			e.comp = cc
			local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
			local o = api.type.SimpleStreetProposal.EdgeObject.new()
			o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = true
			o.model = STOP_MODEL
			o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF stop"
			ssp.edgesToRemove = { T }; ssp.edgesToAdd = { e }; ssp.edgeObjectsToAdd = { o }
			sp.streetProposal = ssp
			deferredSend(api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true), function(res, success)
				log("TRAMSTOP conversion probe on town segment " .. T .. ": success " .. tostring(success))
				pcall(function()
					local list2 = res.proposal.proposal.edgeObjectsToAdd
					log("TRAMSTOP converted stops " .. #list2)
					if #list2 > 0 then convertedEO = list2[1] end
				end)
				i = i - 1
				if not convertedEO then
					AUTO.results[#AUTO.results + 1] = "no converted stop object"
					i = i + 1
				end
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextVariant }
			end)
			return
		end
		if v:sub(1, 6) == "native" then
			local before = stopCount()
			local okp, P = pcall(nativeVariant, v, E, c)
			if not okp then
				AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": proposal " .. shortErr(P)
				return nextVariant()
			end
			local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true) end)
			if not okf or not cmd then
				AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": factory " .. shortErr(cmd)
				return nextVariant()
			end
			deferredSend(cmd, function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
					local after = stopCount()
					local model = ""
					pcall(function()
						for eoE, _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do
							local x = api.engine.getComponent(eoE, api.type.ComponentType.EDGE_OBJECT)
							if x and x.edgeObjectConstruction then model = model .. " " .. tostring(x.edgeObjectConstruction) end
						end
					end)
					local line = "tram stop " .. v .. " on segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why)) .. ", stops " .. before .. " -> " .. after
					log("TRAMSTOP " .. line .. " models:" .. model)
					AUTO.results[#AUTO.results + 1] = line
					if success then AUTO.points[#AUTO.points + 1] = nodePosition(c.node0) end
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextVariant }
				end }
			end)
			return
		end
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		local e = api.type.SegmentAndEntity.new()
		e.entity = -1
		e.type = 0
		local cc = e.comp
		cc.node0 = c.node0; cc.node1 = c.node1
		cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
		cc.position0 = vec(nodePosition(c.node0)); cc.position1 = vec(nodePosition(c.node1))
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		if v == "platformLanes" then
			local platform = { speed = 10, width = 5, height = 0.1, forward = true, offset = 0, transportModes = { [0] = true } }
			local m = { platform }
			for _, l in ipairs(C.marshal(c.laneConfigs)) do m[#m + 1] = l end
			m[#m + 1] = platform
			cc.laneConfigs = C.rebuildLanes(m)
		else
			cc.laneConfigs = c.laneConfigs
		end
		cc.objects = { { -400000000, 0 } }
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		local eo = api.type.SimpleStreetProposal.EdgeObject.new()
		eo.edgeEntity = -1; eo.param = 0.5; eo.oneWay = false; eo.left = true
		eo.model = STOP_MODEL
		eo.playerEntity = api.engine.util.getPlayer()
		eo.name = "MPF stop"
		local ncr = {}
		for _, n in ipairs({ c.node0, c.node1 }) do
			local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			if okn and nc then ncr[#ncr + 1] = n end
		end
		ssp.edgesToRemove = { E }; ssp.edgesToAdd = { e }; ssp.edgeObjectsToAdd = { eo }
		if #ncr > 0 then ssp.nodeConfigsToRemove = ncr end
		sp.streetProposal = ssp
		local before = stopCount()
		local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true) end)
		if not okf or not cmd then
			AUTO.results[#AUTO.results + 1] = "tram stop " .. v .. ": factory " .. shortErr(cmd)
			return nextVariant()
		end
		deferredSend(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local line = "tram stop " .. v .. " on segment " .. E .. " (" .. tostring(c.roadTemplate) .. "): "
					.. (success and "BUILT" or ("refused " .. why)) .. ", stops " .. before .. " -> " .. stopCount()
				log("TRAMSTOP " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then AUTO.points[#AUTO.points + 1] = nodePosition(c.node0) end
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextVariant }
			end }
		end)
	end
	nextVariant()
end

H.tramstop = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runTramStop, p)
	if not ok then
		log("TRAMSTOP failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "tramstop error " .. tostring(err)
		autoFinish()
	end
end

-- Replays native builds captured in a real game (one compact proposal per line in <temp>\mpfever\replay_case.txt),
-- through the same path as a peer: checks the segment count against the originator's
local function runReplayFile(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local path = C.DIR:gsub("[^" .. BS .. "]+$", "") .. "replay_case.txt"
	-- replay_acts.txt: acts exactly as a peer received them (third column of in.log)
	local actsPath = C.DIR:gsub("[^" .. BS .. "]+$", "") .. "replay_acts.txt"
	local fa = C.IO.open(actsPath, "rb")
	if fa then
		local acts = {}
		for l in fa:lines() do if #l > 2 then acts[#acts + 1] = l end end
		fa:close()
		local k = 0
		local function nextAct()
			k = k + 1
			if not acts[k] then return autoFinish() end
			local a = C.deser(acts[k])
			a.uid = "act:" .. k .. ":" .. tostring(a.uid)
			local st = a.args[1].proposal
			local line = "act " .. k .. ": originator +" .. #st.addedSegments .. " -" .. #st.removedSegments .. ", edges before " .. #R.allEdges()
			if k == 2 then
				pcall(function()
					local d = {}
					for _, e in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						local p0, p1 = nodePosition(c.node0), nodePosition(c.node1)
						local function near(q) return q and math.abs(q.x - 1416) < 60 and math.abs(q.y + 346.6) < 60 end
						if near(p0) or near(p1) then
							d[#d + 1] = string.format("%d %d(%.1f %.1f)-%d(%.1f %.1f) t0(%.1f %.1f) t1(%.1f %.1f) %s", e, c.node0, p0.x, p0.y, c.node1, p1.x, p1.y,
								c.tangent0.x, c.tangent0.y, c.tangent1.x, c.tangent1.y, tostring(c.roadTemplate):match("[^/]+$"))
						end
					end
					log("REPLAYFILE near: " .. table.concat(d, " | "))
				end)
			end
			local ok, err = pcall(replayNative, a, 1)
			if not ok then line = line .. ", replay error " .. tostring(err) end
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
				line = line .. ", after " .. #R.allEdges()
				log("REPLAYFILE " .. line)
				AUTO.results[#AUTO.results + 1] = line
				nextAct()
			end }
		end
		return nextAct()
	end
	local f = C.IO.open(path, "rb")
	if not f then AUTO.results[#AUTO.results + 1] = "no " .. path; return autoFinish() end
	local lines = {}
	for l in f:lines() do if #l > 2 then lines[#lines + 1] = l end end
	f:close()
	local i = 0
	local function nextOne()
		i = i + 1
		if not lines[i] then return end
		local compact = C.deser(lines[i])
		local margs = { n = 4, [1] = compact, [2] = { __player = true }, [3] = false, [4] = true }
		R.translateOut("makeWorldBuildProposalCmd", margs, {})
		local a = { uid = "file:" .. i, origin = "file", fn = "makeWorldBuildProposalCmd", args = C.deser(C.ser(margs)), native = true }
		local st = compact.proposal
		local line = "case " .. i .. ": originator +" .. #st.addedSegments .. " -" .. #st.removedSegments .. ", edges before " .. #R.allEdges()
		local ok, err = pcall(replayNative, a, 1)
		if not ok then line = line .. ", replay error " .. tostring(err) end
		G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
			line = line .. ", after " .. #R.allEdges()
			log("REPLAYFILE " .. line)
			AUTO.results[#AUTO.results + 1] = line
			nextOne()
		end }
	end
	nextOne()
	G.waits[#G.waits + 1] = { at = G.frames + 120 * (#lines + 1), fn = autoFinish }
end

H.replayfile = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	if C.ROLE ~= "host" then AUTO.results = { "host only" }; return autoFinish() end
	local ok, err = pcall(runReplayFile, p)
	if not ok then
		log("REPLAYFILE failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "replayfile error " .. tostring(err)
		autoFinish()
	end
end

-- Bulldozer scenario: the engine's own removal proposal for a dead-end segment
local function runBulldoze(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	-- what the API offers to build stops inside an engine proposal
	local av = {}
	for _, path in ipairs({ "api.type.EdgeObject", "api.type.Proposal.EdgeObject", "api.type.ProposalEdgeObject", "api.type.ModelInstance",
		"api.type.Proposal.StreetProposal", "api.type.StreetProposal" }) do
		local cur = _G
		for part in path:gmatch("[^.]+") do if cur ~= nil then local ok, v = pcall(function() return cur[part] end); cur = ok and v or nil end end
		local canNew = false
		if cur ~= nil then canNew = pcall(function() return cur.new() end) end
		av[#av + 1] = path .. "=" .. type(cur) .. (canNew and "(new ok)" or "")
	end
	log("BULLDOZE api: " .. table.concat(av, ", "))
	local ends, edgeOf = deadEnds()
	local tries = 0
	local function attempt(k)
		tries = tries + 1
		if tries > 6 then return autoFinish() end
		local n = ends[(k * 41) % #ends + 1]
		local info = edgeOf[n]
		local okp, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal({ info.e }) end)
		if not okp or not P then log("BULLDOZE no proposal " .. tostring(P)); return attempt(k + 1) end
		local before = edgeCount()
		local pn = nodePosition(n)
		deferredSend(api.cmd.makeWorldBuildProposalCmd(P, playerContext(), false, true), function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			G.waits[#G.waits + 1] = { at = G.frames + 20, fn = function()
				local line = "bulldoze segment " .. info.e .. ": " .. (success and "removed" or ("refused " .. why)) .. ", edges " .. before .. " -> " .. edgeCount()
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				if success then
					AUTO.points[#AUTO.points + 1] = pn
					G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
				else
					attempt(k + 1)
				end
			end }
		end)
	end
	attempt((p.offset or 0) + 3)
end

H.bulldoze = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runBulldoze, p)
	if not ok then
		log("BULLDOZE failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "bulldoze error " .. tostring(err)
		autoFinish()
	end
end

-- Stops inside an engine-made proposal
local function runStops2(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function mem(o)
		local t = {}
		pcall(function() for _, k in ipairs(C.members(o) or {}) do t[#t + 1] = k end end)
		return table.concat(t, ",")
	end
	pcall(function() log("STOPS2 EdgeObject members: " .. mem(api.type.EdgeObject.new())) end)
	pcall(function() log("STOPS2 ModelInstance members: " .. mem(api.type.ModelInstance.new())) end)
	pcall(function() log("STOPS2 StreetProposal members: " .. mem(api.type.StreetProposal.new())) end)
	for _, path in ipairs({ "api.type.StreetProposal.EdgeObject", "api.type.StreetProposalEdgeObject", "api.type.Proposal.StreetProposal",
		"api.type.ProposalEdgeObject", "api.type.StreetProposal.NodeAndEntity" }) do
		local cur = _G
		for part in path:gmatch("[^.]+") do if cur ~= nil then local ok, v = pcall(function() return cur[part] end); cur = ok and v or nil end end
		local ok, obj = false, nil
		if cur ~= nil then ok, obj = pcall(function() return cur.new() end) end
		log("STOPS2 type " .. path .. " = " .. type(cur) .. (ok and obj and (" new ok, members: " .. mem(obj)) or ""))
	end
	pcall(function()
		local keys = {}
		for k, _ in pairs(api.type) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		log("STOPS2 api.type: " .. table.concat(keys, ","))
	end)
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local ctx = playerContext()
	local function try(name, mk)
		local ok, res = pcall(function() return api.cmd.makeWorldBuildProposalCmd(mk(), ctx, false, true) end)
		log("STOPS2 " .. name .. ": factory " .. (ok and (res and "OK" or "nil") or shortErr(res)))
		return ok and res or nil
	end
	try("replaceSegment as is", function() return api.engine.util.proposal.replaceSegment(E) end)
	try("replaceSegment reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		P.proposal = sp
		return P
	end)
	try("replaceSegment segments reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		sp.addedSegments = segs
		P.proposal = sp
		return P
	end)
	local withStop
	withStop = function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		local seg = segs[1]
		local c = seg.comp
		c.objects = { { -400000000, 1 } }
		seg.comp = c
		segs[1] = seg
		sp.addedSegments = segs
		local EOT = nil
		pcall(function() EOT = api.type.StreetProposal.EdgeObject end)
		local eo = EOT and EOT.new() or api.type.EdgeObject.new()
		pcall(function() eo.resultEntity = -1 end)
		pcall(function() eo.category = 0 end)
		pcall(function() eo.segmentEntity = seg.entity end)
		pcall(function() eo.left = true end)
		pcall(function() eo.oneWay = false end)
		pcall(function() eo.name = "MPF stop" end)
		pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
		pcall(function() eo.param = 0.5 end)
		pcall(function() eo.edgeObjectConstruction = STOP_MODEL end)
		pcall(function() eo.model = STOP_MODEL end)
		sp.edgeObjectsToAdd = { eo }
		P.proposal = sp
		log("STOPS2 stop object: " .. C.ser(C.marshal(eo)):sub(1, 400))
		return P
	end
	-- a template stop object: the engine re-adds the stops of a segment it replaces
	local T = nil
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and #c.objects > 0 then T = e; break end
	end
	local template = nil
	if T then
		local okt, errt = pcall(function()
			local P0 = api.engine.util.proposal.replaceSegment(T)
			local sp0 = P0.proposal
			local list = sp0.edgeObjectsToAdd
			log("STOPS2 template segment " .. T .. ": objects to add " .. #list .. ", segment objects " .. C.ser(C.marshal(sp0.addedSegments[1].comp.objects)))
			if #list > 0 then
				template = list[1]
				log("STOPS2 template members: " .. mem(template) .. " = " .. C.ser(C.marshal(template)):sub(1, 600))
				pcall(function() log("STOPS2 template modelInstance: " .. mem(template.modelInstance) .. " modelId=" .. tostring(template.modelInstance.modelId)) end)
			end
		end)
		if not okt then log("STOPS2 template failed: " .. tostring(errt)) end
	end
	-- template from the engine's own conversion of a stop on a road outside the map (refused, nothing is built)
	local function afterTemplate()
		if not template then AUTO.results[#AUTO.results + 1] = "no stop template"; return autoFinish() end
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
		local cmd = try("replaceSegment + stop (engine template)", withStop)
		if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
		O.sendCommand(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local n = 0
			pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
			local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
			log("STOPS2 " .. line)
			AUTO.results[#AUTO.results + 1] = line
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
		end)
	end
	if not template then
		local cE = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		-- right on top of the target street: refused for collision, the conversion still comes back
		local q, q2 = nodePosition(cE.node0), nodePosition(cE.node1)
		local px, py, pz = q.x + 1, q.y + 1, q.z
		local pz2 = q2.z
		local n1 = api.type.NodeAndEntity.new(); n1.entity = -1
		local b1 = n1.comp; b1.position = api.type.Vec3f.new(px, py, pz); n1.comp = b1
		local n2 = api.type.NodeAndEntity.new(); n2.entity = -2
		local b2 = n2.comp; b2.position = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2); n2.comp = b2
		local e = api.type.SegmentAndEntity.new(); e.entity = -3; e.type = 0
		local ec = e.comp
		ec.node0 = -1; ec.node1 = -2
		local tx, ty, tz = q2.x - q.x, q2.y - q.y, pz2 - pz
		ec.tangent0 = api.type.Vec3f.new(tx, ty, tz); ec.tangent1 = api.type.Vec3f.new(tx, ty, tz)
		ec.position0 = api.type.Vec3f.new(px, py, pz); ec.position1 = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2)
		ec.type = 0; ec.typeIndex = -1
		ec.roadTemplate = cE.roadTemplate; ec.roadStyle = cE.roadStyle; ec.roadType = cE.roadType
		ec.laneConfigs = C.templateLanes(cE.roadTemplate)
		e.comp = ec
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		local modelName = (C.ROLE == "host") and "stations/street/small_stops/small_old.con" or "::/stations/street/small_stops/small_old.con"
		log("STOPS2 template probe with model " .. modelName)
		o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false; o.model = modelName
		o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF template"
		ssp.nodesToAdd = { n1, n2 }
		ssp.edgesToAdd = { e }
		ssp.edgeObjectsToAdd = { o }
		sp.streetProposal = ssp
		local okc, cmdT = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true) end)
		log("STOPS2 template probe factory: " .. (okc and "OK" or shortErr(cmdT)))
		if not okc then return afterTemplate() end
		O.sendCommand(cmdT, function(res, success)
			local okx, errx = pcall(function()
				local list = res.proposal.proposal.edgeObjectsToAdd
				log("STOPS2 template probe: success=" .. tostring(success) .. ", converted stops " .. #list)
				if #list > 0 then
					template = list[1]
					log("STOPS2 template members: " .. mem(template))
					pcall(function() log("STOPS2 template modelId=" .. tostring(template.modelInstance.modelId) .. " category=" .. tostring(template.category)) end)
				end
			end)
			if not okx then log("STOPS2 template read failed: " .. tostring(errx)) end
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = afterTemplate }
		end)
		return
	end
	if template then
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
	end
	local cmd = try("replaceSegment + stop", withStop)
	if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		local n = 0
		pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
		local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
		log("STOPS2 " .. line)
		AUTO.results[#AUTO.results + 1] = line
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
	end)
end

H.stops2 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops2, p)
	if not ok then
		log("STOPS2 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops2 error " .. tostring(err)
		autoFinish()
	end
end

-- Vehicle purchase scenario: the same request the depot window sends (through the UI hook file)
local function runBuy(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local vehicles = R.entitiesWith("TRANSPORT_VEHICLE")
	local pick = nil
	for _, v in ipairs(vehicles) do
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then pick = { v = v, tv = tv }; break end
	end
	if not pick then
		AUTO.results[#AUTO.results + 1] = "no vehicle with a depot (" .. #vehicles .. " vehicles)"
		return autoFinish()
	end
	local before = #vehicles
	local margs = { n = 3, [1] = api.engine.util.getPlayer(), [2] = pick.tv.depot, [3] = C.marshal(pick.tv.transportVehicleConfig) }
	R.translateOut("makeVehicleBuyCmd", margs, G.rev)
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = 1, fn = "makeVehicleBuyCmd", args = margs }))
	log("AUTOTEST buy a copy of vehicle " .. pick.v .. " in depot " .. pick.tv.depot .. " (" .. before .. " vehicles)")
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local after = #R.entitiesWith("TRANSPORT_VEHICLE")
		local line = "purchase: vehicles " .. before .. " -> " .. after
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		autoFinish()
	end }
end

H.buy = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runBuy, p)
	if not ok then
		log("AUTOTEST buy failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "buy error " .. tostring(err)
		autoFinish()
	end
end

-- Line scenario: a new line with the stops of an existing line, then a vehicle bought and assigned to it
local function uiRequest(fn, margs)
	R.translateOut(fn, margs, G.rev)
	AUTO.reqId = (AUTO.reqId or 0) + 1
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = AUTO.reqId, fn = fn, args = margs }))
end

local function runLine(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local lines = R.entitiesWith("LINE")
	if #lines == 0 then AUTO.results[#AUTO.results + 1] = "no line in the save"; return autoFinish() end
	local src = api.engine.getComponent(lines[1], api.type.ComponentType.LINE)
	local before = #lines
	local known = {}
	for _, l in ipairs(lines) do known[l] = true end
	uiRequest("makeLineCreateCmd", { n = 4, [1] = "MPF " .. C.ROLE, [2] = C.marshal(api.type.Vec3f.new(0.9, 0.2, 0.1)),
		[3] = api.engine.util.getPlayer(), [4] = C.marshal(src) })
	log("AUTOTEST line with the " .. #src.stops .. " stops of line " .. lines[1])
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
		local now = R.entitiesWith("LINE")
		local newLine = nil
		for _, l in ipairs(now) do if not known[l] then newLine = l end end
		local line = "line create: lines " .. before .. " -> " .. #now
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		-- assign a vehicle of the save to the new line
		local veh = nil
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do veh = v; break end
		if veh and newLine and #now > before then
			uiRequest("makeVehicleSetLineCmd", { n = 3, [1] = veh, [2] = newLine, [3] = 0 })
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				local tv = api.engine.getComponent(veh, api.type.ComponentType.TRANSPORT_VEHICLE)
				local l2 = "vehicle " .. veh .. " on line " .. tostring(tv and tv.line)
				log("AUTOTEST " .. l2)
				AUTO.results[#AUTO.results + 1] = l2
				autoFinish()
			end }
		else
			autoFinish()
		end
	end }
end

H.line = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runLine, p)
	if not ok then
		log("AUTOTEST line failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "line error " .. tostring(err)
		autoFinish()
	end
end

-- Stop on a town street: the engine converts our simple proposal (refused for the parcels), we fix the converted
-- proposal (old/new segment maps, as the native stop tool sets them) and send it again
local function runStops3(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = 0
	local cc = e.comp
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
	cc.type = 0; cc.typeIndex = -1
	cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
	cc.laneConfigs = C.templateLanes(c.roadTemplate)
	e.comp = cc
	local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
	local o = api.type.SimpleStreetProposal.EdgeObject.new()
	o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false
	o.model = "stations/street/small_stops/small_old.con"
	o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF stop"
	ssp.edgesToRemove = { E }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = { o }
	sp.streetProposal = ssp
	log("STOPS3 step 1: simple proposal on town segment " .. E)
	local ctx = playerContext()
	O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("STOPS3 step 1 result: " .. (success and "BUILT" or ("refused " .. why)))
		if success then AUTO.results[#AUTO.results + 1] = "stop built directly"; return autoFinish() end
		local okp, errp = pcall(function()
			local P2 = res.proposal
			local st = P2.proposal
			local eo = st.edgeObjectsToAdd
			local segs = st.addedSegments
			log("STOPS3 converted: added " .. #segs .. " removed " .. #st.removedSegments .. " stops " .. #eo
				.. " seg id " .. tostring(segs[1] and segs[1].entity) .. " objects " .. C.ser(C.marshal(segs[1] and segs[1].comp.objects)))
			local newId = segs[1].entity
			local seg = segs[1]
			local sc = seg.comp
			sc.objects = { { -400000000, 1 } }
			seg.comp = sc
			segs[1] = seg
			st.addedSegments = segs
			pcall(function() log("STOPS3 stop object: left=" .. tostring(eo[1].left) .. " segment=" .. tostring(eo[1].segmentEntity) .. " category=" .. tostring(eo[1].category)) end)
			-- attempts A: the converted proposal itself, repaired (positions always; maps / stop reference optional)
			local pa, pb = nodePosition(c.node0), nodePosition(c.node1)
			local base = C.ser(1)
			local function variantA(withMaps, withObj)
				local PA = res.proposal
				local stA = PA.proposal
				local segsA = stA.addedSegments
				local sA = segsA[1]
				local cA = sA.comp
				cA.position0 = vec(pa)
				cA.position1 = vec(pb)
				if withObj then cA.objects = { { -400000000, 1 } } end
				sA.comp = cA
				segsA[1] = sA
				stA.addedSegments = segsA
				if withMaps then
					stA.new2oldSegments = { [sA.entity] = { E } }
					stA.old2newSegments = { [E] = { sA.entity } }
				end
				PA.proposal = stA
				return PA
			end
			local tries = {}
			local chosen = nil
			for _, t in ipairs(tries) do
				local okf, cmdA = pcall(function() return api.cmd.makeWorldBuildProposalCmd(variantA(t[2], t[3]), playerContext(), false, true) end)
				log("STOPS3 attempt A " .. t[1] .. ": factory " .. (okf and "OK" or shortErr(cmdA)))
				if okf and cmdA and not chosen then chosen = { name = t[1], cmd = cmdA } end
			end
			if chosen then
				O.sendCommand(chosen.cmd, function(resA, successA)
					local whyA = ""
					if not successA then pcall(function() whyA = C.ser(C.marshal(resA.resultProposalData.errorState.messages)) end) end
					local nA = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do nA = nA + 1 end end)
					log("STOPS3 attempt A '" .. chosen.name .. "': " .. (successA and "BUILT" or ("refused " .. whyA)) .. ", edge objects " .. nA)
					AUTO.results[#AUTO.results + 1] = "A " .. chosen.name .. ": " .. (successA and "BUILT" or ("refused " .. whyA))
				end)
			end
			-- attempt B: graft the converted stop object onto the engine's own replacement of the segment
			local P3 = api.engine.util.proposal.replaceSegment(E)
			local st3 = P3.proposal
			local segs3 = st3.addedSegments
			local seg3 = segs3[1]
			local c3 = seg3.comp
			c3.objects = { { -400000000, 1 } }
			seg3.comp = c3
			segs3[1] = seg3
			st3.addedSegments = segs3
			local obj = eo[1]
			obj.segmentEntity = seg3.entity
			st3.edgeObjectsToAdd = { obj }
			st3.new2oldSegments = { [seg3.entity] = { E } }
			st3.old2newSegments = { [E] = { seg3.entity } }
			log("STOPS3 node configs: converted +" .. #st.nodeConfigsToAdd .. " -" .. #st.nodeConfigsToRemove
				.. ", engine replacement +" .. #st3.nodeConfigsToAdd .. " -" .. #st3.nodeConfigsToRemove
				.. "; converted toAdd " .. #P2.toAdd .. ", segmentTags " .. tostring(#P2.segmentTags))
			if #st.nodeConfigsToAdd > 0 then
				st3.nodeConfigsToAdd = st.nodeConfigsToAdd
				st3.nodeConfigsToRemove = st.nodeConfigsToRemove
			end
			P3.proposal = st3
			log("STOPS3 grafted: segment id " .. tostring(seg3.entity) .. ", stops " .. #P3.proposal.edgeObjectsToAdd)
			P2 = P3
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(P2, playerContext(), false, true), function(res2, success2)
				local why2 = ""
				if not success2 then
					pcall(function() why2 = C.ser(C.marshal(res2.resultProposalData.errorState)) end)
					pcall(function() why2 = why2 .. " collisions " .. C.ser(C.marshal(res2.resultProposalData.collisionInfo)):sub(1, 300) end)
				end
				local n = 0
				pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
				local line = "stop via converted proposal on town segment " .. E .. ": " .. (success2 and "BUILT" or ("refused " .. why2)) .. ", edge objects now " .. n
				log("STOPS3 " .. line)
				AUTO.results[#AUTO.results + 1] = line
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end)
		end)
		if not okp then
			log("STOPS3 converted proposal failed: " .. tostring(errp))
			AUTO.results[#AUTO.results + 1] = "converted proposal error " .. tostring(errp)
			autoFinish()
		end
	end)
end

H.stops3 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops3, p)
	if not ok then
		log("STOPS3 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops3 error " .. tostring(err)
		autoFinish()
	end
end

-- Split scenario: a branch joining the middle of an existing segment (the most common road build)
local function runSplit(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and #c.objects == 0 then
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 60 then list[#list + 1] = e end
		end
	end
	local E = list[((p.offset or 0) * 31 + 11) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local A, B = nodePosition(c.node0), nodePosition(c.node1)
	local M = { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 }
	local dx, dy = B.x - A.x, B.y - A.y
	local len = math.sqrt(dx * dx + dy * dy)
	local P = { x = M.x - dy / len * 40, y = M.y + dx / len * 40 }
	P.z = groundZ(P.x, P.y, M.z)
	local lanes = C.templateLanes(c.roadTemplate)
	if p.lanesFrom == "segment" then lanes = c.laneConfigs end
	local function seg(id, n0, n1, p0, p1, owner)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = n0; cc.node1 = n1
		local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z }
		cc.tangent0 = vec(t); cc.tangent1 = vec(t)
		cc.position0 = vec(p0); cc.position1 = vec(p1)
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = lanes
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		if owner then local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po end
		return e
	end
	local function node(id, q)
		local n = api.type.NodeAndEntity.new()
		n.entity = id
		local bn = n.comp; bn.position = vec(q); n.comp = bn
		return n
	end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	ssp.nodesToAdd = { node(-1, M), node(-2, P) }
	ssp.edgesToAdd = { seg(-3, c.node0, -1, A, M, false), seg(-4, -1, c.node1, M, B, false), seg(-5, -1, -2, M, P, true) }
	ssp.edgesToRemove = { E }
	-- lane connections of the nodes touching the removed segment refer to it: remove those node configurations
	local ncr = {}
	for _, n in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = n end
	end
	if p.nodeConfigs then ssp.nodeConfigsToRemove = ncr end
	log("SPLIT node configs on the segment's nodes: " .. #ncr .. (p.nodeConfigs and " (removed)" or " (kept)"))
	sp.streetProposal = ssp
	log("SPLIT segment " .. E .. " (" .. tostring(c.roadTemplate) .. "), lanes from " .. tostring(p.lanesFrom or "template")
		.. ": template " .. tostring(#(C.templateLanes(c.roadTemplate) or {})) .. " lanes, segment " .. #c.laneConfigs .. " lanes")
	pcall(function()
		local function d(l) local t = {} for i = 1, #l do t[#t + 1] = string.format("%.1f/%s/%.2f", l[i].width, tostring(l[i].forward), l[i].offset) end return table.concat(t, " ") end
		log("SPLIT lanes template: " .. d(C.templateLanes(c.roadTemplate)) .. " | segment: " .. d(c.laneConfigs))
	end)
	local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true) end)
	log("SPLIT factory: " .. (okf and "OK" or shortErr(cmd)))
	AUTO.results[#AUTO.results + 1] = "split factory " .. (okf and "OK" or shortErr(cmd))
	if not okf then return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("SPLIT build: " .. (success and "BUILT" or ("refused " .. why)))
		AUTO.results[#AUTO.results + 1] = "split build " .. (success and "BUILT" or ("refused " .. why))
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
	end)
end

H.split = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.nodeConfigs = true
	local ok, err = pcall(runSplit, p)
	if not ok then
		log("SPLIT failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "split error " .. tostring(err)
		autoFinish()
	end
end

H.upgrade = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runUpgrade, p)
	if not ok then
		log("AUTOTEST upgrade failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "upgrade error " .. tostring(err)
		autoFinish()
	end
end

H.autotest_done = function(from, p)
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(p.points or {}) do G.autoPoints[#G.autoPoints + 1] = q end
end

H.autotest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runScenario, p)
	if not ok then
		log("AUTOTEST failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "scenario error " .. tostring(err)
		autoFinish()
	end
end

-- what this game has around the test points: edges (rounded end positions, template) and stops
-- autotest: one game moves its camera around the map (does the camera change the simulation?)
H.camtour = function(from, p)
	if p.role ~= C.ROLE then return end
	local cam = api.gui and api.gui.camera
	if not cam then log("camtour: no api.gui.camera"); return end
	local okc, data = pcall(cam.getCameraData)
	log("camtour: camera " .. (okc and C.dump(data):sub(1, 300) or tostring(data)))
	if not okc then return end
	local spots = {}
	pcall(function()
		local edges = R.allEdges()
		for k = 1, #edges, math.max(1, math.floor(#edges / 12)) do
			local c = api.engine.getComponent(edges[k], api.type.ComponentType.BASE_EDGE)
			local q = c and nodePosition(c.node0)
			if q then spots[#spots + 1] = q end
		end
	end)
	local i = 0
	local function hop()
		i = i + 1
		local q = spots[(i % math.max(1, #spots)) + 1]
		if q then
			local ok, err = pcall(function()
				local d = cam.getCameraData()
				if d.x ~= nil then d.x, d.y = q.x, q.y else d[1], d[2] = q.x, q.y end
				cam.setCameraData(d)
			end)
			if i <= 2 then log("camtour: hop " .. i .. " -> " .. (ok and "ok" or tostring(err))) end
		end
		if i < 400 then G.waits[#G.waits + 1] = { at = G.frames + 90, fn = hop } end
	end
	hop()
end

H.area_dump = function(from, p)
	local lines = {}
	local function near(q)
		for _, c in ipairs(G.autoPoints or {}) do
			local dx, dy = q.x - c.x, q.y - c.y
			if dx * dx + dy * dy < 400 * 400 then return true end
		end
		return false
	end
	local function r(v) return string.format("%.0f", v) end
	for _, e in ipairs(R.allEdges()) do repeat
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if not c then break end
		local a, b = nodePosition(c.node0), nodePosition(c.node1)
		if a and b and (near(a) or near(b)) then
			local s1, s2 = r(a.x) .. "," .. r(a.y), r(b.x) .. "," .. r(b.y)
			if s1 > s2 then s1, s2 = s2, s1 end
			local objs = {}
			for i = 1, #c.objects do
				local eo = api.engine.getComponent(c.objects[i][1], api.type.ComponentType.EDGE_OBJECT)
				objs[#objs + 1] = (eo and tostring(eo.edgeObjectConstruction) or "?") .. "@" .. (eo and string.format("%.2f", eo.param) or "?")
			end
			lines[#lines + 1] = "edge " .. s1 .. " - " .. s2 .. " " .. tostring(c.roadTemplate) .. (#objs > 0 and (" objects " .. table.concat(objs, ";")) or "")
		end
	until true end
	table.sort(lines)
	local f = C.IO.open(C.DIR .. BS .. "area.txt", "wb")
	if f then
		f:write("t=" .. gameTime() .. NL .. table.concat(lines, NL) .. NL)
		f:close()
	end
	send("area_done", { n = #lines })
end

local function neutraliseEmissions()
	-- town pollution/noise come from a non-deterministic engine computation: remove their effect on growth
	local n = 0
	api.engine.forEachEntityWithComponent(function(town)
		n = n + 1
		for _, rating in ipairs({ "pollution", "noise" }) do
			O.sendCommand(O.event("", "Towns", "setTownRatingSensitivity", { townEntity = town, rating = rating, sensitivity = 0 }))
		end
	end, api.type.ComponentType.TOWN)
	log("pollution and noise sensitivity set to 0 for " .. n .. " towns")
end

local function fileSize(name)
	local f = C.IO.open(C.DIR .. BS .. name, "rb")
	if not f then return 0 end
	local n = f:seek("end")
	f:close()
	return n or 0
end

-- This GUI half starts with the game, and again after a resynchronisation (the host's savegame loaded here): what the
-- files already hold belongs to the previous game state, and the savegame's script state holds the host's records.
local function resumeAfterLoad(state)
	-- records of the savegame's script state (an earlier session, or the host's): never shipped or reported again
	local st = state:get() or {}
	for _, o in ipairs(st.out or {}) do if o.n > G.outSent then G.outSent = o.n end end
	-- (keyed by uid and game time: uids start again at 1 in every session, an old record must not hide a new one)
	for _, r in ipairs(st.results or {}) do G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true end
	if type(st.hash) == "table" then G.hashSent = st.hash.n end
	-- first start of this game in the session: everything the launcher wrote so far is for it
	if fileSize("started.txt") == 0 then
		C.appendFile(C.DIR .. BS .. "started.txt", "1")
		return
	end
	G.inOff = fileSize("in.log")
	-- commands the UI hook held before the reload were already shipped and applied: never again
	G.uiOff = fileSize("ui.log")
	G.natOff = fileSize("native_events.log")
	local f = C.IO.open(C.DIR .. BS .. "native_ctl.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		-- the DLL keeps counting releases across loads
		for n in s:gmatch("release (%d+)") do
			n = tonumber(n)
			if n and n > G.natReleased then G.natReleased = n end
		end
	end
	-- entity bindings of a previous game state are void
	C.appendFile(C.DIR .. BS .. "bindings.log", "RESET 0" .. NL)
	if G.inOff > 0 then log("started over an existing session (" .. G.inOff .. " bytes of messages skipped): resynchronised game") end
end

local function guiUpdate(userParams, state, guiState)
	if not C.ACTIVE then return end
	G.frames = G.frames + 1
	if G.frames % 600 == 0 then
		local ps = G.pstat
		log("gui alive frame " .. G.frames .. " t=" .. tostring(gameTime()) .. " | slowed by other clocks " .. ps.barrier .. "/" .. ps.frames .. " frames, by held actions " .. ps.hold)
		ps.frames, ps.barrier, ps.hold = 0, 0, 0
	end
	if not G.started then
		G.started = true
		-- the game's own functions, even if the UI hook already wrapped this api table (shared after a reload)
		local orig = C.origCmds()
		if not orig.sendCommand then
			orig.sendCommand, orig.setSpeed, orig.event = api.cmd.sendCommand, api.cmd.makeGameSetSpeedCmd, api.cmd.makeScriptingSendEventCmd
		end
		O.sendCommand, O.setSpeed, O.event = orig.sendCommand, orig.setSpeed, orig.event
		O.steps = api.cmd.debug and api.cmd.debug.makeGamePerformSimulationStepsCmd
		pcall(function() guiState:subscribeToAllEvents() end)
		log("bridge v0.17 started: name=" .. C.NAME .. " role=" .. C.ROLE .. " dir=" .. C.DIR)
		local okr, errr = pcall(resumeAfterLoad, state)
		if not okr then log("resume after load failed: " .. tostring(errr)) end
		setSpeed(0)
		local okn, errn = pcall(neutraliseEmissions)
		if not okn then log("emissions: " .. tostring(errn)) end
		send("hello", { name = C.NAME, role = C.ROLE, build = getBuildVersion and getBuildVersion() or "?", time = gameTime() })
	end

	for _, line in ipairs(readLines("in.log", "inOff")) do
		local kind, from, payload = parseLine(line)
		if kind then
			local h = H[kind]
			if h then
				local ok, err = pcall(h, from, C.deser(payload) or {})
				if not ok then log("handler " .. kind .. " failed: " .. tostring(err)) end
			end
		end
	end

	local okh, st = pcall(function() return state:get() end)
	if not (okh and type(st) == "table") then st = {} end

	-- outgoing actions BEFORE the clock: a peer must receive an action before it may pass its time
	if G.connected then
		local oks, errs = pcall(stampHeld)
		if not oks then log("stamping failed: " .. tostring(errs)) end
		local okb, errb = pcall(shipNativeBuilds, st)
		if not okb then log("shipping native builds failed: " .. tostring(errb)) end
	end

	if G.connected then
		local okv, errv = pcall(function()
			if G.session.started and not G.natEnabled then G.natEnabled = true; nativeCtl("enable 1") end
			pollNativeEvents()
			runNativeRelease()
			expireNativeWaits()
		end)
		if not okv then log("native deferral failed: " .. tostring(errv)) end
	end
	pcall(runPausedActions)
	local okn, errn = pcall(runNativeReplays)
	if not okn then log("native replays failed: " .. tostring(errn)) end

	if G.connected then
		local okp, sp = pcall(pacing)
		if okp then
			if gameSpeed() ~= sp then G.lastSet = -1 end
			setSpeed(sp)
			-- exact steps up to the stop point (once the engine is stopped, one request at a time)
			local now = gameTime()
			if G.stepTarget and (now >= G.stepTarget or G.frames - G.stepSince > 120) then G.stepTarget = nil end
			if sp == 0 and G.wantSteps and G.wantSteps > 0 and not G.stepTarget and gameSpeed() == 0 then
				G.stepTarget, G.stepSince = now + G.wantSteps * STEP, G.frames
				O.sendCommand(O.steps(G.wantSteps))
			end
		end
		-- stamp distance = barrier window + overshoot reserve + 1. The engine runs the simulation on its own thread,
		-- driven by real time: a game passes a stop point by what it simulates before its interface reacts (a frame,
		-- or a hiccup of a few hundred milliseconds). The reserve covers about half a second of simulation.
		local spd = math.max(1, math.min(4, G.session.speed or 1))
		G.window = spd + 2
		G.ahead = G.window + (2 * spd + 1) + 1
		local okt, t = pcall(gameTime)
		if okt and (t ~= G.lastClock or G.frames % 30 == 0) then
			G.lastClock = t
			G.stampFloor = math.max(G.stampFloor, t + G.ahead * STEP)
			send("clock", { t = t, sp = gameSpeed(), ah = G.ahead })
		end
	end

	-- bindings, results and hashes produced by the simulation half
	for key, e in pairs(st.bind or {}) do
		if G.bind[key] ~= e then
			G.bind[key] = e
			G.rev[e] = key
			C.appendFile(C.DIR .. BS .. "bindings.log", key .. " " .. tostring(e) .. NL)
		end
	end
	if type(st.hash) == "table" and st.hash.n ~= G.hashSent then
		G.hashSent = st.hash.n
		send("sync_hash", { n = st.hash.n, parts = st.hash.parts, cost = st.hash.cost, auth = st.hash.auth })
	end
	for _, r in ipairs(st.results or {}) do
		local key = tostring(r.uid) .. "@" .. tostring(r.at)
		if not G.resultsSeen[key] then
			G.resultsSeen[key] = true
			C.appendFile(C.DIR .. BS .. "results.log", C.line("result", r))
			if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
		end
	end

	if #G.waits > 0 then
		local current = G.waits
		G.waits = {}
		for _, w in ipairs(current) do
			if G.frames >= w.at then
				local ok, err = pcall(w.fn)
				if not ok then log("deferred action failed: " .. tostring(err)) end
			else
				G.waits[#G.waits + 1] = w
			end
		end
	end
end

local function guiHandleEvent(userParams, state, guiState, src, id, name, param)
	if not C.ACTIVE then return end
	if type(name) == "string" and name:find("^builder%.") then
		G.evSeen = G.evSeen or {}
		local key = tostring(id) .. "/" .. name
		if not G.evSeen[key] then G.evSeen[key] = true; log("tool event: " .. key) end
	end
end

function data()
	return {
		update = update,
		handleEvent = handleEvent,
		guiUpdate = guiUpdate,
		guiHandleEvent = guiHandleEvent,
	}
end
