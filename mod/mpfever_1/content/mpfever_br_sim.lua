-- MPFever bridge: simulation half (actions applied at their stamp, captures of native builds, hash).
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ================================================================== simulation half (engine state)


function simApplyDue(state)
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
					local c0 = C.clock()
					local okA, auth = pcall(authValues)
					st.hash = { n = a.n, parts = simHash(st.terrainSig, a.n), cost = C.clock() - c0, auth = okA and auth or nil }
					st.authOwn = st.authOwn or {}
					st.authOwn[#st.authOwn + 1] = { n = a.n, auth = okA and auth or nil }
					while #st.authOwn > 10 do table.remove(st.authOwn, 1) end
				else
					if a.at < now then
						log("LATE action " .. tostring(a.uid) .. " for t=" .. a.at .. " applied at " .. now .. " (" .. ((now - a.at) / STEP) .. " step(s) late)")
						st.late = (st.late or 0) + 1
					end
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
detRandom = nil
function installRandom()
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

function update(userParams, state, dt)
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
function streetExperiments(compact, proposal)
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

function captureNativeBuild(state, param)
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
	-- A terrain modification (raising / lowering the ground) alone: a script cannot read its height cells nor write them, so
	-- the native module copies them (terrain_out_<n>.txt, announced in native_events.log) when the engine applies the
	-- command; the other games get them back through an empty grid of the same size (replayTerrain). The terrain tools cannot
	-- be held like the others: the edit is made here at once and the others make it at the same game time when they can.
	local okt, terrainOnly = pcall(function()
		local g = proposal.terrain and proposal.terrain.baseHeightMod
		if not g or (g.width or 0) * (g.height or 0) <= 0 then return false end
		if #proposal.toAdd > 0 or #proposal.toRemove > 0 then return false end
		local sp = proposal.proposal
		for _, k in ipairs({ "nodesToAdd", "nodesToRemove", "edgesToAdd", "edgesToRemove", "edgeObjectsToAdd", "edgeObjectsToRemove" }) do
			local v = sp[k]
			if v ~= nil and #v > 0 then return false end
		end
		return true
	end)
	if okt and terrainOnly then
		local dims = nil
		pcall(function()
			local g = proposal.terrain.baseHeightMod
			dims = { x0 = g.x0, y0 = g.y0, w = g.width, h = g.height }
		end)
		log("terrain modification at t=" .. now .. (dims and (": " .. dims.w .. "x" .. dims.h .. " cells at " .. dims.x0 .. "," .. dims.y0) or ""))
		st.terrainEdits = (st.terrainEdits or 0) + 1
		st.out = st.out or {}
		st.outSeq = (st.outSeq or 0) + 1
		st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
			fn = "terrainEdit", args = dims or {}, terrain = true, captured = now }
		while #st.out > 50 do table.remove(st.out, 1) end
		state:set(st)
		return
	end
	pcall(function()
		local g = proposal.terrain and proposal.terrain.baseHeightMod
		if g and (g.width or 0) * (g.height or 0) > 0 then
			log("WARNING: a build at t=" .. now .. " carries " .. g.width .. "x" .. g.height .. " terrain cells besides other content: the cells are not copied to the other games")
		end
	end)
	local c0 = C.clock()
	log("capture: start t=" .. now)
	local okc, compact = pcall(C.compactProposal, proposal)
	log("capture: compact " .. string.format("%.3f", C.clock() - c0) .. " s, " .. #C.ser(compact or {}) .. " bytes")
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
	log("capture: translated " .. string.format("%.3f", C.clock() - c0) .. " s")
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
	log("capture: checked " .. string.format("%.3f", C.clock() - c0) .. " s")
	local hasObjects = #((compact.proposal or {}).edgeObjectsToAdd or {}) > 0
	st.out[#st.out + 1] = { n = st.outSeq, at = now, paused = (st.pauseAt ~= nil and now >= st.pauseAt) or nil,
		fn = "makeWorldBuildProposalCmd", args = args, captured = now, ready = not hasObjects }
	st.lastCapture = hasObjects and { n = st.outSeq, at = now } or nil
	while #st.out > 50 do table.remove(st.out, 1) end
	state:set(st)
end

-- After the native apply of a captured build with stops: read what the engine created (model, position on the edge)
function enrichAfterBuild(state, param)
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

function handleEvent(userParams, state, src, id, name, param)
	if not C.ACTIVE then return end
	if id == "apply_command" and name == "onPostBuildProposal" then
		log("engine: post build t=" .. tostring(gameTime()))
		if os.getenv("MPFEVER_CONDUMP") then
			pcall(function()
				local lines = {}
				for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
					local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
					local pp = c and c.transf and R.matPos(c.transf)
					if pp then lines[#lines + 1] = string.format("%s %.1f,%.1f #%d", tostring(c.fileName):match("[^/]+$"), pp.x, pp.y, e) end
				end
				table.sort(lines)
				local f = C.IO.open(C.DIR .. BS .. "conb_" .. tostring(gameTime()) .. ".txt", "wb")
				if f then f:write(table.concat(lines, NL) .. NL); f:close() end
			end)
		end
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
		elseif name == "terrain_note" then
			st.terrainSig = ((st.terrainSig or 0) + (tonumber(param.v) or 0)) % 4294967296
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

end
