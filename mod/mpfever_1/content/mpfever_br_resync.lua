-- MPFever bridge: resynchronisation by the host's savegame, state checks, shipping.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ---------------------------------------------------------------- resynchronisation by the host's savegame
-- resync_save (host): save the paused game; resync_load (others): load the host's savegame received by the launcher.
-- Handled here when the application functions are reachable from this state, otherwise by the UI hook (which waits
-- for a claim in resync_claims.txt before acting, so that only one of them does it).
function claimResync(kind, id)
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
function stampHeld()
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
function enrichEdgeObjects(compact)
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

function needsEnrich(compact)
	for _, e in ipairs(((compact or {}).proposal or {}).edgeObjectsToAdd or {}) do
		if type(e) == "table" and e.model == nil then return true end
	end
	return false
end

-- A terrain edit made here: the cells the DLL copied go to the others with the time the engine applied it. Without them
-- (no native module, cells not read) the games differ for sure: the host's game is reloaded everywhere.
function shipTerrain(o)
	local d = o.args or {}
	local k = nil
	-- the edits are applied in the order the DLL copies them: the oldest copy of the right size that is not too old (an edit
	-- the engine refused leaves a copy no edit comes for), and never one older than the last used
	local first = G.outFirstSeen[o.n] or G.frames
	for i = 1, #G.terrainBlobs do
		local b = G.terrainBlobs[i]
		if b.id > (G.lastBlobId or 0) and first - b.frame < 240 and b.x0 == d.x0 and b.y0 == d.y0 and b.w == d.w and b.h == d.h then k = i; break end
	end
	local function fail(why)
		log("terrain edit made here at t=" .. tostring(o.at) .. " cannot be copied to the other games: " .. why .. " (the host's game will be reloaded)")
		send("replay_failed", { uid = "terrain", why = "terrain modification" })
		return "failed"
	end
	if not k then
		if G.frames - (G.outFirstSeen[o.n] or G.frames) < 150 then return "wait" end
		return fail("the native module did not copy the cells")
	end
	local b = table.remove(G.terrainBlobs, k)
	G.lastBlobId = b.id
	local f = C.IO.open(C.DIR .. BS .. "terrain_out_" .. b.id .. ".txt", "rb")
	local txt = f and f:read("*a")
	if f then f:close() end
	if type(txt) ~= "string" or #txt ~= b.len then return fail("the file of the cells is missing or damaged") end
	if (b.extra or 0) > 0 then
		log("terrain edit at t=" .. tostring(o.at) .. " carries " .. b.extra .. " more grid(s) (ground paint?) that are not copied")
	end
	G.oseq = G.oseq + 1
	local a = { fn = "terrainEdit", args = { x0 = d.x0, y0 = d.y0, w = d.w, h = d.h, fnv = b.fnv, blob = txt }, at = o.at, origin = G.me,
		oseq = G.oseq, uid = G.me .. ":" .. G.oseq, native = true, paused = o.paused }
	send("act", a)
	toSim("terrain_note", { v = tonumber(b.fnv:sub(-8), 16) or 0 })
	G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
		log("terrain edit " .. a.uid .. ": ground here now sum " .. tostring(G.terrainSum(d.x0, d.y0, d.w, d.h)))
	end }
	log("terrain edit shipped " .. a.uid .. " (" .. d.w .. "x" .. d.h .. " cells, " .. #txt .. " bytes as text, made here at t=" .. tostring(o.at) .. ") [frame " .. G.frames .. "]")
	return "sent"
end

function shipNativeBuilds(st)
	G.outFirstSeen = G.outFirstSeen or {}
	for _, o in ipairs(st.out or {}) do
		if o.n > G.outSent and o.terrain then
			G.outFirstSeen[o.n] = G.outFirstSeen[o.n] or G.frames
			local okT, r = pcall(shipTerrain, o)
			if not okT then log("terrain shipping failed: " .. tostring(r)); r = "failed" end
			if r == "wait" then return end
			G.outSent = o.n
		elseif o.n > G.outSent then
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
			if G.natShipIds and #G.natShipIds > 0 then
				-- the released build that was built at this time; the ones released before it and not shipped were refused
				local k = nil
				for i, e in ipairs(G.natShipIds) do if e.at == o.at then k = i; break end end
				k = k or 1
				if G.natShipIds[k].at ~= o.at then
					log("WARNING: a native build landed at t=" .. tostring(o.at) .. " instead of t=" .. tostring(G.natShipIds[k].at) .. " (desync risk)")
				end
				for i = 1, k - 1 do cancelNativeBuild(G.natShipIds[i], "refused before a later build") end
				a.natId = G.natShipIds[k].id
				local rest = {}
				for i = k + 1, #G.natShipIds do rest[#rest + 1] = G.natShipIds[i] end
				G.natShipIds = rest
			end
			send("act", a)
			log("native build shipped " .. a.uid .. " (built here at t=" .. o.at .. ", the other games build it at the same time) [frame " .. G.frames .. "]")
		end
	end
end

function runPausedActions()
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
				send("sync_hash", { n = a.n, parts = simHash(G.simTerrainSig), cost = 0, auth = okA and auth or nil })
			else
				toSim("replaying", {})
				-- paused: the engine answers in a callback, a frame later; the result is reported then
				executeAction(a, O.sendCommand, true, G.bind, function(r)
					r.at = now
					r.answered, r.returned = nil, nil
					log("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t=" .. tostring(now) .. " -> " .. (r.success and "OK" or "REFUSED"))
					if r.created then G.bind[r.created.key] = r.created.e; G.rev[r.created.e] = r.created.key; toSim("bind", r.created) end
					G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true
					LINK.append("results.log", C.line("result", r))
					if r.created then LINK.append("bindings.log", r.created.key .. " " .. tostring(r.created.e) .. NL) end
					if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
				end)
			end
		else
			keep[#keep + 1] = a
		end
	end
	G.pendingPaused = keep
end

end
