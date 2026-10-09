-- MPFever autotest scenarios (dev only): probes, terrain, tram stops, bulldoze.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- Exploration: how the DLL's iteration counter relates to the game time (paused, stepped, and running)
H.iterclock = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local seq = 0
	local function mark(tag)
		seq = seq + 1
		nativeCtl("iterlog " .. seq)
		O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
		local t = gameTime()
		local line = "mark " .. seq .. " (" .. tag .. ") game time " .. t .. " speed " .. tostring(gameSpeed())
		log("AUTOTEST iterclock " .. line)
		AUTO.results[#AUTO.results + 1] = line
	end
	local plan = { 1, 3, 5, 2, 8 }
	local k = 0
	local function nextStep()
		k = k + 1
		if k > #plan then
			O.sendCommand(O.setSpeed(1))
			G.waits[#G.waits + 1] = { at = G.frames + 420, fn = function()
				O.sendCommand(O.setSpeed(0))
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = function() mark("after ~7 s at x1"); autoFinish() end }
			end }
			return
		end
		O.sendCommand(O.steps(plan[k]))
		G.waits[#G.waits + 1] = { at = G.frames + 150, fn = function() mark(plan[k] .. " steps"); nextStep() end }
	end
	O.sendCommand(O.setSpeed(0))
	G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function() mark("paused"); nextStep() end }
end

-- Terrain edit (a patch of ground raised, 4 m cells): the DLL copies the cells, the other game must make the same ground
-- (with MPFEVER_TERRAIN_PATTERN=1 the DLL gives the cells an uneven pattern, so that the copy is checked cell by cell)
H.terrain = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local ok, err = pcall(function()
		local n = tonumber(os.getenv("MPFEVER_TERRAIN_SIZE") or "12") or 12
		local burst = tonumber(os.getenv("MPFEVER_TERRAIN_BURST") or "1") or 1       -- edits sent in the same frame
		local bx, by = -640, -756
		if C.ROLE ~= "host" then bx, by = 300, -200 end
		local patches = {}
		for i = 1, burst do
			patches[i] = { x0 = bx + (i - 1) * (n + 6), y0 = by, w = n + (i - 1), h = n + (i - 1) }
			local pt = patches[i]
			pt.cx, pt.cy = (pt.x0 + pt.w / 2) * 4, (pt.y0 + pt.h / 2) * 4
			pt.h0 = nil
			pcall(function() pt.h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(pt.cx, pt.cy)) end)
			pt.sum0 = G.terrainSum(pt.x0, pt.y0, pt.w, pt.h)
		end
		local pending = burst
		for i, pt in ipairs(patches) do
			local prop = api.type.Proposal.new()
			local zero = os.getenv("MPFEVER_TERRAIN_ZERO")      -- test: an edit whose cells are all {0, 0} (what an empty carrier would be)
			prop.terrain.baseHeightMod = api.type.GridVec2f.new(pt.x0, pt.y0, pt.w, pt.h, zero and api.type.Vec2f.new(0, 0) or api.type.Vec2f.new((pt.h0 or 0) + 3, pt.h0 or 0))
			local ctx = api.type.Context.new()
			ctx.player = api.engine.util.getPlayer()
			log("AUTOTEST terrain edit " .. i .. "/" .. burst .. ": " .. pt.w .. "x" .. pt.h .. " at " .. pt.x0 .. "," .. pt.y0 .. ": height " .. tostring(pt.h0) .. ", sum " .. pt.sum0)
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true), function(res, success)
				local line = "terrain edit " .. i .. ": " .. (success and "built" or "refused")
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
				pending = pending - 1
				if pending == 0 then
					G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
						for j, q in ipairs(patches) do
							local h1 = nil
							pcall(function() h1 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(q.cx, q.cy)) end)
							local line2 = "ground after " .. j .. ": centre " .. tostring(q.h0) .. " -> " .. tostring(h1) .. ", sum " .. G.terrainSum(q.x0, q.y0, q.w, q.h)
							log("AUTOTEST " .. line2)
							AUTO.results[#AUTO.results + 1] = line2
						end
						autoFinish()
					end }
				end
			end)
		end
	end)
	if not ok then
		AUTO.results[#AUTO.results + 1] = "terrain error " .. tostring(err)
		autoFinish()
	end
end

-- A series of terrain edits one after the other (MPFEVER_TERRAIN_COUNT, MPFEVER_TERRAIN_SIZE, MPFEVER_TERRAIN_GAP frames between them)
H.terrainsoak = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local count = tonumber(os.getenv("MPFEVER_TERRAIN_COUNT") or "10") or 10
	local n = tonumber(os.getenv("MPFEVER_TERRAIN_SIZE") or "20") or 20
	local gap = tonumber(os.getenv("MPFEVER_TERRAIN_GAP") or "90") or 90
	local bx, by = -640, -756
	if C.ROLE ~= "host" then bx, by = 300, -200 end
	local patches, k = {}, 0
	local function finish()
		G.waits[#G.waits + 1] = { at = G.frames + 600, fn = function()
			local bad = 0
			for j, q in ipairs(patches) do
				local line = "ground after " .. j .. ": sum " .. G.terrainSum(q.x0, q.y0, q.w, q.h)
				log("AUTOTEST " .. line)
				AUTO.results[#AUTO.results + 1] = line
			end
			autoFinish()
		end }
	end
	local function nextEdit()
		k = k + 1
		if k > count then return finish() end
		local pt = { x0 = bx + ((k - 1) % 6) * (n + 4), y0 = by + math.floor((k - 1) / 6) * (n + 4), w = n, h = n }
		patches[#patches + 1] = pt
		local ok, err = pcall(function()
			local cx, cy = (pt.x0 + pt.w / 2) * 4, (pt.y0 + pt.h / 2) * 4
			local h0 = nil
			pcall(function() h0 = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(cx, cy)) end)
			local prop = api.type.Proposal.new()
			prop.terrain.baseHeightMod = api.type.GridVec2f.new(pt.x0, pt.y0, pt.w, pt.h, api.type.Vec2f.new((h0 or 0) + 1 + (k % 4), h0 or 0))
			local ctx = api.type.Context.new()
			ctx.player = api.engine.util.getPlayer()
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, ctx, false, true), function(res, success)
				if not success then AUTO.results[#AUTO.results + 1] = "terrain edit " .. k .. ": refused" end
				G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextEdit }
			end)
		end)
		if not ok then
			AUTO.results[#AUTO.results + 1] = "terrain edit " .. k .. " error " .. tostring(err)
			G.waits[#G.waits + 1] = { at = G.frames + gap, fn = nextEdit }
		end
	end
	nextEdit()
end

-- Diagnostic (with MPFEVER_PAYLOAD_DUMP=1 in the DLL): empty world-build commands that differ by one flag of the Context, so
-- that the bytes of the flags can be found in the command (then read from the real tools' commands)
H.ctxprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local variants = {
		{ "none", {}, false, true },
		{ "align", { checkTerrainAlignment = true }, false, true },
		{ "cleanup", { cleanupStreetGraph = true }, false, true },
		{ "buildings", { gatherBuildings = true }, false, true },
		{ "fields", { gatherFields = true }, false, true },
		{ "all", { checkTerrainAlignment = true, cleanupStreetGraph = true, gatherBuildings = true, gatherFields = true }, false, true },
		{ "ignore", {}, true, true },
		{ "notplayer", {}, false, false },
	}
	local i = 0
	local function nextOne()
		i = i + 1
		local v = variants[i]
		if not v then return autoFinish() end
		local ok, err = pcall(function()
			local ctx = api.type.Context.new()
			for k, x in pairs(v[2]) do ctx[k] = x end
			ctx.player = api.engine.util.getPlayer()
			log("AUTOTEST ctxprobe " .. i .. " " .. v[1])
			AUTO.results[#AUTO.results + 1] = "ctxprobe " .. i .. " " .. v[1]
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(api.type.Proposal.new(), ctx, v[3], v[4]), function() end)
		end)
		if not ok then AUTO.results[#AUTO.results + 1] = "ctxprobe error " .. tostring(err) end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = nextOne }
	end
	nextOne()
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
function stopForms(E)
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

c0node = nil
function runStopMatrix(p)
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
		local problem = proposalProblem(sp, ctx)
		if problem then log("STOPS " .. f.name .. ": skipped, the engine refuses it beforehand: " .. problem); return nextForm() end
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
function runTramStop(p)
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
			if c and c.type == 0 and isPlainStreet(c) and #c.objects == 0 and #c.laneConfigs > 0 and not hasPersonLane(c) then list[#list + 1] = e end
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
function runReplayFile(p)
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
				local deco, tram, dist5, track0 = 0, 0, 0, 0
				pcall(function()
					for _, e in ipairs(R.allEdges()) do
						local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
						if c and #c.edgeDecorations > 0 then deco = deco + 1 end
						local hasTram = false
						pcall(function() for k = 1, #c.laneConfigs do if c.laneConfigs[k].transportModes[5] then hasTram = true end end end)
						if hasTram then tram = tram + 1 end
						if c and c.distance and c.distance > 0 then dist5 = dist5 + 1 end
						if c and c.type == 1 and c.distance == 0 then track0 = track0 + 1 end
					end
				end)
				line = line .. ", edges with decorations " .. deco .. ", with tram lanes " .. tram .. ", with distance " .. dist5 .. ", tracks with distance 0: " .. track0
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
function runBulldoze(p)
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
	-- the newest dead ends of plain streets first: the road the newroad scenario just built has no traffic yet
	local cand = {}
	for _, n in ipairs(ends) do if isPlainStreet(edgeOf[n].c) then cand[#cand + 1] = n end end
	table.sort(cand, function(a, b) return edgeOf[a].e > edgeOf[b].e end)
	local tries = 0
	local function attempt(k)
		tries = tries + 1
		if tries > 6 or #cand == 0 then return autoFinish() end
		local n = cand[(k - 1) % #cand + 1]
		local info = edgeOf[n]
		local okp, P = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal({ info.e }) end)
		if not okp or not P then log("BULLDOZE no proposal " .. tostring(P)); return attempt(k + 1) end
		local problem = proposalProblem(P, playerContext())
		if problem then log("BULLDOZE segment " .. info.e .. " skipped: " .. problem); return attempt(k + 1) end
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
	-- host and client take different roads (offset 0 / 7 from the launcher)
	attempt(p.offset and p.offset > 0 and 2 or 1)
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

end
