-- MPFever autotest scenarios (dev only): roads, stops, matrix, company.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ================================================================== autotest scenario (MPFever.exe --autotest)
-- Builds like a player would (playerInitiated commands, the path the native tools take): a road from a dead end, a
-- second road from the new node, a bus stop on the second road. The other games must replicate everything.

AUTO = { running = false, results = {}, points = {} }
STOP_MODEL = "stations/street/small_stops/small_old.con"

function vec(p) return api.type.Vec3f.new(p.x, p.y, p.z) end
function pos3(v) return { x = v.x, y = v.y, z = v.z } end

function groundZ(x, y, fallback)
	local z = nil
	pcall(function() z = api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(x, y)) end)
	if type(z) ~= "number" then pcall(function() z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end) end
	return type(z) == "number" and z or fallback
end

-- dead ends of the street network, in a deterministic order (same save = same ids for these)
-- a town or country street (not an industry road, a depot or station entrance, a runway...): the engine asserts when a
-- scenario builds a stop on, or removes, an edge of another road type (finding F10, Phase 1)
function isPlainStreet(c)
	local t = c and c.roadTemplate
	return type(t) == "string" and (t:find("/street/town/", 1, true) ~= nil or t:find("/street/country/", 1, true) ~= nil)
end

-- what the engine says about a proposal before it is built (nil when the API is not there): skip what it refuses -
-- a removal of a segment with vehicles on it ended in an engine assertion (AreAllNodesEmpty, finding F10)
function proposalProblem(P, context)
	local okf, data = pcall(function() return api.engine.util.proposal.makeProposalData(P, context) end)
	if not okf or not data then return nil end
	local problem = nil
	pcall(function()
		local es = data.errorState
		if es and (es.critical or #es.messages > 0) then problem = C.ser(C.marshal(es.messages)):sub(1, 200) end
	end)
	return problem
end

function deadEnds()
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

function nodePosition(n)
	local c = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE)
	return c and pos3(c.position) or nil
end

function roadProposal(fromNode, fromPos, toPos, tmpl)
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

function stopProposal(edge)
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

function autoStep(name, makeProposal, after)
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

function autoFinish()
	AUTO.running = false
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(AUTO.points) do G.autoPoints[#G.autoPoints + 1] = q end
	send("autotest_done", { role = C.ROLE, results = AUTO.results, points = AUTO.points })
end

function runScenario(p)
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
function edgeCount() return #R.allEdges() end

function buildMatrixProposal(o, n, pn, a)
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

function readBack(sp)
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

MATRIX = {
	{ name = "tlShared", tlanes = true, template = true, roadType = true, street = true, owner = true, sharedIds = true },
	{ name = "tlPosShared", tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true },
}

function matrixPlace(k)
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

function runMatrix(done)
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
function playerContext()
	local c = api.type.Context.new()
	c.checkTerrainAlignment = false
	c.cleanupStreetGraph = true
	c.gatherBuildings = false
	c.gatherFields = true
	c.player = api.engine.util.getPlayer()
	return c
end

function runUpgrade(p)
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
function runNewRoad(p)
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

-- Exploration for separate companies: can a second player be created, and do builds / purchases honour it?
runCompanyBuild = nil
function runCompany(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function say(t) log("AUTOTEST company " .. t); AUTO.results[#AUTO.results + 1] = t end
	local P1 = api.engine.util.getPlayer()
	local function bal(P)
		local ok, v = pcall(function() local a = api.engine.getComponent(P, api.type.ComponentType.ACCOUNT); return a.balance end)
		return ok and v or ("err " .. tostring(v))
	end
	say("player 1 = " .. tostring(P1) .. ", balance " .. tostring(bal(P1)))
	local function comps(P)
		local out = {}
		for _, n in ipairs({ "PLAYER", "ACCOUNT", "NAME", "PLAYER_OWNED" }) do
			local ok, c = pcall(api.engine.getComponent, P, api.type.ComponentType[n])
			out[#out + 1] = n .. "=" .. ((ok and c) and "yes" or "no")
		end
		return table.concat(out, " ")
	end
	say("player 1 components: " .. comps(P1))
	local cmd = api.cmd.makeGameAddPlayerCmd("MPF Company 2", api.type.Vec3f.new(0.9, 0.2, 0.2))
	O.sendCommand(cmd, function(res, success)
		local P2 = nil
		pcall(function() P2 = res.resultEntity end)
		if not P2 then pcall(function() P2 = res.data and res.data.resultEntity end) end
		say("add player: success=" .. tostring(success) .. ", new entity " .. tostring(P2))
		if not success or not P2 then return autoFinish() end
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = function()
			say("player 2 exists=" .. tostring(api.engine.entityExists(P2)) .. " balance " .. tostring(bal(P2)) .. " components: " .. comps(P2))
			local acc = nil
			pcall(function() acc = api.engine.getComponent(P2, api.type.ComponentType.ACCOUNT) end)
			if acc then say("player 2 account balance " .. tostring(acc.balance) .. " loan " .. tostring(acc.loan)) end
			nativeCtl("setplayer " .. P2)
			G.waits[#G.waits + 1] = { at = G.frames + 120, fn = function()
				local now = api.engine.util.getPlayer()
				say("after writing the game's local-player field: getPlayer() = " .. tostring(now) .. " (player 2 is " .. tostring(P2) .. ")")
				if now == P2 then say("balance seen through getPlayer: " .. tostring(bal(api.engine.util.getPlayer()))) end
				G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function() runCompanyBuild(P1, P2, say, bal) end }
			end }
		end }
	end)
end

runCompanyBuild = function(P1, P2, say, bal)
	do
		do
			local p = {}
			local entry = api.type.JournalEntry.new()
			entry.amount = 5000000
			entry.time = -1
			entry.category.type = api.type.JournalEntry.Type.OTHER
			O.sendCommand(api.cmd.makeJournalBookAssetCmd(P2, entry), function() end)
			local n, info, pn, a = matrixPlace((p.offset or 0) + 20)
			local o = { tlanes = true, template = true, roadType = true, street = true, owner = true, positions = true, sharedIds = true,
				tmpl = { roadTemplate = info.c.roadTemplate, roadStyle = info.c.roadStyle, roadType = info.c.roadType } }
			local realGet = api.engine.util.getPlayer
			local swapped = pcall(function() api.engine.util.getPlayer = function() return P2 end end)
			local okb, sp = pcall(buildMatrixProposal, o, n, pn, a)
			if swapped then pcall(function() api.engine.util.getPlayer = realGet end) end
			say("owner override " .. tostring(swapped))
			if not okb then say("road proposal error " .. shortErr(sp)); return autoFinish() end
			local known = {}
			for _, e in ipairs(R.allEdges()) do known[e] = true end
			local b1, b2 = bal(P1), bal(P2)
			local ctx = api.type.Context.new()
			ctx.checkTerrainAlignment = true
			ctx.cleanupStreetGraph = true
			ctx.gatherBuildings = true
			ctx.gatherFields = true
			ctx.player = P2
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res2, ok2)
				G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function()
					local owners = {}
					for _, e in ipairs(R.allEdges()) do
						if not known[e] then
							local po = nil
							pcall(function() po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED) end)
							owners[#owners + 1] = e .. ":" .. (po and tostring(po.player) or "none")
						end
					end
					say("road built with player 2 context: " .. tostring(ok2) .. "; new edges (owner) " .. table.concat(owners, ",")
						.. "; balance P1 " .. tostring(b1) .. " -> " .. tostring(bal(P1)) .. ", P2 " .. tostring(b2) .. " -> " .. tostring(bal(P2)))
					-- a vehicle bought for player 2
					local vehicles = R.entitiesWith("TRANSPORT_VEHICLE")
					local pick = nil
					for _, v in ipairs(vehicles) do
						local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
						if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then pick = tv; break end
					end
					if not pick then say("no vehicle to copy"); return autoFinish() end
					local c1, c2, nv = bal(P1), bal(P2), #vehicles
					O.sendCommand(api.cmd.makeVehicleBuyCmd(P2, pick.depot, pick.transportVehicleConfig), function(res3, ok3)
						G.waits[#G.waits + 1] = { at = G.frames + 40, fn = function()
							local newOwner = "?"
							for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do
								if v > 0 then
									local po = nil
									pcall(function() po = api.engine.getComponent(v, api.type.ComponentType.PLAYER_OWNED) end)
									if po and po.player == P2 then newOwner = tostring(v) end
								end
							end
							say("vehicle bought for player 2: " .. tostring(ok3) .. ", vehicles " .. nv .. " -> " .. #R.entitiesWith("TRANSPORT_VEHICLE")
								.. ", vehicle owned by P2: " .. newOwner .. "; balance P1 " .. tostring(c1) .. " -> " .. tostring(bal(P1)) .. ", P2 " .. tostring(c2) .. " -> " .. tostring(bal(P2)))
							autoFinish()
						end }
					end)
				end }
			end)
		end
	end
end

H.company = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runCompany, p)
	if not ok then
		log("AUTOTEST company failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "company error " .. tostring(err)
		autoFinish()
	end
end

-- Exploration: which word of memory is read by getPlayer()? Candidates (words equal to player 1's id, found by the DLL) are
-- patched one at a time to player 2's id; the candidate that changes getPlayer() is the local-player field.
H.pprobe = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local P1 = api.engine.util.getPlayer()
	local function say(t) log("AUTOTEST pprobe " .. t); AUTO.results[#AUTO.results + 1] = t end
	O.sendCommand(api.cmd.makeGameAddPlayerCmd("MPF probe", api.type.Vec3f.new(0.2, 0.6, 0.9)), function(res, success)
		local P2 = res.resultEntity
		say("player 2 = " .. tostring(P2) .. " (player 1 = " .. tostring(P1) .. ")")
		nativeCtl("setplayer " .. P2)
		local i = 0
		local function nextCandidate()
			i = i + 1
			if i > (tonumber(p.max) or 160) then
				nativeCtl("probe 0")
				say("no candidate changed getPlayer()")
				return autoFinish()
			end
			nativeCtl("probe " .. i)
			O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
			G.waits[#G.waits + 1] = { at = G.frames + 24, fn = function()
				local now = api.engine.util.getPlayer()
				if now ~= P1 then
					say("candidate " .. i .. " is the local-player field: getPlayer() became " .. tostring(now))
					G.waits[#G.waits + 1] = { at = G.frames + 30, fn = function()
						nativeCtl("probe 0")
						O.sendCommand(O.event("mpfever", "mpfever", "nop", {}))
						G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
					end }
				else
					nextCandidate()
				end
			end }
		end
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = nextCandidate }
	end)
end

end
