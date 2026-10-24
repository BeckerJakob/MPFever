-- MPFever companies' economy (0.5.0), in the "one company per player" mode: several players in a company (mixed modes),
-- joining, leaving and merging companies, bankruptcy with an auction of the bankrupt company's assets, and the owners' rules
-- for their tracks and depots (private, open, open with a toll).
--
-- Everything here runs in the simulation half of the bridge, on every game at the same game time, from the state saved with
-- the game (the companies registry st.co, see mpfever_co.lua) and the stamped events of the players (handleEvent "mpfever"):
--
--   co_rules        {bankrupt}           the host's rules: months in debt before a bankruptcy (0: never)
--   co_join_ask     {to}                 a player asks to join company `to`
--   co_join_answer  {key, accept}        the chief of the company asked answers
--   co_leave        {}                   a player leaves its company (it gets a new one: see the bridge's coGui)
--   co_cancel       {}                   a player takes its requests back
--   co_merge_ask    {to}                 a chief offers to merge its company into company `to`
--   co_merge_answer {from, accept}       the chief of `to` answers: everything of `from` becomes its company's
--   co_bid          {seq, lot, amount}   a bid at the auction of a bankrupt company
--   co_lot_close    {seq, lot}           the host closes the lot under the hammer (a minute after it opened, see coGui)
--   co_month        {month, debt}        the host's look at a new month: the companies in debt (their money below zero on the
--                                        host's game, which every game's money follows: a game's own balance may lag a step)
--   co_track_rule   {rule, toll}         a company's rule for its tracks: "private", "open", "toll"
--   co_depot_rule   {key, rule, toll}    a company's rule for one of its depots
--
-- param.mpfCo is the sender's company and param.mpfFrom the sender (its name, "#n" for a player who joined), both added by the
-- bridge when the event is applied. What happens in the game's world (owners, money, demolitions) goes through commands sent from
-- here: every game sends the same at the same step. env = { log, CO, R, STEP }.

local E = {}

E.EVENTS = {
	co_rules = true, co_join_ask = true, co_join_answer = true, co_leave = true, co_cancel = true, co_merge_ask = true,
	co_merge_answer = true, co_bid = true, co_lot_close = true, co_track_rule = true, co_depot_rule = true, co_test = true, co_month = true,
}
E.BANKRUPT_DEFAULT = 12        -- months in debt
E.BANKRUPT_CHOICES = { 0, 3, 6, 12, 24 }
E.LOT_SECONDS = tonumber(os.getenv("MPFEVER_LOTSECONDS") or "") or 60   -- a lot stays open that long (real time, on the host)
E.LAST_BID_SECONDS = math.min(15, E.LOT_SECONDS)                         -- and that long after its last bid
E.MIN_RAISE = 0.05             -- a bid beats the best one by 5 % at least
E.TOLL_DEFAULT = 1000
E.RESERVE = { line = 50000, vehicle = 50000, station = 100000, depot = 50000 }

-- (the game time and the bridge's helpers, given by the bridge at every call: see E.event and E.tick)
E.env = nil
local function gt() return E.env.gameTime() end

local function keyOf(origin)
	local plain = tostring(origin or ""):gsub("#.*$", "")
	return plain:lower(), plain
end

-- a host (or a dedicated server) sends its events under its plain name; a player who joined has "#n" after it
local function fromHost(origin)
	return type(origin) == "string" and origin ~= "" and not origin:find("#", 1, true)
end

local function balanceOf(ent)
	local ok, b = pcall(api.engine.util.finance.getPlayersBalance, ent)
	return (ok and type(b) == "number") and b or nil
end

local function book(ent, amount, fill)
	if not ent or amount == 0 then return end
	local e = api.type.JournalEntry.new()
	e.amount = math.floor(amount + 0.5)
	e.time = -1
	local ok = pcall(fill or function(x) x.category.type = api.type.JournalEntry.Type.OTHER end, e)
	if not ok then e.category.type = api.type.JournalEntry.Type.OTHER end
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(ent, e, api.type.Vec3f.new(0, 0, 0)))
end

-- what happened, for the players (the host's game tells it in the chat, see the bridge's coGui): reg.news, the last 30
local function news(reg, t)
	reg.newsSeq = (reg.newsSeq or 0) + 1
	t.n = reg.newsSeq
	t.at = gt()
	reg.news = reg.news or {}
	reg.news[#reg.news + 1] = t
	while #reg.news > 30 do table.remove(reg.news, 1) end
end

local function live(c) return c and not c.gone end

-- ---------------------------------------------------------------- what a company owns
-- every entity a player entity owns (PlayerOwned), sorted (the same set on every game; the ids may differ)
function E.ownedBy(env, ent)
	local out, seen = {}, {}
	local function add(e) if type(e) == "number" and e >= 0 and not seen[e] then seen[e] = true; out[#out + 1] = e end end
	local ok = pcall(function()
		api.engine.forEachEntityWithComponent(function(e)
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			if po and po.player == ent then add(e) end
		end, api.type.ComponentType.PLAYER_OWNED)
	end)
	if not ok or #out == 0 then
		-- (the engine refused the loop: what the checks count, piece by piece)
		local function owned(e)
			local okc, po = pcall(api.engine.getComponent, e, api.type.ComponentType.PLAYER_OWNED)
			return okc and po and po.player == ent
		end
		for _, e in ipairs(env.R.allEdges()) do if owned(e) then add(e) end end
		for _, e in ipairs(env.R.entitiesWith("CONSTRUCTION")) do if owned(e) then add(e) end end
		pcall(function() for _, v in ipairs(api.engine.system.transportVehicleSystem.getVehiclesForPlayer(ent)) do add(v) end end)
	end
	pcall(function() for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(ent)) do add(l) end end)
	table.sort(out)
	return out
end

function E.hasAssets(env, c)
	if not (c and c.ent) then return false end
	local n = 0
	pcall(function() n = n + #api.engine.system.lineSystem.getLinesForPlayer(c.ent) end)
	pcall(function() n = n + #api.engine.system.transportVehicleSystem.getVehiclesForPlayer(c.ent) end)
	if n > 0 then return true end
	return #E.ownedBy(env, c.ent) > 0
end

-- the entities of `list` that `from` owns become `to`'s (the others are left alone: an entity without an owner has none)
local function setOwner(list, from, to)
	local n = 0
	for _, e in ipairs(list) do
		local okc, po = pcall(api.engine.getComponent, e, api.type.ComponentType.PLAYER_OWNED)
		if okc and po and po.player == from then
			local ok = pcall(function() api.cmd.sendCommand(api.cmd.makeEntitySetPlayerCmd(e, to)) end)
			if ok then n = n + 1 end
		end
	end
	return n
end

local function nameOf(e)
	local ok, n = pcall(function() return api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
	return (ok and type(n) == "string") and n or tostring(e)
end

-- ---------------------------------------------------------------- the lots of a bankrupt company
-- Lots: each line with its vehicles, each station, each depot with the vehicles in it. Known by keys that are the same on every
-- game (the line's name and stops, the station's key, the depot's construction and place), sorted by them.
local function lineKey(env, line)
	local parts = {}
	pcall(function()
		local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
		for i = 1, #lc.stops do parts[#parts + 1] = env.R.sgKey(lc.stops[i].stationGroup) end
	end)
	return "L:" .. nameOf(line) .. "|" .. table.concat(parts, ";")
end

local function depotKey(con)
	local ok, k = pcall(function()
		local c = api.engine.getComponent(con, api.type.ComponentType.CONSTRUCTION)
		local t = c.transf
		return "D:" .. tostring(c.fileName) .. "@" .. string.format("%.0f,%.0f", t[13], t[14])
	end)
	return ok and k or ("D:" .. tostring(con))
end
E.depotKey = depotKey

-- the construction of a depot entity (or the depot's construction itself)
function E.depotCon(depot)
	local ok, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForDepot, depot)
	if ok and type(con) == "number" and con >= 0 then return con end
	return depot
end

local function stationEntities(env, sg)
	local out = { sg }
	pcall(function()
		local g = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)
		for i = 1, #g.stations do
			local st = g.stations[i]
			out[#out + 1] = st
			local okc, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForStation, st)
			if okc and type(con) == "number" and con >= 0 then out[#out + 1] = con end
		end
	end)
	return out
end

local function depotsOf(env, ent)
	local out = {}
	for _, e in ipairs(env.R.withoutAssets(env.R.entitiesWith("CONSTRUCTION"))) do
		local ok, isMine = pcall(function()
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			if not (c and c.depots and #c.depots > 0) then return false end
			local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
			return po and po.player == ent
		end)
		if ok and isMine then out[#out + 1] = e end
	end
	return out
end

local function stationsOf(env, ent)
	local out = {}
	for _, sg in ipairs(env.R.entitiesWith("STATION_GROUP")) do
		if env.R.ownerOf(sg) == ent then out[#out + 1] = sg end
	end
	return out
end

function E.lotsOf(env, c)
	local lines, stations, depots = {}, {}, {}
	pcall(function()
		for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do
			local nv = 0
			pcall(function() nv = #api.engine.system.transportVehicleSystem.getLineVehicles(l) end)
			lines[#lines + 1] = { kind = "line", key = lineKey(env, l), label = nameOf(l), vehicles = nv,
				reserve = math.max(E.RESERVE.line, nv * E.RESERVE.vehicle) }
		end
	end)
	for _, sg in ipairs(stationsOf(env, c.ent)) do
		stations[#stations + 1] = { kind = "station", key = env.R.sgKey(sg), label = nameOf(sg), reserve = E.RESERVE.station }
	end
	for _, d in ipairs(depotsOf(env, c.ent)) do
		depots[#depots + 1] = { kind = "depot", key = depotKey(d), label = nameOf(d), reserve = E.RESERVE.depot }
	end
	local function byKey(a, b) return a.key < b.key end
	table.sort(lines, byKey)
	table.sort(stations, byKey)
	table.sort(depots, byKey)
	local lots = {}
	for _, t in ipairs({ lines, stations, depots }) do for _, l in ipairs(t) do lots[#lots + 1] = l end end
	return lots
end

-- the entities of a lot in this game, found again by its key
local function lotEntities(env, c, lot)
	local ents, vehicles, cons = {}, {}, {}
	if lot.kind == "line" then
		pcall(function()
			for _, l in ipairs(api.engine.system.lineSystem.getLinesForPlayer(c.ent)) do
				if lineKey(env, l) == lot.key then
					ents[#ents + 1] = l
					for _, v in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(l)) do vehicles[#vehicles + 1] = v end
					break
				end
			end
		end)
	elseif lot.kind == "station" then
		for _, sg in ipairs(stationsOf(env, c.ent)) do
			if env.R.sgKey(sg) == lot.key then
				for _, e in ipairs(stationEntities(env, sg)) do
					ents[#ents + 1] = e
					local okc, cc = pcall(api.engine.getComponent, e, api.type.ComponentType.CONSTRUCTION)
					if okc and cc then cons[#cons + 1] = e end
				end
				break
			end
		end
	elseif lot.kind == "depot" then
		for _, d in ipairs(depotsOf(env, c.ent)) do
			if depotKey(d) == lot.key then
				ents[#ents + 1] = d
				cons[#cons + 1] = d
				pcall(function()
					local cc = api.engine.getComponent(d, api.type.ComponentType.CONSTRUCTION)
					for i = 1, #cc.depots do
						ents[#ents + 1] = cc.depots[i]
						for _, v in ipairs(api.engine.system.transportVehicleSystem.getDepotVehicles(cc.depots[i])) do vehicles[#vehicles + 1] = v end
					end
				end)
				break
			end
		end
	end
	return ents, vehicles, cons
end

-- what nobody bought goes: the vehicles sold, the line removed, the station or depot demolished (a construction the engine
-- refuses to remove stays, with no player of its own: see E.openOwners)
local function demolish(env, c, lot)
	local ents, vehicles, cons = lotEntities(env, c, lot)
	for _, v in ipairs(vehicles) do pcall(function() api.cmd.sendCommand(api.cmd.makeVehicleSellCmd({ v })) end) end
	if lot.kind == "line" then
		for _, l in ipairs(ents) do pcall(function() api.cmd.sendCommand(api.cmd.makeLineDestroyCmd(l)) end) end
	elseif #cons > 0 then
		pcall(function()
			local sp = api.type.SimpleProposal.new()
			sp.constructionsToRemove = cons
			local ctx = api.type.Context.new()
			ctx.player = c.ent
			ctx.checkTerrainAlignment = false
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, true, false))
		end)
	end
	env.log("companies: auction: lot '" .. tostring(lot.label) .. "' (" .. lot.kind .. ") of company " .. c.id .. " unsold: "
		.. #vehicles .. " vehicle(s) sold, " .. #cons .. " construction(s) demolished")
end

local function sell(env, c, lot, winner, amount)
	local ents, vehicles = lotEntities(env, c, lot)
	local all = {}
	for _, e in ipairs(ents) do all[#all + 1] = e end
	for _, v in ipairs(vehicles) do all[#all + 1] = v end
	local n = setOwner(all, c.ent, winner.ent)
	book(winner.ent, -amount, function(x) x.category.type = api.type.JournalEntry.Type.ACQUISITION end)
	env.log("companies: auction: lot '" .. tostring(lot.label) .. "' (" .. lot.kind .. ") of company " .. c.id .. " sold to company "
		.. winner.id .. " for " .. amount .. " (" .. n .. " entities change hands)")
end

-- ---------------------------------------------------------------- bankruptcy
function E.bankrupt(st, c, env, maxLots)
	local reg = st.co
	c.gone = "bankrupt"
	c.debt = nil
	local mem = env.CO.ensureMembers(c)
	local names = {}
	for _, m in ipairs(mem) do names[#names + 1] = m.key end
	c.formerMembers = names
	c.members = {}
	c.chief = nil
	local lots = E.lotsOf(env, c)
	-- (autotests: the first lots only)
	if maxLots then while #lots > maxLots do table.remove(lots) end end
	reg.auctionSeq = (reg.auctionSeq or 0) + 1
	reg.auction = { seq = reg.auctionSeq, co = c.id, lots = lots, idx = 1, openAt = gt() }
	news(reg, { kind = "bankrupt", co = c.id, lots = #lots })
	env.log("companies: company " .. c.id .. " is BANKRUPT (in debt for " .. tostring((reg.rules or {}).bankrupt or E.BANKRUPT_DEFAULT)
		.. " months): " .. #lots .. " lot(s) at auction; its players get a new company")
	if #lots == 0 then E.finishAuction(st, env) end
end

function E.finishAuction(st, env)
	local reg = st.co
	local au = reg.auction
	if not au then return end
	news(reg, { kind = "auction_end", co = au.co })
	env.log("companies: auction of company " .. tostring(au.co) .. " finished")
	reg.auction = nil
end

local function closeLot(st, env)
	local reg = st.co
	local au = reg.auction
	local c = env.CO.find(reg, au.co)
	local lot = au.lots[au.idx]
	if c and c.ent and lot then
		local w = au.bidder and env.CO.find(reg, au.bidder) or nil
		-- (the best bidder merged meanwhile: the company it went into keeps its bid)
		if w and w.gone == "merged" and w.mergedInto then w = env.CO.find(reg, w.mergedInto) end
		if w and live(w) and w.ent then
			sell(env, c, lot, w, au.best)
			news(reg, { kind = "lot_sold", co = au.co, lot = au.idx, label = lot.label, to = w.id, amount = au.best })
		else
			demolish(env, c, lot)
			news(reg, { kind = "lot_unsold", co = au.co, lot = au.idx, label = lot.label })
		end
	end
	au.best, au.bidder, au.lastBidAt = nil, nil, nil
	au.idx = au.idx + 1
	au.openAt = gt()
	if au.idx > #au.lots then E.finishAuction(st, env) end
end

-- ---------------------------------------------------------------- the monthly look, the tolls
-- Every step (from the bridge's update). At each new game month: each playing company's months in debt (money below zero at the
-- month's turn; back to 0 when it is not), and a bankruptcy when they reach the host's rule. Returns whether the state changed.
function E.tick(st, env)
	E.env = env
	local reg = st.co
	if not (reg and reg.mode == "separate") then return false end
	local changed = false
	local okM, monthDur = pcall(api.util.getDefaultMonthDuration)
	if okM and type(monthDur) == "number" and monthDur > 0 then
		local m = math.floor(gt() / monthDur)
		if reg.month == nil then
			-- (the month the companies mode starts in is not counted)
			reg.month = m
			reg.monthSeen = m
			changed = true
		elseif m > reg.month then
			-- (the months in debt are counted when the host's look at this month arrives: see co_month)
			reg.month = m
			changed = true
		end
	end
	local okT, ch = pcall(E.tolls, st, env)
	if okT and ch then changed = true elseif not okT then env.log("companies: tolls failed: " .. tostring(ch)) end
	return changed
end

-- the rule of a company for its tracks: { rule = "private" | "open" | "toll", toll = n }; a gone company's tracks are open
function E.trackRule(reg, c)
	if not c then return { rule = "private" } end
	if c.gone then return { rule = "open" } end
	local r = reg.track and reg.track[tostring(c.id)]
	return r or { rule = "private" }
end

-- the rule of a depot (its key, see depotKey): the same three; private when nothing was set
function E.depotRule(reg, key)
	local r = reg and reg.depots and reg.depots[key]
	return r or { rule = "private" }
end

-- Tolls: a train of a company that enters the tracks of a company whose rule is "toll" pays that company the toll, once each time it
-- enters them (every 5 steps: each line vehicle's present segment). Booked as for the shared stations: track upkeep of the
-- carrier for the train's company, revenue for the tracks' company.
function E.tolls(st, env)
	local reg = st.co
	local stepNo = math.floor(gt() / env.STEP + 0.5)
	if stepNo % 5 ~= 0 then return false end
	local tollOf = {}
	local any = false
	for _, c in ipairs(reg.list) do
		local r = E.trackRule(reg, c)
		if c.ent and r.rule == "toll" and (tonumber(r.toll) or 0) > 0 then tollOf[c.ent] = { co = c.id, toll = math.floor(tonumber(r.toll)) }; any = true end
	end
	if not any then
		if reg.tollOn then reg.tollOn = nil; return true end
		return false
	end
	local ownerCache = {}
	local function ownerOfEdge(e)
		local o = ownerCache[e]
		if o == nil then
			o = false
			pcall(function()
				if api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_TRACK) then
					local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED)
					if po then o = po.player end
				end
			end)
			ownerCache[e] = o
		end
		return o
	end
	local was = reg.tollOn or {}
	local now = {}
	local owed = {}
	for _, c in ipairs(reg.list) do
		if c.ent then
			local okL, lines = pcall(api.engine.system.lineSystem.getLinesForPlayer, c.ent)
			for _, l in ipairs(okL and lines or {}) do
				local okV, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, l)
				for _, v in ipairs(okV and vehicles or {}) do
					local edge = nil
					pcall(function()
						local mp = api.engine.getComponent(v, api.type.ComponentType.MOVE_PATH)
						edge = mp.path.edges[mp.dyn.pathPos.edgeIndex + 1].edgeId.entity
					end)
					local o = type(edge) == "number" and ownerOfEdge(edge) or false
					local t = o and tollOf[o] or nil
					if t and t.co ~= c.id then
						local k = tostring(v)
						now[k] = t.co
						if was[k] ~= t.co then
							local carrier = nil
							pcall(function() carrier = env.journalCarrier(api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE).carrier) end)
							owed[#owed + 1] = { from = c, to = t.co, fee = t.toll, carrier = carrier }
						end
					end
				end
			end
		end
	end
	reg.tollOn = next(now) and now or nil
	if #owed == 0 then return true end
	local JE = api.type.JournalEntry
	reg.tollIncome = reg.tollIncome or {}
	reg.tollExpense = reg.tollExpense or {}
	for _, o in ipairs(owed) do
		local to = env.CO.find(reg, o.to)
		if to and to.ent and o.from.ent then
			book(o.from.ent, -o.fee, function(x)
				x.category.type = JE.Type.MAINTENANCE
				x.category.maintenance = JE.Maintenance.INFRASTRUCTURE
				x.category.construction = JE.Construction.TRACK
				x.category.carrier = o.carrier or JE.Carrier.RAIL
			end)
			book(to.ent, o.fee, function(x)
				x.category.type = JE.Type.INCOME
				x.category.carrier = o.carrier or JE.Carrier.RAIL
			end)
			reg.tollIncome[tostring(o.to)] = (reg.tollIncome[tostring(o.to)] or 0) + o.fee
			reg.tollExpense[tostring(o.from.id)] = (reg.tollExpense[tostring(o.from.id)] or 0) + o.fee
		end
	end
	E.tollLogged = (E.tollLogged or 0) + 1
	if E.tollLogged <= 20 then env.log("companies: tolls: " .. #owed .. " train(s) entered another company's tracks") end
	return true
end

-- a vehicle bought in (or sent to) another company's depot: allowed when that depot is open; returns allowed, toll
function E.depotUse(reg, env, depot, co)
	local con = E.depotCon(depot)
	local r = E.depotRule(reg, depotKey(con))
	if r.rule == "open" then return true, 0 end
	if r.rule == "toll" then return true, math.max(0, math.floor(tonumber(r.toll) or E.TOLL_DEFAULT)) end
	return false, 0
end

-- ---------------------------------------------------------------- merging
function E.merge(st, a, b, env)
	local reg = st.co
	local list = E.ownedBy(env, a.ent)
	local n = setOwner(list, a.ent, b.ent)
	local bal = balanceOf(a.ent) or 0
	if bal ~= 0 then
		book(a.ent, -bal)
		book(b.ent, bal)
	end
	-- (the loans of a company other than the savegame's follow it: the merged company pays them from now on)
	local la = reg.loan and reg.loan[a.id]
	if la and la.obtainedLoans and #la.obtainedLoans > 0 then
		if b.ent ~= reg.canon and env.loanTable then
			local lb = env.loanTable(st, b.id)
			for _, loan in ipairs(la.obtainedLoans) do
				loan.id = lb.freeId
				lb.freeId = lb.freeId + 1
				lb.obtainedLoans[#lb.obtainedLoans + 1] = loan
			end
		elseif env.payBack then
			-- (into the savegame's company, whose loans are the game's own: paid back at once)
			local sum = 0
			for _, loan in ipairs(la.obtainedLoans) do sum = sum + (env.payBack(loan) or 0) end
			book(b.ent, -sum, function(x) x.category.type = api.type.JournalEntry.Type.LOAN end)
		end
		la.obtainedLoans = {}
	end
	for _, m in ipairs(env.CO.ensureMembers(a)) do env.CO.addMember(b, m.key, m.sid) end
	a.members = {}
	a.chief = nil
	a.gone = "merged"
	a.mergedInto = b.id
	if reg.track then reg.track[tostring(a.id)] = nil end
	news(reg, { kind = "merged", co = a.id, into = b.id })
	env.log("companies: company " .. a.id .. " merged into company " .. b.id .. ": " .. n .. " entities and " .. bal .. " money change hands")
end

-- ---------------------------------------------------------------- the players' events
local function dropRequests(reg, key)
	local keep = {}
	for _, r in ipairs(reg.requests or {}) do if r.key ~= key then keep[#keep + 1] = r end end
	reg.requests = keep
end

local function dropOffers(reg, from)
	local keep = {}
	for _, o in ipairs(reg.mergeOffers or {}) do if o.from ~= from then keep[#keep + 1] = o end end
	reg.mergeOffers = keep
end

-- a player goes into company t (from the company it played, which keeps running without it; an empty one, nothing built and
-- nobody else in it, is gone)
local function moveMember(st, key, t, env)
	local reg = st.co
	local cur = env.CO.memberOf(reg, key)
	local sid = nil
	if cur then
		local m = env.CO.removeMember(cur, key)
		sid = m and m.sid
		if #env.CO.members(cur) == 0 and not E.hasAssets(env, cur) then
			cur.gone = "empty"
			dropOffers(reg, cur.id)
		end
	end
	env.CO.addMember(t, key, sid)
	dropRequests(reg, key)
	news(reg, { kind = "joined", key = key, co = t.id, from = cur and cur.id or nil })
	env.log("companies: player '" .. key .. "' joins company " .. t.id .. (cur and (" (leaves company " .. cur.id .. ")") or ""))
end

function E.event(st, name, param, env)
	E.env = env
	local reg = st.co
	if not (reg and reg.mode == "separate") then return end
	param = type(param) == "table" and param or {}
	local key, plain = keyOf(param.mpfFrom)
	local mine = tonumber(param.mpfCo) and env.CO.find(reg, tonumber(param.mpfCo)) or nil
	local function refuse(why) env.log("companies: " .. name .. " of '" .. tostring(param.mpfFrom) .. "' refused: " .. why) end
	if name == "co_rules" then
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local b = tonumber(param.bankrupt)
		local ok = false
		for _, x in ipairs(E.BANKRUPT_CHOICES) do if b == x then ok = true end end
		if not ok then return refuse("months " .. tostring(param.bankrupt)) end
		reg.rules = reg.rules or {}
		reg.rules.bankrupt = b
		env.log("companies: rules: bankruptcy after " .. b .. " month(s) in debt" .. (b == 0 and " (never)" or ""))
	elseif name == "co_join_ask" then
		local t = env.CO.find(reg, tonumber(param.to))
		local cur = env.CO.memberOf(reg, key)
		if key == "" or not live(t) then return refuse("no such company") end
		if cur and cur.id == t.id then return refuse("already in it") end
		dropRequests(reg, key)
		reg.requests[#reg.requests + 1] = { key = key, name = plain, to = t.id, at = gt() }
		news(reg, { kind = "ask", key = key, name = plain, co = t.id })
		env.log("companies: '" .. key .. "' asks to join company " .. t.id)
	elseif name == "co_cancel" then
		-- (the request to join, or the merger offered, as asked: both when nothing says which)
		if param.what ~= "merge" then dropRequests(reg, key) end
		if param.what ~= "join" and mine and env.CO.chief(mine) == key then dropOffers(reg, mine.id) end
	elseif name == "co_join_answer" then
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not the chief of company " .. tostring(param.mpfCo)) end
		local found = nil
		for _, r in ipairs(reg.requests or {}) do if r.key == param.key and r.to == mine.id then found = r end end
		if not found then return refuse("no such request") end
		if param.accept then moveMember(st, found.key, mine, env)
		else
			dropRequests(reg, found.key)
			news(reg, { kind = "refused", key = found.key, co = mine.id })
		end
	elseif name == "co_leave" then
		if not live(mine) then return refuse("no company") end
		local cur = env.CO.memberOf(reg, key)
		if not cur or cur.id ~= mine.id then return refuse("not a member") end
		if #env.CO.members(cur) <= 1 then return refuse("alone in it") end
		env.CO.removeMember(cur, key)
		cur.left = cur.left or {}
		cur.left[key] = true
		news(reg, { kind = "left", key = key, co = cur.id })
		env.log("companies: player '" .. key .. "' leaves company " .. cur.id .. " (it gets a new one)")
	elseif name == "co_merge_ask" then
		local t = env.CO.find(reg, tonumber(param.to))
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not a chief") end
		if not live(t) or t.id == mine.id then return refuse("no such company") end
		dropOffers(reg, mine.id)
		reg.mergeOffers[#reg.mergeOffers + 1] = { from = mine.id, to = t.id, at = gt() }
		news(reg, { kind = "merge_ask", co = mine.id, to = t.id })
		env.log("companies: company " .. mine.id .. " offers to merge into company " .. t.id)
	elseif name == "co_merge_answer" then
		if not (live(mine) and env.CO.chief(mine) == key) then return refuse("not a chief") end
		local from = env.CO.find(reg, tonumber(param.from))
		local found = false
		for _, o in ipairs(reg.mergeOffers or {}) do if o.from == tonumber(param.from) and o.to == mine.id then found = true end end
		if not (found and live(from) and from.ent and mine.ent) then return refuse("no such offer") end
		dropOffers(reg, from.id)
		if param.accept then E.merge(st, from, mine, env)
		else news(reg, { kind = "merge_refused", co = from.id, to = mine.id }) end
	elseif name == "co_bid" then
		local au = reg.auction
		if not (au and au.seq == tonumber(param.seq) and au.idx == tonumber(param.lot)) then return refuse("not the lot under the hammer") end
		if not (live(mine) and mine.ent) or mine.id == au.co then return refuse("company " .. tostring(param.mpfCo)) end
		local lot = au.lots[au.idx]
		local amount = math.floor(tonumber(param.amount) or 0)
		local min = math.max(lot.reserve or 0, au.best and math.ceil(au.best * (1 + E.MIN_RAISE)) or 0)
		if amount < min then return refuse("bid " .. amount .. " below " .. min) end
		-- (no balance read here: a game's own balance may lag a step behind the host's, and the bid would be taken on one
		-- game and refused on another. The interface offers only what the company has; a winner short of money is in debt)
		au.best, au.bidder, au.lastBidAt = amount, mine.id, gt()
		au.bids = (au.bids or 0) + 1
		news(reg, { kind = "bid", co = au.co, lot = au.idx, by = mine.id, amount = amount })
		env.log("companies: auction: company " .. mine.id .. " bids " .. amount .. " on lot " .. au.idx)
	elseif name == "co_lot_close" then
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local au = reg.auction
		if not (au and au.seq == tonumber(param.seq) and au.idx == tonumber(param.lot)) then return refuse("lot already closed") end
		closeLot(st, env)
	elseif name == "co_track_rule" then
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" then return refuse("rule " .. rule) end
		reg.track = reg.track or {}
		reg.track[tostring(mine.id)] = { rule = rule, toll = math.max(0, math.floor(tonumber(param.toll) or E.TOLL_DEFAULT)) }
		news(reg, { kind = "track_rule", co = mine.id, rule = rule, toll = reg.track[tostring(mine.id)].toll })
		env.log("companies: company " .. mine.id .. " tracks: " .. rule)
	elseif name == "co_month" then
		-- the host's look at a new month: each playing company in debt there one month more, the others none
		if not fromHost(param.mpfFrom) then return refuse("not the host") end
		local m = tonumber(param.month)
		if not m or m <= (reg.monthSeen or -1) then return refuse("month " .. tostring(param.month) .. " already seen") end
		reg.monthSeen = m
		local inDebt = {}
		for _, id in ipairs(type(param.debt) == "table" and param.debt or {}) do inDebt[tonumber(id) or -1] = true end
		local limit = tonumber((reg.rules or {}).bankrupt) or E.BANKRUPT_DEFAULT
		for _, c in ipairs(reg.list) do
			if live(c) and #env.CO.members(c) > 0 then
				if inDebt[c.id] then
					c.debt = (c.debt or 0) + 1
					news(reg, { kind = "debt", co = c.id, months = c.debt, limit = limit })
				else
					c.debt = nil
				end
			end
		end
		if limit > 0 and not reg.auction then
			for _, c in ipairs(reg.list) do
				if live(c) and (c.debt or 0) >= limit then E.bankrupt(st, c, env) break end
			end
		end
	elseif name == "co_test" then
		-- (autotests only, MPFEVER_SCENARIO set: a company goes bankrupt at once, with its first lots only)
		if not os.getenv("MPFEVER_SCENARIO") then return refuse("not a test") end
		local c = env.CO.find(reg, tonumber(param.co))
		if param.op == "bankrupt" and live(c) and not reg.auction then E.bankrupt(st, c, env, tonumber(param.maxLots)) end
		-- (a company spends all its money and 100000 more: the months in debt then count)
		if param.op == "broke" and live(c) and c.ent then book(c.ent, -((balanceOf(c.ent) or 0) + 100000)) end
	elseif name == "co_depot_rule" then
		if not live(mine) then return refuse("no company") end
		local rule = tostring(param.rule)
		if rule ~= "private" and rule ~= "open" and rule ~= "toll" then return refuse("rule " .. rule) end
		-- (only its own depots)
		local ownerOk = false
		for _, d in ipairs(depotsOf(env, mine.ent)) do if depotKey(d) == param.key then ownerOk = true end end
		if not ownerOk then return refuse("not its depot") end
		reg.depots = reg.depots or {}
		reg.depots[tostring(param.key)] = rule ~= "private" and { rule = rule, toll = math.max(0, math.floor(tonumber(param.toll) or E.TOLL_DEFAULT)), co = mine.id } or nil
		env.log("companies: company " .. mine.id .. " depot " .. tostring(param.key) .. ": " .. rule)
	end
end

return E
