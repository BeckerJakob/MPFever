-- MPFever bridge: replays of other players' native builds.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- Replays of other players' builds: the engine applies a command a frame later (verdict in the callback). Until it
-- has, this game stays where it is (nativeHoldAt): resuming at once would let it run steps before the build lands.
-- The dust cloud of a construction going up is an effect of the interface, not of the simulation: only the game whose
-- tool issued the build shows it. The games that replay the build show it too.
function buildEffects(res, success)
	if not success then return end
	local ok, err = pcall(function()
		local P = res.proposal
		if P == nil then return end
		local n = #P.toAdd
		for k = 1, math.min(n, 4) do
			local ce = P.toAdd[k]
			-- a box around the construction (its real size is not read: a puff the size of a small building)
			api.gui.rendering.spawnDust(api.type.Vec3f.new(-10, -10, 0), api.type.Vec3f.new(10, 10, 6), ce.transf)
		end
		G.dustCount = (G.dustCount or 0) + n
		if n > 0 and G.dustCount <= 8 then log("build effects: dust shown for " .. n .. " replayed construction(s)") end
	end)
	if not ok and not G.dustFailed then
		G.dustFailed = true
		log("build effects: no dust for replayed builds (" .. tostring(err):sub(1, 160) .. ")")
	end
end

function replaySend(cmd, cb)
	G.replayOut = (G.replayOut or 0) + 1
	G.replaySince = G.frames
	O.sendCommand(cmd, function(...)
		G.replayOut = math.max(0, (G.replayOut or 1) - 1)
		G.replayQuiet = G.frames + 3   -- room for a follow-up command (next segment, next form)
		pcall(buildEffects, ...)
		if cb then return cb(...) end
	end)
end

-- engine verdicts arrive in callbacks: a refused native replay is retried with the next form, in a fixed order
REPLAY_FORMS = {
	-- the tool's proposal is already cleaned up: cleaning it again can split a curved segment (one more segment here)
	{ v = "minimal", raw = true, ctx = "terrainNoCleanup" },
	{ v = "minimal", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "plain" },
	{ v = "minimalNoOwner", raw = true, ctx = "terrain" }, { v = "minimal", raw = true, ctx = "nil" },
	{ v = "minimal", ctx = "terrain" }, { v = "full", raw = true, ctx = "terrain" },
}
if os.getenv("MPFEVER_FORM1") then REPLAY_FORMS[1].ctx = os.getenv("MPFEVER_FORM1") end

-- A pure upgrade (every added segment replaces a removed one between the same nodes, nothing else): the engine's
-- replaceSegment builds it exactly as the upgrade tool does.
function upgradePlan(margs)
	local st = margs[1] and margs[1].proposal
	if type(st) ~= "table" then return nil end
	if #(st.addedNodes or {}) > 0 or #(st.removedNodes or {}) > 0 or #(st.edgeObjectsToAdd or {}) > 0 then return nil end
	-- a stop removed with the bulldozer looks like an upgrade, but replaceSegment would keep the stop
	if #(st.edgeObjectsToRemove or {}) > 0 then return nil end
	-- constructions: only town buildings the engine moved for the new street (nobody's, -1); every game's own
	-- replaceSegment moves them the same way (a rebuilt proposal could not make them town buildings again)
	local tAdd, tRem = margs[1].toAdd or {}, margs[1].toRemove or {}
	-- buildings moved for the new street: the engine picks their new places at random, so every game would put them
	-- elsewhere (the town then grows differently): they are rebuilt exactly as the originator's engine placed them
	if #tAdd > 0 or #tRem > 0 then return nil end
	local added, removed = st.addedSegments or {}, st.removedSegments or {}
	if #added == 0 or #added ~= #removed then return nil end
	local plan = {}
	for _, ad in ipairs(added) do
		local c = ad.comp or {}
		local match, decorations = nil, nil
		local customLanes = C.customLanes(ad)
		for _, rm in ipairs(removed) do
			local rc = rm.comp or {}
			if (rc.node0 == c.node0 and rc.node1 == c.node1) or (rc.node0 == c.node1 and rc.node1 == c.node0) then
				match = rm.entity
				-- more than a new template (a bridge, a different track...): replaceSegment would not make it
				if c.type ~= rc.type or c.typeIndex ~= rc.typeIndex or c.roadType ~= rc.roadType or ad.type ~= rm.type then return nil end
				-- (the decorations, a noise barrier for instance, are put on the engine's upgrade proposal below)
				if C.ser(c.edgeDecorations or {}) ~= C.ser(rc.edgeDecorations or {}) then decorations = c.edgeDecorations or {} end
			end
		end
		if type(match) ~= "number" or match < 0 then return nil end
		plan[#plan + 1] = { edge = match, template = c.roadTemplate, decorations = decorations, lanes = customLanes, n0 = c.node0 }
	end
	return plan
end

function replayUpgrade(a, plan, i)
	local step = plan[i]
	if not step then return end
	local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(step.edge, step.template) end)
	if not okp or not P then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": no proposal " .. tostring(P))
		return replayUpgrade(a, plan, i + 1)
	end
	if step.decorations or step.lanes then
		-- the engine's upgrade proposal with what the template does not give: the originator's decorations (noise
		-- barrier...) and lanes (tram tracks on a road) on the new segment
		local okd, errd = pcall(function()
			local sp = P.proposal
			local list = sp.addedSegments
			local seg = list[1]
			local cmp = seg.comp
			if step.decorations then
				-- a decoration has a side (left of the segment's direction): when this game's segment runs the other way
				-- round than the originator's, the side is the opposite one
				local deco = C.plain(step.decorations)
				local be = api.engine.getComponent(step.edge, api.type.ComponentType.BASE_EDGE)
				if be and type(step.n0) == "number" and be.node0 ~= step.n0 then
					for _, d in ipairs(deco) do if type(d) == "table" then d[2] = not d[2] end end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " segment " .. step.edge .. " runs the other way round: decoration sides swapped")
				end
				cmp.edgeDecorations = deco
			end
			if step.lanes then cmp.laneConfigs = C.rebuildLanes(step.lanes) end
			seg.comp = cmp
			list[1] = seg
			sp.addedSegments = list
			P.proposal = sp
		end)
		if not okd then log("NATIVE REPLAY " .. tostring(a.uid) .. " upgrade of " .. tostring(step.edge) .. ": decorations/lanes not applied (" .. shortErr(errd) .. ")") end
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
		pcall(function()
			local at = {}
			for k = 1, #res.proposal.toAdd do
				local ce = res.proposal.toAdd[k]
				local t = ce.transf
				at[#at + 1] = tostring(ce.fileName):match("[^/]+$") .. "@" .. string.format("%.1f,%.1f", t[13] or 0, t[14] or 0)
			end
			if #at > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " engine's own constructions: " .. table.concat(at, " ") .. "; removed " .. #res.proposal.toRemove) end
		end)
		G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() replayUpgrade(a, plan, i + 1) end }
	end)
end

-- A pure removal (bulldozer): the engine's own removal proposal
function removalPlan(margs)
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

function engineReplay(a, what, makeP)
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
function sVec(q) return api.type.Vec3f.new(q.x, q.y, q.z) end
function sNodePos(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and { x = c.position.x, y = c.position.y, z = c.position.z } or nil
end
function sContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = true
	c.gatherBuildings = false
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

function stopPlan(margs)
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
	return { E = E, seg = ad, objs = objs, removeIdx = removeIdx, nodeConfigs = st.nodeConfigsToAdd or {}, segType = rm.type }
end

function replayStop(a, plan, variant)
	variant = variant or 1
	local c = api.engine.getComponent(plan.E, api.type.ComponentType.BASE_EDGE)
	if not c then log("NATIVE REPLAY " .. tostring(a.uid) .. ": stop segment missing"); return end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = (type(plan.segType) == "number") and plan.segType or 0   -- 1: a track (a signal)
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
	-- the kind of each new object on the segment: a stop on the left (0) or the right (1), or a signal (2)
	for k, o in ipairs(plan.objs) do list[#list + 1] = { -400000000 - (k - 1), (o.category == 2) and 2 or (o.left and 0 or 1) } end
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
		-- (variant 2, for what the stop tool does not place: the model name as the capture has it)
		eo.model = (variant == 2) and o.model or (o.model:gsub("^::/", ""))
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
		log("NATIVE REPLAY " .. tostring(a.uid) .. " stop: factory (variant " .. variant .. ") " .. shortErr(cmd))
		if variant < 2 then return replayStop(a, plan, variant + 1) end
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

-- A construction placed against a street (depot, station): the tool's proposal also splits the street for it. The
-- engine refuses it rebuilt as one SimpleProposal ("Construction impossible"; without the street part: "Collision"),
-- and the native proposal type refuses the removed segments we rebuild ("Unknown exception"). So it is replayed in two
-- steps, in the order the engine needs: the street part alone (the forms that rebuild roads), then the construction
-- alone on the street that is now cut.
-- why the engine refused a build: error state, colliding entities and what they are
function logRefusal(a, res)
	pcall(function()
		local rpd = res.resultProposalData
		log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: errorState " .. C.ser(C.marshal(rpd.errorState)):sub(1, 400))
		pcall(function() log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: collisionInfo " .. C.ser(C.marshal(rpd.collisionInfo)):sub(1, 500)) end)
		pcall(function()
			local ent = rpd.collisionInfo.collisionEntities[1].entity
			local have = {}
			for _, name in ipairs({ "BASE_EDGE", "BASE_NODE", "CONSTRUCTION", "TOWN_BUILDING", "STATION", "MODEL_INSTANCE_LIST", "NAME", "PLAYER_OWNED",
				"VEHICLE_DEPOT", "SUBCONSTRUCTION", "EDGE_OBJECT", "INDUSTRY", "WAREHOUSE" }) do
				local okc, c = pcall(function() return api.engine.getComponent(ent, api.type.ComponentType[name]) end)
				if okc and c then have[#have + 1] = name end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: colliding entity " .. tostring(ent) .. " components {" .. table.concat(have, ",") .. "}")
			pcall(function()
				local be = api.engine.getComponent(ent, api.type.ComponentType.BASE_EDGE)
				if be then
					local function pos(n) local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) return c and string.format("(%.1f %.1f %.1f)", c.position.x, c.position.y, c.position.z) or "?" end
					log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: edge " .. ent .. " " .. be.node0 .. pos(be.node0) .. " -> " .. be.node1 .. pos(be.node1) .. " " .. tostring(be.roadTemplate))
				end
			end)
			local okt, tf = pcall(function() return api.engine.getComponent(ent, api.type.ComponentType.CONSTRUCTION) end)
			if okt and tf then log("NATIVE REPLAY " .. tostring(a.uid) .. " refusal: construction " .. tostring(tf.fileName)) end
		end)
	end)
end

-- a build this game could not reproduce: the host reloads its game for everybody at once (without waiting for the
-- next checkpoints to notice the difference)
function replayFailed(a, why)
	pcall(send, "replay_failed", { uid = tostring(a.uid), why = tostring(why):sub(1, 120) })
end

-- the street segments a construction brings with it (the entrance of a depot or of a street station, the paths of a
-- rail station): they belong to the construction, whose own script makes them
function isConstructionSegment(sg)
	local tpl = tostring(sg and sg.comp and sg.comp.roadTemplate or "")
	return tpl:find("/constructions/", 1, true) ~= nil or tpl:find("simple.street_template", 1, true) ~= nil
end

function hasConstructionSegments(m)
	if type(m) ~= "table" or #(m.toAdd or {}) == 0 or type(m.proposal) ~= "table" then return false end
	for _, sg in ipairs(m.proposal.addedSegments or {}) do if isConstructionSegment(sg) then return true end end
	return false
end

STREET_FORMS = {
	{ v = "minimal", raw = true, ctx = "terrainNoCleanup" }, { v = "minimal", raw = true, ctx = "terrain" },
	{ v = "minimal", raw = true, ctx = "plain" }, { v = "full", raw = true, ctx = "terrain" },
}

-- Construction against a street, rebuilt as the tool's own native proposal (see C.rebuildNativeWithConstruction): the
-- engine converts the construction for us (the converted proposal comes back with the result of a command that is
-- refused on purpose: the same construction twice at the same place collides with itself, nothing is built).
function replayNativeConstruction(a)
	local m0 = a.args[1]
	if not hasConstructionSegments(m0) then return false end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: unresolved " .. table.concat(miss, ",")) return false end
	local m = cArgs[1]
	-- the engine's conversion of the construction (twice: guaranteed collision, so that nothing is built)
	local spCon = C.rebuildProposal(m, { noStreet = true, seed = 7919 })
	local cons = {}
	do
		local one = spCon.constructionsToAdd
		cons[1] = one[1]
		local two = C.rebuildProposal(m, { noStreet = true, seed = 7919 }).constructionsToAdd
		cons[2] = two[1]
		spCon.constructionsToAdd = cons
	end
	local ctx = api.type.Context.new()
	ctx.checkTerrainAlignment = false
	ctx.cleanupStreetGraph = false
	ctx.gatherBuildings = true
	ctx.gatherFields = true
	ctx.player = api.engine.util.getPlayer()
	local okc, dry = pcall(function() return api.cmd.makeWorldBuildProposalCmd(spCon, ctx, false, true) end)
	if not okc or not dry then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: conversion command " .. shortErr(dry)) return false end
	toSim("replaying", {})
	local edgesBefore = #R.allEdges()
	replaySend(dry, function(res, success)
		if success then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the conversion command was built instead of refused (desync)")
			replayFailed(a, "conversion built")
			return
		end
		local conv = res.proposal
		local okn, nconv = pcall(function() return #conv.toAdd end)
		if not okn or nconv < 1 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: no converted construction in the result (" .. tostring(nconv) .. ")") replayFailed(a, "no converted construction") return end
		-- the removed segments as the engine's own removal proposal makes them
		local rmIds = {}
		for _, sg in ipairs(m.proposal.removedSegments or {}) do if type(sg.entity) == "number" then rmIds[#rmIds + 1] = sg.entity end end
		local okr, rm = pcall(function() return api.engine.util.proposal.makeSegmentsRemoveProposal(rmIds) end)
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: removal proposal " .. shortErr(rm)) rm = nil end
		-- the engine's removal must be the tool's removal (same number of segments and nodes), else nothing is built
		local function ids(list, field)
			local t = {}
			pcall(function() for i = 1, #list do t[#t + 1] = tostring(field and list[i][field] or list[i]) end end)
			return table.concat(t, ",")
		end
		local capNodes = {}
		for _, nd in ipairs(m.proposal.removedNodes or {}) do capNodes[#capNodes + 1] = tostring(nd.entity) end
		local engSeg, engNodes = "?", "?"
		local nSeg, nNodes = -1, -1
		pcall(function() nSeg = #rm.proposal.removedSegments engSeg = ids(rm.proposal.removedSegments, "entity") end)
		pcall(function() nNodes = #rm.proposal.removedNodes engNodes = ids(rm.proposal.removedNodes, "entity") end)
		log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: removal segments tool {" .. table.concat((function() local t = {} for i, v in ipairs(rmIds) do t[i] = tostring(v) end return t end)(), ",") .. "} engine {" .. engSeg .. "}; nodes tool {" .. table.concat(capNodes, ",") .. "} engine {" .. engNodes .. "}")
		if nSeg ~= #rmIds or nNodes ~= #capNodes then
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: the engine's removal differs from the tool's (desync)")
			replayFailed(a, "removal differs")
			return
		end
		C.errors = {}
		local okp, P = pcall(C.rebuildNativeWithConstruction, m, conv, rm)
		if not okp or not P then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: not rebuilt (" .. shortErr(P) .. ")") replayFailed(a, "native rebuild") return end
		do
			local notes = {}
			for _, e in ipairs(C.errors) do if not tostring(e):find("no writable member 'params'", 1, true) then notes[#notes + 1] = e end end
			if #notes > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: rebuild notes " .. table.concat(notes, "; ")) end
		end
		local ctx2 = api.type.Context.new()
		ctx2.checkTerrainAlignment = true
		ctx2.cleanupStreetGraph = false
		ctx2.gatherBuildings = true
		ctx2.gatherFields = true
		ctx2.player = api.engine.util.getPlayer()
		local okk, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(P, ctx2, false, true) end)
		if not okk or not cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: command " .. shortErr(cmd)) replayFailed(a, "native command") return end
		toSim("replaying", {})
		replaySend(cmd, function(res2, success2)
			if not success2 then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res2.resultProposalData.errorState.messages)) end)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction: refused " .. why .. " (desync)")
				logRefusal(a, res2)
				replayFailed(a, "native construction refused " .. why)
				return
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " native construction BUILT")
			pcall(function()
				local st = res2.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res2.proposal.toAdd)
			end)
			local expected = #(m.proposal.addedSegments or {}) - #(m.proposal.removedSegments or {})
			G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
				local got = #R.allEdges() - edgesBefore
				log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS"))
			end }
		end)
	end)
	return true
end

function replayTwoStep(a)
	local m0 = a.args[1]
	if type(m0) ~= "table" or #(m0.toAdd or {}) == 0 or type(m0.proposal) ~= "table" then return false end
	local cArgs = C.deser(C.ser(a.args))
	local miss = R.translateIn(cArgs, G.bind)
	if #miss > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: unresolved " .. table.concat(miss, ",")) return false end

	local function buildConstruction()
		local okr, args, n = pcall(C.rebuildArgs, a.fn, C.deser(C.ser(cArgs)), { seed = 7919, variant = "minimal", raw = true, ctx = "terrainNoCleanup", noStreet = true })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction not rebuilt (" .. shortErr(args) .. ")") replayFailed(a, "construction not rebuilt") return end
		args[3] = true args[4] = false   -- (non-critical collision with its own street connection: ignored)
		local okk, cmd2 = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okk or not cmd2 then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction command " .. shortErr(cmd2)) replayFailed(a, "construction command") return end
		toSim("replaying", {})
		replaySend(cmd2, function(res2, success2)
			local why = ""
			if not success2 then pcall(function() why = C.ser(C.marshal(res2.resultProposalData.errorState.messages)) end) end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: construction " .. (success2 and "BUILT" or ("refused " .. why .. " (desync)")))
			if success2 then pcall(function()
				local st2 = res2.proposal.proposal
				log("NATIVE REPLAY " .. tostring(a.uid) .. " construction engine applied: +nodes " .. #st2.addedNodes .. " -nodes " .. #st2.removedNodes .. " +segments " .. #st2.addedSegments .. " -segments " .. #st2.removedSegments .. " +constructions " .. #res2.proposal.toAdd)
			end) end
			if not success2 then logRefusal(a, res2) replayFailed(a, "construction refused " .. why) end
		end)
	end

	-- the street part without the construction's own entrance (see above); `together`: with the construction in the same
	-- proposal (the engine then connects the construction's free node to the street node itself)
	local edgesBefore = #R.allEdges()
	local function streetStep(k, together)
		local form = STREET_FORMS[k]
		if not form then
			if together then return streetStep(1, false) end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street part refused by every form (desync)")
			replayFailed(a, "street part refused")
			return
		end
		local sArgs = C.deser(C.ser(cArgs))
		if not together then
			sArgs[1].toAdd = {}
			sArgs[1].toRemove = {}
		end
		local dropped = {}
		pcall(function()
			local st = sArgs[1].proposal
			local keepSeg, usedNode = {}, {}
			for _, sg in ipairs(st.addedSegments or {}) do
				if isConstructionSegment(sg) then dropped[#dropped + 1] = sg.entity else keepSeg[#keepSeg + 1] = sg end
			end
			if #dropped > 0 then
				for _, sg in ipairs(keepSeg) do usedNode[sg.comp.node0] = true usedNode[sg.comp.node1] = true end
				local keepNodes = {}
				for _, nd in ipairs(st.addedNodes or {}) do if usedNode[nd.entity] then keepNodes[#keepNodes + 1] = nd end end
				st.addedSegments = keepSeg
				st.addedNodes = keepNodes
				-- (the lane connections this tool computed around the entrance are left to the engine: sending them back
				-- makes the command factory throw)
				st.nodeConfigsToAdd = {}
			end
		end)
		local label = (together and "with the construction, " or "") .. form.v .. "/" .. form.ctx
		local okr, args, n = pcall(C.rebuildArgs, a.fn, sArgs, { seed = 7919, variant = form.v, ctx = form.ctx, raw = form.raw })
		if not okr then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " rebuild " .. shortErr(args)) return streetStep(k + 1, together) end
		-- with the construction: the collisions the engine reports are the construction against its own street connection
		-- (non-critical errors): the build goes on, as the game's own scripts do (ignoreErrors = true)
		if together then args[3] = true args[4] = false end
		local okc, cmd = pcall(function() return api.cmd[a.fn](table.unpack(args, 1, n)) end)
		if not okc or not cmd then log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " command " .. shortErr(cmd)) return streetStep(k + 1, together) end
		toSim("replaying", {})
		replaySend(cmd, function(res, success)
			if not success then
				local why = ""
				pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end)
				log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street " .. label .. " refused " .. why)
				logRefusal(a, res)
				G.waits[#G.waits + 1] = { at = G.frames + 1, fn = function() streetStep(k + 1, together) end }
				return
			end
			if together then
				log("NATIVE REPLAY " .. tostring(a.uid) .. " BUILT street part and construction together with " .. label)
				pcall(function()
					local st = res.proposal.proposal
					log("NATIVE REPLAY " .. tostring(a.uid) .. " engine applied: +nodes " .. #st.addedNodes .. " -nodes " .. #st.removedNodes .. " +segments " .. #st.addedSegments .. " -segments " .. #st.removedSegments .. " +constructions " .. #res.proposal.toAdd)
				end)
				local expected = #(m0.proposal.addedSegments or {}) - #(m0.proposal.removedSegments or {})
				G.waits[#G.waits + 1] = { at = G.frames + 10, fn = function()
					local got = #R.allEdges() - edgesBefore
					log("NATIVE REPLAY " .. tostring(a.uid) .. " edges here " .. got .. ", originator " .. expected .. (got == expected and "" or " SEGMENT COUNT DIFFERS"))
				end }
				return
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " two steps: street part BUILT with " .. label)
			G.waits[#G.waits + 1] = { at = G.frames + 3, fn = buildConstruction }
		end)
	end
	streetStep(1, true)
	return true
end

function replayNative(a, formIndex)
	if formIndex == 1 then
		pcall(function()
			local m = a.args[1]
			local st = m.proposal or {}
			log("NATIVE REPLAY " .. tostring(a.uid) .. " shape: +nodes " .. #(st.addedNodes or {}) .. " -nodes " .. #(st.removedNodes or {})
				.. " +segments " .. #(st.addedSegments or {}) .. " -segments " .. #(st.removedSegments or {}) .. " stops " .. #(st.edgeObjectsToAdd or {})
				.. " +constructions " .. #(m.toAdd or {}) .. " -constructions " .. #(m.toRemove or {}))
			-- what exactly is built (for bug reports: station models, underground segments, heights)
			local names, zmin, zmax, kinds = {}, nil, nil, {}
			for _, ce in ipairs(m.toAdd or {}) do names[#names + 1] = tostring(ce.fileName) end
			for _, nd in ipairs(st.addedNodes or {}) do
				local z = nd.comp and nd.comp.position and nd.comp.position.z
				if type(z) == "number" then zmin = math.min(zmin or z, z) zmax = math.max(zmax or z, z) end
			end
			for _, sg in ipairs(st.addedSegments or {}) do
				kinds[#kinds + 1] = tostring(sg.comp and sg.comp.type) .. "/" .. tostring(sg.comp and sg.comp.typeIndex)
			end
			do
				local at = {}
				for _, ce in ipairs(m.toAdd or {}) do
					local t = ce.transf
					at[#at + 1] = tostring(ce.fileName):match("[^/]+$") .. "@" .. string.format("%.1f,%.1f", t and t[13] or 0, t and t[14] or 0)
				end
				if #at > 0 then log("NATIVE REPLAY " .. tostring(a.uid) .. " originator's constructions: " .. table.concat(at, " ") .. "; removed " .. #(m.toRemove or {})) end
			end
			log("NATIVE REPLAY " .. tostring(a.uid) .. " detail: constructions {" .. table.concat(names, ", ") .. "} node heights " ..
				tostring(zmin) .. ".." .. tostring(zmax) .. " segment type/index {" .. table.concat(kinds, ", ") .. "}")
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
		-- a construction with its street connection: not replayable as one rebuilt proposal (see replayTwoStep)
		if hasConstructionSegments(a.args[1]) then
			if replayNativeConstruction(a) then return end
			if replayTwoStep(a) then return end
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
		if replayTwoStep(a) then return end
		log("NATIVE REPLAY " .. tostring(a.uid) .. ": every form refused (desync)")
		replayFailed(a, "every form refused")
		return
	end
	local margs = C.deser(C.ser(a.args))
	local missing = R.translateIn(margs, G.bind)
	if #missing > 0 then
		log("NATIVE REPLAY " .. tostring(a.uid) .. " SKIPPED, unresolved: " .. table.concat(missing, ","))
		replayFailed(a, "unresolved references")
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

end
