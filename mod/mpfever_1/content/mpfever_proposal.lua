-- MPFever common code, part 2: rebuilding marshalled proposals and command arguments (street segments, lanes,
-- node configurations, constructions) on the game that replays them. Split from mpfever_common.lua in Phase 1:
-- mpfever_common.lua calls this function with its table C, which it extends.
-- No backslash characters on purpose: special characters are built with string.char.
return function(C)
local isVec, plain, rebuild, fill = C.isVec, C.plain, C.rebuild, C.fill

local function entityList(list, field)
	local r = {}
	for _, e in ipairs(list or {}) do
		if type(e) == "table" then r[#r + 1] = e[field or "entity"] else r[#r + 1] = e end
	end
	return r
end

local function baseName(fileName)
	local b = tostring(fileName or "construction"):match("([^/]+)$") or "construction"
	return (b:gsub("%.con$", ""))
end

-- The lanes of a street template, as the native street tool uses them
C.templateLaneCache = {}
function C.templateLanes(roadTemplate)
	if type(roadTemplate) ~= "string" or roadTemplate == "" then return nil end
	local cached = C.templateLaneCache[roadTemplate]
	if cached ~= nil then return cached or nil end
	local lanes = false
	pcall(function()
		local rep = api.res.streetTemplateRep
		local idx = rep.find(roadTemplate)
		if idx == nil or idx < 0 then idx = rep.find((roadTemplate:gsub("^::/", ""))) end
		local t = rep.get(idx)
		if t and t.laneConfigs and #t.laneConfigs > 0 then lanes = t.laneConfigs end
	end)
	C.templateLaneCache[roadTemplate] = lanes
	return lanes or nil
end

-- Which vehicles each lane takes and its direction: lanes of a template and lanes captured on a segment (tables) compare
-- by this signature. Tram tracks laid on a road change it while the road's template stays the same.
function C.laneSignature(lanes)
	local parts = {}
	local ok = pcall(function()
		for i = 1, #lanes do
			local l = lanes[i]
			local modes = {}
			for j = 0, 15 do
				local on = false
				pcall(function() on = l.transportModes[j] == true end)
				if on then modes[#modes + 1] = j end
			end
			parts[#parts + 1] = tostring(l.forward) .. ":" .. table.concat(modes, ",")
		end
	end)
	return ok and table.concat(parts, "|") or nil
end

-- the captured lanes of a segment when they are not the lanes of its template (nil: the template's lanes are right)
function C.customLanes(src)
	local c = type(src) == "table" and src.comp
	if type(c) ~= "table" or type(c.laneConfigs) ~= "table" or #c.laneConfigs == 0 then return nil end
	local tl = C.templateLanes(c.roadTemplate)
	if not tl then return nil end
	local a, b = C.laneSignature(c.laneConfigs), C.laneSignature(tl)
	if a and b and a ~= b then return c.laneConfigs end
	return nil
end

-- transportModes reads from index 0 but its writes may be shifted by one (tm[j] = x lands at j-1, tm[0] wraps to the
-- end): measured once, so that a rebuilt lane keeps its modes (a shifted PERSON flag drops the platform of a stop)
function C.transportModesWriteShift()
	if C.tmShift ~= nil then return C.tmShift end
	C.tmShift = 0
	pcall(function()
		local lc = api.type.LaneConfig.new()
		local tm = lc.transportModes
		for j = 0, 15 do tm[j] = false end
		tm[3] = true
		lc.transportModes = tm
		local back = lc.transportModes
		if back[3] then C.tmShift = 0 elseif back[2] then C.tmShift = 1 end
	end)
	return C.tmShift
end

-- Lane configurations (required: a segment without them makes the factory throw "Unknown exception").
-- transportModes is read from index 0.
function C.rebuildLanes(list)
	local out = {}
	local shift = C.transportModesWriteShift()
	for i, m in ipairs(list or {}) do
		local lc = api.type.LaneConfig.new()
		for _, k in ipairs({ "speed", "width", "height", "forward", "offset" }) do
			if m[k] ~= nil then pcall(function() lc[k] = m[k] end) end
		end
		if type(m.transportModes) == "table" then
			pcall(function()
				local tm = lc.transportModes
				for j = 0, 15 do
					pcall(function() tm[j + shift] = m.transportModes[j] == true end)
				end
				lc.transportModes = tm
			end)
		end
		out[i] = lc
	end
	return out
end

-- a street/track segment with only the fields a script proposal needs (the engine derives lanes, decorations...)
-- bare: geometry only (no street template, no precedence, no owner)
function C.minimalSegment(s, noOwner, bare)
	local se = C.newOf("SegmentAndEntity")
	se.entity = s.entity
	pcall(function() se.type = s.type end)
	local c = s.comp or {}
	local comp = se.comp
	local keys = bare and { "node0", "node1", "type", "typeIndex" }
		or { "node0", "node1", "type", "typeIndex", "roadType", "roadTemplate", "roadStyle", "roadDevelopmentLocked" }
	for _, k in ipairs(keys) do
		if c[k] ~= nil then pcall(function() comp[k] = c[k] end) end
	end
	if bare then
		for _, k in ipairs({ "tangent0", "tangent1" }) do
			if c[k] ~= nil then pcall(function() comp[k] = plain(c[k]) end) end
		end
		pcall(function() se.comp = comp end)
		return se
	end
	for _, k in ipairs({ "tangent0", "tangent1", "position0", "position1" }) do
		if c[k] ~= nil then pcall(function() comp[k] = plain(c[k]) end) end
	end
	-- the distance of a track from its axis (5 for the tracks the tool lays: a noise barrier is placed at that distance, so a
	-- track rebuilt with 0 gets its barrier in the middle of the track)
	if type(c.distance) == "number" and c.distance ~= 0 then pcall(function() comp.distance = c.distance end) end
	-- the road's decorations (the trees of a "_trees" template...) are not derived from the template
	if type(c.edgeDecorations) == "table" and #c.edgeDecorations > 0 then
		local okd, errd = pcall(function() comp.edgeDecorations = plain(c.edgeDecorations) end)
		if not okd then C.errors[#C.errors + 1] = "edgeDecorations: " .. tostring(errd):sub(1, 100) end
	end
	pcall(function() se.comp = comp end)
	if type(s.streetEdge) == "table" then
		pcall(function()
			local e = se.streetEdge
			e.precedenceNode0 = s.streetEdge.precedenceNode0
			e.precedenceNode1 = s.streetEdge.precedenceNode1
			se.streetEdge = e
		end)
	end
	if not noOwner and type(s.playerOwned) == "table" and type(s.playerOwned.player) == "number" then
		pcall(function()
			local po = C.newOf("PlayerOwned")
			po.player = s.playerOwned.player
			se.playerOwned = po
		end)
	end
	return se
end

-- A native proposal numbers its new entities in one sequence shared by nodes, segments and edge objects (nodes -1, -2,
-- -6, segments -3, -7...) and marks the new stops of a segment with placeholders (-400000000 - k). A script proposal
-- numbers new nodes and new segments separately from -1 and adds stops through edgeObjectsToAdd only.
function C.renumberStreet(st)
	local nodeMap, edgeMap = {}, {}
	local nodes = st.nodesToAdd or st.addedNodes or {}
	local edges = st.edgesToAdd or st.addedSegments or {}
	local k = 0
	for _, n in ipairs(nodes) do
		if type(n) == "table" and type(n.entity) == "number" and n.entity < 0 then
			k = k + 1
			nodeMap[n.entity] = -k
			n.entity = -k
		end
	end
	k = 0
	for _, e in ipairs(edges) do
		if type(e) == "table" and type(e.entity) == "number" and e.entity < 0 then
			k = k + 1
			edgeMap[e.entity] = -k
			e.entity = -k
		end
	end
	for _, e in ipairs(edges) do
		local c = type(e) == "table" and e.comp
		if type(c) == "table" then
			if type(c.node0) == "number" and nodeMap[c.node0] then c.node0 = nodeMap[c.node0] end
			if type(c.node1) == "number" and nodeMap[c.node1] then c.node1 = nodeMap[c.node1] end
			if type(c.objects) == "table" then
				local keep = {}
				for _, o in ipairs(c.objects) do
					if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = o end
				end
				c.objects = keep
			end
		end
	end
	for _, o in ipairs(st.edgeObjectsToAdd or {}) do
		if type(o) == "table" and type(o.segmentEntity) == "number" and edgeMap[o.segmentEntity] then
			o.segmentEntity = edgeMap[o.segmentEntity]
		end
	end
	return nodeMap, edgeMap
end

-- The objects (signals, stops) that stay on a segment a build replaces carry the originator's entity ids, which differ from
-- this game's: they are matched by their rank on the removed segment (the removed segments are already this game's own).
function C.existingObjectIds(st)
	local map = {}
	for _, rm in ipairs(st.removedSegments or st.edgesToRemove or {}) do
		if type(rm) == "table" and type(rm.entity) == "number" and rm.entity >= 0 and type(rm.comp) == "table" and type(rm.comp.objects) == "table" then
			local okc, lc = pcall(function() return api.engine.getComponent(rm.entity, api.type.ComponentType.BASE_EDGE) end)
			if okc and lc then
				for k, o in ipairs(rm.comp.objects) do
					local okl, lo = pcall(function() return lc.objects[k][1] end)
					if okl and type(lo) == "number" and type(o) == "table" and type(o[1]) == "number" then map[o[1]] = lo end
				end
			end
		end
	end
	return map
end

-- the existing objects of a captured added segment, as this game's ({ id, kind } pairs)
function C.localObjects(src, idMap)
	local list = {}
	local objs = type(src) == "table" and type(src.comp) == "table" and src.comp.objects
	if type(objs) ~= "table" then return list end
	for _, o in ipairs(objs) do
		if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then
			list[#list + 1] = { idMap[o[1]] or o[1], o[2] }
		end
	end
	return list
end

-- Proposal (native, from the construction tools) or SimpleProposal -> SimpleProposal for makeWorldBuildProposalCmd
-- opts.noStreet: constructions only (their .con template regenerates its own street connector)
-- opts.seed: deterministic seed for constructions that have none (a script ConstructionEntity needs params.seed)
function C.rebuildProposal(m, opts)
	opts = opts or {}
	local sp = C.newOf("SimpleProposal")
	local toAdd = m.constructionsToAdd or m.toAdd or {}
	local cons = {}
	for i, ce in ipairs(toAdd) do
		local c = C.newOf("ConstructionEntity")
		c.fileName = ce.fileName
		local params = ce.params
		if params == nil and type(ce.construction) == "table" then params = ce.construction.params end
		params = plain(params or {})
		if params.seed == nil then params.seed = (opts.seed or 0) + i end
		c.params = params
		if ce.transf then c.transf = plain(ce.transf) end
		-- -1 = nobody's (a town building the tool moved for the new street): it must stay a town building, not
		-- become the player's construction (which the player would also pay for)
		local player = ce.playerEntity
		if type(player) ~= "number" then player = api.engine.util.getPlayer() end
		c.playerEntity = player
		local name = ce.name
		if type(name) ~= "string" or name == "" then name = baseName(ce.fileName) end
		pcall(function() c.name = name end)
		cons[i] = c
	end
	sp.constructionsToAdd = cons
	local removeList = entityList(m.constructionsToRemove or m.toRemove)
	sp.constructionsToRemove = removeList
	if type(m.old2newByRank) == "table" then
		pcall(function()
			local map = {}
			for i, e in ipairs(removeList) do
				local v = m.old2newByRank[i] or m.old2newByRank[tostring(i)]
				if v ~= nil then map[e] = v end
			end
			sp.old2new = map
		end)
	elseif type(m.old2new) == "table" then pcall(function() sp.old2new = plain(m.old2new) end) end

	local st = m.streetProposal or m.proposal
	if type(st) == "table" and not opts.noStreet then
		local ssp = sp.streetProposal
		local variant = opts.variant or "full"
		if not opts.raw then C.renumberStreet(st) end
		local nodes = {}
		for i, n in ipairs(st.nodesToAdd or st.addedNodes or {}) do
			if variant == "full" then
				nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]")
			else
				local ne = C.newOf("NodeAndEntity")
				ne.entity = n.entity
				local comp = ne.comp
				comp.position = plain(n.comp and n.comp.position)
				ne.comp = comp
				nodes[i] = ne
			end
		end
		local edges = {}
		for i, s in ipairs(st.edgesToAdd or st.addedSegments or {}) do
			if variant == "full" then
				edges[i] = rebuild("SegmentAndEntity", s, "addedSegments[" .. i .. "]")
			else
				edges[i] = C.minimalSegment(s, variant ~= "minimal", variant == "bare")
			end
		end
		-- Properties return COPIES: the lists are built in Lua, assigned to the street proposal copy, and the copy is
		-- written back. Every segment needs its lanes (without them the engine asserts in CreateShapes): the lanes of
		-- its street template, as the native tool uses them.
		for i, e in ipairs(edges) do
			local src = (st.edgesToAdd or st.addedSegments)[i]
			local tmpl = src and src.comp and src.comp.roadTemplate
			local custom = C.customLanes(src)
			local lanes = custom and C.rebuildLanes(custom) or C.templateLanes(tmpl)
			if not lanes and src and src.comp and type(src.comp.laneConfigs) == "table" then lanes = C.rebuildLanes(src.comp.laneConfigs) end
			if lanes then
				local c = e.comp
				c.laneConfigs = lanes
				e.comp = c
			else
				C.errors[#C.errors + 1] = "segment " .. i .. ": no lanes for template " .. tostring(tmpl)
			end
		end
		ssp.nodesToAdd = nodes
		ssp.edgesToAdd = edges
		ssp.nodesToRemove = entityList(st.nodesToRemove or st.removedNodes)
		ssp.edgesToRemove = entityList(st.edgesToRemove or st.removedSegments)
		-- the lane connections of the existing nodes a build touches refer to the old segments: their node
		-- configurations must go (the native tools do the same), or the engine fails a lookup (map_util Get assert)
		pcall(function()
			local touched, list = {}, {}
			local function touch(n)
				if type(n) == "number" and n >= 0 and not touched[n] then
					touched[n] = true
					local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
					if okc and nc then list[#list + 1] = n end
				end
			end
			for _, e in ipairs(entityList(st.edgesToRemove or st.removedSegments)) do
				local be = type(e) == "number" and e >= 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
				if be then touch(be.node0); touch(be.node1) end
			end
			for _, sg in ipairs(st.edgesToAdd or st.addedSegments or {}) do
				if type(sg) == "table" and type(sg.comp) == "table" then touch(sg.comp.node0); touch(sg.comp.node1) end
			end
			for _, n in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do touched[n] = true end
			local keep = {}
			for _, n in ipairs(list) do
				local removed = false
				for _, r in ipairs(entityList(st.nodesToRemove or st.removedNodes)) do if r == n then removed = true end end
				if not removed then keep[#keep + 1] = n end
			end
			-- the configurations the native tool removed, when known (the computed set otherwise)
			local captured = entityList(st.nodeConfigsToRemove)
			if #captured > 0 then keep = captured end
			if #keep > 0 then ssp.nodeConfigsToRemove = keep end
		end)
		-- and the configurations it added (lane connections, crosswalks, traffic lights), with the native ids
		if opts.raw and #(st.nodeConfigsToAdd or {}) > 0 then
			local okc, errc = pcall(function()
				local cfgs = {}
				for i, m in ipairs(st.nodeConfigsToAdd) do
					local o = api.type.BaseNodeLaneConnectionAndEntity.new()
					o.entity = m.entity
					local cfg = o.comp
					local mc = m.comp or {}
					local lcs = {}
					for j, l in ipairs(mc.laneConnections or {}) do
						local lc = api.type.LaneConnection.new()
						lc.segment0 = l.segment0; lc.lane0 = l.lane0; lc.segment1 = l.segment1; lc.lane1 = l.lane1
						lc.withRoad = l.withRoad == true; lc.withTram = l.withTram == true
						lcs[j] = lc
					end
					cfg.laneConnections = lcs
					local cw = {}
					for j, x in ipairs(mc.crosswalks or {}) do cw[j] = x end
					cfg.crosswalks = cw
					pcall(function() cfg.trafficLightPreference = mc.trafficLightPreference end)
					pcall(function() cfg.doubleSlipSwitch = mc.doubleSlipSwitch == true end)
					pcall(function() cfg.userModifiedLaneConnections = mc.userModifiedLaneConnections == true end)
					o.comp = cfg
					cfgs[i] = o
				end
				ssp.nodeConfigsToAdd = cfgs
			end)
			if not okc then C.errors[#C.errors + 1] = "node configs: " .. tostring(errc):sub(1, 120) end
		end
		ssp.edgeObjectsToRemove = entityList(st.edgeObjectsToRemove)
		local objs = {}
		for i, o in ipairs(st.edgeObjectsToAdd or {}) do
			if type(o) == "table" and o.model then
				local eo = C.newOf("StreetEdgeObject")
				eo.edgeEntity = o.segmentEntity
				eo.param = o.param or 0.5
				eo.oneWay = o.oneWay == true
				eo.left = o.left == true
				eo.model = o.model
				local pl = o.playerEntity
				if type(pl) ~= "number" or pl < 0 then pl = api.engine.util.getPlayer() end
				eo.playerEntity = pl
				pcall(function() eo.name = o.name or "" end)
				objs[#objs + 1] = eo
			else
				C.errors[#C.errors + 1] = "edge object " .. i .. " without model (not replicated)"
			end
		end
		if #objs > 0 then ssp.edgeObjectsToAdd = objs end
		sp.streetProposal = ssp
	end
	return sp
end

-- A native Proposal (the type the construction tools produce) rebuilt from its compact form: street part only.
-- The engine accepts it as is (a SimpleProposal replacing existing segments is refused).
local function segmentFrom(s, where)
	local e = rebuild("SegmentAndEntity", s, where)
	if type(s.comp) == "table" and type(s.comp.distance) == "number" and s.comp.distance ~= 0 then
		pcall(function() local cd = e.comp; cd.distance = s.comp.distance; e.comp = cd end)
	end
	local tmpl = s.comp and s.comp.roadTemplate
	local custom = C.customLanes(s)
	local lanes = custom and C.rebuildLanes(custom) or C.templateLanes(tmpl)
	if not lanes and s.comp and type(s.comp.laneConfigs) == "table" then lanes = C.rebuildLanes(s.comp.laneConfigs) end
	if lanes then
		local c = e.comp
		c.laneConfigs = lanes
		e.comp = c
	end
	return e
end

-- {new id = {old ids}} maps; after reference translation they travel as { __pairs = { {k = id, v = {ids}} } }
local function idMap(m)
	if type(m) ~= "table" then return nil end
	local r = {}
	local entries = m.__pairs
	if not entries then
		entries = {}
		for k, v in pairs(m) do entries[#entries + 1] = { k = k, v = v } end
	end
	for _, en in ipairs(entries) do
		if type(en.k) == "number" and type(en.v) == "table" then
			local list = {}
			for i = 1, #en.v do list[i] = en.v[i] end
			r[en.k] = list
		end
	end
	return r
end

-- stage (diagnostics): how much of the street part is filled in, to find which assignment the factory refuses
-- 1 nothing, 2 +nodes, 3 +segments, 4 +removed nodes, 5 +removed segments, 6 +id maps (default: everything)
-- rm: how the removed segments are given: nil = rebuilt from the capture, "entity" = their id only, "live" = id and
-- the segment's current edge component in this game
function C.rebuildNativeProposal(m, stage, rm)
	stage = stage or 99
	local st = m.proposal
	if type(st) ~= "table" then error("no street part") end
	if #(m.toAdd or {}) > 0 or #(m.toRemove or {}) > 0 then error("constructions: not a street-only build") end
	local P = api.type.Proposal.new()
	local sp = P.proposal
	local nodes, edges, rnodes, redges = {}, {}, {}, {}
	local objIds = C.existingObjectIds(st)
	for i, n in ipairs(st.addedNodes or {}) do nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]") end
	for i, s in ipairs(st.addedSegments or {}) do
		local c = s.comp or {}
		if type(c.objects) == "table" then
			local keep = {}
			for _, o in ipairs(c.objects) do if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = { objIds[o[1]] or o[1], o[2] } end end
			c.objects = keep
		end
		edges[i] = segmentFrom(s, "addedSegments[" .. i .. "]")
	end
	for i, n in ipairs(st.removedNodes or {}) do rnodes[i] = rebuild("NodeAndEntity", n, "removedNodes[" .. i .. "]") end
	for i, s in ipairs(st.removedSegments or {}) do
		if rm and type(s.entity) == "number" then
			local se = rebuild("SegmentAndEntity", { entity = s.entity }, "removedSegments[" .. i .. "]")
			if rm == "live" then
				local okl, comp = pcall(function() return api.engine.getComponent(s.entity, api.type.ComponentType.BASE_EDGE) end)
				if okl and comp then pcall(function() se.comp = comp end) end
			end
			redges[i] = se
		else
			redges[i] = segmentFrom(s, "removedSegments[" .. i .. "]")
		end
	end
	if stage >= 2 then sp.addedNodes = nodes end
	if stage >= 3 then sp.addedSegments = edges end
	if stage >= 4 then sp.removedNodes = rnodes end
	if stage >= 5 then sp.removedSegments = redges end
	for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
		local mm = stage >= 6 and idMap(st[k])
		if mm then
			local okm, errm = pcall(function() sp[k] = mm end)
			if not okm then C.errors[#C.errors + 1] = k .. ": " .. tostring(errm):sub(1, 100) end
		end
	end
	if #(st.edgeObjectsToAdd or {}) > 0 then C.errors[#C.errors + 1] = "native form: stops not supported yet" end
	P.proposal = sp
	return P
end

-- The native proposal of a construction placed against a street (depot, station), rebuilt in this game from the tool's
-- capture: the construction itself (an engine-made native object, taken from the engine's own conversion of the same
-- construction: `conv` is that converted proposal), the street part as the tool made it (the junction node where the
-- entrance is stretched to the street, the split street), and the removed segments as the engine's own removal
-- proposal `rm` makes them. Returns the native Proposal.
function C.rebuildNativeWithConstruction(m, conv, rm)
	local st = m.proposal
	if type(st) ~= "table" then error("no street part") end
	local P = api.type.Proposal.new()
	local conList = {}
	conList[1] = conv.toAdd[1]
	P.toAdd = conList
	local sp = P.proposal
	local nodes, edges = {}, {}
	local objIds = C.existingObjectIds(st)
	for i, n in ipairs(st.addedNodes or {}) do nodes[i] = rebuild("NodeAndEntity", n, "addedNodes[" .. i .. "]") end
	for i, sg in ipairs(st.addedSegments or {}) do
		local c = sg.comp or {}
		if type(c.objects) == "table" then
			local keep = {}
			for _, o in ipairs(c.objects) do if type(o) == "table" and type(o[1]) == "number" and o[1] >= 0 then keep[#keep + 1] = { objIds[o[1]] or o[1], o[2] } end end
			c.objects = keep
		end
		edges[i] = segmentFrom(sg, "addedSegments[" .. i .. "]")
	end
	sp.addedNodes = nodes
	sp.addedSegments = edges
	if rm then
		local rsp = rm.proposal
		local ok1, e1 = pcall(function() sp.removedSegments = rsp.removedSegments end)
		if not ok1 then C.errors[#C.errors + 1] = "removedSegments: " .. tostring(e1):sub(1, 100) end
		local ok2, e2 = pcall(function() sp.removedNodes = rsp.removedNodes end)
		if not ok2 then C.errors[#C.errors + 1] = "removedNodes: " .. tostring(e2):sub(1, 100) end
	end
	-- the node configurations (lane connections...) the tool removed: only those this game has (removing one that does not
	-- exist is an engine assertion), and those it added, with the native ids
	local cfgRemove = {}
	for _, n in ipairs(entityList(st.nodeConfigsToRemove)) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then cfgRemove[#cfgRemove + 1] = n end
	end
	if #cfgRemove > 0 then
		local okc, ec = pcall(function() sp.nodeConfigsToRemove = cfgRemove end)
		if not okc then C.errors[#C.errors + 1] = "nodeConfigsToRemove: " .. tostring(ec):sub(1, 100) end
	end
	if #(st.nodeConfigsToAdd or {}) > 0 then
		local okc, errc = pcall(function()
			local cfgs = {}
			for i, mcfg in ipairs(st.nodeConfigsToAdd) do
				local o = api.type.BaseNodeLaneConnectionAndEntity.new()
				o.entity = mcfg.entity
				local cfg = o.comp
				local mc = mcfg.comp or {}
				local lcs = {}
				for j, l in ipairs(mc.laneConnections or {}) do
					local lc = api.type.LaneConnection.new()
					lc.segment0 = l.segment0; lc.lane0 = l.lane0; lc.segment1 = l.segment1; lc.lane1 = l.lane1
					lc.withRoad = l.withRoad == true; lc.withTram = l.withTram == true
					lcs[j] = lc
				end
				cfg.laneConnections = lcs
				local cw = {}
				for j, x in ipairs(mc.crosswalks or {}) do cw[j] = x end
				cfg.crosswalks = cw
				pcall(function() cfg.trafficLightPreference = mc.trafficLightPreference end)
				pcall(function() cfg.doubleSlipSwitch = mc.doubleSlipSwitch == true end)
				pcall(function() cfg.userModifiedLaneConnections = mc.userModifiedLaneConnections == true end)
				o.comp = cfg
				cfgs[i] = o
			end
			sp.nodeConfigsToAdd = cfgs
		end)
		if not okc then C.errors[#C.errors + 1] = "nodeConfigsToAdd: " .. tostring(errc):sub(1, 120) end
	end
	if type(st.frozenNodes) == "table" and #st.frozenNodes > 0 then
		local fz = {}
		for i, v in ipairs(st.frozenNodes) do fz[i] = v end
		local okf, ef = pcall(function() sp.frozenNodes = fz end)
		if not okf then C.errors[#C.errors + 1] = "frozenNodes: " .. tostring(ef):sub(1, 100) end
	end
	for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
		local mm = idMap(st[k])
		if mm then
			local okm, errm = pcall(function() sp[k] = mm end)
			if not okm then C.errors[#C.errors + 1] = k .. ": " .. tostring(errm):sub(1, 100) end
		end
	end
	P.proposal = sp
	return P
end

function C.proposalHasConstructions(m)
	return type(m) == "table" and #(m.constructionsToAdd or m.toAdd or {}) > 0
end

-- A native map read WITHOUT indexing it: map[k] on a C++ map inserts the key, which corrupts the live proposal
-- (the engine then loops forever applying it).
function C.marshalMap(v)
	if v == nil then return nil end
	local r = {}
	local ok = pcall(function()
		for k, x in pairs(v) do
			local list = {}
			pcall(function() for _, y in pairs(x) do list[#list + 1] = y end end)
			r[k] = list
		end
	end)
	return ok and r or nil
end

-- compact, serializable form of a native Proposal (from the construction tools): only what a replay needs
function C.compactProposal(p)
	local function get(o, k)
		local ok, v = pcall(function() return o[k] end)
		if ok then return v end
		return nil
	end
	local out = { toAdd = {}, toRemove = C.marshal(get(p, "toRemove")) or {}, old2new = C.marshal(get(p, "old2new")) }
	-- old2new is keyed by the removed constructions' entity ids, which differ between games: shipped by their rank in
	-- toRemove (references there are translated), rebuilt with each game's own ids
	pcall(function()
		if type(out.old2new) ~= "table" then return end
		local byRank = {}
		for i, e in ipairs(out.toRemove) do
			local v = out.old2new[e]
			if v ~= nil then byRank[i] = v end
		end
		out.old2newByRank = byRank
	end)
	local toAdd = get(p, "toAdd") or get(p, "constructionsToAdd")
	local n = 0
	pcall(function() n = #toAdd end)
	for i = 1, n do
		local ce = toAdd[i]
		local params = get(ce, "params")
		if params == nil then
			local con = get(ce, "construction")
			if con ~= nil then params = get(con, "params") end
		end
		out.toAdd[i] = {
			fileName = get(ce, "fileName"),
			params = C.marshal(params),
			transf = C.marshal(get(ce, "transf")),
			playerEntity = get(ce, "playerEntity"),
			name = get(ce, "name"),
		}
	end
	local st = get(p, "proposal") or get(p, "streetProposal")
	if st ~= nil then
		out.proposal = {
			addedNodes = C.marshal(get(st, "addedNodes")) or {},
			addedSegments = C.marshal(get(st, "addedSegments")) or {},
			removedNodes = C.marshal(get(st, "removedNodes")) or {},
			removedSegments = C.marshal(get(st, "removedSegments")) or {},
			edgeObjectsToAdd = C.marshal(get(st, "edgeObjectsToAdd")) or {},
			edgeObjectsToRemove = C.marshal(get(st, "edgeObjectsToRemove")) or {},
			nodeConfigsToAdd = C.marshal(get(st, "nodeConfigsToAdd")) or {},
			nodeConfigsToRemove = C.marshal(get(st, "nodeConfigsToRemove")) or {},
		}
	end
	return out
end

C.ARGS = {
	makeWorldBuildProposalCmd = { "Proposal", "Context" },
	makeVehicleBuyCmd = { false, false, "TransportVehicleConfig" },
	makeVehicleReplaceCmd = { false, "TransportVehicleConfig" },
	makeLineCreateCmd = { false, "Vec3f", false, "Line" },
	makeLineUpdateCmd = { false, "Line" },
	makeEntitySetColorCmd = { false, "Vec3f" },
}

function C.rebuildArgs(fn, margs, opts)
	C.errors = {}
	local types = C.ARGS[fn] or {}
	local args = {}
	local n = margs.n or #margs
	for i = 1, n do
		local m = margs[i]
		local tn = types[i]
		if type(m) ~= "table" then
			args[i] = m
		elseif tn == "Proposal" then
			if opts.variant == "native" then args[i] = C.rebuildNativeProposal(m) else args[i] = C.rebuildProposal(m, opts) end
		elseif tn == "Context" and m.__player then
			-- the build context of the native tools: this game's player (opts.ctx selects the flags)
			local k = opts.ctx or "terrain"
			if k == "nil" then
				args[i] = nil
			else
				local ctx = api.type.Context.new()
				ctx.checkTerrainAlignment = (k == "terrain" or k == "terrainNoCleanup")
				ctx.cleanupStreetGraph = (k ~= "terrainNoCleanup" and k ~= "plainNoCleanup")
				ctx.gatherBuildings = (k == "terrain" or k == "terrainNoCleanup")
				ctx.gatherFields = true
				ctx.player = api.engine.util.getPlayer()
				args[i] = ctx
			end
		elseif tn == "Context" then
			local okc, ctx = pcall(function() return fill(C.newOf("Context"), m, "Context", "context") end)
			args[i] = okc and ctx or nil
		elseif tn then
			args[i] = rebuild(tn, m, fn .. "#" .. i)
		elseif (m.__ud and not isVec(m)) or m.__unknown then
			error("argument " .. i .. " is a native object without rebuild rule")
		else
			args[i] = plain(m)
		end
	end
	return args, n
end

-- every command factory of api.cmd (pairs() cannot enumerate the native table)
C.FACTORIES = {
	"makeAnimalSetStateCmd", "makeAnimalSpawnAtCmd", "makeCreateIndustryExtendProposalCmd", "makeCustomEntityCreateCmd",
	"makeCustomEntityDestroyCmd", "makeCustomEntityUpdateStateCmd", "makeCustomEntityUpdateTransformationCmd",
	"makeCustomVehicleCreateOrUpdateCmd", "makeEntitySetColorCmd", "makeEntitySetEmissionsCmd", "makeEntitySetNameCmd",
	"makeEntitySetPlayerCmd", "makeGameAddPlayerCmd", "makeGameSetCalendarSpeedCmd", "makeGameSetCloudCoverageCmd",
	"makeGameSetDateCmd", "makeGameSetSpeedCmd", "makeGameSetTimeOfDayCmd", "makeIndustrySetDespawnTimeCmd",
	"makeIndustrySetManualDevelopmentCmd", "makeJournalBookAssetCmd", "makeJournalClearAllCmd", "makeJournalLogEntryCmd",
	"makeLineCreateCmd", "makeLineDestroyCmd", "makeLineUpdateCmd", "makeScriptingSendEventCmd",
	"makeStockListDiscardCargoCmd", "makeStockListSetModifiersCmd", "makeStockListSetStocksCargoTypeCmd",
	"makeTownAutoDetectConnectionsCmd", "makeTownBuildingSetBlockedDevelopmentCmd", "makeTownConnectWithIndustriesCmd",
	"makeTownCreateCmd", "makeTownCustomDistributionWeightsCmd", "makeTownDestroyCmd", "makeTownDevelopAtCmd",
	"makeTownSetDevelopmentActiveCmd", "makeTownSetInitialLandUseCapacitiesCmd", "makeTownUpdateCargoNeedsCmd",
	"makeTownUpdateSizeCmd", "makeVehicleBuyCmd", "makeVehicleReplaceCmd", "makeVehicleReverseCmd", "makeVehicleSellCmd",
	"makeVehicleSendToDepotCmd", "makeVehicleSetLineCmd", "makeVehicleSetManualDepartureCmd", "makeVehicleSetModifiersCmd",
	"makeVehicleSetStoppedByUserCmd", "makeVehicleTryToDepartCmd", "makeWorldBuildProposalCmd", "makeWorldChangeWindCmd",
	"makeWorldReplaceTerrainCmd", "makeWorldSetBulldozableCmd",
}

end
