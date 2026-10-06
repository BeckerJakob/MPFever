-- MPFever entity references.
--
-- Entity ids are NOT the same on every machine: the UI of one game allocates entities the others never see
-- (previews, store windows...), so every entity allocated afterwards can get a different id. An action therefore
-- never travels with a raw id for something built during the session: the originator replaces each entity id with a
-- reference describing the entity (construction file + position, depot/station = its construction + index, road
-- node = position, road edge = its end positions, station group = one of its stations, line/vehicle created during
-- the session = the key of the action that created it). Every game resolves the reference against its own world:
-- the same id is used when it still describes the same thing (everything that came from the save), otherwise the
-- entity is searched for.

local R = {}

local CT = function(name) return api.type.ComponentType[name] end

local function comp(e, name)
	if type(e) ~= "number" or e < 0 then return nil end
	local ok, exists = pcall(function() return api.engine.entityExists(e) end)
	if not ok or not exists then return nil end
	local okc, c = pcall(function() return api.engine.getComponent(e, CT(name)) end)
	if okc then return c end
	return nil
end

local function pos3(v)
	if v == nil then return nil end
	local ok, p = pcall(function() return { x = v.x, y = v.y, z = v.z } end)
	if ok and type(p.x) == "number" then return p end
	return nil
end

local function matPos(m)
	if m == nil then return nil end
	local ok, p = pcall(function() return { x = m[13], y = m[14], z = m[15] } end)
	if ok and type(p.x) == "number" then return p end
	return nil
end

R.matPos = matPos

local function dist(a, b)
	if not a or not b then return math.huge end
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function listIndex(list, e)
	local found = nil
	pcall(function()
		for i = 1, #list do if list[i] == e then found = i end end
	end)
	return found
end

local function nodePos(n)
	local c = comp(n, "BASE_NODE")
	return c and pos3(c.position) or nil
end

-- ------------------------------------------------------------------ describe (originator side)

local describe

local function describeCon(e)
	local c = comp(e, "CONSTRUCTION")
	if not c then return nil end
	return { k = "con", id = e, f = c.fileName, p = matPos(c.transf) }
end

local function describeEdge(e)
	local c = comp(e, "BASE_EDGE")
	if not c then return nil end
	return { k = "edge", id = e, p0 = nodePos(c.node0), p1 = nodePos(c.node1) }
end

describe = function(kind, e)
	if type(e) ~= "number" or e < 0 then return nil end
	if kind == "con" then return describeCon(e) end
	if kind == "node" then
		local p = nodePos(e)
		return p and { k = "node", id = e, p = p } or nil
	end
	if kind == "edge" then return describeEdge(e) end
	if kind == "depot" then
		local con = nil
		pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(e) end)
		local cd = describeCon(con)
		local cc = comp(con, "CONSTRUCTION")
		if cd and cc then return { k = "depot", id = e, con = cd, i = listIndex(cc.depots, e) } end
		return { k = "depot", id = e }
	end
	if kind == "station" then
		local con = nil
		pcall(function() con = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(e) end)
		local cd = describeCon(con)
		local cc = comp(con, "CONSTRUCTION")
		if cd and cc then return { k = "station", id = e, con = cd, i = listIndex(cc.stations, e) } end
		-- a roadside stop: an edge object
		local edge = nil
		pcall(function() edge = api.engine.system.streetSystem.getEdgeForEdgeObject(e) end)
		local ed = describeEdge(edge)
		if ed then
			local side = nil
			pcall(function()
				local be = comp(edge, "BASE_EDGE")
				for i = 1, #be.objects do
					if be.objects[i][1] == e then side = be.objects[i][2] end
				end
			end)
			return { k = "station", id = e, edge = ed, side = side }
		end
		return { k = "station", id = e }
	end
	if kind == "sg" then
		local sg = comp(e, "STATION_GROUP")
		local first = nil
		pcall(function() first = sg.stations[1] end)
		return { k = "sg", id = e, st = describe("station", first) }
	end
	return { k = kind, id = e }
end
R.describe = describe

-- ------------------------------------------------------------------ resolve (every game)

-- Every entity with a component. forEachEntityWithComponent refuses some types ("Cannot loop over this component type":
-- BASE_EDGE, BASE_NODE...): the street graph comes from the street system instead.
local function streetMap()
	local ok, m = pcall(function() return api.engine.system.streetSystem.getNode2SegmentMap() end)
	return ok and m or {}
end

function R.allNodes()
	local r = {}
	for n, _ in pairs(streetMap()) do r[#r + 1] = n end
	table.sort(r)
	return r
end

function R.allEdges()
	local seen, r = {}, {}
	for _, segs in pairs(streetMap()) do
		local n = 0
		pcall(function() n = #segs end)
		for i = 1, n do
			local e = segs[i]
			if type(e) == "number" and not seen[e] then seen[e] = true; r[#r + 1] = e end
		end
	end
	table.sort(r)
	return r
end

R.loopErrors = {}
function R.entitiesWith(compName)
	if compName == "BASE_EDGE" then return R.allEdges() end
	if compName == "BASE_NODE" then return R.allNodes() end
	if compName == "LINE" then
		local r = {}
		pcall(function() local l = api.engine.system.lineSystem.getLines(); for i = 1, #l do r[#r + 1] = l[i] end end)
		return r
	end
	local r = {}
	local ok, err = pcall(function()
		api.engine.forEachEntityWithComponent(function(e) r[#r + 1] = e end, CT(compName))
	end)
	if not ok then
		r = {}
		local ok2, list = pcall(function() return api.engine.getEntitiesWithComponent(CT(compName)) end)
		if ok2 and list then
			pcall(function() for i = 1, #list do r[#r + 1] = list[i] end end)
		else
			R.loopErrors[compName] = tostring(err):sub(1, 120)
		end
	end
	return r
end

local function nearestWith(compName, accept)
	local best, bestD = nil, math.huge
	for _, e in ipairs(R.entitiesWith(compName)) do
		local okd, d = pcall(accept, e)
		if okd and d and d < bestD then best, bestD = e, d end
	end
	return best, bestD
end

local resolve

local function resolveCon(r)
	if not r then return nil end
	local c = comp(r.id, "CONSTRUCTION")
	if c and c.fileName == r.f and dist(matPos(c.transf), r.p) < 1 then return r.id end
	local e, d = nearestWith("CONSTRUCTION", function(x)
		local cx = comp(x, "CONSTRUCTION")
		if cx and cx.fileName == r.f then return dist(matPos(cx.transf), r.p) end
		return nil
	end)
	if e and d < 3 then return e end
	return nil
end

local function resolveNode(r)
	if dist(nodePos(r.id), r.p) < 0.5 then return r.id end
	local e, d = nearestWith("BASE_NODE", function(x) return dist(nodePos(x), r.p) end)
	if e and d < 1 then return e end
	return nil
end

local function resolveEdge(r)
	local function score(x)
		local c = comp(x, "BASE_EDGE")
		if not c then return nil end
		local a, b = nodePos(c.node0), nodePos(c.node1)
		return math.min(math.max(dist(a, r.p0), dist(b, r.p1)), math.max(dist(a, r.p1), dist(b, r.p0)))
	end
	local s = score(r.id)
	if s and s < 0.5 then return r.id end
	local e, d = nearestWith("BASE_EDGE", score)
	if e and d < 1 then return e end
	return nil
end

resolve = function(r, bind)
	if type(r) ~= "table" then return r end
	if r.key and bind and bind[r.key] then return bind[r.key] end
	local k = r.k
	if k == "con" then return resolveCon(r) end
	if k == "node" then return resolveNode(r) end
	if k == "edge" then return resolveEdge(r) end
	if k == "depot" then
		if r.con then
			local con = resolveCon(r.con)
			local cc = comp(con, "CONSTRUCTION")
			local e = nil
			if cc and r.i then pcall(function() e = cc.depots[r.i] end) end
			if e then return e end
		end
		return comp(r.id, "VEHICLE_DEPOT") and r.id or nil
	end
	if k == "station" then
		if r.con then
			local con = resolveCon(r.con)
			local cc = comp(con, "CONSTRUCTION")
			local e = nil
			if cc and r.i then pcall(function() e = cc.stations[r.i] end) end
			return e
		end
		if r.edge then
			local edge = resolveEdge(r.edge)
			local be = comp(edge, "BASE_EDGE")
			local e = nil
			if be then
				pcall(function()
					for i = 1, #be.objects do
						if r.side == nil or be.objects[i][2] == r.side then e = e or be.objects[i][1] end
					end
				end)
			end
			return e
		end
		return comp(r.id, "STATION") and r.id or nil
	end
	if k == "sg" then
		if r.st then
			local st = resolve(r.st, bind)
			if st then
				local sg = nil
				pcall(function() sg = api.engine.system.stationGroupSystem.getStationGroup(st) end)
				if type(sg) == "number" and sg >= 0 then return sg end
			end
		end
		return comp(r.id, "STATION_GROUP") and r.id or nil
	end
	if k == "player" then
		return api.engine.util.getPlayer()
	end
	-- plain id (things from the save keep their id everywhere)
	local ok, exists = pcall(function() return api.engine.entityExists(r.id) end)
	if ok and exists then return r.id end
	return nil
end
R.resolve = resolve

-- ------------------------------------------------------------------ which arguments are entities

-- per command: argument index -> kind
R.ARGS = {
	makeVehicleBuyCmd = { [1] = "player", [2] = "depot" },
	makeVehicleSellCmd = { [1] = "veh" },
	makeVehicleSetLineCmd = { [1] = "veh", [2] = "line" },
	makeVehicleSendToDepotCmd = { [1] = "veh", [2] = "depot" },
	makeVehicleReverseCmd = { [1] = "veh" },
	makeVehicleReplaceCmd = { [1] = "veh" },
	makeVehicleSetStoppedByUserCmd = { [1] = "veh" },
	makeVehicleTryToDepartCmd = { [1] = "veh" },
	makeVehicleSetManualDepartureCmd = { [1] = "veh" },
	makeVehicleSetModifiersCmd = { [1] = "veh" },
	makeLineCreateCmd = { [3] = "player" },
	makeLineUpdateCmd = { [1] = "line" },
	makeLineDestroyCmd = { [1] = "line" },
	makeEntitySetNameCmd = { [1] = "any" },
	makeEntitySetColorCmd = { [1] = "any" },
}

-- replace entity ids by references, in place, in marshalled arguments (originator side)
-- rev: local entity -> creation key (lines and vehicles created by replicated actions)
function R.translateOut(fn, margs, rev)
	rev = rev or {}
	local function ref(kind, e)
		if type(e) ~= "number" or e < 0 then return e end
		if rev[e] then return { __ref = true, key = rev[e], id = e, k = kind } end
		local d = (kind == "player") and { k = "player", id = e } or describe(kind, e)
		d = d or { k = kind, id = e }
		d.__ref = true
		return d
	end
	for i, kind in pairs(R.ARGS[fn] or {}) do margs[i] = ref(kind, margs[i]) end
	if fn == "makeLineCreateCmd" or fn == "makeLineUpdateCmd" then
		local line = margs[fn == "makeLineCreateCmd" and 4 or 2]
		if type(line) == "table" then
			for _, stop in ipairs(line.stops or {}) do
				if type(stop) == "table" then stop.stationGroup = ref("sg", stop.stationGroup) end
			end
		end
	end
	if fn == "makeWorldBuildProposalCmd" and type(margs[1]) == "table" then
		local p = margs[1]
		for i, e in ipairs(p.toRemove or {}) do p.toRemove[i] = ref("con", e) end
		for _, ce in ipairs(p.toAdd or {}) do
			if type(ce.playerEntity) == "number" then ce.playerEntity = ref("player", ce.playerEntity) end
		end
		local st = p.proposal
		if type(st) == "table" then
			for _, n in ipairs(st.addedNodes or {}) do
				if type(n) == "table" and type(n.entity) == "number" and n.entity >= 0 then n.entity = ref("node", n.entity) end
			end
			for _, s in ipairs(st.addedSegments or {}) do
				if type(s) == "table" then
					if type(s.entity) == "number" and s.entity >= 0 then s.entity = ref("edge", s.entity) end
					if type(s.comp) == "table" then
						if type(s.comp.node0) == "number" and s.comp.node0 >= 0 then s.comp.node0 = ref("node", s.comp.node0) end
						if type(s.comp.node1) == "number" and s.comp.node1 >= 0 then s.comp.node1 = ref("node", s.comp.node1) end
					end
				end
			end
			for _, n in ipairs(st.removedNodes or {}) do
				if type(n) == "table" and type(n.entity) == "number" then n.entity = ref("node", n.entity) end
			end
			for _, s in ipairs(st.removedSegments or {}) do
				if type(s) == "table" then
					if type(s.entity) == "number" then s.entity = ref("edge", s.entity) end
					if type(s.comp) == "table" then
						if type(s.comp.node0) == "number" and s.comp.node0 >= 0 then s.comp.node0 = ref("node", s.comp.node0) end
						if type(s.comp.node1) == "number" and s.comp.node1 >= 0 then s.comp.node1 = ref("node", s.comp.node1) end
					end
				end
			end
			-- node configurations: their node, and the existing segments their lane connections and crosswalks use
			for _, m in ipairs(st.nodeConfigsToAdd or {}) do
				if type(m) == "table" then
					if type(m.entity) == "number" and m.entity >= 0 then m.entity = ref("node", m.entity) end
					local mc = m.comp
					if type(mc) == "table" then
						for _, l in ipairs(mc.laneConnections or {}) do
							if type(l) == "table" then
								if type(l.segment0) == "number" and l.segment0 >= 0 then l.segment0 = ref("edge", l.segment0) end
								if type(l.segment1) == "number" and l.segment1 >= 0 then l.segment1 = ref("edge", l.segment1) end
							end
						end
						for i, x in ipairs(mc.crosswalks or {}) do
							if type(x) == "number" and x >= 0 then mc.crosswalks[i] = ref("edge", x) end
						end
					end
				end
			end
			for i, n in ipairs(st.nodeConfigsToRemove or {}) do
				if type(n) == "number" and n >= 0 then st.nodeConfigsToRemove[i] = ref("node", n) end
			end
			-- existing ids in the new/old maps (keys and values)
			for _, k in ipairs({ "new2oldSegments", "old2newSegments", "new2oldNodes", "old2newNodes" }) do
				local mm = st[k]
				if type(mm) == "table" then
					local kind = k:find("Nodes") and "node" or "edge"
					local out = {}
					for key, list in pairs(mm) do
						if type(list) == "table" and type(key) == "number" then
							local l2 = {}
							for i = 1, #list do
								local x = list[i]
								l2[i] = (type(x) == "number" and x >= 0) and ref(kind, x) or x
							end
							out[#out + 1] = { k = (key >= 0) and ref(kind, key) or key, v = l2 }
						end
					end
					st[k] = { __pairs = out }
				end
			end
		end
	end
	return margs
end

-- resolve every reference found in marshalled arguments (every game); returns the list of what is missing
function R.translateIn(margs, bind)
	local missing = {}
	local function walk(t, depth)
		if depth > 12 then return end
		for k, v in pairs(t) do
			if type(v) == "table" then
				if v.__ref then
					local e = resolve(v, bind)
					if e == nil then
						missing[#missing + 1] = tostring(v.k) .. "#" .. tostring(v.id) .. (v.key and ("/" .. v.key) or "")
						t[k] = -999999999
					else
						t[k] = e
					end
				else
					walk(v, depth + 1)
				end
			end
		end
	end
	walk(margs, 0)
	return missing
end

-- id-independent world fingerprint parts
function R.contentHash(hashStr, dumpFn)
	local parts = {}
	local function part(name, fn)
		local ok, v = pcall(fn)
		parts[name] = ok and v or ("ERR " .. tostring(v):sub(1, 100))
	end
	local function count(cname, contentFn)
		local n, acc = 0, 0
		for _, e in ipairs(R.entitiesWith(cname)) do
			n = n + 1
			if contentFn then
				local s = contentFn(e)
				if s then acc = (acc + hashStr(0, s)) % 4294967296 end
			end
		end
		if R.loopErrors[cname] then return "cannot list " .. cname end
		return n .. "/" .. acc
	end
	local function r1(v) return v and string.format("%.0f", v) or "?" end
	part("constructions", function() return count("CONSTRUCTION", function(e)
		local c = comp(e, "CONSTRUCTION")
		local p = c and matPos(c.transf)
		return c and (tostring(c.fileName) .. "@" .. r1(p and p.x) .. "," .. r1(p and p.y)) or nil
	end) end)
	part("edges", function() return count("BASE_EDGE", function(e)
		local c = comp(e, "BASE_EDGE")
		if not c then return nil end
		local a, b = nodePos(c.node0), nodePos(c.node1)
		if not a or not b then return nil end
		local s1 = r1(a.x) .. "," .. r1(a.y)
		local s2 = r1(b.x) .. "," .. r1(b.y)
		local swapped = false
		if s1 > s2 then s1, s2 = s2, s1; swapped = true end
		-- what the road carries beyond its template: decorations (side and model) and which vehicles each lane takes (tram)
		local deco, lanesig = "", ""
		pcall(function()
			local t = {}
			for k = 1, #c.edgeDecorations do
				-- (the side is relative to the segment's direction, which may differ between games: the canonical one is used)
				local left = c.edgeDecorations[k][2] and true or false
				if swapped then left = not left end
				t[#t + 1] = tostring(c.edgeDecorations[k][1]) .. (left and "l" or "r")
			end
			table.sort(t)
			deco = table.concat(t, ",")
		end)
		pcall(function()
			local t = {}
			for k = 1, #c.laneConfigs do
				local m = 0
				for j = 0, 15 do if c.laneConfigs[k].transportModes[j] then m = m + 2 ^ j end end
				t[#t + 1] = m
			end
			table.sort(t)
			lanesig = table.concat(t, ",")
		end)
		local okd, nd = pcall(function() return #c.edgeDecorations end)
		return s1 .. "-" .. s2 .. tostring(c.roadTemplate) .. "/" .. tostring(okd and nd or 0) .. "/" .. tostring(c.roadStyle)
			.. "/" .. tostring(c.roadType) .. "/" .. tostring(c.type) .. "/" .. tostring(c.typeIndex) .. "/" .. deco .. "/" .. lanesig .. "/d" .. tostring(c.distance)
	end) end)
	part("vehicles", function() return count("TRANSPORT_VEHICLE", function(e)
		local c = comp(e, "MOVE_PATH")
		return c and dumpFn(c.dyn) or "depot"
	end) end)
	part("townBuildings", function() return count("TOWN_BUILDING") end)
	part("persons", function() return count("SIM_PERSON") end)
	part("stations", function() return count("STATION") end)
	part("lines", function() return count("LINE") end)
	part("edgeObjects", function()
		local n, acc = 0, 0
		for eo, edge in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap() or {}) do
			local c = comp(eo, "EDGE_OBJECT")
			local be = comp(edge, "BASE_EDGE")
			local a = be and nodePos(be.node0)
			n = n + 1
			if c and a then acc = (acc + hashStr(0, tostring(c.edgeObjectConstruction) .. r1(a.x) .. r1(a.y))) % 4294967296 end
		end
		return n .. "/" .. acc
	end)
	return parts
end

return R
