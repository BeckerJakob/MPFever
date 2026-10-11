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
			U.notifLogged = (U.notifLogged or 0) + 1
			if U.notifLogged <= 40 then log("local notification event " .. tostring(tag.args[1]) .. "/" .. tostring(tag.args[3]) .. " " .. C.ser(C.marshal(tag.args[4])):sub(1, 200)) end
			if os.getenv("MPFEVER_NONOTIF") then return end
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
	end, log)
	CO.patchPermits(req, log)
end
local function pollCompanies()
	local f = C.IO.open(C.DIR .. C.BS .. "companies.txt", "rb")
	if not f then return end
	local txt = f:read("*a") or ""
	f:close()
	if txt == U.coTxt then return end
	U.coTxt = txt
	local map, names = {}, {}
	for line in txt:gmatch("[^" .. C.NL .. "]+") do
		local a, b, n = line:match("^(%d+)" .. C.TAB .. "(%d+)" .. C.TAB .. "?([^" .. C.TAB .. "]*)")
		if a then map[tonumber(b)] = tonumber(a); names[tonumber(b)] = n end
		local me = line:match("^me" .. C.TAB .. "(%d+)")
		if me then U.myCo = tonumber(me) end
	end
	U.coMap = map
	U.coNames = names
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
	local fee = U.shares and U.shares[key] or nil
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

-- The line tool lets a company pick only its own stations (entity_util.isOwnedByPlayerOrNotOwned): a station another company
-- shares (shares.txt) can be picked too. The fee is booked by the game-script bridge at every stop.
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
		if not U.shares or next(U.shares) == nil or type(entity) ~= "number" then return false end
		local now = os.clock()
		if now - cacheAt > 1 then cache = {}; cacheAt = now end
		local v = cache[entity]
		if v == nil then
			v = false
			local sg = sharedGroupOf(entity)
			if sg then
				local okk, key = pcall(R.sgKey, sg)
				local fee = okk and key and U.shares[key] or nil
				v = fee ~= nil and fee > 0
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

-- a player's line: name, (you), host, its state; and the colour class
local function playerLine(pl, me)
	local text = pl.name
	if pl.id == me then text = text .. T(" (vous)", " (you)") end
	if pl.role == "host" then text = text .. "  –  " .. T("hôte", "host") end
	local state, cls = (PLAYER_STATES[pl.state] or PLAYER_STATES.ok)(pl)
	return text .. "  ·  " .. state, cls
end

-- the players still in the session (those who left are listed too, for a while)
local function playerCount(st)
	local n = 0
	for _, pl in ipairs(st and st.players or {}) do if pl.state ~= "left" then n = n + 1 end end
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

-- re-renders its recipe when the status changes, and once more when it gets old
local function useStatus(react)
	local key = function() return tostring(U.statusVersion or 0) .. (statusStale(U.status) and "s" or "") end
	local ver = react.useState(key())
	react.onStepTimer(function()
		local k = key()
		if ver:old() ~= k then ver:set(k) end
	end, 0.5)
	return U.status
end

local function installSession(react, builtin)
	if U.sessionInstalled then return end
	U.sessionInstalled = true
	local V, H = builtin.type.Orientation.Vertical, builtin.type.Orientation.Horizontal
	local WIDTH = 460
	local function text(t, class, cls)
		return builtin.TextView { meta = { class = (class or "font-scale-body") .. (cls and (", " .. cls) or "") }, text = t, width = WIDTH }
	end

	-- MPFever's window: stays open while playing, can be moved and closed
	U.SessionWindow = react.RegisterWrapperRecipe("MPFeverSessionWindow", builtin.Window, function(wp)
		local st = useStatus(react)
		local rows = {}
		if st and st.host then
			rows[#rows + 1] = text(C.Tf("Hôte : %s", "Host: %s", st.host) .. "  ·  "
				.. (st.mode == "separate" and T("Une entreprise par joueur", "One company per player") or T("Une entreprise pour tous", "One company for everybody")))
		end
		local link, linkCls = linkLine(st)
		if link then rows[#rows + 1] = text(link, nil, linkCls) end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = text(T("Synchronisation", "Sync"), "font-scale-title-4")
		local sync, syncCls = syncLine(st)
		rows[#rows + 1] = text(sync, nil, syncCls)
		local desyncs = tonumber(st and st.desyncs) or 0
		if desyncs > 0 then rows[#rows + 1] = text(C.Tf("%s désynchronisation(s) depuis le début", "%s desync(s) since the start", desyncs)) end
		rows[#rows + 1] = text(" ")
		rows[#rows + 1] = text(T("Joueurs", "Players") .. "  (" .. playerCount(st) .. ")", "font-scale-title-4")
		for _, pl in ipairs(st and st.players or {}) do
			local line, cls = playerLine(pl, st.me)
			rows[#rows + 1] = text(line, nil, cls)
		end
		if st and st.invite == "1" and st.me and st.players then
			local host = false
			for _, pl in ipairs(st.players) do if pl.id == st.me and pl.role == "host" then host = true end end
			if host then
				rows[#rows + 1] = text(" ")
				rows[#rows + 1] = builtin.Button { meta = { class = "secondary" }, content = text(T("Inviter des amis Steam", "Invite Steam friends")), onClick = requestInvite }
			end
		end
		return builtin.Window {
			title = "MPFever – " .. T("Multijoueur", "Multiplayer"),
			id = "window.mpfever.session",
			initialX = 0.85,
			initialY = 0.3,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			content = builtin.Component { layout = builtin.BoxLayout { orientation = V, children = rows } },
		}
	end)

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

	-- the card in the pause menu: a summary, and a click opens the window
	local Card = react.RegisterRecipe("MPFeverPauseCard", function(p)
		local st = useStatus(react)
		local sync, syncCls = syncLine(st)
		local link, linkCls = linkLine(st)
		local lines = {
			text("MPFever  –  " .. T("Multijoueur", "Multiplayer"), "font-scale-title-4"),
			text(link or sync, nil, link and linkCls or syncCls),
			text(C.Tf("%s joueur(s) dans la partie", "%s player(s) in the game", playerCount(st))),
			text(T("Afficher pendant la partie  ›", "Show while playing  ›"), nil, "info"),
		}
		-- a recipe's result must be a layout (the game refuses a bare button here)
		return builtin.BoxLayout { children = {
			builtin.Button {
				meta = { class = "secondary" },
				content = builtin.Component { layout = builtin.BoxLayout { orientation = V, children = lines } },
				onClick = function() openSession(p.commonParams) end,
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
				builtin.FloatingLayoutChild { h = 0.97, v = 0.5, item = Card { commonParams = params and params.commonParams } },
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
	pcall(pollShares)
	if U.coMap and not U.shareSelectInstalled then
		local oks, errs = pcall(installShareSelect)
		if not oks then U.shareSelectInstalled = true; log("companies: share pick not installed: " .. tostring(errs)) end
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
				log("selftest window of " .. tostring(e) .. ": recipe " .. tostring(r.recipe) .. ", owner '" .. tostring(p.ownerText) .. "', share '" .. tostring(p.shareText) .. "' edit " .. tostring(p.shareEdit) .. " key " .. tostring(p.shareKey) .. " pickable " .. tostring(pick))
			else
				log("selftest window of " .. tostring(e) .. ": " .. tostring(r):sub(1, 200))
			end
			end
		end
	end
	pcall(pollLoanView)
	pcall(pollStatus)
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
