-- MPFever autotest scenarios (dev only): stops, buy, line, split, road types, camera.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- Stops inside an engine-made proposal
function runStops2(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local function mem(o)
		local t = {}
		pcall(function() for _, k in ipairs(C.members(o) or {}) do t[#t + 1] = k end end)
		return table.concat(t, ",")
	end
	pcall(function() log("STOPS2 EdgeObject members: " .. mem(api.type.EdgeObject.new())) end)
	pcall(function() log("STOPS2 ModelInstance members: " .. mem(api.type.ModelInstance.new())) end)
	pcall(function() log("STOPS2 StreetProposal members: " .. mem(api.type.StreetProposal.new())) end)
	for _, path in ipairs({ "api.type.StreetProposal.EdgeObject", "api.type.StreetProposalEdgeObject", "api.type.Proposal.StreetProposal",
		"api.type.ProposalEdgeObject", "api.type.StreetProposal.NodeAndEntity" }) do
		local cur = _G
		for part in path:gmatch("[^.]+") do if cur ~= nil then local ok, v = pcall(function() return cur[part] end); cur = ok and v or nil end end
		local ok, obj = false, nil
		if cur ~= nil then ok, obj = pcall(function() return cur.new() end) end
		log("STOPS2 type " .. path .. " = " .. type(cur) .. (ok and obj and (" new ok, members: " .. mem(obj)) or ""))
	end
	pcall(function()
		local keys = {}
		for k, _ in pairs(api.type) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		log("STOPS2 api.type: " .. table.concat(keys, ","))
	end)
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local ctx = playerContext()
	local function try(name, mk)
		local ok, res = pcall(function() return api.cmd.makeWorldBuildProposalCmd(mk(), ctx, false, true) end)
		log("STOPS2 " .. name .. ": factory " .. (ok and (res and "OK" or "nil") or shortErr(res)))
		return ok and res or nil
	end
	try("replaceSegment as is", function() return api.engine.util.proposal.replaceSegment(E) end)
	try("replaceSegment reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		P.proposal = sp
		return P
	end)
	try("replaceSegment segments reassigned", function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		sp.addedSegments = segs
		P.proposal = sp
		return P
	end)
	local withStop
	withStop = function()
		local P = api.engine.util.proposal.replaceSegment(E)
		local sp = P.proposal
		local segs = sp.addedSegments
		local seg = segs[1]
		local c = seg.comp
		c.objects = { { -400000000, 1 } }
		seg.comp = c
		segs[1] = seg
		sp.addedSegments = segs
		local EOT = nil
		pcall(function() EOT = api.type.StreetProposal.EdgeObject end)
		local eo = EOT and EOT.new() or api.type.EdgeObject.new()
		pcall(function() eo.resultEntity = -1 end)
		pcall(function() eo.category = 0 end)
		pcall(function() eo.segmentEntity = seg.entity end)
		pcall(function() eo.left = true end)
		pcall(function() eo.oneWay = false end)
		pcall(function() eo.name = "MPF stop" end)
		pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
		pcall(function() eo.param = 0.5 end)
		pcall(function() eo.edgeObjectConstruction = STOP_MODEL end)
		pcall(function() eo.model = STOP_MODEL end)
		sp.edgeObjectsToAdd = { eo }
		P.proposal = sp
		log("STOPS2 stop object: " .. C.ser(C.marshal(eo)):sub(1, 400))
		return P
	end
	-- a template stop object: the engine re-adds the stops of a segment it replaces
	local T = nil
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and #c.objects > 0 then T = e; break end
	end
	local template = nil
	if T then
		local okt, errt = pcall(function()
			local P0 = api.engine.util.proposal.replaceSegment(T)
			local sp0 = P0.proposal
			local list = sp0.edgeObjectsToAdd
			log("STOPS2 template segment " .. T .. ": objects to add " .. #list .. ", segment objects " .. C.ser(C.marshal(sp0.addedSegments[1].comp.objects)))
			if #list > 0 then
				template = list[1]
				log("STOPS2 template members: " .. mem(template) .. " = " .. C.ser(C.marshal(template)):sub(1, 600))
				pcall(function() log("STOPS2 template modelInstance: " .. mem(template.modelInstance) .. " modelId=" .. tostring(template.modelInstance.modelId)) end)
			end
		end)
		if not okt then log("STOPS2 template failed: " .. tostring(errt)) end
	end
	-- template from the engine's own conversion of a stop on a road outside the map (refused, nothing is built)
	local function afterTemplate()
		if not template then AUTO.results[#AUTO.results + 1] = "no stop template"; return autoFinish() end
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
		local cmd = try("replaceSegment + stop (engine template)", withStop)
		if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
		O.sendCommand(cmd, function(res, success)
			local why = ""
			if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
			local n = 0
			pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
			local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
			log("STOPS2 " .. line)
			AUTO.results[#AUTO.results + 1] = line
			G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
		end)
	end
	if not template then
		local cE = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
		local sp = api.type.SimpleProposal.new()
		local ssp = sp.streetProposal
		-- right on top of the target street: refused for collision, the conversion still comes back
		local q, q2 = nodePosition(cE.node0), nodePosition(cE.node1)
		local px, py, pz = q.x + 1, q.y + 1, q.z
		local pz2 = q2.z
		local n1 = api.type.NodeAndEntity.new(); n1.entity = -1
		local b1 = n1.comp; b1.position = api.type.Vec3f.new(px, py, pz); n1.comp = b1
		local n2 = api.type.NodeAndEntity.new(); n2.entity = -2
		local b2 = n2.comp; b2.position = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2); n2.comp = b2
		local e = api.type.SegmentAndEntity.new(); e.entity = -3; e.type = 0
		local ec = e.comp
		ec.node0 = -1; ec.node1 = -2
		local tx, ty, tz = q2.x - q.x, q2.y - q.y, pz2 - pz
		ec.tangent0 = api.type.Vec3f.new(tx, ty, tz); ec.tangent1 = api.type.Vec3f.new(tx, ty, tz)
		ec.position0 = api.type.Vec3f.new(px, py, pz); ec.position1 = api.type.Vec3f.new(q2.x + 1, q2.y + 1, pz2)
		ec.type = 0; ec.typeIndex = -1
		ec.roadTemplate = cE.roadTemplate; ec.roadStyle = cE.roadStyle; ec.roadType = cE.roadType
		ec.laneConfigs = C.templateLanes(cE.roadTemplate)
		e.comp = ec
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		local modelName = (C.ROLE == "host") and "stations/street/small_stops/small_old.con" or "::/stations/street/small_stops/small_old.con"
		log("STOPS2 template probe with model " .. modelName)
		o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false; o.model = modelName
		o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF template"
		ssp.nodesToAdd = { n1, n2 }
		ssp.edgesToAdd = { e }
		ssp.edgeObjectsToAdd = { o }
		sp.streetProposal = ssp
		local okc, cmdT = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true) end)
		log("STOPS2 template probe factory: " .. (okc and "OK" or shortErr(cmdT)))
		if not okc then return afterTemplate() end
		O.sendCommand(cmdT, function(res, success)
			local okx, errx = pcall(function()
				local list = res.proposal.proposal.edgeObjectsToAdd
				log("STOPS2 template probe: success=" .. tostring(success) .. ", converted stops " .. #list)
				if #list > 0 then
					template = list[1]
					log("STOPS2 template members: " .. mem(template))
					pcall(function() log("STOPS2 template modelId=" .. tostring(template.modelInstance.modelId) .. " category=" .. tostring(template.category)) end)
				end
			end)
			if not okx then log("STOPS2 template read failed: " .. tostring(errx)) end
			G.waits[#G.waits + 1] = { at = G.frames + 5, fn = afterTemplate }
		end)
		return
	end
	if template then
		withStop = function()
			local P = api.engine.util.proposal.replaceSegment(E)
			local sp = P.proposal
			local segs = sp.addedSegments
			local seg = segs[1]
			local c = seg.comp
			c.objects = { { -400000000, 1 } }
			seg.comp = c
			segs[1] = seg
			sp.addedSegments = segs
			local eo = template
			pcall(function() eo.resultEntity = -1 end)
			pcall(function() eo.segmentEntity = seg.entity end)
			pcall(function() eo.left = false end)
			pcall(function() eo.name = "MPF stop" end)
			pcall(function() eo.playerEntity = api.engine.util.getPlayer() end)
			pcall(function()
				local mi = eo.modelInstance
				local tr = mi.transf
				local a, b = c.position0, c.position1
				local V = api.type.Vec4f.new
				mi.transf = api.type.Mat4f.new(V(tr[1], tr[2], tr[3], tr[4]), V(tr[5], tr[6], tr[7], tr[8]), V(tr[9], tr[10], tr[11], tr[12]),
					V((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1))
				eo.modelInstance = mi
			end)
			sp.edgeObjectsToAdd = { eo }
			P.proposal = sp
			return P
		end
	end
	local cmd = try("replaceSegment + stop", withStop)
	if not cmd then AUTO.results[#AUTO.results + 1] = "stop: factory refused"; return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		local n = 0
		pcall(function() n = #api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE).objects end)
		local line = "stop on town segment " .. E .. ": " .. (success and "BUILT" or ("refused " .. why))
		log("STOPS2 " .. line)
		AUTO.results[#AUTO.results + 1] = line
		G.waits[#G.waits + 1] = { at = G.frames + 30, fn = autoFinish }
	end)
end

H.stops2 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops2, p)
	if not ok then
		log("STOPS2 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops2 error " .. tostring(err)
		autoFinish()
	end
end

-- Vehicle purchase scenario: the same request the depot window sends (through the UI hook file)
function runBuy(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local vehicles = R.entitiesWith("TRANSPORT_VEHICLE")
	local pick = nil
	for _, v in ipairs(vehicles) do
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if tv and type(tv.depot) == "number" and tv.depot >= 0 and api.engine.entityExists(tv.depot) then pick = { v = v, tv = tv }; break end
	end
	if not pick then
		AUTO.results[#AUTO.results + 1] = "no vehicle with a depot (" .. #vehicles .. " vehicles)"
		return autoFinish()
	end
	local before = #vehicles
	local margs = { n = 3, [1] = api.engine.util.getPlayer(), [2] = pick.tv.depot, [3] = C.marshal(pick.tv.transportVehicleConfig) }
	R.translateOut("makeVehicleBuyCmd", margs, G.rev)
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = 1, fn = "makeVehicleBuyCmd", args = margs }))
	log("AUTOTEST buy a copy of vehicle " .. pick.v .. " in depot " .. pick.tv.depot .. " (" .. before .. " vehicles)")
	G.waits[#G.waits + 1] = { at = G.frames + 400, fn = function()
		local after = #R.entitiesWith("TRANSPORT_VEHICLE")
		local line = "purchase: vehicles " .. before .. " -> " .. after
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		autoFinish()
	end }
end

H.buy = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runBuy, p)
	if not ok then
		log("AUTOTEST buy failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "buy error " .. tostring(err)
		autoFinish()
	end
end

-- Line scenario: a new line with the stops of an existing line, then a vehicle bought and assigned to it
function uiRequest(fn, margs)
	R.translateOut(fn, margs, G.rev)
	AUTO.reqId = (AUTO.reqId or 0) + 1
	C.appendFile(C.DIR .. BS .. "ui.log", C.line("act_req", { tok = "auto-" .. C.ROLE, id = AUTO.reqId, fn = fn, args = margs }))
end

function runLine(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local lines = R.entitiesWith("LINE")
	if #lines == 0 then AUTO.results[#AUTO.results + 1] = "no line in the save"; return autoFinish() end
	local src = api.engine.getComponent(lines[1], api.type.ComponentType.LINE)
	local before = #lines
	local known = {}
	for _, l in ipairs(lines) do known[l] = true end
	uiRequest("makeLineCreateCmd", { n = 4, [1] = "MPF " .. C.ROLE, [2] = C.marshal(api.type.Vec3f.new(0.9, 0.2, 0.1)),
		[3] = api.engine.util.getPlayer(), [4] = C.marshal(src) })
	log("AUTOTEST line with the " .. #src.stops .. " stops of line " .. lines[1])
	G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
		local now = R.entitiesWith("LINE")
		local newLine = nil
		for _, l in ipairs(now) do if not known[l] then newLine = l end end
		local line = "line create: lines " .. before .. " -> " .. #now
		log("AUTOTEST " .. line)
		AUTO.results[#AUTO.results + 1] = line
		-- assign a vehicle of the save to the new line
		local veh = nil
		for _, v in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do veh = v; break end
		if veh and newLine and #now > before then
			uiRequest("makeVehicleSetLineCmd", { n = 3, [1] = veh, [2] = newLine, [3] = 0 })
			G.waits[#G.waits + 1] = { at = G.frames + 300, fn = function()
				local tv = api.engine.getComponent(veh, api.type.ComponentType.TRANSPORT_VEHICLE)
				local l2 = "vehicle " .. veh .. " on line " .. tostring(tv and tv.line)
				log("AUTOTEST " .. l2)
				AUTO.results[#AUTO.results + 1] = l2
				autoFinish()
			end }
		else
			autoFinish()
		end
	end }
end

H.line = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runLine, p)
	if not ok then
		log("AUTOTEST line failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "line error " .. tostring(err)
		autoFinish()
	end
end

-- Commands scenario: the player commands that no other scenario exercises (names, stopping and reversing a vehicle,
-- sending it to a depot, changing a line's waiting times, selling), sent as the interface would; the checkpoint hash
-- (names, vehicle state, lines) then says whether every game ended up the same.
function runCmds(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local lines = R.entitiesWith("LINE")
	local vehs = R.entitiesWith("TRANSPORT_VEHICLE")
	if #lines == 0 or #vehs < 2 then AUTO.results[#AUTO.results + 1] = "needs a line and two vehicles"; return autoFinish() end
	local line = lines[1]
	local v1 = vehs[((p.offset or 0) % #vehs) + 1]
	local v2 = vehs[((p.offset or 0) + 1) % #vehs + 1]
	local role = C.ROLE
	local steps = {
		{ "rename the line", function() uiRequest("makeEntitySetNameCmd", { n = 2, [1] = line, [2] = "MPF line " .. role }) end },
		{ "rename a vehicle", function() uiRequest("makeEntitySetNameCmd", { n = 2, [1] = v1, [2] = "MPF vehicle " .. role }) end },
		{ "line colour", function() uiRequest("makeEntitySetColorCmd", { n = 2, [1] = line, [2] = C.marshal(api.type.Vec3f.new(0.2, 0.8, role == "host" and 0.1 or 0.9)) }) end },
		{ "stop a vehicle", function() uiRequest("makeVehicleSetStoppedByUserCmd", { n = 2, [1] = v1, [2] = true }) end },
		{ "restart it", function() uiRequest("makeVehicleSetStoppedByUserCmd", { n = 2, [1] = v1, [2] = false }) end },
		{ "reverse a vehicle", function() uiRequest("makeVehicleReverseCmd", { n = 1, [1] = v2 }) end },
		{ "line waiting times", function()
			local lc = C.marshal(api.engine.getComponent(line, api.type.ComponentType.LINE))
			lc.stops[1].minWaitingTime = (role == "host") and 21 or 33
			lc.stops[1].maxWaitingTime = 60
			uiRequest("makeLineUpdateCmd", { n = 2, [1] = line, [2] = lc })
		end },
		{ "send a vehicle to the depot", function() uiRequest("makeVehicleSendToDepotCmd", { n = 2, [1] = v2, [2] = false }) end },
	}
	local i = 0
	local function nextStep()
		i = i + 1
		local st = steps[i]
		if not st then
			AUTO.results[#AUTO.results + 1] = "all commands sent"
			return autoFinish()
		end
		local ok, err = pcall(st[2])
		local line1 = st[1] .. ": " .. (ok and "sent" or ("error " .. tostring(err)))
		log("AUTOTEST cmds " .. line1)
		AUTO.results[#AUTO.results + 1] = line1
		G.waits[#G.waits + 1] = { at = G.frames + 240, fn = nextStep }
	end
	nextStep()
end

-- Command latency scenario: how many interface frames the engine takes to answer a command, the game running or paused
H.cmdlat = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local line = R.entitiesWith("LINE")[1]
	local k = 0
	local function one()
		k = k + 1
		if k > 6 then return autoFinish() end
		local f0 = G.frames
		local t0 = gameTime()
		local cmd = api.cmd.makeEntitySetNameCmd(line, "MPF lat " .. C.ROLE .. k)
		O.sendCommand(cmd, function(res, success)
			local msg = "cmd latency " .. (G.frames - f0) .. " frames, game speed " .. tostring(gameSpeed()) .. ", game time moved " .. (gameTime() - t0)
			log("AUTOTEST " .. msg)
			AUTO.results[#AUTO.results + 1] = msg
			G.waits[#G.waits + 1] = { at = G.frames + 60, fn = one }
		end)
	end
	one()
end

H.cmds = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runCmds, p)
	if not ok then
		log("AUTOTEST cmds failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "cmds error " .. tostring(err)
		autoFinish()
	end
end

-- Stop on a town street: the engine converts our simple proposal (refused for the parcels), we fix the converted
-- proposal (old/new segment maps, as the native stop tool sets them) and send it again
function runStops3(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and c.roadTemplate:find("town", 1, true) and #c.objects == 0 then list[#list + 1] = e end
	end
	local E = list[((p.offset or 0) * 31 + 67) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	local e = api.type.SegmentAndEntity.new()
	e.entity = -1
	e.type = 0
	local cc = e.comp
	cc.node0 = c.node0; cc.node1 = c.node1
	cc.tangent0 = vec(c.tangent0); cc.tangent1 = vec(c.tangent1)
	cc.type = 0; cc.typeIndex = -1
	cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
	cc.laneConfigs = C.templateLanes(c.roadTemplate)
	e.comp = cc
	local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
	local o = api.type.SimpleStreetProposal.EdgeObject.new()
	o.edgeEntity = -1; o.param = 0.5; o.oneWay = false; o.left = false
	o.model = "stations/street/small_stops/small_old.con"
	o.playerEntity = api.engine.util.getPlayer(); o.name = "MPF stop"
	ssp.edgesToRemove = { E }
	ssp.edgesToAdd = { e }
	ssp.edgeObjectsToAdd = { o }
	sp.streetProposal = ssp
	log("STOPS3 step 1: simple proposal on town segment " .. E)
	local ctx = playerContext()
	O.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, ctx, false, true), function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("STOPS3 step 1 result: " .. (success and "BUILT" or ("refused " .. why)))
		if success then AUTO.results[#AUTO.results + 1] = "stop built directly"; return autoFinish() end
		local okp, errp = pcall(function()
			local P2 = res.proposal
			local st = P2.proposal
			local eo = st.edgeObjectsToAdd
			local segs = st.addedSegments
			log("STOPS3 converted: added " .. #segs .. " removed " .. #st.removedSegments .. " stops " .. #eo
				.. " seg id " .. tostring(segs[1] and segs[1].entity) .. " objects " .. C.ser(C.marshal(segs[1] and segs[1].comp.objects)))
			local newId = segs[1].entity
			local seg = segs[1]
			local sc = seg.comp
			sc.objects = { { -400000000, 1 } }
			seg.comp = sc
			segs[1] = seg
			st.addedSegments = segs
			pcall(function() log("STOPS3 stop object: left=" .. tostring(eo[1].left) .. " segment=" .. tostring(eo[1].segmentEntity) .. " category=" .. tostring(eo[1].category)) end)
			-- attempts A: the converted proposal itself, repaired (positions always; maps / stop reference optional)
			local pa, pb = nodePosition(c.node0), nodePosition(c.node1)
			local base = C.ser(1)
			local function variantA(withMaps, withObj)
				local PA = res.proposal
				local stA = PA.proposal
				local segsA = stA.addedSegments
				local sA = segsA[1]
				local cA = sA.comp
				cA.position0 = vec(pa)
				cA.position1 = vec(pb)
				if withObj then cA.objects = { { -400000000, 1 } } end
				sA.comp = cA
				segsA[1] = sA
				stA.addedSegments = segsA
				if withMaps then
					stA.new2oldSegments = { [sA.entity] = { E } }
					stA.old2newSegments = { [E] = { sA.entity } }
				end
				PA.proposal = stA
				return PA
			end
			local tries = {}
			local chosen = nil
			for _, t in ipairs(tries) do
				local okf, cmdA = pcall(function() return api.cmd.makeWorldBuildProposalCmd(variantA(t[2], t[3]), playerContext(), false, true) end)
				log("STOPS3 attempt A " .. t[1] .. ": factory " .. (okf and "OK" or shortErr(cmdA)))
				if okf and cmdA and not chosen then chosen = { name = t[1], cmd = cmdA } end
			end
			if chosen then
				O.sendCommand(chosen.cmd, function(resA, successA)
					local whyA = ""
					if not successA then pcall(function() whyA = C.ser(C.marshal(resA.resultProposalData.errorState.messages)) end) end
					local nA = 0
					pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do nA = nA + 1 end end)
					log("STOPS3 attempt A '" .. chosen.name .. "': " .. (successA and "BUILT" or ("refused " .. whyA)) .. ", edge objects " .. nA)
					AUTO.results[#AUTO.results + 1] = "A " .. chosen.name .. ": " .. (successA and "BUILT" or ("refused " .. whyA))
				end)
			end
			-- attempt B: graft the converted stop object onto the engine's own replacement of the segment
			local P3 = api.engine.util.proposal.replaceSegment(E)
			local st3 = P3.proposal
			local segs3 = st3.addedSegments
			local seg3 = segs3[1]
			local c3 = seg3.comp
			c3.objects = { { -400000000, 1 } }
			seg3.comp = c3
			segs3[1] = seg3
			st3.addedSegments = segs3
			local obj = eo[1]
			obj.segmentEntity = seg3.entity
			st3.edgeObjectsToAdd = { obj }
			st3.new2oldSegments = { [seg3.entity] = { E } }
			st3.old2newSegments = { [E] = { seg3.entity } }
			log("STOPS3 node configs: converted +" .. #st.nodeConfigsToAdd .. " -" .. #st.nodeConfigsToRemove
				.. ", engine replacement +" .. #st3.nodeConfigsToAdd .. " -" .. #st3.nodeConfigsToRemove
				.. "; converted toAdd " .. #P2.toAdd .. ", segmentTags " .. tostring(#P2.segmentTags))
			if #st.nodeConfigsToAdd > 0 then
				st3.nodeConfigsToAdd = st.nodeConfigsToAdd
				st3.nodeConfigsToRemove = st.nodeConfigsToRemove
			end
			P3.proposal = st3
			log("STOPS3 grafted: segment id " .. tostring(seg3.entity) .. ", stops " .. #P3.proposal.edgeObjectsToAdd)
			P2 = P3
			O.sendCommand(api.cmd.makeWorldBuildProposalCmd(P2, playerContext(), false, true), function(res2, success2)
				local why2 = ""
				if not success2 then
					pcall(function() why2 = C.ser(C.marshal(res2.resultProposalData.errorState)) end)
					pcall(function() why2 = why2 .. " collisions " .. C.ser(C.marshal(res2.resultProposalData.collisionInfo)):sub(1, 300) end)
				end
				local n = 0
				pcall(function() for _ in pairs(api.engine.system.streetSystem.getEdgeObject2EdgeMap()) do n = n + 1 end end)
				local line = "stop via converted proposal on town segment " .. E .. ": " .. (success2 and "BUILT" or ("refused " .. why2)) .. ", edge objects now " .. n
				log("STOPS3 " .. line)
				AUTO.results[#AUTO.results + 1] = line
				G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
			end)
		end)
		if not okp then
			log("STOPS3 converted proposal failed: " .. tostring(errp))
			AUTO.results[#AUTO.results + 1] = "converted proposal error " .. tostring(errp)
			autoFinish()
		end
	end)
end

H.stops3 = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runStops3, p)
	if not ok then
		log("STOPS3 failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "stops3 error " .. tostring(err)
		autoFinish()
	end
end

-- Split scenario: a branch joining the middle of an existing segment (the most common road build)
function runSplit(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local list = {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.type == 0 and c.roadTemplate and #c.objects == 0 then
			local a, b = nodePosition(c.node0), nodePosition(c.node1)
			if a and b and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 60 then list[#list + 1] = e end
		end
	end
	local E = list[((p.offset or 0) * 31 + 11) % #list + 1]
	local c = api.engine.getComponent(E, api.type.ComponentType.BASE_EDGE)
	local A, B = nodePosition(c.node0), nodePosition(c.node1)
	local M = { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2 }
	local dx, dy = B.x - A.x, B.y - A.y
	local len = math.sqrt(dx * dx + dy * dy)
	local P = { x = M.x - dy / len * 40, y = M.y + dx / len * 40 }
	P.z = groundZ(P.x, P.y, M.z)
	local lanes = C.templateLanes(c.roadTemplate)
	if p.lanesFrom == "segment" then lanes = c.laneConfigs end
	local function seg(id, n0, n1, p0, p1, owner)
		local e = api.type.SegmentAndEntity.new()
		e.entity = id
		e.type = 0
		local cc = e.comp
		cc.node0 = n0; cc.node1 = n1
		local t = { x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z }
		cc.tangent0 = vec(t); cc.tangent1 = vec(t)
		cc.position0 = vec(p0); cc.position1 = vec(p1)
		cc.type = 0; cc.typeIndex = -1
		cc.roadTemplate = c.roadTemplate; cc.roadStyle = c.roadStyle; cc.roadType = c.roadType
		cc.laneConfigs = lanes
		e.comp = cc
		local se = e.streetEdge; se.precedenceNode0 = 2; se.precedenceNode1 = 2; e.streetEdge = se
		if owner then local po = C.newOf("PlayerOwned"); po.player = api.engine.util.getPlayer(); e.playerOwned = po end
		return e
	end
	local function node(id, q)
		local n = api.type.NodeAndEntity.new()
		n.entity = id
		local bn = n.comp; bn.position = vec(q); n.comp = bn
		return n
	end
	local sp = api.type.SimpleProposal.new()
	local ssp = sp.streetProposal
	ssp.nodesToAdd = { node(-1, M), node(-2, P) }
	ssp.edgesToAdd = { seg(-3, c.node0, -1, A, M, false), seg(-4, -1, c.node1, M, B, false), seg(-5, -1, -2, M, P, true) }
	ssp.edgesToRemove = { E }
	-- lane connections of the nodes touching the removed segment refer to it: remove those node configurations
	local ncr = {}
	for _, n in ipairs({ c.node0, c.node1 }) do
		local okn, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
		if okn and nc then ncr[#ncr + 1] = n end
	end
	if p.nodeConfigs then ssp.nodeConfigsToRemove = ncr end
	log("SPLIT node configs on the segment's nodes: " .. #ncr .. (p.nodeConfigs and " (removed)" or " (kept)"))
	sp.streetProposal = ssp
	log("SPLIT segment " .. E .. " (" .. tostring(c.roadTemplate) .. "), lanes from " .. tostring(p.lanesFrom or "template")
		.. ": template " .. tostring(#(C.templateLanes(c.roadTemplate) or {})) .. " lanes, segment " .. #c.laneConfigs .. " lanes")
	pcall(function()
		local function d(l) local t = {} for i = 1, #l do t[#t + 1] = string.format("%.1f/%s/%.2f", l[i].width, tostring(l[i].forward), l[i].offset) end return table.concat(t, " ") end
		log("SPLIT lanes template: " .. d(C.templateLanes(c.roadTemplate)) .. " | segment: " .. d(c.laneConfigs))
	end)
	local okf, cmd = pcall(function() return api.cmd.makeWorldBuildProposalCmd(sp, playerContext(), false, true) end)
	log("SPLIT factory: " .. (okf and "OK" or shortErr(cmd)))
	AUTO.results[#AUTO.results + 1] = "split factory " .. (okf and "OK" or shortErr(cmd))
	if not okf then return autoFinish() end
	O.sendCommand(cmd, function(res, success)
		local why = ""
		if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
		log("SPLIT build: " .. (success and "BUILT" or ("refused " .. why)))
		AUTO.results[#AUTO.results + 1] = "split build " .. (success and "BUILT" or ("refused " .. why))
		G.waits[#G.waits + 1] = { at = G.frames + 60, fn = autoFinish }
	end)
end

H.split = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	p.nodeConfigs = true
	local ok, err = pcall(runSplit, p)
	if not ok then
		log("SPLIT failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "split error " .. tostring(err)
		autoFinish()
	end
end

-- Road types scenario: every street/track template the game has, applied with the engine's own upgrade proposal (the
-- tools' native path: captured here, replayed by the other game); the edge hash (template, style, type, decorations)
-- then shows what a replay loses.
function allTemplateNames()
	local names = {}
	local rep = api.res.streetTemplateRep
	local ok, list = pcall(function() return rep.getAll() end)
	if ok and type(list) == "table" then
		for _, n in pairs(list) do names[#names + 1] = n end
	else
		log("AUTOTEST roadtypes: getAll failed: " .. tostring(list))
		for i = 0, 400 do
			local okg, t = pcall(function() return rep.get(i) end)
			if not okg or t == nil then break end
			local okn, nm = pcall(function() return rep.getName(i) end)
			if okn and nm then names[#names + 1] = nm end
		end
	end
	table.sort(names)
	return names
end

function runRoadTypes(p)
	AUTO.running = true
	AUTO.results = {}
	AUTO.points = {}
	local names = allTemplateNames()
	log("AUTOTEST roadtypes (" .. C.ROLE .. "): " .. #names .. " templates: " .. table.concat(names, ", "))
	local streets, tracks = {}, {}
	for _, e in ipairs(R.allEdges()) do
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if c and c.roadTemplate and c.roadTemplate ~= "" and #c.objects == 0 and not c.roadTemplate:find("entrance", 1, true) then
			local list = (c.type == 0) and streets or tracks
			list[#list + 1] = { e = e, c = c }
		end
	end
	log("AUTOTEST roadtypes: " .. #streets .. " plain street segments, " .. #tracks .. " plain track segments")
	local queue = {}
	for _, t in ipairs(names) do
		-- (highway_new_small_*: the engine itself hangs applying it as an upgrade of a country road, with or without MPFever)
		if not t:find("entrance", 1, true) and not t:find("constructions", 1, true) and not t:find("highway_new_small", 1, true) then queue[#queue + 1] = t end
	end
	-- MPFEVER_TOWN=1: town streets widened to the largest town templates (the upgrade moves buildings of the town)
	if os.getenv("MPFEVER_TOWN") then
		local town = {}
		for _, e in ipairs(streets) do if e.c.roadTemplate:find("/town/", 1, true) then town[#town + 1] = e end end
		streets = town
		queue = {}
		for _, t in ipairs(names) do
			if t:find("/town/town_new_large", 1, true) and not t:find("tram", 1, true) and not t:find("bus", 1, true) then queue[#queue + 1] = t end
		end
		for _, t in ipairs(names) do
			if t:find("/town/town_new_medium", 1, true) and not t:find("tram", 1, true) then queue[#queue + 1] = t end
		end
		log("AUTOTEST roadtypes (town mode): " .. #streets .. " town segments, templates " .. table.concat(queue, ", "))
	end
	local first = (p.offset or 0) + 1
	local done, step = 0, 0
	local limit = tonumber(os.getenv("MPFEVER_ROADTYPES") or "") or 10
	local used = {}
	local function nextOne()
		step = step + 1
		local stride = os.getenv("MPFEVER_TOWN") and 1 or 3
		local t = queue[((first - 1) + (step - 1) * stride) % math.max(1, #queue) + 1]
		if done >= limit or step > #queue + 4 + (os.getenv("MPFEVER_TOWN") and 20 or 0) or not t then return autoFinish() end
		local isTrack = t:find("track", 1, true) ~= nil
		local pool = isTrack and tracks or streets
		local pick = nil
		for k = 1, #pool do
			local cand = pool[((p.offset or 0) * 31 + step * 53 + k * 7) % #pool + 1]
			if cand.c.roadTemplate ~= t and not used[cand.e] then pick = cand; break end
		end
		if not pick then
			AUTO.results[#AUTO.results + 1] = t:match("[^/]+$") .. ": no candidate segment"
			return nextOne()
		end
		used[pick.e] = true
		local okp, P = pcall(function() return api.engine.util.proposal.replaceSegment(pick.e, t) end)
		if not okp or not P then
			local line = t:match("[^/]+$") .. ": replaceSegment failed (" .. shortErr(P) .. ")"
			log("AUTOTEST roadtypes " .. line)
			AUTO.results[#AUTO.results + 1] = line
			return nextOne()
		end
		local a = nodePosition(pick.c.node0)
		local okc, errc = pcall(function()
			local ctx = playerContext()
			if os.getenv("MPFEVER_TOOLCTX") then
				-- the flags of the game's own tools (what a replay of an upgrade uses)
				ctx.checkTerrainAlignment = true
				ctx.cleanupStreetGraph = true
				ctx.gatherBuildings = true
			end
			deferredSend(api.cmd.makeWorldBuildProposalCmd(P, ctx, false, true), function(res, success)
				local why = ""
				if not success then pcall(function() why = C.ser(C.marshal(res.resultProposalData.errorState.messages)) end) end
				local line = t:match("[^/]+$") .. " on " .. tostring(pick.c.roadTemplate):match("[^/]+$") .. ": " .. (success and "built" or ("refused " .. why))
				log("AUTOTEST roadtypes " .. line .. " [frame " .. G.frames .. "]")
				AUTO.results[#AUTO.results + 1] = line
				if success then done = done + 1; AUTO.points[#AUTO.points + 1] = a end
				G.waits[#G.waits + 1] = { at = G.frames + 90, fn = nextOne }
			end)
		end)
		if not okc then
			log("AUTOTEST roadtypes command failed: " .. shortErr(errc))
			nextOne()
		end
	end
	nextOne()
end

H.roadtypes = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runRoadTypes, p)
	if not ok then
		log("AUTOTEST roadtypes failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "roadtypes error " .. tostring(err)
		autoFinish()
	end
end

H.upgrade = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runUpgrade, p)
	if not ok then
		log("AUTOTEST upgrade failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "upgrade error " .. tostring(err)
		autoFinish()
	end
end

H.autotest_done = function(from, p)
	G.autoPoints = G.autoPoints or {}
	for _, q in ipairs(p.points or {}) do G.autoPoints[#G.autoPoints + 1] = q end
end

H.autotest = function(from, p)
	if p.role ~= C.ROLE or AUTO.running then return end
	local ok, err = pcall(runScenario, p)
	if not ok then
		log("AUTOTEST failed: " .. tostring(err))
		AUTO.results[#AUTO.results + 1] = "scenario error " .. tostring(err)
		autoFinish()
	end
end

-- what this game has around the test points: edges (rounded end positions, template) and stops
-- autotest: one game moves its camera around the map (does the camera change the simulation?)
H.camtour = function(from, p)
	if p.role ~= C.ROLE then return end
	local cam = api.gui and api.gui.camera
	if not cam then log("camtour: no api.gui.camera"); return end
	local okc, data = pcall(cam.getCameraData)
	log("camtour: camera " .. (okc and C.dump(data):sub(1, 300) or tostring(data)))
	if not okc then return end
	local spots = {}
	pcall(function()
		local edges = R.allEdges()
		for k = 1, #edges, math.max(1, math.floor(#edges / 12)) do
			local c = api.engine.getComponent(edges[k], api.type.ComponentType.BASE_EDGE)
			local q = c and nodePosition(c.node0)
			if q then spots[#spots + 1] = q end
		end
	end)
	local i = 0
	local function hop()
		i = i + 1
		local q = spots[(i % math.max(1, #spots)) + 1]
		if q then
			local ok, err = pcall(function()
				local d = cam.getCameraData()
				if d.x ~= nil then d.x, d.y = q.x, q.y else d[1], d[2] = q.x, q.y end
				cam.setCameraData(d)
			end)
			if i <= 2 then log("camtour: hop " .. i .. " -> " .. (ok and "ok" or tostring(err))) end
		end
		if i < 400 then G.waits[#G.waits + 1] = { at = G.frames + 90, fn = hop } end
	end
	hop()
end

H.area_dump = function(from, p)
	local lines = {}
	local function near(q)
		for _, c in ipairs(G.autoPoints or {}) do
			local dx, dy = q.x - c.x, q.y - c.y
			if dx * dx + dy * dy < 400 * 400 then return true end
		end
		return false
	end
	local function r(v) return string.format("%.0f", v) end
	for _, e in ipairs(R.allEdges()) do repeat
		local c = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE)
		if not c then break end
		local a, b = nodePosition(c.node0), nodePosition(c.node1)
		if a and b and (near(a) or near(b)) then
			local s1, s2 = r(a.x) .. "," .. r(a.y), r(b.x) .. "," .. r(b.y)
			if s1 > s2 then s1, s2 = s2, s1 end
			local objs = {}
			for i = 1, #c.objects do
				local eo = api.engine.getComponent(c.objects[i][1], api.type.ComponentType.EDGE_OBJECT)
				objs[#objs + 1] = (eo and tostring(eo.edgeObjectConstruction) or "?") .. "@" .. (eo and string.format("%.2f", eo.param) or "?")
			end
			lines[#lines + 1] = "edge " .. s1 .. " - " .. s2 .. " " .. tostring(c.roadTemplate) .. (#objs > 0 and (" objects " .. table.concat(objs, ";")) or "")
		end
	until true end
	-- every node configuration (lane connections, crosswalks, traffic lights), as the checkpoint hash sees it
	pcall(function()
		for _, n in ipairs(R.allNodes()) do
			local okc, nc = pcall(function() return api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) end)
			local q = okc and nc and nodePosition(n)
			if q then
				lines[#lines + 1] = string.format("nodecfg %.0f,%.0f lc=%d cw=%d pref=%s", q.x, q.y, #nc.laneConnections, #nc.crosswalks, tostring(nc.trafficLightPreference))
			end
		end
	end)
	-- every construction (file and rounded position, as the checkpoint hash sees it): what a moved building changes
	pcall(function()
		for _, e in ipairs(R.entitiesWith("CONSTRUCTION")) do
			local c = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION)
			local m = c and c.transf
			if m then
				local pp = R.matPos and R.matPos(m)
				lines[#lines + 1] = string.format("con %s %.1f,%.1f", tostring(c.fileName), pp and pp.x or 0, pp and pp.y or 0)
			end
		end
	end)
	table.sort(lines)
	local f = C.IO.open(C.DIR .. BS .. "area.txt", "wb")
	if f then
		f:write("t=" .. gameTime() .. NL .. table.concat(lines, NL) .. NL)
		f:close()
	end
	send("area_done", { n = #lines })
end

end
