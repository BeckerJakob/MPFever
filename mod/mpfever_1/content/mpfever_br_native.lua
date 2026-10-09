-- MPFever bridge: native deferral (builds held by the native module), terrain edits.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ================================================================== native deferral (with mpfever_native.dll)
-- The DLL holds a build issued by a UI tool and reports it in native_events.log. This game announces it to the others
-- (nat_pending: "a build of mine happens at T"), every game holds at T, this game releases the held command at T (its
-- simulation applies it then, the capture ships it), the others apply it while held at T: same step everywhere.
G.natOff = 0
G.natRelease = {}       -- this game's held builds: { id, at }
G.natWait = {}          -- builds announced by others: { origin, at, since }
G.natReleased = 0
G.natEnabled = false

function nativeCtl(line)
	LINK.nativeCtl(line)
end

function nativeHoldAt()
	local m = nil
	for _, r in ipairs(G.natRelease) do if m == nil or r.at < m then m = r.at end end
	for _, w in ipairs(G.natWait) do if m == nil or w.at < m then m = w.at end end
	-- other players' builds already received: this game must stop exactly at their time
	local now = gameTime()
	if (G.replayOut or 0) > 0 and G.frames - (G.replaySince or 0) > 600 then
		log("replay without engine answer for 600 frames: hold released")
		G.replayOut = 0
	end
	if (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0) or G.terrainBusy then return now end
	for _, a in ipairs(G.nativeQueue or {}) do if a.at > now and (m == nil or a.at < m) then m = a.at end end
	return m
end

H.nat_pending = function(from, p)
	if p.origin == G.me then return end
	logMargin("nat_pending", p.at, p.origin)
	G.natWait[#G.natWait + 1] = { origin = p.origin, id = p.id, at = p.at, since = G.frames }
	log("native build of " .. tostring(p.origin) .. " announced for t=" .. tostring(p.at) .. ": holding there")
end

-- While the build waits for its game time (about two seconds), a translucent circle on the ground where the player
-- clicked shows that it is on its way (no interface element: the world's own zone drawing). Removed once shipped.
G.pendingMarks = {}
function markPending(id, at)
	local ok, err = pcall(function()
		local pos = at
		if not pos then
			local m = api.gui.mouse
			if not (m and m.hasTerrainPosition and m.hasTerrainPosition()) then return end
			pos = m.getTerrainPosition()
		end
		api.gui.mission.setZoneCircle("mpfever_pending_" .. id, api.type.Vec2f.new(pos.x, pos.y), 14, true,
			api.type.Vec4f.new(1.0, 0.75, 0.1, 0.45), false, false)
		G.pendingMarks[id] = G.frames
	end)
	if not ok then log("pending mark failed: " .. tostring(err)) end
end

function refreshPendingMarks()
	if next(G.pendingMarks) == nil then return end
	local live = {}
	for _, r in ipairs(G.natRelease) do live[r.id] = true end
	for _, e in ipairs(G.natShipIds or {}) do live[e.id] = true end
	for id, since in pairs(G.pendingMarks) do
		if not live[id] or G.frames - since > 900 then
			pcall(api.gui.mission.removeZone, "mpfever_pending_" .. id)
			G.pendingMarks[id] = nil
		end
	end
end

-- terrain edits: the cells the DLL copied when the engine applied an edit here (to ship), and the verdicts on the ones
-- received (injected into the empty grid the replay sends)
G.terrainBlobs = {}
G.terrainIn = {}
G.lastBlobId = 0
-- the ground under a patch of cells (a diagnostic: the same sum in two games means the same ground)
G.terrainSum = function(x0, y0, w, h)
	local sum, n = 0, 0
	for i = 0, math.min(w, 24) - 1 do
		for j = 0, math.min(h, 24) - 1 do
			local z = nil
			pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new((x0 + i + 0.5) * 4, (y0 + j + 0.5) * 4)) end)
			if type(z) == "number" then sum = sum + z; n = n + 1 end
		end
	end
	return string.format("%.3f over %d points", sum, n)
end
function pollNativeEvents()
	refreshPendingMarks()
	for _, line in ipairs(readLines("native_events.log", "natOff")) do
		local tid, tx0, ty0, tw, th, tlen, tfnv, textra = line:match("^terrain (%d+) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d+) (%x+) (%d+)")
		if tid then
			G.terrainBlobs[#G.terrainBlobs + 1] = { id = tonumber(tid), x0 = tonumber(tx0), y0 = tonumber(ty0), w = tonumber(tw),
				h = tonumber(th), len = tonumber(tlen), fnv = tfnv, extra = tonumber(textra), frame = G.frames }
			while #G.terrainBlobs > 12 do table.remove(G.terrainBlobs, 1) end
		end
		local rid, rst = line:match("^terrain_in (%d+) (%a+)")
		if rid then G.terrainIn[tonumber(rid)] = rst end
		local id = tonumber(line:match("^deferred (%d+)"))
		if id then
			markPending(id)
			local now = gameTime()
			local paused = G.session.pauseAt ~= nil and now >= G.session.pauseAt
			local at = paused and pausedStamp(now) or (stampFor(now) + STEP)
			G.natRelease[#G.natRelease + 1] = { id = id, at = at }
			send("nat_pending", { origin = G.me, at = at, id = id })
			log("native build " .. id .. " held by the DLL, released at t=" .. at .. " (now " .. now .. ") [frame " .. G.frames .. "]")
		end
	end
end

-- autotest: a scripted build follows the tools' path (announced, every game holds at its time, then it is sent)
G.autoBuildSeq = 0
function deferredSend(cmd, cb)
	local now = gameTime()
	G.autoBuildSeq = G.autoBuildSeq + 1
	local id = 100000 + G.autoBuildSeq
	local at = stampFor(now) + STEP
	G.natRelease[#G.natRelease + 1] = { id = id, at = at, fn = function() O.sendCommand(cmd, cb) end }
	markPending(id, { x = 0, y = 0 })
	log("pending mark drawn for autotest build " .. id)
	send("nat_pending", { origin = G.me, at = at, id = id })
end

-- A released build the engine refused is never shipped: the others, who hold for it, are told at once (they would
-- wait half a minute), and its id must not be taken by the next build that is shipped.
function cancelNativeBuild(entry, why)
	send("nat_cancel", { origin = G.me, id = entry.id })
	log("native build " .. tostring(entry.id) .. " produced nothing (" .. why .. "): the others stop holding for it")
end

function expireShipIds()
	local keep = {}
	for _, e in ipairs(G.natShipIds or {}) do
		if G.frames - e.frame > 150 then cancelNativeBuild(e, "refused or not built") else keep[#keep + 1] = e end
	end
	G.natShipIds = keep
end

H.nat_cancel = function(from, p)
	if p.origin == G.me then return end
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if w.origin == p.origin and w.id == p.id and not w.arrived then
			log("native build of " .. tostring(w.origin) .. " for t=" .. tostring(w.at) .. " cancelled by its originator: no longer holding")
		else
			keep[#keep + 1] = w
		end
	end
	G.natWait = keep
end

-- the held build goes to the engine; it is built at game time `at` (the time the game is at now, or the one the steps
-- queued just before it end at)
function releaseOne(r, at, how)
	G.natReleased = G.natReleased + 1
	G.natShipIds = G.natShipIds or {}
	G.natShipIds[#G.natShipIds + 1] = { id = r.id, at = at, frame = G.frames, combined = how ~= nil }
	if r.fn then
		-- a scripted build (autotest) deferred like the tools' ones: sent now, at its announced time
		G.natReleased = G.natReleased - 1
		pcall(r.fn)
	else
		nativeCtl("release " .. G.natReleased)
		-- any command reaching CommandList::Add lets the DLL release the held build just before it
		O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
	end
	log("native build " .. r.id .. " released at t=" .. at .. (how or "") .. (at > r.at and (" (" .. ((at - r.at) / STEP) .. " step(s) late)") or "") .. " [frame " .. G.frames .. "]")
end

function runNativeRelease()
	expireShipIds()
	if #G.natRelease == 0 then return end
	local now = gameTime()
	local keep = {}
	for _, r in ipairs(G.natRelease) do
		if now >= r.at and gameSpeed() == 0 then
			releaseOne(r, now)
		else
			keep[#keep + 1] = r
		end
	end
	G.natRelease = keep
end

function expireNativeWaits()
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

function matchesWait(w, a)
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

function nativeArrived(a)
	local keep = {}
	for _, w in ipairs(G.natWait) do
		if not matchesWait(w, a) then keep[#keep + 1] = w end
	end
	G.natWait = keep
end

-- Another game's terrain edit, in two phases so that a failure never reaches the engine: (1) the cells go to the DLL (a file and
-- a control line, read when the next command enters the command list: a nop event is sent for that) and the DLL says "ready";
-- (2) only then a command with an empty grid of the same size goes to the engine, and the DLL copies the cells into it as it
-- enters the command list ("injected"). An empty grid applied by itself would flatten the ground it covers.
function terrainFail(a, why)
	G.terrainBusy = nil
	log("TERRAIN REPLAY " .. tostring(a.uid) .. ": " .. why)
	replayFailed(a, why)
end

function replayTerrain(a)
	local t = a.args or {}
	if type(t.blob) ~= "string" or type(t.w) ~= "number" or type(t.h) ~= "number" then
		return terrainFail(a, "no cells received")
	end
	G.terrainInSeq = (G.terrainInSeq or 0) + 1
	local okT, tm = pcall(os.time)
	local id = ((okT and tm or 0) % 100000) * 1000 + G.terrainInSeq % 1000
	local f = C.IO.open(C.DIR .. BS .. "terrain_in_" .. id .. ".txt", "wb")
	if not f then return terrainFail(a, "cannot write the cells") end
	f:write(t.blob)
	f:close()
	G.terrainBusy = { id = id, frame = G.frames, a = a, phase = "load" }
	nativeCtl("tin " .. id)
	O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))     -- the DLL reads the control line when this command enters the list
end

function sendTerrainCarrier(busy)
	local a, id = busy.a, busy.id
	local t = a.args
	local okc, cmd = pcall(function()
		local prop = api.type.Proposal.new()
		prop.terrain.baseHeightMod = api.type.GridVec2f.new(t.x0, t.y0, t.w, t.h)
		local ctx = api.type.Context.new()
		ctx.player = api.engine.util.getPlayer()
		return api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true)
	end)
	if not okc or not cmd then return terrainFail(a, "command not made (" .. shortErr(cmd) .. ")") end
	busy.phase = "inject"
	busy.frame = G.frames
	toSim("replaying", {})
	toSim("terrain_note", { v = tonumber(tostring(t.fnv):sub(-8), 16) or 0 })
	local hx, hy = (t.x0 + math.floor(t.w / 2)) * 4 + 2, (t.y0 + math.floor(t.h / 2)) * 4 + 2
	local h0 = nil
	pcall(function() h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(hx, hy)) end)
	replaySend(cmd, function(res, success)
		local h1 = nil
		pcall(function() h1 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(hx, hy)) end)
		log("TERRAIN REPLAY " .. tostring(a.uid) .. (success and " applied" or " REFUSED") .. " (" .. t.w .. "x" .. t.h .. " cells at " .. t.x0 .. ","
			.. t.y0 .. "; DLL: " .. tostring(G.terrainIn[id]) .. "; height at the centre " .. tostring(h0) .. " -> " .. tostring(h1) .. ")")
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
			log("TERRAIN REPLAY " .. tostring(a.uid) .. ": ground now sum " .. tostring(G.terrainSum(t.x0, t.y0, t.w, t.h)))
		end }
		if not success then replayFailed(a, "terrain refused") end
	end)
end

-- every frame: moves the edit being replayed from one phase to the next
function pumpTerrain()
	local busy = G.terrainBusy
	if not busy then return end
	local st = G.terrainIn[busy.id]
	local age = G.frames - busy.frame
	if busy.phase == "load" then
		if st == "ready" then sendTerrainCarrier(busy)
		elseif st == "failed" then terrainFail(busy.a, "the native module could not read the cells")
		elseif age > 180 then terrainFail(busy.a, "the native module did not answer (" .. tostring(st) .. ")") end
	else
		if st == "injected" then G.terrainBusy = nil
		elseif age > 300 then terrainFail(busy.a, "the cells were not injected (" .. tostring(st) .. ")") end
	end
end

function runNativeReplays()
	pumpTerrain()
	if #G.nativeQueue == 0 then return end
	local now = gameTime()
	table.sort(G.nativeQueue, before)
	local keep = {}
	for _, a in ipairs(G.nativeQueue) do
		if a.at <= now and a.fn == "terrainEdit" and G.terrainBusy then
			keep[#keep + 1] = a      -- the cells of the previous edit are still being handed to the engine
		elseif a.at <= now then
			if a.at < now then
				log("LATE native build " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
				G.aheadLocked = true
			end
			nativeArrived(a)
			local okr, errr
			if a.fn == "terrainEdit" then okr, errr = pcall(replayTerrain, a) else okr, errr = pcall(replayNative, a, 1) end
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

end
